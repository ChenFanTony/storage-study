# Day 7: Writeback (Dirty Pages to Persistent Storage)

## Learning Objectives
- Understand the dirty page lifecycle in Linux
- Learn how and when writeback is triggered
- Identify key writeback code paths and data structures
- Understand the role of flusher threads and dirty throttling
- Practice observing and tuning writeback behavior safely

---

## 1. Why Writeback Exists

In buffered I/O, `write()` usually updates page cache first and returns before data is persisted to disk.

That gives good performance, but creates a second responsibility:
- track dirty memory pages
- flush them to storage at appropriate times
- balance throughput, latency, and memory pressure

This process is **writeback**.

---

## 2. Dirty Page Lifecycle

Conceptual flow:

```text
userspace write()
  -> vfs_write()
    -> filesystem buffered write path
      -> page cache folio/page marked dirty
         (data not yet durable)

later, writeback triggers:
  -> flusher/background reclaim/sync/fsync
     -> filesystem writeback callbacks
        -> bio/request submission
           -> device completion
              -> page/folio cleaned
```

Key idea: dirty means “modified in memory, not yet persisted”.

---

## 3. Main Writeback Triggers

Writeback can start from multiple sources:

1. **Background writeback**
   - kernel flusher threads periodically push dirty data

2. **Memory pressure / reclaim**
   - reclaim paths may force dirty pages to be written

3. **Threshold-based throttling**
   - when dirty memory exceeds configured limits, writers are slowed and writeback pressure increases

4. **Explicit durability operations**
   - `fsync()`, `fdatasync()`, `sync()`, `syncfs()`

---

## 4. Key Source Files

Primary files for Day 7:
- `mm/page-writeback.c`
- `fs/fs-writeback.c`

Supporting areas:
- filesystem-specific writeback implementations (e.g., ext4/xfs)
- block-layer submission/completion paths (`block/`)

---

## 5. Core Concepts and Structures

### Dirty accounting
Kernel tracks dirty memory globally and per-writeback domain.

### `writeback_control` (WBC)
Control structure that guides writeback behavior (scope, sync mode, limits).

### Per-bdi / writeback contexts
Writeback is organized by backing device/inode ownership to improve fairness and locality.

### Balance dirty pages
Writers can be throttled when dirty memory grows too fast, preventing runaway dirtying.

---

## 6. Flusher Thread Role

Flusher threads are kernel workers that:
- scan dirty inodes/pages
- invoke filesystem writeback callbacks
- keep dirty memory under control
- reduce large latency spikes from forced sync later

Without proactive flushing, applications may encounter severe stalls when dirty limits are hit.

---

## 7. Durability and Ordering Notes

- A successful buffered `write()` does **not** guarantee data is on stable storage.
- `fsync()`/`fdatasync()` provide stronger durability guarantees.
- Filesystem journaling and metadata policies affect actual persistence ordering.

So correctness-sensitive applications must use explicit sync semantics.

---

## 8. Runtime Knobs (Sysctl)

Common knobs:

- `vm.dirty_background_ratio`
- `vm.dirty_ratio`
- `vm.dirty_background_bytes`
- `vm.dirty_bytes`
- `vm.dirty_expire_centisecs`
- `vm.dirty_writeback_centisecs`

Typical meaning:
- **background** thresholds start asynchronous flushing
- **dirty** thresholds start stronger throttling/pressure
- **expire/writeback centisecs** influence aging and periodic flush cadence

Use caution: aggressive tuning can cause either throughput loss or latency spikes.

---

## 9. Hands-On Exercises

### Exercise 1: Inspect current dirty/writeback settings
```bash
sysctl vm.dirty_background_ratio vm.dirty_ratio vm.dirty_expire_centisecs vm.dirty_writeback_centisecs
```

### Exercise 2: Observe dirty/writeback memory in real time
```bash
watch -n1 "grep -E '^(Dirty|Writeback|Cached):' /proc/meminfo"
```

### Exercise 3: Generate buffered write load
```bash
# buffered write workload
dd if=/dev/zero of=/tmp/day7-writeback-test.bin bs=1M count=2048 status=progress
```

While it runs, monitor `/proc/meminfo` and observe `Dirty` / `Writeback` movement.

### Exercise 4: Force explicit sync and compare behavior
```bash
# after write load
sync
```

Compare perceived stalls with and without periodic syncing during long write bursts.

### Exercise 5: Basic fio buffered write experiment
```bash
fio --name=bufwrite --filename=/tmp/day7-fio.img --size=1G --rw=write --bs=256k --ioengine=psync --direct=0
```

Repeat with changed dirty knobs (carefully) and compare throughput/latency consistency.

---

## 10. Safe Tuning Workflow

1. Record baseline sysctl values
2. Change one knob at a time
3. Run repeatable workload (same file size, same storage, low background noise)
4. Observe both throughput and stall behavior
5. Restore defaults when done

Avoid broad production changes without workload-specific validation.

---

## 11. Source Navigation Checklist

1. `mm/page-writeback.c`
   - dirty threshold logic
   - balancing/throttling flow

2. `fs/fs-writeback.c`
   - dirty inode traversal and writeback scheduling

3. Filesystem writeback callbacks
   - where dirty cache transitions to block I/O submission

---

## 12. Common Pitfalls

1. Assuming `write()` implies durability
   - it usually means data reached page cache, not disk

2. Over-tuning dirty limits blindly
   - too high: long flush stalls and latency spikes
   - too low: frequent throttling and lower throughput

3. Ignoring filesystem semantics
   - journaling mode and metadata behavior change outcomes

4. Measuring only average throughput
   - tail latency and stall events matter for real workloads

---

## 13. Self-Check Questions

1. What does a dirty page represent?
2. Name three writeback trigger sources.
3. Which files are central to writeback policy and execution?
4. Why can high dirty thresholds increase latency risk?
5. Which syscall should an app use when it needs strong durability guarantees?

## 14. Self-Check Answers

1. Data modified in memory but not yet persisted to stable storage.
2. Background flusher activity, memory pressure/reclaim, threshold-based throttling, or explicit sync operations.
3. `mm/page-writeback.c` and `fs/fs-writeback.c`.
4. More dirty data can accumulate, causing larger later flush bursts and potential stalls.
5. `fsync()` (or `fdatasync()` depending on required metadata semantics).

---

## 15. Tomorrow’s Preview: Day 8 — Bio Layer

Next we move from cache/writeback policy to block I/O units:
- `struct bio`, `bio_vec`
- `submit_bio()` flow
- bio allocation, population, submission, completion
- tracing bio lifecycle in practice.
