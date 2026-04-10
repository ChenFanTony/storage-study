# Day 14: Week 2 Review — Block Layer End-to-End

## Learning Objectives
- Consolidate the full block I/O path from `submit_bio()` to hardware completion
- Re-read bio → request → dispatch → completion with confidence
- Draw the complete block I/O diagram from memory
- Identify personal weak spots for targeted revisiting

---

## 1. Why a Review Day

Week 2 covered the block layer in depth: bio creation, blk-mq architecture, I/O schedulers, request merging/plugging, device registration, and tracing tools. This is a good checkpoint to verify you can follow any block I/O end-to-end without referencing notes.

---

## 2. End-to-End Block I/O Path Recap

```text
Filesystem / Direct I/O / Page Cache writeback
        |
        v
bio allocation + populate bio_vecs
        |
        v
submit_bio(bio)
        |
        v
blk-mq software queue (blk_mq_ctx)
  - plugging batches requests
  - scheduler may reorder/merge
        |
        v
blk-mq hardware queue (blk_mq_hw_ctx)
  - tag allocation
  - dispatch to driver
        |
        v
Driver .queue_rq() callback
  - NVMe: builds NVMe command, rings doorbell
  - SCSI: builds SCSI CDB, submits to HBA
  - null_blk: immediate or timer-based completion
        |
        v
Hardware processes command
        |
        v
IRQ / poll completion
        |
        v
blk_mq_complete_request()
  - tag freed
  - bio endio callback
  - upper layer notified (page unlocked, writeback complete, etc.)
```

---

## 3. Key Concepts Checklist

Review each concept. Mark any you cannot confidently explain:

- [ ] `struct bio` — purpose, `bio_vec` array, lifetime
- [ ] `submit_bio()` — entry point from filesystem to block layer
- [ ] blk-mq software queues vs hardware queues
- [ ] Tag sets and tag allocation
- [ ] I/O scheduler role (none, mq-deadline, bfq, kyber)
- [ ] Front-merge vs back-merge
- [ ] Plugging and unplugging — why batching helps
- [ ] `gendisk` registration lifecycle
- [ ] `blktrace` output interpretation (Q, G, D, C, M actions)
- [ ] `bpftrace` block tracepoints (`block:block_rq_issue`, etc.)

Any unchecked items deserve a targeted re-read of the corresponding day's notes.

---

## 4. Diagram Exercise

Draw the following from memory on paper or whiteboard:

1. **Bio lifecycle diagram:** allocation → populate → submit → completion
2. **blk-mq queue topology:** per-CPU sw queues → hw queues → driver
3. **Request merge flow:** adjacent bio → merge check → combined request
4. **Device registration:** driver init → queue setup → gendisk → userspace visibility

Compare your drawings against Days 8–12 notes. Note discrepancies.

---

## 5. Trace Exercise

Run a complete tracing session that captures a single I/O from submission to completion:

```bash
# Option A: blktrace
sudo blktrace -d /dev/sda -o - | blkparse -i - | head -50

# While running:
dd if=/dev/sda of=/dev/null bs=4k count=1 iflag=direct
```

Identify these events in the output:
- **Q** — bio queued
- **G** — request allocated (get)
- **M** — merged with existing request
- **I** — inserted into scheduler
- **D** — dispatched to driver
- **C** — completed

```bash
# Option B: bpftrace one-liner
sudo bpftrace -e '
tracepoint:block:block_rq_issue { printf("issue: dev=%d,%d sector=%lld\n", args.dev >> 20, args.dev & 0xfffff, args.sector); }
tracepoint:block:block_rq_complete { printf("complete: dev=%d,%d sector=%lld\n", args.dev >> 20, args.dev & 0xfffff, args.sector); }
'
```

---

## 6. Cross-Cutting Questions

These span multiple days:

1. A buffered `write()` dirties a page. Trace the full path from dirty page → writeback → bio → request → hardware → completion.
2. What determines whether two adjacent bios get merged into one request?
3. If you switch from `mq-deadline` to `none`, what changes in the dispatch path?
4. How does `null_blk` simulate completion without real hardware?
5. What information does `blktrace` D→C latency represent?

---

## 7. Cross-Cutting Answers

1. Flusher thread wakes → calls `writepages()` → filesystem creates bio(s) → `submit_bio()` → blk-mq queuing → scheduler → dispatch → hardware → completion → page marked clean.
2. Merge eligibility: same device, adjacent sectors, compatible flags, total size within queue limits, scheduler permits.
3. With `none`, requests bypass scheduler reordering and dispatch directly from software queue to hardware queue.
4. `null_blk` completes requests via timer callback or inline completion depending on configuration, never touching real storage.
5. D→C latency is the time from driver dispatch to hardware completion — the device service time.

---

## 8. Weak Spot Action Plan

For each concept you marked uncertain in Section 3:

| Weak Area | Re-read | Practice |
|-----------|---------|----------|
| Bio lifecycle | Day 8 | Trace `submit_bio` with ftrace |
| blk-mq queues | Day 9 | Inspect `/sys/block/<dev>/mq/` |
| I/O schedulers | Day 10 | Switch schedulers, benchmark |
| Merge/plug | Day 11 | blktrace M-flag observation |
| Registration | Day 12 | Load/unload null_blk, check sysfs |
| Tracing tools | Day 13 | Run biolatency + biosnoop |

---

## 9. Tomorrow's Preview: Day 15 — Device Mapper Core

We move to Week 3 with the Device Mapper subsystem:
- `drivers/md/dm.c` and bio remapping architecture
- dm table and target_type concepts
- hands-on with `dm-linear` via `dmsetup`.
