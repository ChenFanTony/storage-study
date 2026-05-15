# Day 20: Btrfs — CoW B-tree, Snapshots & Send/Receive

## Learning Objectives
- Understand Btrfs's CoW B-tree as the foundation for all Btrfs features
- Follow snapshot creation and the subvolume model at source level
- Understand the send/receive stream format and incremental backup mechanics
- Know Btrfs's production limits and where it fails
- Know when to recommend Btrfs vs XFS for backup/snapshot architectures

---

## 1. Btrfs's Core: The CoW B-tree

Everything in Btrfs — data extents, metadata, snapshots, subvolumes — is
stored in a single CoW (copy-on-write) B-tree. Understanding this tree is
the key to understanding all Btrfs features.

```
Btrfs on-disk structure:

Superblock
  └── Root tree (a tree of trees — points to other trees)
       ├── FS tree (filesystem data/metadata)
       │    ├── inode items
       │    ├── dir items
       │    └── extent data items → data extents on disk
       ├── Extent tree (tracks allocated disk blocks + refcounts)
       ├── Chunk tree (maps logical → physical addresses across devices)
       ├── Dev tree (device management)
       └── Subvolume trees (one per subvolume/snapshot)
            ├── subvol A tree (independent filesystem tree)
            └── subvol B tree (snapshot = copy of tree root pointer)
```

### CoW B-tree mechanics

```c
// fs/btrfs/ctree.c — the CoW B-tree implementation

// Every modification follows the CoW path:
//   1. Do NOT modify the existing node
//   2. Allocate a new block
//   3. Copy the node's contents to the new block
//   4. Modify the copy
//   5. Update parent to point to the new copy (CoW the parent too if needed)
//   6. Old node becomes free space (after transaction commits)

__btrfs_cow_block(trans, root, buf, parent, parent_slot, cow_ret, ...):
    // Allocate new block at a fresh logical address
    cow = btrfs_alloc_tree_block(trans, root, ...);
    // Copy content from old block
    copy_extent_buffer_full(cow, buf);
    // Link parent to new block (parent itself may need CoW first)
    btrfs_set_node_blockptr(parent, parent_slot, cow->start);
    // Decrement refcount on old block; it will be freed at transaction commit
    btrfs_free_tree_block(trans, btrfs_root_id(root), buf, ...);
```

### Why CoW B-tree enables snapshots

```
Before snapshot:
  Root → Node A → Node B → Leaf (data)

Create snapshot — just copy the root pointer:
  FS root   → Node A → Node B → Leaf (data)
  Snap root ─┘  (points to SAME Node A; refcount of Node A incremented)

Modify data in FS (triggers CoW from root to leaf along the modified path):
  FS root   → Node A' → Node B' → Leaf' (new data)
  Snap root → Node A  → Node B  → Leaf  (original data, unchanged)

Cost of modification: CoW copies only the path root→leaf (O(log N) nodes)
Cost of snapshot creation: O(1) — just one new root entry
```

This is the architecturally important property: **snapshot creation is
constant-time regardless of subvolume size.**

---

## 2. Subvolumes and Snapshots

```bash
# Create subvolumes
btrfs subvolume create /mnt/btrfs/subvol_a
btrfs subvolume create /mnt/btrfs/subvol_b

# List subvolumes
btrfs subvolume list /mnt/btrfs

# Read-write snapshot
btrfs subvolume snapshot /mnt/btrfs/subvol_a /mnt/btrfs/snap_a_rw

# Read-only snapshot (REQUIRED for send/receive)
btrfs subvolume snapshot -r /mnt/btrfs/subvol_a /mnt/btrfs/snap_a_ro

# Verify it was instant
time btrfs subvolume snapshot -r /mnt/btrfs/large_subvol /mnt/btrfs/snap_instant
# real  0m0.003s — microseconds regardless of data size
```

```c
// fs/btrfs/transaction.c, fs/btrfs/ioctl.c

// Snapshot creation (via BTRFS_IOC_SNAP_CREATE_V2 ioctl):
create_pending_snapshot(trans, pending):
    // 1. CoW the source subvolume's root node (creates a duplicate root)
    // 2. Create a new root item in the root tree pointing to the duplicated root
    // 3. Increment refcounts on the shared tree nodes
    //    (so freeing source nodes doesn't break the snapshot)
    // 4. Insert new directory entry making the snapshot visible
    // Transaction commits → snapshot is permanent

    // Total work: O(1) — one CoW of the source root + a few metadata updates
```

**Subvolumes vs snapshots: a key distinction.**
A subvolume is a separate filesystem tree (its own root in the root tree).
A snapshot IS a subvolume — there's no separate "snapshot type." A snapshot
just starts life sharing all its tree nodes with the source. Over time, as
either side is modified (via CoW), they diverge.

---

## 3. Send/Receive: Stream-Based Replication

`btrfs send` produces a stream of operations that, when applied by
`btrfs receive`, recreates a snapshot on another filesystem.

```
Full send (no parent reference):
  Walks the entire snapshot, emits: create dirs, create files, write data
  for every byte. Stream size ≈ snapshot size.

Incremental send (with parent reference):
  Compares two snapshots, emits ONLY the differences.
  Stream size ≈ size of changed data.
  Efficiency: 50 TB FS with 100 GB changed → ~100 GB stream, not 50 TB.
```

```bash
# Initial full backup
btrfs subvolume snapshot -r /mnt/source/data /mnt/source/snap_20260401
btrfs send /mnt/source/snap_20260401 | btrfs receive /mnt/backup/

# Daily incremental
btrfs subvolume snapshot -r /mnt/source/data /mnt/source/snap_20260402
btrfs send -p /mnt/source/snap_20260401 /mnt/source/snap_20260402 \
    | btrfs receive /mnt/backup/

# Over network (most common production pattern)
btrfs send -p /mnt/source/snap_yesterday /mnt/source/snap_today \
    | ssh backup-host btrfs receive /backup/

# To a file (offline transport)
btrfs send /mnt/source/snap_20260402 > /backup/snap_20260402.btrfs
btrfs receive /mnt/restore/ < /backup/snap_20260402.btrfs

# Verify integrity after receive
btrfs scrub start /mnt/backup
btrfs scrub status /mnt/backup
```

### Send stream format

```c
// fs/btrfs/send.c — send stream generation

// Stream begins with a header:
struct btrfs_stream_header {
    char    magic[sizeof(BTRFS_SEND_STREAM_MAGIC)]; // "btrfs-stream\0"
    __le32  version;                                 // 1 or 2
};

// Stream commands (selected):
// BTRFS_SEND_C_SUBVOL         — start of new subvolume
// BTRFS_SEND_C_SNAPSHOT       — declare this is incremental, ref parent
// BTRFS_SEND_C_MKFILE         — create regular file
// BTRFS_SEND_C_MKDIR          — create directory
// BTRFS_SEND_C_SYMLINK        — create symlink
// BTRFS_SEND_C_WRITE          — write data to file
// BTRFS_SEND_C_CLONE          — clone extent from a reference subvolume
// BTRFS_SEND_C_RENAME         — rename file/dir
// BTRFS_SEND_C_UNLINK         — delete file
// BTRFS_SEND_C_TRUNCATE       — truncate file
// BTRFS_SEND_C_UTIMES         — update timestamps
// BTRFS_SEND_C_CHMOD/CHOWN    — change permissions
// BTRFS_SEND_C_END            — end of subvolume stream
// BTRFS_SEND_C_UPDATE_EXTENT  — used for "no_data" mode (metadata-only stream)
```

**The CLONE command — critical for efficiency:**

If the receiver already has an extent (because it received an earlier
snapshot containing it), the sender emits CLONE rather than WRITE. The
receiver creates a reflink to its existing copy. **Zero data transferred
over the wire** for blocks that already exist on both sides.

This is what makes Btrfs backup of container images and VM clusters
efficient: shared base layers turn into CLONE commands.

---

## 4. The Subvolume Tree Walk That Drives Send

```c
// fs/btrfs/send.c

send_subvol(sctx):
    // 1. Walk the send subvolume's tree
    btrfs_search_slot(...) ; for each item:

        // 2. If incremental mode: also walk the parent's tree at same position
        // Compare items. Emit one of:
        //   - WRITE / CLONE (data changed)
        //   - MKFILE / MKDIR (new in send subvol)
        //   - UNLINK (in parent but not in send subvol)
        //   - RENAME (moved)

    // 3. For each WRITE: read data from extent map, emit data in stream
    //    For each CLONE: emit just the reference to source extent

// Throughout: send uses "commit roots" — snapshot's tree as it existed at commit
// time, not the live tree. This is why send REQUIRES read-only snapshots.
```

**Why read-only snapshots are required:**
A writable snapshot might be modified during the send. The send walks the
tree assuming it's frozen; a concurrent write could relocate nodes via CoW
and break the walk. Read-only snapshots can't be modified, so the walk is
consistent. (This is enforced at the kernel level; trying to send a
read-write subvolume returns EINVAL.)

---

## 5. CoW Fragmentation Over Time

This is Btrfs's main production performance problem.

```
Initial state: 1 GB file, written once as one contiguous extent

After 1 year of small in-place modifications:
  Each small write → CoW of that block → new physical location
  After 50,000 modifications: 50,000 small extents scattered across the device
  Sequential read of the file: 50,000 seeks (or random NVMe reads)
  Performance degrades by orders of magnitude over time
```

```bash
# Check fragmentation of a file
filefrag -v /mnt/btrfs/fragmented_file
# Output: "/mnt/btrfs/fragmented_file: 50234 extents found"
# Healthy: a few extents. Fragmented: thousands.

# Defragment a file (online)
btrfs filesystem defragment -v /mnt/btrfs/fragmented_file

# Defragment a directory tree
btrfs filesystem defragment -r /mnt/btrfs/

# Compress while defragmenting
btrfs filesystem defragment -r -c zstd /mnt/btrfs/
```

**Critical warning about defragment:**
`btrfs filesystem defragment` BREAKS reflinks. A defragmented file is
rewritten to a new contiguous extent, losing the sharing with snapshots.
Disk usage can balloon as snapshot data becomes independent. For
snapshot-heavy systems, defragment is dangerous.

Workarounds:
- For database files: use `chattr +C` to disable CoW on that file (no
  snapshots possible for that file either)
- For VM images: same — `chattr +C`
- For general use: just accept the fragmentation, or migrate workload away
  from Btrfs

---

## 6. Checksums: Btrfs's Unique Integrity Feature

```bash
# Btrfs checksums all data and metadata by default
# Algorithms: crc32c (default), xxhash, sha256, blake2b

# Check checksum algorithm
btrfs inspect-internal dump-super /dev/nvme0n1 | grep csum_type
# csum_type 0 = crc32c, 1 = xxhash64, 2 = sha256, 3 = blake2

# Set at mkfs time only:
mkfs.btrfs --csum sha256 /dev/nvme0n1   # stronger but slower
mkfs.btrfs --csum xxhash /dev/nvme0n1   # faster than crc32c, modern default for many

# Verify all checksums (scrub)
btrfs scrub start /mnt/btrfs
btrfs scrub status /mnt/btrfs
# Scrub reads every block, verifies checksum
# With RAID-1: scrub detects + REPAIRS silently using the good replica
# Without RAID: scrub detects but cannot repair (reports error)
```

```c
// fs/btrfs/disk-io.c, fs/btrfs/raid56.c

// On every read:
btrfs_validate_metadata_buffer():
    // Compute checksum of the block
    // Compare to stored checksum
    // If mismatch:
    //   - If RAID-1/10: try the other copy
    //   - If RAID-5/6: try parity reconstruction
    //   - Otherwise: return EIO to upper layer
```

**Architect implication:** Btrfs can detect silent data corruption (bit-rot,
controller errors, bad cables) that XFS and ext4 cannot. For archival
storage where bit-rot accumulates over years, this is significant.

---

## 7. Btrfs Production Stability Assessment

```
Mature / production-ready:
  ✓ Single device with checksums
  ✓ RAID-1 (mirror) / RAID-10 (striped mirror)
  ✓ Snapshots and send/receive
  ✓ Subvolumes
  ✓ Compression (zstd, lzo, zlib)
  ✓ Online grow / shrink
  ✓ scrub for corruption detection and repair (with RAID-1/10)

Use with caution:
  ⚠ Very large filesystems (>100 TB) — performance degrades
  ⚠ Heavy random-write workloads — CoW fragmentation
  ⚠ Quota groups (qgroups) — high overhead, occasional accuracy bugs

Do not use in production:
  ✗ RAID-5/6 — long-standing parity write-hole and rebuild bugs
    See: https://btrfs.readthedocs.io/en/latest/Status.html
    Multiple documented data-loss scenarios. Use mdadm RAID-6 underneath
    Btrfs if you need parity RAID with Btrfs features.
```

The RAID-5/6 caveat has been the standing recommendation for years. The
core problem: parity calculation during partial-stripe writes is not
atomic with respect to the CoW B-tree updates, and crash recovery doesn't
reliably reconstruct correct parity.

---

## 8. When to Recommend Btrfs vs XFS for Backup Architectures

| Use Case | Recommendation | Reason |
|----------|---------------|--------|
| Primary filesystem, OLTP database | XFS | Better random write perf; CoW overhead too high |
| Primary filesystem, large files | XFS | Less fragmentation long-term; mature at scale |
| Backup destination with incremental | **Btrfs** | Send/receive is native; CLONE deduplication |
| Archival with bit-rot detection | **Btrfs** | Checksums catch silent corruption |
| Container image store | Either | Btrfs subvolumes + reflinks; XFS reflinks also work |
| NFS server | XFS | Better concurrent access, stable |
| Snapshot-heavy VM host | Btrfs | Native snapshots; cheaper than LVM thin |
| RAID-5/6 with parity | XFS | Btrfs RAID-5/6 unsafe; use mdadm + XFS |

---

## 9. Hands-On: Incremental Send/Receive

```bash
# Setup: source and backup Btrfs filesystems
dd if=/dev/zero of=/tmp/src.img bs=1M count=2048
dd if=/dev/zero of=/tmp/bak.img bs=1M count=2048
SRC=$(losetup --find --show /tmp/src.img)
BAK=$(losetup --find --show /tmp/bak.img)

mkfs.btrfs $SRC
mkfs.btrfs $BAK

mkdir -p /mnt/source /mnt/backup
mount $SRC /mnt/source
mount $BAK /mnt/backup

# Create source subvolume with data
btrfs subvolume create /mnt/source/data
dd if=/dev/urandom of=/mnt/source/data/file1 bs=1M count=100
dd if=/dev/urandom of=/mnt/source/data/file2 bs=1M count=100

# Day 1: full backup
btrfs subvolume snapshot -r /mnt/source/data /mnt/source/snap_day1
btrfs send /mnt/source/snap_day1 | btrfs receive /mnt/backup/

du -sh /mnt/backup/snap_day1   # ~200 MB

# Day 2: modify source, take new snapshot
dd if=/dev/urandom of=/mnt/source/data/file1 bs=1M count=10  # rewrite 10 MB
dd if=/dev/urandom of=/mnt/source/data/file3 bs=1M count=50  # add 50 MB
btrfs subvolume snapshot -r /mnt/source/data /mnt/source/snap_day2

# Incremental: measure stream size
btrfs send -p /mnt/source/snap_day1 /mnt/source/snap_day2 \
    | wc -c
# Expect: ~60 MB (just the changes), not 260 MB (full)

# Apply the incremental
btrfs send -p /mnt/source/snap_day1 /mnt/source/snap_day2 \
    | btrfs receive /mnt/backup/

# Backup now has both snapshots
btrfs subvolume list /mnt/backup

# Verify backup integrity
btrfs scrub start /mnt/backup ; btrfs scrub status /mnt/backup

# Cleanup
umount /mnt/source /mnt/backup
losetup -d $SRC $BAK
rm /tmp/src.img /tmp/bak.img
```

---

## 10. Source Reading Checklist

```
fs/btrfs/ctree.c            — the CoW B-tree implementation
fs/btrfs/ctree.h            — B-tree structures and item types
fs/btrfs/transaction.c      — transaction commit, create_pending_snapshot()
fs/btrfs/send.c             — send stream generation
fs/btrfs/disk-io.c          — checksum validation on read
fs/btrfs/extent_io.c        — extent-level I/O
fs/btrfs/file.c             — file write path (CoW for data extents)
fs/btrfs/ioctl.c            — snapshot, defrag, send ioctls
```

Reading order: `ctree.c` (`btrfs_cow_block`, `btrfs_search_slot`),
then `transaction.c` (`create_pending_snapshot`), then `send.c`
(`send_subvol`). The first two explain everything else.

---

## 11. Week 3 Review: Filesystem Architecture Summary

| Filesystem | Parallel Metadata | Write Model | Snapshot | Checksums | Best For |
|-----------|------------------|-------------|----------|-----------|---------|
| XFS | Excellent (AG model) | Direct + delalloc | Via LVM thin / reflink | No (metadata only) | Production primary, large files, parallel workloads |
| ext4 | Good | Journal + delalloc | Via LVM thin | No | Simple workloads, smaller filesystems |
| Btrfs | Good | CoW (fragmentation risk) | Native (instant) | Yes (all data) | Backup destination, archival, snapshot-heavy |

---

## 12. Self-Check Questions

1. How does Btrfs's CoW B-tree make snapshot creation O(1) regardless of subvolume size?
2. What is the CLONE command in the Btrfs send stream and why is it important for efficiency?
3. Why does Btrfs send REQUIRE read-only snapshots? What would break with a writable source?
4. A 1 GB file on Btrfs has been modified many times in-place over a year. What is its likely physical layout and why?
5. Btrfs RAID-5/6 is not recommended for production. What is the underlying technical reason?
6. You need to replicate a 50 TB Btrfs filesystem to a remote site daily, with only ~100 GB changing per day. Give the command sequence and estimate the daily transfer size.
7. A customer wants per-file checksums for archival storage to detect bit-rot over 10+ years. XFS or Btrfs? Justify.

## 13. Answers

1. A snapshot is just a new root entry in the root tree, pointing to the same B-tree root node as the source subvolume. No data or tree nodes are copied. The kernel increments reference counts on the shared nodes. The operation is constant-time — microseconds — regardless of subvolume size. Divergence happens later, lazily, as either side is modified (CoW copies only the path from root to modified leaf).
2. CLONE references an extent in a previously-sent (or otherwise present) subvolume on the receiver. Instead of sending the extent's data bytes, the sender emits a CLONE command with a reference; the receiver creates a reflink to its existing copy. Zero data transferred for shared blocks. For workloads with deduplicated content (container images, VM bases, deduped data), this drastically reduces stream size.
3. Send walks the source subvolume's commit-time tree assuming it's frozen. A writable source could be modified during send, triggering CoW that relocates tree nodes; the walk would see partial or inconsistent state. Read-only snapshots cannot be modified, so the tree is guaranteed stable. The kernel enforces this by rejecting send on read-write subvolumes.
4. Highly fragmented — likely thousands or tens of thousands of small extents. Every in-place modification triggered CoW: the modified block was written to a new physical location, leaving the file's extent map pointing to many scattered locations. Sequential reads degrade to nearly-random I/O. Defragment can fix it but breaks any reflinks/snapshots sharing the file's extents.
5. Parity calculation during partial-stripe writes interacts badly with the CoW B-tree updates. Btrfs's crash recovery does not reliably reconstruct correct parity after a power loss during a partial-stripe write, leading to data corruption or unrecoverable arrays. The bugs have existed for years and the upstream maintainers explicitly recommend against RAID-5/6 in production. Use mdadm RAID-6 underneath Btrfs (or a different filesystem) for parity RAID.
6. Daily routine: `btrfs subvolume snapshot -r /mnt/source/data /mnt/source/snap_$(date +%Y%m%d)`, then `btrfs send -p /mnt/source/snap_yesterday /mnt/source/snap_today | ssh backup-host btrfs receive /backup/`. Estimated daily transfer: ~100 GB (the changed data) plus stream overhead — possibly less if changes are reflinks of existing data (CLONE commands carry references, not bytes). Definitely not 50 TB.
7. Btrfs. It checksums all data and metadata blocks (crc32c by default; xxhash, sha256, or blake2b available). `btrfs scrub` walks every block, verifies checksums, and (with RAID-1/10) repairs corruption automatically. XFS checksums only metadata (in v5/CRC format), not data — silent data corruption from bit-rot is invisible to XFS. For 10-year archival, Btrfs's data checksums are the architecturally correct choice. Pair with RAID-1 or send/receive replication so corruption can be repaired, not just detected.

---

## Tomorrow: Day 21 — Week 3 Review: Filesystem Architecture Decisions

We synthesize the week into a defensible filesystem decision framework,
with a production scenario that requires integrating dm-crypt + RAID + XFS.
