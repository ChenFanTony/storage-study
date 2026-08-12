# Day 5: Read-ahead — Adaptive Algorithm & Tiering Implications

<!-- study-nav -->
[← Previous: Day 4](day04-writeback-thresholds.md) | [Next: Day 6 →](day06-io-schedulers-architect.md)

## Learning Objectives
- Understand the adaptive read-ahead algorithm in `mm/readahead.c`
- Know the architectural implications of read-ahead with a cache tier (bcache/dm-cache)
- Know when read-ahead actively harms cache efficiency vs helps it
- Be able to tune read-ahead per workload and validate the decision

---

## 1. First Principle: Who Performs Read-ahead?

Linux read-ahead is primarily a **page-cache operation**, not an autonomous
feature of the generic block layer or bcache. The owner and consumer are
separate:

```text
Buffered file read
  → file/page-cache readahead (`mm/readahead.c`)
  → filesystem `->readahead()` builds bios marked `REQ_RAHEAD`
  → `/dev/bcache0` receives those bios
  → bcache decides whether to cache or bypass the prefetched data
  → backing HDD/SSD services a miss
```

The filesystem/page cache predicts future pages. bcache does not inspect an
ordinary read and independently fetch the following sectors. It sees the bios
that upper layers already generated and applies cache-admission policy.

A raw block device also has an address-space and `blkdev_readahead()` operation,
so **buffered** reads of `/dev/bcache0` can use the same page-cache machinery.
Direct I/O (`O_DIRECT`, commonly `fio --direct=1`) bypasses the page cache and
therefore bypasses this read-ahead entirely. A direct-I/O application must do
its own prefetching or asynchronous I/O.

This distinction matters because unused prefetched data can consume page-cache
memory, backing-device bandwidth, and—depending on bcache policy—SSD cache
capacity.

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

## 4. How bcache Handles Read-ahead Bios

In current bcache, `check_should_bypass()` checks `REQ_RAHEAD` and
`REQ_BACKGROUND`. The `readahead_cache_policy` setting controls admission:

- `all`: non-metadata read-ahead may populate the SSD cache.
- `meta-only`: non-metadata read-ahead bypasses the SSD; metadata read-ahead
  remains cacheable.
- `sequential_cutoff`: independently detects a long sequential stream and
  bypasses the SSD after the configured threshold.

```text
Page cache predicts and submits prefetched pages
                    ↓ REQ_RAHEAD
                  bcache
        ┌───────────┴────────────┐
        │ cache admission allowed │ → cache fill on a miss
        │ bypass policy selected  │ → backing device, no SSD fill
        └─────────────────────────┘
```

For a cold sequential scan, page-cache read-ahead can combine adjacent work and
keep an HDD busy efficiently. The demanded and prefetched pages enter the page
cache. They enter the bcache SSD only if bcache's admission and sequential
bypass policies allow it. If the data will be read again after page-cache
eviction, caching it on SSD may help; for a one-time scan, bypass is usually
preferable.

---

## 5. Read-ahead & bcache: When It Hurts

**Scenario: Random 4K read workload (OLTP database)**

The adaptive page-cache algorithm normally shrinks or stops read-ahead when
it cannot establish sequential access. It can still prefetch unused pages for
short sequential runs, interleaved streams, mmap faults, or a workload whose
pattern changes after the window grows.

Unused prefetched data always costs page-cache space and I/O bandwidth. It
pollutes the bcache SSD only when bcache admits the `REQ_RAHEAD` bios. With a
bypass-oriented readahead policy, the extra I/O can still burden the backing
HDD, but it does not displace hot SSD-cache data.

**bcache sequential cutoff:**
```bash
# bcache has a built-in protection: sequential I/O bypass
# Sequential reads ABOVE this threshold bypass the SSD cache.
# i.e. cutoff = 4MB means I/O streams longer than 4MB will bypass.
cat /sys/block/bcache0/bcache/sequential_cutoff
# default: 4MB

# This means: large sequential reads don't pollute the cache.
# But if your workload has many medium-size sequential reads SMALLER
# than the cutoff, they will still enter the cache.
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

# For a filesystem mounted on bcache0, bcache0's value supplies the
# page-cache limit. Forwarding its bios to sda does NOT run a second
# page-cache readahead pass, so sda's read_ahead_kb is not applied again.
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
# Tune the device visible to the filesystem mounted for this test
echo 0    > /sys/block/bcache0/queue/read_ahead_kb  # disable page-cache RA
echo 1024 > /sys/block/bcache0/queue/read_ahead_kb  # larger RA window

# Separately inspect bcache admission controls (names depend on kernel/bcache version)
cat /sys/block/bcache0/bcache/readahead_cache_policy
cat /sys/block/bcache0/bcache/sequential_cutoff
```

---

## 7. Hands-On: Separate Page-cache Read-ahead from bcache Admission

Use a disposable test file on a filesystem mounted on `/dev/bcache0`. Do not
run this against valuable data, and do not use `--direct=1`: direct I/O would
bypass the mechanism being tested.

```bash
# Example only: point this at a disposable file on the bcache-backed filesystem.
TEST_FILE=/mnt/bcache-test/readahead.bin

# Create the file once, then ensure its dirty data is written.
fio --name=create --filename="$TEST_FILE" --rw=write --bs=1M \
    --size=10G --ioengine=sync --direct=0
sync

# Test A: buffered sequential read with page-cache read-ahead disabled.
echo 0 > /sys/block/bcache0/queue/read_ahead_kb
echo 3 > /proc/sys/vm/drop_caches
fio --name=seq-ra0 --filename="$TEST_FILE" --rw=read --bs=128k \
    --size=10G --ioengine=sync --direct=0 --invalidate=1

# Test B: repeat with a larger page-cache readahead limit.
echo 1024 > /sys/block/bcache0/queue/read_ahead_kb
echo 3 > /proc/sys/vm/drop_caches
fio --name=seq-ra1024 --filename="$TEST_FILE" --rw=read --bs=128k \
    --size=10G --ioengine=sync --direct=0 --invalidate=1
```

Compare throughput, latency, backing-device I/O, and bcache statistics. Run
multiple alternating trials because the SSD cache is a second cache: dropping
Linux page caches does **not** clear bcache. To isolate SSD admission, compare
bcache's readahead policy and `sequential_cutoff` while keeping
`read_ahead_kb` constant.

A control run with `--direct=1` is also useful: changing `read_ahead_kb` should
not materially affect that run, because direct I/O bypasses page-cache
read-ahead. Never reset or invalidate a production cache merely for this test.

---

## 8. Read-ahead Source Code Navigation

```c
// Page-cache decision logic: mm/readahead.c

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

// Per-open-file state: include/linux/fs.h: struct file_ra_state

// Raw block-device page-cache implementation: block/fops.c
// blkdev_readahead() calls mpage_readahead() or iomap_bio_readahead()

// Sysfs limit: block/blk-sysfs.c
// queue/read_ahead_kb reads/writes disk->bdi->ra_pages

// bcache admission/bypass: drivers/md/bcache/request.c
// check_should_bypass() checks REQ_RAHEAD and readahead_cache_policy
```

---

## 9. Self-Check Questions

1. What pattern does the kernel use to detect sequential access for read-ahead?
2. Which layer originates read-ahead, and what role does bcache play?
3. What is bcache's `sequential_cutoff` and what problem does it solve?
4. Why does changing `read_ahead_kb` not tune an `O_DIRECT` database workload?
5. What is the async readahead trigger point, and why does it exist?
6. If you have a workload that does sequential reads but will NEVER re-read the data (full table scan), should read-ahead data go into the SSD cache? How would you prevent it?

## 10. Answers

1. Tracks `prev_pos` per file. If the new request is at `prev_pos + 1` (next page), it's sequential. If offset is random relative to `prev_pos`, `ra_state` resets.
2. The filesystem/page cache predicts future pages and emits `REQ_RAHEAD` bios. bcache does not originate those reads; it decides whether the resulting data should populate or bypass the SSD cache.
3. `sequential_cutoff` bypasses the SSD cache for I/O sequences longer than the threshold (default 4MB). Prevents large sequential scans from evicting random-access hot data.
4. `O_DIRECT` bypasses the page cache, so it bypasses `mm/readahead.c` and the `bdi->ra_pages` limit exposed as `read_ahead_kb`. Tune the application's own asynchronous prefetch or queue depth instead.
5. The async trigger is set at a fraction of the current window. When the app reaches that page, the next window is submitted async (no stall). It exists to overlap storage I/O with application consumption, hiding latency.
6. Keep page-cache read-ahead if it improves streaming throughput, but configure bcache to bypass non-metadata `REQ_RAHEAD` bios or use an appropriate `sequential_cutoff` so the one-time stream does not displace reusable SSD data. Page-cache retention is a separate concern; application hints such as `POSIX_FADV_DONTNEED` after consumption can release those pages.

---

## Tomorrow: Day 6 — I/O Schedulers: Architect's View

We benchmark `none` vs `mq-deadline` vs `bfq`, measure p99 latency
(not just throughput), and build a decision matrix for real workloads.
