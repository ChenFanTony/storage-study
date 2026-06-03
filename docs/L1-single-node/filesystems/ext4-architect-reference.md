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

The extent tree replaced the old block map in ext4. It maps file logical blocks to physical blocks using a balanced tree of variable-length extents.

### Data Structures

```c
// include/linux/ext4_extents.h

struct ext4_extent_header {
    __le16  eh_magic;      // 0xF30A — magic number for validation
    __le16  eh_entries;    // valid entries in this node
    __le16  eh_max;        // max entries capacity of this node
    __le16  eh_depth;      // depth of tree (0 = leaf node)
    __le32  eh_generation; // for external tools; kernel ignores
};

struct ext4_extent_idx {   // internal node entry
    __le32  ei_block;      // logical block covered by this subtree
    __le32  ei_leaf_lo;    // physical block of child node (low 32 bits)
    __le16  ei_leaf_hi;    // physical block (high 16 bits)
    __u16   ei_unused;
};

struct ext4_extent {       // leaf node entry
    __le32  ee_block;      // first logical block of this extent
    __le16  ee_len;        // blocks in extent:
                           //   bit 15 = 0 → initialized (ee_len = actual count, 1..32767)
                           //   bit 15 = 1 → unwritten (ee_len & 0x7FFF = count)
    __le16  ee_start_hi;   // physical start block (high 16 bits)
    __le32  ee_start_lo;   // physical start block (low 32 bits)
};
```

### Extent Tree Walk Example

```
File has 5 extents → root holds all 4? no, 4 max at root.
5th extent forces depth-1 tree:

inode i_block (60 bytes):
  ext4_extent_header: magic=0xF30A, entries=2, max=3, depth=1
  ext4_extent_idx[0]: ei_block=0,     ei_leaf_lo=12345  → leaf block 12345
  ext4_extent_idx[1]: ei_block=50000, ei_leaf_lo=12346  → leaf block 12346

leaf block 12345 (4096 bytes):
  ext4_extent_header: magic=0xF30A, entries=3, max=340, depth=0
  ext4_extent[0]: ee_block=0,     ee_len=10000, ee_start=100000  → LBA 100000..109999
  ext4_extent[1]: ee_block=10000, ee_len=5000,  ee_start=200000  → LBA 200000..204999
  ext4_extent[2]: ee_block=15000, ee_len=25000, ee_start=300000  → LBA 300000..324999  ← unwritten if bit15 set

leaf block 12346 (4096 bytes):
  ext4_extent_header: entries=2, depth=0
  ext4_extent[0]: ee_block=50000, ee_len=8000,  ee_start=400000
  ext4_extent[1]: ee_block=58000, ee_len=12000, ee_start=500000
```

**Capacity per leaf block:** `(4096 - 12) / 12 = 340` extents per leaf node.

**Maximum extent tree depth:** 5 levels (rarely needed; 4 levels handles >1PB files).

### Unwritten Extents and Initialization

```
fallocate(fd, FALLOC_FL_KEEP_SIZE, 0, 1GB):
  → mballoc allocates 1GB of blocks
  → creates extents with ee_len bit 15 set (unwritten)
  → blocks appear allocated in block bitmap
  → reading returns zeros (kernel synthesizes)
  → writing initializes: clears bit 15, writes data, updates journal

Purpose:
  - Guarantee space reservation before writing (no ENOSPC mid-write)
  - Avoid stale data exposure (unlike writeback without zeroing)
  - Database files: preallocate full size at creation
```

---

## Section 4: Multi-Block Allocator (mballoc)

The multi-block allocator (`fs/ext4/mballoc.c`) is ext4's block allocation engine. It replaced the serial one-block-at-a-time allocator from ext3.

### Buddy Allocator Structure

```
Per-BG buddy system (in memory, loaded from block bitmap):

  Order 0: individual blocks     (4KB each)
  Order 1: pairs                 (8KB each)
  Order 2: groups of 4           (16KB each)
  ...
  Order 13: groups of 8192       (32MB — full BG at 4KB blocks)

Buddy bitmaps mirror the block bitmap but at each order.
Allocation: find smallest order ≥ requested size with a free run.
```

### Pre-Allocation (PA) System

```
Two PA types:

1. Per-inode PA (for sequential write workloads):
   - mballoc reserves a window of blocks for a specific inode
   - Subsequent allocations for that inode are served from the window
   - Window size doubles with each sequential write (up to mb_stream_req blocks)
   - Discarded on inode close or when inode stops writing

2. Locality Group PA (for small file / metadata workloads):
   - Per-CPU pool of pre-allocated blocks
   - Small allocations (< mb_stream_req) served from LG pool
   - Keeps small files in same BG → better locality

Key tunables:
  /sys/fs/ext4/<dev>/mb_stream_req    # min size for per-inode PA (default: 16 blocks = 64KB)
  /sys/fs/ext4/<dev>/mb_group_prealloc # LG PA window size (default: 512 blocks = 2MB)
  /sys/fs/ext4/<dev>/mb_max_inode_prealloc # per-inode PA cap
```

### mballoc Allocation Goal: Locality

```
For each allocation, mballoc tries in order:
  1. Per-inode PA window (if exists and has space)
  2. Locality group PA (if small allocation)
  3. Best-fit search in goal BG (BG where inode lives or was recently active)
  4. Expand search to nearby BGs
  5. Any BG with enough free space

"cr" (criteria) levels in mb_find_extent():
  cr=0: exact hit in goal BG, large contiguous run
  cr=1: good hit in goal BG
  cr=2: any hit in goal BG
  cr=3: any hit in any BG
```

### Delayed Allocation (`delalloc`)

```
Write path with delalloc:
  1. write() → data goes to page cache
  2. Kernel assigns a LOGICAL block (fake block number 0) — no physical block yet
  3. writeback (pdflush/work queue) fires:
     a. ext4_writepages() → mballoc allocates physical blocks
     b. Assigns real block numbers, updates extent tree
     c. Submits bio with real physical addresses

Benefits:
  - mballoc sees the full write before allocating → can give contiguous extents
  - Eliminates allocation of blocks that are overwritten before writeback (write coalescing)
  - Reduces write amplification for temporary files (never written to disk)

Risk:
  - ENOSPC can appear late (at writeback time, not at write() time)
  - Fix: reserve 5% of blocks (r_blocks_count) for root; tune2fs -m 5 /dev/sdX
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
