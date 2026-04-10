# Day 8: bcache Internals — Bucket GC & SSD Wear

## Learning Objectives
- Understand bcache's bucket-based allocation model in depth
- Follow the GC (garbage collection) path in `alloc.c`
- Understand how GC interacts with SSD write amplification
- Instrument GC behavior under sustained write load
- Know the conditions that cause GC pressure and how to detect them early

---

## 1. bcache's Allocation Model: Buckets

bcache divides the SSD cache device into fixed-size **buckets**
(default 512KB, configurable at `make-bcache` time).

```
SSD cache device layout:
┌──────────┬──────────┬──────────┬──────────┬──────────┐
│ bucket 0 │ bucket 1 │ bucket 2 │ bucket 3 │ bucket N │
│  512KB   │  512KB   │  512KB   │  512KB   │  512KB   │
└──────────┴──────────┴──────────┴──────────┴──────────┘

Each bucket has metadata in the bucket array (in-memory):
  struct bucket {
      uint16_t  prio;        // recency (used by LRU eviction)
      uint8_t   gen;         // generation counter (for pointer validation)
      uint8_t   last_gc;     // gen at last GC
      uint16_t  sectors_used; // how many sectors are live in this bucket
  };
```

Key concept: bcache writes **sequentially within a bucket** and never
overwrites within a bucket. When data in a bucket is invalidated (overwritten
or evicted), the bucket must be **garbage collected** before it can be reused.

This is the same fundamental model as SSD flash translation layers — bcache
implements a log-structured cache on top of the SSD's own FTL.

---

## 2. The Write Path: Bucket Allocation

```c
// drivers/md/bcache/alloc.c

// When bcache needs to write new data to SSD:
bch_bucket_alloc(ca, reserve, wait):
    // 1. Try to get a bucket from the free list
    if (!fifo_pop(&ca->free[reserve], b))
        // 2. No free buckets → must wait for GC to free some
        wait_event(ca->alloc_wait, ...)

    // Return bucket index b — caller writes sequentially into it
```

```
Bucket states (tracked in ca->buckets[]):
  FREE          — available for allocation
  DIRTY         — contains live dirty data (writeback pending to HDD)
  CLEAN         — contains live clean data (cached copy of HDD data)
  INVALIDATED   — data overwritten/evicted; bucket needs GC before reuse
  IN_USE        — currently being written to (open bucket)
```

At any time bcache has a small number of "open buckets" being written to.
When an open bucket fills, it's closed and a new one is opened.

---

## 3. The GC Path: `bch_allocator_thread`

The allocator thread runs continuously in the background:

```c
// drivers/md/bcache/alloc.c
static int bch_allocator_thread(void *arg)
{
    struct cache *ca = arg;

    while (1) {
        // 1. Move buckets from ca->free_inc to ca->free[]
        //    (free_inc = recently invalidated, not yet safe to reuse)
        while (can_invalidate_bucket(ca, ca->buckets + b)) {
            bch_invalidate_one_bucket(ca, &ca->free_inc);
        }

        // 2. If free list is low, trigger GC
        if (fifo_empty(&ca->free[RESERVE_MOVINGGC]) ||
            fifo_empty(&ca->free[RESERVE_NONE])) {
            // Wake up the GC thread
            wake_up_gc(ca->set);
            // Wait for GC to produce free buckets
            wait_event(ca->alloc_wait, ...);
        }
    }
}
```

The actual GC (`bch_gc_thread`) walks the btree to find which buckets
contain live data vs dead data:

```c
// drivers/md/bcache/btree.c (GC walk)
bch_gc_thread():
    bch_btree_gc(b->c):
        // Walk entire B-tree of cached extents
        // For each bucket: count how many sectors are still live
        // Mark buckets with 0 live sectors as reclaimable
        // Update bucket->sectors_used
```

After GC completes, buckets with `sectors_used == 0` are moved to the
free list. Buckets with partial live data may be **compacted** (moving
data to reclaim the dead space).

---

## 4. GC & SSD Write Amplification

This is the critical connection for architects:

```
Scenario: bcache SSD cache, heavy random write workload

1. Writes land in open buckets (sequential within bucket — good for SSD)
2. Data is overwritten → old copies become dead in their buckets
3. Buckets are partially full of dead data
4. GC must compact: copy live data out of half-dead buckets
5. Compaction = additional writes to SSD

Write amplification (WA) = total SSD writes / user data written
  WA = 1.0 (perfect, no GC overhead) to 3.0+ (heavy GC pressure)
```

**Factors that increase GC pressure:**

| Factor | Effect | Why |
|--------|--------|-----|
| Small bucket size | More GC overhead | More buckets to track; GC cycles more frequently |
| High write rate | Faster bucket exhaustion | Free list depletes faster than GC can refill |
| Low SSD capacity vs working set | High cache churn | Every write evicts another write → constant GC |
| Random small writes | Worst case | Many partially-dead buckets with little live data to compact |
| Writeback mode vs writethrough | Higher WA in writeback | Dirty data written twice (SSD then HDD) |

---

## 5. The bcache Btree: GC's Dependency

bcache's btree maps `(inode, offset)` → `(device, sector)` for all cached
extents. GC depends on this btree being consistent.

```
bcache btree structure:
  Root node → internal nodes → leaf nodes
  Each leaf: sorted array of bkey (cached extent records)
  bkey: { inode, offset, size, device, sector, generation }

GC walk: traverse entire btree, for each bkey:
  bucket = sector_to_bucket(bkey->ptr.offset)
  ca->buckets[bucket].sectors_used += bkey->size
```

**Btree lock contention under high queue depth:**

This is bcache's main bottleneck on fast NVMe-backed systems:
- GC holds btree node locks during the walk
- I/O path holds btree node locks for lookups
- At high IOPS, lock contention becomes the limiting factor

```bash
# Detect btree lock contention:
bpftrace -e '
kprobe:bch_btree_node_get {
    @lock_attempts[comm] = count();
}
kprobe:btree_node_unlock {
    @lock_releases[comm] = count();
}
interval:s:5 {
    print(@lock_attempts); print(@lock_releases);
    clear(@lock_attempts); clear(@lock_releases);
}'
```

---

## 6. GC Pressure Indicators

```bash
# 1. Watch free bucket count (low = GC under pressure)
watch -n1 "cat /sys/fs/bcache/*/cache/*/stats_total/cache_miss_collisions 2>/dev/null; \
           cat /sys/block/bcache*/bcache/cache/*/freelist_percent 2>/dev/null"

# 2. Indirect: cache hit rate degradation under write load
# (GC evicting useful data to free buckets)
watch -n2 "cat /sys/block/bcache0/bcache/stats_five_minute/cache_hit_ratio"

# 3. Direct GC activity via bpftrace
bpftrace -e '
kprobe:bch_gc_thread { printf("GC started: %s\n", comm); @gc_count++; }
kretprobe:bch_gc_thread { printf("GC done\n"); }
interval:s:10 { print(@gc_count); clear(@gc_count); }'

# 4. Watch SSD write amplification over time
# Compare sectors written to bcache SSD vs user data written to bcache device
# (via /proc/diskstats for both devices)
BCACHE_DEV=bcache0
SSD_DEV=nvme0n1

while true; do
    bcache_writes=$(awk "/$BCACHE_DEV / {print \$10}" /proc/diskstats)
    ssd_writes=$(awk "/$SSD_DEV / {print \$10}" /proc/diskstats)
    echo "$(date +%T) bcache_sectors=$bcache_writes ssd_sectors=$ssd_writes"
    sleep 5
done
```

---

## 7. Hands-On: Reproducing GC Pressure

```bash
# Setup: bcache device with SSD cache + HDD backing
# Goal: drive GC pressure and observe its effect on hit rate and latency

# Step 1: Fill cache to ~80% with random data
fio --name=fill --filename=/dev/bcache0 \
    --rw=randwrite --bs=4k \
    --size=80%   \  # fill 80% of SSD cache
    --ioengine=libaio --iodepth=64

# Step 2: Run sustained random write workload (causes cache churn)
fio --name=churn --filename=/dev/bcache0 \
    --rw=randwrite --bs=4k \
    --size=200%  \  # write 2x cache size → force heavy eviction/GC
    --ioengine=libaio --iodepth=64 \
    --time_based --runtime=120 &

# Step 3: Monitor in parallel
watch -n1 "
echo '=== bcache stats ==='
cat /sys/block/bcache0/bcache/stats_five_minute/cache_hit_ratio
cat /sys/block/bcache0/bcache/dirty_data
cat /sys/block/bcache0/bcache/writeback_rate_debug
echo '=== SSD wear indicator ==='
nvme smart-log /dev/nvme0n1 | grep -i 'data_units_written\|wear'
"
```

---

## 8. Tuning to Reduce GC Pressure

```bash
# 1. Bucket size: set at make-bcache time (cannot change after)
# Larger buckets = less GC overhead but more wasted space per bucket
make-bcache -C /dev/nvme0n1 --bucket-size 1024  # 1MB buckets (default 512KB)

# 2. Cache mode: writethrough reduces write amplification vs writeback
# (at cost of write performance — every write goes to HDD immediately)
echo writethrough > /sys/block/bcache0/bcache/cache_mode

# 3. Sequential cutoff: prevent large sequential writes from entering cache
# (they would fill buckets and trigger GC without being cache-useful)
echo 8388608 > /sys/block/bcache0/bcache/sequential_cutoff  # 8MB

# 4. Writeback rate: control how fast dirty data drains to HDD
# Slower writeback = more time dirty data occupies SSD buckets
# Faster writeback = more HDD write I/O but frees buckets sooner
echo 100M > /sys/block/bcache0/bcache/writeback_rate  # manual override
cat /sys/block/bcache0/bcache/writeback_rate_debug     # see auto-tuner state

# 5. Cache replacement policy
cat /sys/block/bcache0/bcache/cache/*/cache_replacement_policy
# Options: lru, fifo, random
# lru (default): evict least recently used bucket
# For databases with good temporal locality, lru is usually best
```

---

## 9. Self-Check Questions

1. What is a bcache "bucket" and why does bcache never overwrite within a bucket?
2. What triggers the `bch_allocator_thread` to wake the GC thread?
3. Explain the path from "user writes data" to "write amplification on SSD".
4. Why does bcache's btree lock contention become a bottleneck on high-queue-depth NVMe?
5. You observe bcache cache hit rate dropping under write load even though the working set fits in SSD. What is likely happening?
6. A customer has bcache with 512KB buckets and observes high SSD wear. What would you change and why?

## 10. Answers

1. A bucket is a fixed-size SSD allocation unit (default 512KB). bcache uses a log-structured approach: it writes sequentially within buckets to match SSD's preferred write pattern and to enable atomic invalidation. Overwriting within a bucket would require read-modify-write, destroying the log-structured benefit.
2. When `fifo_empty(&ca->free[])` — the free bucket list is exhausted. The allocator cannot get a free bucket for new writes, so it wakes GC to reclaim invalidated buckets.
3. User writes → land in open SSD bucket → later overwritten → old copy becomes dead in bucket → bucket is partially dead → GC must copy live data out (compaction write) → bucket freed → compaction write = write amplification.
4. GC holds btree node locks while walking the tree to count live sectors. The I/O path holds btree node locks for cache lookups. At high IOPS, many threads contend on the same btree node locks → spinlock contention dominates CPU time.
5. GC is evicting hot data to free buckets for new writes (cache churn). The working set nominally fits, but write pressure is forcing evictions faster than the working set can stabilize. Check `cache_hit_ratio` trend and `freelist_percent`.
6. Increase bucket size to 1MB or 2MB at next cache recreation. Larger buckets reduce GC frequency (fewer buckets to manage) and improve sequential write efficiency. Also check `sequential_cutoff` — large sequential writes should bypass cache to avoid thrashing.

---

## Tomorrow: Day 9 — bcache: Cache Coherency Under Failure

We analyze exactly what data is lost under each failure scenario:
cache device failure, system crash, and dirty shutdown in writeback mode.
