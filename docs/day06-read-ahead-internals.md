# Day 6: Read-ahead Internals

## Learning Objectives
- Understand why Linux read-ahead exists and when it is triggered
- Learn the core decision flow in `mm/readahead.c`
- Understand adaptive window growth/shrink behavior
- Connect read-ahead tuning to observable workload performance
- Practice measuring sequential read behavior with controlled experiments

---

## 1. Why Read-ahead Exists

Storage latency is much higher than CPU/memory latency. If the kernel waited for every page fault or cache miss synchronously, sequential reads would stall repeatedly.

Read-ahead mitigates this by:
- predicting near-future reads
- prefetching additional pages before they are explicitly requested
- overlapping I/O with application progress

Result: higher throughput and lower apparent read latency in sequential workloads.

---

## 2. Position in the Buffered Read Path

Conceptual flow:

```text
read()
  -> vfs_read()
    -> filesystem read_iter
      -> filemap_read()
        -> cache lookup
          -> miss/trigger point
             -> ondemand_readahead() / related helpers
             -> submit readahead I/O
        -> copy available pages to userspace
```

Key files:
- `mm/readahead.c` (policy/algorithms)
- `mm/filemap.c` (read path integration)

---

## 3. Core Read-ahead Concepts

### Readahead window
The range of pages kernel decides to prefetch beyond current demand.

### Synchronous vs asynchronous readahead
- **Synchronous trigger:** current read misses and needs immediate data
- **Asynchronous extension:** kernel opportunistically expands prefetch while app is still consuming current pages

### Access pattern sensitivity
- Sequential/streaming access tends to increase readahead usefulness
- Random access can waste I/O and cache space if prefetch is too aggressive

---

## 4. Adaptive Behavior (High-Level)

Linux read-ahead is adaptive rather than fixed-size only.

Typical behavior:
1. detect likely sequential progression
2. start with a modest prefetch size
3. increase window if pattern remains sequential
4. reduce/reset when pattern breaks or misses become non-sequential

This balances:
- performance for streaming reads
- reduced cache pollution for irregular access

---

## 5. `mm/readahead.c` Study Focus

When reading source, focus on:
- readahead state tracking (per-file stream behavior)
- trigger conditions from cache misses
- window calculation and update logic
- submission boundaries and interaction with filesystem mapping/read callbacks

Even if helper names vary slightly by kernel version, the strategy remains:
**predict + prefetch + adapt**.

---

## 6. Device-Level Influence: `read_ahead_kb`

Per-block-device setting:

```text
/sys/block/<dev>/queue/read_ahead_kb
```

This affects baseline prefetch behavior at the block layer interface.

Important:
- too low can underutilize sequential throughput
- too high can increase unnecessary I/O and cache churn
- optimal value depends on device latency, workload pattern, and concurrency

---

## 7. Interactions with Page Cache and Workload Type

Read-ahead effectiveness depends on:
- page cache pressure (memory availability)
- active competing workloads
- file access regularity
- filesystem and block-device characteristics

Typical outcomes:
- large sequential scan: high benefit
- random small reads: low or negative benefit
- mixed workload: tune carefully and validate with measurements

---

## 8. Hands-On Exercises

### Exercise 1: Inspect current read-ahead setting
```bash
lsblk
cat /sys/block/sda/queue/read_ahead_kb
```

### Exercise 2: Baseline sequential buffered read test
```bash
fio --name=seqread-base --filename=/tmp/ra-test.img --size=512M --rw=read --bs=128k --ioengine=psync --direct=0
```

### Exercise 3: Compare with different `read_ahead_kb` values
```bash
# Example values; pick your real test device
sudo sh -c 'echo 128 > /sys/block/sda/queue/read_ahead_kb'
fio --name=seqread-ra128 --filename=/tmp/ra-test.img --size=512M --rw=read --bs=128k --ioengine=psync --direct=0

sudo sh -c 'echo 1024 > /sys/block/sda/queue/read_ahead_kb'
fio --name=seqread-ra1024 --filename=/tmp/ra-test.img --size=512M --rw=read --bs=128k --ioengine=psync --direct=0
```

### Exercise 4: Random-read contrast
```bash
fio --name=randread --filename=/tmp/ra-test.img --size=512M --rw=randread --bs=4k --iodepth=32 --ioengine=libaio --direct=0
```

Compare whether larger readahead still helps.

### Exercise 5: Source walkthrough checklist
```text
1) mm/readahead.c: find ondemand_readahead-style logic
2) mm/filemap.c: identify where readahead is triggered during buffered read
3) Note state fields controlling next-window decisions
```

---

## 9. Measurement Notes

For cleaner comparisons:
- run multiple trials per configuration
- keep CPU frequency/power profile stable
- avoid heavy background I/O during tests
- compare both throughput and tail latency where relevant

Avoid drawing conclusions from a single run.

---

## 10. Source Navigation Checklist

Primary:
- `mm/readahead.c`
- `mm/filemap.c`

Supporting:
- `include/linux/fs.h`
- `/sys/block/<dev>/queue/read_ahead_kb` runtime interface

---

## 11. Common Pitfalls

1. Assuming bigger read-ahead is always better
   - it can increase useless prefetch and cache eviction

2. Testing only sequential workloads
   - random/mixed workloads may behave very differently

3. Ignoring cache warmth and background noise
   - uncontrolled state can invalidate comparisons

4. Treating one device’s optimal setting as universal
   - NVMe, SATA SSD, and HDD may need different tuning

---

## 12. Self-Check Questions

1. What problem does read-ahead primarily solve?
2. How does Linux generally adapt readahead window size?
3. Why can read-ahead hurt some random-access workloads?
4. Which kernel file contains core read-ahead policy logic?
5. What runtime knob exposes per-device read-ahead size?

## 13. Self-Check Answers

1. It hides storage latency by prefetching likely-next data.
2. It grows for sustained sequential access and shrinks/resets when pattern breaks.
3. Prefetched data may not be used, wasting I/O bandwidth and page cache space.
4. `mm/readahead.c`.
5. `/sys/block/<dev>/queue/read_ahead_kb`.

---

## 14. Tomorrow’s Preview: Day 7 — Writeback

Next we will study dirty pages and persistence:
- dirty page lifecycle
- flusher threads and writeback triggers
- core files: `mm/page-writeback.c`, `fs/fs-writeback.c`
- practical tuning with dirty-ratio-related knobs.
