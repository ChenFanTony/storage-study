# Day 17: XFS Internals Part 1 — Allocation Groups and On-Disk Layout

## Learning Objectives
- Understand XFS's allocation group (AG) model and why it enables parallelism
- Know the on-disk headers (superblock, AGF, AGI, AGFL) and what each contains
- Understand the per-AG B+trees for free space and inode tracking
- Use `xfs_db` and `xfs_info` to inspect a real XFS filesystem
- Know how AG count interacts with workload concurrency

---

## 1. Why XFS Looks Different from ext4

ext4 is essentially a refined ext2/ext3: a single set of global structures
(superblock, block groups, inode bitmaps) with a journal layered on top.
Most metadata operations serialize on shared locks.

XFS was designed at SGI for very large filesystems and high-concurrency
workloads. Its core architectural idea: **partition the filesystem into
independent allocation groups (AGs), each with its own metadata and locks.**
Metadata operations within different AGs proceed in parallel without
contention.

```
XFS filesystem (4TB, default AG size = 1TB):

  AG 0                  AG 1                  AG 2                  AG 3
  ┌──────────┐          ┌──────────┐          ┌──────────┐          ┌──────────┐
  │ SB copy  │          │ SB copy  │          │ SB copy  │          │ SB copy  │
  │ AGF      │          │ AGF      │          │ AGF      │          │ AGF      │
  │ AGI      │          │ AGI      │          │ AGI      │          │ AGI      │
  │ AGFL     │          │ AGFL     │          │ AGFL     │          │ AGFL     │
  │ btrees   │          │ btrees   │          │ btrees   │          │ btrees   │
  │ inodes   │          │ inodes   │          │ inodes   │          │ inodes   │
  │ data     │          │ data     │          │ data     │          │ data     │
  └──────────┘          └──────────┘          └──────────┘          └──────────┘
   ↑ independent: own locks, own free space, own inode tracking
```

Files and directories can span AG boundaries, but allocation decisions
(where to place new data or inodes) are made per-AG. Parallelism comes
from threads operating in different AGs concurrently.

---

## 2. The On-Disk Headers (the "fixed location" metadata)

Each AG starts with four header structures. From the XFS designers' notes:
"the only fixed location metadata is the allocation group headers
(SB, AGF, AGFL and AGI); all other metadata structures need to be
discovered by walking the filesystem."

```
AG layout (first few sectors of each AG):

  Sector 0:  Superblock (XFS_SB_MAGIC = "XFSB")
              - Filesystem-wide info: size, AG count, block size, features
              - AG 0's copy is authoritative; others are mirrors for recovery
  Sector 1:  AGF (XFS_AGF_MAGIC = "XAGF")
              - Free-space tracking for this AG: B+tree roots, free counts
  Sector 2:  AGI (XFS_AGI_MAGIC = "XAGI")
              - Inode tracking for this AG: B+tree roots, inode counts
  Sector 3:  AGFL (XFS_AGFL_MAGIC = "XAFL")
              - Free List: small reserve of blocks for allocator metadata growth
```

If your sector size equals your filesystem block size (both 4K), each header
occupies its own block. With 512-byte sectors and 4K blocks, all four share
the first block.

### Inspect them with xfs_db

```bash
# Look at the primary superblock (on AG 0)
xfs_db -r /dev/sda1 -c "sb 0" -c "p"
# Output: agcount, agblocks, blocksize, inodesize, logstart, features, ...

# Look at AG 0's AGF
xfs_db -r /dev/sda1 -c "agf 0" -c "p"
# Output: freeblks, longest, btreeblks, bnoroot, cntroot, rmaproot, refcntroot, ...

# Look at AG 0's AGI
xfs_db -r /dev/sda1 -c "agi 0" -c "p"
# Output: count (allocated inodes), freecount, root (inobt root), ...

# Look at AG 0's AGFL (the free list)
xfs_db -r /dev/sda1 -c "agfl 0" -c "p"
```

### What the AGF tracks

The AGF is the entry point for free-space management. Two B+trees track
free space within the AG:

- **BNO btree** (by block number) — free extents indexed by their starting block.
  Used when XFS wants to allocate near a specific location (e.g., near a file's
  existing extents).
- **CNT btree** (by extent length) — free extents indexed by size. Used when
  XFS wants the smallest free extent that fits a request (best-fit allocation).

Two trees indexed differently from the same free-space records. This is why
XFS allocation is fast: O(log n) lookup either by location or by size.

Modern XFS (v5 / CRC) adds:
- **RMAP btree** — reverse mapping: "who owns this block?" (used by online repair)
- **REFCNT btree** — reference counts (used for reflink/COW)

### What the AGI tracks

The AGI manages inodes. Inodes are allocated in **chunks of 64**. The B+tree
tracks chunk locations, not individual inodes. Each chunk has a 64-bit free
bitmap; a chunk record says "chunk starts at block X, these inode positions
within it are free."

- **INO btree** — every inode chunk in this AG
- **FINO btree** — only inode chunks with at least one free inode (a fast
  lookup index for finding where to allocate a new inode)

### What the AGFL is for

The AGFL is a tiny reserve (typically 4 blocks on a fresh filesystem,
up to ~128 entries) used during allocator transactions. Allocating from
the free-space B+trees can require splitting or merging btree nodes —
which itself needs blocks. The AGFL is pre-reserved space for those
allocator-internal operations, so a normal allocation can never fail
for lack of metadata space.

Don't worry about tuning it; it's an internal-correctness mechanism.

---

## 3. Inode Numbers Encode Their Location

An XFS inode number is **not arbitrary** — it encodes the AG and offset within
the AG. This means `stat()` knows immediately which AG to look in; no
filesystem-wide inode table is needed.

```
Inode number layout (v5 inodes):

  [    AG number    |       block in AG       |  inode in block  ]
   bits depend on agcount and agblklog
```

Consequence: when XFS allocates a new inode for a file, it tries to put it
in the same AG as the parent directory's inode, so `ls -lR` walks tend to
hit one AG at a time, improving locality.

```bash
# See the AG-to-inode mapping
ls -i /mnt/xfs/somefile
# 8589934721 somefile
# That number, in hex, broken across AG bits, tells you AG and offset.

# xfs_db can decode it:
xfs_db -r /dev/sda1 -c "inode 8589934721" -c "p"
# Output: core.di_format, core.di_size, AG number derivable from the inode's
# physical location.
```

---

## 4. Choosing the AG Count

`mkfs.xfs` picks AG count based on filesystem size:
- Default: AG size ~1TB, so a 4TB FS gets 4 AGs.
- Override with `-d agcount=N`.

```bash
# How many AGs does an existing filesystem have?
xfs_info /mnt/xfs | grep agcount
# data     = bsize=4096 blocks=1048576000, imaxpct=5
#          = sunit=0 swidth=0 blks
# naming   =version 2 bsize=4096 ascii-ci=0, ftype=1
# log      =internal log bsize=4096 blocks=521728, version=2
# realtime =none extsz=4096 blocks=0, rtextents=0
# (look for agcount=N earlier in output)

xfs_info /mnt/xfs | head -5
# meta-data=/dev/sda1   isize=512  agcount=32, agsize=32768000 blks
```

### Architect's heuristic

Performance scales with concurrent operations across AGs, NOT total AG count
beyond a point. Rule of thumb:

| Workload | AG count guidance |
|----------|-------------------|
| Single-threaded sequential | 4 is fine; more doesn't help |
| Highly parallel metadata (many small files, many threads) | One AG per CPU core, or per concurrent writer |
| Very large FS, mixed | Default (1TB AGs) usually correct |
| Container/VM image storage with many namespaces | Higher AG count (16–64) reduces metadata contention |

Don't go crazy: each AG has its own headers, btrees, and free-space
bookkeeping. Hundreds of AGs on a small filesystem just wastes space.

### Once set, AG count cannot decrease

You can only grow XFS (`xfs_growfs`), which adds AGs. You cannot shrink XFS
or reduce AG count. Choose at mkfs time with the largest size you expect
the filesystem to reach.

---

## 5. The Log (Brief Preview for Day 18)

The log is special: it doesn't live in an AG. By default it's an internal
log placed in the middle AG (the one closest to the geographic center
of the device, for HDD head-positioning reasons).

```bash
xfs_info /mnt/xfs | grep log
# log      =internal log bsize=4096 blocks=521728, version=2

# An internal log of 2 GB on a 4TB FS is typical
```

You can place the log on an external device with `mkfs.xfs -l logdev=...`.
The original motivation was performance — keep the log on a separate, fast
device so metadata journaling doesn't compete with data I/O. Less relevant
now with NVMe, but still useful for HDD-backed XFS in tiered systems.

Day 18 covers the log (CIL, delayed logging) in detail.

---

## 6. Self-Describing Metadata (CRC / v5)

XFS v5 (default since xfsprogs 3.2.0, 2013) adds:
- **CRC checksums** on every metadata block — corruption detected on read
- **Self-describing headers** — every metadata block has its own type, UUID
  ref to filesystem, and "owner" info
- **bigtime** timestamps (5.10+) — pushes the Year-2038 problem to 2486

```bash
# Check version 5 / CRC enabled
xfs_info /mnt/xfs | grep -E "crc|ftype"
# naming = version 2 bsize=4096 ascii-ci=0, ftype=1
# Look for crc=1 in newer output

# If you see crc=0, it's an old v4 filesystem. New formats default to v5.
```

For new filesystems: always v5. For existing v4 filesystems: there's no
conversion tool. You'd need to backup, reformat with v5, and restore.

---

## 7. Hands-On: Build, Inspect, Reason

```bash
# Build a small XFS on a loop device
dd if=/dev/zero of=/tmp/xfs.img bs=1M count=512
LOOP=$(losetup --find --show /tmp/xfs.img)

mkfs.xfs -f -d agcount=8 $LOOP

# Inspect filesystem structure
xfs_info $LOOP
# Look at: agcount, agsize, log size, crc=1

# Look at the on-disk superblock fields
xfs_db -r $LOOP -c "sb 0" -c "p" | head -40

# How much space does each AG header consume?
xfs_db -r $LOOP -c "agf 0" -c "p" | grep -E "freeblks|btreeblks"

# Walk all AG headers
for ag in 0 1 2 3 4 5 6 7; do
    echo "=== AG $ag ==="
    xfs_db -r $LOOP -c "sb $ag" -c "p" | grep -E "blocksize|sectsize"
    xfs_db -r $LOOP -c "agf $ag" -c "p" | grep -E "freeblks|longest"
    xfs_db -r $LOOP -c "agi $ag" -c "p" | grep -E "count|freecount"
done

# Mount, create some files, watch which AGs receive inodes
mkdir -p /mnt/xfs-test
mount $LOOP /mnt/xfs-test

# Create files in parallel and observe AG distribution
for i in $(seq 1 100); do
    mkdir -p /mnt/xfs-test/dir$i
    touch /mnt/xfs-test/dir$i/file
done

# See how inode numbers spread across AGs
ls -i /mnt/xfs-test/*/file | awk '{print $1}' | sort -n | head -20

# Cleanup
umount /mnt/xfs-test
losetup -d $LOOP
rm /tmp/xfs.img
```

---

## 8. AG Count and Production Concurrency: The Real-World Pattern

A common production pattern: workload is single-AG bound.

```
Symptom: XFS on 16-core box, heavy file-creation workload, only 1 CPU shows
high system time, others idle. iostat shows the device is not saturated.

Diagnosis: Most of the work targets the same parent directory.
XFS tries to allocate new inodes in the parent's AG → all threads contend
on the same AGI lock → serialization.

Fix at allocation time:
  - Spread parent directories across AGs (inode32 / inode64 allocation hint)
  - Use multiple parent directories
  - At mkfs time, set higher agcount so the allocator has more locks to spread across
```

Inode allocation mode interacts with this:
```bash
# Mount option: inode32 vs inode64 (default since 3.7)
mount -o inode32 ...  # restrict inodes to AGs below 1TB boundary (legacy compat)
mount -o inode64 ...  # default; inodes spread across all AGs
```

`inode64` is the default and what you want unless you're working around
broken 32-bit userspace.

---

## 9. Source Reading Checklist

```
fs/xfs/libxfs/xfs_sb.{c,h}         # superblock structure and validation
fs/xfs/libxfs/xfs_alloc.{c,h}      # AGF and free-space btree operations
fs/xfs/libxfs/xfs_ialloc.{c,h}     # AGI and inode allocation btree
fs/xfs/libxfs/xfs_format.h         # on-disk structure definitions
fs/xfs/xfs_super.c                 # mount, sb validation, feature bits
```

The on-disk structs in `xfs_format.h` are worth reading once. They are
the contract — anything reading or writing XFS metadata must match these
exactly.

---

## 10. Self-Check Questions

1. What are the four fixed-location metadata headers per AG, and what does each track?
2. Why does the AGF maintain two B+trees over the same free-space records?
3. What is the AGFL for and why does the allocator pre-reserve space in it?
4. An XFS filesystem has agcount=4 and a workload creates files only under /data. Why might only one CPU show high system time?
5. How does an XFS inode number differ from an ext4 inode number?
6. You want to grow an XFS from 4TB to 8TB. Does AG count change? Can you reduce AG count instead?

## 11. Answers

1. **Superblock (SB):** filesystem-wide info (size, AG count, features); each AG has a copy for redundancy. **AGF:** free-space management — roots of BNO (by-block) and CNT (by-count) free-space B+trees. **AGI:** inode management — roots of INO (all chunks) and FINO (chunks with free inodes) B+trees. **AGFL:** small reserve of blocks for allocator-internal operations.
2. To support two different lookup patterns in O(log n): "find the largest free extent for a big request" (CNT, indexed by size) and "find a free extent near this specific location" (BNO, indexed by block number).
3. AGFL is a pre-reserved pool of blocks used during allocator B+tree splits/merges. The allocator may need to allocate blocks while it's *in the middle of* an allocation transaction; pre-reserving guarantees that recursive allocation can always succeed without re-entering the main allocator.
4. New file creation tends to put the new inode in the same AG as the parent directory's inode. If all files are created under one directory, they all hit one AGI's locks — only one AG's allocator runs at a time. Either spread directories across AGs (move some subtrees) or increase agcount at the next mkfs.
5. XFS inode numbers encode their physical location (AG number + block within AG + inode position in block). ext4 inode numbers are just indices into a per-block-group inode table; the inode-to-block mapping comes from the bgdt + ext4_inode_table reference. XFS thus needs no centralized inode table at all.
6. `xfs_growfs` adds new AGs at the end of the device; existing AGs are unchanged. You cannot reduce AG count — XFS doesn't support shrinking the filesystem at all. Plan AG count at mkfs time for the largest expected size.

---

## Tomorrow: Day 18 — XFS Internals Part 2: Log, Delayed Allocation, Reflink

We cover the parts of XFS that drive its modern performance and durability
properties: the Committed Item List (CIL), delayed logging, delayed
allocation, and reflink (COW snapshots).
