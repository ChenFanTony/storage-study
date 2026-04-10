# Day 1: Linux Storage Stack Overview

## Learning Objectives
- Understand the complete I/O path from user space to hardware
- Identify the key abstractions at each layer
- Know the source file locations for each component
- Be able to trace a read() syscall through the stack

---

## 1. The Big Picture: Linux I/O Path

When a user-space application calls `read()` or `write()`, the request travels through
multiple kernel layers before reaching the physical storage device:

```
┌─────────────────────────────────────────────────────────┐
│                    USER SPACE                           │
│  Application calls read(fd, buf, count)                 │
└────────────────────────┬────────────────────────────────┘
                         │ syscall
                         ▼
┌─────────────────────────────────────────────────────────┐
│              SYSTEM CALL INTERFACE                      │
│  ksys_read() → vfs_read()                              │
│  Source: fs/read_write.c:554                            │
└────────────────────────┬────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────┐
│           VIRTUAL FILESYSTEM (VFS)                      │
│  file->f_op->read_iter() or file->f_op->read()         │
│  Path lookup: namei.c                                   │
│  Dentry cache: dcache.c                                 │
│  Key structs: super_block, inode, dentry, file          │
│  Source: fs/*.c, include/linux/fs.h                     │
└────────────────────────┬────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────┐
│              PAGE CACHE                                 │
│  Check if data is already cached in memory              │
│  filemap_read() → filemap_get_pages()                   │
│  If cache hit → copy to user buffer, DONE               │
│  If cache miss → trigger readahead + block I/O          │
│  Source: mm/filemap.c, mm/readahead.c                   │
└────────────────────────┬────────────────────────────────┘
                         │ cache miss
                         ▼
┌─────────────────────────────────────────────────────────┐
│             FILESYSTEM LAYER                            │
│  ext4_readahead() / xfs_vm_readahead() / ...            │
│  Maps file offset → disk block number (extent tree)     │
│  Creates bio structures                                 │
│  Source: fs/ext4/, fs/xfs/, fs/btrfs/, etc.             │
└────────────────────────┬────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────┐
│               BLOCK LAYER                               │
│  submit_bio() → bio merging → request creation          │
│  I/O scheduler: mq-deadline, bfq, kyber, none           │
│  Multi-queue (blk-mq): software queues → hardware queues│
│  Key structs: bio, request, request_queue, gendisk      │
│  Source: block/blk-core.c, block/blk-mq.c, block/bio.c │
└────────────────────────┬────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────┐
│             DEVICE DRIVER                               │
│  NVMe: drivers/nvme/host/pci.c                          │
│  SCSI/SATA: drivers/scsi/                               │
│  Virtio-blk: drivers/block/virtio_blk.c                 │
│  Device mapper: drivers/md/dm.c                         │
│  Sends commands to hardware controller                  │
└────────────────────────┬────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────┐
│               HARDWARE                                  │
│  NVMe SSD, SATA SSD/HDD, SCSI disk, etc.               │
│  DMA transfer → data arrives in memory                  │
│  Interrupt → completion callback up the stack           │
└─────────────────────────────────────────────────────────┘
```

---

## 2. Key Abstractions at Each Layer

### 2.1 VFS Layer Abstractions

The VFS provides a uniform interface for all filesystems. Four core objects:

| Structure | Purpose | Defined in |
|-----------|---------|------------|
| `struct super_block` | Represents a mounted filesystem instance | `include/linux/fs.h` |
| `struct inode` | Represents a file on disk (metadata: permissions, size, block map) | `include/linux/fs.h` |
| `struct dentry` | Represents a directory entry (name → inode mapping), cached in dcache | `include/linux/dcache.h` |
| `struct file` | Represents an open file (per-process, tracks position, flags) | `include/linux/fs.h` |

**Operations tables** — each filesystem registers callback functions:
- `struct file_operations` — `read`, `write`, `mmap`, `fsync`, `llseek`, ...
- `struct inode_operations` — `create`, `lookup`, `mkdir`, `rename`, ...
- `struct super_operations` — `alloc_inode`, `write_inode`, `sync_fs`, ...
- `struct address_space_operations` — `read_folio`, `writepages`, `dirty_folio`, ...

### 2.2 Page Cache

The page cache sits between VFS and the block layer:
- Every `inode` has an `address_space` (`i_mapping`) that manages cached pages/folios
- `filemap_read()` checks the page cache first
- On miss, the filesystem's `address_space_operations->read_folio()` is called
- Dirty pages are written back by flusher threads (`fs/fs-writeback.c`)

### 2.3 Block Layer Abstractions

| Structure | Purpose | Defined in |
|-----------|---------|------------|
| `struct bio` | A single I/O operation: device + sector range + memory pages (bio_vec) | `include/linux/blk_types.h` |
| `struct bio_vec` | A segment: page + offset + length | `include/linux/bvec.h` |
| `struct request` | One or more merged bios, ready for the driver | `include/linux/blk-mq.h` |
| `struct gendisk` | Represents a physical/virtual disk | `include/linux/blkdev.h` |
| `struct request_queue` | Per-device queue holding pending requests | `include/linux/blkdev.h` |
| `struct blk_mq_hw_ctx` | Hardware dispatch queue (maps to device submission queue) | `include/linux/blk-mq.h` |
| `struct blk_mq_ctx` | Software staging queue (per-CPU) | `block/blk-mq.h` |

**The bio lifecycle:**
```
bio_alloc()           → allocate bio
bio_set_dev()         → set target block device
bio->bi_iter.bi_sector = ...  → set starting sector
bio_add_page()        → add memory pages (bio_vecs)
submit_bio()          → submit to block layer
  → blk-mq merges/schedules → creates request
  → dispatches to hardware queue
  → driver processes request
  → bio->bi_end_io() callback on completion
```

---

## 3. Tracing a read() Syscall — Source Code Walkthrough

### Step 1: System call entry
```
fs/read_write.c:700   SYSCALL_DEFINE3(read, ...)
  → ksys_read(fd, buf, count)
    → fdget_pos(fd)                    // get struct file from fd table
    → vfs_read(file, buf, count, pos)  // enter VFS
```

### Step 2: VFS dispatch (fs/read_write.c:554)
```c
ssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)
{
    // Permission checks...
    ret = rw_verify_area(READ, file, pos, count);

    if (file->f_op->read)
        ret = file->f_op->read(file, buf, count, pos);     // legacy
    else if (file->f_op->read_iter)
        ret = new_sync_read(file, buf, count, pos);         // modern path
}
```
Most modern filesystems use `read_iter`. `new_sync_read()` wraps the call with a `kiocb` + `iov_iter`.

### Step 3: Filesystem read_iter → page cache
For ext4: `ext4_file_read_iter()` → `generic_file_read_iter()` → `filemap_read()`
```
mm/filemap.c: filemap_read()
  → filemap_get_pages()    // look up page cache
  → if not found: readahead / read_folio
  → copy_folio_to_iter()   // copy data to user buffer
```

### Step 4: Page cache miss → block I/O
```
mm/readahead.c: page_cache_ra_unbounded()
  → aops->readahead(rac)   // filesystem callback
  → e.g. ext4_readahead() builds bios
  → submit_bio(bio)
```

### Step 5: Block layer processing (block/blk-core.c)
```c
void submit_bio(struct bio *bio)
{
    // ... accounting, cgroup throttle ...
    __submit_bio(bio)
      → __submit_bio_noacct(bio)  // stacking (dm, md) may remap
      → __submit_bio_noacct_mq(bio)  // enter blk-mq
        → blk_mq_submit_bio(bio)
```

### Step 6: blk-mq processing (block/blk-mq.c)
```
blk_mq_submit_bio(bio)
  → attempt merge with existing request (blk_mq_bio_to_request or merge)
  → if no merge: allocate new request from tag set
  → I/O scheduler may reorder (mq-deadline, bfq, etc.)
  → blk_mq_run_hw_queue() → dispatch to hardware
  → driver's queue_rq callback invoked
```

### Step 7: Device driver → hardware
For NVMe:
```
drivers/nvme/host/pci.c: nvme_queue_rq()
  → build NVMe command
  → write to submission queue doorbell
  → DMA transfer happens
  → interrupt on completion
  → nvme_irq() → nvme_handle_cqe() → blk_mq_complete_request()
```

### Step 8: Completion path (bottom-up)
```
blk_mq_complete_request()
  → blk_mq_end_request()
    → bio->bi_end_io(bio)
      → end_bio_bh_io_sync() or similar
        → unlock page → wake up waiting process
          → filemap_read() continues → copies data to user
            → syscall returns bytes read
```

---

## 4. Hands-On Exercises

### Exercise 1: Explore /sys/block
```bash
# List all block devices
lsblk

# Examine a specific device
ls /sys/block/sda/        # or nvme0n1
cat /sys/block/sda/queue/scheduler
cat /sys/block/sda/queue/nr_requests
cat /sys/block/sda/queue/read_ahead_kb
cat /sys/block/sda/stat
```

### Exercise 2: Read /proc/diskstats
```bash
# Fields: major minor name reads_completed reads_merged
#         sectors_read ms_reading writes_completed writes_merged
#         sectors_written ms_writing ios_in_progress ms_io weighted_ms_io
cat /proc/diskstats

# Watch I/O activity in real-time
watch -n1 cat /proc/diskstats
```

### Exercise 3: Trace a read() with strace
```bash
# Trace file I/O of a dd command
strace -e trace=read,write,openat dd if=/dev/zero of=/tmp/test bs=4k count=1000

# See the syscall numbers and return values
strace -T -e trace=read cat /etc/hostname
```

### Exercise 4: Trace with ftrace
```bash
# Enable function tracing for the VFS read path
cd /sys/kernel/debug/tracing
echo 0 > tracing_on
echo function_graph > current_tracer
echo vfs_read > set_graph_function
echo 1 > tracing_on

# Trigger some reads
cat /etc/hostname > /dev/null

# View the trace
echo 0 > tracing_on
cat trace | head -100
```

### Exercise 5: Block layer tracing with blktrace
```bash
# Trace block I/O on sda for 10 seconds
blktrace -d /dev/sda -o - | blkparse -i - | head -50

# Or with bpftrace (simpler)
bpftrace -e 'tracepoint:block:block_rq_issue { printf("%s %d %d\n",
    args.rwbs, args.sector, args.nr_sector); }'
```

### Exercise 6: Check device queue configuration
```bash
# List all block devices and their schedulers
for dev in /sys/block/*/queue/scheduler; do
    echo "$dev: $(cat $dev)"
done

# Check multi-queue topology
ls /sys/block/nvme0n1/mq/    # one directory per hardware queue
```

---

## 5. Key Source Files Reference

| Component | Key Files |
|-----------|----------|
| Syscall entry | `fs/read_write.c` — `vfs_read()`, `vfs_write()`, `ksys_read()` |
| VFS core | `include/linux/fs.h` — all VFS structures |
| Path lookup | `fs/namei.c` — `path_lookupat()`, `walk_component()` |
| Dentry cache | `fs/dcache.c` — `d_lookup()`, `d_alloc()` |
| Page cache | `mm/filemap.c` — `filemap_read()`, `filemap_get_pages()` |
| Readahead | `mm/readahead.c` — `page_cache_ra_unbounded()` |
| Bio | `include/linux/blk_types.h` — `struct bio`; `block/bio.c` |
| Block core | `block/blk-core.c` — `submit_bio()` |
| blk-mq | `block/blk-mq.c` — `blk_mq_submit_bio()`, `blk_mq_run_hw_queue()` |
| Gendisk | `include/linux/blkdev.h` — `struct gendisk`, `struct request_queue` |
| Request | `include/linux/blk-mq.h` — `struct request` |
| I/O schedulers | `block/mq-deadline.c`, `block/bfq-iosched.c`, `block/kyber-iosched.c` |
| NVMe driver | `drivers/nvme/host/core.c`, `drivers/nvme/host/pci.c` |

---

## 6. Key Concepts to Remember

1. **VFS is the switchboard** — it dispatches to the correct filesystem via function pointer tables
2. **Page cache is the fast path** — most reads are served from memory without touching the block layer
3. **bio is the fundamental I/O unit** — it represents a single I/O request (sector range + memory pages)
4. **Requests are merged bios** — the block layer combines adjacent bios for efficiency
5. **blk-mq provides parallelism** — per-CPU software queues feed into per-hardware-context dispatch queues
6. **Completion is asynchronous** — hardware interrupts trigger callbacks that unblock waiting processes

---

## 7. Self-Check Questions

1. What happens when you call `read()` and the data is already in the page cache?
2. What is the difference between `struct bio` and `struct request`?
3. Why does the block layer merge bios into requests?
4. What is the role of `address_space_operations->read_folio()`?
5. How many software queues does blk-mq create? How many hardware queues?
6. What function does a filesystem call to submit I/O to the block layer?
7. What is the completion callback mechanism for bio?

## 8. Tomorrow's Preview: Day 2 — VFS Core Structures

We'll deep-dive into `struct super_block`, `struct inode`, `struct dentry`, and `struct file`.
We'll read `include/linux/fs.h` and trace how `open()` populates these structures.
