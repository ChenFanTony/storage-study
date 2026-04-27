# Day 3: blk-mq — Scheduler Interaction & Plug/Unplug

## Learning Objectives
- Understand the plug/unplug mechanism and when it helps vs hurts
- Understand how I/O schedulers interact with blk-mq dispatch
- Use blktrace to observe P/U/M events and correlate with latency
- Know when to set `none` vs `mq-deadline` vs `bfq` as an architect

---

## 1. The Plug Mechanism

Plugging is a deliberate delay of dispatch — the kernel holds requests in a
per-task list (`current->plug`) and dispatches them in a batch when the plug
is released. This enables merging across multiple `submit_bio()` calls within
the same task before anything hits the HW queue.

```c
// Filesystem or caller:
struct blk_plug plug;
blk_start_plug(&plug);        // plug: hold requests in current->plug

// ... submit multiple bios ...
submit_bio(bio1);
submit_bio(bio2);
submit_bio(bio3);

blk_finish_plug(&plug);       // unplug: flush plug list to HW queue
```

What happens internally:
```
blk_start_plug()  → set current->plug, init list
submit_bio()      → blk_attempt_plug_merge() first
                    if merge fails → add to plug list (not to HW queue yet)
blk_finish_plug() → blk_flush_plug(plug, false)
                    → blk_mq_flush_plug_list()
                    → dispatch all queued requests to HW queue at once
```

**Why this helps:**
- Consecutive 4K writes to adjacent sectors → merged into single 64K request
- One HW queue doorbell instead of N separate doorbells ( a MMIO write request to notify NVME/ssd)
- Scheduler sees a batch → can sort more effectively

**Why this can hurt:**
- Adds latency for the first requests in the plug (they wait for unplug)
- For latency-sensitive paths (fsync, database commit), plug adds tail latency
- `O_SYNC` / `O_DIRECT` typically bypass plug intentionally

---

## 2. Plug Merge vs Elevator Merge

There are two merge opportunities in the blk-mq path:

```
submit_bio()
    │
    ├─► 1. Plug merge (blk_attempt_plug_merge)
    │       — merge with requests already in current->plug list
    │       — very fast: O(small constant), no lock
    │       — only works within same task's plug
    │
    └─► 2. Elevator merge (blk_mq_attempt_bio_merge)
            — merge with requests already in scheduler's red-black tree
            — requires scheduler lock (per-hctx)
            — works across tasks
            — front-merge, back-merge, or discard-merge

If neither merges → allocate new request, send to scheduler or direct dispatch
```

Front-merge: new bio appended to the *front* of an existing request (lower sector).
Back-merge: new bio appended to the *back* (higher sector) — more common.

---

## 3. I/O Scheduler Placement in blk-mq

```
submit_bio()
    → blk_mq_submit_bio()
        → merge attempt (plug / elevator)
        → blk_mq_get_request()     ← tag allocated here
        → blk_mq_bio_to_request()  ← bio → request conversion
        │
        ├── [scheduler != none]:
        │   → e->type->ops.insert_requests(hctx, &list, flags)
        │     scheduler holds request, reorders by policy
        │     scheduler calls blk_mq_dispatch_rq_list() when ready
        │
        └── [scheduler == none]:
            → directly to hctx->dispatch list
            → blk_mq_run_hw_queue() immediately
```

Schedulers operate on `struct request`, not `struct bio`. By the time a
scheduler sees a request, tag allocation has already happened — the request
is "committed" and the tag is held until completion.

---

## 4. mq-deadline: What It Guarantees

mq-deadline maintains two sorted trees (read and write) plus FIFO expiry lists.

```c
// block/mq-deadline.c
// Key parameters (tunable via sysfs):
// read_expire:  default 500ms — max age before a read gets priority
// write_expire: default 5000ms
// writes_starved: default 2 — how many read batches before writes get a turn
// front_merges: default 1 — enable front merges
```

```bash
# Tune deadline parameters
cat /sys/block/sda/queue/iosched/read_expire
cat /sys/block/sda/queue/iosched/write_expire
cat /sys/block/sda/queue/iosched/writes_starved

echo 200 > /sys/block/sda/queue/iosched/read_expire
```

**When to use mq-deadline:**
- HDDs or HDD-backed bcache (seek reordering matters)
- Mixed workloads where you need read latency guarantees
- Situations where write starvation is a concern (writes_starved tuning)

**When NOT to use:**
- NVMe with `none` scheduler: deadline overhead (red-black tree ops) costs
  more latency than any benefit from reordering

---

## 5. BFQ: Fairness Model

BFQ (Budget Fair Queueing) treats each process/group as a logical queue with
a budget of sectors, not just time slices.

```
BFQ key properties:
- I/O scheduling per-process (like CFQ but for blk-mq)
- Budget: each queue gets a budget of sectors per slice
- Interactive I/O detection: small-random processes get priority
- cgroup-aware: integrates with blk-cgroup weight
- Throughput vs fairness tradeoff: expect 10–20% throughput drop vs none
```

```bash
# BFQ tunable: slice_idle (how long to wait for a process to submit more I/O)
cat /sys/block/sda/queue/iosched/slice_idle
# 0 = no idling (good for SSDs), >0 = wait for more from same process (good for HDDs)
echo 0 > /sys/block/sda/queue/iosched/slice_idle
```

**When to use BFQ:**
- Multi-tenant environment where fairness between cgroups matters
- Desktop/interactive workloads (mouse/keyboard responsiveness during I/O)
- Systems where preventing I/O starvation of interactive processes matters

---

## 6. blktrace — Reading the Output

blktrace captures every block layer event. Understanding the action codes
is essential for diagnosing I/O behavior.

```
Action codes (most important for architect):
  Q  — queued (bio submitted to block layer)
  G  — get request (tag allocated, request created)
  M  — merge (bio merged into existing request)
  P  — plug (plug started)
  U  — unplug (plug flushed)
  I  — insert (request inserted into scheduler queue)
  D  — dispatched (sent to driver queue_rq)
  C  — completed (driver completion, interrupt handled)

RWBS field:
  R = read, W = write, D = discard, F = flush
  S = sync, M = meta, A = ahead (readahead), E = FUA
```

Latency you can derive from traces:
- **Scheduler latency:** time from `I` to `D` (how long scheduler held it)
- **Device latency:** time from `D` to `C` (how long device took)
- **Total I/O latency:** time from `Q` to `C`

---

## 7. Hands-On: blktrace Lab

```bash
# Run blktrace on your test device for 10 seconds
# (replace nvme0n1 with your device)
blktrace -d /dev/nvme0n1 -o trace &
BTRACE_PID=$!

# Generate workload
fio --name=mixed --filename=/dev/nvme0n1 --rw=randrw --bs=4k \
    --ioengine=libaio --iodepth=32 --time_based --runtime=8 &

wait
kill $BTRACE_PID 2>/dev/null

# Parse output
blkparse -i trace -o trace.txt

# Look for merge events
grep " M " trace.txt | head -20

# Look for plug/unplug cycles
grep -E " [PU] " trace.txt | head -30

# Calculate D→C latency (device service time) for first 100 completions
awk '/D / {d[$6]=$1} / C / {if($6 in d) printf "lat=%.6f\n", $1-d[$6]}' \
    trace.txt | head -100
```

```bash
# Alternative: bpftrace for real-time latency histogram
bpftrace -e '
tracepoint:block:block_rq_issue   { @start[args.sector] = nsecs; }
tracepoint:block:block_rq_complete {
    if (@start[args.sector]) {
        @us = hist((nsecs - @start[args.sector]) / 1000);
        delete(@start[args.sector]);
    }
}
interval:s:10 { print(@us); clear(@us); clear(@start); exit(); }
'
```

---

## 8. Plug Behavior in Practice

```bash
# Observe plug/unplug in blktrace output
# A healthy sequential write will show:
#   P (plug)
#   Q Q Q Q Q ... (many bios queued)
#   U (unplug)
#   M M M M ... (merges happening)
#   G (single request allocated)
#   I D C (insert, dispatch, complete)

# A random 4K workload will show:
#   Q G I D C Q G I D C ...  (no plugging, no merges — each bio becomes a request)
```

```bash
# Test: compare plug vs no-plug for sequential writes
# (journaling filesystems unplug frequently — look for U events)

# Heavy sequential write to see plug in action:
dd if=/dev/zero of=/tmp/test bs=1M count=512 &
blktrace -d /dev/sda -o - | blkparse -i - | grep -E "^.*[PUM] " | head -50
```

---

## 9. Architect's Plug/Unplug Decision Reference

| Workload | Plug Behavior | Impact |
|----------|--------------|--------|
| Sequential buffered write | Strong plug/merge | Single large request per unplug |
| Random 4K direct I/O | No plug benefit | Each bio → request, no merge |
| Journal commit (ext4/XFS) | Short plug window | Metadata bios batched before flush |
| io_uring fixed-buffer sequential | Explicit plug in io_uring | Similar to buffered, controllable |
| NVMe passthrough | No plug (bypasses blk-mq) | Driver handles coalescing directly |

---

## 10. Self-Check Questions

1. What is the difference between a plug merge and an elevator merge? Which is faster and why?
2. If you see many `M` events in blktrace but low actual throughput, what might be wrong?
3. Why does BFQ have lower throughput than `none` on NVMe?
4. A database does many small random `O_DIRECT` writes. Which scheduler and why?
5. What does the time between `D` and `C` in blktrace represent, and what affects it?
6. Why might an I/O scheduler make things *worse* on NVMe?

## 11. Answers

1. Plug merge: within the current task's plug list, O(small constant), no lock. Elevator merge: across tasks in the scheduler's sorted tree, requires hctx lock. Plug merge is faster.
2. Merging is good but something else limits throughput: maybe queue depth is too low (not enough in-flight after merge), or the merged requests are still not optimal size.
3. BFQ maintains per-process queues, tracks budgets, detects interactive I/O — all of this is CPU work and adds latency to the dispatch path.
4. `none` — O_DIRECT random writes have no spatial locality, reordering doesn't help, and you want minimum scheduler overhead.
5. Device service time — time the request spent in the hardware. Affected by: device load, internal device queue depth, flash management (for SSDs), seek/rotation (for HDDs).
6. Scheduler adds overhead (tree operations, lock contention) without benefit: NVMe has its own internal command reordering and can handle out-of-order completions natively.

---

## Tomorrow: Day 4 — Page Cache: Writeback Thresholds & Flusher Behavior

We shift to the writeback cliff: understanding `balance_dirty_pages()`,
why large `dirty_ratio` values cause latency spikes, and how to instrument
flusher thread behavior with bpftrace.
