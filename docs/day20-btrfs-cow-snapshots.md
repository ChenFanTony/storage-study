# Day 20: Btrfs — CoW B-tree, Snapshots & Send/Receive

## Learning Objectives
- Understand Btrfs's CoW B-tree as the foundation for all Btrfs features
- Follow snapshot creation and the subvolume model at source level
- Understand send/receive stream format and its use in backup/replication
- Know Btrfs's production limits and where it fails
- Know when to recommend Btrfs vs XFS for backup/snapshot architectures

---

## 1. Btrfs's Core: The CoW B-tree

Everything in Btrfs — data, metadata, snapshots, subvolumes — is stored
in a single CoW (copy-on-write) B-tree. Understanding this tree is the key
to understanding all Btrfs features.

```
Btrfs on-disk structure:

Superblock
  └── Root tree (tree of trees)
       ├── FS tree (filesystem data/metadata)
       │    ├── inode items
       │    ├── dir items
       │    └── extent data items → data extents on disk
       ├── Extent tree (tracks allocated disk blocks)
       ├── Chunk tree (maps logical → physical addresses)
       ├── Dev tree (device management)
       └── Subvolume trees (one per subvolume/snapshot)
            ├── subvol A tree (independent filesystem tree)
            └── subvol B tree (snapshot = copy of tree root pointer)
```

### CoW B-tree mechanics

```c
// fs/btrfs/ctree.c — the CoW B-tree implementation

// Every modification:
// 1. Do NOT modify the existing node
// 2. Copy the node to a new location
// 3. Modify the copy
// 4. Update parent to point to new copy
// 5. Old node becomes free space (after transaction commits)

btrfs_cow_block(trans, root, buf, parent, parent_slot, cow_ret):
    // Allocate new block
    new = btrfs_alloc_tree_block(trans, root, ...)
    // Copy content from old block
    copy_extent_buffer(new, buf, ...)
    // Link parent to new block
    btrfs_set_node_blockptr(parent, parent_slot, new->start)
    // Old block will be freed at transaction commit
```

**Why CoW B-tree enables snapshots:**
```
Before snapshot:
  Root → Node A → Node B → Leaf (data)

Create snapshot (instant — just copy root pointer):
  FS root   → Node A → Node B → Leaf (data)
  Snap root → Node A ↗           (same nodes, reference counted)

Modify data in FS (triggers CoW path from root to leaf):
  FS root   → Node A' → Node B' → Leaf' (new data)
  Snap root → Node A  → Node B  → Leaf  (original data, unchanged)

Cost: CoW copies only the path from root to modified leaf
      O(log N) copies per modification, not full tree copy
```

---

## 2. Subvolumes and Snapshots

```bash
# Create subvolumes
btrfs subvolume create /mnt/btrfs/subvol_a
btrfs subvolume create /mnt/btrfs/subvol_b

# List subvolumes
btrfs subvolume list /mnt/btrfs

# Create read-write snapshot of subvol_a
btrfs subvolume snapshot /mnt/btrfs/subvol_a /mnt/btrfs/snap_a_rw

# Create read-only snapshot (for send/receive)
btrfs subvolume snapshot -r /mnt/btrfs/subvol_a /mnt/btrfs/snap_a_ro

# Snapshots are instant (microseconds regardless of subvolume size)
time btrfs subvolume snapshot -r /mnt/btrfs/large_subvol /mnt/btrfs/snap_instant
# real 0m0.003s — just a new root pointer, no data copy
```

```c
// fs/btrfs/subpage.c, fs/btrfs/volumes.c

// Snapshot creation:
btrfs_snapshot_root():
    // 1. Allocate new tree root item
    // 2. Copy root node reference (NOT the entire tree)
    // 3. Increment reference counts on shared nodes
    // 4. Insert new root into root tree
    // Transaction commits → snapshot is permanent
    // Total: O(1) — constant time regardless of data size
```

---

## 3. Send/Receive: The Backup Architecture

Btrfs send/receive generates a stream of changes between two snapshots,
enabling efficient incremental backups and replication.

```
Full send (no parent):
  Generates stream describing all data in snapshot
  Stream contains: create dirs, create files, write data for every byte

Incremental send (with parent snapshot):
  Compares two snapshots → generates only the DIFFERENCES
  Stream contains: only changed/added/deleted files since parent snapshot
  
  Efficiency: 1TB filesystem with 1MB changed → ~1MB send stream
```

```bash
# Full backup (initial)
btrfs subvolume snapshot -r /mnt/btrfs/data /mnt/btrfs/snap_20260401
btrfs send /mnt/btrfs/snap_20260401 | btrfs receive /mnt/backup/

# Incremental backup (daily)
btrfs subvolume snapshot -r /mnt/btrfs/data /mnt/btrfs/snap_20260402
btrfs send -p /mnt/btrfs/snap_20260401 /mnt/btrfs/snap_20260402 \
    | btrfs receive /mnt/backup/

# Send over network (SSH)
btrfs send /mnt/btrfs/snap_20260402 | ssh backup-server btrfs receive /backup/

# Send to file (for offline backup)
btrfs send /mnt/btrfs/snap_20260402 > /backup/snap_20260402.btrfs
btrfs receive /mnt/restore/ < /backup/snap_20260402.btrfs
```

### Send stream format

```c
// fs/btrfs/send.c — send stream generation

// Stream header:
struct btrfs_stream_header {
    char    magic[sizeof(BTRFS_SEND_STREAM_MAGIC)]; // "btrfs-stream"
    __le32  version;                                 // stream version (1 or 2)
};

// Commands in stream:
// BTRFS_SEND_C_MKFILE    — create file
// BTRFS_SEND_C_MKDIR     — create directory
// BTRFS_SEND_C_WRITE     — write data to file
// BTRFS_SEND_C_CLONE     — clone extent (reflink — same data, no transfer)
// BTRFS_SEND_C_UPDATE_EXTENT — update extent (for incremental)
// BTRFS_SEND_C_RENAME    — rename file/dir
// BTRFS_SEND_C_UNLINK    — delete file

// Key optimization: CLONE command
// If two files share an extent (via reflink), send uses CLONE:
// → receiver relinks the extent (no data transfer over network)
// → deduplication is preserved across backup
```

---

## 4. CoW Fragmentation Over Time

This is Btrfs's main production performance problem:

```
Initial state: 1GB file, one contiguous extent

After 1 year of small modifications (CoW path):
  1GB file → 50,000 small extents scattered across device
  Sequential read of file: 50,000 seeks (or random NVMe reads)
  
  Why: each small write → CoW of that block → new location
       over time, file's extents spread across entire device
```

```bash
# Check fragmentation of a Btrfs file
btrfs filesystem defragment -v -r /mnt/btrfs/fragmented_file  # fix it
# OR check before fixing:
filefrag -v /mnt/btrfs/fragmented_file
# Shows extent count — high count = fragmented

# Filesystem-wide defragmentation (online, but I/O intensive)
btrfs filesystem defragment -r /mnt/btrfs/
# WARNING: this BREAKS reflinks and snapshots for defragmented files
#          (CoW extents get re-written as non-shared extents)
#          Use with caution if you rely on snapshots for dedup savings
```

---

## 5. Checksums: Btrfs's Unique Data Integrity Feature

```bash
# Btrfs checksums all data and metadata by default
# Algorithm: crc32c (default), xxhash, sha256, or blake2b

# Check checksum algorithm in use
btrfs inspect-internal dump-super /dev/nvme0n1 | grep csum_type

# Verify all checksums (scrub)
btrfs scrub start /mnt/btrfs
btrfs scrub status /mnt/btrfs
# Scrub reads every block, verifies checksum, repairs if RAID configured

# With RAID-1: scrub detects + repairs silently
# Without RAID: scrub detects but cannot repair (single device)
```

**Architect implication:** Btrfs can detect bit-rot (silent data corruption)
that XFS and ext4 cannot. For archival storage, this is a significant advantage.

---

## 6. Btrfs Production Stability Assessment

```
Mature/stable (safe for production):
  ✓ Single device
  ✓ RAID-1 (mirroring)
  ✓ Snapshots and send/receive
  ✓ Subvolumes
  ✓ Checksums and scrub
  ✓ Online grow

Use with caution:
  ⚠ RAID-5/6 — known bugs; NOT recommended for production data
    (parity rebuild is buggy; data loss possible on RAID-5/6 crash)
  ⚠ Very large filesystems (>100TB) — performance degrades
  ⚠ Heavy random-write workloads — CoW fragmentation

Avoid:
  ✗ RAID-5/6 for any critical data
  ✗ Database workloads (CoW overhead + fragmentation)
  ✗ VM image storage with many small random writes
```

---

## 7. When to Recommend Btrfs vs XFS for Backup Architecture

| Use Case | Recommendation | Reason |
|----------|---------------|--------|
| Primary filesystem, OLTP | XFS | Better random write perf, no CoW overhead |
| Primary filesystem, large files | XFS | Less fragmentation long-term |
| Backup destination with incremental | Btrfs | Send/receive is efficient and native |
| Archival with bit-rot detection | Btrfs | Checksums catch silent corruption |
| Container image store | Either | Btrfs reflink efficient; XFS also supports reflink |
| NFS server | XFS | Better concurrent access, stable |
| Snapshot-heavy VM host | Btrfs | Native snapshots cheaper than LVM thin |

---

## 8. Hands-On: Send/Receive Incremental Backup

```bash
# Setup: source and backup Btrfs filesystems
mkfs.btrfs /dev/sda
mkfs.btrfs /dev/sdb
mount /dev/sda /mnt/source
mount /dev/sdb /mnt/backup

# Create source subvolume with data
btrfs subvolume create /mnt/source/data
dd if=/dev/urandom of=/mnt/source/data/file1 bs=1M count=100
dd if=/dev/urandom of=/mnt/source/data/file2 bs=1M count=100

# Day 1: full backup
btrfs subvolume snapshot -r /mnt/source/data /mnt/source/snap_day1
btrfs send /mnt/source/snap_day1 | btrfs receive /mnt/backup/
echo "Full backup size:"
du -sh /mnt/backup/snap_day1

# Day 2: modify source, incremental backup
dd if=/dev/urandom of=/mnt/source/data/file1 bs=1M count=10  # modify 10MB
dd if=/dev/urandom of=/mnt/source/data/file3 bs=1M count=50  # add 50MB

btrfs subvolume snapshot -r /mnt/source/data /mnt/source/snap_day2

# Incremental send (only changes since snap_day1)
btrfs send -p /mnt/source/snap_day1 /mnt/source/snap_day2 \
    | btrfs receive /mnt/backup/

echo "Incremental send size (should be ~60MB, not 200MB):"
# Measure send size
btrfs send -p /mnt/source/snap_day1 /mnt/source/snap_day2 \
    | wc -c

# Verify backup integrity
btrfs scrub start /mnt/backup
btrfs scrub status /mnt/backup
```

---

## 9. Week 3 Review: Filesystem Architecture Decision Summary

| Filesystem | Parallel Metadata | Write Model | Snapshot | Checksums | Best For |
|-----------|------------------|-------------|----------|-----------|---------|
| XFS | Excellent (AG model) | Direct + delalloc | Via LVM thin | No | Production primary FS, large files, parallel workloads |
| ext4 | Good | Journal + delalloc | Via LVM thin | No | Simple workloads, small filesystems, familiarity |
| Btrfs | Good | CoW (fragmentation risk) | Native (instant) | Yes | Backup destination, archival, snapshot-heavy |

---

## 10. Self-Check Questions

1. How does the CoW B-tree enable instant snapshot creation regardless of subvolume size?
2. What is the CLONE command in the Btrfs send stream and why is it important for efficiency?
3. Why does Btrfs CoW lead to fragmentation over time on a database workload?
4. Btrfs RAID-5/6 is marked as not production-ready. What specific behavior makes it dangerous?
5. You need to replicate a 50TB Btrfs filesystem to a remote site daily, with only ~100GB changing per day. What is the send/receive command sequence and estimated transfer size?
6. A customer wants per-file checksums for archival storage to detect bit-rot over 10+ years. XFS or Btrfs?

## 11. Answers

1. A snapshot is just a new root pointer in the root tree, pointing to the same B-tree root as the source subvolume. No data is copied. Reference counts on shared nodes are incremented. The operation is O(1) — microseconds regardless of data size.
2. CLONE sends a `clone` command instead of `write` + data when two files share an extent (via reflink). The receiver relinks the extent rather than receiving data bytes. For filesystems with many reflinked files (container images, VM images, deduped data), this drastically reduces send stream size and network transfer.
3. Every small write triggers a CoW of the modified block to a new physical location. Over time, a file's extents spread across the entire device rather than staying contiguous. Sequential reads become random I/O. Databases do many small random writes — maximum CoW overhead, maximum fragmentation.
4. The parity calculation for RAID-5/6 is not atomic with respect to the CoW B-tree updates. A crash during a RAID-5 stripe write can leave parity inconsistent (the RAID-5 write hole), and Btrfs's recovery doesn't reliably handle this. Data loss is possible on RAID-5/6 arrays after crashes.
5. Commands: `btrfs subvolume snapshot -r /mnt/source/data /mnt/source/snap_$(date +%Y%m%d)` then `btrfs send -p /mnt/source/snap_yesterday /mnt/source/snap_today | ssh remote btrfs receive /backup/`. Estimated transfer: ~100GB (only changed data) + stream overhead, not 50TB. With CLONE optimization for reflinked data, possibly less.
6. Btrfs — it checksums all data and metadata blocks using crc32c (or stronger algorithms). Scrub can detect and (with RAID) repair silent corruption from bit-rot. XFS has no per-block data checksums (metadata only in newer versions). For 10-year archival, Btrfs's checksums are the architecturally correct choice.

---

## Tomorrow: Day 21 — Week 3 Review: Filesystem Architecture Decisions

We synthesize the week into a defensible filesystem decision framework,
with a production scenario that requires integrating dm-crypt + RAID + XFS.
