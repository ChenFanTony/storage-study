# Day 17: XFS — AG Model, Log Design & Allocator

## Learning Objectives
- Understand XFS's Allocation Group model and why it enables parallel metadata operations
- Follow the XFS log (journal) design: how it differs from JBD2 and why it matters
- Read `xfs_alloc.c` B-tree allocator and understand the two allocation strategies
- Use `xfs_info`, `xfs_db`, `xfs_logprint` to inspect live and offline filesystems
- Know the architect-level implications: when XFS wins and where it has limits

---

## 1. Why XFS Dominates Production Linux Storage

Before reading source, understand the design goals XFS was built around (1993, SGI):

- **Massive files** (terabyte-scale when ext2 topped out at gigabytes)
- **Parallel metadata** (multiple processes creating files simultaneously)
- **Online growing** (expand filesystem while mounted)
- **Journaling** (before Linux had any journaled filesystem)

These goals drove every architectural decision. Understanding them makes
the source code obvious rather than arbitrary.

---

## 2. Allocation Groups: The Core Parallelism Mechanism

XFS divides the filesystem into fixed-size **Allocation Groups** (AGs).
Each AG is an independent sub-filesystem with its own:

```
Per-AG structures:
  ├── AGF (AG Free space header)     — tracks free blocks
  ├── AGI (AG Inode header)          — tracks inode allocation
  ├── AGFL (AG Free List)            — small reserve for btree splits
  └── B-trees:
       ├── bnobt  — free space indexed by block number (for locality)
       ├── cntbt  — free space indexed by count (for best-fit allocation)
       ├── inobt  — inode B-tree (tracks allocated inodes)
       └── finobt — free inode B-tree (tracks inodes with free slots)
```

```bash
# Inspect AG layout
xfs_info /dev/nvme0n1
# Key output:
# data     =              bsize=4096   blocks=...  imaxpct=25
#          =              sunit=0      swidth=0 blks
# naming   =version 2     bsize=4096   ascii-ci=0, ftype=1
# log      =internal log  bsize=4096   blocks=...  version=2
# agcount=16, agsize=...blks    ← number and size of AGs

# Check individual AG
xfs_db -r /dev/nvme0n1 -c "agf 0" -c "print"
xfs_db -r /dev/nvme0n1 -c "agi 0" -c "print"
```

**Why AGs enable parallelism:**
```
Without AGs (ext4 with single global lock):
  Process A allocates file → holds global lock
  Process B allocates file → waits
  → serialized metadata operations

With AGs (XFS):
  Process A allocates file → locks AG 0
  Process B allocates file → locks AG 7 (different AG)
  → truly parallel metadata operations
  → scales with CPU count for metadata-heavy workloads
```

This is why XFS outperforms ext4 on workloads like:
- `git clone` of large repos (many small file creates)
- Container image unpacking
- Build systems (`make -j48`)
- Mail servers (millions of small files)

---

## 3. XFS Allocation Strategies

XFS uses two B-trees per AG for free space, enabling two distinct strategies:

```c
// fs/xfs/xfs_alloc.c

// Strategy 1: Near allocation (bnobt — by block number)
// Goal: allocate blocks physically close to a given target block
// Use: extend existing file (keep file contiguous)
xfs_alloc_ag_vextent_near():
    // Search bnobt for free extent near target block
    // Try to match exactly, then look left/right of target
    // → spatial locality for sequential reads

// Strategy 2: Size allocation (cntbt — by count)
// Goal: find a free extent of exactly the right size
// Use: new file allocation, where we want a good fit
xfs_alloc_ag_vextent_size():
    // Search cntbt for smallest extent >= requested size
    // → prevents fragmentation from large extents being split unnecessarily
```

```bash
# Check free space fragmentation (many small extents = fragmented)
xfs_db -r /dev/nvme0n1 -c "freesp -d"
# Shows histogram of free extent sizes
# Healthy: most free space in large extents
# Fragmented: many tiny extents

# Check file fragmentation
xfs_bmap -v /path/to/large/file | head -20
# Shows extent map: each line is a contiguous extent
# Few extents = good; many short extents = fragmented
```

---

## 4. XFS Log: Architecture and Design

XFS's log is fundamentally different from ext4's JBD2. Understanding this
difference is critical for production architecture decisions.

### JBD2 (ext4): Block-based journaling
```
JBD2 journals entire blocks:
  Before modifying block B:
    1. Write block B (old version) to journal
    2. Modify block B in memory
    3. Commit: write journal commit record
    4. Later: write modified block B to its real location

Cost: journal writes are entire block copies
Benefit: simple, proven, low overhead for small metadata changes
Problem: large metadata changes journal many full blocks
```

### XFS Log: Logical (intent) logging
```
XFS journals logical operations, not block copies:
  Before allocating block for inode:
    1. Write log record: "allocate block X for inode Y" (small, ~100 bytes)
    2. Perform the allocation in memory
    3. Commit log record

Cost: log writes are small operation descriptions
Benefit: much less log I/O for complex metadata operations
Trade-off: recovery requires replaying operations (more complex than block replay)
```

```c
// fs/xfs/xfs_log.c — the XFS log subsystem

// Log is a circular ring buffer on disk
struct xlog {
    struct xfs_mount    *l_mp;          // filesystem mount
    struct xlog_in_core *l_iclog;       // in-core log buffers
    int                 l_iclog_size;   // size of each in-core buffer
    int                 l_iclog_bufs;   // number of in-core buffers

    xfs_lsn_t           l_tail_lsn;    // oldest committed LSN still needed
    xfs_lsn_t           l_last_sync_lsn; // last flushed LSN
    // ...
};

// Transaction commit path:
xfs_trans_commit():
    xfs_log_commit_cil():
        // CIL = Committed Item Log
        // Collect all dirty log items from this transaction
        // Write to CIL (in-memory staging area)
        // Periodically flush CIL to on-disk log
```

### CIL (Committed Item Log): XFS's key innovation

```
Traditional log commit: write to disk immediately (synchronous)
XFS CIL: batch multiple commits in memory, flush periodically

CIL flow:
  Transaction 1 commits → CIL buffer (not yet on disk)
  Transaction 2 commits → CIL buffer
  ...
  Transaction N commits → CIL buffer
  CIL checkpoint: write all N transactions to log in one I/O
  
Benefit: dramatically reduces log I/O for metadata-heavy workloads
         (N transactions → 1 log I/O instead of N log I/Os)
Risk: transactions 1..N are not durable until CIL checkpoint
      (same guarantee as any async commit — mitigated by fsync)
```

---

## 5. XFS Log Sizing

Log size directly affects metadata throughput and recovery time.

```bash
# Check log size
xfs_info /dev/nvme0n1 | grep "log"
# log =internal log  bsize=4096   blocks=32768   (= 128MB internal log)

# For high-throughput metadata workloads: larger log = better
# Maximum log size: 128GB
# Recommended: 512MB–2GB for busy filesystems

# Set log size at mkfs time:
mkfs.xfs -l size=2g /dev/nvme0n1

# External log on fast device (recommended for write-heavy workloads):
mkfs.xfs -l logdev=/dev/nvme0n2,size=2g /dev/nvme0n1
# External log on NVMe = log writes don't compete with data I/O
```

**Log exhaustion is a real production problem:**
```
Symptom: filesystem operations stall (appear hung)
Cause: log is full — all log space is used by uncommitted transactions
       waiting for checkpoint to free space
Diagnosis:
  xfs_logprint -t /dev/nvme0n1 | tail -20  # check log state
  dmesg | grep -i "xfs.*log"               # look for log errors

Prevention:
  - Larger log (primary fix)
  - External log on separate fast device
  - Avoid holding transactions open too long (application bug)
```

---

## 6. Delayed Allocation

XFS delays physical block allocation until data is actually written to disk:

```
Without delalloc (ext2 style):
  write() → allocate physical blocks immediately → assign to file
  Problem: many small writes → many small allocations → fragmentation

With delalloc (XFS):
  write() → mark pages dirty, record "pending allocation" (no physical blocks yet)
  writeback() → now allocate physical blocks in one operation
             → allocate contiguous extent for all pending dirty pages
             → single large extent instead of many small ones
  
Result: dramatically better allocation for streaming writes
        files written sequentially get contiguous extents
```

```bash
# See delalloc in action
# Write a 1GB file and check fragmentation
dd if=/dev/zero of=/mnt/xfs/testfile bs=1M count=1024
xfs_bmap -v /mnt/xfs/testfile
# Should show: 1 extent (contiguous) for a single dd write

# Compare with O_SYNC (forces immediate allocation)
dd if=/dev/zero of=/mnt/xfs/testfile_sync bs=1M count=1024 oflag=sync
xfs_bmap -v /mnt/xfs/testfile_sync
# May show more extents (less coalescing opportunity)
```

---

## 7. Speculative Preallocation

For files being actively written, XFS pre-allocates more space than requested
to avoid repeated allocation calls:

```c
// fs/xfs/xfs_iomap.c
xfs_iomap_write_delay():
    // Calculate speculative preallocation size:
    // Starts at 64KB, grows to match allocation patterns
    // Capped at xfs_inode_is_filestream() limit or max_extsize

    // Unwritten extent: allocated but not yet written
    // Shows as 'u' in xfs_bmap output
```

```bash
# See unwritten (speculatively allocated) extents
xfs_bmap -v /path/to/growing/file
# 'u' flag = unwritten (preallocated but not yet written)
# These are converted to 'written' as data is written

# Control preallocation behavior
# Large speculative preallocation can waste space on nearly-full filesystems
# Reduce with:
mount -o allocsize=64k /dev/nvme0n1 /mnt/xfs
# allocsize= controls initial speculative preallocation hint
```

---

## 8. Hands-On: XFS Inspection

```bash
# 1. Create XFS filesystem with explicit AG count
mkfs.xfs -d agcount=8 /dev/nvme0n1
mount /dev/nvme0n1 /mnt/xfs

# 2. Inspect AG structure
xfs_info /mnt/xfs

# 3. Observe parallel allocation across AGs
# Create many files simultaneously - watch AG distribution
for i in $(seq 1 32); do
    dd if=/dev/urandom of=/mnt/xfs/file_$i bs=1M count=10 &
done
wait

# Check which AGs files landed in
for i in $(seq 1 10); do
    xfs_bmap /mnt/xfs/file_$i | head -3
done

# 4. Log inspection (offline)
umount /mnt/xfs
xfs_logprint /dev/nvme0n1 | tail -30
# Shows recent log operations

# 5. Free space fragmentation check
xfs_db -r /dev/nvme0n1 -c "freesp -d"

# 6. Check inode distribution across AGs
xfs_db -r /dev/nvme0n1 -c "inode_btree 0" -c "print" 2>/dev/null || \
xfs_db -r /dev/nvme0n1 -c "agi 0" -c "print"

# Remount
mount /dev/nvme0n1 /mnt/xfs
```

---

## 9. XFS vs ext4: Architect's Comparison

| Aspect | XFS | ext4 |
|--------|-----|------|
| Parallel metadata | Yes (per-AG locking) | Limited (global locks) |
| Journal type | Logical (operation-based) | Physical (block-based) |
| Large files | Excellent (extent tree, 64-bit) | Good (extent tree since 4.0) |
| Small files (<64K) | Slightly worse (overhead) | Better |
| Online grow | Yes | Yes (with resize2fs) |
| Online shrink | No | No (neither) |
| Max filesystem | 8 exabytes | 1 exabyte |
| Allocation strategy | Two B-trees (bno + cnt) | Multiblock allocator |
| Delalloc | Yes (aggressive) | Yes |
| Reflink/CoW | Yes (since 4.16) | Yes (since 4.2) |
| Recovery time | Proportional to log size | Proportional to log size |
| fsck (xfs_repair) | Very slow (hours on large FS) | Faster (e2fsck) |

**Choose XFS when:**
- Parallel metadata workloads (containers, git, build systems)
- Large files (video, databases, backups)
- High-throughput sequential I/O
- Need online filesystem grow

**Stick with ext4 when:**
- Many tiny files with simple access patterns
- fsck speed matters (embedded, boot volume)
- Team has more ext4 operational experience

---

## 10. Self-Check Questions

1. Why do multiple AGs allow parallel file creation while ext4 with a single global lock cannot?
2. XFS uses logical logging while JBD2 uses physical (block) logging. What is the key difference in recovery?
3. What is delayed allocation and why does it reduce file fragmentation compared to immediate allocation?
4. What happens when the XFS log fills up and no checkpoint has run?
5. You have a filesystem doing 50K file creates/second. XFS or ext4? Why?
6. An XFS filesystem's log is on the same HDD as data. What performance problem does this cause and how do you fix it?

## 11. Answers

1. Each AG has independent lock. Process A creating a file in AG 0 acquires AG 0's lock. Process B creating a file in AG 4 acquires AG 4's lock. These don't conflict — both proceed simultaneously. With a single global lock, B must wait for A to complete before acquiring the lock.
2. Physical logging (JBD2): recovery replays block images — simple but requires writing large blocks to journal. Logical logging (XFS): recovery replays operation descriptions — smaller journal writes but recovery must understand and re-execute operations.
3. Delayed allocation defers block assignment until writeback. By the time writeback runs, the full extent of the write is known — XFS allocates one contiguous extent for the entire write. Immediate allocation assigns blocks during each `write()` call, leading to many small, non-contiguous allocations.
4. Log full: new transactions cannot commit (no space for new log records). Filesystem operations stall (block in `xfs_log_reserve()`). Background threads try to force a checkpoint to free log space, but if they're blocked by the stalled transactions, the system appears hung. Recovery: nothing to do except wait for checkpoint or remount.
5. XFS — per-AG locking enables parallel inode and directory block allocation. At 50K creates/second with multiple processes, ext4's global inode allocation lock becomes the bottleneck. XFS scales with CPU count for this workload.
6. Log writes compete with data writes on the same HDD heads — log checkpoint I/O causes data write latency spikes and vice versa. Fix: external log on a separate fast device (NVMe partition): `mkfs.xfs -l logdev=/dev/nvme0n1p1 /dev/sda`.

---

## Tomorrow: Day 18 — XFS: Delayed Allocation, Reflink & Speculative Preallocation

Second XFS day: we go deep on the iomap layer, reflink mechanics,
and XFS-specific production tuning for large-scale deployments.
