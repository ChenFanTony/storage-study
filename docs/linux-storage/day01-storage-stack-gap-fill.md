# Day 1: Storage Stack Gap-Fill (Half Day)

## Context
You already know this stack. This is a **directed audit**, not a tutorial.
Goal: confirm your mental model is complete and current, identify any gaps
before the deep dives begin. Timebox strictly — 1.5 hours max.

---

## 1. The Stack You Know — Verify It

Draw your current I/O path diagram from memory **before** reading further.
Then compare against this reference. Mark anything that surprises you.

```
┌─────────────────────────────────────────────────────────┐
│                    USER SPACE                           │
│  read() / write() / io_uring SQE                        │
└────────────────────────┬────────────────────────────────┘
                         │ syscall / io_uring
                         ▼
┌─────────────────────────────────────────────────────────┐
│              VFS + PAGE CACHE                           │
│  vfs_read/write → filemap_read → page cache lookup      │
│  Hit: copy_to_user, done                                │
│  Miss: address_space_operations->readahead/read_folio   │
└────────────────────────┬────────────────────────────────┘
                         │ cache miss / O_DIRECT / DAX
                         ▼
┌─────────────────────────────────────────────────────────┐
│              FILESYSTEM LAYER                           │
│  ext4 / XFS / Btrfs / etc.                              │
│  Logical offset → physical block (extent/B-tree lookup) │
│  Journal/log updates (metadata)                         │
│  bio construction                                       │
└────────────────────────┬────────────────────────────────┘
                         │ submit_bio()
                         ▼
┌─────────────────────────────────────────────────────────┐
│               BLOCK LAYER (blk-mq)                      │
│  bio → merge → request allocation (tag set)             │
│  per-CPU software queue → hardware queue dispatch       │
│  I/O scheduler: none / mq-deadline / bfq / kyber        │
│  cgroup throttle / iolatency enforcement                │
└────────────────────────┬────────────────────────────────┘
                         │ queue_rq()
                         ▼
┌─────────────────────────────────────────────────────────┐
│         STACKING DRIVERS (optional layers)              │
│  Device Mapper: dm-linear, dm-crypt, dm-cache, dm-thin  │
│  MD: RAID-1/5/6/10                                      │
│  bcache: cache device intercept                         │
│  Each layer remaps bio and re-submits                   │
└────────────────────────┬────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────┐
│               DEVICE DRIVER                             │
│  NVMe: drivers/nvme/host/pci.c — SQ/CQ doorbell        │
│  virtio-blk: drivers/block/virtio_blk.c (you know this) │
│  SCSI/SATA: drivers/scsi/                               │
└────────────────────────┬────────────────────────────────┘
                         │ DMA + interrupt
                         ▼
┌─────────────────────────────────────────────────────────┐
│               HARDWARE                                  │
│  NVMe SSD / SATA / SAS / virtio device                  │
│  Completion interrupt → blk_mq_complete_request()       │
│  → bio->bi_end_io() → wake waiter / io_uring CQE        │
└─────────────────────────────────────────────────────────┘
```

**Gaps to look for:**
- Do you know where exactly bcache intercepts in the stack? (hint: it's a block device sitting between blk-mq and the backing device — not a dm target)
- Do you know the difference between the DAX path and the normal buffered path? (DAX skips both page cache AND block layer)
- Do you know io_uring's two submit paths: through the normal VFS stack vs NVMe passthrough?

---

## 2. What Changed Since You Last Looked

If your main experience is on older kernels, here are the significant changes
worth noting before the deep dives:

| Area | What Changed | Since |
|------|-------------|-------|
| Page cache | `struct page` → `struct folio` (variable-size cache units) | 5.16+ |
| blk-mq | Legacy single-queue path removed entirely | 5.0 |
| io_uring | Added NVMe passthrough (`uring_cmd`), fixed buffers, registered files | 5.12–6.0 |
| Scheduler | `kyber` added for low-latency NVMe; `none` now default for NVMe | 5.x |
| ZNS | Zoned namespace support in blk-mq, new zone-append op | 5.9+ |
| blk-crypto | Inline hardware encryption at block layer | 5.8+ |
| NVMe-oF | TCP transport added (no RDMA HW needed) | 5.0 |

---

## 3. Hands-On Audit (30 min)

```bash
# 1. Verify your understanding of the mq topology
lsblk -t
ls /sys/block/

# For each device you care about:
cat /sys/block/nvme0n1/queue/scheduler
cat /sys/block/nvme0n1/queue/nr_requests
cat /sys/block/nvme0n1/queue/nr_hw_queues     # how many HW queues?
ls /sys/block/nvme0n1/mq/                     # one dir per HW queue

cat /sys/block/vda/queue/nr_hw_queues         # virtio-blk: likely just 1 or few
ls /sys/block/vda/mq/

# 2. Confirm bcache if present
ls /sys/fs/bcache/ 2>/dev/null
cat /sys/block/bcache0/bcache/state 2>/dev/null

# 3. Confirm io_uring support
cat /proc/sys/kernel/io_uring_disabled        # 0 = enabled

# 4. Check diskstats — verify you can read every field
# fields: reads_completed reads_merged sectors_read ms_reading
#         writes_completed writes_merged sectors_written ms_writing
#         ios_in_progress ms_io weighted_ms_io
#         discards_completed discards_merged sectors_discarded ms_discarding
#         flush_completed ms_flushing
cat /proc/diskstats | head -5
```

---

## 4. Gap Identification Worksheet

Answer these quickly. Any "unsure" → add to your study notes for the relevant day.

| Question | Answer / Unsure |
|----------|----------------|
| What is a `struct folio` and why replace `struct page`? | |
| Where exactly in blk-mq does a bio get a tag assigned? | |
| What is the difference between `io.max` and `io.latency` in cgroup v2? | |
| bcache operates as a block device — what does its `make_request_fn` do? | |
| What NVMe queue model does virtio-blk approximate? | |
| What does DAX mean for a filesystem — what does it bypass? | |
| io_uring fixed buffers — what kernel cost do they eliminate? | |
| What is ANA in NVMe-oF multipathing? | |

---

## 5. Key Source Files to Keep Open This Month

Bookmark these now — you will return to them repeatedly:

```
block/blk-mq.c              # the heart of the block layer
block/blk-mq-tag.c          # tag set / request allocation
block/blk-cgroup.c          # cgroup I/O
block/blk-iolatency.c       # io.latency enforcement
drivers/md/bcache/request.c # bcache I/O path (you know this area)
drivers/md/bcache/alloc.c   # bcache GC
drivers/md/dm-cache-target.c
drivers/nvme/host/core.c
drivers/nvme/host/pci.c
io_uring/io_uring.c
```

---

## 6. Self-Check

Before Day 2, you should be able to answer:

1. How many hardware queues does a typical NVMe device expose vs a virtio-blk device?
2. At what point in the stack does bcache intercept I/O, and what does it do with it?
3. Name two things that changed in the block layer between kernel 4.x and 6.x that affect how you read the source.

---

## Tomorrow: Day 2 — blk-mq: Hardware Queues, Tag Sets, Dispatch

We go deep on blk-mq internals: how tag sets are allocated, how software
queues map to hardware queues, and how `__blk_mq_run_hw_queue()` drives dispatch.
This is the area most architects get wrong when reasoning about queue depth.
