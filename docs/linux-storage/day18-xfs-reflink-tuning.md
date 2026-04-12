# Day 18: XFS — Reflink, iomap Layer & Production Tuning

## Learning Objectives
- Understand XFS reflink/CoW fork at source level (`xfs_refcount*.c`)
- Understand the iomap layer and why it replaced direct buffer_head usage
- Know XFS-specific production tuning: mount options, AG sizing, log sizing
- Use `xfs_db` and `xfs_repair` confidently for production diagnosis
- Know the architect-level limits: where XFS struggles

---

## 1. Reflink: Shared Block References

Reflink (reference-counted links) allows multiple files to share the same
physical blocks. Added to XFS in kernel 4.16.

```
Traditional copy (cp file1 file2):
  Read file1 → write new physical blocks → file2 maps to new blocks
  Cost: reads + writes all data; doubled disk usage

Reflink copy (cp --reflink file1 file2):
  Duplicate extent tree entries pointing to same physical blocks
  Both files share physical blocks (reference counted)
  Cost: metadata operation only (milliseconds regardless of file size)
  Disk usage: not doubled (blocks counted once until modified)
```

### How XFS implements reflink

```c
// fs/xfs/xfs_refcount.c — reference count B-tree

// XFS adds a new per-AG B-tree: refcountbt
// Maps: (agblock, length) → reference_count
// Only blocks with refcount > 1 are tracked

// cp --reflink path:
xfs_reflink_remap_extent():
    // 1. For each extent in source file:
    //    - Increment refcount in refcountbt
    //    - Add extent to destination file's extent map (same physical block)
    // 2. Update destination inode size
    // No data movement at all
```

### CoW on write to shared block

```
File1 and File2 share block X (refcount=2)

Write to File2 at block X:
  1. Detect block is shared (refcount > 1)
  2. Allocate new block Y (CoW fork allocation)
  3. Copy data from block X to block Y
  4. Write new data to block Y
  5. Update File2's extent map: points to Y instead of X
  6. Decrement refcount of X (now refcount=1, File1 still points to X)
  7. Remove Y from CoW fork, add to data fork
```

```c
// fs/xfs/xfs_iomap.c — CoW path

xfs_iomap_write_allocate():
    if (xfs_iext_lookup_extent(ip, &ip->i_cowfp, ...)):
        // extent is in CoW fork — already have a CoW allocation
        // use it
    else:
        // need to CoW this block
        xfs_reflink_allocate_cow():
            // allocate new blocks in CoW fork
            // mark as "needs copy" — copy happens at writeback
```

```bash
# Demonstrate reflink
mkfs.xfs /dev/nvme0n1   # must be XFS
mount /dev/nvme0n1 /mnt/xfs

# Create 1GB source file
dd if=/dev/urandom of=/mnt/xfs/source.img bs=1M count=1024

# Reflink copy (instant, regardless of size)
time cp --reflink=always /mnt/xfs/source.img /mnt/xfs/copy.img
# Should complete in <1 second

# Check disk usage — blocks shared, not doubled
du -sh /mnt/xfs/source.img /mnt/xfs/copy.img
df /mnt/xfs   # filesystem usage not doubled

# Verify reflink is active
xfs_bmap -v /mnt/xfs/source.img | head -5
xfs_bmap -v /mnt/xfs/copy.img | head -5
# Same physical block numbers = reflinked

# Modify copy — triggers CoW
echo "modified" >> /mnt/xfs/copy.img
xfs_bmap -v /mnt/xfs/copy.img | tail -5
# Last extent now has different physical block = CoW happened
```

---

## 2. The iomap Layer

iomap is a generic I/O mapping layer (kernel 4.8+) that XFS pioneered and
that has since been adopted by other filesystems.

```
Traditional filesystem I/O path (buffer_head based):
  VFS → filesystem → buffer_head per 512-byte block → block layer
  Problem: buffer_head is tied to block size, not page size
           overhead for large I/O (many buffer_heads per page)

iomap path (XFS, ext4 newer code, btrfs):
  VFS → iomap_ops → iomap (describes range of file: offset + length + physical block)
      → generic iomap code handles page cache, direct I/O, DAX
  Benefit: works at arbitrary granularity; shared across filesystems
```

```c
// include/linux/iomap.h

struct iomap {
    u64             addr;       // disk address (physical block, in bytes)
    loff_t          offset;     // file offset (bytes)
    u64             length;     // length of this mapping (bytes)
    u16             type;       // IOMAP_HOLE, IOMAP_DELALLOC, IOMAP_MAPPED,
                                // IOMAP_UNWRITTEN, IOMAP_INLINE
    u16             flags;      // IOMAP_F_NEW, IOMAP_F_DIRTY, IOMAP_F_SHARED
    struct block_device *bdev;
    // ...
};

// XFS implements:
const struct iomap_ops xfs_iomap_ops = {
    .iomap_begin    = xfs_iomap_begin,   // map file offset → disk block
    .iomap_end      = xfs_iomap_end,     // finalize after I/O (CoW completion, etc.)
};
```

**iomap types architects need to know:**

| Type | Meaning | Action on read | Action on write |
|------|---------|----------------|-----------------|
| `IOMAP_HOLE` | No block allocated | Return zeros | Allocate block |
| `IOMAP_DELALLOC` | Space reserved, no block yet | Shouldn't happen (writeback only) | Use reservation |
| `IOMAP_MAPPED` | Block allocated and written | Read from disk | Write to disk |
| `IOMAP_UNWRITTEN` | Block allocated but not yet written | Return zeros | Write + convert to mapped |
| `IOMAP_INLINE` | Data stored in inode | Read from inode | Write to inode |

---

## 3. Production Tuning: Mount Options

```bash
# Key XFS mount options for production

# noatime: don't update access time on read (significant overhead on metadata-heavy workloads)
mount -o noatime /dev/nvme0n1 /mnt/xfs

# logbufs / logbsize: tune log buffer count and size
# More/larger buffers = better log write batching
mount -o logbufs=8,logbsize=256k /dev/nvme0n1 /mnt/xfs

# allocsize: initial speculative preallocation hint
# Large = less fragmentation for streaming writes; too large = wasted space on near-full FS
mount -o allocsize=256k /dev/nvme0n1 /mnt/xfs

# largeio: hint to use large I/O for better performance on large files
mount -o largeio /dev/nvme0n1 /mnt/xfs

# discard / nodiscard: TRIM on SSD
# discard: synchronous trim (bad for performance — use fstrim cron instead)
# nodiscard (default) + weekly fstrim: better
mount -o nodiscard /dev/nvme0n1 /mnt/xfs
# Weekly: fstrim /mnt/xfs

# For databases (no atime, direct I/O preferred):
mount -o noatime,nodiscard,logbufs=8,logbsize=256k /dev/nvme0n1 /mnt/db
```

---

## 4. AG Sizing and Count

```bash
# AG size affects parallelism and B-tree depth
# Default: XFS tries to have ~8 AGs, each ≤1TB

# More AGs = more parallelism (up to # CPUs)
# Fewer, larger AGs = deeper B-trees (slightly slower lookup)
# Too many AGs = wasted space in small AG headers

# For a 10TB filesystem on 16-core server:
mkfs.xfs -d agcount=16 /dev/nvme0n1
# 16 AGs ≈ one per CPU core — maximum parallelism

# For a 100TB filesystem:
mkfs.xfs -d agsize=4g /dev/nvme0n1
# 4GB AG size = ~25 AGs for 100TB
# Balance: enough AGs for parallelism, not so many that headers dominate

# Check effective AG count and size
xfs_info /mnt/xfs | grep agcount
```

---

## 5. `xfs_repair`: Understanding What It Does

```bash
# xfs_repair is SLOW on large filesystems — plan for it

# Phase 1: Find and validate superblock
# Phase 2: Scan AG headers and free space B-trees
# Phase 3: Scan inode list (ALL inodes)
# Phase 4: Check inode data and attribute forks
# Phase 5: Check directory tree
# Phase 6: Check link counts
# Phase 7: Check quotas

# On a 100TB XFS filesystem: xfs_repair can take 24+ hours
# This is the main operational disadvantage vs ext4's e2fsck

# Dry run first (no changes):
xfs_repair -n /dev/nvme0n1

# Full repair (filesystem must be unmounted):
xfs_repair /dev/nvme0n1

# Speed up repair on large filesystems:
# More memory = larger inode chunk cache = faster phase 3+
xfs_repair -o ag_stride=32 /dev/nvme0n1  # parallel AG processing

# After unclean shutdown: try mount first (log replay)
# Only run xfs_repair if mount fails
mount /dev/nvme0n1 /mnt/xfs   # log replay happens automatically
# If mount fails with "structure needs cleaning" → then run xfs_repair
```

---

## 6. XFS Quotas

```bash
# XFS has first-class quota support (more robust than ext4)
# Quotas stored in dedicated quota inodes, not fragile quota files

# Enable at mkfs time (cannot add after)
mkfs.xfs -m crc=1 /dev/nvme0n1
mount -o uquota,gquota /dev/nvme0n1 /mnt/xfs  # user + group quotas
# Or: pquota (project quotas — useful for directory trees)

mount -o pquota /dev/nvme0n1 /mnt/xfs
xfs_quota -x -c "project -s -p /mnt/xfs/projectdir 42" /mnt/xfs
xfs_quota -x -c "limit -p bhard=100g 42" /mnt/xfs
# Now /mnt/xfs/projectdir is limited to 100GB regardless of which user writes there
```

---

## 7. Production Diagnosis Workflow

```bash
# Symptom: filesystem operations slow or stalling

# Step 1: Check if it's log-related
dmesg | grep -i "xfs" | tail -20
# Look for: "xfs_log_force" / "log head/tail" warnings

# Step 2: Check fragmentation
xfs_db -r /dev/nvme0n1 -c "freesp -d"
# Many small free extents = fragmented; impacts allocation performance

# Step 3: Check for stuck transactions
cat /proc/fs/xfs/stat | grep -E "trans|log"

# Step 4: Online defragmentation (if fragmented)
xfs_fsr /mnt/xfs        # defragment all files
xfs_fsr /mnt/xfs/bigfile  # defragment specific file

# Step 5: Check inode count limits
xfs_info /mnt/xfs | grep "imaxpct"
# imaxpct=25 means max 25% of filesystem blocks used for inodes
# On small filesystems with many files, this can be a limit

# Increase inode percentage (cannot do online — requires mkfs with -m inode64)
mkfs.xfs -m inode64 /dev/nvme0n1  # use 64-bit inode addresses
```

---

## 8. XFS Limits Architects Must Know

```
Maximum filesystem size:    8 exabytes (theoretical), ~16TB practical on 32-bit systems
                            Use -m inode64 for >16TB or many-inode workloads

Maximum file size:          8 exabytes

Maximum directory entries:  ~2 billion (B-tree directory)

Minimum AG size:            16MB (rarely relevant)

Maximum AG size:            1TB (hard limit in older kernels; 16TB in newer)

Log size:                   512KB minimum, 128GB maximum
                            Rule of thumb: 512MB–2GB for busy filesystems

xfs_repair time:            Hours to days on petabyte-scale filesystems
                            Plan maintenance windows accordingly

Shrink online:              Not supported (XFS cannot shrink a mounted filesystem)
```

---

## 9. Self-Check Questions

1. What is the difference between a reflink copy and a hard link in XFS?
2. When a process writes to a reflinked file's shared block, what exactly happens at the block layer?
3. What is `IOMAP_UNWRITTEN` and when does it appear?
4. Why does `xfs_repair` take much longer than `e2fsck` on equivalent-sized filesystems?
5. A 50TB XFS filesystem is showing slow file creation performance. You suspect AG contention. How do you diagnose and what would you change?
6. You need per-directory disk space limits on XFS (e.g., each customer's data directory limited to 1TB). What XFS mechanism handles this and how is it configured?

## 10. Answers

1. Hard link: multiple directory entries pointing to the same inode — same file, same data, same metadata (size, timestamps). Reflink: separate inodes (different files, different metadata) sharing physical data blocks via the refcount B-tree. Hard links can't cross directories or filesystems; reflinks are within one XFS filesystem but are separate files.
2. XFS detects the block is shared (refcount > 1 in refcountbt). It allocates a new block in the CoW fork, copies the old data to the new block, applies the write, then atomically updates the extent map to point to the new block and decrements the old block's refcount.
3. `IOMAP_UNWRITTEN` represents a block that has been allocated (physical space reserved) but not yet written. XFS uses this for speculative preallocation and for blocks allocated but pending first write. Reads return zeros; on write completion, the extent is converted to `IOMAP_MAPPED`.
4. xfs_repair processes metadata differently from e2fsck: it must reconstruct the inode B-tree by scanning all AG inode chunks, verify all extent maps, and check directory consistency — all without the summary data that e2fsck can use. On large filesystems, the inode scan (Phase 3) alone can take hours. e2fsck uses block group bitmaps as checkpoints; XFS has no equivalent shortcut.
5. Diagnosis: `perf stat -e 'xfs:*' -a sleep 10` or `bpftrace -e 'tracepoint:xfs:xfs_ialloc_ag_select { @[args->agno] = count(); } interval:s:5 { print(@); }'` to see if allocations concentrate in one AG. Also `xfs_db -c "agi N" -c "print"` for each AG to check free inode counts. Fix: increase AG count at mkfs time (cannot change online) — if the filesystem is new enough to recreate, use `agcount=N` where N ≥ CPU count. Short-term: check if `inode32` mount option is forcing inode allocation into lower AGs — switch to `inode64`.
6. XFS project quotas (`pquota`). Configure: (1) mount with `-o pquota`; (2) assign a project ID to the directory tree with `xfs_quota -x -c "project -s -p /path 42"`; (3) set limit with `xfs_quota -x -c "limit -p bhard=1t 42"`. Project quotas track all blocks under a directory tree regardless of which user owns them.

---

## Tomorrow: Day 19 — ext4: JBD2 Crash Recovery (Targeted)

One focused day on what JBD2 actually guarantees — ordered vs writeback
vs journal mode tradeoffs at the architect level.
