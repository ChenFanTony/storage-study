# Day 28: cgroup I/O — Weight, Throttle & Latency Target

## Learning Objectives
- Understand the three cgroup v2 I/O enforcement mechanisms and their distinct kernel paths
- Know precisely what `io.max`, `io.weight`, and `io.latency` do and don't guarantee
- Know which I/O scheduler each requires (`io.weight` ↔ BFQ; others independent)
- Choose the right mechanism for noisy-neighbor isolation, fairness, and latency SLOs
- Recognize which features bypass cgroup enforcement (the io_uring passthrough gap)

---

## 1. Three Distinct Mechanisms, Three Source Files

Cgroup I/O is not one feature. It's three independent mechanisms, each
enforcing a different policy through a different kernel path:

```
io.max     →  block/blk-throttle.c
              Hard upper limit, unconditional throttle
              "This cgroup gets at most N MB/s, period."

io.weight  →  BFQ scheduler (block/bfq-iosched.c)
              Proportional sharing, only under contention
              "When competing, A gets 2× the bandwidth of B."

io.latency →  block/blk-iolatency.c
              Adaptive throttling based on observed latency
              "If this cgroup's I/O latency exceeds 1 ms, slow down others."
```

These are independent. You can use any combination, but understand which
problem each solves and which kernel code is enforcing it.

---

## 2. io.max — Hard Throttle (block/blk-throttle.c)

```
Behavior:
  Token bucket per cgroup per device per direction (read/write).
  Tokens refill at the configured rate.
  Every bio consumes tokens.
  If insufficient tokens: bio is QUEUED in the throttle group until refill.
  
Enforcement:
  Unconditional — applies whether the device is idle or saturated.
  This is a HARD CAP, not a fair-share.
```

```c
// block/blk-throttle.c

struct throtl_grp {
    // Configured limits (bytes/sec, iops)
    u64 bps[2];                    // [READ, WRITE] bps limits
    unsigned int iops[2];          // [READ, WRITE] iops limits
    
    // Token bucket state
    u64 bytes_disp[2];             // bytes dispatched in current slice
    unsigned int io_disp[2];       // ios dispatched in current slice
    unsigned long slice_start[2];  // current slice start jiffies
    unsigned long slice_end[2];    // current slice end jiffies
    
    // Queued bios waiting for tokens
    struct bio_list queued[2];
    // ...
};

// On bio submission:
blk_throtl_bio():
    if (tg_may_dispatch(tg, bio, &wait)) {
        // Enough tokens: consume them, allow bio to proceed
        throtl_charge_bio(tg, bio);
        return BLK_THROTL_PASS;
    } else {
        // Not enough tokens: queue the bio, schedule wake-up after `wait` jiffies
        throtl_add_bio_tg(bio, tg);
        return BLK_THROTL_QUEUED;
    }
```

```bash
# Configure io.max for a cgroup (cgroup v2, mounted at /sys/fs/cgroup)

# Find the major:minor for the target block device
ls -la /dev/nvme0n1
# brw-rw---- 1 root disk 259, 0 ...   ← major=259, minor=0

# Create a cgroup
mkdir /sys/fs/cgroup/myservice

# Set io.max: 100 MB/s read, 50 MB/s write, 10K read iops, 5K write iops
echo "259:0 rbps=104857600 wbps=52428800 riops=10000 wiops=5000" \
    > /sys/fs/cgroup/myservice/io.max

# Verify
cat /sys/fs/cgroup/myservice/io.max
# 259:0 rbps=104857600 wbps=52428800 riops=10000 wiops=5000

# Move a process in
echo $$ > /sys/fs/cgroup/myservice/cgroup.procs
# Now this shell and its children are subject to io.max

# Use "max" to remove a specific limit
echo "259:0 rbps=max wbps=52428800 riops=max wiops=5000" \
    > /sys/fs/cgroup/myservice/io.max
```

**When to use `io.max`:**
- Multi-tenant systems with strict per-tenant SLAs ("tenant X gets 100 MB/s")
- Limiting a runaway batch job ("don't let backup consume the disk")
- Predictable resource accounting for billing/chargeback

**The downside:** waste. If `io.max=100 MB/s` and the device is otherwise
idle (could deliver 3 GB/s), the cgroup is still capped at 100 MB/s.
This is the right choice when predictability matters more than utilization.

---

## 3. io.weight — Proportional Fair Share (BFQ)

```
Behavior:
  Proportional weight (1-10000, default 100).
  Under contention, bandwidth is allocated in proportion to weights.
  If only one cgroup is active: it gets all bandwidth (no waste).
  
Enforcement: ONLY through the BFQ scheduler.
  Other schedulers (none, mq-deadline, kyber) IGNORE io.weight.
  This is a configuration-time decision per block device.
```

```c
// block/bfq-iosched.c — BFQ scheduler

// BFQ maintains per-cgroup queues with weighted fair queuing.
// Each request submitter gets a queue; the scheduler dispatches from
// queues in proportion to their cgroup's io.weight.

struct bfq_group {
    struct bfq_entity entity;  // scheduling entity with weight
    // ... queues, stats ...
};

bfq_select_queue():
    // Pick the next queue to dispatch from, based on:
    //   - virtual time (B-WF2Q+ scheduling)
    //   - queue weight (derived from cgroup io.weight)
    // Higher weight = more frequent dispatch turns
```

```bash
# REQUIRED: select BFQ scheduler on the device
echo bfq > /sys/block/sda/queue/scheduler

# Verify
cat /sys/block/sda/queue/scheduler
# [bfq] mq-deadline kyber none
# (square brackets indicate active)

# Set io.weight
echo "100" > /sys/fs/cgroup/cg-a/io.weight    # default = 100
echo "200" > /sys/fs/cgroup/cg-b/io.weight    # 2× cg-a

# Per-device weight (overrides global io.weight for that device)
echo "default 100" > /sys/fs/cgroup/cg-a/io.weight
echo "259:0 50"    >> /sys/fs/cgroup/cg-a/io.weight
```

**The BFQ requirement is the catch.**
BFQ is typically used on rotational disks and slower SATA SSDs.
On modern NVMe, BFQ adds latency overhead (per-request scheduling
decisions) — `none` is preferred for raw performance. So `io.weight`
is most often used in:
- Mixed workloads where fairness matters more than maximum throughput
- HDD-backed storage
- Multi-tenant SATA SSD arrays where fairness > peak IOPS

For NVMe deployments where peak IOPS matter, you typically pick `none`
and use `io.latency` (Section 4) or `io.max` instead.

```bash
# Confirm the scheduler/weight tradeoff: what BFQ costs on NVMe
echo none > /sys/block/nvme0n1/queue/scheduler
fio --name=baseline --filename=/dev/nvme0n1 --rw=randread --bs=4k \
    --ioengine=io_uring --iodepth=32 --direct=1 --runtime=30 --time_based

echo bfq > /sys/block/nvme0n1/queue/scheduler
fio --name=bfq --filename=/dev/nvme0n1 --rw=randread --bs=4k \
    --ioengine=io_uring --iodepth=32 --direct=1 --runtime=30 --time_based

# Typical result: BFQ reduces NVMe peak IOPS by 30-60%
# Acceptable if fairness across cgroups is the goal.
```

---

## 4. io.latency — Adaptive Latency Target (block/blk-iolatency.c)

The newest and most sophisticated mechanism:

```
Behavior:
  Set a per-cgroup latency target (in nanoseconds).
  Kernel measures observed read I/O latency for the cgroup over a window.
  If observed latency exceeds target → throttle OTHER cgroups (lower priority).
  
Enforcement:
  Adaptive — throttling kicks in only when the protected cgroup misses target.
  Adjusts request queue depths of other cgroups dynamically.
```

```c
// block/blk-iolatency.c

struct iolatency_grp {
    struct rq_depth rq_depth;          // adjusted depth limit for this group
    u64 min_lat_nsec;                  // latency target
    struct latency_stat cur_stat;      // current window latency stats
    struct latency_stat last_stat;
    // ...
};

// Once per measurement window:
iolatency_check_latencies():
    // Measure: observed latency in current window
    // If observed > target:
    //   Reduce rq_depth.max_depth of LOWER-priority groups
    //   → those groups can have fewer in-flight requests
    //   → less I/O traffic from them
    //   → protected group gets back under its target
    // If observed << target:
    //   Gradually relax throttling
```

```bash
# Set a 1 ms latency target for the critical cgroup (1ms = 1,000,000 ns)
echo "259:0 target=1000000" > /sys/fs/cgroup/critical/io.latency

# (No target needed for cgroups that should yield)
# Default is no target — kernel doesn't protect them

# Verify
cat /sys/fs/cgroup/critical/io.latency
# 259:0 target=1000000

# Monitor effectiveness via io.stat
cat /sys/fs/cgroup/critical/io.stat
# 259:0 rbytes=... wbytes=... rios=... wios=...
#       dbytes=...   ← bytes throttled by io.max
#       (io.latency contribution shown in tracepoints, not io.stat directly)
```

**io.latency vs io.max:**

```
io.max:      "ensure this cgroup never exceeds 100 MB/s"
             Wasteful when device is idle.

io.latency:  "ensure this cgroup's reads complete in under 1 ms"
             Lets cgroup use 100% of device if no contention.
             Only throttles others when contention causes latency to spike.
```

For latency-sensitive workloads (databases, online serving), `io.latency`
is usually the right answer because it preserves performance when there's
no contention.

---

## 5. The io_uring Passthrough Gap

This is the production gotcha you need to know about (from Day 25):

```
io.max, io.weight, io.latency all enforce in the BLOCK LAYER (blk-mq).

io_uring's IORING_OP_URING_CMD against /dev/ng* BYPASSES blk-mq.
  → cgroup I/O limits are NOT applied to NVMe-passthrough I/O.
  → A process in a "limited" cgroup can saturate the device via uring_cmd.

Implication:
  If your isolation strategy depends on cgroup I/O limits,
  do NOT allow tenants to use io_uring passthrough.
  This is a real exfiltration path for I/O capacity.
  
  Either:
    - Disable /dev/ng* access (chmod, namespaces)
    - Use containers that can't open /dev/ng* (cgroup device controller)
    - Don't rely on cgroup I/O for isolation against adversarial workloads
```

---

## 6. Practical Decision Guide

| Goal | Use | Reasoning |
|------|-----|-----------|
| Hard cap per tenant (SLA) | `io.max` | Predictable, simple, enforced unconditionally |
| Latency SLO for a critical service | `io.latency` | Adaptive — no waste when no contention |
| Fair sharing across services (HDD) | `io.weight` + BFQ | Proportional fairness; BFQ overhead OK on HDD |
| Fair sharing across services (NVMe) | `io.latency` | BFQ kills NVMe perf; latency-target gives effective sharing |
| Prevent backup from impacting OLTP | `io.latency` on OLTP + `io.max` on backup | Latency target protects OLTP; hard cap on backup |
| Multi-tenant container host | `io.max` per tenant | Enforces tenant SLAs; combine with QoS classes |

---

## 7. Hands-On: Observe All Three in Action

```bash
# Setup: a test device. Use /dev/nullb0 from null_blk for a deterministic device.
modprobe null_blk gb=8 nr_devices=1
DEV=/dev/nullb0
MAJMIN=$(stat -c '%t:%T' $DEV | awk -F: '{printf "%d:%d", strtonum("0x"$1), strtonum("0x"$2)}')

# Confirm cgroup v2 is mounted
mount | grep cgroup2

# Make two cgroups
mkdir -p /sys/fs/cgroup/cg-fast /sys/fs/cgroup/cg-slow

# Experiment 1: io.max — hard cap
echo "$MAJMIN rbps=10485760" > /sys/fs/cgroup/cg-slow/io.max   # 10 MB/s

(
  echo $$ > /sys/fs/cgroup/cg-slow/cgroup.procs
  fio --name=throttled --filename=$DEV --rw=read --bs=1M \
      --ioengine=libaio --iodepth=4 --direct=1 \
      --time_based --runtime=10 --status-interval=1 2>&1 | grep BW
)
# BW should be ~10 MB/s regardless of device capability

# Experiment 2: io.weight (requires BFQ — only if /dev/nullb0 supports it)
# Most null_blk setups don't expose a real scheduler; this works better on real devices
# Skip if no BFQ-capable device

# Experiment 3: io.latency
echo "$MAJMIN target=500000" > /sys/fs/cgroup/cg-fast/io.latency   # 0.5 ms target
# Start a noisy workload in cg-slow (without io.max this time)
echo "$MAJMIN rbps=max" > /sys/fs/cgroup/cg-slow/io.max
(
  echo $$ > /sys/fs/cgroup/cg-slow/cgroup.procs
  fio --name=noisy --filename=$DEV --rw=randread --bs=4k \
      --ioengine=libaio --iodepth=128 --direct=1 \
      --time_based --runtime=20 &
) &

# Meanwhile in cg-fast (protected)
(
  echo $$ > /sys/fs/cgroup/cg-fast/cgroup.procs
  fio --name=protected --filename=$DEV --rw=randread --bs=4k \
      --ioengine=libaio --iodepth=4 --direct=1 \
      --time_based --runtime=15
)
# cg-fast latency should stay near target; cg-slow gets throttled adaptively

# Cleanup
rmdir /sys/fs/cgroup/cg-fast /sys/fs/cgroup/cg-slow
modprobe -r null_blk
```

---

## 8. Observability for cgroup I/O

```bash
# Per-cgroup I/O stats
cat /sys/fs/cgroup/myservice/io.stat
# 259:0 rbytes=15728640 wbytes=4194304 rios=100 wios=50 dbytes=0 dios=0
# dbytes/dios = bytes/ios delayed by io.max throttle

# Pressure information (PSI) — how much time spent stalled on I/O
cat /sys/fs/cgroup/myservice/io.pressure
# some avg10=12.34 avg60=8.91 avg300=4.56 total=...
# full avg10=2.45 avg60=1.78 avg300=0.92 total=...
#
# "some" = at least one task stalled on I/O
# "full" = ALL tasks stalled on I/O
# Numbers are percentages over the window

# Live monitor pressure
watch -n1 'cat /sys/fs/cgroup/myservice/io.pressure'

# Trace throttle events with bpftrace
bpftrace -e '
kprobe:throtl_charge_bio { @charges = count(); }
kprobe:throtl_add_bio_tg { @queues = count(); }
interval:s:5 { print(@charges); print(@queues); clear(@charges); clear(@queues); }
'
# Ratio of queues to charges = fraction of I/Os throttled
```

---

## 9. Source Reading Checklist

```
block/blk-throttle.c          — io.max enforcement (token bucket)
block/blk-iolatency.c         — io.latency adaptive throttling
block/bfq-iosched.c           — BFQ scheduler (enforces io.weight)
block/bfq-cgroup.c            — BFQ cgroup integration
block/blk-cgroup.c            — common cgroup-blk infrastructure
block/blk-cgroup-rwstat.h     — rwstat counters per cgroup
include/linux/blk-cgroup.h    — blkcg structures

kernel/cgroup/cgroup.c        — cgroup v2 core (not specific to I/O)
```

Reading order: `blk-cgroup.c` (the shared infrastructure: `blkcg`,
`blkg`), then `blk-throttle.c` (simplest: token bucket). After that,
`blk-iolatency.c` (more sophisticated: latency measurement + adaptive
depth control). BFQ is the largest body of code; read it only if you
need to deeply understand `io.weight` or BFQ specifically.

---

## 10. Self-Check Questions

1. You set `io.weight=200` on a cgroup but observe no behavioral change. What's the most likely cause?
2. Distinguish what `io.max`, `io.weight`, and `io.latency` enforce in one sentence each.
3. On a fast NVMe shared across services, you want to protect a critical database from noisy neighbors but don't want to cap maximum throughput when there's no contention. Which mechanism, and why not the others?
4. A tenant in a cgroup with `io.max rbps=100M` runs an io_uring program that drives 2 GB/s of NVMe reads. How is this possible?
5. What does `cat /sys/fs/cgroup/X/io.pressure` tell you, and how is "some" different from "full"?
6. You set `io.latency target=500000` on cgroup A and run heavy I/O in cgroup B. What does the kernel adjust to enforce A's target?
7. Why does `io.weight` (and BFQ) typically reduce maximum NVMe IOPS by 30%+ compared to scheduler `none`?

## 11. Answers

1. The block device's I/O scheduler is not BFQ. `io.weight` is enforced exclusively by BFQ; on `none`, `mq-deadline`, or `kyber` schedulers, the value is silently ignored. Check `cat /sys/block/DEVICE/queue/scheduler` — if `[bfq]` is not active, weights have no effect. Switch with `echo bfq > /sys/block/DEVICE/queue/scheduler` (and be aware of the IOPS cost on fast NVMe).
2. `io.max`: hard cap — never exceed N (bytes/sec or iops). `io.weight`: proportional share when contending — A's weight ÷ sum(weights) = A's share. `io.latency`: adaptive — throttle others to keep this cgroup's observed I/O latency under target.
3. `io.latency`. It throttles OTHER cgroups only when the protected cgroup's observed latency rises above target. When there's no contention, the database gets full device performance (no waste). `io.max` would waste capacity by capping unconditionally. `io.weight` would help under contention but requires BFQ, which cuts NVMe peak IOPS by 30%+ — paying a permanent penalty for protection that's only sometimes needed.
4. io_uring `IORING_OP_URING_CMD` against `/dev/ng*` (NVMe character device) bypasses blk-mq entirely. The bios that would be subject to `io.max` aren't created — instead, the io_uring path goes directly to the NVMe driver's ioctl handler. Cgroup I/O enforcement happens in the block layer and isn't applied to passthrough commands. Mitigation: deny tenants access to `/dev/ng*` via cgroup device controller, namespace, or chmod, depending on the deployment model.
5. PSI (Pressure Stall Information). It reports the percentage of time tasks in the cgroup were blocked on I/O over the last 10s/60s/300s windows. "some" = at least one task was waiting on I/O (some pressure). "full" = ALL runnable tasks were waiting on I/O (the cgroup is making no progress). Rising "full" indicates serious I/O contention; rising "some" with stable "full" indicates contention without complete stalls.
6. The kernel reduces the maximum in-flight request depth (`rq_depth.max_depth` in `struct iolatency_grp`) for cgroups OTHER than A — particularly cgroup B — so they have fewer concurrent I/Os queued at the device. With less concurrent traffic from B, A's measured I/O latency drops back below 500 µs. The kernel adjusts these depths dynamically over time, relaxing throttle when A is meeting target and tightening it when not.
7. BFQ makes a per-request scheduling decision based on B-WF2Q+ (Worst-case Fair Weighted Fair Queuing): pick the next queue based on virtual finish time and weight. Each decision is microseconds of CPU work, plus lock acquisition and tree updates. On a slow device this overhead is dominated by I/O latency itself. On fast NVMe (IOPS in millions), the per-request scheduling time becomes the limiting factor — the CPU can't make scheduling decisions fast enough to keep the device fed. Scheduler `none` skips this entirely, dispatching requests as they arrive.

---

## End of Week 4: What You Should Now Be Able to Defend

Week 4 covered the modern I/O stack at source level:

- **Day 22 — NVMe driver**: queue pair model, submission/completion paths in `drivers/nvme/host/pci.c`, multi-namespace management, passthrough.
- **Day 23 — NVMe-oF architecture**: transport comparison, queue allocation over a fabric, discovery, when to recommend each transport.
- **Day 24 — NVMe-oF failure handling + O_DIRECT**: reconnect behavior, ANA multipathing, the precise kernel O_DIRECT path and what it eliminates.
- **Day 25 — io_uring**: SQ/CQ ring mechanics, fixed buffers, registered files, SQPOLL, NVMe passthrough via `uring_cmd`.
- **Day 26 — ZNS**: zone model, write pointer, zone append, why bcache/dm-cache can't use ZNS, software stack.
- **Day 27 — Persistent memory / DAX**: the byte-addressable model, what DAX bypasses (page cache AND block layer), durability via clwb/sfence.
- **Day 28 — cgroup I/O**: three enforcement mechanisms, three source files, three different use cases, and the io_uring passthrough gap.

Decisions you can now defend:
- "Use io_uring + fixed buffers for our 600K-IOPS service, but stay on the standard block path because we depend on cgroup I/O limits for tenant isolation."
- "Pmem for the WAL — synchronous durability at 500ns vs NVMe at 50µs is a step-change. Bulk data stays on NVMe."
- "NVMe-oF/TCP for our disaggregated storage tier — TCP latency is acceptable and operational complexity is much lower than RDMA."
- "ZNS doesn't fit our PostgreSQL workload; dm-zoned would erase the benefit. Save ZNS for the RocksDB tier with ZenFS."

---

## Tomorrow: Day 29 — Full-Stack Performance Tuning Lab

We integrate everything from Weeks 1-4 into a single full-stack scenario:
diagnose and tune a real performance problem from application through
filesystem, block layer, device driver, and hardware. The lab tests
whether you can move fluently between layers — the architect's actual job.
