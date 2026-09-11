# Day 2: blk-mq — Hardware Queues, Tag Sets, Dispatch

<!-- study-nav -->
[← Previous: Day 1](day01-storage-stack-gap-fill.md) | [Next: Day 3 — blk-mq: Scheduler Interaction & Plug/Unplug →](day03-blk-mq-scheduler-plug.md)

> **Source baseline:** Linux `v7.2-rc3` (`block/blk-mq.c`); function names and call paths below follow this version.

## Learning Objectives
- Understand blk-mq's two-level queue architecture in depth
- Follow the exact path from `submit_bio()` to `queue_rq()` in driver
- Understand tag set allocation and what a tag actually is
- Measure queue depth impact and explain the tradeoffs
- Be able to explain the architecture to another engineer from first principles

---

## 1. Why blk-mq Exists — The Architecture Problem It Solves

Legacy single-queue block layer had a global lock per request queue.
NVMe can handle 64K+ IOPS with tens of hardware queues — the global lock
became a bottleneck before the device was even close to saturated.

blk-mq solution:
- **Per-CPU software queues** — eliminate cross-CPU contention for staging
- **Multiple hardware queues** — match device parallelism (NVMe: 1 HW queue per CPU core or per interrupt vector)
- **Tag-based request tracking** — O(1) request allocation without global locks

```
              CPU 0        CPU 1        CPU 2        CPU 3
            ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐
            │ sw ctx │  │ sw ctx │  │ sw ctx │  │ sw ctx │  (blk_mq_ctx, per-CPU)
            └───┬────┘  └───┬────┘  └───┬────┘  └───┬────┘
                │            │            │            │
                └────────────┴────────────┴────────────┘
                             │  (mapped to HW queues)
                    ┌────────┴────────┐
                    │   HW queue 0    │  (blk_mq_hw_ctx)
                    │   HW queue 1    │
                    │   HW queue N    │
                    └────────┬────────┘
                             │ queue_rq()
                    ┌────────┴────────┐
                    │  NVMe SQ/CQ     │  (hardware submission/completion queues)
                    └─────────────────┘
```

For virtio-blk: typically 1–4 HW queues, many CPUs map to same queue.
For NVMe: often 1 HW queue per CPU (or per interrupt vector).

---

## 2. Key Data Structures

### `struct blk_mq_tag_set` — the device-level resource pool
```c
struct blk_mq_tag_set {
    const struct blk_mq_ops *ops;       // driver callbacks (queue_rq, etc.)
    unsigned int            nr_hw_queues; // number of hardware queues
    unsigned int            queue_depth;  // max in-flight per HW queue (== nr_tags)
    unsigned int            cmd_size;     // driver-private per-request data size
    struct blk_mq_tags      **tags;       // one blk_mq_tags per HW queue
    // ...
};
```

The tag set is **shared across all request_queues** if a driver manages multiple devices
with the same tag set (e.g., NVMe namespaces sharing the controller's queue).

### `struct blk_mq_tags` — per-HW-queue tag bitmap
```c
struct blk_mq_tags {
    unsigned int    nr_tags;        // == queue_depth
    unsigned int    nr_reserved_tags;
    struct sbitmap_queue bitmap_tags;    // fast bitmap allocator
    struct sbitmap_queue breserved_tags;
    struct request  **rqs;          // rqs[tag] → in-flight request
    struct request  **static_rqs;   // pre-allocated request pool
    // ...
};
```

A **tag** is just an index into `rqs[]`. Allocating a tag = atomically claiming a slot.
This is what limits queue depth: no tag available = request must wait.

### `struct blk_mq_hw_ctx` — one hardware dispatch queue
```c
struct blk_mq_hw_ctx {
    struct blk_mq_tags  *tags;       // points into tag_set->tags[hctx_idx]
    struct blk_mq_ctx   **ctxs;      // sw queues mapped to this hw queue
    unsigned int        nr_ctx;      // number of sw queues mapped here
    struct request_queue *queue;
    struct blk_mq_tag_set *tag_set;
    // dispatch list, run state, ...
};
```

### `struct blk_mq_ctx` — per-CPU software queue
```c
struct blk_mq_ctx {
    struct blk_mq_hw_ctx *hctx;     // which HW queue this CPU maps to
    unsigned int         cpu;
    // rq_lists for dispatch staging
};
```

---

## 3. The bio → request → dispatch Path

### Step 1: `submit_bio()` → `blk_mq_submit_bio()`

```c
// block/blk-core.c
void submit_bio(struct bio *bio)
{
    // cgroup throttle check
    // accounting
    __submit_bio(bio);
}

// → __submit_bio_noacct_mq()
// → blk_mq_submit_bio(bio)
```

### Step 2: Attempt merge (`blk_mq_submit_bio`)

```c
// block/blk-mq.c
blk_mq_submit_bio(bio):
    // 1. Reuse a tagged request cached by the current plug, if available
    rq = blk_mq_get_cached_request(plug, q, bio->bi_opf);

    // 2. Try plug or elevator merge
    if (blk_mq_attempt_bio_merge(q, bio, nr_segs))
        return;

    // 3. No cached request and no merge — allocate request and tag(s)
    if (!rq)
        rq = blk_mq_get_new_requests(q, plug, bio);

    // 4. Attach the bio after request allocation
    blk_mq_bio_to_request(rq, bio, nr_segs);
```

### Step 3: Request and tag allocation (`blk_mq_get_new_requests` → `__blk_mq_alloc_requests`)

```c
// block/blk-mq.c
blk_mq_get_new_requests(q, plug, bio):
    // initialize allocation data; a plug can request a batch of tags
    data.cmd_flags = bio->bi_opf;
    data.nr_tags = plug ? plug->nr_ios : 1;
    rq = __blk_mq_alloc_requests(&data);

__blk_mq_alloc_requests(data):
    // map the current per-CPU software context to a hardware context
    data->ctx = blk_mq_get_ctx(q);
    data->hctx = blk_mq_map_queue(data->cmd_flags, data->ctx);

    // apply scheduler depth limits and try batched allocation when requested
    blk_mq_limit_depth(data);

    // allocate a driver or scheduler tag; a waiting allocation can sleep
    tag = blk_mq_get_tag(data);
    rq = blk_mq_rq_ctx_init(data, blk_mq_tags_from_data(data), tag);
    return rq;
```

If no tag is available, a normal allocation waits in `blk_mq_get_tag()`.
An allocation carrying `REQ_NOWAIT` returns `BLK_MQ_NO_TAG`; the submission
path then completes the bio with a would-block error. This is controlled by
`REQ_NOWAIT`, not simply by whether the caller uses synchronous or asynchronous I/O.

### Step 4: I/O scheduler (if not `none`)

```c
// bio → request conversion is done; now scheduler may reorder
e->type->ops.insert_requests(hctx, &rq_list, flags);
// scheduler holds requests, reorders by deadline / cfq / bfq policy
// then releases them for dispatch
```

Without a scheduler, `blk_mq_submit_bio()` normally tries
`blk_mq_try_issue_directly()`; resource shortages move the request to
`hctx->dispatch` for a later `blk_mq_run_hw_queue()`. This avoids scheduler
work while preserving retry handling.

### Step 5: Dispatch to driver

```c
// block/blk-mq.c
// Fast path used by blk_mq_submit_bio() when no scheduler is required
blk_mq_try_issue_directly(hctx, rq):
    ret = __blk_mq_issue_directly(hctx, rq, true);
    // resource shortage: insert into hctx->dispatch and rerun the queue

// Queued path used for scheduler or dispatch-list requests
blk_mq_run_hw_queue(hctx, async):
    blk_mq_run_dispatch_ops(q,
        blk_mq_sched_dispatch_requests(hctx));
            // dispatch ultimately calls q->mq_ops->queue_rq(hctx, &bd)
            // on success, the driver owns the request
```

### Step 6: Completion

```c
// driver calls (e.g., NVMe IRQ handler):
blk_mq_complete_request(rq);
    → blk_mq_end_request(rq, error);
        → blk_mq_free_request(rq);  // frees tag back to bitmap
            → bio->bi_end_io(bio);  // wakes waiter / io_uring CQE
```

---

## 4. Queue Depth: What It Really Controls

`queue_depth` (set in `blk_mq_tag_set.queue_depth`) = **maximum simultaneous in-flight requests per HW queue**.

This is NOT the same as `nr_requests` in sysfs (that's the scheduler queue limit).

```bash
# sysfs: scheduler queue depth (requests waiting in elevator)
cat /sys/block/nvme0n1/queue/nr_requests

# Actual tag set depth, per hardware queue. Each /sys/block/<dev>/mq/N
# directory corresponds to one hardware queue (indexed 0..nr_hw_queues-1).
for d in /sys/block/nvme0n1/mq/*/; do
    echo "$d nr_tags=$(cat $d/nr_tags)"
done

# io depth in flight at any moment:
cat /sys/block/nvme0n1/inflight
```

**Too low queue depth:**
- device underutilized (NVMe can sustain 32–128+ in-flight easily)
- throughput limited by round-trip latency × queue_depth

**Too high queue depth:**
- tag exhaustion less likely
- but p99 latency increases (requests wait behind a long queue)
- scheduler loses ability to reorder (queue too deep to be effective)

**Rule of thumb for NVMe:** start at 32–64, validate with `fio --iodepth`.
For virtio-blk in VMs: often 32–128 depending on hypervisor implementation.

---

## 5. CPU → HW Queue Mapping

```bash
# See the mapping: which CPUs map to which HW queues.
# One mq/N directory per HW queue; cpu_list inside it shows the CPUs
# that dispatch through that queue.
for d in /sys/block/nvme0n1/mq/*/; do
    echo "$d cpu_list=$(cat $d/cpu_list)"
done
```

The mapping is set at driver init time via `blk_mq_map_queues()` or
driver-specific `map_queues` callback. NVMe typically uses IRQ affinity
to align each HW queue with a CPU core or NUMA node.

**Implication for architects:** NUMA-aware queue mapping matters for NVMe
on multi-socket servers. Cross-NUMA queue dispatch adds latency.

```bash
# check NUMA node for NVMe device
cat /sys/block/nvme0n1/device/numa_node

# check NUMA node for CPU
numactl --hardware
```

---

## 6. Hands-On: Queue Depth Impact Measurement

```bash
# Baseline: measure NVMe random read at various iodepths
# Goal: find the "knee" — where latency starts rising faster than IOPS grow

for depth in 1 2 4 8 16 32 64 128; do
    fio --name=iodepth-${depth} \
        --filename=/dev/nvme0n1 \  # use a real NVMe device or file
        --rw=randread \
        --bs=4k \
        --ioengine=libaio \
        --iodepth=${depth} \
        --numjobs=1 \
        --time_based \
        --runtime=10 \
        --output-format=terse \
        | grep -E "iops|lat"
done

# Plot IOPS vs depth AND p99 latency vs depth
# The knee is your optimal queue depth for this device
```

```bash
# Compare NVMe vs virtio-blk queue topology
ls /sys/block/nvme0n1/mq/  | wc -l   # likely == nproc
ls /sys/block/vda/mq/       | wc -l   # likely 1 or few
```

---

## 7. Source Reading Checklist

Focus on these specific functions — read them in order:

```
1. blk_mq_submit_bio()          block/blk-mq.c
   — entry point, merge attempt, request alloc

2. blk_mq_get_new_requests()    block/blk-mq.c
   — prepares allocation data and supports plug request caching

3. __blk_mq_alloc_requests()    block/blk-mq.c
   — maps ctx to hctx, applies depth limits, allocates and initializes request(s)

4. blk_mq_get_tag()             block/blk-mq-tag.c
   — sbitmap_queue_get(), what blocks when tags are exhausted

5. blk_mq_dispatch_rq_list()    block/blk-mq.c
   — calls queue_rq(), handles BLK_STS_DEV_RESOURCE

6. blk_mq_end_request()         block/blk-mq.c
   — tag free, bio completion
```

---

## 8. Architect's Decision Points

| Scenario | Recommendation | Reason |
|----------|---------------|--------|
| NVMe direct-attached | `none` scheduler, depth 32–128 | device handles reordering; scheduler overhead not worth it |
| virtio-blk in VM | `none` or `mq-deadline`, depth 32 | hypervisor queues underneath; match to vhost config |
| HDD or HDD-backed cache | `mq-deadline` or `bfq` | seek reordering matters; elevator helps |
| Multi-tenant (cgroup) | `bfq` or `mq-deadline` | fairness/latency guarantees needed |
| NVMe-oF target | `none`, depth matches fabric RTT×bandwidth | fabric latency dominates; deep queue needed |

---

## 9. Self-Check Questions

1. A tag is exhausted — what happens to the next `submit_bio()` call?
2. Why does `none` scheduler outperform `mq-deadline` on NVMe?
3. On a 32-core machine with NVMe, how many `blk_mq_ctx` instances exist? How many `blk_mq_hw_ctx`?
4. What is the difference between `nr_requests` (sysfs) and `queue_depth` (tag set)?
5. Why does NUMA node misalignment affect NVMe latency?
6. At what point in the code path is a `struct request` allocated from the tag set?

## 10. Answers

1. A normal allocation waits in `blk_mq_get_tag()` until a tag becomes available. With `REQ_NOWAIT`, allocation returns `BLK_MQ_NO_TAG` and `blk_mq_submit_bio()` completes the bio with a would-block error. `BLK_STS_DEV_RESOURCE` instead describes a driver dispatch result and is handled later in the request-dispatch path.
2. NVMe has its own internal command reordering; scheduler overhead (lock, list operations) adds latency without benefit.
3. 32 `blk_mq_ctx` (one per CPU). HW queues: depends on device, often 32 for NVMe (one per CPU), but could be fewer.
4. `nr_requests` is the scheduler's staging queue limit. `queue_depth` is the maximum simultaneously in-flight requests backed by tags. On `none` scheduler they effectively converge.
5. Cross-NUMA memory access for the tag bitmap, request struct, and completion callback adds latency cycles. The completion IRQ may also fire on a CPU on the remote NUMA node, requiring cross-node wakeups for the waiter.
6. After merge attempts fail, `blk_mq_submit_bio()` uses `blk_mq_get_new_requests()` → `__blk_mq_alloc_requests()` → `blk_mq_get_tag()`. The allocator then calls `blk_mq_rq_ctx_init()` for the request represented by that tag. A request cached by the current plug is an exception because it was allocated earlier.

---

## Tomorrow: Day 3 — blk-mq Scheduler Interaction & Plug/Unplug

We go deeper on when plugging helps vs hurts, how the elevator interacts
with blk-mq dispatch, and how to use blktrace to observe merge and plug events.
