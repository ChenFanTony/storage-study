# Day 10: bcache — Limitations & Where It Breaks Down

## Learning Objectives
- Understand bcache's specific failure modes under real workloads
- Reproduce btree lock contention at high queue depth
- Observe cache thrashing under mixed sequential/random workloads
- Know when to recommend alternatives (dm-cache, application-level tiering)
- Leave with a clear "bcache is wrong for this" checklist

---

## 1. Limitation 1: Btree Lock Contention on Fast NVMe

As covered in Day 8, bcache's single btree with coarse locking becomes the
bottleneck when the SSD is fast enough to expose it.

### The contention model

```
I/O path (every cache lookup):
  bch_btree_node_get() → spin on btree node lock
  → lookup key in btree → release lock

GC path (periodically):
  bch_btree_gc() → holds btree node lock during walk
  → counts live sectors per bucket → releases lock

Writeback path:
  bch_btree_insert() → spin on btree node lock
  → update key (dirty → clean) → release lock

With NVMe at 500K+ IOPS:
  - 500K lock acquisitions/second per CPU
  - GC holds lock for ms-duration walks
  - Spinlock contention → CPUs burning cycles in spin loops
  - Throughput plateaus well below device capability
```

### Detection

```bash
# Method 1: perf to find spinlock hotspots
perf top -e cycles -p $(pgrep -x kworker) 2>/dev/null &
# Look for bcache btree functions consuming high CPU

# Method 2: bpftrace lock contention measurement
bpftrace -e '
kprobe:bch_btree_node_get {
    @start[tid] = nsecs;
}
kretprobe:bch_btree_node_get {
    if (@start[tid]) {
        @lock_wait_us = hist((nsecs - @start[tid]) / 1000);
        delete(@start[tid]);
    }
}
interval:s:10 { print(@lock_wait_us); exit(); }'

# Method 3: compare bcache IOPS vs raw SSD IOPS
# If raw SSD achieves 500K IOPS but bcache achieves only 150K → contention
fio --name=raw    --filename=/dev/nvme0n1 --rw=randread --bs=4k \
    --ioengine=libaio --iodepth=32 --time_based --runtime=30 &
fio --name=bcache --filename=/dev/bcache0 --rw=randread --bs=4k \
    --ioengine=libaio --iodepth=32 --time_based --runtime=30
# Ratio below 50% = severe btree contention
```

### Workarounds (limited)

```bash
# 1. Reduce queue depth (less contention but lower throughput)
# 2. Use writethrough (fewer btree writes)
# 3. Accept the limit — bcache was designed for SSD-accelerating-HDD,
#    not NVMe-on-NVMe scenarios
```

**Architect verdict:** If your SSD cache is NVMe-class (>200K IOPS) and your
workload is high-concurrency random I/O, bcache will be the bottleneck.
Use dm-cache or application-level caching instead.

---

## 2. Limitation 2: Sequential Scan Cache Thrashing

### The thrashing mechanism

```
Scenario: hot OLTP working set (20GB) in SSD cache
          background analytics job runs sequential scan of 100GB dataset

Sequential scan behavior:
  - Scan reads pages sequentially: page 0, 1, 2, ... (100GB)
  - Each page enters bcache (if below sequential_cutoff or cutoff not set)
  - Scan evicts hot OLTP data from SSD cache
  - After scan: OLTP cache hit rate drops from 95% to 20%
  - OLTP latency spikes from 0.5ms to 50ms (hitting HDD)
```

### Detection

```bash
# Watch hit rate before, during, and after a large sequential read
watch -n1 "echo 'Hit rate:'; \
    cat /sys/block/bcache0/bcache/stats_five_minute/cache_hit_ratio; \
    echo 'Dirty data:'; \
    cat /sys/block/bcache0/bcache/dirty_data"

# In another terminal, simulate the scan:
dd if=/dev/bcache0 of=/dev/null bs=1M count=100000  # 100GB sequential read
```

### Fix: sequential_cutoff tuning

```bash
# Check current cutoff
cat /sys/block/bcache0/bcache/sequential_cutoff
# Default: 4194304 (4MB)

# Increase to protect cache from large sequential reads
# Any I/O sequence longer than this bypasses SSD cache
echo 33554432 > /sys/block/bcache0/bcache/sequential_cutoff  # 32MB

# For analytics workloads that ONLY do large scans, consider:
echo writearound > /sys/block/bcache0/bcache/cache_mode
# writearound: reads served from HDD, cache not polluted
```

### When sequential_cutoff isn't enough

The problem: sequential_cutoff uses a per-request heuristic. If the analytics
job does 1MB reads (below cutoff), they all enter the cache.

```bash
# Check what I/O sizes the analytics job uses:
bpftrace -e '
tracepoint:block:block_rq_issue {
    @sizes_kb[comm] = hist(args.nr_sector / 2);
}
interval:s:10 { print(@sizes_kb); clear(@sizes_kb); }'

# If analytics I/O is consistently below sequential_cutoff,
# you need a different approach: cgroup io.max throttle on the
# analytics job, or a separate bcache device for analytics
```

---

## 3. Limitation 3: ZNS Incompatibility

Zoned Namespace (ZNS) NVMe devices require sequential writes within each zone.
bcache's write model conflicts with this:

```
bcache write pattern:
  - Opens buckets and writes sequentially within each bucket: OK for ZNS
  - BUT: GC compaction requires reading from one zone + writing to another
  - AND: btree updates scatter writes across SSD address space
  - These out-of-zone writes violate ZNS constraints

Result: bcache cannot be used directly on a ZNS device as the cache device.
```

If you need tiered caching with ZNS:
- Use dm-cache with a zone-aware target (future work as of kernel 6.x)
- Use application-level caching (RocksDB's tiered compaction, etc.)
- Use a small conventional NVMe namespace for bcache, ZNS for main storage

---

## 4. Limitation 4: No TRIM/Discard Propagation

```bash
# bcache does not propagate discard/TRIM to the SSD cache device
# when backing device blocks are freed (file deletion, etc.)

# Consequence: SSD fills up with "stale" cache entries for deleted data
# GC will eventually reclaim these, but:
#   - SSD sees higher utilization than necessary
#   - More GC pressure

# Workaround: periodic cache invalidation
echo 1 > /sys/block/bcache0/bcache/invalidate  # flush entire cache
# (heavy operation — use during maintenance windows only)

# Check if your kernel version has improved discard handling:
grep -i discard /sys/block/bcache0/bcache/cache/*/stats_total/* 2>/dev/null
```

---

## 5. Limitation 5: Single Cache Device

bcache supports only one SSD cache device per cache set. You cannot:
- Mirror the SSD cache for redundancy
- Stripe across multiple SSDs for more bandwidth
- Replace a failed SSD without losing all dirty data

```bash
# Verify: cache set shows only one cache device
ls /sys/fs/bcache/*/cache/
# You'll see cache0 only, never cache1

# For redundant cache: use dm-raid1 on two SSDs, then bcache on top
# OR: use dm-cache which supports multiple cache devices via dm-mirror
```

---

## 6. When to Recommend Alternatives

### Use dm-cache instead of bcache when:

| Condition | Reason |
|-----------|--------|
| NVMe-class SSD cache (>200K IOPS needed) | btree contention caps bcache throughput |
| Need cache device redundancy | bcache supports only 1 cache device |
| Need fine-grained cache policy control | dm-cache has pluggable policies (smq, cleaner) |
| Mixed workload with many large sequential I/Os | dm-cache SMQ handles this better |
| Integration with LVM thin provisioning | dm-cache is native to device mapper stack |

### Use application-level caching instead when:

| Condition | Reason |
|-----------|--------|
| Application knows access patterns (database) | App-level cache is far more efficient |
| Need ZNS compatibility | Block-level caching incompatible with ZNS |
| Sub-millisecond latency required | Block-layer caching adds overhead; io_uring + NVMe direct is faster |
| Working set > SSD capacity | Block-level cache has no semantic advantage over app cache |

### Keep bcache when:

| Condition | Reason |
|-----------|--------|
| HDD backing + SSD cache (classic use case) | bcache was designed for this; works well |
| Moderate IOPS (<150K) | Below btree contention threshold |
| Simple setup needed | bcache has simpler ops model than dm-cache |
| Writeback acceptable + SSD is reliable | Best write performance for HDD-backed tier |

---

## 7. Hands-On: Reproduce Cache Thrashing

```bash
# Step 1: Warm the cache with random data (simulates OLTP working set)
fio --name=warmup --filename=/dev/bcache0 \
    --rw=randread --bs=4k --size=16G \
    --ioengine=libaio --iodepth=32

echo "Warmed. Hit rate:"
cat /sys/block/bcache0/bcache/stats_five_minute/cache_hit_ratio

# Step 2: Run OLTP simulation (small random reads)
fio --name=oltp --filename=/dev/bcache0 \
    --rw=randread --bs=4k --size=16G \
    --ioengine=libaio --iodepth=32 \
    --time_based --runtime=300 &
OLTP_PID=$!

echo "OLTP running. Hit rate before scan:"
sleep 10 && cat /sys/block/bcache0/bcache/stats_five_minute/cache_hit_ratio

# Step 3: Start sequential scan (analytics job thrashing the cache)
fio --name=scan --filename=/dev/bcache0 \
    --rw=read --bs=1M --size=100%  \
    --ioengine=psync &

echo "Scan started. Hit rate during scan:"
for i in $(seq 1 6); do
    sleep 10
    cat /sys/block/bcache0/bcache/stats_five_minute/cache_hit_ratio
done

# Observe hit rate drop during scan

# Step 4: Repeat with sequential_cutoff protection
kill $OLTP_PID
echo 67108864 > /sys/block/bcache0/bcache/sequential_cutoff  # 64MB
# Re-warm and repeat — hit rate should be protected
```

---

## 8. Self-Check Questions

1. At approximately what IOPS level does bcache btree lock contention become the bottleneck?
2. Why doesn't simply increasing queue depth solve the btree contention problem?
3. A customer has bcache with sequential_cutoff=4MB. Their analytics job does 512KB reads. Are they protected from cache thrashing?
4. Why can't bcache be used on a ZNS NVMe device as the cache?
5. You need a tiered caching solution where the SSD cache must survive any single device failure. Can bcache do this? What would you use instead?
6. An application developer says "I want to use bcache to accelerate my database." What questions would you ask before recommending for or against?

## 9. Answers

1. Typically ~150–200K IOPS is where btree lock contention becomes visible. Above ~300K IOPS on NVMe, bcache is rarely the right choice.
2. More in-flight requests = more concurrent btree lock acquisitions = more contention. Increasing queue depth makes contention worse, not better.
3. No — 512KB reads are below the 4MB cutoff, so they enter the SSD cache and will evict hot OLTP data. Need to raise cutoff to at least 1MB (and ideally match or exceed their read I/O size).
4. ZNS requires sequential writes within each zone. bcache's btree updates and GC compaction scatter writes across the SSD address space, violating zone write constraints.
5. bcache cannot — it supports only one SSD cache device, no mirroring. Use dm-cache on top of a dm-raid1 mirror of two SSDs, or use a hardware RAID controller for the SSD layer.
6. Key questions: (1) What is the database's working set size vs SSD cache size? (2) Does the DB use O_DIRECT or buffered I/O? (3) What IOPS does the workload require? (4) What are the durability requirements (can we afford dirty data loss on SSD failure)? (5) Are there large sequential scans mixed with random I/O? These answers determine whether bcache is appropriate or dm-cache/app-level caching is better.

---

## Tomorrow: Day 11 — dm-cache: Architecture & Policy Plugins

We move to dm-cache: its migration engine, the SMQ policy internals,
and how it compares to bcache in failure behavior and policy flexibility.
