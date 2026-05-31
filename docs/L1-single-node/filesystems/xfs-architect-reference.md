# XFS Internals — Architect's Deep Reference

**Audience:** Storage architect / senior kernel engineer
**Context:** Deep coverage of XFS data structures, B-trees, log mechanics, and performance model. Assumes day17 (AG layout) and day18 (log, delayed alloc, reflink) as prerequisites.
**Related:** day17-xfs-internals-part1.md, day18-xfs-internals-part2.md

---

## 1. The Seven B-Trees — What XFS Actually Is

XFS is fundamentally a collection of B-trees, one or more per Allocation Group. Understanding which B-tree protects what is the foundation of everything else.

### Per-AG B-trees (stored in each AG's header region)

| B-tree | Abbreviation | Key | Value | Purpose |
|--------|-------------|-----|-------|---------|
| Free space by block number | BNObt | agbno | length | Find if a specific block is free; merge adjacent free extents |
| Free space by count | CNTbt | length, agbno | — | Find the largest free extent; best-fit allocation |
| Inode allocation | INObt (inobt) | agbno | inode chunk bitmap | Track which 64-inode chunks are allocated |
| Free inode | FINObt (finobt) | agbno | free inode bitmap | Fast path for inode allocation (v5 feature) |
| Reverse mapping | RMAPbt | agbno, owner | offset, flags | Map every physical block to its owner (v5 feature) |
| Reference count | REFCNTbt | agbno | refcount | Count sharing references for reflink extents (v5) |

### Per-file B-tree (stored in inode or separate blocks)

| B-tree | Abbreviation | Key | Value | Purpose |
|--------|-------------|-----|-------|---------|
| Block map | BMBTbt | file offset | physical extent | Map file logical offset → physical block range |

**Total: 7 distinct B-tree types.** Every XFS operation touches at least 2–3 of these. A reflink CoW operation touches all seven.

### Why two free-space B-trees (BNO + CNT)?

```
BNObt answers: "is block 0x4000 free?"
  → key = starting block number
  → used by: free space merging (coalescing adjacent free extents after delete)

CNTbt answers: "find me the largest free extent ≥ 128 blocks"
  → key = (length, startblock)  ← length first!
  → used by: allocation (find best-fit extent for a new file)

They contain the same set of free extents, indexed differently.
Every free extent insert/delete updates BOTH trees atomically.
```

### Why the free inode B-tree (FINObt)?

Before v5 finobt: allocating an inode required scanning the inobt to find a chunk with a free slot — O(chunks) scan in the worst case.

With finobt: only chunks with at least one free inode are in the finobt. Inode allocation = finobt lookup → instant. The inobt is still needed for full chunk management; finobt is a faster index of "has free inodes."

### Why RMAP?

RMAP records every physical block's owner: `(agbno, length) → (owner_ino, file_offset, flags)`. Owner is one of:
- An inode number + file offset (data block)
- `XFS_RMAP_OWN_AG` (AG B-tree block)
- `XFS_RMAP_OWN_LOG` (log)
- `XFS_RMAP_OWN_FS` (superblock, AG headers)

RMAP enables:
1. **Online repair** (`xfs_scrub`): verify B-tree consistency without unmounting
2. **Reflink CoW**: identify all physical extents that must be copied on first write to a shared region
3. **Reverse lookup during recovery**: reconstruct ownership after partial writes

RMAP adds ~10–15% space overhead (one B-tree entry per allocated extent) and write overhead (every allocation/free updates RMAPbt). This is why it is a v5 opt-in feature, not the default on v4.

---

## 2. Extent Format — The 128-Bit Packed Record

Every physical extent in XFS is described by a single 128-bit packed record:

```
 127        73 72      21 20        1 0
 ┌──────────┬──────────┬────────────┬─┐
 │ startoff │startblock│ blockcount │F│
 │ (54 bits)│ (52 bits)│ (21 bits)  │ │
 └──────────┴──────────┴────────────┴─┘

F = 0: normal (unwritten = 0)
F = 1: unwritten (prealloc'd but not initialized — reads return zeros)

startoff:   file logical block offset (up to 8 EiB files)
startblock: physical AG block number (up to 8 EiB filesystem)
blockcount: run length in blocks (up to 2^21 = 2M blocks = 8 GB at 4K block)
```

**This is why XFS can represent a 1 GB contiguous file in a single extent record** — the entire file is one 128-bit entry. Compare to ext4's block map (each block needs a separate entry for files without extents).

**Unwritten extents** (F=1) are created by `fallocate()`. Reading an unwritten extent returns zeros without touching disk. On the first write, XFS converts the extent to written (updates the BMBT and logs the conversion), which is why fallocate + sequential write is fast: the extent is pre-reserved, only the "unwritten → written" flag flip is logged per-extent, not per-block.

---

## 3. Inode Format — Three Data Forks

Every XFS inode is 512 bytes (default, configurable to 256 or 2048 at mkfs). The inode core occupies ~96 bytes; the rest is the **data fork** and optionally an **attribute fork**.

### Data fork formats (di_format field)

```c
#define XFS_DINODE_FMT_LOCAL    1   // data stored inline in inode
#define XFS_DINODE_FMT_EXTENTS  2   // extent list fits in inode
#define XFS_DINODE_FMT_BTREE    3   // too many extents → BMBT B-tree
```

**LOCAL**: The file data itself lives in the inode's data fork area. Used for:
- Small files (≤ ~440 bytes at 512-byte inode size)
- Small directories (≤ ~448 bytes — the "short-form directory")
- Short symlinks

**EXTENTS**: The data fork holds a packed array of 128-bit extent records. A 512-byte inode can hold up to 18 extents inline. Most normal files stay in EXTENTS format indefinitely if well-allocated.

**BTREE**: When a file has more extents than fit in the inode (>18 for 512-byte inodes), XFS promotes the extent list to a BMBT B-tree. The data fork now holds the B-tree root. This happens most often for:
- Heavily fragmented files (many small extents)
- Very large files with many allocation segments
- Files written in tiny chunks over time

**Format transitions** are one-way upgrades logged as metadata changes:
```
LOCAL → EXTENTS: when data grows beyond inline size
EXTENTS → BTREE: when extent count exceeds inline capacity
```

**Fragmentation and the BTREE penalty**: every read from a BTREE-format file requires at least one extra block read for the B-tree traversal (more levels = more reads). This is why fragmentation hurts: not just because extents are non-contiguous, but because the BMBT adds read latency to every I/O.

---

## 4. Directory Structure — Five Formats

XFS directories use different on-disk formats based on size. Promotion is automatic.

### Format 1: Short-form (inline in inode, LOCAL format)

```
[ inode core ] [ sf_hdr ] [ entry: namelen, offset, ino ] [ entry ... ]
```

Stores the entire directory in the inode data fork. Maximum entries: ~12–15 for typical names at 512-byte inode size. This is used for newly created directories with few entries. Lookup is a linear scan (acceptable at this size).

### Format 2: Block directory (1 data block)

When the directory outgrows the inode, it expands to a single 4 KB block (or larger if `dir_blksize` > 4 KB). The block contains:
- Directory entries (variable-length, packed)
- A "leaf" section at the end of the block with a sorted hash index

Lookup: compute `da_hashname(name)` → binary search in the leaf section → find entry offset → read entry. O(log N) within the single block.

### Format 3: Leaf directory (multiple data blocks + 1 leaf block)

When entries exceed one block, the directory has:
- Multiple "data" blocks containing actual entries
- A single separate "leaf" block containing the hash-to-data-block index

The leaf block is an array of `(hashval, address)` pairs sorted by hash. Lookup: hash → binary search in leaf → jump to data block → scan for exact match.

### Format 4: Node directory (multiple data blocks + tree of nodes)

When the leaf block itself is full, the leaf level becomes a multi-level B-tree of hash indexes ("da_node" blocks) pointing down to the leaf level which points to data blocks. Three-level lookup: node → leaf → data.

### Format 5: B-tree directory (htree)

Very large directories (millions of entries) where even the node level overflows. The hash index becomes a full B-tree. Lookup is O(log N) always.

**The hash function**: `xfs_dir2_hashname()` computes a 32-bit hash of the filename. Hash collisions in the same directory are handled by chaining. The hash is stored in the on-disk leaf/node entries.

**Architect implication**: directory lookup is O(log N) for any size directory in XFS — no linear scans at any scale. This is why `ls` in a directory with 10 million files is fast on XFS (it's a B-tree traversal) but can be slow on ext4 without `dir_index` (htree) enabled.

---

## 5. The XFS Log — Deeper Than Day 18

### Log physical structure

The log is a circular buffer of 512-byte sectors (or larger with biglogsectsize). It contains:
- **Log record headers** (`xlog_rec_header_t`): mark the start of a log write, contain cycle number, LSN, length
- **Log operations** (`xlog_op_header_t`): one per logged item chunk
- **Item data**: the actual metadata bytes being logged (inode cores, B-tree blocks, AG headers)

The log has two pointers:
```
log->l_tail_lsn  — oldest log record still needed for recovery
log->l_head_lsn  — next write position

Available log space = (tail - head + log_size) % log_size
```

The tail advances when the oldest dirty items are written to disk (checkpointed). If the log fills (head catches up to tail), all writes block — **log space exhaustion**.

### Log Item types

Every on-disk structure that must be logged has a corresponding log item type:

| Log item | Abbreviation | What it logs |
|----------|-------------|-------------|
| Inode log item | ILI | inode core, data fork extents, attr fork |
| Buffer log item | BLI | raw block contents (B-tree nodes, AG headers) |
| Extent free intent | EFI | "I am about to free these extents" |
| Extent free done | EFD | "I completed freeing those extents" |
| Block use intent | BUI | "I am about to map these blocks" |
| Block use done | BUD | "mapping complete" |
| Refcount update intent | CUI | "I am about to change refcount of these blocks" |
| Refcount update done | CUD | "refcount change complete" |
| Rmap update intent | RUI | "I am about to change rmap entries" |
| Rmap update done | RUD | "rmap change complete" |

### Intent / Done pairs — the atomicity mechanism

The EFI/EFD (and BUI/BUD, CUI/CUD, RUI/RUD) pairs are how XFS makes multi-step operations atomic across crashes.

Example: freeing an extent requires:
1. Remove the extent from the file's BMBT
2. Add the blocks to the AG free space (BNObt + CNTbt)
3. Update the RMAP B-tree
4. Update the REFCOUNT B-tree (if shared)

These are 4 separate B-tree modifications. If a crash happens between steps 2 and 3, the filesystem is inconsistent.

**Solution**: before starting the operation, log an EFI: "I intend to free blocks [X, Y]." When all 4 steps complete, log the EFD: "I completed the free." On recovery:

```
Recovery algorithm:
  Forward pass: replay all committed transactions
  After forward pass: scan log for EFIs without matching EFDs
  Any unmatched EFI → the operation was started but not completed
  Re-execute the free operation from the EFI record
```

This ensures multi-step operations complete atomically even across crashes. The intent is logged before the work; the done is logged after. An unmatched intent means "redo this."

### Log recovery phases

```
Phase 1 — Find the log head:
  Scan log from known good point, find highest LSN (newest write)
  Head = first block after the newest committed record

Phase 2 — Find the log tail:
  Walk backward from head, find oldest record still referenced
  Tail = oldest record still needed

Phase 3 — Validate:
  Check CRCs on all log records between tail and head

Phase 4 — Replay:
  Apply all log records from tail to head in order
  Re-execute all logged item changes against the filesystem structures
  Handle unmatched intents (EFI without EFD, etc.)

Phase 5 — Recover unlinked inodes:
  Walk the iunlink list (inodes unlinked but not freed — open file deleted)
  Free any inodes that were pending deletion
```

Recovery is typically fast (seconds to minutes) because only the log needs to be replayed, not the entire filesystem.

### Log reservation — why transactions can't be unlimited

Before any transaction can log anything, it must **reserve** log space:

```c
xfs_trans_reserve(tp,
    M_RES(mp)->tr_write,    // unit reservation (per log item)
    blocks,                  // block reservation for allocation
    0);                      // real-time extents
```

Log reservation is taken from the **grant head** — a counter of available log space. If the grant head has insufficient space, the transaction blocks until log space is freed by checkpointing dirty items to disk.

**This is why `sync` or `fsync` storms can stall**: many concurrent transactions all reserving log space → grant head depleted → all new transactions block waiting for the log to drain.

Log size determines max concurrent in-flight metadata. Too small a log → grant head starvation under heavy concurrent metadata workloads. XFS sizes the log based on filesystem size; for production use on NVMe with heavy metadata workloads, use an external log on a separate NVMe to reduce log write latency.

---

## 6. Transaction and Locking Model

### Lock order (strictly enforced, no exceptions)

XFS has a defined lock order to prevent deadlock. Any code that acquires multiple locks must follow this order:

```
1. Superblock (rarely held)
2. AGF lock  (guards free space B-trees)
3. AGI lock  (guards inode B-trees)
4. AGFL lock (guards the free list)
5. Inode lock (per-inode read/write lock)
6. Buffer locks (per-block B-tree buffer)
```

**Why AGF before AGI?** Inode allocation needs free blocks (AGF) to add a new inode chunk. The lock order prevents deadlock between "allocate block for inode" and "allocate inode for directory entry."

**Why this matters for architects**: lock order violations in kernel code cause AB-BA deadlocks. XFS lockdep annotations (`LOCKDEP_CLASS_*` in `xfs_inode.c`) enforce this at runtime in debug kernels.

### Per-AG locking enables parallelism

Each AG has its own AGF lock and AGI lock. Two threads writing to different AGs hold different locks — they run in parallel. This is the core of XFS's concurrency model:

```
Thread A: write to file in AG 0 → holds AGF lock for AG 0
Thread B: write to file in AG 8 → holds AGF lock for AG 8
→ No contention. Both run at full NVMe speed.
```

The AG count determines the maximum metadata concurrency. On a 96-core machine doing 1M IOPS, you need enough AGs that competing threads rarely land in the same AG. Rule of thumb: `agcount = 2-4 × CPU_count`, bounded by AG size ≥ 4 GB.

---

## 7. Allocation Strategy — How XFS Places Data

### Inode allocation AG selection

When creating a new file:
1. XFS tries to allocate the inode in the same AG as the parent directory (locality: keep directory and its files close)
2. If that AG is full, fall back to the AG with the most free inodes (round-robin load balance)
3. Inode chunk: allocate 64 inodes at once in a contiguous block, then dish them out from the chunk

### Data block allocation strategy

```
1. Try to allocate near the inode's existing extents (locality for sequential reads)
2. Within the AG: use the CNTbt to find the best-fit free extent
3. If AG is too full (<25% free), move to a different AG
4. For large writes: allocate in the same AG as the inode if possible (keeps I/O within one AG's seek range on HDD)
```

**Extent size hints**: applications can tell XFS to allocate in multiples of a given extent size:
```bash
xfs_io -c "extsize 1m" /path/to/file
# Subsequent allocations rounded up to 1 MB extents
# Reduces fragmentation for large-file sequential workloads
```

**Stripe alignment**: if `sunit`/`swidth` are set at mkfs time, XFS aligns all allocations to RAID stripe boundaries:
```bash
mkfs.xfs -d su=256k,sw=4 /dev/sda   # 256 KB stripe unit, 4 disks = 1 MB stripe width
```

Unaligned I/O on a striped array causes partial-stripe reads on write — a major performance killer. Setting `su`/`sw` correctly at mkfs time is mandatory for RAID/software-RAID deployments.

---

## 8. Fragmentation — Causes, Measurement, Repair

### How fragmentation happens in XFS

XFS's delayed allocation (day18) significantly reduces fragmentation for streaming writes. Fragmentation still occurs from:

1. **Interleaved concurrent writers**: two threads writing simultaneously claim alternating free extents
2. **Delete and re-fill**: deleting files leaves holes that new files partially fill with small extents
3. **Append-heavy workloads**: many files growing simultaneously → each gets a small speculative preallocation → prealloc is trimmed on close → next write gets another small chunk

### Measuring fragmentation

```bash
# File-level fragmentation (extent count vs ideal)
xfs_db -r -c "frag" /dev/sda
# Output: actual 12345, ideal 1234, fragmentation factor 90.00%
# fragmentation factor = 1 - (ideal/actual)
# 0% = perfectly contiguous; 100% = every block is a separate extent

# Free space fragmentation (are there large contiguous runs?)
xfs_db -r -c "freesp -s" /dev/sda
# Histogram of free extent sizes — want to see large extents, not many tiny ones

# Per-file extent count
xfs_io -c "fiemap" /path/to/file | wc -l
# Or:
filefrag -v /path/to/file
# "1 extent" = perfectly contiguous; "100 extents" = highly fragmented
```

### Defragmentation

```bash
# Online defragmentation (no unmount needed)
xfs_fsr /dev/sda               # defrag entire filesystem
xfs_fsr -t 3600 /dev/sda      # run for 1 hour
xfs_fsr /path/to/file         # defrag single file

# How xfs_fsr works:
# 1. Read the file's current extent list
# 2. Create a temp file, write a contiguous copy using read/write
# 3. Use XFS_IOC_SWAPEXT ioctl to atomically swap extents between original and temp
# 4. Delete the temp file
# The swap is atomic: no window where the file has inconsistent extents
```

**When defrag helps**: HDD workloads with many small files, heavily fragmented databases. On NVMe, random I/O is nearly free — defrag provides minimal benefit and causes extra wear.

---

## 9. RMAP B-tree — Deep Dive

### What an RMAP record looks like

```c
struct xfs_rmap_irec {
    xfs_agblock_t   rm_startblock;  // physical block number within AG
    xfs_extlen_t    rm_blockcount;  // run length
    uint64_t        rm_owner;       // XFS_RMAP_OWN_* or inode number
    uint64_t        rm_offset;      // file offset (0 for metadata owners)
    unsigned int    rm_flags;       // UNWRITTEN, ATTR_FORK, BMBT_BLOCK
};
```

**BMBT_BLOCK flag**: the block is a B-tree block of the file's BMBT, not file data. This means RMAP can distinguish "this block is the file's extent map B-tree" from "this block is the file's data."

**ATTR_FORK flag**: the block belongs to the inode's attribute fork, not the data fork.

### RMAP and reflink interaction

When two files share an extent (via `cp --reflink`):
```
Physical block 0x4000:
  RMAP entry 1: owner=inode_A, offset=0, flags=0
  RMAP entry 2: owner=inode_B, offset=0, flags=0
  REFCOUNT entry: agbno=0x4000, refcount=2
```

On write to inode_A at offset 0:
1. CoW allocates a new block (say 0x5000)
2. New data written to 0x5000
3. BMBT for inode_A updated: offset 0 → 0x5000
4. RMAP updated: add (0x5000, inode_A, 0), remove (0x4000, inode_A, 0)
5. REFCOUNT for 0x4000 decremented to 1
6. inode_B still maps 0x4000 (unchanged)

All 5 steps are logged atomically via CUI/CUD and RUI/RUD intent pairs.

### RMAP and online repair (xfs_scrub)

```bash
# Online filesystem check (no unmount needed, v5+ only)
xfs_scrub /dev/sda
# or
xfs_scrub /mount/point
```

`xfs_scrub` uses RMAP to verify every B-tree's consistency while the filesystem is live:
- Verify BNObt: every free extent should have no RMAP entry
- Verify BMBTs: every file extent should have a matching RMAP entry
- Verify REFCNTbt: refcount should equal number of RMAP entries for each block
- Cross-reference all B-trees for consistency

Without RMAP, this verification would require unmounting (xfs_repair). With RMAP, it runs online.

---

## 10. Performance Profile — Where XFS Excels and Where It Struggles

### XFS excels at

**1. Large file sequential I/O**: delayed allocation + extent-based format means a 10 GB file written sequentially is often 1 extent. Sequential read is 1 BMBT lookup + 1 large I/O.

**2. High-concurrency metadata operations**: per-AG locking means N threads writing to N different AGs run without contention. On a 96-core machine with 32+ AGs, XFS scales nearly linearly.

**3. Very large filesystems**: 8 EiB max, B-tree metadata scales logarithmically. A 100 TB filesystem with 100 million files is routine for XFS.

**4. Large directory operations**: B-tree directories scale to millions of entries with O(log N) lookup. `ls` in a 10M-entry directory is fast.

**5. Parallel streaming writes**: multiple writers to different files in different AGs — near-line throughput on NVMe.

### XFS struggles with

**1. Small file creation storms**: creating millions of tiny files quickly. Each file creation is a transaction (inode alloc + directory update + data block alloc). At high concurrency, the log becomes the bottleneck. Ext4 with `dir_index` and a journal on NVMe is often faster for this workload.

**2. fsync-heavy workloads**: every `fsync()` forces a log flush. In XFS, `fsync` waits for the CIL to push (checkpoint the current log buffer). Under heavy concurrent `fsync` load, the log grant head depletes and threads block. PostgreSQL with `synchronous_commit=on` on XFS can bottleneck here.

**3. Metadata-heavy random writes to many small files**: the AGF/AGI locks become contended if all threads hash to the same AG. Mitigation: set AG count appropriately, use `inode64` mount option (default since 3.7) to distribute inodes across AGs.

**4. Free space exhaustion near 100% full**: when the filesystem is > 95% full, the CNTbt finds no large extents. Every allocation is a fragmented small extent. Write performance degrades severely. XFS reserves 5% for root by default (`imaxpct`). Never fill XFS past 90% for write workloads.

### Key performance numbers (NVMe, large XFS, 32 AGs)

```
Sequential read (large file, single stream):  saturates NVMe bandwidth (6–7 GB/s)
Sequential write (large file, single stream): saturates NVMe bandwidth
Random 4 KB read (32 threads, 32 AGs):       ~1M+ IOPS (no AG contention)
File creation (mkdir + open + close):         ~100K–200K files/sec (log-bound)
Directory lookup (10M entry dir):             microseconds (B-tree htree)
xfs_repair on 100 TB filesystem:             hours (with RMAP: xfs_scrub online)
```

---

## 11. Key Failure Modes and Diagnosis

### Failure 1: Log space exhaustion ("hung in xfsaild")

**Symptom**: writes stall, processes stuck in `D` state, `xfs_log_force` in kernel stack trace.

**Cause**: log grant head depleted — too many in-flight dirty items, log can't drain fast enough.

**Diagnosis**:
```bash
# Check log activity
xfs_info /mount/point | grep log

# Kernel stack trace of hung process
cat /proc/<pid>/wchan   # should show "xlog_grant_head_wait"

# Check if log is external or internal
xfs_info /dev/sda | grep "log ="
# internal = log on same device as data (common cause of log I/O starvation)
```

**Fix**: external log on separate NVMe, increase log size at mkfs (`-l size=2g`), or reduce concurrent metadata workload.

### Failure 2: AG locking contention

**Symptom**: iostat shows good device throughput but application sees high latency. `perf top` shows time in `xfs_buf_lock`, `xfs_ilock`.

**Diagnosis**:
```bash
# Check AG count vs CPU count
xfs_info /dev/sda | grep agcount

# If agcount << CPU_count, threads contend on the same AGF/AGI locks
# Fix: only fixable by reformatting with more AGs
```

### Failure 3: Fragmentation spiral

**Symptom**: write throughput declining over months of operation. `filefrag` shows many extents per file.

**Diagnosis**:
```bash
xfs_db -r -c "frag" /dev/sda
# fragmentation factor > 50% → significant fragmentation

# Check free space fragmentation
xfs_db -r -c "freesp -s" /dev/sda
# If largest free extent << filesystem size, free space is fragmented
```

**Fix**: `xfs_fsr` (online), or backup + mkfs + restore (offline).

### Failure 4: Filesystem full with space apparently available

**Symptom**: `df` shows 5% free but writes fail with ENOSPC.

**Causes**:
1. All free space is in small extents (fragmented free space); the write needs a contiguous extent larger than any available
2. Reserved space (`imaxpct` inode reservation consuming blocks)
3. Speculative preallocation consuming more space than actually written (run `sync` to trim preallocations)

```bash
# Trim speculative preallocation (reclaim reserved but unwritten space)
sync && echo 3 > /proc/sys/vm/drop_caches
# Or:
xfs_io -c "bulkstat" /mount/point  # walk all inodes and trim preallocations
```

---

## 12. mkfs.xfs Parameters — What Matters at Format Time

```bash
# Production NVMe filesystem for high-concurrency workload
mkfs.xfs \
  -b size=4096 \          # block size (4K is standard; 64K for HPC large-file)
  -m crc=1,reflink=1 \    # v5 features: CRC + reflink
  -l size=2g,lazy-count=1 \  # 2 GB internal log; lazy-count reduces log pressure
  -d agcount=32 \         # 32 AGs for 32+ core parallelism
  -i size=512 \           # 512-byte inodes (enough for most workloads)
  /dev/nvme0n1

# External log (separate NVMe reduces log write latency from data I/O)
mkfs.xfs \
  -l logdev=/dev/nvme1n1,size=4g \
  -d agcount=32 \
  /dev/nvme0n1

# RAID-aware (RAID-5, 4+1, 256 KB stripe unit)
mkfs.xfs \
  -d su=256k,sw=4 \       # stripe unit 256 KB, 4 data disks → 1 MB stripe width
  -d agcount=16 \
  /dev/md0
```

**Parameters that cannot be changed after mkfs:**
- `agcount` (AG count)
- `blocksize`
- `isize` (inode size)
- `crc` (v4 vs v5)
- `reflink`
- `rmapbt`

Get these right at format time. There is no "alter table" for XFS.

---

## 13. Source Code Map

| Subsystem | Files |
|-----------|-------|
| AG / superblock | `fs/xfs/libxfs/xfs_ag.c`, `xfs_sb.c` |
| BNObt / CNTbt | `fs/xfs/libxfs/xfs_alloc_btree.c`, `xfs_alloc.c` |
| Inobt / finobt | `fs/xfs/libxfs/xfs_ialloc_btree.c`, `xfs_ialloc.c` |
| RMAPbt | `fs/xfs/libxfs/xfs_rmap_btree.c`, `xfs_rmap.c` |
| REFCNTbt | `fs/xfs/libxfs/xfs_refcount_btree.c`, `xfs_refcount.c` |
| BMBT (per-file) | `fs/xfs/libxfs/xfs_bmap_btree.c`, `xfs_bmap.c` |
| Inode format | `fs/xfs/libxfs/xfs_inode_fork.c`, `xfs_inode.h` |
| Directory | `fs/xfs/libxfs/xfs_dir2*.c` |
| Log / CIL | `fs/xfs/xfs_log.c`, `xfs_log_cil.c`, `xfs_log_recover.c` |
| Transactions | `fs/xfs/xfs_trans.c`, `xfs_trans_buf.c` |
| Delayed alloc | `fs/xfs/xfs_iomap.c` |
| Reflink / CoW | `fs/xfs/xfs_reflink.c` |

---

## 14. XFS vs ext4 — Architect's Comparison

Understanding the structural differences helps you choose the right filesystem and predict behavior under load.

### Fundamental design difference

```
ext4:  fixed-location metadata (block group descriptors at known offsets)
       → predictable layout, simple recovery, but fixed parallelism ceiling

XFS:   per-AG B-trees, all metadata in B-trees, dynamic layout
       → unlimited parallelism scaling, but more complex recovery
```

### Data structure comparison

| Feature | XFS | ext4 |
|---------|-----|------|
| Allocation unit | Allocation Group (AG), 1 per CPU recommended | Block Group (BG), fixed 128 MB per group |
| Free space index | Two B-trees (BNO + CNT) | Bitmap per block group + buddy allocator (mb_alloc) |
| Inode location | Flexible within AG, inode number encodes AG | Fixed inode table at start of each block group |
| Inode allocation | 64-inode chunks, B-tree tracked | Bitmap per block group |
| Extent tracking | BMBT B-tree (per file, 128-bit packed records) | Extent tree (ext4 extents) or old block map |
| Max extents inline | 18 (512-byte inode) | 4 (in inode) |
| Directory structure | 5 formats: short-form → htree B-tree | 2 formats: linear → htree (when dir_index enabled) |
| Metadata integrity | CRC32c on every metadata block (v5) | CRC32c (metadata_csum feature) |
| Reverse mapping | RMAPbt (v5, optional) | Not available |
| Reflink / CoW | Yes (v5, default) | Yes (since kernel 4.16) |
| Online check | xfs_scrub (with RMAP) | e2scrub (limited) |

### Concurrency and scaling

```
ext4 block group lock:
  Each 128 MB block group has its own lock.
  On a 4 TB filesystem: ~32K block groups → high lock count but fixed size.
  Block group size is fixed at mkfs (typically 128 MB).
  Adding CPUs beyond ~block_group_count provides no benefit.

XFS AG lock:
  Each AG has its own AGF + AGI lock.
  AG count is set at mkfs, typically = CPU count.
  A 4 TB filesystem with agcount=32: 32 parallel metadata paths.
  On a 96-core machine: set agcount=64–96 for near-linear scaling.
```

**Concurrency winner: XFS** — tuneable AG count vs fixed block group size.

### Allocation algorithm

```
ext4 multi-block allocator (mballoc):
  - Per-block-group buddy allocator (like kernel page allocator)
  - Preallocation per-inode (ext4_prealloc_space)
  - Group preallocation for large allocations
  - Delayed allocation: same as XFS

XFS allocator:
  - CNTbt: always finds best-fit free extent in O(log N)
  - Delayed allocation: accumulates dirty pages, allocates on writeback
  - Speculative preallocation: proactively reserves space for growing files
  - Extent size hints: application-controlled allocation granularity
```

For random-write workloads creating many files, ext4's buddy allocator is competitive. For large sequential files, XFS's extent-based allocation produces fewer, larger extents.

### Journal / log comparison

```
ext4 JBD2 journal:
  - Journals full metadata blocks (entire block, even if 1 byte changed)
  - Three modes: journal (safest), ordered (default), writeback (fastest)
  - Journal is a circular log of block copies
  - fsync: flush journal, write commit block, done
  - Journal size: typically 128 MB–1 GB

XFS log:
  - Logs only changed bytes (log vectors), not full blocks → smaller log writes
  - Single mode: equivalent to ext4 "ordered" semantics
  - CIL (Committed Item List): batches many transactions into one log write
  - fsync: flush CIL, write commit record, done
  - Log size: typically 512 MB–4 GB (can be external)
```

**Log efficiency winner: XFS** — logging changed bytes vs full blocks means XFS log writes are smaller under metadata-heavy workloads (many small changes to many B-tree nodes).

**fsync latency**: comparable, but XFS CIL batching means a single `fsync` can amortize many concurrent dirty items into one log flush. Under high concurrency, XFS fsync throughput is better.

### Crash recovery

```
ext4 recovery:
  - Replay journal from last checkpoint
  - Typically seconds (small journal, full-block replay)
  - Simple: journal is a circular buffer of full blocks

XFS recovery:
  - Phase 1-5: find head/tail → validate → replay → intent cleanup → unlinked inodes
  - Typically seconds to minutes for large filesystems
  - More complex: intent/done pairs must be matched
  - But: handles partial multi-step operations correctly via intent replay
```

**Recovery simplicity winner: ext4** — but XFS's intent/done pairs provide stronger atomicity guarantees for complex multi-B-tree operations.

### Feature comparison

| Feature | XFS | ext4 | Notes |
|---------|-----|------|-------|
| Max filesystem size | 8 EiB | 1 EiB (with 64-bit feature) | Both effectively unlimited |
| Max file size | 8 EiB | 16 TiB (4K blocks) | XFS wins for very large files |
| Max directory size | ~32 TB | ~2 TB | XFS wins |
| Max filename length | 255 bytes | 255 bytes | Tie |
| Inline data | Yes (small files/symlinks) | Yes (inline_data feature) | Similar |
| Sparse files | Yes | Yes | Tie |
| Quotas | User, group, project | User, group, project | Both support project quotas |
| Online grow | Yes | Yes | Both support online grow |
| Online shrink | No | No (limited) | Neither supports cleanly |
| Encryption | No (use dm-crypt) | Yes (fscrypt) | ext4 wins for native encryption |
| Compression | No | No | Neither (use btrfs for compression) |
| Checksums | Per-block CRC32c (v5) | Per-block CRC32c (metadata_csum) | Both v5/modern |
| Online defrag | Yes (xfs_fsr) | Yes (e4defrag) | Both |
| Shrink | xfs_growfs only grows | resize2fs can shrink | ext4 wins |

### Workload-based selection guide

| Workload | Winner | Reason |
|----------|--------|--------|
| Large files, sequential I/O (video, HPC, ML datasets) | **XFS** | Extent-based, large allocation, no fragmentation |
| High-concurrency random metadata (many threads, many files) | **XFS** | Per-AG locking scales with CPU count |
| Very large filesystem (> 10 TB) | **XFS** | B-tree scales better than block group bitmaps |
| Many small files, simple workload | **ext4** | Simpler, battle-tested, slightly faster for single-threaded small-file ops |
| Container root filesystem (small, single-user) | **ext4** | Simpler, slightly lower overhead at small scale |
| Database (PostgreSQL, MySQL) | **XFS** (preferred) | Better large-file performance, external log option |
| fsync-heavy OLTP | **XFS** with external log | CIL batching + separate log device reduces fsync latency |
| Encrypted filesystem | **ext4** (fscrypt) or dm-crypt | XFS has no native file-level encryption |
| Boot / root partition | **ext4** | More universal bootloader support, simpler |

### The practical summary

```
ext4:  battle-tested, simple, universally supported, fast for small-scale
       workloads. The right default for boot partitions, small VMs, and
       anything where "it just works" matters more than peak performance.

XFS:   purpose-built for scale. The right choice for NVMe data volumes,
       large files, high-concurrency metadata, and any filesystem > 1 TB.
       Default for RHEL/CentOS data volumes since RHEL 7 (2014).
       Default for most cloud block storage volumes.
```

Red Hat switched RHEL default from ext4 to XFS in RHEL 7. This was not a religious choice — it was based on measured performance at the scale of enterprise storage (multi-TB filesystems, 10K+ file/sec creation rates, RAID and SAN workloads). For those workloads, XFS wins on throughput, concurrency, and long-term fragmentation resistance.

---

## Quick Reference: XFS Architect Decision Points

| Decision | Rule |
|----------|------|
| AG count | `2–4 × CPU_count`, AG size ≥ 4 GB, max 2^20 AGs |
| Log size | ≥ 512 MB for metadata-heavy; 2–4 GB for heavy workloads; external log on separate NVMe |
| Block size | 4 KB standard; 64 KB for HPC (reduces BMBT depth, improves large I/O) |
| Inode size | 512 B default; 2048 B if many extended attributes per file |
| Fill threshold | Never fill past 90% for write workloads; 85% recommended |
| Fragmentation check | `xfs_db -c "frag"` monthly; run `xfs_fsr` if factor > 30% |
| v5 features | Always: `crc=1,reflink=1,rmapbt=1` (defaults since xfsprogs 5.x) |
| RAID alignment | Always set `su`/`sw` when on RAID; misalignment causes 2–3× write overhead |
| External log | For NVMe workloads with heavy `fsync`; eliminates log/data I/O contention |
