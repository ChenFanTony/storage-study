# Working Set Size Measurement in Production

**Audience:** Storage architect / senior engineer
**Context:** How to measure the actual working set size of a running system — the prerequisite for correct cache sizing
**Related:** cache-framework-design.md §6 (Working Set Model), cache-framework-design-part2.md (sizing heuristics)

---

## Why You Need to Measure, Not Guess

The docs state the rule: cache must be sized to the working set. The working set is the set of blocks actively accessed in a time window T. But **how do you know what T seconds of access looks like in production?**

No heuristic ("OLTP = 10–20% of dataset") beats measuring the real system. A mis-sized cache either wastes money (over-provisioned) or causes thrashing (under-provisioned). The five methods below let you find the actual boundary.

---

## Method 1 — Hit Rate Curve (Most Reliable)

The working set size is the point where hit rate stops growing as cache grows.

**Principle:** Plot hit rate vs cache size. The knee of the curve is the working set boundary. Beyond it, adding cache absorbs only cold data — hit rate plateaus.

```
Hit rate
100% ─────────────────────────plateau────
 90%               ╱
 70%           ╱
 50%       ╱  ← knee ≈ working set size
 20%   ╱
  0% ──────────────────────────────────→ Cache size
```

### bcache

```bash
# Instantaneous hit rate (5-minute window)
watch -n 5 'cat /sys/block/bcache0/bcache/stats_five_minute/cache_hit_ratio'

# Cumulative counters (use for plotting over time)
cat /sys/block/bcache0/bcache/stats_total/cache_hits
cat /sys/block/bcache0/bcache/stats_total/cache_misses

# hit_rate = cache_hits / (cache_hits + cache_misses)
```

After a restart the cache is cold. Watch hit rate climb as the cache fills.
When it stops climbing → cache has absorbed the working set (or is full and still climbing → undersized).

### dm-cache

```bash
# Parse dmsetup status output
dmsetup status my-cache
# Fields: <used_metadata>/<total_metadata> <used_cache>/<total_cache>
#         <read_hits> <read_misses> <write_hits> <write_misses> ...

# Compute hit rate:
dmsetup status my-cache | awk '{
    rh=$8; rm=$9
    printf "read hit rate: %.1f%%\n", rh*100/(rh+rm)
}'
```

### RocksDB block cache

```
# From LOG or statistics output:
block_cache_hit  / (block_cache_hit + block_cache_miss) = hit rate
```

**Interpreting the result:**
- Hit rate still climbing when cache is full → cache undersized; working set > cache
- Hit rate plateaued before cache was full → cache oversized; working set < cache
- Target ≥ 90% for meaningful latency benefit (below ~80%, average latency is dominated by backing store)

---

## Method 2 — Ghost Entry Hit Rate (ARC / 2Q / W-TinyLFU)

Ghost entries track recently-evicted blocks without storing their data. A ghost hit means "this block was evicted but the application accessed it again" — direct evidence of working set overflow.

```
ghost_hit_rate = ghost_hits / (ghost_hits + real_misses)

ghost_hit_rate high  → evicted blocks are re-accessed → cache < working set
ghost_hit_rate ≈ 0   → evicted blocks never come back → cache ≥ working set
```

**ARC's `p` parameter** is an implicit working set signal: if ARC keeps shifting `p` toward T2 (frequently-accessed list), the working set is frequency-dominated and your cache covers it well. If `p` keeps shifting toward T1 (recently-accessed list) with high ghost hits, the working set is larger than the cache and the algorithm is desperately trying to keep up with recency.

### Linux page cache (simplified 2Q)

```bash
# Active pages ≈ frequently-accessed working set held in DRAM
grep "nr_active_file\|nr_inactive_file" /proc/vmstat

# If nr_active_file is near total page cache size → working set fits in DRAM
# High pgpgout (evictions) relative to pgpgin → thrashing → working set > page cache
grep "pgpgin\|pgpgout\|pgscan_kswapd\|pgsteal_kswapd" /proc/vmstat
```

High `pgscan_kswapd` and `pgsteal_kswapd` with sustained non-zero `pgpgout` → kswapd is evicting pages under memory pressure → page cache working set exceeds available DRAM.

---

## Method 3 — blktrace Block Access Analysis (Ground Truth)

Capture the raw block I/O access pattern and count unique blocks. This is ground truth for the block-layer working set.

```bash
# Capture 5 minutes of block I/O on the backing device
blktrace -d /dev/nvme0n1 -o trace -w 300

# Count unique 4K blocks accessed
blkparse -i trace -f "%S %n\n" | awk '{
    start = int($1 / 8)
    count = int($2 / 8)
    for (i = 0; i < count; i++) blocks[start + i] = 1
} END {
    print length(blocks), "unique 4K blocks"
    print length(blocks) * 4 / 1024, "MB working set"
}'
```

**Critical caveat:** if a large cache is already in front of the device, most accesses are absorbed at cache level and never reach blktrace. You are measuring the cache-miss working set, not the total working set.

**To capture the real application working set, bypass the cache:**

```bash
# Temporarily disable write-back caching on bcache
echo writethrough > /sys/block/bcache0/bcache/cache_mode

# Now trace the backing device — all reads are passed through
blktrace -d /dev/sda -o trace -w 300

# Restore
echo writeback > /sys/block/bcache0/bcache/cache_mode
```

In writethrough mode, reads are served from the SSD cache but also populate it — the backing device sees all read traffic, giving you the true access pattern.

---

## Method 4 — Backing Store IOPS Signal

The simplest production signal: watch the backing device (HDD tier) IOPS while varying cache size.

```bash
# Watch backing store utilization
iostat -x 1 /dev/sda    # or whichever is the slow tier

# Interpret:
# backing IOPS ≈ 0         → cache absorbing everything → working set fits
# backing IOPS ≈ app IOPS  → cache doing nothing → working set >> cache
# backing IOPS = 10% of app IOPS → 90% hit rate → working set roughly fits
```

**The miss-rate inflection method:**

Increase cache size incrementally (add bcache devices, grow dm-cache metadata, increase buffer pool size) and plot backing IOPS vs cache size. The point where adding more cache no longer reduces backing IOPS is the working set boundary.

```
Backing IOPS
 high ─┐
       │ \
       │  \
       │   \── inflection = working set size
       │        ──────── plateau (cold data)
  low ─┘
       └─────────────────────────────────→ Cache size
```

---

## Method 5 — Application-Level Profiling (Most Accurate)

For databases and application-layer caches, the application has exact visibility into its own access pattern.

### PostgreSQL

```sql
-- Which tables are cached in shared_buffers and how much?
SELECT relname,
       count(*) * 8192 / 1024 / 1024 AS cached_mb
FROM pg_buffercache b
JOIN pg_class c ON b.relfilenode = c.relfilenode
GROUP BY relname
ORDER BY cached_mb DESC;

-- Hit rate per table — tables with low hit_rate have working set not in cache
SELECT relname,
       heap_blks_hit,
       heap_blks_read,
       heap_blks_hit::float / nullif(heap_blks_hit + heap_blks_read, 0) AS hit_rate
FROM pg_statio_user_tables
ORDER BY heap_blks_read DESC;
```

Working set = the sum of sizes of tables with low hit_rate. If the hot tables fit in `shared_buffers`, hit rate will be high for those tables.

### RocksDB

```
# Enable statistics at open time:
options.statistics = rocksdb::CreateDBStatistics();

# Key counters:
BLOCK_CACHE_HIT        — number of block cache hits
BLOCK_CACHE_MISS       — number of block cache misses
BLOCK_CACHE_BYTES_READ — bytes served from block cache

# Working set estimate:
# total unique bytes requested = BLOCK_CACHE_BYTES_READ + bytes_read_from_SST
# working set ≈ total unique block bytes accessed in measurement window
```

### Linux page cache

```bash
# fincore: show which pages of a file are in page cache
fincore /path/to/datafile

# pcstat: page cache stats for a file
pcstat /path/to/datafile
# Output: pages in cache / total pages → portion of file in working set

# vmtouch: touch/inspect/evict page cache for a path
vmtouch -v /path/to/database/
# Shows cached pages per file — sum of cached sizes = current page cache working set
```

---

## Combining the Methods

No single method is complete. Use them together:

| What you see | What it means | Action |
|-------------|---------------|--------|
| Hit rate < 80%, backing IOPS high | Working set > cache | Grow cache |
| Ghost hit rate high | Working set > cache (ARC/2Q) | Grow cache |
| Hit rate ≥ 90%, backing IOPS ≈ 0 | Working set fits | Tune other things |
| Hit rate 90%+ but cache is only 30% full | Cache oversized | Reclaim capacity |
| blktrace unique blocks << cache size | Working set is small | Cache is oversized |
| blktrace unique blocks >> cache size | Working set is large | Cache is undersized |

---

## Practical Workflow for a New System

1. **Start with cache at 10–20% of dataset size** (OLTP heuristic from part1)
2. **Watch backing store IOPS** with `iostat -x 1` for 1–2 hours under representative load
3. **Check hit rate** via bcache/dm-cache sysfs or application stats
4. If hit rate < 85%: double cache size, repeat from step 2
5. If hit rate > 95% and cache < 50% used: halve cache size, repeat from step 2
6. **Record the inflection point** — this is your measured working set size
7. **Add 20% headroom** for working set growth (new data, schema changes, seasonal load)

---

## Key Numbers to Remember

| Signal | Meaning |
|--------|---------|
| Hit rate ≥ 90% | Cache covers working set adequately |
| Hit rate < 80% | Cache is undersized; backing store dominates average latency |
| Ghost hit rate > 10% | Meaningful working set overflow; cache should grow |
| `pgscan_kswapd` > 0 sustained | Page cache working set exceeds DRAM |
| Backing device utilization = 0% | Cache fully absorbing working set |
| Backing device utilization = app load% | Cache contributing nothing |
