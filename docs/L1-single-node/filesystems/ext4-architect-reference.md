# ext4 Filesystem — Architect Deep Reference

> Companion to `day19-ext4-jbd2-recovery.md` (JBD2 journal modes, commit mechanics, recovery).
> Cross-reference with `xfs-architect-reference.md` for XFS vs ext4 design comparison.

---

## Section 0: Abbreviation and Terminology Reference

### Structural Units

| Term | Expansion | Meaning |
|------|-----------|---------|
| SB | Superblock | Global filesystem metadata; copy at block 0 of each block group (primary at offset 1024 bytes) |
| BG | Block Group | Fixed-size partition of the filesystem (~128MB default); the fundamental allocation unit |
| GDT | Group Descriptor Table | Array of `ext4_group_desc` structs, one per BG; lives after superblock |
| BGD | Block Group Descriptor | Single entry in GDT; tracks block bitmap, inode bitmap, inode table locations for one BG |
| BB | Block Bitmap | 1-bit-per-block bitmap indicating free/used within a BG |
| IB | Inode Bitmap | 1-bit-per-inode bitmap; which inode numbers in this BG are allocated |
| IT | Inode Table | Array of `ext4_inode` structs; 128 bytes (rev0) or 256 bytes (large inodes) each |
| BG0 | Block Group 0 | First block group; contains primary SB, GDT, reserved GDT blocks |

### Inode and Extent Terms

| Term | Expansion | Meaning |
|------|-----------|---------|
| EXT4_EXTENTS_FL | Extents Flag | inode flag (0x80000) — if set, inode uses extent tree; else old indirect block map |
| EH | Extent Header | `ext4_extent_header`: magic 0xF30A, entries count, max entries, tree depth |
| EI | Extent Index | `ext4_extent_idx`: internal tree node pointing to a child block |
| EL | Extent Leaf | `ext4_extent`: leaf entry mapping logical→physical blocks, up to 32767 blocks per entry |
| i_block | Inode Block Array | 60-byte field in inode; holds root of extent tree (depth≥0) or 15 indirect pointers (old) |
| ee_len | Extent Length | 15-bit field; if bit 15 set → unwritten (pre-allocated but not initialized) extent |
| delalloc | Delayed Allocation | Data written to page cache, physical block not assigned until writeback; reduces fragmentation |
| mballoc | Multi-Block Allocator | `fs/ext4/mballoc.c`; allocates multiple blocks in one pass using buddy system |
| prealloc | Pre-allocation | `fallocate()` or speculative mballoc prealloc; reserves physical blocks without data |
| unwritten | Unwritten Extent | Allocated blocks not yet initialized to zero; zero-fill happens on first read |
| inline data | Inline Data | File content ≤60 bytes stored directly in i_block field (no separate data block) |

### Journal Terms (JBD2)

| Term | Expansion | Meaning |
|------|-----------|---------|
| JBD2 | Journaling Block Device 2 | The journal layer shared by ext3/ext4; lives at `fs/jbd2/` |
| JH | Journal Head | `struct journal_head`; per-buffer journal metadata (one per journaled buffer) |
| T_RUNNING | Transaction Running | Current transaction accepting modifications |
| T_COMMIT | Transaction Commit | Transaction being written to journal |
| CP | Checkpoint | Writing committed journal blocks to their final on-disk location; reclaims journal space |
| TID | Transaction ID | Monotonically increasing 32-bit ID per committed transaction |
| grant head | Grant Head | Journal log space reservation accounting; two heads: `j_head` (written) and `j_tail` (checkpointed) |
| revoke | Revoke Record | Journal record marking a block as "do not replay"; prevents replaying freed metadata |
| ordered data | Ordered Data | `data=ordered` mode: data written before metadata commit; default ext4 mode |

### Allocation and Block Map Terms

| Term | Expansion | Meaning |
|------|-----------|---------|
| bg_free_blocks_count | BG Free Block Count | In BGD; updated by mballoc on each allocation |
| mb_order | Buddy Order | mballoc internal: buddy allocator order (2^order contiguous blocks) |
| pa | Pre-Allocation Structure | `ext4_prealloc_space`; tracks reserved blocks per-inode or per-locality-group |
| lg | Locality Group | mballoc group: per-CPU set of pre-allocated blocks for small file allocation |
| flex_bg | Flexible Block Group | Feature: cluster N BGs into one flex group, place all inode tables together |

### Mount Options and Features

| Term | Meaning |
|------|---------|
| `has_journal` | Superblock feature: JBD2 journal present |
| `extents` | Superblock compat feature: extent tree enabled (default since ext4) |
| `dir_index` | HTree B-tree directory index enabled |
| `large_file` | Files > 2GB supported |
| `sparse_super` | Only BG 0, 1, and powers of 3/5/7 have SB copies |
| `64bit` | >2^32 blocks supported (large filesystem feature) |
| `flex_bg` | Flexible block groups enabled |
| `uninit_bg` | Block/inode bitmaps pre-initialized to "all free" at format time; skips zero-fill |
| `meta_bg` | Meta block groups: GDT at start of each meta-BG (not all in BG0) |
| `mmp` | Multi-Mount Protection: disk heartbeat prevents dual mount |
| `bigalloc` | Cluster-based allocation: allocation granularity = cluster (multiple blocks) |
| `inline_data` | Small files stored inline in inode |

---

## Section 1: On-Disk Layout

### Block Group Structure

```
Disk Layout (left to right = increasing LBA):

  [Boot] [SB copy] [GDT copy] [Reserved GDT] [BB] [IB] [IT................] [Data blocks.............]
         BG 0                                                                  BG 0 data

  [SB*] [GDT*] [Reserved GDT*] [BB] [IB] [IT...] [Data blocks...............]
         BG 1  (* = only if not sparse_super)

  ... repeat for each BG ...

  BG size  = s_blocks_per_group * block_size   (default: 32768 * 4096 = 128MB)
  Inodes   = s_inodes_per_group               (default: 8192 per BG)
  IT size  = 8192 * 256 bytes = 2MB           (with large inodes feature)
```

Key structural constants (default 4K block, large inodes):

| Field | Default Value | Note |
|-------|--------------|------|
| Block size | 4096 bytes | Set at mkfs; can be 1K/2K/4K |
| Blocks per group | 32768 | = 8 * block_size * 8 (fits in one BB) |
| BG size | 128 MB | 32768 * 4096 |
| Inodes per group | 8192 | Default ratio: 1 inode per 16KB |
| Inode size | 256 bytes | `-I 256`; 128 bytes minimum (rev0) |
| IT blocks | 512 | 8192 * 256 / 4096 |

### Superblock (`ext4_super_block`) Key Fields

```c
// include/linux/ext4_fs.h
struct ext4_super_block {
    __le32  s_inodes_count;        // total inodes
    __le32  s_blocks_count_lo;     // total blocks (low 32 bits)
    __le32  s_r_blocks_count_lo;   // reserved blocks for root
    __le32  s_free_blocks_count_lo;
    __le32  s_free_inodes_count;
    __le32  s_first_data_block;    // 0 for 4K blocks, 1 for 1K blocks
    __le32  s_log_block_size;      // 0=1K, 1=2K, 2=4K
    __le32  s_blocks_per_group;
    __le32  s_inodes_per_group;
    __le32  s_mtime;               // last mount time
    __le32  s_wtime;               // last write time
    __le16  s_state;               // EXT4_VALID_FS / EXT4_ERROR_FS
    __le16  s_errors;              // behavior on error: continue/remount-ro/panic
    __le32  s_lastcheck;           // time of last fsck
    __le32  s_checkinterval;       // max time between fscks
    __le32  s_creator_os;          // 0 = Linux
    __le32  s_rev_level;           // 0 = original, 1 = dynamic (has compat features)
    __le32  s_feature_compat;      // compat features (safe to mount if unknown)
    __le32  s_feature_incompat;    // incompat features (MUST know to mount)
    __le32  s_feature_ro_compat;   // ro-compat (must know to write)
    __u8    s_uuid[16];            // filesystem UUID
    char    s_volume_name[16];
    __le64  s_journal_inum;        // inode number of internal journal file
    // ... 64bit fields, checksum, etc.
};
```

**Feature flag discipline:**
- `s_feature_compat`: kernel can mount r/w even without understanding these
- `s_feature_incompat`: kernel MUST understand before mounting at all (e.g., `extents`, `64bit`)
- `s_feature_ro_compat`: can mount read-only without understanding; needs understanding for write

### Group Descriptor (`ext4_group_desc`)

```c
struct ext4_group_desc {
    __le32  bg_block_bitmap_lo;    // block number of block bitmap
    __le32  bg_inode_bitmap_lo;    // block number of inode bitmap
    __le32  bg_inode_table_lo;     // block number of inode table start
    __le16  bg_free_blocks_count_lo;
    __le16  bg_free_inodes_count_lo;
    __le16  bg_used_dirs_count_lo;  // directories in this BG
    __le16  bg_flags;              // EXT4_BG_INODE_UNINIT | EXT4_BG_BLOCK_UNINIT
    __le32  bg_exclude_bitmap_lo;  // (snapshot; rarely used)
    __le16  bg_block_bitmap_csum_lo; // checksum for block bitmap
    __le16  bg_inode_bitmap_csum_lo;
    __le16  bg_itable_unused_lo;   // unused inode table entries at end
    __le16  bg_checksum;           // CRC16 of sb_uuid, BG number, BGD
    // 64bit extension fields...
    __le32  bg_block_bitmap_hi;
    __le32  bg_inode_bitmap_hi;
    __le32  bg_inode_table_hi;
    // ...
};
```

`EXT4_BG_INODE_UNINIT` / `EXT4_BG_BLOCK_UNINIT`: the `uninit_bg` feature marks newly-formatted BGs so the kernel doesn't need to read/write the all-free bitmaps — it synthesizes them on demand. This makes `mkfs.ext4` nearly instantaneous even for large filesystems.

---

## Section 2: Inode Structure

### `ext4_inode` Layout (256-byte form)

```c
struct ext4_inode {
    __le16  i_mode;             // file type + permissions
    __le16  i_uid;              // owner UID (low 16)
    __le32  i_size_lo;          // file size (low 32 bits)
    __le32  i_atime;
    __le32  i_ctime;            // also used for ctime nanoseconds in extra space
    __le32  i_mtime;
    __le32  i_dtime;            // deletion time
    __le16  i_gid;              // group GID (low 16)
    __le16  i_links_count;
    __le32  i_blocks_lo;        // 512-byte block count (NOT filesystem block count)
    __le32  i_flags;            // EXT4_EXTENTS_FL, EXT4_INLINE_DATA_FL, etc.
    // ...
    __le32  i_block[EXT4_N_BLOCKS]; // 15 entries × 4 bytes = 60 bytes
                                     // holds: extent tree root OR 12 direct + 1 ind + 1 dind + 1 tind
    __le32  i_generation;       // NFS generation number
    __le32  i_file_acl_lo;      // extended attribute block
    __le32  i_size_high;        // file size (high 32 bits) — for large_file feature
    // 128-byte boundary — fields below require inode_size >= 256
    __le16  i_extra_isize;      // extra space beyond 128 bytes that is valid
    __le16  i_checksum_hi;      // crc32c checksum high bits
    __le32  i_ctime_extra;      // ctime nsec and extra sec bits
    __le32  i_mtime_extra;
    __le32  i_atime_extra;
    __le32  i_crtime;           // creation time (not in POSIX; ext4 v2 addition)
    __le32  i_crtime_extra;
    __le32  i_version_hi;
    __le32  i_projid;           // project quota ID
};
```

**The `i_block[15]` dual use:**

```
Without extents (old indirect block map, for compatibility):
  i_block[0..11]  = 12 direct block pointers
  i_block[12]     = single indirect block pointer (→ block of 1024 block ptrs at 4K)
  i_block[13]     = double indirect (→ block → block of ptrs)
  i_block[14]     = triple indirect (→ block → block → block of ptrs)
  Max file size: 12 + 1024 + 1024² + 1024³ = ~1TB

With extents (EXT4_EXTENTS_FL set):
  i_block[0..14]  = extent tree root (60 bytes = ext4_extent_header + 4 entries OR 3 idx entries)
  Root depth 0: fits ≤4 extents inline in inode (no additional blocks needed)
  Root depth 1+: root contains index nodes pointing to leaf blocks
```

---

## Section 3: Extent Tree

The extent tree replaced the old indirect block map in ext4. It maps file logical blocks to physical blocks using a balanced B+-tree of variable-length contiguous runs (extents). Understanding it deeply requires tracing: structure layout → lookup → insertion → split → merge → hole → unwritten → punch hole.

### 3.1 Data Structures (Byte-Level Layout)

```c
// include/linux/ext4_extents.h

struct ext4_extent_header {   // 12 bytes, always first in any node
    __le16  eh_magic;         // must be 0xF30A; validated on every read
    __le16  eh_entries;       // number of valid entries currently in this node
    __le16  eh_max;           // maximum entries this node can hold
    __le16  eh_depth;         // 0 = leaf node; N = internal node with N levels below
    __le32  eh_generation;    // version counter for external tools (fsck); kernel ignores
};                            // total: 12 bytes

struct ext4_extent_idx {      // 12 bytes, internal node entry
    __le32  ei_block;         // first logical block covered by this subtree
    __le32  ei_leaf_lo;       // physical block# of child node (low 32 bits)
    __le16  ei_leaf_hi;       // physical block# of child node (high 16 bits → 48-bit total)
    __u16   ei_unused;
};                            // total: 12 bytes

struct ext4_extent {          // 12 bytes, leaf node entry
    __le32  ee_block;         // first logical block# of this extent
    __le16  ee_len;           // number of blocks; bit 15 encodes initialized vs unwritten:
                              //   bit15=0: initialized extent, length = ee_len (1..32767)
                              //   bit15=1: unwritten extent, length = ee_len & 0x7FFF
    __le16  ee_start_hi;      // physical start block# (high 16 bits)
    __le32  ee_start_lo;      // physical start block# (low 32 bits)
};                            // total: 12 bytes
```

**All three structs are 12 bytes.** This is intentional — the same slot size means a node can hold either N index entries or N leaf entries, simplifying the capacity formula.

**Capacity of a node:**
```
Root (in inode i_block, 60 bytes):
  60 - 12 (header) = 48 bytes → 48/12 = 4 leaf extents OR 3 index entries

Internal/leaf block (4096 bytes):
  4096 - 12 (header) = 4084 bytes → 4084/12 = 340 entries per node
```

**Max tree depth and file size:**
```
Depth 0 (root only):         4 extents × 32767 blocks × 4096 = 512MB
Depth 1 (root → 3 leaves):  3 × 340 = 1020 extents
Depth 2:                     3 × 340 × 340 = ~347K extents
Depth 3:                     ~118M extents → handles files > 1 PB
Depth 4:                     ~40B extents → theoretical maximum
```
Kernel caps tree depth at 5 (EXT_MAX_LEVELS). For practical use, depth 1-2 covers nearly all real workloads.

### 3.2 Lookup: `ext4_find_extent()`

```c
// fs/ext4/extents.c — simplified

struct ext4_ext_path *ext4_find_extent(struct inode *inode, ext4_lblk_t block,
                                        struct ext4_ext_path **orig_path, int flags)
{
    // path[] array tracks one entry per tree level (depth+1 entries total)
    // path[0] = root (in inode buffer, always cached)
    // path[1] = level-1 node block
    // ...
    // path[depth] = leaf node

    eh = ext_inode_hdr(inode);           // pointer to header in i_block[]
    depth = ext_depth(inode);            // eh->eh_depth

    for (i = 0; i < depth; i++) {
        // Binary search in current index node for largest ei_block ≤ target
        ext4_ext_binsearch_idx(inode, path + i, block);
        // Read child block from disk (or buffer cache)
        bh = read_extent_tree_block(inode, path[i].p_idx->ei_leaf_lo, depth - i - 1);
        path[i+1].p_hdr = ext_block_hdr(bh);
    }

    // Now at leaf node — binary search for the extent containing 'block'
    ext4_ext_binsearch(inode, path + depth, block);
    // path[depth].p_ext points to the matching extent (or NULL if hole)

    return path;
}
```

**Binary search within a node:**
```
Entries are sorted by ee_block (or ei_block for index nodes).
Binary search finds the largest entry whose ee_block ≤ target logical block.
If found extent covers target (ee_block ≤ target < ee_block + ee_len): hit.
Otherwise: hole (sparse file) or beyond EOF.
```

**Path structure — what it tracks:**
```c
struct ext4_ext_path {
    ext4_fsblk_t    p_block;   // physical block# of this node
    __u16           p_depth;   // depth of this level
    __u16           p_maxdepth;
    struct ext4_extent      *p_ext;   // points to matching leaf entry (leaf level)
    struct ext4_extent_idx  *p_idx;   // points to matching index entry (internal level)
    struct ext4_extent_header *p_hdr; // header of this node's block
    struct buffer_head      *p_bh;   // buffer holding this node (NULL for root)
};
```
The path is stack-allocated per lookup; it pins the buffer_heads along the traversal path, which prevents the nodes from being evicted from the buffer cache while a write operation modifies them.

### 3.3 Insertion and Splitting

When a new extent is inserted (e.g., after delalloc assigns physical blocks), the kernel calls `ext4_ext_insert_extent()`:

```
Case 1: New extent is adjacent and contiguous with an existing extent
  → Merge: extend ee_len of the existing entry. No structural change.
  Condition: new.ee_block == existing.ee_block + existing.ee_len
             AND new physical start == existing physical start + existing.ee_len
             AND both are initialized (or both unwritten)
             AND combined length ≤ 32767 (max ee_len)

Case 2: Leaf has space (eh_entries < eh_max)
  → Shift entries to make room; insert new extent in sorted position.
  One journal credit for the modified leaf block.

Case 3: Leaf is full (eh_entries == eh_max == 340)
  → Leaf split required:
     a. Allocate a new filesystem block for the second half of the leaf
     b. Move the upper half of entries to the new block
     c. Insert a new index entry in the parent pointing to the new leaf
     d. If parent is also full → recursive split upward
     e. If root is full → tree grows one level (root splits into two leaves;
        root becomes a depth-1 internal node pointing to both leaves)

Journal credits for a split:
  - 1 credit per leaf block modified or created
  - 1 credit per index block modified or created
  - 1 credit for the inode (root node)
  - ext4_ext_calc_credits_for_single_extent() computes the max worst case
```

**Tree growth example (root overflow):**
```
Before (depth=0, root has 4 extents, full):
  inode i_block:
    header: depth=0, entries=4, max=4
    extent[0]: logical 0..999   → phys 1000
    extent[1]: logical 1000..1999 → phys 2000
    extent[2]: logical 2000..2999 → phys 3000
    extent[3]: logical 3000..3999 → phys 4000

Insert extent[4]: logical 4000..4999 → phys 5000:
  → root is full → must split

After (depth=1):
  inode i_block (now depth=1, root has 2 index entries):
    header: depth=1, entries=2, max=3
    idx[0]: ei_block=0,    ei_leaf=block A
    idx[1]: ei_block=2000, ei_leaf=block B

  block A (leaf, depth=0):
    header: entries=2, max=340
    extent[0]: logical 0..999   → phys 1000
    extent[1]: logical 1000..1999 → phys 2000

  block B (leaf, depth=0):
    header: entries=3, max=340
    extent[0]: logical 2000..2999 → phys 3000
    extent[1]: logical 3000..3999 → phys 4000
    extent[2]: logical 4000..4999 → phys 5000   ← newly inserted
```

### 3.4 Extent Merging

The kernel tries to merge adjacent extents aggressively after insert, via `ext4_ext_try_to_merge()`:

```
Merge conditions (all must hold):
  1. Right extent immediately follows left: right.ee_block == left.ee_block + left.ee_len
  2. Right extent is physically adjacent: right.ee_start == left.ee_start + left.ee_len
  3. Same type: both initialized OR both unwritten (cannot merge initialized+unwritten)
  4. Combined length ≤ 32767 (the max representable in 15 bits of ee_len)

When merge happens:
  left.ee_len += right.ee_len
  Remove right entry from leaf node (shift entries down, decrement eh_entries)
  Mark leaf buffer dirty for journaling

Why merging matters:
  - Fewer extents → shallower tree → fewer block reads per lookup
  - Sequential write workload that mballoc serves from a PA window
    typically produces adjacent physical blocks → merge keeps the tree flat
  - Without merge, a 1GB sequential file written in 4KB chunks would produce
    262144 extents (very deep tree, slow lookup)
  - With merge, it produces 1 extent (root depth 0, single lookup)
```

### 3.5 Hole Handling (Sparse Files)

Holes are regions of a file with no backing physical blocks — reads return zeros without any disk I/O.

```
In the extent tree, a hole is simply the absence of an extent covering that logical range.

Example: file with data at offsets 0-4KB and 1GB-1GB+4KB, hole in between:
  inode i_block (depth=0):
    header: entries=2
    extent[0]: ee_block=0,       ee_len=1, ee_start=phys_A
    extent[1]: ee_block=262144,  ee_len=1, ee_start=phys_B
                                 ↑ 262144 = 1GB / 4KB

Read at offset 512KB (logical block 128):
  ext4_find_extent() binary search: largest ee_block ≤ 128 is extent[0] (ee_block=0)
  Coverage check: 0 + 1 = 1, target 128 ≥ 1 → not covered → hole
  ext4_ext_map_blocks() returns 0 blocks, flags=FIEMAP_EXTENT_UNWRITTEN? no, hole flag
  Page cache fills with zeros, no bio submitted

Write to hole:
  Triggers delalloc → mballoc allocates physical blocks → new extent inserted
  Hole is replaced with a real extent covering the written range
  Unwritten regions between existing extents and new extent remain as holes

lseek(fd, 0, SEEK_DATA) / lseek(fd, 0, SEEK_HOLE):
  Kernel walks extent tree to find boundaries between data and holes
  O(log N + number of extents) time
```

### 3.6 Unwritten Extents — Full Lifecycle

Unwritten extents (bit 15 of ee_len set) exist to provide pre-allocated space that is safe to read (returns zeros) before the application writes to it.

```
Step 1: fallocate(fd, 0, offset, length)   [or FALLOC_FL_KEEP_SIZE]
  ext4_fallocate()
    → ext4_ext_map_blocks(..., EXT4_GET_BLOCKS_CREATE_UNWRIT_EXT)
    → mballoc allocates physical blocks
    → Inserts extents with EXT_INIT_MAX_LEN bit set in ee_len (bit 15)
    → Journal: inode + leaf block modified
  Result: blocks allocated, block bitmap updated, extent marked unwritten

Step 2: read() from unwritten extent
  ext4_readpages() → ext4_ext_map_blocks()
  map->m_flags has EXT4_MAP_UNWRITTEN set
  → do NOT issue bio to disk; fill page with zeros instead
  → page is clean (not dirty); no writeback triggered

Step 3: write() to unwritten extent
  ext4_write_begin() → ext4_ext_map_blocks(..., EXT4_GET_BLOCKS_CONVERT_UNWRITTEN)
  Two sub-cases:
    a. write covers entire unwritten extent:
       → Flip bit 15 of ee_len (set to initialized) in place; single journal entry
    b. write covers partial extent:
       → Must SPLIT the unwritten extent:
          Before: [unwritten: logical 0..999]
          After write at 200..299:
            [unwritten: 0..199] [initialized: 200..299] [unwritten: 300..999]
          This is the "unwritten extent conversion" transaction — up to 5 journal credits
          (split can create 2 new extents + modify existing + inode + leaf block)
  → page written, dirty
  → writeback submits bio

Step 4: crash between fallocate and write
  On recovery: JBD2 replays journal → extents remain unwritten
  Post-recovery read: still returns zeros (correct; no stale data exposure)
  This is the key safety property: unwritten guarantees zero-read even after crash

Diagnostic:
  filefrag -v /path/to/file | grep "unwritten"
  # shows extents with the 'U' flag (unwritten)
  debugfs /dev/sda1 -R "dump_extents /path/to/file"
```

### 3.7 Hole Punching: `FALLOC_FL_PUNCH_HOLE`

```c
// fallocate(fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, offset, length)
// Frees physical blocks in [offset, offset+length), leaving a hole in the extent tree

ext4_punch_hole():
  1. Truncate page cache pages in range (writeback if dirty first)
  2. ext4_ext_remove_space(inode, start_block, end_block):
     Walk extent tree and for each extent overlapping [start, end]:
       a. Fully covered extent: delete entry, free blocks via ext4_free_blocks()
       b. Partially overlapping at start: shorten extent (decrease ee_len)
       c. Partially overlapping at end: advance ee_block + ee_start, decrease ee_len
       d. Extent fully surrounds punch range: split into two extents (both shortened)
  3. Journal: inode + all modified leaf blocks

Post-punch extent tree:
  Before: [initialized: 0..999]
  Punch 200..299:
    → [initialized: 0..199] [hole: 200..299] [initialized: 300..999]
  Physical blocks 200..299 returned to block bitmap (free)

Use case: sparse databases (SQLite WAL, PostgreSQL relation files with deleted rows)
```

### 3.8 Extent Status Cache (`ext4_es_cache`)

To avoid repeated extent tree lookups for the same inode, ext4 maintains an in-memory extent status (ES) cache per inode:

```c
// fs/ext4/extents_status.h
struct extent_status {
    struct rb_node  rb_node;
    ext4_lblk_t     es_lblk;    // logical block start
    ext4_lblk_t     es_len;     // length in blocks
    ext4_fsblk_t    es_pblk;    // physical block start (or 0 for hole/delayed)
    // status flags encoded in low bits of es_pblk:
    // EXTENT_STATUS_WRITTEN    — initialized on disk
    // EXTENT_STATUS_UNWRITTEN  — unwritten (preallocated)
    // EXTENT_STATUS_DELAYED    — in delalloc (no physical block yet)
    // EXTENT_STATUS_HOLE       — known hole (avoids tree lookup to confirm)
};
```

```
ES cache is a red-black tree of extent_status entries, per inode.
Hit: logical block found in ES cache → return immediately, no disk read.
Miss: walk on-disk extent tree → insert result into ES cache.

ES cache shrinking:
  When memory pressure is high, the ES cache shrinker prunes cold entries.
  This is tracked by ext4_es_stats (see /proc/fs/ext4/<dev>/es_shrinker_info).

Delalloc tracking:
  A delayed allocation extent appears in ES cache as EXTENT_STATUS_DELAYED
  before mballoc assigns physical blocks.
  At writeback time, the ES entry transitions from DELAYED → WRITTEN.
  This allows the kernel to accurately report file size and handle overwrites
  of not-yet-allocated regions without touching the on-disk extent tree.
```

### 3.9 Observability: Diagnosing the Extent Tree

```bash
# Show extents for a file (human-readable)
filefrag -v /path/to/file
# Output columns: extent#, logical start, physical start, length, flags
# Flags: N=not last, C=contiguous with previous, U=unwritten, M=merged

# Full dump via debugfs
debugfs /dev/sda1 -R "dump_extents /path/to/file"
# Shows the full tree with depth, each node's entries

# Count extents (fragmentation proxy)
filefrag /path/to/file
# "X extents found" — 1 extent for sequential, many = fragmented

# Find highly fragmented files
find /mountpoint -xdev -type f | xargs filefrag 2>/dev/null | \
  awk '$NF ~ /[0-9]+/ { if ($NF+0 > 100) print $NF, $0 }' | sort -rn | head -20

# ES cache stats
cat /sys/fs/ext4/sda1/es_shrinker_info   # how often ES cache is being shrunk
cat /proc/fs/ext4/sda1/mb_groups         # per-BG free block counts

# Check if a file uses extents
debugfs /dev/sda1 -R "stat <inode_number>" | grep "Flags"
# "Flags: 0x80000" → extents flag set
```

---

## Section 4: Multi-Block Allocator (mballoc)

mballoc (`fs/ext4/mballoc.c`) is ext4's block allocation engine. It replaced ext3's serial one-block allocator and is responsible for deciding *which* physical blocks to hand out for a given request. Understanding mballoc means understanding: the buddy system structure → how it loads from the block bitmap → the allocation criteria search → preallocation → how delalloc integrates → what happens on free.

### 4.1 The Buddy Bitmap System

mballoc maintains an in-memory buddy allocator for each block group. This is separate from the on-disk block bitmap — it is a cache that accelerates free-run searches.

```
On-disk block bitmap (per BG):
  32768 bits (for 32768 blocks per BG at 4KB), one bit per block
  bit=0: free; bit=1: allocated

In-memory buddy bitmaps (per BG, in struct ext4_group_info):
  Buddy order 0:  32768 bits — mirrors the block bitmap exactly
  Buddy order 1:  16384 bits — bit[i]=1 if blocks[2i] AND blocks[2i+1] are BOTH free
  Buddy order 2:   8192 bits — bit[i]=1 if all 4 blocks starting at 4i are free
  Buddy order 3:   4096 bits — 8 consecutive blocks all free
  ...
  Buddy order 13:     4 bits — 8192 consecutive blocks all free (= full BG free)

Total memory per BG: 32768/8 × 2 ≈ 8KB per BG
Total for 1TB filesystem (8192 BGs): ~64MB (acceptable)
```

**Building the buddy from the block bitmap:**
```c
// fs/ext4/mballoc.c — ext4_mb_generate_buddy()

for (i = 0; i < max_order; i++) {
    for (block = 0; block < blocks_per_group >> i; block++) {
        // buddy[i][block] = 1 iff all (2^i) blocks starting at (block << i) are free
        // Built bottom-up: order 1 derives from order 0, order 2 from order 1, etc.
        if (buddy[i-1][2*block] && buddy[i-1][2*block+1])
            set_bit(block, buddy[i]);
    }
}
```

**Lazy loading:** The buddy is not loaded for a BG until the first allocation request targets that BG. It is built from the on-disk block bitmap via `ext4_mb_load_buddy()`, and freed when memory pressure demands it. A per-BG `bb_prealloc_list` tracks active PAs to ensure they are accounted for even when the buddy is unloaded.

### 4.2 `ext4_group_info` — The Per-BG Allocation State

```c
// fs/ext4/mballoc.h
struct ext4_group_info {
    unsigned long   bb_state;           // EXT4_GROUP_INFO_NEED_INIT_BIT, etc.
    struct rw_semaphore alloc_sem;       // per-BG lock for allocation
    ext4_grpblk_t   bb_first_free;      // first free block (hint for bitmap scan)
    ext4_grpblk_t   bb_free;            // total free blocks in this BG
    ext4_grpblk_t   bb_fragments;       // number of free fragments (contiguous runs)
    ext4_grpblk_t   bb_largest_free_order; // largest contiguous run in buddy order units
    struct          list_head bb_prealloc_list; // active PAs with blocks in this BG
    void            *bb_bitmap;          // pointer to buddy bitmap (NULL if unloaded)
    // ...
};
```

`bb_largest_free_order` is the critical fast-path field: before locking a BG and doing a full buddy scan, mballoc checks `bb_largest_free_order` to quickly skip BGs that cannot satisfy the request. This avoids loading buddy bitmaps for BGs that are too full.

### 4.3 The Allocation Search: Criteria Levels

When `ext4_mb_new_blocks()` is called, it runs `ext4_mb_regular_allocator()` which implements a multi-pass search with progressively relaxed criteria:

```
Allocation request: (inode, goal BG, nblocks)

Pass cr=0 — Best quality, goal BG only:
  Criteria: buddy order ≥ ceil(log2(nblocks)), in the goal BG.
  If found: return the free run immediately (best locality, contiguous).
  If not found: try cr=1.

Pass cr=1 — Relaxed contiguity, goal BG first then neighbors:
  Criteria: any free run ≥ nblocks in goal BG, then neighboring BGs.
  Uses bb_largest_free_order to skip BGs that are definitely too full.
  If not found: try cr=2.

Pass cr=2 — Any match in goal BG:
  Criteria: any free blocks in goal BG, even if fragmented.
  mballoc will allocate whatever fits.

Pass cr=3 — Any BG in the filesystem:
  Linear scan of all BGs ordered by free block count.
  This is the "allocation of last resort" — fragmentation is likely.
  Triggered when filesystem is > ~85% full.

After each pass, if a match is found:
  → Try to carve it from a pre-allocation (PA) first (see Section 4.4).
  → If no PA, call ext4_mb_use_best_found() to claim from buddy bitmap.
```

**Why cr=0 is rare to hit in practice:**
A newly written large file starts with cr=0 and finds a large contiguous run in its goal BG. But once the filesystem fills up and BGs become fragmented, cr=0 misses and the allocator falls through to cr=1, cr=2, cr=3. The `mb_cr_score` stat tracks how often each criterion level is used.

### 4.4 Pre-Allocation (PA) System — Detailed Mechanics

PA exists to bridge the gap between allocation granularity (one logical block at a time, potentially) and physical contiguity (want a large run on disk).

**Per-inode PA:**
```
Trigger: an inode writes more than mb_stream_req blocks in the same call.
         (default: 16 blocks = 64KB threshold)

mballoc allocates a LARGER window than requested:
  Initial PA size: 2 × requested (rounded up to power of 2)
  Each subsequent sequential write: PA window doubles (up to mb_max_inode_prealloc)

Example: sequential writes of 16 blocks each:
  1st write: request 16 → PA window allocated = 32 blocks
             inode gets blocks 0..15; blocks 16..31 reserved in PA
  2nd write: request 16 → served from PA (blocks 16..31); no mballoc call needed
  3rd write: request 16 → PA exhausted; new PA allocated, window = 64 blocks
  4th write: served from new PA; ...

Per-inode PA lifecycle:
  Allocated: ext4_mb_new_inode_pa() → inserts struct ext4_prealloc_space into
             ei->i_prealloc_list AND into bg_info->bb_prealloc_list
  Released on inode close: ext4_mb_release_inode_pa() → returns unused blocks to
             block bitmap (they are NOT freed until PA is discarded)
  Force-released under memory pressure or filesystem sync

struct ext4_prealloc_space {
    struct list_head    pa_inode_list;  // linked from inode's i_prealloc_list
    struct list_head    pa_group_list;  // linked from BG's bb_prealloc_list
    spinlock_t          pa_lock;
    atomic_t            pa_count;       // reference count
    unsigned            pa_deleted;     // being discarded
    ext4_fsblk_t        pa_pstart;      // physical start of pre-allocated window
    ext4_lblk_t         pa_lstart;      // logical start
    ext4_grpblk_t       pa_len;         // total length of window
    ext4_grpblk_t       pa_free;        // blocks remaining unused in window
    unsigned short      pa_type;        // MB_INODE_PA or MB_GROUP_PA
};
```

**Locality Group (LG) PA:**
```
Trigger: allocation request < mb_stream_req (small file or metadata)

Per-CPU per-BG structure (struct ext4_locality_group):
  - Each CPU has its own locality group to avoid cross-CPU contention
  - mballoc pre-allocates mb_group_prealloc blocks (default: 512 = 2MB)
    from the goal BG and places them in the LG PA
  - Small allocations are carved from the LG PA without acquiring the BG lock

Why per-CPU:
  In a high-concurrency workload creating many small files:
  Without LG PA: every allocation acquires bg alloc_sem → serialized per BG
  With LG PA: each CPU carves from its own LG PA → nearly lockless until LG PA exhausted

LG PA does NOT track which inode owns which blocks:
  Small files land in the same BG, but not necessarily contiguous with each other.
  Goal is BG locality, not per-file contiguity.
```

### 4.5 Delayed Allocation (`delalloc`) — Integration with Extent Tree

Delayed allocation is the key mechanism that lets mballoc make better allocation decisions by seeing larger write extents.

```
Without delalloc (ext3 behavior):
  write(1 block) → allocate 1 physical block immediately → write to disk
  write(1 block) → allocate 1 physical block → write to disk
  ...
  1000 writes = 1000 separate allocation calls = potentially 1000 fragments

With delalloc (ext4 default):
  write(1 block) → data goes to page cache
                 → ES cache records: logical block 0 as EXTENT_STATUS_DELAYED
  write(1 block) → data goes to page cache
                 → ES cache: logical block 1 as EXTENT_STATUS_DELAYED
  ... (writeback timer fires or page cache pressure)
  writeback runs on inode:
    ext4_writepages() collects all dirty pages → finds 1000 DELAYED blocks
    mballoc sees request for 1000 contiguous blocks → allocates 1 large run
    Result: 1 extent on disk covering all 1000 blocks

The full delalloc write path:

  write(fd, buf, size):
    generic_file_write_iter()
      ext4_write_begin():
        grab pages in page cache
        ext4_da_reserve_space():          // "da" = delayed allocation
          check if we have enough free blocks (balloc_reserve check)
          increment ei->i_reserved_data_blocks counter
          does NOT allocate physical blocks yet
        copy data to pages (dirty)
        ext4_da_write_end():
          ext4_da_get_block_prep():       // called per page block
            mark page's buffer_heads as BH_Delay (no physical block)
            insert EXTENT_STATUS_DELAYED into ES cache

  writeback fires (dirty_writeback_centisecs or memory pressure):
    ext4_writepages():
      mpage_prepare_extent_to_map():      // collect contiguous dirty page range
      ext4_map_blocks(..., EXT4_GET_BLOCKS_CREATE):
        sees EXTENT_STATUS_DELAYED range
        calls ext4_mb_new_blocks() with full range as request
        mballoc allocates contiguous physical blocks (PA system engaged)
        ext4_ext_map_blocks() inserts new extent into on-disk extent tree
        buffer_heads updated with real physical block numbers (BH_Delay cleared)
      submit bio with real physical addresses

delalloc and ENOSPC:
  Space reservation happens at write() time via ext4_da_reserve_space():
    if (free_blocks - reserved_blocks < request): return -ENOSPC
  Physical allocation happens at writeback time.
  If mballoc fails at writeback (e.g., fragmentation prevented contiguous alloc):
    → journal error; filesystem remounts read-only (with errors=remount-ro)
  This is why keeping filesystem < 85% full is important:
    mballoc needs contiguous free space to honor reservations.

nodelalloc mount option:
  Disables delayed allocation. Physical block allocated immediately at write().
  Restores ext3-style behavior.
  Use for: databases that call fsync() per transaction and want deterministic ENOSPC.
  Cost: more fragmentation, more allocation calls, lower write throughput.
```

### 4.6 Block Free Path: `ext4_free_blocks()`

Understanding free is important because it directly affects future allocation quality.

```c
// fs/ext4/balloc.c + mballoc.c
ext4_free_blocks(inode, block, count, flags):
  1. Mark blocks free in the block bitmap (or defer if discard is pending)
  2. Update bg_free_blocks_count in the BG descriptor
  3. Update sb_free_blocks_count in the superblock
  4. Rebuild buddy bitmap entries for the affected BG:
       ext4_mb_free_metadata() updates in-memory buddy at each order
       If order N is now fully free: propagate up to order N+1
  5. If trim/discard is enabled (mount -o discard):
       Immediately issue blkdev_issue_discard() for freed blocks
       This hints to SSD FTL that blocks are no longer in use
     If discard not enabled: blocks remain in buddy; no trim

Journal interaction on free:
  Free operations are journaled: block bitmap change + BG descriptor change
  journaled atomically with the metadata operation that freed the blocks
  (e.g., unlink: inode delete + block free in same transaction)

PA interaction on free:
  If freed blocks overlap a PA window:
    PA is invalidated; remaining PA blocks also freed
    ext4_mb_discard_inode_preallocations() called on inode close or trim

Buddy update after free example:
  Free blocks 16, 17 (order 0 pair):
    buddy[0][16] = 1, buddy[0][17] = 1
    Both free → buddy[1][8] = 1  (pair 8 = blocks 16..17)
    Is buddy[1][9] also 1? (blocks 18..19 free?)
      If yes → buddy[2][4] = 1 (group of 4: blocks 16..19 all free)
      If no  → stop at order 1
  bb_largest_free_order updated if this is now the largest free run
```

### 4.7 bigalloc: Cluster-Based Allocation

The `bigalloc` feature changes mballoc's allocation granularity from 1 block to 1 cluster (multiple blocks), reducing metadata overhead for large files.

```
Without bigalloc:
  Allocation granularity: 4KB (1 block)
  Block bitmap: 1 bit per 4KB

With bigalloc (mkfs.ext4 -C 65536 → 64KB cluster = 16 blocks per cluster):
  Allocation granularity: 64KB (1 cluster)
  Cluster bitmap: 1 bit per 64KB
  Block bitmap size: 32768/16 = 2048 bits → fits in fraction of a block
  BG size grows proportionally: 32768 clusters × 64KB = 2GB per BG

Benefits:
  - Reduced bitmap I/O (bitmap is smaller)
  - Better for very large files (each extent covers more bytes per entry)
  - Metadata overhead (per-extent journaling) amortized over larger allocation units

Costs:
  - Internal fragmentation: a 1KB file wastes 63KB of physical space
  - NOT suitable for small-file workloads
  - mkfs.ext4 -C <cluster_size_in_bytes>  (must be power of 2, ≥ block size)

Real use: rarely used in practice. XFS AG allocation naturally achieves similar
  contiguity without fixed cluster overhead.
```

### 4.8 mballoc Observability and Tuning

```bash
# Per-BG free block distribution (shows fragmentation)
cat /sys/fs/ext4/sda1/mb_groups
# Format: group [N]: free blocks [M], fragments [F], first free [B], largest free order [O]
# Large F with small O → fragmented BG (many small runs, no large ones)

# Allocation stats since mount
cat /sys/fs/ext4/sda1/stats
# Key lines:
#   reqs: N         — total allocation requests
#   cr0: N (X%)     — requests satisfied at criteria level 0 (best quality)
#   cr1: N (X%)     — satisfied at cr=1
#   cr2: N (X%)     — cr=2
#   cr3: N (X%)     — cr=3 (worst; high % indicates near-full or fragmented FS)
#   hits: N         — served from PA (preallocation hit rate)
#   groups_scanned  — how many BGs were examined per request on average

# Fragmentation report
e2freefrag /dev/sda1
# Shows histogram of free-space chunk sizes
# Healthy: most free space in large chunks (> 1MB)
# Fragmented: free space split into many small chunks (< 64KB)

# Enable/disable stats collection
echo 1 > /sys/fs/ext4/sda1/mb_stats

# Tune PA behavior
echo 32 > /sys/fs/ext4/sda1/mb_stream_req       # threshold for per-inode PA
echo 1024 > /sys/fs/ext4/sda1/mb_group_prealloc # LG PA window size (blocks)
echo 512 > /sys/fs/ext4/sda1/mb_max_inode_prealloc  # cap per-inode PA window

# Trim to reduce SSD fragmentation and reclaim over-reserved PA space
fstrim -v /mountpoint                           # one-shot trim
mount -o discard /dev/sda1 /mountpoint          # real-time discard on free

# Defragment individual files or directories
e4defrag /path/to/file                         # single file
e4defrag /mountpoint/                          # recursive directory
# e4defrag copies file data to a temporary location, then replaces the original
# Requires ~equal free space to the file being defragmented
```

### 4.9 Design Trade-offs: Why mballoc Is Good Enough but Not Great

```
mballoc strength: The PA system and delalloc together give good allocation quality
  for sequential and append workloads. A streaming write to a new file will
  typically get one or two large extents, matching HDD/SSD performance expectations.

mballoc weakness: The per-BG buddy structure means "contiguous allocation" is limited
  to within one BG (128MB at 4KB blocks). Cross-BG contiguity is not possible.
  XFS per-AG allocation can allocate larger contiguous runs within a 1GB AG.

mballoc weakness: The fixed block bitmap (one bit per block) means the allocator must
  scan/update bitmaps on every allocation, which becomes a bottleneck at high IOPS.
  XFS's B-tree free-space index (BNObt + CNTbt) is more cache-friendly for random
  small allocation patterns.

mballoc vs XFS comparison:
  Workload                   mballoc result    XFS mballoc equivalent
  Large sequential write     1 extent/128MB    1 extent/1GB
  Many small files            LG PA, BG-local  Per-AG LG equivalent
  Near-full FS random write  cr=3 (poor)       CNTbt search (better)
  Read-modify-write          Adequate          Similar
```

---

## Section 5: Directory Structure

### Three Directory Formats

```
1. Linear (small directories):
   - Directory data block = array of ext4_dir_entry_2 structs
   - Variable-length records, padded to 4-byte alignment
   - Search = linear scan (O(n))
   - Used when dir_index feature absent OR directory < 2 blocks

2. HTree (hash B-tree, `dir_index` feature):
   - Root block: dx_root struct (hash params, pointer to leaf level)
   - Leaf blocks: hash-sorted arrays of ext4_dir_entry_2
   - Search = O(log n) via hash tree
   - Default for new directories in modern ext4

3. Inline directory (inline_data feature):
   - Very small directories with ≤ 4 entries stored in inode i_block field
   - No separate directory data blocks at all
```

### `ext4_dir_entry_2` Structure

```c
struct ext4_dir_entry_2 {
    __le32  inode;       // inode number (0 = deleted/hole entry)
    __le16  rec_len;     // length of this entry including padding (always 4-byte aligned)
    __u8    name_len;    // length of name (not null-terminated)
    __u8    file_type;   // EXT4_FT_REG_FILE, EXT4_FT_DIR, EXT4_FT_SYMLINK, etc.
    char    name[];      // filename (not null-terminated)
};

// rec_len can be larger than actual entry: slack space reused for next entry
// Deletion: set inode=0, merge rec_len with previous entry's slack
// This means directory blocks are never compacted until explicit fsck
```

### HTree Root Block Layout

```c
// fs/ext4/dx.h
struct dx_root {
    struct fake_dirent dot;       // "." entry (inode = this dir)
    char dot_name[4];
    struct fake_dirent dotdot;    // ".." entry
    char dotdot_name[4];
    struct dx_root_info {
        __le32 reserved_zero;
        __u8   hash_version;      // DX_HASH_TEA, DX_HASH_HALF_MD4, DX_HASH_UNSIGNED
        __u8   info_length;       // = 8
        __u8   indirect_levels;   // tree depth (0=1 level, 1=2 levels)
        __u8   flags;
    } info;
    struct dx_entry {
        __le32  hash;
        __le32  block;            // directory block number of entries with hash >= this
    } entries[];                  // fills rest of root block
};
```

**Lookup path:**
1. Compute hash of target name using hash_version algorithm
2. Binary search `entries[]` in root block for largest hash ≤ target
3. Read the pointed leaf block; linear scan for exact name match

**Hash collision handling:** Multiple entries with same hash are stored sequentially in the leaf; scan continues until hash no longer matches.

---

## Section 6: Extended Attributes (xattr)

### Three Storage Locations

```
1. Inode body (extra space):
   - In the 256-byte inode, bytes after ext4_inode (offset 128 + i_extra_isize onward)
   - Available space: 256 - 128 - i_extra_isize bytes
   - Fastest access (no extra block read)

2. External xattr block:
   - One dedicated 4KB block per inode (referenced by i_file_acl_lo)
   - ext4_xattr_header at block start
   - Array of ext4_xattr_entry (name+value pairs)
   - Block-level deduplication: multiple inodes can share same xattr block (refcounted)

3. No xattr:
   - Inode i_file_acl_lo = 0 → no external block
```

### Xattr Block Sharing

```
Content-addressable xattr blocks:
  - When creating xattr, compute hash of all entries
  - Scan existing xattr blocks with matching hash
  - If found: share the block (increment reference count in ext4_xattr_header.h_refcount)
  - Creates implicit deduplication of identical xattr sets (common for SELinux labels)
```

---

## Section 7: Journal (JBD2) Architecture Summary

> Full detail in `day19-ext4-jbd2-recovery.md`. This section summarizes the architect-level design.

### Journal as a Circular Log

```
Journal device (or journal file within the filesystem):

  [Superblock block] [Descriptor] [Data...] [Commit] [Descriptor] [Data...] [Commit] ...
   j_sb_buffer        T1                     T1        T2                     T2

  j_head: next write position (producer)
  j_tail: oldest unclean transaction (consumer)
  journal wraps around: head chases tail

Invariant: j_head never overwrites uncommitted or uncheckpointed data
Journal full → writer blocks until checkpoint frees space
```

### Four Journal Object Types

```
JBD2 writes four types of blocks to the journal:

1. Descriptor block:
   - Lists which blocks follow (their on-disk addresses)
   - One descriptor per batch of data blocks

2. Data blocks:
   - The actual block contents being journaled
   - For metadata: block bitmap, inode, extent tree blocks
   - For data=journal: also data blocks

3. Commit block:
   - Single block; written last per transaction
   - Contains TID, magic, checksum
   - Its presence = transaction is complete and recoverable

4. Revoke block:
   - Lists block numbers that should NOT be replayed
   - Used when a block was journaled, then freed in a later transaction
   - Prevents replaying stale metadata images
```

### Why External Journal Wins on HDD

```
Internal journal (journal file inside the filesystem):
  - Journal writes and data writes compete for the same HDD seek queue
  - Commit → seek to journal → write → seek back to data → next data write
  - Each commit costs 2 seeks on HDD (~15ms × 2 = 30ms per commit)

External journal (separate device):
  - HDD head stays near data; journal writes go to NVMe/SSD
  - Journal I/O latency: μs not ms
  - Effective for write-heavy workloads on HDD storage
  - mkfs.ext4 -J device=/dev/nvme0n1p1 /dev/sda1
```

---

## Section 8: Block Group Strategy and Inode Allocation

### Inode Allocation Policy

```c
// fs/ext4/ialloc.c — ext4_new_inode()

Goal: place new inode in "good" BG

For directories (new subdir):
  - Orlov allocator (default): choose BG based on parent dir's BG,
    taking into account free inodes, free blocks, and directory count
  - Goal: sibling directories spread across BGs (better balance)
  - --vs-- old policy: always in parent's BG (leads to hot BGs)

For files (new file in directory):
  - Choose same BG as parent directory
  - Fallback: BG with most free inodes

Orlov heuristic:
  If (parent dir has used < avg inodes AND parent's BG has free blocks):
    allocate in parent's BG   ← keeps related files together
  Else:
    find BG with best balance of free_inodes, free_blocks, and low dir_count
    ← spreads load, avoids filling one BG
```

### flex_bg: Aggregating Block Groups

```
flex_bg feature (default since RHEL 6 era):
  Groups of N block groups (flex_bg size, power of 2) form one "flex group"
  All inode tables and bitmaps of the group are placed consecutively at the start

  Benefit:
    - Metadata (inode tables) reads are localized → fewer seeks
    - Large sequential writes see longer contiguous free block runs
    - mkfs.ext4 -G 16 sets flex_bg size (16 BGs per flex group)

Layout with flex_bg=4 (4 BGs per flex):
  BG0: SB | GDT | BB0 | BB1 | BB2 | BB3 | IB0 | IB1 | IB2 | IB3 | IT0 | IT1 | IT2 | IT3 | data...
  BG1: BB→BG0 area | IB→BG0 area | IT→BG0 area | data...
  (BG1-BG3 metadata packed into BG0's space)
```

---

## Section 9: Performance Profile

### Where ext4 Excels

| Scenario | Reason |
|----------|--------|
| Small to medium files (< 1MB) | mballoc LG prealloc keeps them compact; BG-local allocation |
| Mixed random read workloads | Fixed BG layout allows O(1) BG selection without tree traversal |
| fsync-heavy applications | JBD2 commit overhead is predictable; external journal on NVMe is effective |
| Databases with `data=writeback` | Skip ordered overhead; DB manages durability via O_DIRECT |
| Boot volumes, OS filesystems | Fast `uninit_bg` mkfs; ext4 is universally supported |
| Simple directory trees | HTree lookup is O(log n); adequate for most directory sizes |

### Where ext4 Struggles

| Scenario | Reason | Mitigation |
|----------|--------|------------|
| >16M files in one filesystem | Fixed inode ratio at mkfs (`-i` option); can't add inodes | `mkfs.ext4 -i 4096` for inode-dense workloads |
| Very large files (TB-scale sequential) | Extent tree is fine, but mballoc per-BG scan is slower than XFS AG search | Use XFS for large file workloads |
| Highly concurrent metadata (many parallel creates) | Single GDT structure, per-BG BG descriptor lock | XFS per-AG parallelism scales better |
| Directory with >10M entries | HTree depth limit; debugfs shows `dx_htree` depth maxed | Split directories; XFS scales better |
| Near-full filesystem (>95%) | mballoc cr=3 global search; allocation quality degrades | Keep < 90% full |
| Online shrink | Not supported (only grow: `resize2fs`) | Plan capacity in advance |
| Snapshot / subvolume | Not natively supported | Use LVM snapshots, or Btrfs |

### Latency Model

```
For a single fsync write (O_SYNC or fsync after write):

  write() path:
    page cache write: < 1μs
    JBD2 add to running transaction: ~1μs

  fsync() path:
    JBD2 commit (if not already committed):
      data=ordered: submit data I/O + wait → submit metadata → wait for commit block
      Storage latency dominates:
        NVMe: ~30-100μs
        SATA SSD: ~100-500μs
        HDD: ~10-20ms (seek + rotational)

  External journal on NVMe + data on HDD:
    metadata journal: ~100μs on NVMe
    data write (ordered): still needs HDD seek (~10-20ms)
    Net: external journal doesn't help fsync much when data is on HDD
    Best case: random write workload where data is on NVMe too
```

---

## Section 10: Key Failure Modes

### 1. Inode Exhaustion (ENOSPC with Free Blocks)

```
Symptom: df shows 40% used, but any create fails with ENOSPC
Cause: inode table full (fixed at mkfs time)

df -i /mount/point
Filesystem      Inodes  IUsed   IFree IUse% Mounted on
/dev/sda1      1048576 1048576      0  100% /data   ← all inodes consumed

Recovery:
  - Cannot add inodes to live ext4 filesystem
  - Options: delete files, or reformat with smaller -i ratio
  mkfs.ext4 -i 4096 /dev/sda1   # 1 inode per 4KB = 4× more inodes than default
  mkfs.ext4 -N 10000000 /dev/sda1  # explicit inode count

Detection in advance:
  watch -n 60 'df -i /data | tail -1'
  # Alert when IUse% > 80
```

### 2. Journal Corruption

```
Symptom: mount fails with "JBD2: no valid journal superblock found"
Cause: journal file corrupted (power loss during journal write without barrier)

e2fsck -f /dev/sda1       # try repair
# If journal unrecoverable:
tune2fs -O ^has_journal /dev/sda1   # remove journal (make ext2)
tune2fs -j /dev/sda1               # add new journal
# Or: mkfs.ext4 (data loss)

Prevention:
  - Use write barriers (default; don't use -o barrier=0)
  - Use battery-backed RAID controller or NVMe (power-loss protected flash)
```

### 3. Fragmentation Degradation

```
Symptom: sequential read throughput drops over time on HDD

Measure:
  e4defrag -c /data/largefile     # check fragmentation score
  filefrag -v /data/largefile     # show extent list (many extents = fragmented)

  # Filesystem-wide extent count
  tune2fs -l /dev/sda1 | grep -i "free blocks"
  e2freefrag /dev/sda1            # free space fragmentation report

Fix:
  e4defrag /data/largefile        # defrag single file (online)
  e4defrag /data/                 # defrag directory tree
  # Note: e4defrag moves data to temporary file then renames → needs free space

Prevention:
  - Keep filesystem < 85% full (mballoc needs contiguous free space)
  - Use -E stride,stripe_width at mkfs for RAID alignment
  - Tune mb_stream_req and mb_group_prealloc for workload
```

### 4. Block Bitmap / GDT Inconsistency

```
Symptom: e2fsck reports "block X in use but bitmap says free"
Cause: crash between block allocation (bitmap write) and journal commit

e2fsck -fp /dev/sda1   # auto-repair
# -f: force check even if clean flag set
# -p: auto preen (fix obvious errors non-interactively)

Recovery philosophy:
  JBD2 recovery replays journaled transactions → should be consistent.
  If not: journal itself is corrupt (see above), or metadata outside journal was modified
  (shouldn't happen in normal operation — indicates kernel bug or storage fault).
```

### 5. Directory Index Corruption

```
Symptom: ls on large directory hangs or returns EUCLEAN
Cause: HTree B-tree corrupted

e2fsck -D /dev/sda1   # rebuild directory indices

Temporary workaround (mount without dir_index):
  tune2fs -O ^dir_index /dev/sda1
  e2fsck -f /dev/sda1            # converts htree dirs to linear
  mount /dev/sda1 /mnt           # now accessible
  tune2fs -O dir_index /dev/sda1 # re-enable for new dirs
```

---

## Section 11: Production mkfs.ext4 Parameters

### General-Purpose (4K blocks, NVMe)

```bash
mkfs.ext4 \
  -b 4096 \                     # block size (4K optimal for most workloads)
  -i 16384 \                    # 1 inode per 16KB = default; reduce for small-file workloads
  -E lazy_itable_init=0,\       # initialize inode tables at mkfs (not lazy in background)
     lazy_journal_init=0 \      # initialize journal now (safer for production)
  -m 1 \                        # reserve 1% for root (reduce from default 5% on large volumes)
  -J size=1024 \                # 1GB journal (for high-write workloads)
  -L data \                     # filesystem label
  /dev/nvme0n1p1
```

### Small-File / Container Workload

```bash
mkfs.ext4 \
  -b 4096 \
  -i 4096 \                     # 1 inode per 4KB = 4× denser inode table
  -N 0 \                        # auto-calculate from -i ratio
  -E lazy_itable_init=0,\
     lazy_journal_init=0,\
     num_backup_sb=1 \          # only 1 extra SB copy (saves space)
  -O inline_data \              # enable inline data (files ≤ 60 bytes stored in inode)
  -m 2 \
  /dev/sda1
```

### RAID-Aligned (RAID6 with 256KB stripe, 6 data disks)

```bash
# RAID6: 6 data + 2 parity, 256KB chunk per disk
# Stripe width = 6 * 256KB = 1536KB; stride = 256KB / 4KB = 64 blocks

mkfs.ext4 \
  -b 4096 \
  -E stride=64,\                # chunk_size / block_size = 256KB / 4KB = 64
     stripe_width=384,\         # stride * data_disks = 64 * 6 = 384
     lazy_itable_init=0,\
     lazy_journal_init=0 \
  -m 1 \
  /dev/md0

# With stride/stripe_width:
#   mballoc aligns block group allocation to RAID stripe boundaries
#   Avoids partial stripe writes (read-modify-write) on RAID5/6
```

### External Journal

```bash
# Create journal device (use small NVMe partition)
mke2fs -O journal_dev -b 4096 /dev/nvme0n1p1

# Create filesystem pointing to external journal
mkfs.ext4 \
  -J device=/dev/nvme0n1p1 \   # journal on fast device
  -b 4096 \
  -m 1 \
  /dev/sda1

# Mount (kernel auto-detects external journal via superblock pointer)
mount /dev/sda1 /data
```

---

## Section 12: Key Tuning Parameters

### Mount Options

```bash
# Production database (O_DIRECT, manages own durability)
mount -o data=writeback,noatime,nodiratime,errors=remount-ro /dev/sda1 /dbdata

# General application server
mount -o data=ordered,noatime,commit=5,errors=remount-ro /dev/sda1 /data

# High-durability (critical config / low-throughput)
mount -o data=journal,noatime,errors=panic /dev/sda1 /critical

# Important options:
#   noatime       — skip atime updates on reads (eliminates gratuitous writes)
#   nodiratime    — skip diratime only
#   commit=N      — background journal commit interval (seconds); default 5
#   errors=X      — continue | remount-ro | panic
#   barrier=0     — disable write barrier (risky; only for battery-backed storage)
#   delalloc      — enabled by default; improves allocation quality
#   nodelalloc    — disable for databases that manage fsync (eliminates late ENOSPC)
```

### Runtime Tuning via /sys

```bash
# mballoc tuning
echo 64 > /sys/fs/ext4/sda1/mb_stream_req      # per-inode PA threshold (blocks)
echo 2048 > /sys/fs/ext4/sda1/mb_group_prealloc # LG prealloc size (blocks)

# Check current stats
cat /sys/fs/ext4/sda1/mb_groups       # per-BG free block histogram
cat /sys/fs/ext4/sda1/stats           # mballoc allocation stats

# JBD2 stats
cat /proc/fs/jbd2/sda1-8/info         # commit count, timing histogram
```

### tune2fs Post-Format Adjustments

```bash
tune2fs -l /dev/sda1                          # show all parameters
tune2fs -m 1 /dev/sda1                        # reduce reserved space to 1%
tune2fs -c 0 -i 0 /dev/sda1                  # disable periodic fsck (use cron instead)
tune2fs -e remount-ro /dev/sda1              # error behavior: remount read-only
tune2fs -E max_mount_count=0 /dev/sda1       # disable mount-count-based fsck
tune2fs -J size=1024 /dev/sda1              # resize journal (offline + e2fsck first)
tune2fs -O extents,uninit_bg,dir_index /dev/sda1  # enable features on old FS (offline)
```

---

## Section 13: Source Code Map

```
fs/ext4/
  super.c          — mount, unmount, fill_super(); SB read and validation
  ialloc.c         — ext4_new_inode(); Orlov allocator
  balloc.c         — block bitmap manipulation; ext4_new_blocks_credits()
  mballoc.c        — multi-block allocator; buddy system; prealloc; ext4_mb_new_blocks()
  extents.c        — extent tree walk, insert, split; ext4_ext_map_blocks()
  inode.c          — ext4_writepages(); delalloc: ext4_da_write_begin()
  namei.c          — directory operations; htree lookup: ext4_find_entry()
  dir.c            — readdir; linear directory scan
  dx.c             — HTree operations; dx_probe(), dx_make_map()
  file.c           — file_operations; io_uring path; direct I/O
  xattr.c          — xattr read/write; xattr block sharing
  acl.c            — POSIX ACL implementation (uses xattr)

fs/jbd2/
  transaction.c    — jbd2_journal_start/stop; transaction state machine
  commit.c         — jbd2_journal_commit_transaction(); 6-phase commit
  recovery.c       — jbd2_journal_recover(); SCAN/REVOKE/REPLAY passes
  checkpoint.c     — __jbd2_journal_clean_checkpoint_list()
  journal.c        — journal lifecycle; log space accounting (grant heads)
  revoke.c         — revoke table management

include/linux/
  ext4_fs.h        — on-disk structures (ext4_super_block, ext4_group_desc, ext4_inode)
  ext4_extents.h   — ext4_extent, ext4_extent_idx, ext4_extent_header
  jbd2.h           — jbd2 public API; T_RUNNING/T_COMMIT/... states
```

---

## Section 14: ext4 vs XFS Quick Comparison

> Full comparison in `xfs-architect-reference.md` Section 14.

| Dimension | ext4 | XFS |
|-----------|------|-----|
| Allocation unit | Block Group (128MB fixed) | Allocation Group (tunable, default 1GB) |
| Free space structure | Per-BG buddy bitmap (mballoc) | Per-AG B-trees (BNObt + CNTbt) |
| Inode allocation | Fixed at mkfs (`-i` ratio) | Dynamic; inode chunks allocated on demand |
| Extent tree | Per-inode B-tree (extent tree) | Per-inode B-tree (BMBT, same concept) |
| Directory index | HTree (hash B-tree) | HTree (same concept, different impl) |
| Journal | JBD2 (block-level, separate layer) | Internal (byte-range, integrated) |
| Journal recovery | 3-pass (scan/revoke/replay) | 5-phase (with intent/done pairs) |
| Online repair | e2fsck offline only | xfs_scrub online (with RMAP) |
| Reflink / CoW | Not supported (native) | Yes (v5, RMAPbt + REFCNTbt) |
| Snapshot | No | No (use LVM or Btrfs) |
| Online grow | Yes (resize2fs) | Yes (xfs_growfs) |
| Online shrink | No | No |
| Max file size | 16TB (4K blocks) | 8EB |
| Max FS size | 1EB (64bit feature) | 8EB |
| Universality | Default on Debian/Ubuntu; broadest tool support | Default on RHEL; better for enterprise scale |

**Choose ext4 when:** broad compatibility, fsync-heavy small-file workloads, boot volumes, container environments, or when XFS features (RMAP, reflink) are not needed.

**Choose XFS when:** large files, high directory entry counts, many parallel writers, online repair requirements, or reflink/CoW storage efficiency.

---

## Quick Reference

```
On-disk layout:
  SB (offset 1024) → GDT → Reserved GDT → BB → IB → IT → Data (per BG)
  flex_bg: packs N BGs' metadata contiguously

Inode:
  256 bytes; i_block[15] = extent tree root OR old indirect pointers
  EXT4_EXTENTS_FL (0x80000) in i_flags → uses extent tree

Extent tree:
  ext4_extent_header (12B) + entries in each node
  Depth 0: leaf (ext4_extent); depth >0: internal (ext4_extent_idx)
  ee_len bit 15: unwritten extents (pre-allocated, not initialized)

Allocation:
  mballoc buddy per BG; per-inode PA for sequential; LG PA for small
  delalloc: physical block assigned at writeback, not at write()

Directory:
  Small: linear ext4_dir_entry_2 array
  Large: HTree hash B-tree (dx_root → dx_entry → leaf blocks)

Journal (JBD2):
  Modes: writeback / ordered (default) / journal
  Commit: 6 phases; atomicity via single commit block sector write
  Recovery: 3 passes SCAN → REVOKE → REPLAY (idempotent)

Key failure modes:
  Inode exhaustion: df -i; fixed at mkfs time
  Journal corruption: e2fsck + tune2fs -O ^has_journal → -j
  Fragmentation: e4defrag; keep < 85% full

Diagnostics:
  debugfs /dev/sda1 -R "stat <2>"    # root inode
  debugfs /dev/sda1 -R "dump_extents /path/to/file"
  e2freefrag /dev/sda1               # free space fragmentation
  cat /proc/fs/jbd2/sda1-8/info     # journal commit stats
  cat /sys/fs/ext4/sda1/stats       # mballoc stats
```
