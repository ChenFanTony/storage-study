# Day 28: cgroup I/O — Weight, Throttle & Latency Target

## Learning Objectives
- Understand blk-cgroup's three distinct enforcement mechanisms
- Read `blk-throttle.c` and `blk-iolatency.c` at source level
- Configure `io.max`, `io.weight`, and `io.latency` and observe their behavior
- Understand how each mechanism interacts with blk-mq under saturation
- Know which mechanism to use for which isolation requirement

---

## 1. Three Distinct Mechanisms, Three Different Models

```
┌─────────────────────────────────────────────────────┐
│              cgroup v2 I/O interface                │
│                                                     │
│  io.max      → blk-throttle  → hard bandwidth limit│
│  io.weight   → bfq scheduler → proportional share  │
│  io.latency  → blk-iolatency → adaptive throttle   │
└─────────────────────────────────────────────────────┘

Key distinction:
  io.max:     enforced UNCONDITIONALLY — even when device has spare capacity
  io.weight:  enforced only under CONTENTION — proportional share
  io.latency: enforced ADAPTIVELY — throttles when latency target exceeded
```

---

## 2. io.max — Hard Bandwidth/IOPS Throttle

```c
// block/blk-throttle.c

// Per-cgroup throttle state:
struct throtl_grp {
    struct blkcg_gq         pd;         // policy data
    struct throtl_service_queue sq;     // pending I/O queue
    uint64_t                bps[2];     // bytes/sec limit [READ][WRITE]
    uint32_t                iops[2];    // I/Os/sec limit [READ][WRITE]
    // token bucket state for each limit
};

// Enforcement: token bucket
// On each bio submission:
throtl_bio_may_dispatch():
    // Check if token bucket has capacity
    if (tokens_available(tg, bio)):
        consume_token(tg, bio)
        return true  // dispatch immediately
    else:
        queue_bio(tg, bio)  // defer until next refill
        schedule_timer(tg)  // wake up when tokens refill
        return false
```

```bash
# Set io.max limits (cgroup v2)
# Format: MAJ:MIN rbps=N wbps=N riops=N wiops=N

# Limit a cgroup to 100MB/s read, 50MB/s write, 1000 IOPS read
echo "8:0 rbps=104857600 wbps=52428800 riops=1000 wiops=500" \
    > /sys/fs/cgroup/mygroup/io.max

# Check current limits
cat /sys/fs/cgroup/mygroup/io.max

# Unlimited (remove limit):
echo "8:0 rbps=max wbps=max riops=max wiops=max" \
    > /sys/fs/cgroup/mygroup/io.max

# Observe enforcement in action:
# Put a process in the cgroup:
echo $$ > /sys/fs/cgroup/mygroup/cgroup.procs

# Read test — should be capped at 100MB/s
dd if=/dev/sda of=/dev/null bs=1M count=1024 status=progress
```

**io.max characteristics:**
```
+ Simple, predictable: bandwidth is capped, period
+ Works regardless of scheduler (no BFQ needed)
+ Low overhead
- Wastes capacity: capped even when device is idle
- No feedback: doesn't adapt to device state
- Two-level hierarchy: cgroup can be further subdivided
```

---

## 3. io.weight — Proportional Scheduling

```bash
# io.weight requires BFQ scheduler on the device
echo bfq > /sys/block/sda/queue/scheduler

# Set weights (default=100, range 1-10000)
echo "8:0 200" > /sys/fs/cgroup/high_priority/io.weight   # 2× normal
echo "8:0 50"  > /sys/fs/cgroup/low_priority/io.weight    # half normal
echo "8:0 100" > /sys/fs/cgroup/normal/io.weight          # default

# Check weights
cat /sys/fs/cgroup/high_priority/io.weight
```

**io.weight characteristics:**
```
+ Efficient: unused bandwidth goes to other cgroups
+ Fair: proportional allocation under contention
- Only effective under contention (idle device: all cgroups get full bandwidth)
- Requires BFQ scheduler (adds overhead on NVMe)
- Complex to reason about: share depends on competing cgroups
- Not a hard guarantee: a cgroup might get less than expected
```

---

## 4. io.latency — Adaptive Latency-Based Throttle

This is the most sophisticated mechanism and the least understood.

```c
// block/blk-iolatency.c

// Per-cgroup iolatency state:
struct iolatency_grp {
    struct blkcg_gq         pd;
    struct rq_depth         rq_depth;   // tracks queue depth for this cgroup
    struct rq_wait          rq_wait;    // wait queue for throttled requests
    u64                     latency_target; // target latency in ns
    u64                     cur_win_ns; // current measurement window
    // windowed stats: recent average latency
};

// Enforcement logic:
blkcg_iolatency_throttle():
    // 1. Check recent average latency for this device
    avg_lat = get_avg_latency(blkg);

    if (avg_lat > latency_target):
        // Device is under pressure — throttle this cgroup
        // Reduce rq_depth (max in-flight for this cgroup)
        rq_depth_calc_max_depth(&iolatg->rq_depth);
        // If rq_depth reaches 1: further submissions must wait

    else:
        // Device has headroom — allow more in-flight
        rq_depth_inc(&iolatg->rq_depth);
```

**The adaptive model:**
```
io.latency sets a LATENCY TARGET, not a bandwidth limit:
  "This cgroup should experience < 10ms average latency"

Enforcement:
  - If device latency > target: throttle this cgroup (reduce its queue depth)
  - If device latency < target: allow more (increase queue depth)
  - System adapts dynamically to device load

Interaction with other cgroups:
  - If one cgroup causes latency > target for another cgroup:
    kernel throttles the offending cgroup
  - Protection: latency-sensitive cgroups are protected from
    bandwidth-hungry neighbors
```

```bash
# Set latency target (ns)
# "This cgroup's I/O should experience < 10ms latency"
echo "8:0 10000000" > /sys/fs/cgroup/latency_sensitive/io.latency
# 10000000 ns = 10ms

# For interactive/database workloads:
echo "8:0 1000000" > /sys/fs/cgroup/db/io.latency    # 1ms target
echo "8:0 100000"  > /sys/fs/cgroup/db_wal/io.latency # 100µs target

# For background bulk jobs (no latency target — uses default):
# Don't set io.latency, let it be adaptive

# Monitor latency enforcement
cat /sys/fs/cgroup/db/io.stat
# Shows: rbytes wbytes rios wios dbytes dios
# Watch for throttling events

# Better: bpftrace to observe throttle events
bpftrace -e '
kprobe:blkcg_iolatency_throttle {
    @throttled[comm] = count();
}
interval:s:5 {
    print(@throttled); clear(@throttled);
}'
```

---

## 5. Interaction with blk-mq Under Saturation

This is what architects miss: behavior changes when the device is saturated.

```
Device NOT saturated (plenty of headroom):
  io.max:     cgroup is throttled even though device is idle ← wasteful
  io.weight:  all cgroups get full bandwidth (no contention)
  io.latency: no throttling (latency target met easily)

Device SATURATED (at or near capacity):
  io.max:     hard limit enforced — cgroup cannot exceed configured bandwidth
              other cgroups get remaining capacity
  io.weight:  BFQ enforces proportional share — bandwidth split per weight
  io.latency: detects rising latency → throttles high-bandwidth cgroups
              to protect low-latency cgroups

Key insight: io.latency is REACTIVE (detects and responds)
             io.max is PROACTIVE (enforces regardless of state)
             io.weight is PROPORTIONAL (shares fairly under contention)
```

```bash
# Demonstrate io.latency protection under saturation:

# Setup: two cgroups, one with latency target, one doing bulk I/O
mkdir /sys/fs/cgroup/protected
mkdir /sys/fs/cgroup/bulk

# Set latency target for protected cgroup (1ms)
echo "8:0 1000000" > /sys/fs/cgroup/protected/io.latency

# Move processes to cgroups:
echo $PROTECTED_PID > /sys/fs/cgroup/protected/cgroup.procs
echo $BULK_PID      > /sys/fs/cgroup/bulk/cgroup.procs

# Run bulk I/O in bulk cgroup (should saturate device)
# Observe: protected cgroup latency stays near 1ms target
#          kernel throttles bulk cgroup to protect protected cgroup

# Monitor with iostat + bpftrace
iostat -x 1 | grep sda &
bpftrace -e '
tracepoint:block:block_rq_complete {
    @lat_us = hist((nsecs - @start[args.sector]) / 1000);
    delete(@start[args.sector]);
}
tracepoint:block:block_rq_issue {
    @start[args.sector] = nsecs;
}
interval:s:5 { print(@lat_us); clear(@lat_us); }'
```

---

## 6. Choosing the Right Mechanism

| Requirement | Mechanism | Reason |
|-------------|-----------|--------|
| Hard bandwidth cap (SLA contract) | `io.max` | Unconditional — never exceeded |
| Fair sharing between equals | `io.weight` | Proportional, efficient |
| Protect latency-sensitive workload from noisy neighbor | `io.latency` | Adaptive — throttles offenders |
| Container isolation in Kubernetes | `io.max` | Simple, predictable, no BFQ needed |
| Multi-tenant database + analytics on same server | `io.latency` (db) + `io.max` (analytics) | db protected by latency target; analytics hard-capped |
| Cost allocation / billing | `io.max` | Deterministic, auditable |

---

## 7. Hands-On: Three-Cgroup Isolation Test

```bash
# Create test cgroups
for cg in db analytics backup; do
    mkdir -p /sys/fs/cgroup/test_${cg}
done

# Device: /dev/nvme0n1 (MAJ:MIN = 259:0, check with ls -l /dev/nvme0n1)
DEV_ID=$(ls -l /dev/nvme0n1 | awk '{print $5$6}' | tr ',' ':')

# db: latency-sensitive, 1ms target
echo "$DEV_ID 1000000" > /sys/fs/cgroup/test_db/io.latency

# analytics: capped at 200MB/s
echo "$DEV_ID rbps=209715200 wbps=209715200" > /sys/fs/cgroup/test_analytics/io.max

# backup: low priority weight (needs BFQ)
echo bfq > /sys/block/nvme0n1/queue/scheduler
echo "$DEV_ID 50" > /sys/fs/cgroup/test_backup/io.weight

# Run competing workloads:
# db cgroup: random 4K reads (latency-sensitive)
cgexec -g io:test_db fio --name=db --filename=/dev/nvme0n1 \
    --rw=randread --bs=4k --ioengine=libaio --iodepth=32 \
    --time_based --runtime=60 --percentile_list=99 &

# analytics cgroup: large sequential reads (throughput)
cgexec -g io:test_analytics fio --name=analytics --filename=/dev/nvme0n1 \
    --rw=read --bs=1M --ioengine=libaio --iodepth=8 \
    --time_based --runtime=60 &

# backup cgroup: background writes
cgexec -g io:test_backup fio --name=backup --filename=/dev/nvme0n1 \
    --rw=write --bs=256k --ioengine=libaio --iodepth=4 \
    --time_based --runtime=60 &

wait
# Observe: db p99 latency, analytics throughput (capped), backup throughput (low weight)
```

---

## 8. Self-Check Questions

1. What is the fundamental difference between `io.max` and `io.latency` in how they enforce limits?
2. Why does `io.weight` only matter under contention?
3. A container running a database is experiencing high read latency because a co-located container doing backups is saturating the disk. Which mechanism would you configure and on which cgroup?
4. `io.latency` is set to 1ms for a cgroup. Device average latency is 0.5ms. Is the cgroup being throttled?
5. You need to guarantee a cgroup never uses more than 500MB/s regardless of device state. Which mechanism?
6. `io.latency` requires no specific I/O scheduler. `io.weight` does. What is that scheduler?

## 9. Answers

1. `io.max` enforces unconditionally using a token bucket — the cgroup is throttled even if the device has spare capacity. `io.latency` enforces adaptively — it only throttles when the measured device latency exceeds the configured target. When the device has headroom, `io.latency` imposes no throttling and allows full bandwidth.
2. `io.weight` implements proportional scheduling via BFQ — it divides available bandwidth in proportion to weights. When only one cgroup is doing I/O, it gets all available bandwidth regardless of weight. Weights only affect allocation when multiple cgroups compete for the same device simultaneously.
3. Set `io.latency` on the database cgroup (e.g., `echo "8:0 2000000" > db_cgroup/io.latency` for 2ms target). When the backup I/O causes device latency to exceed 2ms, the kernel throttles the backup cgroup's queue depth to reduce its I/O pressure, protecting the database's latency. Optionally also set `io.max` on the backup cgroup as a hard cap.
4. No — the device latency (0.5ms) is well below the target (1ms). `io.latency` only throttles when the latency target is exceeded. With latency at half the target, the cgroup can run at full speed.
5. `io.max` — it's unconditional. Set `rbps=524288000 wbps=524288000` for 500MB/s read and write limits. The token bucket enforces this regardless of what other cgroups are doing.
6. BFQ (Budget Fair Queuing). `io.weight` is implemented as a BFQ policy — it requires BFQ to be active on the device. `io.max` and `io.latency` are implemented in blk-throttle and blk-iolatency respectively, which sit outside the scheduler and work with any scheduler including `none`.

---

## Tomorrow: Day 29 — Full-Stack Performance Tuning Lab

We tune a real workload (PostgreSQL or RocksDB) end-to-end:
scheduler, queue depth, readahead, mount options, cgroup I/O,
and NVMe queue count. Every tuning decision documented with justification.
