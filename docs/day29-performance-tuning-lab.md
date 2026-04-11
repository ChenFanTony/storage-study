# Day 29: Full-Stack Performance Tuning Lab

## Objective
Integrate everything from Weeks 1–4 into a complete, documented tuning
exercise on a real workload. Every decision must be justified at the
architecture level — not "I read it was good", but "because X causes Y
which limits Z".

Choose ONE workload from: PostgreSQL, RocksDB, or mixed container workload.
This document covers all three with a common methodology.

---

## 1. Tuning Methodology

```
Step 1: Baseline measurement
  - Measure before ANY changes
  - Record: throughput, p50/p99/p99.9 latency, CPU%, iowait%
  - Use: fio (storage), pgbench/db-bench (application), iostat, bpftrace

Step 2: Identify bottleneck
  - Is it CPU-bound? → tuning storage won't help
  - Is it I/O latency? → queue depth, scheduler
  - Is it I/O throughput? → bandwidth, queue depth
  - Is it writeback cliff? → dirty_ratio
  - Is it lock contention? → per-stack investigation

Step 3: One change at a time
  - Change one parameter, measure, record delta
  - Multiple simultaneous changes: cannot attribute improvement

Step 4: Document every decision
  - What changed, why, measured result
  - This is the deliverable — the justification matters as much as the number
```

---

## 2. Workload A: PostgreSQL OLTP

### Environment
```
Hardware: 2× NVMe (local), 32 cores, 128GB RAM
PostgreSQL 15, single primary, no replicas
Workload: pgbench (TPC-B like), 100 clients, 60 seconds
Metric: TPS (transactions per second) + p99 latency
```

### Baseline
```bash
# pgbench setup
createdb pgbench
pgbench -i -s 100 pgbench    # scale factor 100 = ~1.4GB dataset

# Baseline run (all defaults)
pgbench -c 100 -j 8 -T 60 pgbench
# Record: tps, latency average, latency stddev
```

### Tuning Layer 1: NVMe Scheduler
```bash
# Baseline: what scheduler is active?
cat /sys/block/nvme0n1/queue/scheduler
# Expected default: none (correct for NVMe)
# If mq-deadline: switch to none and remeasure

echo none > /sys/block/nvme0n1/queue/scheduler
# Justification: PostgreSQL does random 8KB I/O (data pages) and
# sequential WAL writes. NVMe has its own reordering; mq-deadline
# adds tree overhead without benefit. p99 latency improves ~10-15%.
```

### Tuning Layer 2: Queue Depth
```bash
# Find optimal queue depth for this workload
cat /sys/block/nvme0n1/queue/nr_requests   # current depth

# PostgreSQL generates I/O from multiple backend processes
# Each backend: typically 1-2 in-flight at a time
# 100 clients × 2 in-flight = 200 potential concurrent requests
# But NVMe saturates at 32-64; deeper queues add latency

# Benchmark queue depth impact:
for depth in 16 32 64 128 256; do
    echo $depth > /sys/block/nvme0n1/queue/nr_requests
    pgbench -c 100 -j 8 -T 30 pgbench | grep tps
done
# Find the knee: highest TPS with acceptable p99
```

### Tuning Layer 3: WAL Filesystem
```bash
# PostgreSQL WAL: sequential writes, fsync on commit
# XFS external log on dedicated NVMe eliminates log I/O vs data I/O contention

# Move WAL to second NVMe:
# (Requires rebuilding cluster — do this at setup time ideally)
# In postgresql.conf:
# wal_level = replica
# synchronous_commit = on     # must be on for durability
# wal_buffers = 64MB          # default 4MB is often too small
# checkpoint_completion_target = 0.9

# Mount WAL volume with XFS, no atime, external log:
mkfs.xfs -l logdev=/dev/nvme1n1p1 /dev/nvme1n1p2
mount -o noatime,logbufs=8 /dev/nvme1n1p2 /var/lib/postgresql/data/pg_wal

# Justification: WAL is append-only sequential writes with frequent fsync.
# Separating WAL to dedicated NVMe eliminates interference with random
# data page I/O on the primary NVMe. Measured: 15-25% TPS improvement.
```

### Tuning Layer 4: Writeback for Shared Buffers
```bash
# PostgreSQL shared_buffers = 32GB (25% of RAM)
# Data files use O_DIRECT → bypass page cache → dirty_ratio irrelevant
# WAL uses buffered I/O → subject to writeback cliff

# Tune for WAL buffered writes:
sysctl -w vm.dirty_background_bytes=67108864   # 64MB: start flushing early
sysctl -w vm.dirty_bytes=134217728             # 128MB: throttle threshold

# Justification: WAL writes are bursty (commit storms). Small dirty_bytes
# prevents cliff events. Absolute bytes (not ratio) prevents scaling issue
# on 128GB RAM (20% = 25GB dirty = massive cliff).
```

### Tuning Layer 5: cgroup I/O Isolation
```bash
# If PostgreSQL shares hardware with other workloads:
# Protect PostgreSQL WAL latency from background jobs

echo "259:0 2000000" > /sys/fs/cgroup/postgresql/io.latency   # 2ms target
echo "259:0 rbps=104857600 wbps=104857600" \
    > /sys/fs/cgroup/backup_jobs/io.max    # 100MB/s cap on backup

# Justification: PostgreSQL commit latency (WAL fsync) directly impacts TPS.
# io.latency adaptively throttles competing cgroups when they cause latency
# to exceed 2ms, protecting commit latency without wasting capacity.
```

### Final Documentation Template
```
Tuning Log: PostgreSQL on NVMe
Date: 2026-04-XX

Baseline: 4,230 TPS, p99=45ms

Change 1: scheduler=none on nvme0n1, nvme1n1
  Before: 4,230 TPS, p99=45ms
  After:  4,510 TPS, p99=38ms
  Reason: eliminated mq-deadline tree overhead; NVMe does own reordering

Change 2: WAL moved to dedicated NVMe (nvme1n1)
  Before: 4,510 TPS, p99=38ms
  After:  5,340 TPS, p99=28ms
  Reason: WAL sequential writes no longer compete with data random reads

Change 3: dirty_bytes=128MB (was 20% RAM = 25GB)
  Before: 5,340 TPS, p99=28ms (occasional p99 spikes to 800ms)
  After:  5,340 TPS, p99=28ms (no spikes)
  Reason: eliminated writeback cliff on WAL writes; consistent p99

Change 4: io.latency=2ms on postgresql cgroup
  Before: 5,340 TPS (degrades to 2,100 when backup runs)
  After:  5,210 TPS (stable even when backup runs)
  Reason: adaptive throttle protects WAL latency during backup I/O

Total improvement: 4,230 → 5,210 TPS (+23%), p99 45ms → 28ms (-38%)
```

---

## 3. Workload B: RocksDB (LSM-tree database)

### Key Characteristics
```
RocksDB I/O pattern:
  - Compaction: large sequential reads + writes (background)
  - Point reads: small random reads (foreground)
  - WAL writes: sequential append + fsync
  
  Compaction dominates I/O bandwidth but is background
  Point reads are latency-sensitive (user-facing)
```

### Tuning Priorities for RocksDB
```bash
# 1. Scheduler: none (NVMe) — same reasoning as PostgreSQL
echo none > /sys/block/nvme0n1/queue/scheduler

# 2. Queue depth: higher for RocksDB (more concurrent compaction I/O)
echo 128 > /sys/block/nvme0n1/queue/nr_requests
# Compaction: 4-8 concurrent jobs × 16 in-flight each = 64-128 concurrent

# 3. Separate compaction and foreground I/O with cgroups:
echo "259:0 1000000" > /sys/fs/cgroup/rocksdb_fg/io.latency  # 1ms for reads
echo "259:0 rbps=524288000" > /sys/fs/cgroup/rocksdb_bg/io.max  # 500MB/s compaction cap
# Put foreground threads in fg cgroup, compaction threads in bg cgroup

# 4. Read-ahead: disable for random reads, keep for compaction sequential
echo 0    > /sys/block/nvme0n1/queue/read_ahead_kb  # disable globally
# RocksDB manages its own read-ahead for compaction (db_options.compaction_readahead_size)

# 5. For ZNS-capable NVMe: use ZenFS plugin
# ZenFS maps compaction output to sequential zones → eliminates FTL WA
# Each compaction level → dedicated zone group
# Zone reset on level expiry → clean reclaim without FTL GC
```

---

## 4. Workload C: Mixed Container Workload

### Scenario
```
4 containers on 1 server, 1× NVMe:
  Container A: PostgreSQL (latency-sensitive)
  Container B: Elasticsearch (throughput-sensitive, indexing)
  Container C: Backup job (background, bulk)
  Container D: Log aggregation (moderate)
```

### cgroup I/O Configuration
```bash
DEV="259:0"   # adjust to your NVMe MAJ:MIN

# A: PostgreSQL — protect latency (2ms target)
echo "$DEV 2000000" > /sys/fs/cgroup/container_a/io.latency

# B: Elasticsearch — cap throughput (300MB/s max, no latency target)
echo "$DEV rbps=314572800 wbps=314572800" > /sys/fs/cgroup/container_b/io.max

# C: Backup — hard cap at 100MB/s (must not interfere)
echo "$DEV rbps=104857600 wbps=104857600" > /sys/fs/cgroup/container_c/io.max

# D: Log aggregation — low weight (gets what's left)
echo bfq > /sys/block/nvme0n1/queue/scheduler
echo "$DEV 50" > /sys/fs/cgroup/container_d/io.weight

# Verify with bpftrace per-cgroup latency tracking
bpftrace -e '
tracepoint:block:block_rq_issue { @s[args.sector, cgroup] = nsecs; }
tracepoint:block:block_rq_complete {
    $k = (args.sector, cgroup);
    @lat_by_cg[cgroup] = hist((nsecs - @s[$k]) / 1000);
    delete(@s[$k]);
}
interval:s:30 { print(@lat_by_cg); clear(@lat_by_cg); }'
```

---

## 5. Universal Tuning Checklist

Before declaring tuning complete, verify each item:

```bash
# 1. Correct scheduler
for dev in /sys/block/nvme*/queue/scheduler; do
    echo "$dev: $(cat $dev)"
done
# NVMe: should show [none]
# HDD: should show [mq-deadline] or [bfq] depending on workload

# 2. Queue depth sanity
for dev in /sys/block/nvme*/queue/nr_requests; do
    echo "$dev: $(cat $dev)"
done
# NVMe: 32-128 typically; find knee with fio sweep

# 3. Writeback thresholds
sysctl vm.dirty_background_bytes vm.dirty_bytes
# Should be absolute bytes, not ratios, for predictable behavior

# 4. Read-ahead per workload
for dev in /sys/block/*/queue/read_ahead_kb; do
    echo "$dev: $(cat $dev)"
done
# Random workload: 0 or 16; Sequential: 1024+

# 5. cgroup I/O coverage
# Every production workload should be in a cgroup with at least one policy
cat /sys/fs/cgroup/*/io.max 2>/dev/null | grep -v "^$"
cat /sys/fs/cgroup/*/io.latency 2>/dev/null | grep -v "^$"

# 6. NUMA alignment for NVMe
for dev in /sys/block/nvme*/device/numa_node; do
    echo "$dev: $(cat $dev)"
done
# Should match the NUMA node of the CPUs running the workload

# 7. Validate with sustained load
fio --name=validate \
    --filename=/dev/nvme0n1 \
    --rw=randrw --rwmixread=70 \
    --bs=8k \
    --ioengine=libaio \
    --iodepth=32 \
    --time_based --runtime=300 \   # 5 minutes — long enough to hit writeback
    --percentile_list=50,99,99.9
```

---

## 6. Self-Check: Can You Justify Every Parameter?

For each tuning decision in your configuration, write one sentence:
"I set X to Y because Z causes W."

Example:
- "I set `scheduler=none` because mq-deadline's red-black tree operations add microseconds of latency per request without benefit on NVMe, which handles its own command reordering internally."
- "I set `dirty_bytes=128MB` because at 256GB RAM, `dirty_ratio=20%` would allow 51GB of dirty pages before throttling, creating massive writeback cliff events under PostgreSQL's WAL write bursts."

If you cannot write that sentence for a parameter, you don't understand it
well enough to defend it — go back and re-read the relevant day.

---

## Tomorrow: Day 30 — Final Review & Storage Architecture Roadmap

Produce your complete storage stack architecture diagram, write your
"Storage Architecture Decision Guide", and identify your next 30 days.
