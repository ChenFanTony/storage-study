# Day 5: Page Cache (Read Path Fundamentals)

## Learning Objectives
- Understand the role of page cache in Linux file I/O
- Follow the buffered read path in `mm/filemap.c`
- Understand cache hit vs cache miss behavior
- Connect page cache misses to readahead and block I/O
- Observe cache behavior from userspace with practical tools

---

## 1. What the Page Cache Does

The page cache is the in-memory cache for file data.

When an application reads a file:
- If requested data is already cached, kernel can serve it from memory (fast path)
- If not cached, kernel fetches data from storage, inserts it into cache, then returns it

This is why repeated reads are often much faster than first reads.

---

## 2. Where It Lives in the I/O Path

High-level buffered read path:

```text
read()
  -> vfs_read()
    -> filesystem read_iter (e.g. ext4/xfs)
      -> generic file read path
        -> filemap_read()               [mm/filemap.c]
          -> filemap_get_pages()        [cache lookup/fill]
            -> cache hit: copy to user
            -> cache miss: trigger readahead/read_folio
```

Core file to study today:
- `mm/filemap.c`

Related files:
- `mm/readahead.c`
- `include/linux/fs.h` (`address_space`)

---

## 3. Core Objects and Terms

### `address_space`
Per-inode page cache mapping (`inode->i_mapping`).

It contains:
- cached folios/pages (xarray)
- operations table (`a_ops`)
- accounting and mapping metadata

### Folio/Page
A folio is the modern abstraction for cached file-backed memory chunks (often page-sized, sometimes larger).

### Cache hit
Requested file offset already has a resident, valid folio in cache.

### Cache miss
Data not present or not uptodate; kernel must fetch from backing storage.

---

## 4. `filemap_read()` Read-Path Behavior

Conceptually, `filemap_read()` does:
1. Determine target file offset range
2. Lookup needed folios from page cache
3. If missing, invoke readahead / filesystem read callbacks
4. Wait for folios to become uptodate when needed
5. Copy data to user iterator
6. Advance file position and return bytes read

Important: page cache handling is designed to support both:
- sequential reads (benefit from readahead)
- random reads (less predictable prefetch)

---

## 5. Cache Hit vs Miss: What Changes

### Cache hit path
- no storage access required for those bytes
- low latency, CPU/memory-copy dominated
- often limited by memcpy + userspace consumption speed

### Cache miss path
- storage I/O required
- can trigger synchronous wait for data readiness
- may perform readahead to prefetch adjacent data

This difference is the core reason benchmark methodology must account for warm vs cold cache state.

---

## 6. Readahead Interaction

On miss (or sequential pattern detection), kernel may call readahead logic:
- detect access pattern
- submit additional nearby pages
- hide future I/O latency

Readahead logic primarily lives in:
- `mm/readahead.c`

Read path and readahead are tightly coupled for throughput on sequential workloads.

---

## 7. Write Side (Preview-Level)

Writes in buffered mode typically:
- update page cache first
- mark folios/pages dirty
- defer persistence to writeback

So page cache is not only read optimization—it is also the staging area for buffered writes.

(Writeback details are covered more deeply in Day 7.)

---

## 8. Practical Observability

Useful system indicators:
- `/proc/meminfo`: `Cached`, `Dirty`, `Writeback`
- `/proc/vmstat`: many cache/writeback counters
- `vmtouch`: inspect file residency in cache

Remember:
- global cache metrics are system-wide, not per-process
- other workloads can distort your test interpretation

---

## 9. Hands-On Exercises

### Exercise 1: Watch cache-related memory stats
```bash
grep -E '^(Cached|Dirty|Writeback):' /proc/meminfo
watch -n1 "grep -E '^(Cached|Dirty|Writeback):' /proc/meminfo"
```

### Exercise 2: Warm-cache effect with repeated reads
```bash
# first pass (colder)
time cat /usr/bin/python3 > /dev/null

# second pass (warmer)
time cat /usr/bin/python3 > /dev/null
```

### Exercise 3: Sequential read with fio and readahead tuning
```bash
# inspect current setting (choose your test block device)
cat /sys/block/sda/queue/read_ahead_kb

# simple sequential read test
fio --name=seqread --filename=/tmp/pagecache-test --size=256M --rw=read --bs=128k --ioengine=psync --direct=0
```

### Exercise 4: Inspect file residency with vmtouch
```bash
# install if needed, then:
vmtouch /usr/bin/python3
vmtouch -v /usr/bin/python3
```

### Exercise 5: Correlate misses and readahead code study
```bash
# kernel source reading checklist:
# 1) mm/filemap.c: filemap_read(), filemap_get_pages() style flow
# 2) mm/readahead.c: ondemand_readahead() style logic
# 3) filesystem a_ops read path (e.g., ext4)
```

---

## 10. Source Navigation Checklist

Primary:
- `mm/filemap.c`
- `mm/readahead.c`

Supporting:
- `include/linux/fs.h` (`struct address_space`, `address_space_operations`)
- `fs/ext4/` or `fs/xfs/` read-side integration files

---

## 11. Common Pitfalls

1. Assuming every `read()` reaches storage
   - many reads are fully served from memory

2. Comparing benchmark runs without controlling cache state
   - warm vs cold cache can dominate results

3. Ignoring readahead effects
   - sequential workloads can look much better due to prefetch

4. Treating page cache as only a read feature
   - buffered writes also depend on it

---

## 12. Self-Check Questions

1. What kernel structure represents per-file page cache mapping?
2. In buffered reads, what is the key behavioral difference between hit and miss?
3. Why can second-read latency be much lower than first-read latency?
4. Which kernel source files are central for today’s topic?
5. How does readahead improve sequential-read performance?

## 13. Self-Check Answers

1. `address_space` (`inode->i_mapping`).
2. Hit serves from memory; miss requires storage fetch and possible wait.
3. Data is already resident in page cache (warm cache).
4. `mm/filemap.c` and `mm/readahead.c`.
5. It prefetches likely-next data pages so future reads avoid synchronous misses.

---

## 14. Tomorrow’s Preview: Day 6 — Read-ahead Internals

Next we will deep-dive into readahead decisions:
- sequential pattern detection
- readahead window sizing
- key logic in `mm/readahead.c`
- measurable impact on throughput and latency.
