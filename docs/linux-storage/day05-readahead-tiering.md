# Day 5: Read-ahead — Adaptive Algorithm & Tiering Implications

## Learning Objectives
- Understand the adaptive read-ahead algorithm in `mm/readahead.c`
- Know the architectural implications of read-ahead with a cache tier (bcache/dm-cache)
- Know when read-ahead actively harms cache efficiency vs helps it
- Be able to tune read-ahead per workload and validate the decision

---

## 1. Why Architects Need to Understand Read-ahead

Read-ahead is not just a performance knob — it directly affects cache tier
efficiency. Aggressive read-ahead on a random workload:
- fills your SSD cache with data that will never be re-read
- evicts hot data from the cache
- causes HDD thrashing for no benefit

This is one of the most common misconfigurations in tiered storage systems.

---

## 2. The Adaptive Read-ahead Algorithm

```c
// mm/readahead.c: ondemand_readahead()
// Called when: cache miss, or sequential marker triggers async prefetch
void ondemand_readahead(struct readahead_control *ractl,
                        struct folio *folio, unsigned long req_size)
{
    // State tracked per file (struct file_ra_state):
    //   ra->start     — start of current readahead window
    //   ra->size      — current window size (pages)
    //   ra->async_size — async trigger point within window

    // Sequential detection:
    //   if (offset == ra->prev_pos + 1) → sequential pattern confirmed
    //   if miss but near prev_pos → probably sequential, small window

    // Window growth (simplified):
    //   initial_ra_size = req_size or READ_AHEAD_PAGES
    //   if sequential → double window next time (up to max_pages_per_readahead)
    //   if random pattern → reset ra_state, no readahead
}
```

Key state in `struct file_ra_state`:
```c
struct file_ra_state {
    pgoff_t start;           // start of readahead window
    unsigned int size;       // current window size (pages)
    unsigned int async_size; // when to trigger next async readahead
    unsigned int ra_pages;   // per-file max (from backing device)
    unsigned int mmap_miss;  // mmap read-ahead miss counter
    loff_t prev_pos;         // -1 = invalid; tracks sequential progress
};
```

**Window growth pattern:**
```
First miss:  submit min(req_size, initial_max) pages
Sequential:  double window each miss until max_pages_per_readahead
Random:      window resets to 0 (no readahead for random access)

max_pages_per_readahead = read_ahead_kb * 1024 / PAGE_SIZE
```

---

## 3. Async vs Sync Readahead

```
Sequential read: page 0 requested
  → sync readahead: submit pages 0..N (fill initial window)
  → app reads page 0
  
App reads page N/2 (async trigger point):
  → async readahead: submit pages N+1..2N (expand window)
  → no wait — these submit in background while app reads current window

App reads page N+1: already in cache (async prefetch worked)
  → no storage I/O visible to application
```

The async trigger point (`ra->async_size`) is set so that the prefetch
completes before the app reaches those pages. If storage is slow (HDD),
you need a large window. If storage is fast (NVMe), a small window suffices.

---

## 4. Read-ahead & bcache: When It Helps

**Scenario: Cold HDD-backed bcache, sequential workload (backup, scan)**

```
Sequential read of 1GB file:
  Read-ahead submits large requests to bcache device
  bcache: SSD cache miss (cold) → passes through to HDD
  HDD: sequential read is efficient (no seek penalty)
  Data lands in SSD cache AND in page cache

  Next sequential scan of same file:
  → Page cache serves it (no storage I/O at all)
  Or if page cache evicted:
  → bcache SSD cache serves it (fast)

Result: read-ahead + tiering works well here
```

**Why it helps:**
- Sequential data that will be re-read benefits from both page cache and SSD caching
- Large read-ahead reduces HDD seek impact on cold reads
- bcache's sequential bypass (`sequential_cutoff`) can be disabled for workloads that do re-read sequential data

---

## 5. Read-ahead & bcache: When It Hurts

**Scenario: Random 4K read workload (OLTP database)**

```
Random read pattern — read-ahead algorithm detects non-sequential:
  → ra_state resets, read_ahead_kb effectively 0 for random
  → no readahead

BUT: if read_ahead_kb is forced large, or workload is pseudo-random
  with some sequential runs mixed in:
  → read-ahead fires, prefetches 256KB around each random read
  → only 4KB wanted, 252KB is waste

Waste data enters bcache:
  → evicts hot random-access data from SSD cache
  → cache hit rate drops
  → subsequent random reads miss cache → go to HDD → high latency
```

**bcache sequential cutoff:**
```bash
# bcache has a built-in protection: sequential I/O bypass
# Sequential reads above this threshold bypass the SSD cache
cat /sys/block/bcache0/bcache/sequential_cutoff
# default: 4MB

# This means: large sequential reads don't pollute the cache
# But if your workload has many medium-size sequential reads < 4MB
# they will still enter the cache
```

**dm-cache equivalent protection:**
```bash
# dm-cache SMQ policy also has sequential detection
# But it's less aggressive than bcache's explicit cutoff
```

---

## 6. Tuning read_ahead_kb for Tiered Systems

```bash
# Check current settings per device
cat /sys/block/nvme0n1/queue/read_ahead_kb   # NVMe: maybe 128KB default
cat /sys/block/sda/queue/read_ahead_kb       # HDD: maybe 128KB
cat /sys/block/bcache0/queue/read_ahead_kb   # bcache device

# The bcache device's read_ahead_kb is what the filesystem sees
# The underlying devices' settings also matter for HDD passthrough reads
```

**Decision guide:**

| Workload | Device | Recommended read_ahead_kb | Reason |
|----------|--------|--------------------------|--------|
| Pure random 4K (OLTP) | Any | 0 or 16 | No benefit; avoid cache pollution |
| Sequential scan (analytics) | HDD-backed | 1024–4096 | Hide HDD latency, batch I/O |
| Sequential scan (NVMe) | NVMe | 128–512 | NVMe is fast; huge RA wastes memory |
| Mixed (re-reads likely) | bcache | 128–256 | Balance: some RA, don't trash cache |
| streaming media | HDD | 2048+ | Large buffer needed for smooth delivery |

```bash
# Tune at runtime
echo 0    > /sys/block/bcache0/queue/read_ahead_kb   # disable for pure random
echo 1024 > /sys/block/sda/queue/read_ahead_kb       # aggressive for sequential HDD
```

---

## 7. Hands-On: Measuring Read-ahead Impact on Cache Hit Rate

```bash
# Test setup: bcache with SSD cache + HDD backing
# Measure how read_ahead_kb affects cache hit rate under random workload

# Step 1: Warm the cache with the working set
fio --name=warmup --filename=/dev/bcache0 --rw=randread --bs=4k \
    --size=10G --ioengine=libaio --iodepth=32

# Step 2: Check cache stats
cat /sys/block/bcache0/bcache/stats_day/cache_hits
cat /sys/block/bcache0/bcache/stats_day/cache_misses

# Step 3: Run random workload with default read_ahead_kb
echo 128 > /sys/block/bcache0/queue/read_ahead_kb
fio --name=randread-ra128 --filename=/dev/bcache0 --rw=randread --bs=4k \
    --size=10G --ioengine=libaio --iodepth=32 --time_based --runtime=60

cat /sys/block/bcache0/bcache/stats_hour/cache_hits
cat /sys/block/bcache0/bcache/stats_hour/cache_misses

# Step 4: Repeat with no read-ahead
echo 0 > /sys/block/bcache0/queue/read_ahead_kb
# reset bcache stats: echo 1 > /sys/block/bcache0/bcache/stats_day/reset
fio --name=randread-ra0 --filename=/dev/bcache0 --rw=randread --bs=4k \
    --size=10G --ioengine=libaio --iodepth=32 --time_based --runtime=60

# Compare hit rates — expect ra0 to have HIGHER hit rate for pure random
```

---

## 8. Read-ahead Source Code Navigation

```c
// mm/readahead.c — key functions to read

// 1. Entry point for page cache misses
void page_cache_ra_unbounded(struct readahead_control *ractl,
                              unsigned long nr_to_read,
                              unsigned long lookahead_size);

// 2. Adaptive on-demand readahead decision
static void ondemand_readahead(struct readahead_control *ractl,
                                struct folio *folio,
                                unsigned long req_size);

// 3. Called from filemap_get_pages on miss
void page_cache_async_ra(struct readahead_control *ractl,
                          struct folio *folio,
                          unsigned long req_size);

// Key struct to understand:
// include/linux/fs.h: struct file_ra_state
// — this is the per-open-file readahead state
```

---

## 9. Self-Check Questions

1. What pattern does the kernel use to detect sequential access for read-ahead?
2. Why can a high `read_ahead_kb` harm a bcache SSD cache hit rate for random workloads?
3. What is bcache's `sequential_cutoff` and what problem does it solve?
4. For a pure OLTP random-read workload on bcache, what `read_ahead_kb` would you set and why?
5. What is the async readahead trigger point, and why does it exist?
6. If you have a workload that does sequential reads but will NEVER re-read the data (full table scan), should read-ahead data go into the SSD cache? How would you prevent it?

## 10. Answers

1. Tracks `prev_pos` per file. If the new request is at `prev_pos + 1` (next page), it's sequential. If offset is random relative to `prev_pos`, `ra_state` resets.
2. Read-ahead prefetches adjacent pages around each random read. These are unlikely to be re-read, but they enter the SSD cache and evict hot random-access data.
3. `sequential_cutoff` bypasses the SSD cache for I/O sequences longer than the threshold (default 4MB). Prevents large sequential scans from evicting random-access hot data.
4. `0` or as low as possible. Random workload has no benefit from read-ahead, only cache pollution.
5. The async trigger is set at a fraction of the current window. When the app reaches that page, the next window is submitted async (no stall). It exists to overlap storage I/O with application consumption, hiding latency.
6. Raise bcache `sequential_cutoff` below your scan I/O size — sequential reads above cutoff bypass the SSD entirely. Alternatively, use `fadvise(POSIX_FADV_NOREUSE)` to hint the page cache to not retain these pages, combined with bcache sequential bypass.

---

## Tomorrow: Day 6 — I/O Schedulers: Architect's View

We benchmark `none` vs `mq-deadline` vs `bfq`, measure p99 latency
(not just throughput), and build a decision matrix for real workloads.
