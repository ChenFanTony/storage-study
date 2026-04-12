# Day 6: I/O Schedulers — Architect's View

## Learning Objectives
- Understand what each scheduler actually guarantees (not just its name)
- Measure p99 latency, not just throughput — that's what architects defend
- Build a decision matrix you can use in real design reviews
- Understand scheduler interaction with blk-mq, cgroups, and NVMe

---

## 1. The Architect's Framing

Most engineers ask: "which scheduler gives the most IOPS?"
Architects ask: "which scheduler gives acceptable p99 latency under mixed load,
with cgroup isolation, without starving any workload?"

The answer changes completely depending on:
- Device type (NVMe vs HDD vs bcache composite)
- Workload mix (sequential vs random, read vs write)
- Tenancy model (single workload vs multi-tenant cgroups)
- Latency SLA (50ms acceptable vs 5ms required)

---

## 2. Scheduler Internals Summary

### `none` (noop)
```
Mechanism: bypass scheduler entirely, direct dispatch to HW queue
Merge: plug merges only (no elevator merges)
Reorder: none
Fairness: none (first-come, first-served at CPU level)
Overhead: minimal
Best for: NVMe, ZNS devices, any device with own command reordering
```

### `mq-deadline`
```
Mechanism: two sorted red-black trees (read, write) + FIFO expire queues
Guarantee: no request waits longer than {read,write}_expire ms
Fairness: reads preferred (writes_starved knob)
Overhead: tree operations per insert/dispatch (~microseconds)
Best for: HDD, mixed read/write where read latency matters
Tuning knobs:
  read_expire (default 500ms)
  write_expire (default 5000ms)
  writes_starved (default 2 — write batch every 2 read batches)
  front_merges (default 1)
```

### `bfq`
```
Mechanism: per-process/cgroup virtual time slices + sector budgets
Guarantee: proportional I/O bandwidth per cgroup/weight
Fairness: explicit per-process and per-cgroup fairness
Overhead: significant — per-request classification, interactive detection
Throughput: ~10-20% lower than none on NVMe, similar on HDD
Best for: multi-tenant, desktop, anywhere cgroup I/O isolation needed
Tuning knobs:
  slice_idle (default 8ms on HDD, 0 on SSD)
  low_latency (default 1 — boosts interactive processes)
```

### `kyber`
```
Mechanism: token bucket per latency domain (read/sync_write/other)
Guarantee: latency target per domain (tunable)
Overhead: low (simpler than bfq)
Best for: fast NVMe where you want latency targets, not fairness
```

---

## 3. What p99 Actually Tells You

Average latency hides the problem. p99 exposes it:

```
mq-deadline on NVMe, random 4K reads, single process:
  avg: 0.12ms    p50: 0.10ms    p99: 0.45ms    p99.9: 2.1ms

none on NVMe, same workload:
  avg: 0.11ms    p50: 0.09ms    p99: 0.18ms    p99.9: 0.32ms

→ avg is similar, but p99 is 2.5x worse with mq-deadline
→ the scheduler's tree operations add tail latency
```

```
bfq on HDD, two competing workloads:
  Without bfq (none):
    Process A (sequential): 120 MB/s
    Process B (random):       2 MB/s  ← starved

  With bfq:
    Process A: 80 MB/s
    Process B: 15 MB/s  ← fairly scheduled
    Total: 95 MB/s (lower, but fair)
```

---

## 4. Hands-On: Scheduler Benchmark

```bash
# Switch schedulers at runtime
echo none         > /sys/block/nvme0n1/queue/scheduler
echo mq-deadline  > /sys/block/nvme0n1/queue/scheduler
echo bfq          > /sys/block/nvme0n1/queue/scheduler

# Verify
cat /sys/block/nvme0n1/queue/scheduler
```

```bash
# Benchmark: p99 latency comparison
# Run this for each scheduler setting

DEVICE=/dev/nvme0n1  # adjust to your device

for sched in none mq-deadline bfq; do
    echo $sched > /sys/block/nvme0n1/queue/scheduler
    sleep 0.5

    echo "=== scheduler: $sched ==="
    fio --name=lat-test-${sched} \
        --filename=${DEVICE} \
        --rw=randread \
        --bs=4k \
        --ioengine=libaio \
        --iodepth=32 \
        --numjobs=4 \
        --time_based \
        --runtime=30 \
        --group_reporting \
        --percentile_list=50,90,95,99,99.9
done
```

```bash
# Mixed workload test: simulate competing sequential + random
# This shows where bfq fairness matters vs mq-deadline starvation

for sched in none mq-deadline bfq; do
    echo $sched > /sys/block/sda/queue/scheduler  # use HDD for this test

    echo "=== scheduler: $sched ==="
    # Job 1: sequential read (background scan)
    fio --name=seq-${sched} \
        --filename=/tmp/test1.img \
        --rw=read --bs=256k \
        --ioengine=psync \
        --time_based --runtime=30 &

    # Job 2: random read (interactive)
    fio --name=rand-${sched} \
        --filename=/tmp/test2.img \
        --rw=randread --bs=4k \
        --ioengine=libaio --iodepth=8 \
        --time_based --runtime=30 \
        --percentile_list=99

    wait
done
```

---

## 5. Scheduler + cgroup Interaction

This is the area most architects miss. Scheduler choice affects cgroup
I/O isolation effectiveness:

```
bfq + cgroup v2 io.weight:
  → bfq respects per-cgroup weights
  → I/O bandwidth proportional to weight setting
  → isolation works well

none/mq-deadline + cgroup v2 io.latency:
  → io.latency uses blk-iolatency for enforcement
  → doesn't require bfq
  → throttles cgroups that exceed latency target
  → works on NVMe (where bfq is overkill)

none/mq-deadline + cgroup v2 io.max:
  → hard bandwidth throttle
  → works regardless of scheduler
  → lowest overhead approach
```

```bash
# Check cgroup I/O capabilities for your scheduler
cat /sys/block/nvme0n1/queue/scheduler   # if "none"

# io.max works regardless of scheduler
# io.latency works regardless of scheduler (uses blk-iolatency)
# io.weight requires bfq OR is best-effort only

# Set up a test:
mkdir /sys/fs/cgroup/test-cgroup
echo "nvme0n1 rbps=52428800 wbps=52428800" > /sys/fs/cgroup/test-cgroup/io.max
# 50MB/s read+write limit, enforced by blk-throttle regardless of scheduler
```

---

## 6. Architect's Decision Matrix

| Device | Workload | Tenancy | Recommendation |
|--------|----------|---------|----------------|
| NVMe local | single-process | single | `none` |
| NVMe local | multi-process, latency-SLA | single | `none` + `io.latency` |
| NVMe local | multi-tenant containers | multi | `none` + `io.max` or `io.latency` |
| NVMe-oF | any | any | `none` (fabric adds latency; don't add scheduler) |
| bcache (SSD cache) | mixed | any | `none` on SSD; `mq-deadline` on HDD backing |
| HDD raw | sequential-heavy | single | `mq-deadline` (reduces seeks) |
| HDD raw | mixed random/sequential | multi | `bfq` (prevents starvation) |
| HDD in RAID | database | multi | `mq-deadline` (deadline guarantees) |

---

## 7. How Schedulers Interact with bcache

bcache exposes two levels of scheduling opportunity:

```
Application I/O
  → bcache device scheduler (set on /sys/block/bcache0/queue/scheduler)
      → cache hit: → SSD (use none/mq-deadline on SSD)
      → cache miss: → HDD (use mq-deadline on HDD)

You can tune independently:
echo none        > /sys/block/nvme0n1/queue/scheduler  # SSD: none
echo mq-deadline > /sys/block/sda/queue/scheduler      # HDD: deadline
echo none        > /sys/block/bcache0/queue/scheduler  # bcache composite: none
```

For the bcache composite device, `none` is usually correct — bcache's
own I/O routing logic handles the SSD/HDD decision. Don't add scheduler
overhead on top of bcache's already complex request routing.

---

## 8. Self-Check Questions

1. Why is p99 latency a better metric than average latency when evaluating schedulers?
2. On NVMe, `mq-deadline` adds overhead without much benefit. What specifically is that overhead?
3. You have a multi-tenant system with containers. You want to ensure no container can dominate I/O. Which scheduler + cgroup mechanism would you use and why?
4. bcache composite device — which scheduler on the bcache device, which on the SSD, which on the HDD?
5. A database on HDD reports occasional 2-second read latencies. The device `await` is 2s periodically. Scheduler is `none`. What would you try and why?
6. What is the difference between `io.max`, `io.weight`, and `io.latency` in cgroup v2?

## 9. Answers

1. Averages are dominated by fast common cases, hiding the tail. p99 reveals the worst 1% of requests — what users actually experience as "slowness".
2. Red-black tree insert/lookup per request, per-hctx lock contention, expire-list scanning. On NVMe doing 1M+ IOPS, these CPU cycles add up to measurable latency.
3. `none` scheduler + `io.max` (hard bandwidth caps) for guaranteed isolation. Or `none` + `io.latency` for adaptive latency-based throttling. BFQ is another option but adds scheduler overhead to NVMe.
4. bcache device: `none`. SSD: `none`. HDD: `mq-deadline` (or `bfq` if multiple processes compete for HDD bandwidth).
5. Switch to `mq-deadline` — HDD with `none` has no seek reordering, so requests are dispatched in arrival order regardless of sector locality. `mq-deadline` will sort by sector proximity while still bounding maximum latency.
6. `io.max`: hard bandwidth/IOPS throttle, enforced unconditionally. `io.weight`: proportional scheduling weight (best with bfq). `io.latency`: adaptive — throttles cgroups if they cause the device's average latency to exceed the target (uses blk-iolatency).

---

## Tomorrow: Day 7 — Week 1 Review: Architect Decision Points

We synthesize the week: write your personal decision matrix for queue depth,
scheduler choice, and writeback tuning. Goal: be able to defend any
storage configuration choice under technical cross-examination.
