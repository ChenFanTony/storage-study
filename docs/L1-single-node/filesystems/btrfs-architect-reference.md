# Btrfs Filesystem — Architect Deep Reference

> Companion to `day20-btrfs-cow-snapshots.md` (CoW B-tree basics, send/receive, production stability).
> Cross-reference with `xfs-architect-reference.md` and `ext4-architect-reference.md`.

---

## Section 0: Abbreviation and Terminology Reference

### Structural Units

| Term | Meaning |
|------|---------|
| SB | Superblock — primary copy at offset 64KB; mirror copies at 64MB, 256GB, 1PB |
| BG | Block Group — contiguous range of physical disk space (default 1GB data, 256MB metadata); the allocation unit |
| chunk | Logical range of address space; one chunk maps to one or more physical stripes (device extents) |
| dev_extent | Physical allocation on one device belonging to one chunk |
| logical address | Btrfs-internal address used by all trees; the chunk tree maps logical → physical |
| physical address | Real disk LBA; never stored directly in FS trees (only in the chunk tree) |
| bytenr | "Byte number" — Btrfs address unit; all tree pointers use bytenr (not block#) |
| nodesize | B-tree node size (default 16KB); all internal + leaf nodes are exactly nodesize bytes |
| sectorsize | Smallest I/O unit (default 4KB = page size) |
| leaf | B-tree node with no children; holds packed key-value items |
| internal node | B-tree node with child pointers (key + bytenr pairs) |
| path | `struct btrfs_path` — stack of (node, slot) pairs from root to leaf for one search |

### Tree Names

| Term | Meaning |
|------|---------|
| root tree | The "tree of trees"; root items for every other tree; object ID 1 |
| FS tree | Per-subvolume filesystem tree (inodes, dirs, extents); one per subvolume/snapshot |
| extent tree | Tracks every allocated extent (data + metadata) with reference counts; object ID 2 |
| chunk tree | Maps logical address space to physical devices; object ID 3 |
| dev tree | Device inventory and per-device stats; object ID 4 |
| csum tree | Per-block data checksums; object ID 7 |
| free space tree | v2 free space cache as a B-tree (fsck-friendly alternative to free space inodes); object ID 10 |
| log tree | Per-subvolume write-ahead log for fsync (similar to JBD2); temporary, rebuilt on recovery |
| reloc tree | Temporary tree during balance/relocation operations |
| quota tree | qgroup accounting tree (enabled only if quota is turned on) |
| uuid tree | Maps subvolume UUIDs to subvolume IDs; used by send/receive |

### Key and Item Types

| Term | Meaning |
|------|---------|
| objectid | 64-bit object identifier; inode number for files, tree root ID for roots |
| type | 8-bit key type field; distinguishes different item types with the same objectid |
| offset | 64-bit key offset; meaning depends on type (file offset, block number, etc.) |
| key | (objectid, type, offset) triplet; the sorted key for all B-tree items |
| INODE_ITEM | Inode metadata (mode, uid, size, etc.); key = (ino, INODE_ITEM, 0) |
| INODE_REF | Hardlink record (parent dir ino + name); key = (ino, INODE_REF, parent_ino) |
| DIR_ITEM | Directory entry; key = (dir_ino, DIR_ITEM, name_hash) |
| DIR_INDEX | Ordered directory index; key = (dir_ino, DIR_INDEX, sequential_index) |
| EXTENT_DATA | File data extent record; key = (ino, EXTENT_DATA, file_offset) |
| EXTENT_ITEM | Extent allocation record in the extent tree; key = (bytenr, EXTENT_ITEM, length) |
| METADATA_ITEM | Metadata extent record (v2 extent tree format); key = (bytenr, METADATA_ITEM, 0) |
| BLOCK_GROUP_ITEM | Free/used stats for a block group; key = (bg_start, BLOCK_GROUP_ITEM, bg_length) |
| CHUNK_ITEM | Logical→physical mapping; key = (1, CHUNK_ITEM, logical_offset) |
| DEV_ITEM | Per-device info; key = (1, DEV_ITEM, dev_id) |
| DEV_EXTENT | Physical allocation on a device; key = (dev_id, DEV_EXTENT, dev_offset) |
| ROOT_ITEM | Root descriptor for a tree; key = (root_id, ROOT_ITEM, 0) |
| ROOT_BACKREF | Back-reference from subvolume to its parent directory entry |

### Snapshot and Reflink Terms

| Term | Meaning |
|------|---------|
| subvolume | A Btrfs filesystem tree with its own root; the basic mountable unit |
| snapshot | A subvolume that started life sharing tree nodes with another subvolume (O(1) creation) |
| CoW | Copy-on-Write — modifying any node creates a new copy rather than modifying in-place |
| reflink | File-level data sharing: two files reference the same extent via reference counting |
| extent ref | Reference count entry in the extent tree for a shared extent |
| back ref | Reverse pointer from extent to its owner(s); two types: inline (in EXTENT_ITEM) and keyed |
| inline back ref | Owner info packed directly into the EXTENT_ITEM value; used when ref count = 1 |
| keyed back ref | Separate EXTENT_DATA_REF item; used when ref count > 1 (multiple owners) |
| delayed ref | Batched extent tree update; applied at transaction commit, not immediately |
| dedup | Deduplication — sharing identical extents across files (in-band or out-of-band) |
| balance | Operation that migrates block groups across devices or changes their RAID profile |

### Transaction and Log Terms

| Term | Meaning |
|------|---------|
| transaction | Btrfs unit of atomicity; all tree modifications in one transaction are committed together |
| trans_id | Monotonically increasing 64-bit transaction ID; written into every tree node header |
| generation | Synonym for trans_id in node headers; used to detect stale node reads |
| log tree | Per-subvolume write-ahead log for fsync-class durability (bypasses full transaction commit) |
| log commit | Flush log tree to disk (faster than full transaction commit) |
| CRC | Per-block checksum stored in node/leaf header; verified on every read |
| FSID | Filesystem UUID; in every metadata block header to prevent cross-FS block confusion |
| COW tree | Any of the main trees; all use CoW on modification (as opposed to the log tree) |

---

## Section 1: On-Disk Structure — The Tree of Trees

Btrfs is fundamentally different from ext4/XFS in that it has no fixed-offset metadata. All metadata lives in B-tree nodes whose locations are tracked by other B-trees. The entry point is the superblock.

### 1.1 Superblock Layout

```
Disk layout (offsets from device start):
  64KB   — primary superblock
  64MB   — first mirror superblock
  256GB  — second mirror superblock
  1PB    — third mirror superblock (if device is large enough)

Multiple copies exist so that even if one sector is corrupt, the filesystem
can be mounted using another copy. On multi-device filesystems, all devices
carry superblock copies.
```

```c
// include/uapi/linux/btrfs_tree.h
struct btrfs_super_block {
    __u8     csum[BTRFS_CSUM_SIZE];     // checksum of this superblock
    __u8     fsid[BTRFS_FSID_SIZE];     // filesystem UUID
    __le64   bytenr;                    // physical offset of this SB (must = 64KB for primary)
    __le64   flags;
    __le64   magic;                     // 0x4D5F53665248425FULL "_BHRfS_M"
    __le64   generation;                // transaction ID when this SB was written
    __le64   root;                      // bytenr of the root tree root node
    __le64   chunk_root;                // bytenr of the chunk tree root node
    __le64   log_root;                  // bytenr of the log tree (0 if no log)
    __le64   total_bytes;               // total filesystem size (logical)
    __le64   bytes_used;                // used bytes
    __le64   root_dir_objectid;         // always 6 (the default subvolume's root dir ino)
    __le64   num_devices;
    __le32   sectorsize;                // minimum I/O unit (default 4096)
    __le32   nodesize;                  // B-tree node size (default 16384)
    __le32   leafsize;                  // same as nodesize (legacy field)
    __le32   stripesize;                // for RAID, stripe size
    __le32   sys_chunk_array_size;      // size of embedded chunk array below
    __le64   compat_flags;
    __le64   incompat_flags;            // features that must be understood to mount
    // Embedded bootstrap chunks (chunk tree entries needed to find chunk tree itself):
    __u8     sys_chunk_array[2048];
    // ... subvolume_uuids, device info, etc.
};
```

**The bootstrap problem:** To mount the filesystem you need the chunk tree (to translate logical→physical addresses). But the chunk tree is itself a B-tree whose nodes are at logical addresses. To read the chunk tree you first need the chunk map. Solution: the superblock contains `sys_chunk_array` — a hand-encoded list of the system chunk mappings sufficient to read the chunk tree root. After reading the chunk tree root, the full chunk map is available.

### 1.2 The Multi-Tree Architecture

```
                    Superblock
                    │ .root ──────────────────────────────► Root Tree
                    │ .chunk_root ──────────────────────► Chunk Tree
                    │ .sys_chunk_array ── bootstrap chunks ┘

Root Tree (tree of trees):
  ROOT_ITEM(1, ROOT_ITEM, 0)     → Extent Tree root node bytenr
  ROOT_ITEM(2, ROOT_ITEM, 0)     → Chunk Tree root node bytenr (redundant with SB)
  ROOT_ITEM(3, ROOT_ITEM, 0)     → Dev Tree root node bytenr
  ROOT_ITEM(4, ROOT_ITEM, 0)     → FS Tree (default subvolume) root node bytenr
  ROOT_ITEM(7, ROOT_ITEM, 0)     → Checksum Tree root node bytenr
  ROOT_ITEM(10, ROOT_ITEM, 0)    → Free Space Tree root node bytenr (v2)
  ROOT_ITEM(256, ROOT_ITEM, 0)   → First user subvolume FS tree
  ROOT_ITEM(257, ROOT_ITEM, 0)   → Second user subvolume FS tree
  ROOT_ITEM(258, ROOT_ITEM, 0)   → Snapshot of subvolume 256 (same structure as a subvolume)
  ...

FS Tree (per-subvolume):
  INODE_ITEM(256, INODE_ITEM, 0)        → root directory inode
  DIR_ITEM(256, DIR_ITEM, hash("foo"))  → "foo" directory entry → inode 257
  INODE_ITEM(257, INODE_ITEM, 0)        → file "foo" inode
  EXTENT_DATA(257, EXTENT_DATA, 0)      → file "foo" data at offset 0 → logical addr X

Extent Tree:
  EXTENT_ITEM(X, EXTENT_ITEM, 4096)     → reference count=1, back ref → inode 257 offset 0

Chunk Tree:
  CHUNK_ITEM(1, CHUNK_ITEM, X)          → logical X → physical device 1 offset Y

Checksum Tree:
  CSUM_ITEM(CSUM_OBJECTID, EXTENT_CSUM, X) → checksum for 4KB at logical addr X
```

**Key insight:** No structure references a physical address except the chunk tree and the superblock's `sys_chunk_array`. Everything else uses logical addresses. This indirection is what enables:
- Multi-device support (physical layout is hidden)
- RAID (one logical address maps to multiple physical addresses)
- Balance/relocation (physical layout can be changed without touching FS trees)

### 1.3 B-tree Node Format

All Btrfs B-tree nodes (internal and leaf) are exactly `nodesize` bytes (default 16KB).

```c
// Shared header for every node (internal or leaf):
struct btrfs_header {
    __u8     csum[BTRFS_CSUM_SIZE];  // CRC32c (or xxhash/sha256/blake2b) of rest of block
    __u8     fsid[BTRFS_FSID_SIZE];  // filesystem UUID (prevents cross-FS block confusion)
    __le64   bytenr;                 // expected logical address of this block (self-check)
    __le64   flags;                  // BTRFS_HEADER_FLAG_WRITTEN | _RELOC
    __u8     chunk_tree_uuid[16];    // chunk tree UUID
    __le64   generation;             // transaction ID when this block was last CoW'd
    __le64   owner;                  // objectid of the tree that owns this block
    __le32   nritems;                // number of items/key-ptrs in this node
    __u8     level;                  // 0 = leaf, 1+ = internal
};  // 101 bytes

// Internal node (level > 0): header + array of key-pointer pairs
struct btrfs_key_ptr {
    struct btrfs_disk_key key;   // (objectid, type, offset) — 17 bytes
    __le64 blockptr;             // bytenr of child node
    __le64 generation;           // generation of child at time of write
};  // 33 bytes per key-ptr

// Internal node capacity: (16384 - 101) / 33 = 495 child pointers per internal node

// Leaf node (level == 0): header + item array at start, item data at end (grows inward)
//   [header][item0][item1]...[itemN] ....free.... [dataN]...[data1][data0]
struct btrfs_item {
    struct btrfs_disk_key key;   // 17 bytes
    __le32 offset;               // byte offset of this item's data within the leaf
    __le32 size;                 // byte size of this item's data
};  // 25 bytes per item
// Item data is variable-length; grows from the end of the leaf toward the start.
// Leaf capacity: (16384 - 101) / 25 = ~654 items (smaller for larger item data)
```

**The `generation` field in key-ptrs:** When reading a child node, Btrfs verifies that the child's `header.generation` matches the `generation` recorded in the parent's key-ptr. A mismatch means the parent is stale (read an old version). This catches write barrier failures where an old block survives a crash.

---

## Section 2: CoW B-tree Mechanics

### 2.1 The CoW Path: Root-to-Leaf Write

Every write to a Btrfs tree follows the same CoW path. The key invariant: **never modify an existing block that might be shared**.

```
Goal: modify leaf at path root → A → B → leaf

Step 1: Check if leaf is shared (generation != current_trans_id OR refcount > 1)
  If not shared: modify in place (single-transaction modifications are fine)
  If shared: CoW:

Step 2: CoW the leaf
  Allocate new_leaf at a fresh logical address
  copy_extent_buffer(new_leaf, old_leaf)
  Modify new_leaf (insert/delete/update item)
  Mark new_leaf dirty (will be written at commit)
  Free old_leaf (via delayed ref: decrement refcount)

Step 3: CoW parent node B (must update pointer to new_leaf)
  If B is shared: CoW B → new_B (copy, update key-ptr to new_leaf)
  If B is not shared: update in place

Step 4: CoW grandparent A if needed (to update pointer to new_B)
  ... continue up to root ...

Step 5: CoW the root itself
  Allocate new_root, copy, update key-ptr
  Update ROOT_ITEM in root tree to point to new_root
  (Root tree itself gets CoW'd up to the root tree's root)
  Update superblock .root field on commit

Total blocks written per modification:
  depth × 1 new block per level (root to leaf)
  Default depth: 1-3 levels for typical filesystems
  = 2-4 new blocks per single-item modification

This is the CoW overhead: every write to any item requires O(depth) new block allocations.
```

### 2.2 Shared Blocks and Reference Counting

Blocks become shared in two ways:
1. **Snapshot creation**: snapshot's root points to same nodes as source
2. **Reflinks**: two EXTENT_DATA items point to the same data extent

```
Snapshot of subvolume 256 (creating subvolume 258):

Before:
  Root Tree: ROOT_ITEM(256) → node_A (generation=100)
  node_A → node_B → leaf → EXTENT_DATA → logical 0x1000

After snapshot creation (one transaction):
  Root Tree: ROOT_ITEM(256) → node_A (still generation=100)
             ROOT_ITEM(258) → node_A (same node_A ← now shared)
  Extent tree: EXTENT_ITEM(node_A_bytenr) → refcount=2

Now subvolume 256 is modified:
  CoW path: new_node_A → new_node_B → new_leaf
  node_A refcount decrements to 1 (owned only by snapshot 258)
  new_node_A refcount = 1 (owned only by subvolume 256)
  Divergence: snapshot and subvolume now have independent trees
```

### 2.3 Delayed References

Updating the extent tree on every CoW would create a cascade: modifying a leaf adds an extent entry (CoW the extent tree) which requires CoW-ing the extent tree's internal nodes (more extent entries) — infinite recursion.

Solution: **delayed references** (`fs/btrfs/delayed-ref.c`).

```
When a block is CoW'd:
  Instead of immediately updating the extent tree:
  1. Add a "decrement ref" delayed_ref for old_block
  2. Add an "increment ref" delayed_ref for new_block
  Both go into the transaction's delayed_ref_root (an rb-tree in memory)

At transaction commit time:
  delayed_ref_root is flushed in a controlled order:
  1. Process all decrements first (free old blocks)
  2. Process all increments (record new blocks)
  3. Run all the extent tree updates together
  This batching allows a single transaction to contain many CoW operations
  without the extent tree modifications interfering with each other.

Why this works:
  The delayed refs are all applied in one atomic transaction commit.
  No intermediate state is visible.
  The extent tree is only written at commit time, not during the modification phase.

struct btrfs_delayed_ref_node {
    struct rb_node  rb_node;
    u64             bytenr;        // which extent is being modified
    u64             num_bytes;     // extent size
    u64             seq;           // ordering (for correct application)
    int             ref_mod;       // +1 (add ref) or -1 (drop ref)
    u8              type;          // BTRFS_TREE_BLOCK_REF or BTRFS_EXTENT_DATA_REF
    // back ref info (owner, offset, root)
};
```

### 2.4 Transaction Commit Sequence

A full Btrfs transaction commit is a multi-phase process ensuring atomicity across all trees:

```
Phase 1: Freeze new modifications
  btrfs_transaction_commit() → set transaction state to TRANS_STATE_COMMIT_START
  New write() calls start waiting for the next transaction
  In-progress handles (btrfs_trans_handle) drain

Phase 2: Flush dirty data pages (ordered mode)
  All pending data writes are submitted to disk
  Wait for completion (ensures data is on disk before metadata references it)
  Same ordering guarantee as ext4 data=ordered

Phase 3: Run delayed references
  Process the delayed_ref_root: update extent tree for all pending ref changes
  This is the largest phase — many extent tree CoW operations happen here

Phase 4: Write dirty tree blocks
  All CoW'd tree blocks (new leaves and internal nodes) are written to disk
  Order: write children before parents (ensures tree is valid if crash during write)

Phase 5: Write superblock
  New superblock is written with updated .root, .chunk_root, .generation
  A single superblock write is the commit point (atomicity boundary)
  If crash before this write: previous transaction's superblock still valid → no data loss
  If crash after this write: new transaction's trees are on disk → full recovery

Phase 6: Unblock next transaction
  Release the transaction lock; new writes can start
```

**The superblock write is the commit point** — analogous to JBD2's commit block, but at the filesystem level rather than the journal level.

---

## Section 3: The Extent Tree — Reference Counting

### 3.1 Extent Item Structure

The extent tree tracks every allocated extent (data and metadata) with reference counts. This enables CoW sharing and reflinks.

```c
// An EXTENT_ITEM in the extent tree:
// Key: (bytenr, EXTENT_ITEM, num_bytes)

struct btrfs_extent_item {
    __le64  refs;       // reference count (how many owners share this extent)
    __le64  generation; // transaction ID when this extent was first allocated
    __le64  flags;      // BTRFS_EXTENT_FLAG_DATA or BTRFS_EXTENT_FLAG_TREE_BLOCK
};

// Followed immediately by back reference(s):

// Inline back ref (packed inside EXTENT_ITEM when refs==1 or tree block):
struct btrfs_extent_inline_ref {
    __u8    type;           // BTRFS_TREE_BLOCK_REF_KEY or BTRFS_EXTENT_DATA_REF_KEY
    // For EXTENT_DATA_REF:
    struct btrfs_extent_data_ref {
        __le64  root;       // subvolume tree ID that owns this extent
        __le64  objectid;   // inode number
        __le64  offset;     // file offset
        __le32  count;      // reference count from this owner
    };
};
```

### 3.2 How Reference Counts Drive Free Space

```
Data extent at logical 0x10000, length 4096:
  Created by subvolume 256, inode 500, offset 0:
  EXTENT_ITEM(0x10000, EXTENT_ITEM, 4096):
    refs = 1
    inline back ref: root=256, objectid=500, offset=0, count=1

Reflink copy (cp --reflink=always):
  subvolume 257, inode 600, offset 0 now also points to 0x10000:
  EXTENT_ITEM(0x10000, EXTENT_ITEM, 4096):
    refs = 2
    back ref #1: root=256, objectid=500, offset=0, count=1
    back ref #2: root=257, objectid=600, offset=0, count=1
    (now stored as two keyed back refs, not inline)

Delete file in subvolume 256:
  Delayed ref: decrement root=256, objectid=500, offset=0, count=1
  At commit: EXTENT_ITEM refs = 1
  extent NOT freed (reflink copy in subvolume 257 still holds it)

Delete file in subvolume 257:
  Delayed ref: decrement root=257, objectid=600, offset=0, count=1
  At commit: EXTENT_ITEM refs = 0 → extent freed
  Block group free count updated
  Physical space reclaimed
```

### 3.3 Back Reference Resolution

Back references are used by:
- `btrfs check` — verifying every extent has valid owners
- Balance — finding what needs to be updated when an extent is relocated
- Snapshot delete — walking back refs to find which subvolume trees to update

**Full back ref walk** (used during balance):
```c
// fs/btrfs/backref.c — btrfs_find_all_roots()
// Given a data extent at bytenr X:
//   1. Look up EXTENT_ITEM(X) in extent tree
//   2. For each back ref (inline or keyed):
//      a. root = the subvolume tree ID
//      b. Read that subvolume's FS tree
//      c. Look up EXTENT_DATA(objectid, EXTENT_DATA, offset) in that FS tree
//      d. Verify it points to X (consistency check)
//   3. If back ref says "tree block" (metadata extent):
//      a. Walk from the tree root down to the node at X
//      b. Verify the node at X is reachable via the declared path
//
// This is O(refs × tree_depth) per extent — expensive for highly shared extents.
// Balance of a large filesystem with many snapshots can take hours for this reason.
```

---

## Section 4: Chunk Tree and RAID Layer

### 4.1 Logical-to-Physical Translation

The chunk tree maps the Btrfs logical address space to physical device offsets. This layer is where RAID lives.

```
Chunk tree entry example:
  Key: (1, CHUNK_ITEM, 0x400000)  ← logical offset 4MB
  Value: struct btrfs_chunk {
    length:        1073741824  (1GB — this chunk covers logical 4MB..1GB+4MB)
    owner:         2           (chunk tree object ID)
    stripe_len:    65536       (64KB stripe)
    type:          BTRFS_BLOCK_GROUP_DATA | BTRFS_BLOCK_GROUP_RAID1
    num_stripes:   2           (RAID-1: 2 copies)
    stripes[0]:    { devid=1, offset=0x400000 }   ← copy 1 on device 1
    stripes[1]:    { devid=2, offset=0x400000 }   ← copy 2 on device 2
  }
```

**RAID profiles and their stripe/mirror layout:**

| Profile | `num_stripes` | Parity | Space efficiency | Production status |
|---------|--------------|--------|------------------|------------------|
| SINGLE | 1 | None | 100% | Stable |
| DUP | 2 (same device) | None | 50% | Stable (single-device mirror) |
| RAID0 | N | None | 100% | Stable |
| RAID1 | 2 | None | 50% | Stable |
| RAID1C3 | 3 | None | 33% | Stable (kernel 5.5+) |
| RAID1C4 | 4 | None | 25% | Stable (kernel 5.5+) |
| RAID10 | 2N | None | 50% | Stable |
| RAID5 | N-1 data + 1 parity | XOR | (N-1)/N | **Unsafe** — write hole bug |
| RAID6 | N-2 data + 2 parity | XOR+P+Q | (N-2)/N | **Unsafe** — write hole bug |

**Why RAID5/6 is unsafe in Btrfs:**
```
The write hole problem:
  Writing a partial stripe (less than full stripe width) requires:
  1. Read old data (read-modify-write)
  2. Compute new parity
  3. Write new data stripe(s) + new parity stripe

  In Btrfs, steps 1-3 are NOT atomic with respect to the CoW transaction.
  If power is lost between step 3's individual writes:
    Some data stripes updated, parity not (or vice versa)
  On next mount: parity mismatch detected → array declared inconsistent
  Btrfs recovery does not have the logic to repair this
  (unlike mdadm which has the journal/bitmap to reconstruct)

Fix: use mdadm RAID5/6 underneath a single-device Btrfs.
  The mdadm RAID layer handles the write hole; Btrfs sees a single device.
```

### 4.2 Block Groups

Block groups are the allocation units within Btrfs. Each block group corresponds to one chunk.

```c
struct btrfs_block_group {
    u64     start;           // logical start address (= chunk start)
    u64     length;          // size (= chunk length)
    u64     used;            // bytes allocated within this block group
    u64     bytes_super;     // bytes used for superblock copies
    u64     flags;           // DATA, METADATA, SYSTEM; RAID profile
    // Free space tracking:
    struct btrfs_free_space_ctl *free_space_ctl;  // in-memory free space info
    // ...
};
```

Block groups are type-separated:
```
Block group types:
  DATA     — holds file data extents
  METADATA — holds B-tree nodes (all trees: FS tree, extent tree, etc.)
  SYSTEM   — holds chunk tree nodes specifically (bootstrap requirement)
  MIXED    — DATA + METADATA in same block group (only for small filesystems)

Separate DATA and METADATA block groups:
  - Metadata allocations (B-tree nodes) don't fragment data space and vice versa
  - Allows different RAID profiles for data vs metadata:
    mkfs.btrfs -d raid0 -m raid1 /dev/sd{a,b}
    ← data striped (performance), metadata mirrored (reliability)
  - Metadata block groups are typically much smaller (256MB default vs 1GB for data)
```

### 4.3 Free Space Cache

Btrfs has two generations of free space tracking:

**v1 (free space inodes) — old default:**
```
Each block group has a special inode (free space cache inode) in the FS tree.
The inode's data blocks contain a bitmap and extent list of free space within the BG.
Written to disk as a regular file; read on first allocation from that BG.
Problem: not covered by the extent tree → fsck (btrfs check) cannot verify it.
If the free space cache is wrong, the filesystem thinks space is used when it's free (or vice versa).
Fix: mount -o clear_cache → regenerate all free space caches from extent tree (slow).
```

**v2 (free space tree) — stable since kernel 4.9:**
```
A proper B-tree (object ID 10 in the root tree) containing FREE_SPACE_EXTENT and
FREE_SPACE_BITMAP items, one per block group.
Fully integrated with the extent tree: changes are transactional.
btrfs check can verify it.
Enable: mkfs.btrfs --features=free-space-tree
       or: btrfs rescue enable-free-space-tree /dev/sdX (offline conversion)
Production recommendation: always use v2 (mount -o space_cache=v2).
```

---

## Section 5: Per-Subvolume FS Tree — Inode and Extent Layout

### 5.1 Inode Items

```c
// Key: (ino, INODE_ITEM, 0)
struct btrfs_inode_item {
    __le64  generation;     // transaction ID of last modification
    __le64  transid;        // same (redundant; kept for compatibility)
    __le64  size;           // file size in bytes
    __le64  nbytes;         // allocated bytes (≥ size; counts preallocated space)
    __le64  block_group;    // hint for data block allocation
    __le32  nlink;
    __le32  uid;
    __le32  gid;
    __le32  mode;
    __le64  rdev;
    __le64  flags;          // BTRFS_INODE_NODATASUM, BTRFS_INODE_NODATACOW, etc.
    __le64  sequence;       // NFS generation
    // timestamps: atime, ctime, mtime, otime (creation time)
    struct btrfs_timespec atime, ctime, mtime, otime;
};
```

**Key inode flags:**
| Flag | Meaning |
|------|---------|
| `NODATACOW` (`chattr +C`) | Disable CoW for this file's data extents; write in place instead |
| `NODATASUM` | Disable checksums for this file (implied by NODATACOW) |
| `COMPRESS` | Compress file data (algorithm from inode_item or mount option) |
| `PREALLOC` | File has unwritten (preallocated) extents |
| `SYNC` | Synchronous writes (each write is an fsync) |

**`chattr +C` (NODATACOW):** Disables CoW for data extents only — metadata (inode, directory entries) still uses CoW. Writes go to the same physical blocks (like ext4/XFS). Consequence: snapshots of NODATACOW files do NOT capture the data (the snapshot sees whatever the live file currently contains, since they share the same physical blocks). Use for: VM images, database files with their own WAL.

### 5.2 EXTENT_DATA Items — Three Forms

```c
// Key: (ino, EXTENT_DATA, file_offset)
struct btrfs_file_extent_item {
    __le64  generation;     // transaction ID of this extent's creation
    __le64  ram_bytes;      // uncompressed byte count (= num_bytes if not compressed)
    __u8    compression;    // BTRFS_COMPRESS_NONE / ZLIB / LZO / ZSTD
    __u8    encryption;     // 0 = none (encryption not implemented in Btrfs)
    __le16  other_encoding;
    __u8    type;           // BTRFS_FILE_EXTENT_INLINE / REGULAR / PREALLOC
    // For REGULAR and PREALLOC:
    __le64  disk_bytenr;    // logical address of the extent (0 = hole)
    __le64  disk_num_bytes; // length of the extent on disk (may be > num_bytes if shared)
    __le64  offset;         // offset within disk extent (for cloned sub-extents)
    __le64  num_bytes;      // logical length of this mapping
};
```

**Three extent types:**

```
1. INLINE (type = BTRFS_FILE_EXTENT_INLINE):
   File data stored directly in the leaf node (after the item header).
   Used for small files (< nodesize/2, default < 8KB) unless compression is enabled.
   ram_bytes = actual data size; disk_bytenr field not used.
   Reading: zero block I/O — data is in the metadata buffer.
   Tradeoff: wastes leaf space; suitable for config files, symlinks.

2. REGULAR (type = BTRFS_FILE_EXTENT_REGULAR):
   File data at a separate extent (disk_bytenr, disk_num_bytes).
   offset field allows sub-extent references (for clones and reflinks):
     file offset 0..99 → disk extent at bytenr=X, disk_len=200, offset=0  (uses first 100 bytes)
     file offset 0..99 in clone → same X, disk_len=200, offset=0 (shared)
     CoW writes first 10 bytes of clone → new extent for bytes 0..9, clone still refs X offset=10

3. PREALLOC (type = BTRFS_FILE_EXTENT_PREALLOC):
   Space allocated but not yet written (fallocate() equivalent).
   On read: returns zeros.
   On write: converts to REGULAR in-place (no new extent needed since blocks are reserved).
   Differs from XFS unwritten extents: Btrfs PREALLOC is in the FS tree, not the extent tree.
```

### 5.3 Compression

```
Compression in Btrfs is per-file-extent, transparent to applications.

Write path with compression enabled:
  1. write() → page cache dirty pages accumulate
  2. writeback: collect pages for one compression unit (default 128KB)
  3. Compress in-memory: zstd_compress() / lzo_compress() / etc.
  4. If compressed_size < original_size: write compressed data to disk
     - disk_num_bytes = compressed size (rounded up to sectorsize)
     - ram_bytes = original size
     - compression field = algorithm
  5. If compressed_size >= original_size: write uncompressed (no benefit)
  6. Create EXTENT_DATA item with compression field set

Read path:
  1. Read extent from disk (disk_num_bytes bytes)
  2. Decompress to ram_bytes
  3. Serve from page cache

Checksum covers the compressed on-disk data, not the original.
After decompression, the decompressed data is NOT re-checksummed.
(If decompressor is buggy, corruption may not be detected.)

Algorithms:
  zlib:  slowest, best ratio. Good for cold archival data.
  lzo:   fast, moderate ratio. Good for warm data on spinning disk.
  zstd:  best balance of speed and ratio. Default recommendation since kernel 4.14.
         Level 1 (default): ~3GB/s on modern CPU. Level 3: better ratio, ~1GB/s.

Setting compression:
  mount -o compress=zstd:3 /dev/sdX /mnt      # mount-wide default
  btrfs property set /mnt/myfile compression zstd  # per-file
  chattr +c /mnt/myfile                        # per-file (uses mount default algorithm)
```

---

## Section 6: Snapshots, Send/Receive, and Reflinks — Deep Mechanics

### 6.1 Snapshot Delete — Why It Can Be Slow

Creating a snapshot is O(1). Deleting one can be O(filesystem_size).

```
Delete snapshot 258 (which shares many extents with subvolume 256):

btrfs subvolume delete /mnt/snap258
  → Removes ROOT_ITEM(258) from root tree
  → Marks old_root_of_258 for deletion
  → Transaction commits

Background: btrfs-cleaner kernel thread processes the deletion:
  btrfs_drop_snapshot():
    Walk every tree node in snapshot 258's FS tree (depth-first)
    For each node:
      Look up EXTENT_ITEM in extent tree
      Decrement refcount (delayed ref)
      If refcount reaches 0: extent is freed
      If refcount > 0: extent still shared (by subvolume 256 or other snapshots)
                       leave it allocated

  The walk must process EVERY leaf node in the snapshot's FS tree.
  For a 1TB snapshot with millions of files: this can take minutes to hours.
  It runs in the background; the filesystem is usable during deletion.
  But: disk space is NOT reclaimed immediately — only as btrfs-cleaner progresses.

Monitoring deletion progress:
  btrfs subvolume list -s /mnt           # shows snapshots still being deleted
  btrfs qgroup show /mnt                 # if qgroups enabled, shows exclusive usage
  watch -n2 'btrfs filesystem show'      # watch free space increase as cleaner runs
```

### 6.2 Reflinks

```bash
# Reflink copy (instant, no data copied):
cp --reflink=always src dst
# Creates a new inode with EXTENT_DATA items pointing to the same extents as src
# Extent tree reference counts incremented (delayed refs)
# Time: O(number of extents in src) — typically milliseconds

# CoW-on-write: when dst is modified:
#   Only the modified extents are CoW'd → new physical data
#   Unmodified extents remain shared

# Verify sharing:
btrfs filesystem du /mnt/src /mnt/dst
# "Shared" column shows bytes shared between files
```

**Reflink and snapshot interaction:**
```
subvolume 256, file A (1GB): [extent E1]
cp --reflink file_A file_B:
  file A: [extent E1, refs=2]
  file B: [extent E1, refs=2]

Snapshot of subvolume 256 → subvolume 258:
  All FS tree nodes shared between 256 and 258
  E1 still has refs=2 (not incremented by snapshot — the FS tree node is the ref)
  Snapshot effectively shares E1 via the shared FS tree node

Modify file A (CoW):
  New extent E2 allocated for modified region of file A
  file A now: [E2 (modified region), E1 (unmodified region)]
  file B still: [E1, refs=2] (one ref from file B, one from snapshot)

du -sh file_A file_B:
  file_A: shows full size (E2 exclusive + E1 shared)
  file_B: shows full size (E1 shared)
  Total physical: E1 (1 copy) + E2 (modified part) = < 2 × original size
```

### 6.3 Send/Receive Internals

```
Send stream generation (fs/btrfs/send.c):

Key data structures:
  sctx->send_root:   the snapshot being sent (read-only)
  sctx->parent_root: the parent snapshot for incremental (read-only)
  sctx->send_filp:   file descriptor of the send pipe/file

Main loop (btrfs_iterate_dir_inodes → process_recorded_refs):
  1. Walk send_root's FS tree via btrfs_search_slot, processing items in key order
  2. For each inode:
     a. Compare with parent_root's equivalent inode (incremental mode)
     b. Classify change: CREATED / DELETED / MODIFIED / RENAMED / UNCHANGED
  3. Emit appropriate send commands

For each MODIFIED file:
  Compare EXTENT_DATA items between send_root and parent_root:
  a. Same disk_bytenr in both → CLONE command (zero data transferred)
  b. Different disk_bytenr → WRITE command (data must be sent)

The CLONE command:
  struct btrfs_tlv { type=BTRFS_SEND_C_CLONE, length, offset, length, clone_uuid, clone_ctransid, clone_path, clone_offset }
  Receiver: calls BTRFS_IOC_CLONE_RANGE ioctl to create reflink
  Space used: 0 bytes on receiver (sharing with existing extent)
  Network bytes: ~50 bytes per clone (just the reference, not the data)

Stream integrity:
  Each command is prefixed with type + length + CRC32 of the command data.
  btrfs receive verifies each command's CRC before applying.
  On corruption: receive stops with error; filesystem is not modified past that point.
```

---

## Section 7: The Log Tree — fsync Without Full Commit

A full transaction commit touches many B-trees and flushes many pages. For `fsync()`, Btrfs uses a per-subvolume log tree to provide durability without paying the full commit cost.

```
fsync() path:
  1. Flush dirty data pages for this inode to disk (bio submit + wait)
  2. Write changed inode item + changed EXTENT_DATA items to the log tree
     (log tree is a small dedicated B-tree, separate from the FS tree)
  3. Write log commit record (single write, analogous to JBD2 commit block)

Log tree format:
  Same B-tree structure as an FS tree.
  Contains only: INODE_ITEM, EXTENT_DATA, DIR_ITEM, DIR_INDEX items
  for the specific inode(s) being fsynced.
  Does NOT contain free space updates, extent tree updates, etc.

Recovery from log tree:
  At mount with a dirty log tree:
  1. Read log tree from log_root (in superblock)
  2. Replay: apply INODE_ITEM / EXTENT_DATA items to the FS tree
  3. Discard log tree
  Recovery is partial: only fsync'd inodes are recovered; others may be lost
  (same guarantee as ext4 data=ordered)

Log tree commit sequence:
  btrfs_sync_file():
    btrfs_log_inode_parent()  → write changed items to log tree
    btrfs_sync_log()           → write log tree root + flush to disk
  Much faster than btrfs_commit_transaction() (only writes changed inode data)

Log tree interaction with snapshots:
  If a snapshot is taken while a log tree exists:
  The snapshot creation triggers a full transaction commit (flushes the log tree).
  Reason: the snapshot must capture a consistent state; the log tree represents
  uncommitted changes that the snapshot creator must decide to include or exclude.
  Practical implication: taking snapshots frequently while doing heavy fsync
  workloads reduces the benefit of the log tree optimization.
```

---

## Section 8: Performance Profile

### Where Btrfs Excels

| Scenario | Reason |
|----------|--------|
| Backup destination with snapshots | Send/receive + CLONE = near-zero-copy incremental backup |
| Container image store | Subvolume per container; reflinks for layer sharing; fast snapshot per container |
| Archival storage | Per-block data checksums detect bit-rot; scrub repairs with RAID-1 |
| Read-heavy after initial write | Data is contiguous at write time (CoW allocates fresh extents) |
| Transparent compression | zstd gives 2-5× compression ratio for text/log data with minimal CPU cost |
| Small filesystem (< 1TB, single device) | Simple and stable; features exceed ext4/XFS in snapshot/checksum |

### Where Btrfs Struggles

| Scenario | Root Cause | Mitigation |
|----------|-----------|------------|
| Random in-place writes (databases, VMs) | Every write CoWs blocks → fragmentation over time | `chattr +C` (NODATACOW); use XFS instead |
| Very large FS (> 100TB) | B-tree depth increases; balance operations take hours | XFS scales better at this size |
| High metadata churn (millions of small files) | Every file create = multiple B-tree updates in a single transaction | ext4 with `dir_hash` is faster for small-file storms |
| qgroups (quota) enabled | qgroup accounting adds overhead to every extent alloc/free | Disable qgroups if not needed for quotas |
| RAID-5/6 | Write hole bug; data loss on power failure | Use mdadm RAID-6 + Btrfs single |
| Snapshot accumulation (100s of snaps) | Deletion is slow; back ref walks are O(snap_count) | Rotate snapshots aggressively; keep < 50 |
| Filesystem-level deduplication | `duperemove` runs extent tree back ref walks → very slow on large FS | Schedule during low-I/O windows |

### CoW Write Amplification

```
For a workload that overwrites blocks in-place (database updates):

Without NODATACOW:
  Each 4KB random write:
    1. Allocate new 4KB extent (block group free space update)
    2. Write 4KB data to new extent
    3. Update EXTENT_DATA item in FS tree (CoW path from root to leaf)
    4. Decrement old extent refcount (delayed ref)
    5. Update checksum tree (EXTENT_CSUM entry for new extent)
  Total I/O per 4KB write:
    4KB data + ~2-3 metadata blocks per CoW level + csum update
  Effective write amplification: ~5-10× vs raw overwrite

With NODATACOW:
  Each 4KB random write:
    1. Write 4KB data in-place (no new extent)
    2. Update checksum: DISABLED (NODATACOW implies NODATASUM)
    No extent tree update, no FS tree update (size unchanged)
  Effective write amplification: ~1× (same as XFS/ext4)
  Cost: no snapshots, no checksums for this file
```

---

## Section 9: Key Failure Modes

### 1. Metadata Space Exhaustion (ENOSPC from Metadata)

```
Symptom: df shows 30% full, but write() returns ENOSPC.
Cause: metadata block groups are full even though data block groups have space.

Btrfs separates data and metadata allocation.
Metadata block groups default: 1 per 4GB data, 256MB each.
Heavy workloads (millions of small files, many snapshots): metadata fills before data.

Diagnosis:
  btrfs filesystem show /dev/sdX      # shows total used
  btrfs filesystem df /mnt            # shows DATA vs METADATA used separately
  # If "Metadata: total=X, used=Y" where Y/X > 90% → metadata exhaustion

Fix:
  btrfs balance start -dusage=50 /mnt   # rebalance data block groups (compact them)
  # This frees underused data BGs, allowing their space to be converted to metadata BGs

  btrfs balance start -musage=50 /mnt   # rebalance metadata block groups

  # Emergency: convert some data space to metadata
  btrfs balance start -dlimit=1 -dusage=80 /mnt
```

### 2. CoW Fragmentation

```
Symptom: sequential read throughput degrades over months; filefrag shows thousands of extents.
Cause: repeated CoW on a file scatters its extents across the device.

Diagnosis:
  filefrag -v /path/to/file | tail -1   # "N extents found"
  btrfs filesystem defragment -v /path/to/file  # WARNING: breaks reflinks

Safe defragmentation strategy:
  For files without reflinks or snapshots:
    btrfs filesystem defragment -r -czstd /mnt/   # compress while defragging
  For files with snapshots:
    DO NOT defragment — you'll lose snapshot sharing, ballooning disk usage
    Instead: use NODATACOW for files that need stable I/O performance
```

### 3. Full Filesystem During Snapshot Delete

```
Symptom: filesystem appears full; btrfs-cleaner is running; space not freeing fast enough.
Cause: btrfs-cleaner processes snapshot deletion asynchronously. During cleanup,
  both old and new copies of extents exist temporarily.

Diagnosis:
  btrfs qgroup show /mnt     # if qgroups enabled, shows exclusive bytes per subvolume
  dmesg | grep btrfs         # "btrfs: transaction used N out of M bytes" 
  btrfs subvolume list -s /mnt  # snapshots pending deletion show "DELETED" flag

Mitigation:
  btrfs balance start -dusage=10 /mnt   # compact block groups (may create space)
  # Wait for btrfs-cleaner to finish (can take hours for large snapshots)
  # Emergency: add a device temporarily (btrfs device add)
```

### 4. Missing Device (RAID degraded)

```
Symptom: mount fails with "one or more devices missing" for RAID-1/10.
Cause: one device in a multi-device array is removed or failed.

Mount degraded (read-only access):
  mount -o degraded,ro /dev/sdA /mnt    # mount with missing device

If device permanently gone, replace:
  btrfs replace start 1 /dev/sdC /mnt   # replace devid 1 with new device sdC
  btrfs replace status /mnt             # monitor progress
  btrfs balance start /mnt              # rebalance to restore redundancy

Never run btrfs balance on a degraded array without first replacing the device.
```

### 5. Checksum Errors (Scrub Reports)

```
btrfs scrub start /mnt && btrfs scrub status /mnt

Output: "1 errors, 0 errors corrected"
  → Corruption detected. "errors corrected" = 0 → no mirror to repair from.

With RAID-1: "1 errors, 1 errors corrected"
  → Corruption detected AND repaired from the good mirror. Silent fix.

On checksum error with no repair:
  btrfs restore /dev/sdX /mnt/emergency_restore/   # extract readable files
  # Identify corrupted files:
  btrfs check --check-data-csum /dev/sdX 2>&1 | grep "checksum verify failed"
```

---

## Section 10: Production mkfs and Mount Options

### mkfs.btrfs for Common Scenarios

```bash
# Single device, checksums, free-space-tree v2 (recommended baseline)
mkfs.btrfs \
  --csum xxhash \               # faster than crc32c, stronger than crc32c
  --features free-space-tree \  # v2 free space cache (always use this)
  --label mydata \
  /dev/nvme0n1

# Two-device RAID-1 (data and metadata both mirrored)
mkfs.btrfs \
  -d raid1 \                    # data: mirror
  -m raid1 \                    # metadata: mirror
  --csum xxhash \
  --features free-space-tree \
  /dev/sda /dev/sdb

# Two-device: data RAID-0 (performance), metadata RAID-1 (safety)
mkfs.btrfs \
  -d raid0 \                    # data: striped (no redundancy)
  -m raid1 \                    # metadata: mirrored (safe)
  --features free-space-tree \
  /dev/nvme0n1 /dev/nvme1n1

# Backup destination (single device + compression)
mkfs.btrfs \
  --csum xxhash \
  --features free-space-tree \
  --nodesize 16384 \            # default; fine for backup workload
  /dev/sdb

# Container runtime (many small files, many subvolumes)
mkfs.btrfs \
  --csum xxhash \
  --features free-space-tree \
  --nodesize 16384 \
  /dev/sdb
# Use subvolumes per container; overlay driver or native btrfs driver
```

### Mount Options

```bash
# General recommendation
mount -o \
  compress=zstd:1,\             # transparent compression (level 1 = fast)
  space_cache=v2,\              # use free space tree (not inodes)
  noatime,\                     # skip atime updates
  autodefrag,\                  # background defrag for small writes (databases: do NOT use)
  /dev/nvme0n1 /mnt

# Backup destination (read safety over write performance)
mount -o \
  space_cache=v2,\
  noatime,\
  commit=60,\                   # flush to disk every 60s (reduce I/O for write-once backup)
  /dev/sdb /backup

# Database workload with NODATACOW files (must set per-file with chattr)
mount -o \
  space_cache=v2,\
  noatime,\
  nodatacow,\                   # disable CoW globally (not recommended — use per-file)
  /dev/nvme0n1 /dbdata
# Better: mount normally, then: chattr +C /dbdata/postgresql/
# chattr +C disables CoW for that directory tree only

# Key options table:
# compress=zstd:N   Transparent compression. N=1 fast, N=19 best ratio.
# space_cache=v2    Use free space tree (v2). Always set this.
# autodefrag        Background defragmentation for small-write patterns.
#                   WARNING: breaks reflinks. Use only for specific workloads.
# commit=N          Transaction commit interval in seconds (default 30).
# ssd               Enable SSD-specific optimizations (sequential reads, less rotation seeking).
# discard=async     Asynchronous TRIM on free (good for SSDs; async avoids blocking I/Os).
# rescue=ibadroots  Mount even if some tree roots are corrupt (emergency read).
# degraded          Mount with missing device (RAID degraded mode).
```

---

## Section 11: Source Code Map

```
fs/btrfs/
  ctree.c             — CoW B-tree: btrfs_search_slot(), btrfs_cow_block(),
                        btrfs_insert_item(), btrfs_del_item()
  ctree.h             — All on-disk structures: btrfs_header, btrfs_item,
                        btrfs_extent_item, btrfs_file_extent_item, etc.
  transaction.c       — Transaction lifecycle: btrfs_start_transaction(),
                        btrfs_commit_transaction(), create_pending_snapshot()
  delayed-ref.c       — Delayed reference system: btrfs_add_delayed_ref(),
                        btrfs_run_delayed_refs()
  extent-tree.c       — Extent allocation/free: btrfs_alloc_extent(),
                        btrfs_free_extent(), back ref updates
  block-group.c       — Block group management: allocation, free space tracking
  free-space-cache.c  — Free space v1 (inode-based cache)
  free-space-tree.c   — Free space v2 (B-tree based)
  send.c              — Send stream: send_subvol(), emit_write(), emit_clone()
  backref.c           — Back reference resolution: btrfs_find_all_roots()
  file.c              — File write: btrfs_file_write_iter() → CoW or NOCOW path
  inode.c             — Inode operations: btrfs_new_inode(), btrfs_setattr()
  compression.c       — Compression: btrfs_compress_pages(), btrfs_decompress()
  disk-io.c           — Block I/O: checksum on read (btrfs_validate_metadata_buffer())
  volumes.c           — Multi-device: chunk allocation, stripe I/O, RAID read/write
  raid56.c            — RAID5/6 parity: stripe read-modify-write (the buggy part)
  tree-log.c          — Log tree: btrfs_log_inode(), btrfs_sync_log() for fsync
  scrub.c             — Background scrub: checksum verification, repair
  ioctl.c             — User-facing ioctls: snapshot, defrag, balance, send, receive

Key reading order:
  ctree.c (btrfs_search_slot, btrfs_cow_block)  — foundation
  transaction.c (btrfs_commit_transaction)       — understand the commit sequence
  delayed-ref.c                                  — understand why extent-tree isn't updated inline
  send.c (send_subvol, send_write, send_clone)   — how snapshots are serialized
```

---

## Section 12: Btrfs vs XFS vs ext4 — Architect Comparison

| Dimension | Btrfs | XFS | ext4 |
|-----------|-------|-----|------|
| Write model | CoW always (unless NODATACOW) | Direct + delalloc | Direct + delalloc |
| Fragmentation risk | High (CoW scatters extents) | Low (large extent alloc) | Medium (buddy alloc) |
| Snapshot | Native, O(1) creation | No (use LVM thin) | No (use LVM thin) |
| Data checksums | Yes (all data + metadata) | No (metadata only, v5) | No (metadata only) |
| Multi-device/RAID | Built-in (avoid RAID5/6) | No (use mdadm/LVM) | No (use mdadm/LVM) |
| Compression | Built-in (zstd/lzo/zlib) | No | No |
| Reflinks | Yes | Yes (v5) | Yes (kernel 4.16+) |
| Online defrag | Yes (breaks reflinks) | Yes (xfs_fsr) | Yes (e4defrag) |
| Online repair | Limited (scrub repairs with RAID-1) | xfs_scrub (online, RMAP) | Offline only (e2fsck) |
| Max FS size | 16 EiB | 8 EiB | 1 EiB |
| Journal/log | Log tree (per-subvolume, for fsync) | Byte-range CIL log | JBD2 block-level journal |
| Metadata efficiency | High CoW overhead | Low (byte-range log) | Medium (full-block journal) |
| Production maturity | Stable for specific use cases | Very stable | Very stable |

**Unique Btrfs advantages over XFS/ext4:**
1. **Data checksums** — only filesystem that checksums data blocks by default. Silent corruption is detectable.
2. **Native snapshots** — O(1) creation, no LVM dependency. Enables per-commit-point rollback.
3. **Send/receive** — network-efficient incremental replication using CLONE for shared extents.
4. **Built-in compression** — transparent, per-file, no separate layer needed.
5. **Per-file RAID profile** — data vs metadata on different RAID profiles in one mkfs.

**Where XFS wins over Btrfs:**
1. **Consistent write performance** — no CoW overhead; performance doesn't degrade as FS ages.
2. **Large-scale metadata** — millions of files without fragmentation; B-tree free space vs BG allocation.
3. **Online repair with RMAP** — xfs_scrub repairs metadata online; Btrfs scrub can only repair data with RAID-1.
4. **Production maturity at scale** — Btrfs at > 100TB or with heavy random-write workloads is risky.

**Workload decision:**

| Workload | Choice | Reason |
|----------|--------|--------|
| Database primary (PostgreSQL, MySQL) | XFS | No CoW overhead; predictable latency |
| VM image store | Btrfs (NODATACOW) or XFS | Btrfs if snapshots needed; XFS if stable performance needed |
| Backup destination | **Btrfs** | Send/receive + CLONE = bandwidth-efficient; scrub = integrity |
| Container runtime | **Btrfs** | Subvolumes + native overlay; fast per-container snapshot |
| HPC / large file sequential | XFS | Better large contiguous allocation |
| Archival (10+ years bit-rot detection) | **Btrfs** | Only option with data checksums + repair |
| Boot / root partition | ext4 | Universally supported; simple |
| NVMe data volume, high concurrency | XFS | Per-AG scaling; no CoW serialization |

---

## Quick Reference

```
On-disk entry point:
  Superblock (64KB) → root tree (bytenr) → all other trees via ROOT_ITEMs

B-tree node:
  btrfs_header (101B) + key-ptrs (internal, 33B each, 495/node) or
                         items+data (leaf, items=25B, data=variable)
  Every node: CRC32c checksum, FSID, generation (transaction ID)

CoW path:
  Modify leaf → CoW leaf + all ancestors to root → update ROOT_ITEM
  O(depth) new blocks per modification; depth typically 2-4

Delayed refs:
  Extent tree NOT updated inline; batched as delayed_ref_node in rb-tree
  Applied at transaction commit to avoid cascading CoW

Transaction commit:
  Freeze → flush data → run delayed refs → write tree blocks (child before parent)
  → write superblock (THE commit point) → unblock next transaction

Chunk/RAID:
  Chunk tree: logical → physical (device + offset)
  RAID at chunk level: one chunk = one RAID stripe set
  RAID5/6: UNSAFE (write hole); use mdadm + Btrfs single

Snapshots:
  Create: O(1) — share root node, increment generation
  Delete: O(filesystem size) — background btrfs-cleaner walks entire FS tree

Free space:
  Always use space_cache=v2 (free space tree, not inodes)
  Metadata ENOSPC: check 'btrfs filesystem df'; balance with -dusage

Key failure modes:
  Metadata ENOSPC: balance with -dusage=50
  CoW fragmentation: defragment (but breaks reflinks)
  Snapshot space leak: btrfs-cleaner is async; space reclaimed gradually

Diagnostics:
  btrfs filesystem df /mnt          # data vs metadata usage
  btrfs filesystem show /dev/sdX    # device stats
  btrfs scrub start/status /mnt     # checksum verification
  btrfs balance status /mnt         # ongoing balance
  filefrag -v /path                 # extent count (fragmentation)
  btrfs subvolume list /mnt         # subvolumes and snapshots
  btrfs check /dev/sdX              # offline consistency check
```
