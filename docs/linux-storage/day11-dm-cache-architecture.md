# Day 11: dm-cache — Architecture & Policy Plugins

## Learning Objectives
- Understand dm-cache's architecture: cache map, migration engine, policy interface
- Read and understand `dm-cache-target.c` and `dm-cache-policy-smq.c`
- Set up dm-cache with smq vs cleaner policy and benchmark
- Precisely compare dm-cache vs bcache on metadata overhead, failure behavior, policy flexibility

---

## 1. dm-cache Architecture Overview

Unlike bcache (which is a standalone block driver), dm-cache is a **device mapper target**.
It sits in the dm stack and can be composed with other dm targets.

```
dm-cache architecture:

┌──────────────────────────────────────────┐
│           dm-cache device                │
│  (/dev/mapper/cached)                    │
│                                          │
│  ┌────────────────┐  ┌────────────────┐  │
│  │   Cache map    │  │ Migration      │  │
│  │  (metadata)    │  │ engine         │  │
│  │                │  │                │  │
│  │ origin block → │  │ promote:       │  │
│  │ cache block    │  │  origin→cache  │  │
│  │                │  │ demote:        │  │
│  │ dirty flag     │  │  cache→origin  │  │
│  └────────┬───────┘  └───────┬────────┘  │
│           │                  │           │
│  ┌────────┴──────────────────┴────────┐  │
│  │         Policy interface           │  │
│  │  (smq / cleaner / mq)              │  │
│  │  decide: promote? demote? writeback?│  │
│  └────────────────────────────────────┘  │
└────────┬─────────────────┬───────────────┘
         │                 │
    ┌────▼────┐       ┌────▼────┐
    │  Cache  │       │ Origin  │
    │  SSD    │       │  HDD    │
    └─────────┘       └─────────┘
```

**Key difference from bcache:** dm-cache separates the **policy** (what to cache)
from the **mechanism** (how to cache). Policies are loadable kernel modules.

---

## 2. Core Data Structures in `dm-cache-target.c`

```c
// The main cache structure
struct cache {
    struct dm_target        *ti;
    struct dm_dev           *origin_dev;    // HDD
    struct dm_dev           *cache_dev;     // SSD
    struct dm_dev           *metadata_dev;  // separate metadata device (optional)

    struct dm_cache_policy  *policy;        // pluggable policy
    struct dm_cache_metadata *cmd;          // on-disk metadata manager

    dm_cblock_t             cache_size;     // number of cache blocks
    sector_t                cache_block_size; // sectors per cache block (default 64 = 32KB)

    struct workqueue_struct *wq;            // migration workqueue
    struct list_head        quiesced_migrations;
    struct list_head        completed_migrations;

    atomic_t                nr_dirty;       // dirty cache blocks count
    // ...
};

// Cache map entry (one per cache block):
// Stored in dm-cache-metadata on the metadata device
// Maps: cblock_t (cache block index) ↔ oblock_t (origin block index)
// Plus: dirty flag, hint (policy-specific data)
```

### Cache block size matters

```bash
# Default cache block size: 64 sectors = 32KB
# Configurable at dm-cache creation time

# Too small: more metadata, more migration overhead per I/O
# Too large: internal fragmentation, promotes too much unused data
# For 4K random I/O workload: 32KB–128KB is reasonable
# For large sequential: 256KB–1MB can reduce migration count

# View current cache block size
dmsetup table cached | grep -o 'block_size [0-9]*'
```

---

## 3. The Migration Engine

dm-cache's migration engine handles the actual data movement between
origin and cache devices:

```
Promotion (origin → cache):
  Triggered by: cache miss + policy says "yes, cache this"
  Steps:
    1. Allocate a cache block
    2. Read data from origin (HDD)
    3. Write data to cache (SSD)
    4. Update cache map (mark cblock as valid, not dirty)
    5. Future reads go to cache

Demotion (cache → origin):
  Triggered by: cache full + policy says "evict this"
  For CLEAN blocks: just invalidate (no write needed, origin already current)
  For DIRTY blocks:
    1. Write data from cache (SSD) to origin (HDD)
    2. Mark as clean
    3. Invalidate cache block
    4. Future I/O goes to origin

Migration concurrency:
  cat /sys/module/dm_cache/parameters/migration_throttle
  # Controls max concurrent migrations (default 512)
  # High: faster cache warmup, more migration I/O pressure
  # Low: less migration overhead, slower cache warmup
```

---

## 4. SMQ Policy Internals

SMQ (Stochastic Multiqueue) is dm-cache's default policy since kernel 4.4.

```
SMQ design:
  - Maintains "hot" and "cold" queues per (read/write) type
  - Uses probabilistic (stochastic) promotion to avoid promoting every miss
  - Tracks access frequency per origin block (with bounded memory)
  - Adaptive: adjusts promotion rate based on cache hit rate

SMQ vs bcache LRU:
  bcache: pure LRU per-bucket, no access frequency tracking
  SMQ: multi-queue with frequency estimation, better for mixed workloads

Key SMQ behaviors:
  1. Promotional throttle: not every miss is promoted
     - Avoids cache thrashing under large sequential scans (built-in protection)
     - Unlike bcache sequential_cutoff (manual), SMQ adapts automatically

  2. Dirty/clean separation: tracks which cache blocks are dirty
     - Writeback happens based on dirty count and thresholds

  3. Hints: persistent per-block policy hints survive cache restarts
     - SMQ stores hint in metadata → hot data stays hot across restarts
```

```bash
# SMQ parameters (dm-cache-policy-smq.c exposes these as dm table params)
# View current policy stats
dmsetup status cached
# Output includes: <#used_cache_blocks>/<#total_cache_blocks> <#dirty> <#features>
#                  policy_name [policy_args] <#mappings> <#promotions> <#demotions>
```

---

## 5. dm-cache vs bcache: Detailed Comparison

| Aspect | bcache | dm-cache |
|--------|--------|---------|
| Architecture | Standalone block driver | Device mapper target |
| Metadata location | On cache SSD | Separate metadata device (recommended) or on cache SSD |
| Policy | LRU (fixed) | Pluggable (smq, cleaner, mq) |
| Sequential protection | Manual `sequential_cutoff` | Automatic in SMQ (probabilistic) |
| Cache block size | Bucket size (512KB default) | Configurable (32KB default) |
| Multiple cache devices | No (1 only) | Yes (via dm-mirror under cache) |
| Writeback granularity | Per bucket | Per cache block (smaller, more precise) |
| Metadata overhead | Low (in btree on SSD) | Higher (separate metadata device recommended) |
| Btree lock contention | Yes — limits NVMe throughput | No btree; different metadata model |
| Integration with LVM | Poor (separate tool) | Native (lvmcache = LVM wrapper for dm-cache) |
| Failure recovery | Journal replay | dm-cache-metadata journal |
| Dirty data on cache failure | LOST (writeback) | LOST (writeback) — same risk |

---

## 6. Setting Up dm-cache

```bash
# Setup: NVMe SSD cache + HDD origin + small SSD for metadata

SSD=/dev/nvme0n1     # cache device
HDD=/dev/sda         # origin device
META=/dev/nvme0n2    # metadata device (small SSD, even 1GB is enough)

# Step 1: Create metadata and cache volumes with LVM (recommended)
pvcreate $SSD $META $HDD
vgcreate vg_cache $SSD $META
vgcreate vg_data $HDD

lvcreate -L 200G -n cache_data vg_cache $SSD
lvcreate -L 1G   -n cache_meta vg_cache $META

# Step 2: Create dm-cache using lvmcache
lvconvert --type cache-pool \
    --cachepool vg_cache/cache_data \
    --poolmetadata vg_cache/cache_meta \
    --cachemode writeback \
    --chunksize 64k \
    vg_data/data_lv

# Step 3: Verify
dmsetup table vg_data-data_lv
dmsetup status vg_data-data_lv
```

```bash
# Manual dm-cache setup (without LVM) for understanding internals

ORIGIN_SIZE=$(blockdev --getsz $HDD)
CACHE_SIZE=$(blockdev --getsz $SSD)
CACHE_BLOCK=128   # sectors (64KB cache block size)

# Load dm-cache and policy modules
modprobe dm-cache
modprobe dm-cache-smq

# Create cache pool
echo "0 $CACHE_SIZE cache-pool $META $SSD $CACHE_BLOCK 0 smq 0" \
    | dmsetup create cache_pool

# Create cached device
echo "0 $ORIGIN_SIZE cache /dev/mapper/cache_pool $HDD $CACHE_BLOCK 1 writeback smq 0" \
    | dmsetup create cached
```

---

## 7. Hands-On: SMQ vs Cleaner Policy Benchmark

```bash
# Benchmark 1: SMQ policy (normal caching)
lvchange --cachepolicy smq /dev/vg_data/data_lv
sleep 2

# Warm the cache
fio --name=warmup --filename=/dev/vg_data/data_lv \
    --rw=randread --bs=4k --size=20G \
    --ioengine=libaio --iodepth=32

# Measure hit rate and latency
fio --name=smq-test --filename=/dev/vg_data/data_lv \
    --rw=randread --bs=4k --size=20G \
    --ioengine=libaio --iodepth=32 \
    --time_based --runtime=60 \
    --percentile_list=50,99 &

watch -n2 "dmsetup status vg_data-data_lv | tr ' ' '\n' | head -20"
```

```bash
# Benchmark 2: Cleaner policy (cache drain — for decommissioning cache)
# Cleaner policy: demotes everything, writes back all dirty, no new promotions
lvchange --cachepolicy cleaner /dev/vg_data/data_lv

# Observe: dirty count should drop to 0 as cleaner drains the cache
watch -n1 "dmsetup status vg_data-data_lv | awk '{print \"dirty:\", \$7}'"
# When dirty=0 and no more migration activity, cache is fully drained
# Safe to remove cache device at this point
```

---

## 8. dm-cache Failure Behavior

dm-cache's failure behavior is similar to bcache but with some differences:

```bash
# Check writeback mode dirty blocks
dmsetup status cached | awk '{print "dirty blocks:", $7}'

# Simulate metadata device failure (TEST ONLY on non-production):
# If metadata device fails: dm-cache cannot update cache map
# → dm-cache falls back to bypassing cache (reads go to origin)
# → dirty writeback data: same risk as bcache — lost if cache device fails

# Clean shutdown procedure (drain before removing cache):
lvchange --cachepolicy cleaner /dev/vg_data/data_lv
# Wait for dirty=0
lvconvert --uncache /dev/vg_data/data_lv
# Cache removed, origin device now accessed directly
```

**Key difference from bcache:** dm-cache has a `cleaner` policy that
gracefully drains dirty data before decommissioning. bcache requires a manual
`writeback_percent=0` + wait approach or `stop` (which also waits).

---

## 9. Self-Check Questions

1. What is the difference between dm-cache's `cache block size` and bcache's `bucket size`?
2. How does SMQ's probabilistic promotion protect against cache thrashing from large sequential scans?
3. In dm-cache writeback mode, if the SSD cache device fails, what happens to dirty data?
4. Why is a separate metadata device recommended for dm-cache in production?
5. A customer wants to use SSD caching with LVM thin provisioning. Which would you recommend, bcache or dm-cache?
6. What is the `cleaner` policy and when would you use it?

## 10. Answers

1. dm-cache cache block size (default 32KB) is the unit of promotion/demotion — the smallest amount of data moved between origin and cache. bcache bucket size (default 512KB) is the allocation unit for cache device space. dm-cache's smaller default means less wasted promotion for small-block workloads.
2. SMQ uses stochastic (probabilistic) promotion: not every cache miss results in a promotion. For sequential scans, the miss rate is high but the probability of repeated access is low — SMQ learns this and reduces promotion rate, protecting hot data.
3. Lost — same as bcache writeback. dm-cache dirty data resides on the SSD; if the SSD fails, dirty blocks that haven't been written back to the origin (HDD) are gone.
4. If metadata is on the same SSD as cache data, a single SSD failure loses both cache data and metadata. A separate metadata device (even a small NVMe or SSD) means metadata survives cache device failure, enabling cleaner recovery.
5. dm-cache — it integrates natively with LVM as `lvmcache`. bcache and LVM are awkward to compose. dm-cache + dm-thin is a natural LVM-managed stack.
6. `cleaner` is a dm-cache policy that stops all promotions and demotes all cached blocks back to origin (writeback for dirty, discard for clean). Use it to gracefully drain the cache before removing the cache device or replacing the SSD.

---

## Tomorrow: Day 12 — dm-thin: Thin Provisioning & Metadata

We go deep on dm-thin: mapping tree, snapshot COW, and what happens
to all thin volumes when the metadata device fails.
