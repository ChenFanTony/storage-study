# Day 3 — blk_execute_rq: the slow path

**Week 1**: Block Layer — blk-mq and SCSI Mid Layer  
**Time**: 1–2 hours  
**Reference**: `block/blk-exec.c`, `block/blk-mq.c`, `include/linux/blkdev.h`

---

## Why a separate slow path exists

Normal I/O (READ/WRITE) is asynchronous — the caller submits a bio and receives a callback via
`bi_end_io` when done. The caller moves on immediately. This works well for filesystem I/O where
the application doesn't need to wait for any particular result before proceeding.

But some SCSI commands require a synchronous result before the caller can proceed:
- `PERSISTENT RESERVE OUT` — registration must succeed before claiming the reservation
- `INQUIRY` — the caller needs device identification data before deciding anything
- `TEST UNIT READY` — need to know device state right now, not later
- `MODE SELECT` — parameters must be applied before issuing further I/O

For these, the kernel uses `blk_execute_rq()` which injects the request at the HEAD of the queue
and blocks the calling thread until the command completes. This is the "slow path."

---

## blk_rq_is_passthrough — the discriminator used everywhere

```c
/* block/blk-mq.h */
static inline bool blk_rq_is_passthrough(struct request *rq)
{
    return blk_op_is_passthrough(rq->cmd_flags);
}

static inline bool blk_op_is_passthrough(blk_opf_t op)
{
    op &= REQ_OP_MASK;  /* mask off modifier flags, keep only operation */
    return op == REQ_OP_DRV_IN || op == REQ_OP_DRV_OUT;
}
```

This check appears at multiple key points:

| Location | What it does when true |
|---|---|
| `blk_mq_submit_bio()` | skips I/O scheduler, goes direct |
| `blk_execute_rq()` | asserts this must be passthrough |
| `scsi_io_completion()` | skips retry logic, completes directly |
| `blk_mq_sched_dispatch_requests()` | injects at head via `hctx->dispatch` |

A PR command has `REQ_OP_DRV_OUT` set. A READ has `REQ_OP_READ`. This one flag determines the
code path at every layer of the stack.

---

## blk_execute_rq — `block/blk-exec.c`

```c
blk_status_t blk_execute_rq(struct request *rq, bool at_head)
{
    DECLARE_COMPLETION_ONSTACK(wait);
    struct blk_rq_wait data = {
        .done = &wait,
    };

    WARN_ON(irqs_disabled());
    WARN_ON(!blk_rq_is_passthrough(rq));  /* must be passthrough */

    rq->end_io_data = &data;
    rq->end_io      = blk_end_sync_rq;   /* completion wakes us */

    blk_account_io_start(rq);

    /*
     * Inject the request into the queue. at_head=true puts it at the
     * front of hctx->dispatch, ahead of all pending I/O.
     * Then kick the queue — the request is dispatched before we sleep.
     */
    blk_execute_rq_nowait(rq, at_head);

    /*
     * Sleep until blk_end_sync_rq() calls complete().
     * TASK_UNINTERRUPTIBLE | TASK_IO — counts as I/O wait in iostat.
     * The stack frame stays alive with 'data' and 'wait' on it.
     */
    wait_for_completion_io(&wait);

    return data.ret;  /* blk_status_t set by blk_end_sync_rq */
}
```

`DECLARE_COMPLETION_ONSTACK(wait)` creates a `struct completion` on the calling thread's kernel
stack. This is safe because the function blocks until completion — the stack frame is alive.

```c
/* the completion callback — called by the driver on command done */
static void blk_end_sync_rq(struct request *rq, blk_status_t error)
{
    struct blk_rq_wait *data = rq->end_io_data;

    data->ret = error;    /* store the result where the sleeper will read it */
    complete(data->done); /* wake the thread sleeping in wait_for_completion_io */
}
```

`complete()` sets `wait.done = 1` and calls `wake_up()` on the wait queue embedded in the
`completion` struct. The sleeping thread wakes, reads `data.ret`, and `blk_execute_rq()` returns.

---

## blk_execute_rq_nowait — the injection

```c
void blk_execute_rq_nowait(struct request *rq, bool at_head)
{
    WARN_ON(irqs_disabled());
    WARN_ON(!blk_rq_is_passthrough(rq));

    blk_account_io_start(rq);

    if (at_head)
        blk_mq_insert_request(rq, BLK_MQ_INSERT_AT_HEAD);
    else
        blk_mq_insert_request(rq, 0);

    /*
     * Kick dispatch immediately (async=false = run inline).
     * By the time wait_for_completion_io() is called below in the caller,
     * the request is already on the wire.
     */
    blk_mq_run_hw_queues(rq->q, false);
}
```

`blk_mq_insert_request(rq, BLK_MQ_INSERT_AT_HEAD)`:

```c
void blk_mq_insert_request(struct request *rq, blk_insert_t flags)
{
    struct request_queue *q = rq->q;
    struct blk_mq_hw_ctx *hctx;

    hctx = blk_mq_map_queue(q, rq->cmd_flags, rq->mq_ctx);

    if (flags & BLK_MQ_INSERT_AT_HEAD) {
        spin_lock(&hctx->lock);
        list_add(&rq->queuelist, &hctx->dispatch); /* HEAD of dispatch list */
        spin_unlock(&hctx->lock);
    } else {
        blk_mq_sched_insert_request(rq, false, true, false);
    }
}
```

Inserting at the HEAD of `hctx->dispatch` means this request will be the very first one processed
by the next call to `blk_mq_sched_dispatch_requests()`, which always drains `hctx->dispatch` before
consulting the I/O scheduler (day 2).

---

## Full execution timeline

```
scsi_execute_cmd()           (day 4 — builds the request)
    │
    ▼
blk_execute_rq(rq, at_head=true)
    │
    ├── rq->end_io = blk_end_sync_rq
    ├── blk_execute_rq_nowait(rq, true)
    │       ├── blk_mq_insert_request(rq, AT_HEAD)
    │       │     └── list_add(&rq->queuelist, &hctx->dispatch)  ← HEAD
    │       └── blk_mq_run_hw_queues(q, async=false)
    │             └── __blk_mq_run_hw_queue(hctx)
    │                   └── blk_mq_sched_dispatch_requests(hctx)
    │                         ├── drain hctx->dispatch → finds our rq first
    │                         └── blk_mq_dispatch_rq_list()
    │                               └── q->mq_ops->queue_rq()  ← PDU on wire
    │
    └── wait_for_completion_io(&wait)   ← caller sleeps HERE
              │
              │  (time passes, target responds, RX thread receives response)
              │
              ▼
        blk_end_sync_rq(rq, BLK_STS_OK)
              └── complete(&wait)       ← caller wakes
    │
    ▼
return data.ret  (blk_status_t)
```

The key insight: `blk_mq_run_hw_queues()` is called BEFORE `wait_for_completion_io()`. By the time
the thread goes to sleep, the PR PDU is already transmitted. The thread wakes only when the target
sends back a response.

---

## Why no_path_retry=queue cannot affect slow path requests

`no_path_retry=queue` is implemented in `multipath_map_bio()` (day 7) — it intercepts `bio`s
submitted to the dm device and holds them in `m->queued_ios` when no path is available.

PR commands never go through `multipath_map_bio()`. They reach the underlying `/dev/sdX` directly
via `sd_pr_ops->reserve()` → `sd_pr_reserve()` → `scsi_execute_cmd()`. The dm device is bypassed
entirely.

Even if a passthrough request somehow reached the dm device, `blk_rq_is_passthrough()` would
cause it to skip the I/O scheduler and `multipath_map_bio()` would not be called for it — dm uses
`dm_make_request()` which calls `__split_and_process_bio()` which calls the target's `map_bio()`,
but passthrough requests use `dm_dispatch_clone_request()` directly.

---

## Contrast: async fast path vs sync slow path

```
ASYNC FAST PATH (READ/WRITE)         SYNC SLOW PATH (PR/passthrough)
────────────────────────────         ─────────────────────────────────
submit_bio(bio)                      blk_execute_rq(rq, at_head=true)
    │                                    │
    ▼                                    ▼
blk_mq_submit_bio()                  blk_execute_rq_nowait()
 bio → request                        rq injected at HEAD of hctx->dispatch
 I/O scheduler may reorder            no scheduler involvement
    │                                    │
    ▼                                    ▼
blk_mq_dispatch_rq_list()           blk_mq_dispatch_rq_list()
 calls queue_rq()                     calls queue_rq() immediately
    │                                    │
    ▼                                    ▼
Driver / network                     Driver / network
    │                                    │
    ▼  (softirq / interrupt)             ▼  (softirq / interrupt)
bi_end_io() callback                 blk_end_sync_rq()
 async — caller already gone          complete() — wakes sleeping thread
    │                                    │
    ▼                                    ▼
VFS / filesystem notified            blk_execute_rq() returns
 error propagates up call stack       caller reads result inline
```

In the async path, the caller is gone when the completion fires — no thread to wake, just a
callback. In the slow path, the calling thread's stack is alive holding `struct completion` and
`struct blk_rq_wait`. There is nothing for dm-multipath to requeue.

---

## Key takeaways

- `blk_execute_rq()` injects at HEAD of `hctx->dispatch` via `at_head=true`, then sleeps via
  `wait_for_completion_io()`.
- `blk_end_sync_rq()` is the completion callback — it stores the result and calls `complete()` to
  wake the sleeping thread.
- `blk_rq_is_passthrough()` is the discriminator checked at every layer. `REQ_OP_DRV_IN/OUT`
  marks a request as passthrough.
- `blk_mq_run_hw_queues()` fires BEFORE `wait_for_completion_io()` — the PDU is on the wire
  before the thread sleeps.
- The slow path bypasses: I/O scheduler, dm-multipath bio interception, all retry logic.
- `no_path_retry=queue` cannot affect PR commands — they never reach `multipath_map_bio()`.
- `wait_for_completion_io()` sets `TASK_UNINTERRUPTIBLE | TASK_IO` — counted as I/O wait in `top`.

---

## Previous / Next

[Day 2 — blk-mq core dispatch](day02.md) | [Day 4 — SCSI mid layer queueing](day04.md)
