# Day 8: Bio Layer (`struct bio` and Submission Flow)

## Learning Objectives
- Understand what a `bio` represents in the Linux block stack
- Learn core `bio` fields and related structures (`bio_vec`, iterators)
- Follow `submit_bio()` into block-layer processing
- Understand bio completion callbacks and lifecycle
- Practice tracing bio issue/completion events

---

## 1. Why the Bio Layer Exists

At the VFS/filesystem level, operations are file-offset based. At lower levels, devices need block/sector-oriented I/O requests.

The bio layer bridges that gap by representing block I/O in a standard form.

A `bio` describes:
- target block device
- operation type (read/write/flush/discard/etc.)
- sector range
- memory buffers involved in transfer
- completion callback behavior

---

## 2. Where Bio Sits in the I/O Path

Conceptual placement:

```text
syscall/VFS/filesystem
  -> page cache / filesystem mapping
    -> build bio(s)
      -> submit_bio()
        -> block layer processing
          -> request queue / scheduler / driver dispatch
```

A single high-level read/write can generate multiple bios depending on layout, contiguity, and filesystem decisions.

---

## 3. Core Structures

### `struct bio`
Main block-I/O descriptor.

Key conceptual fields:
- device target (`bi_bdev`)
- operation + flags (`bi_opf`)
- range iterator (`bi_iter` with sector/size progress)
- vector list of memory segments (`bio_vec[]`)
- end callback (`bi_end_io`)

### `struct bio_vec`
Describes one memory segment:
- page/folio backing memory
- offset within page
- length in bytes

### `bvec_iter` / bio iterator state
Tracks current position while bio is being processed/completed (remaining bytes, current sector, segment index).

---

## 4. Typical Bio Lifecycle

```text
bio_alloc*()
  -> configure op/device/sector
  -> attach segments (bio_add_page, helpers)
  -> submit_bio(bio)
     -> block layer handles/merges/routes
     -> driver submits to hardware
     -> completion interrupt/path
  -> bi_end_io callback
  -> bio put/free
```

Important: lifecycle ownership rules matter. Correct reference and completion handling are essential to avoid leaks or use-after-free bugs.

---

## 5. `submit_bio()` High-Level Behavior

`submit_bio()` is a central handoff from filesystem/page-cache side to block layer.

High-level responsibilities include:
- validating/normalizing bio metadata
- accounting/policy hooks
- passing bio through stacking layers (e.g., DM/MD)
- entering blk-mq request path

Not every bio maps 1:1 to final hardware command; downstream logic may split/merge/reorder depending on constraints.

---

## 6. Operations You’ll See in `bi_opf`

Common operations:
- READ
- WRITE
- FLUSH/FUA-related durability operations
- DISCARD/trim-like deallocation hints
- WRITE_ZEROES (device-assisted zeroing)

Understanding op type is critical when interpreting traces and latency patterns.

---

## 7. Bio and Stacking Drivers

Layered block subsystems (like device mapper and md/RAID) often:
- inspect incoming bio
- remap sectors/devices
- clone/split bios
- forward to lower devices

So traces may show multiple related bio events for what appears to be one user request.

---

## 8. Completion Path Basics

On completion, block layer eventually triggers `bi_end_io` chain.

Completion handling typically:
- reports status (success/error)
- unlocks/updates associated cache state
- wakes waiters or advances higher-level I/O completion
- releases bio references

Many debugging tasks depend on confirming where completion stalls occur.

---

## 9. Practical Tracing Exercises

### Exercise 1: Locate core bio definitions/usages in source
```bash
grep -n "struct bio" include/linux/blk_types.h
grep -n "submit_bio" block/blk-core.c
grep -n "bio_add_page" block/bio.c
```

### Exercise 2: Observe block request issue/completion tracepoints
```bash
sudo bpftrace -e 'tracepoint:block:block_rq_issue { printf("ISSUE dev=%d:%d bytes=%d rwbs=%s\n", args.dev >> 20, args.dev & ((1<<20)-1), args.bytes, str(args.rwbs)); }'
```

In another terminal, trigger I/O:
```bash
dd if=/dev/zero of=/tmp/day8-bio.bin bs=1M count=256 status=progress
```

### Exercise 3: Pair issue and complete events
```bash
sudo bpftrace -e 'tracepoint:block:block_rq_issue { @issue = count(); } tracepoint:block:block_rq_complete { @done = count(); } interval:s:5 { print(@issue); print(@done); clear(@issue); clear(@done); }'
```

### Exercise 4: Use blktrace for deeper event stream
```bash
sudo blktrace -d /dev/sda -o - | blkparse -i - | head -100
```

(Use your actual target device, e.g. `nvme0n1`.)

### Exercise 5: Study stacked path behavior (optional)
```bash
# If using dm/md devices, trace both top-level and underlying block device
lsblk -o NAME,TYPE,MOUNTPOINT
```

---

## 10. Source Navigation Checklist

Primary files:
- `include/linux/blk_types.h` (`struct bio` and related types)
- `block/bio.c` (bio helpers/manipulation)
- `block/blk-core.c` (`submit_bio` path)

Related:
- `block/blk-mq.c` (handoff into multi-queue request machinery)
- `drivers/md/` (stacking/remap examples)

---

## 11. Common Pitfalls

1. Assuming one syscall equals one bio
   - can be many bios per syscall depending on mapping and size

2. Treating bio and request as the same object
   - bio is fundamental I/O descriptor; requests can aggregate bios for dispatch

3. Ignoring layered remapping
   - DM/MD may transform bios before hardware sees them

4. Forgetting completion ownership
   - incorrect end-io handling can cause severe correctness issues

---

## 12. Self-Check Questions

1. What core information does a `bio` carry?
2. What is the role of `bio_vec`?
3. Why might one user write generate multiple bios?
4. What is `submit_bio()` conceptually responsible for?
5. Why can traces show additional bio activity on DM/RAID setups?

## 13. Self-Check Answers

1. Device target, operation type/flags, sector range, memory segments, and completion callback context.
2. It describes one memory segment (page + offset + length) used in transfer.
3. Due to file/block mapping fragmentation, size splitting, or alignment/stacking constraints.
4. It hands filesystem-produced block I/O into block-layer processing and downstream routing.
5. Layered drivers can split/clone/remap bios before forwarding.

---

## 14. Tomorrow’s Preview: Day 9 — blk-mq Architecture

Next we’ll study how bios become dispatchable requests in modern multi-queue block layer:
- software queues vs hardware queues
- tag sets and request lifecycle
- queue mapping and CPU locality
- practical queue topology inspection in `/sys/block/<dev>/mq/`.
