# Filesystem Architect Comparison: ext4 vs XFS vs Btrfs

> Synthesizes and extends the per-filesystem deep dives in:
> `ext4-architect-reference.md`, `xfs-architect-reference.md`, `btrfs-architect-reference.md`
>
> Organized by dimension, not by filesystem — designed for architect-level design decisions.

---

## 1. Design Philosophy

Understanding *why* each filesystem is built the way it is predicts its behavior before you measure it.

```
ext4: Fixed-location metadata, external journal layer (JBD2)
  Philosophy: evolutionary from ext2/ext3; maximize compatibility and simplicity.
  Key invariant: metadata lives at predictable offsets (inode tables at BG start,
    GDT always in BG 0). Simple recovery: replay a journal of block copies.
  Design era: 2006 (ext4 mainlined); target = general-purpose desktop/server.
  Trade-off: simplicity and universality over scalability.

XFS: B-tree everything, byte-range integrated log, per-AG parallelism
  Philosophy: purpose-built for parallel, large-scale I/O from day one.
  Key invariant: no fixed-offset metadata; all state in B-trees within AGs.
    AG count tuned to CPU count → metadata parallelism scales with hardware.
  Design era: 1993 (SGI IRIX); mainlined Linux 2001; redesigned for NVMe era.
  Trade-off: complexity and no online shrink in exchange for scale.

Btrfs: CoW B-tree for everything, no fixed structure, multi-device built-in
  Philosophy: bring ZFS-style integrity and snapshot features to Linux.
  Key invariant: never modify a block in-place (unless NODATACOW).
    Every write produces a new block; old blocks freed only when refcount drops to 0.
    This gives atomic snapshots and checksummed data as first-class features.
  Design era: 2007 (Oracle); mainlined 2009; still maturing for some features.
  Trade-off: CoW overhead and fragmentation in exchange for snapshots + integrity.
```

The design philosophy predicts the failure mode:
- ext4 fails when it runs out of inodes (fixed at mkfs) or when metadata layout becomes a bottleneck at high core count
- XFS fails when you need native snapshots, data checksums, or online shrink
- Btrfs fails when workload requires stable random-write performance (CoW fragmentation) or at very large scale

---

## 2. On-Disk Architecture

### Allocation Unit and Metadata Location

| Aspect | ext4 | XFS | Btrfs |
|--------|------|-----|-------|
| Allocation unit | Block Group (BG), fixed 128MB | Allocation Group (AG), tunable (default 1GB) | Block Group (BG), default 1GB data / 256MB metadata |
| Metadata location | Fixed: inode table at BG start, GDT in BG 0 | Dynamic: all metadata in B-trees within each AG | Dynamic: all metadata in CoW B-trees at any logical address |
| Free space tracking | Per-BG buddy bitmap (mballoc) | Per-AG B-trees: BNObt (by address) + CNTbt (by size) | Per-BG free space tree (v2) or free space inodes (v1) |
| Inode allocation | Fixed ratio at mkfs (default 1 inode / 16KB) | Dynamic: 64-inode chunks allocated on demand | Dynamic: inode items in FS tree, no pre-allocation |
| Max file size | 16 TiB (4KB blocks) | 8 EiB | 16 EiB |
| Max filesystem size | 1 EiB (64bit feature) | 8 EiB | 16 EiB |

### Key Structural Difference: What Lives Where

```
ext4:
  Disk is divided into Block Groups. Within each BG:
  [SB copy][GDT copy][BB bitmap][IB bitmap][Inode Table][Data blocks...]
  Metadata at known offsets → O(1) lookup of any inode or block.
  Disadvantage: inode table occupies fixed space at BG start, fragmentation
    of free space is local to each 128MB BG.

XFS:
  Disk is divided into AGs. Each AG is self-contained:
  [AGF (free space B-tree root)][AGI (inode B-tree root)][Data + B-tree nodes]
  All metadata is in B-trees; location varies per transaction.
  Advantage: AGF and AGI locks are independent → parallel allocation.
  Disadvantage: no data checksums; no RAID.

Btrfs:
  No fixed structure at all. Entry point: superblock → root tree → all other trees.
  Logical address space → physical via chunk tree (RAID layer).
  Every tree node has: CRC32c checksum + FSID + generation (transaction ID).
  Advantage: data integrity, snapshots, multi-device.
  Disadvantage: CoW overhead; complexity of multi-tree consistency.
```

---

## 3. Write Path Comparison

Understanding the write path is the foundation for predicting I/O behavior, latency, and fragmentation.

### 3.1 Normal Data Write (buffered, no fsync)

```
ext4 (data=ordered, delalloc):
  write() → page cache (dirty pages)
           → ext4_da_reserve_space(): reserve counter++, no physical block yet
  writeback → ext4_writepages():
               mballoc: allocate contiguous physical blocks for full dirty range
               update extent tree: insert/extend extents in inode
               submit data I/O → wait for completion
               commit metadata to JBD2 journal (ordered: data before metadata)
  Physical block assigned: at writeback time (delalloc)
  Write path coalescing: mballoc sees full dirty range → one large extent

XFS (delalloc):
  write() → page cache (dirty pages)
           → xfs_file_buffered_aio_write(): reserve log space
  writeback → xfs_writepage_map():
               xfs_bmapi_write(): CNTbt finds best-fit free extent
               insert BMBT entry in inode's extent tree
               submit data I/O → wait for completion
               log metadata changes (byte-range log, CIL)
  Physical block assigned: at writeback time (same as ext4 delalloc)
  Write path coalescing: same benefit — allocator sees full dirty range

Btrfs (CoW, no delalloc equivalent for metadata):
  write() → page cache (dirty pages)
  writeback → btrfs_writepages():
               if NODATACOW: overwrite in place (like ext4/XFS)
               if CoW (default):
                 allocate NEW physical blocks for every dirty page
                 update EXTENT_DATA items in FS tree (CoW the B-tree path)
                 add delayed refs for old extent (decrement) and new (increment)
                 submit data I/O to new physical location
                 old physical blocks freed at transaction commit
  Physical block assigned: at writeback (same timing), but always a NEW location
  Write path: never modifies existing data blocks → fragmentation accumulates
```

### 3.2 fsync Write (durability path)

```
ext4 fsync:
  flush dirty data pages (if data=ordered: already done before metadata commit)
  JBD2 commit: write metadata journal blocks + commit block (REQ_FUA | REQ_PREFLUSH)
  Commit block is the durability point.
  Cost: 1 journal commit (may include other threads' dirty metadata = batching)
  Latency: storage_latency × 2 (data + commit) on HDD; ~100-500μs on NVMe

XFS fsync:
  flush dirty data pages
  CIL flush: collect all dirty log items for this inode + any co-committed items
  Write log record batch + commit record (single flush)
  CIL batching: under high concurrency, one fsync flushes work of N threads
  Cost: 1 log flush per fsync call, but amortized over concurrent fsyncs
  Latency: ~50-200μs on NVMe (byte-range log, smaller writes than JBD2)

Btrfs fsync:
  flush dirty data pages
  Log tree update: write INODE_ITEM + EXTENT_DATA items to per-subvolume log tree
  Log tree commit: flush log tree root (single write)
  Cost: log tree is smaller and contains only this inode's changes
  Latency: ~50-200μs on NVMe for log tree commit
  BUT: if a snapshot is taken concurrently → full transaction commit triggered
       (log tree flushed into main trees → expensive)
```

### 3.3 Write Amplification Summary

**Journal/log write amplification per metadata byte changed:**

| Operation | JBD2 (ext4) | XFS log | Btrfs log tree |
|-----------|-------------|---------|----------------|
| Inode size update (8B) | 4096B (full block) | ~56B | ~56B |
| Add directory entry (32B) | 4096B (full dir block) | ~80B | ~80B |
| Allocate 1 block (bitmap+descriptor) | 8192B (2 blocks) | ~120B | N/A (extent tree = delayed ref) |
| File create (inode+dir+alloc) | ~20480B (5 blocks) | ~300B | ~300B |
| **Amplification ratio** | **~300-1000×** | **~7-10×** | **~7-10×** |

**Data write amplification (per 4KB data write):**

| Write type | ext4 | XFS | Btrfs (CoW) | Btrfs (NODATACOW) |
|------------|------|-----|-------------|-------------------|
| Sequential append | 1× | 1× | 1× (new extent, contiguous) | 1× |
| Random overwrite, 1st time | 1× | 1× | 1× (new extent) | 1× |
| Random overwrite, 100th time | 1× | 1× | 1× (new location each time) | 1× |
| **Fragmentation effect** | **Low** | **Minimal** | **Accumulates with each write** | **None** |
| **Metadata write per data write** | ~2-3 blocks (journal+extent) | ~1-2 log records | ~3-4 blocks (CoW path) | ~1-2 (no CoW) |

---

## 4. Concurrency and Locking

### 4.1 Lock Granularity

```
ext4:
  Per-BG allocation lock: struct rw_semaphore alloc_sem (one per 128MB BG)
  Lock held during: buddy bitmap scan + block bitmap update + BG descriptor update
  Hold time: O(ms) on fragmented BG (full bitmap scan)
  Effective parallelism: min(threads, BG_count_being_written_to)

  In practice:
  - Files in the same directory land in the same BG → same lock
  - 32 threads creating files in /data: all compete for one alloc_sem
  - Saturates at ~2-4 cores; rest spin on alloc_sem

XFS:
  Per-AG allocation lock: xfs_buf lock on AGF buffer (one per AG, default 1 per CPU)
  Lock held during: B-tree search + update (CNTbt + BNObt)
  Hold time: O(μs) — B-tree traversal of 3-4 levels
  Effective parallelism: min(threads, agcount) with AG rotation under contention

  In practice:
  - Files in different directories → different AGs → different locks
  - 32 threads creating files: XFS rotates across AGs automatically
  - Scales to 24+ cores before log becomes the bottleneck (not allocation)

Btrfs:
  Per-subvolume transaction lock: btrfs_transaction (one per filesystem, not per-subvolume)
  Lock type: reference-counted handle (btrfs_trans_handle)
  Multiple handles can be open concurrently within one transaction
  Serialization point: transaction commit (only one commit at a time)

  In practice:
  - Multiple writers within one transaction DO run in parallel
  - Each writer CoWs its own B-tree path (different leaf nodes → no conflict)
  - But: CoW always allocates from the same block group pool → bg lock contention
  - Free space tree (v2) has its own lock: contended under high metadata churn
  - Worst case: many small file creates → all touch the same metadata BG → serialized
```

### 4.2 Concurrency Scaling Model

```
Throughput vs thread count (file create workload, approximate):

  ext4:
    1-4 threads:   near-linear (single BG can keep up)
    4-8 threads:   plateau (alloc_sem becomes bottleneck)
    8-32 threads:  flat or degraded (lock queue grows)
    Ceiling: ~4-8× single-thread throughput

  XFS:
    1-N threads (N=agcount): near-linear (each thread in own AG)
    N+ threads:   plateau (log becomes bottleneck, not allocation)
    With external log on NVMe: plateau delayed further
    Ceiling: ~16-24× single-thread throughput at agcount=32

  Btrfs:
    1-4 threads:   near-linear (transaction handles run in parallel)
    4-16 threads:  plateau (metadata BG lock + free space tree contention)
    16+ threads:   may degrade (transaction commit serializes all threads)
    CoW also generates more extent tree updates → more delayed refs to process
    Ceiling: ~4-8× single-thread throughput (similar to ext4 in practice)

Rule of thumb:
  High-concurrency metadata (> 8 threads, > 50K file ops/sec): choose XFS.
  Single-digit concurrency, < 10K file ops/sec: all three are acceptable.
```

---

## 5. Journal, Log, and Recovery

### 5.1 Journal Architecture

| Aspect | ext4 (JBD2) | XFS (log) | Btrfs (log tree + transaction) |
|--------|-------------|-----------|-------------------------------|
| Layer | Separate (`fs/jbd2/`) | Integrated (`fs/xfs/xfs_log.c`) | Integrated (log tree + CoW commit) |
| Granularity | Full 4KB block | Byte-range log vectors | Byte-range (log tree) + full node (CoW) |
| Journal modes | writeback / ordered / journal | Single (ordered semantics) | Single (CoW = always ordered) |
| Batching | Per-transaction batch | CIL (Committed Item List) | Log tree batches; CoW batches in transaction |
| Journal size | 128MB–1GB typical | 512MB–4GB typical | No fixed journal; transaction size varies |
| External journal | Yes (`-J device=`) | Yes (`-l logdev`) | N/A (no separate journal file) |
| Recovery passes | 3 (SCAN → REVOKE → REPLAY) | 5 (head/tail → validate → replay → intents → unlinked) | Superblock generation check + log tree replay |

### 5.2 Recovery Mechanics

```
ext4 crash recovery:
  1. Mount → JBD2 detects dirty journal (s_state != EXT4_VALID_FS)
  2. SCAN pass: walk journal forward, find last valid commit block
  3. REVOKE pass: collect revoke records (freed blocks not to replay)
  4. REPLAY pass: apply committed blocks to their on-disk locations
  Duration: seconds (journal is small, full-block replay)
  Guarantee: all committed transactions are fully replayed; uncommitted are discarded.
  Risk: if journal itself is corrupt → e2fsck needed (offline)

XFS crash recovery:
  Phase 1: Find log head and tail (latest commit sequence number)
  Phase 2: Validate log records (checksum, FSID, LSN ordering)
  Phase 3: Replay log records (apply byte-range changes to AG metadata)
  Phase 4: Process intent/done pairs:
    Incomplete EFI (free extent intent) without EFD (done) → finish the free
    Incomplete BUI/RUI/CUI → finish the update
    This is the key XFS advantage: multi-B-tree operations are atomic
  Phase 5: Recover unlinked inodes (files deleted but still open at crash)
  Duration: seconds (byte-range log is compact)
  Guarantee: all committed transactions + partially-committed intent/done pairs
    are correctly resolved. No incomplete multi-step operations left dangling.

Btrfs crash recovery:
  Mechanism 1: CoW transaction commit
    If crash before superblock write: previous superblock still valid
    All trees reflect state of last committed transaction
    No replay needed: the on-disk state IS the consistent state
  Mechanism 2: Log tree replay (for fsynced data not yet in main commit)
    If log_root != 0 in superblock: replay log tree for affected subvolumes
    Log tree replay: apply INODE_ITEM + EXTENT_DATA items to FS trees
    Duration: seconds (log tree is small)
  Guarantee: all committed transactions + all fsynced data recovered.
    Data written since last fsync/commit may be lost (same as ext4 ordered).
  No recovery passes needed for non-log metadata: CoW guarantees consistency.
```

### 5.3 Recovery Speed and Complexity

```
Recovery duration (approximate, per filesystem size):

  FS size     ext4 JBD2    XFS log      Btrfs
  1 GB        < 1 sec      < 1 sec      < 1 sec
  1 TB        1-5 sec      1-5 sec      1-5 sec (log tree only)
  100 TB      5-30 sec     5-30 sec     5-30 sec (log tree only)
  NOTE: This is journal/log replay only, not fsck. fsck is far slower.

  After journal replay, filesystem is mounted. No scan of inodes/blocks needed.
  JBD2 and XFS log are small (< 4GB) relative to data volume.
  Btrfs CoW eliminates journal replay for most metadata changes.

Complexity comparison for partial operations:
  ext4: REVOKE records handle the most common partial operation case.
    Multi-step operations (e.g., rename across directories) may leave
    inconsistencies if not all steps are journaled atomically.

  XFS: Intent/done pairs explicitly handle complex multi-B-tree operations.
    An incomplete rename, reflink, or inode allocation can always be
    completed or rolled back deterministically. Most robust recovery model.

  Btrfs: CoW inherently handles partial writes (old state preserved).
    The risk is in the log tree: log tree replay is less well-tested
    than the main CoW commit path. For maximum safety: use fsync sparingly
    or accept the cost of full transaction commits.
```

---

## 6. Data Integrity

This is the dimension where Btrfs is architecturally distinct.

### 6.1 Checksum Coverage

| What is checksummed | ext4 | XFS | Btrfs |
|---------------------|------|-----|-------|
| Superblock | Yes (since ~3.5) | Yes (v5) | Yes (always) |
| Inode table blocks | Yes (metadata_csum) | Yes (v5) | Yes (always) |
| Directory blocks | Yes (metadata_csum) | Yes (v5) | Yes (always) |
| Free space bitmaps | Yes (metadata_csum) | Yes (v5) | Yes (always) |
| B-tree nodes | Yes (metadata_csum) | Yes (v5) | Yes (always) |
| **Data blocks (file content)** | **No** | **No** | **Yes (always)** |
| Stale block detection (LSN) | No | **Yes (v5 LSN in every block)** | Partial (generation in every block) |

**The data checksum gap:** Silent data corruption (storage controller error, bit-rot, bad cable) that affects a data block is invisible to ext4 and XFS. The filesystem returns the corrupted data without any indication. Btrfs catches this on every read and can repair it (with RAID-1).

**LSN vs generation for stale block detection:**

```
XFS: every metadata block contains the LSN (log sequence number) of the last
  transaction that wrote it. On read, XFS verifies: block_LSN ≤ current_log_head.
  If block_LSN > current log head: this block is from the future → stale → reject.
  Catches: write barrier failures where a stale cached block survives a crash.

Btrfs: every node contains the transaction ID (generation) when it was last CoW'd.
  Parent node records the generation of its child at the time of writing.
  On read: child.header.generation must match parent.key_ptr.generation.
  Catches: stale block reads (old cached content served instead of new).

ext4: no LSN in metadata blocks. Checksum covers content but not ordering.
  Cannot detect stale block replay after write barrier failure.
  Risk: on hardware without power-loss protection (consumer SSDs), a barrier
  failure could leave old metadata blocks on disk → invisible corruption.
```

### 6.2 Scrub and Repair

| Capability | ext4 | XFS | Btrfs |
|------------|------|-----|-------|
| Online corruption detection | No (e2scrub via LVM snapshot, limited) | **Yes** (xfs_scrub) | **Yes** (btrfs scrub) |
| Online metadata repair | No | **Yes** (xfs_scrub -x) | Partial (only with RAID-1/10) |
| Online data repair | No | No (no data checksums) | **Yes** (with RAID-1/10) |
| Offline check tool | e2fsck | xfs_repair | btrfs check |
| Offline check speed (50TB) | ~1-2 hours | ~15-30 min | ~30-60 min |
| Why online repair is possible | — | RMAP → O(1) ownership lookup | Data checksums + RAID mirror |
| Scheduled scrub | e2scrub (LVM dependency) | `xfs_scrub -s` (systemd timer) | `btrfs scrub start` (no dependency) |

```
xfs_scrub online repair mechanism (RMAP required):
  For each physical extent X:
    Look up RMAPbt(X) → owner (inode + offset)  ← O(1) thanks to RMAP
    Look up inode's BMBT → verify it references X ← O(depth) = O(log N)
    If mismatch: repair in place under brief AGF write lock
  Total time: O(physical_blocks × log(FS_size)) — online, no downtime

btrfs scrub mechanism:
  For each block group:
    Read every block, verify CRC32c checksum
    If mismatch AND RAID-1: read from mirror → return good copy → correct on-disk
    If mismatch AND no mirror: report error, cannot repair
  Total time: limited by sequential read speed (reads entire FS)
  CPU: low (hardware CRC acceleration on modern CPUs)
```

---

## 7. Allocation and Fragmentation

### 7.1 Allocation Algorithm Comparison

```
ext4 mballoc:
  Per-BG buddy allocator (binary buddy system).
  Find smallest order ≥ request with free run.
  Preallocation: per-inode PA (doubles window for sequential) + LG PA (per-CPU, small files).
  Delalloc: physical block assigned at writeback, not at write() → coalescing.
  Cross-BG contiguous allocation: impossible (each BG's buddy is independent).
  Max contiguous run: 128MB (one BG).

XFS allocator:
  Per-AG B-tree search: CNTbt (sorted by size) → best-fit first.
  Speculative preallocation: aggressively pre-allocates for growing files.
  Extent size hints: application can request minimum extent size.
  Cross-AG contiguous allocation: not possible (AG-local allocation).
  Max contiguous run: AG size (default 1GB) — 8× larger than ext4 BG.

Btrfs allocator:
  Per-BG free space tree (or bitmap for v1).
  New extents always allocated to fresh physical locations (CoW).
  Locality: tries to allocate near existing extents of the same inode.
  No preallocation window equivalent (CoW makes it less relevant).
  fallocate(): creates PREALLOC extents (like XFS unwritten).
  Max contiguous run: block group size (default 1GB for data).
```

### 7.2 Fragmentation Trajectory Over Time

This is the most important practical difference for long-running filesystems:

```
ext4 fragmentation:
  Cause: mballoc allocates from partially-used BGs over time.
    New files placed in non-contiguous runs as BGs fill up.
    Deleted files leave holes → buddy buddy merges them but imperfectly.
  Profile: moderate initial fragmentation; gradual degradation over months.
  Worst case: filesystem > 85% full → cr=3 allocation → high fragmentation.
  Mitigation: keep < 85% full; e4defrag (online); ext4 free space compaction.
  Rate of degradation: slow (months to years for noticeable impact on HDD).

XFS fragmentation:
  Cause: CNTbt best-fit limits fragmentation significantly.
    Speculative preallocation reduces fragmentation for sequential writes.
    RMAP enables precise space reclaim.
  Profile: low baseline; very slow degradation.
  Worst case: filesystem > 90% full + many small files → fragmentation.
  Mitigation: xfs_fsr (online defrag); keep < 85% full.
  Rate of degradation: very slow (years under normal workload).

Btrfs fragmentation:
  Cause: CoW ALWAYS writes to a new location.
    Each overwrite of any block → new physical block allocated.
    After 100 overwrites of the same file → 100 scattered extents.
  Profile: fragmentation starts immediately for random-write workloads.
    After 6-12 months of database-style usage: performance severely degraded.
  Worst case: random-write database file → thousands of extents per file.
  Mitigation:
    chattr +C (NODATACOW): eliminates CoW for that file/directory.
    btrfs filesystem defragment: rewrite file contiguously (BREAKS reflinks).
    Accept degradation and schedule periodic defragment.
  Rate of degradation: fast (weeks to months under random-write workload).

Fragmentation resistance ranking: XFS > ext4 >> Btrfs (for random-write workloads)
For append/write-once workloads: all three are equivalent.
```

### 7.3 Space Efficiency

```
ext4:
  Reserved blocks: 5% default (tune2fs -m); reclaim with -m 1 for large volumes.
  Inode table: fixed at mkfs; wastes space if -i ratio is too small.
    Default 1 inode / 16KB → inode table = 1/16 of total capacity used for inodes.
    For small-file workloads: use -i 4096 (larger inode table, less data space).
  Journal: 128MB–1GB; dedicated space but tunable.
  Overhead: ~2-6% of total capacity for metadata.

XFS:
  No fixed inode table: inodes allocated on demand in 64-inode chunks.
  No reserved blocks (root restriction different from ext4).
  Log: 512MB–4GB but separate device is common for production.
  AG alignment: ~0.1% overhead per AG boundary.
  Overhead: ~1-3% of total capacity for metadata (lower than ext4).

Btrfs:
  Metadata block groups: 256MB each, allocated as needed.
  CoW generates duplicate metadata during transactions (old + new blocks exist simultaneously).
  With 100 snapshots: tree nodes shared where unchanged, new nodes for changed paths.
    Space usage depends on how diverged snapshots are.
  Overhead without snapshots: ~2-5% for metadata.
  Overhead with 100 active snapshots: varies widely (1× to 5× data size in worst case).
  qgroups (quota): adds significant overhead to all extent operations; disable if not needed.
  Actual free space: 'btrfs filesystem df' more useful than 'df' (shows DATA vs METADATA).
```

---

## 8. Snapshot and CoW Feature Comparison

| Feature | ext4 | XFS | Btrfs |
|---------|------|-----|-------|
| Native snapshots | No | No | **Yes** (O(1) creation) |
| Snapshot via LVM thin | Yes | Yes | Yes (but redundant) |
| Reflinks (cp --reflink) | Yes (kernel 4.16+) | Yes (v5, since kernel 4.9) | **Yes** (always) |
| CoW on write | No (direct overwrite) | No (direct overwrite) | **Yes** (unless NODATACOW) |
| Snapshot delete cost | N/A | N/A | O(snapshot FS tree size) — hours for large snaps |
| Incremental replication | Via rsync (no native) | Via rsync (no native) | **btrfs send/receive** (byte-efficient) |
| Deduplication | No (use VDO) | No (use VDO) | In-band (bees/duperemove) |
| Transparent compression | No | No | **Yes** (zstd/lzo/zlib, per-file) |

**Reflinks: not the same as snapshots:**
```
Reflink (cp --reflink): two files share the same physical extents.
  Both ext4, XFS, and Btrfs support this.
  Uses the extent reference counting mechanism.
  Granularity: file-level (only the copied file is shared).

Snapshot (Btrfs native): entire subvolume tree is shared at the B-tree level.
  Includes inodes, directory entries, all extents → all shared instantly.
  ext4/XFS have no equivalent — they can only reflink individual files.
  For backup: Btrfs snapshots capture entire subvolume state in O(1).
```

---

## 9. Multi-Device and RAID

| Capability | ext4 | XFS | Btrfs |
|------------|------|-----|-------|
| Native multi-device | No | No | **Yes** (chunk tree maps logical → N devices) |
| Native RAID | No | No | **Yes** (RAID0/1/10/1C3/1C4) |
| RAID5/6 | Via mdadm | Via mdadm | Built-in (UNSAFE — write hole bug) |
| Recommended RAID approach | mdadm + ext4 | mdadm or LVM + XFS | Btrfs RAID1/10 for simple; mdadm + Btrfs single for parity |
| Different RAID for data/metadata | No | No | **Yes** (-d raid0 -m raid1) |
| Per-block checksum + RAID repair | No | No | **Yes** (scrub reads + corrects from mirror) |
| Balance (change RAID profile) | No | No | **Yes** (btrfs balance — online but slow) |

**The critical point:** For RAID-1 with data integrity verification and repair, Btrfs is the only native Linux option. ext4 and XFS on mdadm RAID-1 cannot verify that the mirrored copy was written correctly (no data checksums). Btrfs RAID-1 scrub verifies both copies against their checksums and silently heals the bad one.

---

## 10. Online Maintenance Operations

| Operation | ext4 | XFS | Btrfs |
|-----------|------|-----|-------|
| Online grow | Yes (resize2fs) | Yes (xfs_growfs) | Yes (btrfs filesystem resize) |
| Online shrink | No | No | Yes (btrfs filesystem resize -NGB /mnt) |
| Online defrag | Yes (e4defrag) | Yes (xfs_fsr) | Yes (btrfs defrag — breaks reflinks) |
| Online check | Limited (e2scrub via LVM) | **Yes** (xfs_scrub) | **Yes** (btrfs scrub) |
| Online balance | No | No | **Yes** (redistribute data across devices) |
| Add device (online) | No | Yes (xfs_growfs -n) | **Yes** (btrfs device add) |
| Remove device (online) | No | No | **Yes** (btrfs device delete, if space allows) |
| Offline repair | e2fsck (slow for large FS) | xfs_repair (faster at scale) | btrfs check (slowest at scale) |

**Btrfs online shrink is unique:** Neither ext4 nor XFS supports online shrink. Btrfs `filesystem resize -NGB /mnt` shrinks the logical address space; combined with `balance` to move data out of the freed range, this enables online volume reduction.

---

## 11. Failure Mode Comparison

### ext4 Failure Modes

| Failure | Symptom | Diagnosis | Fix |
|---------|---------|-----------|-----|
| Inode exhaustion | ENOSPC despite free blocks | `df -i` → IUse% = 100% | Cannot fix online; reformat with `-i 4096` |
| Journal corruption | Mount fails, JBD2 error | `dmesg | grep JBD2` | `e2fsck -f`; recreate journal |
| BG fragmentation | Write speed degrades | `e2freefrag /dev/sdX` | `e4defrag`; keep < 85% full |
| Metadata overwrite (writeback mode) | Stale data after crash | None (by design) | Use `data=ordered` for non-database workloads |
| Filesystem full (reserved blocks) | ENOSPC at 95% | `df -h` shows 95%+ | `tune2fs -m 1` to reduce reserved |

### XFS Failure Modes

| Failure | Symptom | Diagnosis | Fix |
|---------|---------|-----------|-----|
| Log exhaustion | Write stalls, `xfsaild` spinning | `dmesg | grep xfs`; `xfs_logprint` | Larger log; external log on NVMe |
| AG lock contention | High CPU wait in `__xfs_buf_lock` | `perf top` shows buf lock | Increase agcount at mkfs time |
| Fragmentation spiral | Sequential throughput drops | `xfs_db -c frag /dev/sdX` | `xfs_fsr`; keep < 85% full |
| ENOSPC with free space | ENOSPC despite df showing space | `xfs_info`; check AG free distribution | `xfs_repair -n` to inspect; balance AGs |
| Unlinked inode list | Long mount after crash | Phase 5 in xfs_repair output | Normal; xfs_repair processes it |

### Btrfs Failure Modes

| Failure | Symptom | Diagnosis | Fix |
|---------|---------|-----------|-----|
| Metadata ENOSPC | ENOSPC despite data free | `btrfs filesystem df` → metadata full | `btrfs balance -dusage=50` |
| CoW fragmentation | Slow reads after months | `filefrag -v file` → thousands of extents | `btrfs defrag` (breaks reflinks) or NODATACOW |
| Slow snapshot delete | Disk full during deletion | `btrfs subvolume list -s` shows DELETED | Wait for btrfs-cleaner; balance if needed |
| RAID-5/6 corruption | Silent data loss after crash | `btrfs scrub` reports errors | Use mdadm RAID instead; cannot repair |
| qgroup stalling | Metadata operations slow | `btrfs qgroup show` slow to complete | Disable qgroups if not needed |
| Transaction abort | FS goes read-only suddenly | `dmesg | grep BTRFS` → "Transaction aborted" | `btrfs check --repair /dev/sdX` (risky); restore from backup |

---

## 12. RTO and Operational Implications

```
Recovery Time Objective (RTO) after unplanned crash:

  ext4:
    Journal replay: seconds → filesystem mounted
    If journal corrupt: e2fsck → 50TB = 1-2 hours offline
    Scheduled fsck: monthly (tune2fs -i 30) → plan maintenance window
    RTO commitment: 99.9% achievable (seconds per crash, rare long e2fsck)

  XFS:
    Log replay: seconds → filesystem mounted
    If log corrupt: xfs_repair → 50TB = 15-30 minutes offline
    Online scrub: xfs_scrub catches issues before they cascade → no unplanned downtime
    RTO commitment: 99.99% achievable (online repair eliminates most maintenance windows)

  Btrfs:
    CoW recovery: seconds (no replay for CoW metadata)
    Log tree replay: seconds (if fsynced data present)
    If trees corrupt: btrfs check (offline) → 50TB = 30-60 minutes
    If severe: btrfs restore (extract readable data) → restore from backup
    Scrub: detects data corruption; can repair with RAID-1
    RTO commitment: 99.9% for stable use cases; risk of transaction abort for heavy
      random-write workloads → avoid for those
```

---

## 13. Decision Framework

### Primary Decision Tree

```
1. Do you need native snapshots or incremental replication?
   YES → Btrfs (if workload is write-once/append) or LVM thin + XFS/ext4
   NO  → continue to 2

2. Do you need data block checksums (bit-rot detection for archival)?
   YES → Btrfs (only option)
   NO  → continue to 3

3. Is the filesystem > 5TB or do you have > 8 CPUs writing concurrently?
   YES → XFS (AG-level parallelism; xfs_scrub for online repair; no inode exhaustion)
   NO  → continue to 4

4. Is this a boot/root partition or a small (<1TB) general-purpose volume?
   YES → ext4 (universal support, simple, stable)
   NO  → XFS (better long-term fragmentation resistance; online repair)
```

### Workload Matrix

| Workload | Choice | Why |
|----------|--------|-----|
| PostgreSQL / MySQL primary | **XFS** | Stable write latency; no CoW overhead; external log reduces fsync |
| MongoDB / RocksDB (LSM) | **XFS** | Sequential write-heavy; good large extent allocation |
| VM image store (KVM, libvirt) | **XFS** (stable perf) or **Btrfs** (snapshots) | XFS if no snapshot need; Btrfs with NODATACOW + snapshots |
| Container runtime (Docker/Podman) | **Btrfs** or ext4 (overlay) | Btrfs native overlay; fast per-image snapshots |
| Backup destination | **Btrfs** | send/receive + CLONE; scrub detects corruption |
| Archival (10+ years) | **Btrfs** with RAID-1 | Data checksums + automatic repair; only option for data integrity |
| NFS server (many clients) | **XFS** | Per-AG parallelism handles concurrent NFS requests; stable |
| HPC scratch (large sequential) | **XFS** | 1GB AG extents; minimal fragmentation; fast parallel writes |
| Kubernetes PV on NVMe | **XFS** | Per-AG concurrency; fast metadata; predictable latency |
| CI/CD build cache | **Btrfs** | Subvolume per-job; instant snapshot for cache layers |
| Embedded / IoT | **ext4** | Universally supported; smallest footprint; simplest recovery |
| Boot / root partition | **ext4** | Broadest bootloader support; no surprises |
| Write-once media archive | **Btrfs** | Checksums detect gradual bit-rot; send/receive for off-site copy |
| High-IOPS OLTP (> 100K IOPS) | **XFS** | XFS allocation doesn't degrade at high IOPS; Btrfs CoW overhead too high |

### When Each Filesystem Fails You

```
Choose ext4 and regret it when:
  - You create 10M small files → inode table exhausted (fixed at mkfs, no fix online)
  - You add 16 CPU cores → allocation still serialized on same BG lock
  - Storage controller fails with write barrier → stale metadata, silent ext4
  - You need to know if your 5-year-old archive has bit-rot → no data checksums

Choose XFS and regret it when:
  - You need instant rollback (XFS has no native snapshots → LVM thin = complexity)
  - Storage hardware is bit-rotting (XFS has no data checksums → silent corruption)
  - You need to shrink a volume online (xfs_growfs only grows)
  - You need per-file RAID (not possible; XFS uses mdadm/LVM for redundancy)

Choose Btrfs and regret it when:
  - You run PostgreSQL without chattr +C → CoW fragmentation → perf crater in 6 months
  - You accumulate 500 snapshots → snapshot delete stalls for hours; disk appears full
  - You use RAID-5/6 → data loss after power failure (documented write hole bug)
  - Your filesystem grows past 100TB → btrfs check takes hours; scrub takes days
  - Transaction abort under disk pressure → FS goes read-only → immediate outage
```

---

## 14. Production Configuration Cheat Sheet

### mkfs quick reference

```bash
# ext4 — general NVMe data volume
mkfs.ext4 -b 4096 -m 1 -J size=1024 \
  -E lazy_itable_init=0,lazy_journal_init=0 \
  /dev/nvme0n1p1

# ext4 — small-file / container workload
mkfs.ext4 -b 4096 -i 4096 -m 1 \
  -O inline_data \
  -E lazy_itable_init=0,lazy_journal_init=0 \
  /dev/nvme0n1p1

# XFS — NVMe, 32-core server
mkfs.xfs -b size=4096 \
  -d agcount=64 \
  -l size=2g,version=2 \
  /dev/nvme0n1p1

# XFS — with external log on separate NVMe
mkfs.xfs -d agcount=32 \
  -l logdev=/dev/nvme1n1p1,size=4g \
  /dev/nvme0n1p1

# Btrfs — single device, backup destination
mkfs.btrfs --csum xxhash \
  --features free-space-tree \
  /dev/sdb

# Btrfs — RAID-1 (data + metadata mirrored)
mkfs.btrfs -d raid1 -m raid1 \
  --csum xxhash \
  --features free-space-tree \
  /dev/sda /dev/sdb
```

### Mount options quick reference

```bash
# ext4 — database (O_DIRECT, manage own durability)
mount -o data=writeback,noatime,errors=remount-ro /dev/sdX /dbdata

# ext4 — general
mount -o data=ordered,noatime,commit=5,errors=remount-ro /dev/sdX /data

# XFS — general NVMe
mount -o noatime,logbufs=8,logbsize=256k /dev/nvme0n1p1 /data

# XFS — with external log
mount -o noatime,logdev=/dev/nvme1n1p1 /dev/nvme0n1p1 /data

# Btrfs — backup destination
mount -o space_cache=v2,noatime,compress=zstd:1,commit=60 /dev/sdb /backup

# Btrfs — container runtime
mount -o space_cache=v2,noatime,compress=zstd:1 /dev/nvme0n1p1 /var/lib/containers
```

### Key operational commands

```bash
# ext4
tune2fs -l /dev/sdX           # filesystem parameters
e2freefrag /dev/sdX           # free space fragmentation
e4defrag /mountpoint/         # online defrag
e2fsck -fp /dev/sdX           # offline repair (unmounted)
tune2fs -J device=/dev/nvme1  # add external journal

# XFS
xfs_info /mountpoint          # filesystem parameters
xfs_db -c frag /dev/sdX       # fragmentation report
xfs_fsr /mountpoint           # online defrag
xfs_scrub /mountpoint         # online check + repair
xfs_repair /dev/sdX           # offline repair (unmounted)
xfs_growfs /mountpoint        # online grow

# Btrfs
btrfs filesystem df /mnt               # data/metadata usage breakdown
btrfs filesystem show /dev/sdX         # device stats
btrfs scrub start/status /mnt          # data integrity check + repair
btrfs balance start -dusage=50 /mnt    # compact block groups
btrfs filesystem defragment -r /mnt    # online defrag (breaks reflinks)
btrfs subvolume snapshot -r /mnt/data /mnt/snap  # read-only snapshot
btrfs send -p /mnt/snap1 /mnt/snap2 | ssh host btrfs receive /backup/
btrfs check /dev/sdX                   # offline check (slow)
btrfs rescue zero-log /dev/sdX         # clear corrupt log tree (emergency)
```

---

## Quick Reference Card

```
PHILOSOPHY:
  ext4  = fixed layout + JBD2 journal  → simple, universal, bounded scale
  XFS   = B-tree everything + CIL log  → parallel, scalable, no data checksum
  Btrfs = CoW B-tree + no fixed struct → snapshots, integrity, fragmentation risk

CHOOSE:
  ext4  → boot/root, < 1TB general, broadest compatibility
  XFS   → > 1TB, > 8 CPUs, production databases, NFS, HPC
  Btrfs → backups, archival, containers, snapshot-heavy, bit-rot detection

NEVER:
  ext4  → inode-dense workloads without -i 4096 at mkfs
  XFS   → when you need native snapshots or data checksums
  Btrfs → RAID-5/6, > 100TB, production random-write without NODATACOW

CONCURRENCY:
  ext4: saturates ~4-8 threads (BG alloc_sem O(ms) hold time)
  XFS:  scales to agcount threads (AGF lock O(μs) hold time)
  Btrfs: saturates ~4-8 threads (metadata BG + transaction serialization)

JOURNAL WA (per 8-byte metadata change):
  ext4: ~4096 bytes (full block)
  XFS:  ~56 bytes (byte-range log vector)
  Btrfs: ~56 bytes (byte-range log tree) + CoW overhead for data

RECOVERY:
  ext4: seconds (JBD2 replay, 3 passes)
  XFS:  seconds (byte-range log replay, 5 phases with intent/done)
  Btrfs: seconds (CoW consistency; log tree replay for fsynced data)

FRAGMENTATION AGING (random-write workload):
  ext4: slow (months)   XFS: very slow (years)   Btrfs: fast (weeks)

DATA CHECKSUMS:
  ext4: no    XFS: no (metadata only)    Btrfs: YES (data + metadata)
```
