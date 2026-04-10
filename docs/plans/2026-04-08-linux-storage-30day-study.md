# 30-Day Linux Kernel Storage Study Plan

**Created:** 2026-04-08
**Status:** Active
**Goal:** Systematic study of the Linux kernel storage stack, from VFS to hardware drivers

---

## Curriculum Modules

| Module | Topic | Key Source |
|--------|-------|-----------|
| 1 | Storage Stack Overview | `Documentation/block/` |
| 2 | Virtual Filesystem (VFS) | `fs/namei.c`, `fs/read_write.c` |
| 3 | Page Cache & Writeback | `mm/filemap.c`, `mm/readahead.c` |
| 4 | Block Layer | `block/blk-mq.c`, `block/bio.c` |
| 5 | I/O Schedulers | `block/mq-deadline.c`, `block/bfq-iosched.c` |
| 6 | Device Mapper | `drivers/md/dm.c`, `drivers/md/dm-*.c` |
| 7 | Software RAID (md) | `drivers/md/md.c`, `drivers/md/raid*.c` |
| 8 | Filesystems (ext4/XFS/Btrfs) | `fs/ext4/`, `fs/xfs/`, `fs/btrfs/` |
| 9 | NVMe & SCSI | `drivers/nvme/`, `drivers/scsi/` |
| 10 | Direct I/O & io_uring | `io_uring/`, `fs/direct-io.c` |
| 11 | bcache & dm-cache | `drivers/md/bcache/`, `drivers/md/dm-cache*` |
| 12 | Advanced Topics | Zoned devices, pmem, NVMe-oF, blk-crypto, BPF |
| 13 | Debugging & Tracing | blktrace, ftrace, bpftrace, perf |
| 14 | Performance Tuning | Queue depth, cgroup I/O, scheduler tuning |

---

## Week 1: Foundation — I/O Path & VFS

### Day 1 — Storage Stack Overview
- **Read:** `Documentation/block/` overview; understand user -> VFS -> block -> driver -> hw path
- **Hands-on:** Run `lsblk`, `cat /proc/diskstats`, explore `/sys/block/`
- **Goal:** Draw the full I/O stack diagram

### Day 2 — VFS Core Structures
- **Read:** `include/linux/fs.h` — `super_block`, `inode`, `dentry`, `file`
- **Hands-on:** Trace a `read()` syscall with `strace` + `ftrace`
- **Goal:** Understand the four VFS objects and their relationships

### Day 3 — VFS Operations
- **Read:** `fs/read_write.c` — `vfs_read()`, `vfs_write()` flow
- **Hands-on:** Write a minimal kernel module that registers a `file_operations`
- **Goal:** Follow a read from syscall entry to filesystem dispatch

### Day 4 — Path Lookup & Dcache
- **Read:** `fs/namei.c` — `path_lookupat()`, `walk_component()`
- **Hands-on:** Use `perf probe` on `d_lookup`, measure dcache hit rate
- **Goal:** Understand RCU-walk vs ref-walk path lookup

### Day 5 — Page Cache
- **Read:** `mm/filemap.c` — `filemap_get_pages()`, `filemap_read()`
- **Hands-on:** Monitor `/proc/meminfo` Cached/Dirty, use `vmtouch`
- **Goal:** Explain how the page cache serves reads and handles misses

### Day 6 — Read-ahead
- **Read:** `mm/readahead.c` — `page_cache_ra_unbounded()`, `ondemand_readahead()`
- **Hands-on:** Tune `read_ahead_kb`, benchmark with `fio` sequential read
- **Goal:** Understand adaptive read-ahead algorithm

### Day 7 — Writeback
- **Read:** `mm/page-writeback.c`, `fs/fs-writeback.c`
- **Hands-on:** Tune `dirty_ratio`, `dirty_expire_centisecs`; observe with `bpftrace`
- **Goal:** Understand dirty page thresholds and flusher thread behavior

---

## Week 2: Block Layer & I/O Scheduling

### Day 8 — Bio Layer
- **Read:** `block/bio.c`, `include/linux/bio.h` — `struct bio`, `bio_vec`, `submit_bio()`
- **Hands-on:** Trace `submit_bio` with ftrace
- **Goal:** Understand bio lifecycle: allocation, populate, submit, completion

### Day 9 — blk-mq Architecture
- **Read:** `block/blk-mq.c` — hardware queues, software queues, tag sets
- **Hands-on:** Examine `/sys/block/<dev>/mq/`, check queue mapping
- **Goal:** Explain software queue -> hardware queue dispatch

### Day 10 — I/O Schedulers
- **Read:** `block/mq-deadline.c` and `block/bfq-iosched.c`
- **Hands-on:** Switch schedulers, benchmark with `fio` random 4K read
- **Goal:** Compare deadline (latency) vs BFQ (fairness) characteristics

### Day 11 — Request Merge & Plug
- **Read:** `block/blk-merge.c`, `block/blk-mq.c` plug/unplug
- **Hands-on:** Use `blktrace` to observe merge events (M flags)
- **Goal:** Understand front-merge, back-merge, and plugging

### Day 12 — Block Device Registration
- **Read:** `block/genhd.c` — `add_disk()`, `del_gendisk()`
- **Hands-on:** Study `drivers/block/null_blk/` as a simple block driver
- **Goal:** Understand how a block device is registered and exposed to userspace

### Day 13 — blktrace & BPF Tools
- **Read:** `blktrace`/`blkparse` output format; Brendan Gregg's biolatency
- **Hands-on:** Run `biolatency`, `biosnoop`, `bitesize` on your system
- **Goal:** Be proficient with block-layer tracing tools

### Day 14 — Week 2 Review
- **Review:** Re-read bio -> request -> dispatch path end-to-end
- **Hands-on:** Draw the full block I/O diagram from memory
- **Goal:** Trace any block I/O from `submit_bio()` to hardware completion

---

## Week 3: Device Mapper, MD & Filesystems

### Day 15 — Device Mapper Core
- **Read:** `drivers/md/dm.c` — `dm_submit_bio()`, target dispatch
- **Hands-on:** Create `dm-linear` device with `dmsetup`
- **Goal:** Understand dm table, target_type, and bio remapping

### Day 16 — dm-thin & dm-cache
- **Read:** `drivers/md/dm-thin.c`, `drivers/md/dm-cache-target.c`
- **Hands-on:** Set up thin provisioning with `lvcreate --thin`
- **Goal:** Understand thin pool metadata, mapping tree, and cache policy

### Day 17 — dm-crypt & dm-verity
- **Read:** `drivers/md/dm-crypt.c` (encrypt_bio), `dm-verity-target.c`
- **Hands-on:** Create LUKS volume with `cryptsetup`, measure overhead
- **Goal:** Understand per-bio encryption and Merkle-tree verification

### Day 18 — md/RAID
- **Read:** `drivers/md/md.c`, `drivers/md/raid1.c`
- **Hands-on:** Create md RAID-1 with `mdadm`, observe rebuild
- **Goal:** Understand md personalities, resync, and bitmap journaling

### Day 19 — ext4: Layout & Journal
- **Read:** `fs/ext4/super.c`, `fs/ext4/inode.c`; understand JBD2 (`fs/jbd2/`)
- **Hands-on:** `mkfs.ext4`, `debugfs`, `dumpe2fs`; examine on-disk layout
- **Goal:** Understand block groups, journal transactions, and recovery

### Day 20 — ext4: Extents & Delayed Allocation
- **Read:** `fs/ext4/extents.c`, `fs/ext4/ialloc.c`
- **Hands-on:** Use `filefrag` to check extent allocation
- **Goal:** Understand extent tree and why delayed allocation reduces fragmentation

### Day 21 — XFS or Btrfs Deep Dive
- **Pick one:**
  - **XFS:** `fs/xfs/xfs_alloc.c`, AG model, B+tree allocator, log design
  - **Btrfs:** `fs/btrfs/ctree.c`, CoW B-tree, snapshots, checksums, send/receive
- **Hands-on:** Create filesystem, run `xfs_info`/`btrfs fi show`, test snapshots
- **Goal:** Understand one advanced filesystem's core design in depth

---

## Week 4: Modern I/O, Caching & Advanced Topics

### Day 22 — NVMe Driver
- **Read:** `drivers/nvme/host/core.c`, `pci.c` — queue setup, command submission
- **Hands-on:** `nvme list`, `nvme smart-log`, explore `/sys/class/nvme/`
- **Goal:** Understand NVMe queue pairs and command lifecycle

### Day 23 — io_uring
- **Read:** `io_uring/io_uring.c` — SQ/CQ rings, `io_submit_sqes()`
- **Hands-on:** Write a simple `io_uring` read program using `liburing`
- **Goal:** Understand submission/completion ring mechanism

### Day 24 — Direct I/O
- **Read:** `fs/direct-io.c`, `iomap` direct I/O path
- **Hands-on:** Benchmark `O_DIRECT` vs buffered with `fio`
- **Goal:** Understand when and why to bypass the page cache

### Day 25 — bcache
- **Read:** `drivers/md/bcache/super.c`, `request.c`, `writeback.c`
- **Hands-on:** Set up bcache: SSD cache + HDD backing, test sequential/random
- **Goal:** Understand cache set registration, lookup, and writeback policy

### Day 26 — Zoned Devices & ZNS
- **Read:** `Documentation/block/zoned-blockdevices.rst`, `block/blk-zoned.c`
- **Hands-on:** Use `null_blk` with zoned mode, test with `zonefs`
- **Goal:** Understand zone types, write pointer, and zone append

### Day 27 — cgroup I/O Control
- **Read:** `block/blk-cgroup.c`, `block/blk-throttle.c`, `block/blk-iolatency.c`
- **Hands-on:** Set up `io.max` / `io.latency` in cgroup v2
- **Goal:** Understand I/O weight, bandwidth throttling, and latency targets

### Day 28 — Inline Encryption
- **Read:** `block/blk-crypto.c`, `block/blk-crypto-profile.c`
- **Hands-on:** Study fscrypt + blk-crypto integration
- **Goal:** Understand hardware vs software crypto fallback in the block layer

### Day 29 — Performance Tuning Lab
- **Study:** Integrate all knowledge — tune a real workload (database or build)
- **Hands-on:** Full stack tuning: scheduler, queue depth, readahead, mount opts, cgroup
- **Goal:** Demonstrate measurable performance improvement with tuning

### Day 30 — Final Review & Roadmap
- **Review:** All modules, identify weak areas, plan next 30 days
- **Hands-on:** Draw complete storage stack diagram; write a summary document
- **Goal:** Articulate the full Linux storage stack from syscall to hardware

---

## Daily Study Structure

```
Each Day (~2-3 hours)

[30 min]  Read kernel source / docs
[30 min]  Trace code path with ftrace or read LWN article
[60 min]  Hands-on lab exercise
[15 min]  Write notes / diagram
[15 min]  Review previous day's notes
```

## Weekly Milestones

| Week | You Should Be Able To |
|------|----------------------|
| 1 | Trace a `read()` from syscall through VFS -> page cache -> block layer |
| 2 | Explain bio -> request -> dispatch, switch/tune I/O schedulers, use blktrace |
| 3 | Set up device mapper targets, explain ext4 journaling/extents, create RAID |
| 4 | Use io_uring, set up bcache, tune a full storage stack for a workload |

## Tools to Install

```bash
# tracing & profiling
apt install linux-tools-common bpfcc-tools bpftrace blktrace

# storage utilities
apt install fio nvme-cli mdadm lvm2 cryptsetup thin-provisioning-tools

# filesystem tools
apt install e2fsprogs xfsprogs btrfs-progs f2fs-tools

# development
apt install liburing-dev
```

## Key References

- **"Understanding the Linux Kernel"** — Bovet & Cesati
- **"Linux Kernel Development"** — Robert Love
- **"BPF Performance Tools"** — Brendan Gregg
- **LWN.net** — lwn.net (best source for kernel storage evolution)
- **kernel.org docs** — `Documentation/filesystems/`, `Documentation/block/`, `Documentation/admin-guide/device-mapper/`
