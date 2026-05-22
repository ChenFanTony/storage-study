# Day 2 — blk-mq core dispatch

**Week 1**: Block Layer — blk-mq and SCSI Mid Layer  
**Time**: 1–2 hours  
**Reference**: `block/blk-mq.c`, `block/blk-mq.h`, `block/blk-mq-tag.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted; verify against elixir.bootlin.com for the kernel version you target.

---

## Why blk-mq

The old single-queue block layer serialized all I/O through one spinlock. On multi-core machines
with fast devices (10GbE iSCSI, NVMe), that lock became the bottleneck. blk-mq replaces it with:

- **Per-CPU software queues** (`blk_mq_ctx`) — no cross-CPU contention when submitting
- **Multiple hardware queues** (`blk_mq_hw_ctx`) — one per NVMe queue or one per iSCSI session
- **Tag-based flow control** — in-flight count bounded per hardware queue

Most iSCSI deployments use a single hardware queue per session, but multi-queue iSCSI is
supported (Mike Christie's series; both `iscsi_tcp` and `iser` honor `nr_hw_queues > 1`). NVMe
typically uses one hardware queue per CPU core. blk-mq handles both uniformly through the same
dispatch machinery.

---

## struct blk_mq_ctx — per-CPU software queue — `block/blk-mq.h`

```c
struct blk_mq_ctx {
    struct {
        spinlock_t      lock;
        /* pending requests before dispatch, per hctx type */
        struct list_head rq_lists[HCTX_MAX_TYPES];
    } ____cacheline_aligned_in_smp;

    unsigned int        cpu;          /* CPU this ctx belongs to */
    unsigned short      index_hw[HCTX_MAX_TYPES]; /* hw queue indices */
    struct blk_mq_hw_ctx *hctxs[HCTX_MAX_TYPES]; /* corresponding hctxs */

    struct request_queue *queue;
    struct kobject       kobj;
} ____cacheline_aligned_in_smp;
```

Requests submitted on CPU N go into CPU N's `blk_mq_ctx`. The `____cacheline_aligned_in_smp`
attribute ensures the lock and list are on their own cache line — no false sharing between CPUs.

`HCTX_MAX_TYPES` = 3 (`HCTX_TYPE_DEFAULT`, `HCTX_TYPE_READ`, `HCTX_TYPE_POLL`). For typical iSCSI
deployments only `HCTX_TYPE_DEFAULT` is used.

---

## struct blk_mq_hw_ctx — hardware queue — `block/blk-mq.h`

```c
struct blk_mq_hw_ctx {
    struct {
        spinlock_t      lock;
        struct list_head dispatch;   /* requests waiting for driver — drained first */
        unsigned long   state;       /* BLK_MQ_S_* bitflags */
    } ____cacheline_aligned_in_smp;

    struct delayed_work run_work;    /* async kick: kblockd schedules this */
    cpumask_var_t       cpumask;     /* CPUs mapped to this hw queue */
    int                 next_cpu;    /* round-robin CPU for work */

    unsigned int        nr_ctx;      /* number of sw queues feeding this hw queue */
    struct blk_mq_ctx **ctxs;        /* the sw queues */

    atomic_t            nr_active;   /* in-flight request count */
    struct blk_mq_tags  *tags;       /* tag set — bounds in-flight */
    struct blk_mq_tags  *sched_tags; /* scheduler-managed tags */

    unsigned long       queued;      /* dispatch counter */
    unsigned long       run;         /* run_hw_queue counter */

    unsigned int        queue_num;   /* index in q->queue_hw_ctx[] */
    unsigned int        numa_node;

    struct request_queue *queue;
    struct blk_flush_queue *fq;      /* flush request machinery */

    void               *sched_data;  /* I/O scheduler private data */
    struct list_head    hctx_list;
};

/* hctx->state bits */
#define BLK_MQ_S_STOPPED    0   /* dispatch paused — no new requests sent */
#define BLK_MQ_S_TAG_ACTIVE 1   /* tag set is active */
#define BLK_MQ_S_SCHED_RESTART 2 /* scheduler requested restart */
```

`hctx->dispatch` is the key list. Requests that the driver could not accept (returned
`BLK_STS_RESOURCE`) land here. The next dispatch attempt drains this list FIRST before touching
the I/O scheduler. This is where head-injected passthrough requests (via `blk_execute_rq`) are
queued.

`BLK_MQ_S_STOPPED` can be set by drivers (or by dm at the dm layer) to halt dispatch entirely.
Note that dm-multipath manages queueing at the dm device's level (via `m->queued_bios`); it does
NOT directly stop the underlying SCSI device's hctx — those continue to dispatch normally.

---

## blk_mq_submit_bio — `block/blk-mq.c` (simplified)

Entry point when `submit_bio()` is called. Converts bio → request and kicks dispatch.

```c
/* Simplified — actual implementation uses __blk_mq_alloc_requests() and
 * is structured differently. See block/blk-mq.c for the real code. */
void blk_mq_submit_bio(struct bio *bio)
{
    struct request_queue *q = bdev_get_queue(bio->bi_bdev);
    struct request *rq;
    struct blk_plug *plug;

    /*
     * Plug: if the caller is batching bios (blk_start_plug was called),
     * add to the plug list and return without dispatching.
     * The plug is flushed when blk_finish_plug() is called.
     */
    plug = blk_mq_plug(bio);

    /*
     * Try to merge this bio with the last pending request on this CPU's
     * software queue. Merging reduces the number of requests sent.
     */
    if (plug && !blk_queue_nomerges(q)) {
        if (blk_attempt_plug_merge(q, bio, nr_segs))
            return;  /* merged — no new request needed */
    }

    /*
     * Allocate a new request from the tag pool.
     * This may block if no tags are available (driver is saturated).
     */
    rq = __blk_mq_alloc_requests(...);
    if (unlikely(!rq)) {
        bio->bi_status = BLK_STS_RESOURCE;
        bio_endio(bio);
        return;
    }

    /* initialize request fields from bio */
    blk_mq_bio_to_request(rq, bio, nr_segs);

    if (plug) {
        blk_add_rq_to_plug(plug, rq);  /* batch for later */
    } else {
        /* hand to scheduler (if any) and run the queue */
        blk_mq_run_hw_queue(rq->mq_hctx, true);
    }
}
```

Plugging is important for sequential write performance regardless of the underlying transport.
Filesystems can submit hundreds of bios for a large write inside a plug, which then merge into a
much smaller number of requests when the plug is flushed. This applies to iSCSI just as much as
to NVMe — any time iSCSI backs a filesystem on the initiator, writeback I/O traverses the plug.

---

## blk_mq_dispatch_rq_list — `block/blk-mq.c`

The core dispatch function. Pulls requests from the list and calls the driver's `queue_rq`.

```c
/* Simplified — see block/blk-mq.c for the full implementation. */
bool blk_mq_dispatch_rq_list(struct blk_mq_hw_ctx *hctx,
                               struct list_head *list,
                               unsigned int nr_budgets)
{
    struct request_queue *q = hctx->queue;
    struct request *rq;
    int errors = 0, queued = 0;
    blk_status_t ret = BLK_STS_OK;

    do {
        struct blk_mq_queue_data bd;

        rq = list_first_entry(list, struct request, queuelist);

        if (!blk_mq_get_dispatch_budget(hctx))
            break;  /* budget (tag) exhausted */

        list_del_init(&rq->queuelist);

        bd.rq   = rq;
        bd.last = list_empty(list); /* hint: is this the last request? */

        /*
         * Call the driver's queue_rq operation.
         * For SCSI: this is scsi_queue_rq()
         * For iSCSI LLD: this eventually calls iscsi_queuecommand()
         */
        ret = q->mq_ops->queue_rq(hctx, &bd);

        switch (ret) {
        case BLK_STS_OK:
            queued++;
            break;

        case BLK_STS_RESOURCE:
        case BLK_STS_DEV_RESOURCE:
            /*
             * Driver temporarily cannot accept more I/O.
             * Put request back — it will be retried on next dispatch.
             */
            blk_mq_requeue_request(rq, false);
            goto out;

        default:
            /* hard error — complete the request with the error status */
            errors++;
            blk_mq_end_request(rq, ret);
        }
    } while (!list_empty(list));

out:
    /* anything left in list goes back to hctx->dispatch */
    if (!list_empty(list)) {
        spin_lock(&hctx->lock);
        list_splice_init(list, &hctx->dispatch);
        spin_unlock(&hctx->lock);
        /*
         * If driver is busy, the scheduler will be re-kicked when
         * resources free up (e.g. via blk_mq_delay_run_hw_queue).
         */
    }

    return queued + errors != 0;
}
```

The `BLK_STS_RESOURCE` path is the back-pressure mechanism. When `iscsi_queuecommand()` returns
`SCSI_MLQUEUE_HOST_BUSY` (no task slots), it maps to `BLK_STS_RESOURCE`, the request goes back to
`hctx->dispatch`, and dispatch pauses until a completion frees a slot.

---

## blk_mq_run_hw_queues — `block/blk-mq.c`

Called whenever there might be work ready — after new request, after completion, after path recovery.

```c
void blk_mq_run_hw_queues(struct request_queue *q, bool async)
{
    struct blk_mq_hw_ctx *hctx;
    unsigned long i;

    queue_for_each_hw_ctx(q, hctx, i) {
        if (blk_mq_hctx_stopped(hctx))
            continue;   /* BLK_MQ_S_STOPPED — skip */

        blk_mq_run_hw_queue(hctx, async);
    }
}

void blk_mq_run_hw_queue(struct blk_mq_hw_ctx *hctx, bool async)
{
    bool need_run = !blk_mq_hctx_stopped(hctx) &&
                    blk_mq_hctx_has_work(hctx);

    if (need_run) {
        if (!async && !(hctx->flags & BLK_MQ_F_BLOCKING)) {
            /* run inline on the calling CPU */
            __blk_mq_run_hw_queue(hctx);
        } else {
            /* defer to kblockd kthread */
            kblockd_mod_delayed_work_on(blk_mq_hctx_next_cpu(hctx),
                                        &hctx->run_work, 0);
        }
    }
}
```

`async=true` defers to `kblockd` — used when running from completion softirq context where
sleeping or re-entering dispatch would be unsafe. `async=false` runs inline — used by
`blk_execute_rq()` before calling `wait_for_completion()` (day 3).

`__blk_mq_run_hw_queue()` calls `blk_mq_sched_dispatch_requests()`:

```c
static void blk_mq_sched_dispatch_requests(struct blk_mq_hw_ctx *hctx)
{
    LIST_HEAD(rq_list);

    /*
     * Step 1: drain hctx->dispatch first (leftover from previous attempt).
     * This is what ensures passthrough requests injected at head are sent
     * before any scheduler-queued I/O.
     */
    if (!list_empty_careful(&hctx->dispatch)) {
        spin_lock(&hctx->lock);
        list_splice_init(&hctx->dispatch, &rq_list);
        spin_unlock(&hctx->lock);
    }

    /* Step 2: ask the I/O scheduler for more requests */
    if (!list_empty(&rq_list) || blk_mq_hctx_has_work(hctx))
        blk_mq_dispatch_rq_list(hctx, &rq_list, 0);
}
```

The two-step order (dispatch leftover first, then scheduler) is what makes `at_head=true`
injection work for the PR slow path.

---

## Tag allocation — `block/blk-mq-tag.c`

Tags are integers [0, queue_depth) that uniquely identify in-flight requests. The driver uses them
to match completions: iSCSI uses the tag as part of ITT, NVMe uses it as command ID.

```c
/* Simplified — real function is more involved. See block/blk-mq-tag.c. */
unsigned int blk_mq_get_tag(struct blk_mq_alloc_data *data)
{
    struct blk_mq_tags *tags = blk_mq_tags_from_data(data);
    int tag;

    /*
     * Try to atomically allocate a tag from the bitmap.
     * __sbitmap_queue_get() finds and sets a free bit in O(1) amortized.
     * If unavailable and blocking is allowed, the call sleeps on
     * bt_wait_ptr() until a tag is freed.
     */
    tag = __sbitmap_queue_get(&tags->bitmap_tags);
    if (tag < 0 && (data->flags & BLK_MQ_REQ_RESERVED))
        tag = __sbitmap_queue_get(&tags->breserved_tags);

    return tag >= 0 ? tag : BLK_MQ_NO_TAG;
}
```

When `blk_mq_get_tag()` returns `BLK_MQ_NO_TAG`, the driver's in-flight limit is reached. The
request cannot be dispatched. For iSCSI, tag depth = `cmds_max` configured during session setup
(open-iscsi default: 128).

Tag release on completion:
```c
void blk_mq_put_tag(struct blk_mq_tags *tags,
                    struct blk_mq_ctx *ctx, unsigned int tag)
{
    if (!blk_mq_tag_is_reserved(tags, tag)) {
        const int real_tag = tag - tags->nr_reserved_tags;
        sbitmap_queue_clear(&tags->bitmap_tags, real_tag, ctx->cpu);
    } else {
        sbitmap_queue_clear(&tags->breserved_tags,
                            tag, ctx->cpu);
    }
}
```

After `sbitmap_queue_clear()`, any threads waiting for a tag are woken and dispatch resumes.

---

## Key takeaways

- blk-mq uses per-CPU `blk_mq_ctx` (software queues) to avoid lock contention, feeding into
  per-device `blk_mq_hw_ctx` (hardware queues).
- `blk_mq_submit_bio()` tries bio merging, allocates a tag/request, and kicks dispatch.
- `blk_mq_dispatch_rq_list()` calls `queue_rq()` on the driver. `BLK_STS_RESOURCE` → request goes
  back to `hctx->dispatch`.
- `blk_mq_sched_dispatch_requests()` always drains `hctx->dispatch` FIRST, then the scheduler.
  This is why head-injected passthrough requests go immediately.
- `BLK_MQ_S_STOPPED` on an hctx pauses all dispatch on that hctx. dm-multipath manages
  bio queueing at the dm layer (`m->queued_bios`), not by stopping the underlying device's hctx.
- Tags bound in-flight depth. No tag = no dispatch until a completion returns one.
- `kblockd` is the fallback kthread for async dispatch when inline dispatch is unsafe.

---

## Previous / Next

[Day 1 — bio and request structs](day01.md) | [Day 3 — blk_execute_rq the slow path](day03.md)
