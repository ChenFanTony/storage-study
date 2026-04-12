# Month 3 Week 1: Storage Engine Internals (Days 1–7)

---

# Day 1: B-tree — Structure, Split & Merge

## Learning Objectives
- Understand B-tree page structure and the half-full invariant
- Follow insert with split and delete with merge/rotate
- Know fill factor and its effect on space vs update performance
- Know which databases use B-trees and why

---

## 1. B-tree Structure

```
B-tree (and B+ tree, used by databases) properties:
  - All data in leaf nodes (B+ tree)
  - Internal nodes: keys + child pointers only
  - All leaves at same depth (balanced)
  - Each node: between ⌈order/2⌉ and order keys (half-full invariant)
  - Leaves linked in a doubly-linked list (for range scans)

Node layout on disk (typical 4KB or 8KB page):
  ┌──────────────────────────────────────────────┐
  │ Header: flags, num_keys, free_space_offset   │
  │ Key array: [k1, k2, k3, ..., kN]            │
  │ Pointer array: [p0, p1, p2, ..., pN]         │
  │  (for leaf: value offsets or inline values)  │
  │ Free space                                    │
  │ Values (variable length, packed from end)    │
  └──────────────────────────────────────────────┘

Page types:
  Root page: top of tree (may be leaf if tree is small)
  Internal page: keys + child page IDs
  Leaf page: keys + values (or key + pointer to value heap)
```

---

## 2. Insert and Split

```
Insert key K into node N:
  1. Find correct leaf via binary search down tree
  2. If leaf has space: insert K in sorted position, done
  3. If leaf is full: SPLIT
     a. Create new leaf N'
     b. Move upper half of keys to N'
     c. Promote median key to parent
     d. If parent is full: recursively split parent
     e. If root splits: new root is created (tree grows taller)

Split example (order=4, max 3 keys per node):
  Before: [10, 20, 30] ← full
  Insert 25:
    Split: [10, 20] | [25, 30]
    Promote 25 to parent
  After: parent gets key 25, two children [10,20] and [25,30]

Cost of split:
  - One page read (original)
  - Two page writes (two halves)
  - One parent write (updated with promoted key)
  - Cascading splits rare (amortized O(1) per insert)
```

---

## 3. Delete and Merge/Rotate

```
Delete key K from leaf L:
  1. Remove K from L
  2. If L still has ≥ ⌈order/2⌉ keys: done
  3. If L has too few keys (underflow):
     a. Try to BORROW from sibling (rotate):
        - Right sibling has extra keys: take smallest key, update parent separator
        - Left sibling has extra keys: take largest key, update parent separator
     b. If no sibling has extra: MERGE
        - Merge L with a sibling
        - Remove separator key from parent
        - If parent now underflows: recurse up

Merge example:
  Parent: [20]  Children: [10,15] | [25]
  Delete 25 → [25] underflows
  Left sibling [10,15] has no extra keys (already at minimum)
  Merge: [10, 15, 20] (bring down parent separator 20)
  Parent key 20 removed → if parent now underflows, recurse

Performance implication:
  Deletes are more expensive than inserts (potential cascading merges)
  Many databases delay merges: keep underflowing pages temporarily
  Vacuum/compaction later reclaims space (PostgreSQL VACUUM, SQLite VACUUM)
```

---

## 4. Fill Factor and Its Tradeoffs

```
Fill factor: target occupancy percentage when writing new pages
  fill_factor=100%: pack pages fully on initial write
    + Maximum space efficiency
    - Every insert causes immediate split (no free space)
    - Worst update performance after initial load

  fill_factor=70% (PostgreSQL default):
    + Leaves room for subsequent inserts without splitting
    + Better update performance
    - More space overhead (~30% wasted initially)

  fill_factor=50%:
    + Optimized for heavy update workloads (lots of room)
    - Very low space efficiency

Setting fill factor:
  PostgreSQL: CREATE INDEX ... WITH (fillfactor = 70);
  SQLite: compile-time setting
  InnoDB: innodb_fill_factor (per-table)

Rule of thumb:
  Read-heavy, insert-once: fill_factor=90-100%
  Mixed read/write: fill_factor=70-80%
  Heavy random updates to existing keys: fill_factor=50-70%
```

---

## 5. B-tree in Production Systems

```
Who uses B-trees and why:
  PostgreSQL: B-tree for all default indexes (GIN/GiST for special types)
  MySQL InnoDB: clustered B-tree (data IS the index, sorted by primary key)
  SQLite: B-tree for both tables and indexes
  RocksDB metadata: B-tree for block index within SSTable files
  LMDB: append-only B-tree with CoW (no in-place update, like Btrfs)

Why B-tree dominates OLTP:
  ✓ O(log N) point lookup (predictable)
  ✓ O(log N + k) range scan (k = result size)
  ✓ Good update performance (in-place update)
  ✓ Page cache friendly (fixed-size pages)
  ✗ Random writes (each update = random page write)
  ✗ Write amplification: every random write = full page rewrite (4-16KB for 8 bytes changed)

B-tree write amplification:
  B-tree WA = page_size / record_size
  For 8KB pages, 8-byte keys: WA = 1024× (disk write >> data written)
  Mitigation: write-ahead log (WAL) makes writes sequential at journal level
```

---

## 6. Hands-On: SQLite B-tree Inspection

```bash
# Create a SQLite database and inspect its B-tree structure
sqlite3 /tmp/btree_test.db << 'EOF'
CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT);
INSERT INTO test SELECT i, 'value_' || i FROM generate_series(1, 10000);
EOF

# Inspect page count and tree structure
sqlite3 /tmp/btree_test.db << 'EOF'
PRAGMA page_count;
PRAGMA page_size;
PRAGMA freelist_count;
SELECT name, rootpage FROM sqlite_master WHERE type='table';
EOF

# Use sqlite_analyzer (if installed) for detailed B-tree stats
sqlite3_analyzer /tmp/btree_test.db 2>/dev/null | grep -A5 "test"

# Visual B-tree with btree utility (install: pip install sqlite-utils)
python3 -c "
import sqlite3
conn = sqlite3.connect('/tmp/btree_test.db')
# Count pages at each level
cur = conn.execute('PRAGMA integrity_check')
print(cur.fetchone())
conn.close()
"

# Observe split behavior: insert until page splits
# Watch page_count increase as tree grows
for i in $(seq 1 5); do
    sqlite3 /tmp/btree_test.db "INSERT INTO test SELECT i, 'v'||i FROM generate_series(${i}0001, ${i}1000);"
    sqlite3 /tmp/btree_test.db "PRAGMA page_count;" | xargs echo "Pages after ${i}0K records:"
done
```

---

## 7. Self-Check

1. A B+ tree has order 100 (max 100 keys per node). A leaf splits. How many disk writes does the split require in the best case?
2. Why do databases use fill factor < 100%? What workload makes fill factor most important?
3. B-tree write amplification: for 8KB pages and 100-byte records, what is the WA for a random point update?
4. PostgreSQL uses WAL + B-tree. Where does WAL reduce B-tree's write amplification?

## 8. Answers

1. Best case (parent has room): read original leaf → write two new half-full leaves → write updated parent = 3 writes. Plus the original page read. If parent also splits: add 2 more writes (split parent) + 1 parent of parent update = potentially 5-7 writes. Average: 3-4 writes per insert.
2. Fill factor < 100% leaves room for future inserts without splitting. Most important for: tables with heavy random inserts/updates after initial load (OLTP hot tables). Least important for: read-mostly tables, bulk-loaded append-only tables.
3. WA = page_size / record_size = 8192 / 100 = 82×. One 100-byte record update → must rewrite entire 8KB page containing it.
4. WAL makes random writes sequential at the journal level. Instead of immediately writing the modified 8KB page (random write to data file), PostgreSQL first writes a small WAL record (~100 bytes) sequentially to WAL file. The modified page is written lazily during checkpoint (buffered, potentially merged with other dirty pages). This converts random page writes to sequential WAL writes, dramatically improving write throughput on HDD/NVMe.

---

# Day 2: LSM-tree — MemTable, SSTables & Compaction

## Learning Objectives
- Understand the LSM-tree write path from MemTable to on-disk SSTables
- Understand SSTable format: data blocks, index block, bloom filter
- Understand two compaction strategies: size-tiered and leveled
- Trace a read through multiple levels

---

## 1. LSM-tree Write Path

```
Write "key=foo, value=bar":

1. Write to WAL (Write-Ahead Log):
   Sequential append to WAL file → crash recovery
   WAL write is durable (fsync or group commit)

2. Write to MemTable (in-memory sorted structure):
   Usually a skip list or red-black tree
   Keeps keys sorted → efficient range scans
   Size: typically 64MB-256MB

3. When MemTable full → flush to disk as L0 SSTable:
   Write sorted key-value pairs to new SSTable file
   Write index block (sample of keys → byte offsets)
   Write bloom filter (probabilistic membership test)
   Immutable after writing (never modified)

4. Compaction (background):
   Merge multiple SSTables → produce new, sorted SSTables
   Remove deleted keys (tombstones) after all levels processed
   Remove overwritten versions (keep only latest)

Crash recovery:
  WAL present → replay WAL to rebuild MemTable
  WAL replayed → discard WAL, normal operation
```

---

## 2. SSTable Format

```
SSTable file layout:
┌─────────────────────────────────────────┐
│ Data Blocks (sorted key-value pairs)    │
│   Block 0: keys A..D, values            │
│   Block 1: keys E..H, values            │
│   ...                                   │
│   Block N: keys X..Z, values            │
├─────────────────────────────────────────┤
│ Index Block                             │
│   "A" → offset 0                       │
│   "E" → offset 4096                    │
│   "X" → offset N*4096                  │
├─────────────────────────────────────────┤
│ Bloom Filter                            │
│   (probabilistic: is key in this file?) │
├─────────────────────────────────────────┤
│ Footer (offsets to index + bloom)       │
└─────────────────────────────────────────┘

Point read of key K:
  1. Check bloom filter: if "not present" → skip file (O(1), fast)
  2. Binary search index block → find data block containing K
  3. Read data block → binary search for K
  Total: 1-2 I/Os per SSTable file (vs 1 for B-tree hot path)

Range scan of keys [K1, K2]:
  1. Find start position in each SSTable (via index)
  2. Merge-scan all SSTables in range (sorted merge)
  LSM-tree: range scan touches ALL levels → more I/Os than B-tree range scan
```

---

## 3. Compaction Strategies

### Size-Tiered Compaction (Cassandra default, RocksDB universal)

```
Principle: when enough same-size SSTables accumulate → merge them

Tiers: [small] [small] [small] [small] → merge → [medium]
       [medium] [medium] [medium] → merge → [large]

Pros:
  + Write amplification is low (~10× total)
  + Simple: just merge same-tier files
Cons:
  - Space amplification: temporarily need 2× space during compaction
  - Read amplification: many files at each tier → more files to check per read

Use: write-heavy workloads where read latency is less critical
```

### Leveled Compaction (LevelDB default, RocksDB default)

```
Principle: each level has size limit; L_i can be at most 10× L_{i-1}

L0: freshly flushed SSTables (unsorted relative to each other, limit 4 files)
L1: 10MB total (sorted, non-overlapping key ranges)
L2: 100MB total
L3: 1GB total
L4: 10GB total
...

Compaction trigger: L_i exceeds size limit →
  Pick one SSTable from L_i
  Find overlapping SSTables in L_{i+1}
  Merge → write new SSTables to L_{i+1}
  Delete old SSTables from L_i and L_{i+1}

Pros:
  + Low read amplification: 1 file per level (non-overlapping in L1+)
  + Low space amplification: ~10× tighter than size-tiered
Cons:
  - Higher write amplification (~30× total vs ~10× size-tiered)
  - CPU-intensive (constant compaction activity)

Use: read-heavy workloads, mixed read/write
```

---

## 4. Read Path Through Multiple Levels

```
Read key K in RocksDB (leveled compaction):

1. Check MemTable (skip list): O(log N) — in-memory
2. Check immutable MemTable(s) (being flushed): O(log N)
3. Check L0 SSTables (may overlap): check ALL L0 files
   - Bloom filter eliminates most (false positive rate ~1%)
   - Typically 0-4 L0 files → 0-4 bloom filter checks
4. Check L1: exactly 1 SSTable can contain K (non-overlapping)
   - Binary search on file index → 1 file → bloom → 1 I/O max
5. Repeat for L2, L3, ... until found or all levels checked

Read amplification (worst case): O(levels) = ~7 I/Os for 7-level RocksDB
Read amplification (average with bloom filters): ~2-3 I/Os (bloom eliminates most)

Compare to B-tree: O(log N) = ~3-4 I/Os → similar in practice for warm cache
```

---

## 5. Hands-On: RocksDB Exploration

```bash
# Install RocksDB tools
apt install rocksdb-tools 2>/dev/null || \
  git clone https://github.com/facebook/rocksdb && cd rocksdb && make -j4 tools

# Create a test database and inspect SSTable structure
# Using python-rocksdb or the ldb tool

# ldb: RocksDB command-line tool
ldb --db=/tmp/testdb put key1 value1
ldb --db=/tmp/testdb put key2 value2
ldb --db=/tmp/testdb get key1

# Inspect SSTable files
ldb --db=/tmp/testdb manifest_dump
# Shows: version, level files, compaction information

# Dump SSTable content
ldb --db=/tmp/testdb dump --compression_type=no
# Shows: key-value pairs sorted

# Check compaction stats
ldb --db=/tmp/testdb stats
# Shows: level sizes, compaction I/O, read/write amplification estimates

# Alternative: python-rocksdb
pip install python-rocksdb --quiet
python3 << 'EOF'
import rocksdb

# Open with stats enabled
opts = rocksdb.Options()
opts.create_if_missing = True
opts.max_write_buffer_size = 64 * 1024 * 1024  # 64MB MemTable
opts.level0_file_num_compaction_trigger = 4

db = rocksdb.DB("/tmp/pyrocksdb", opts)

# Write 100K keys
for i in range(100000):
    db.put(f"key{i:08d}".encode(), f"value{i}".encode())

# Get stats
print(db.get_property(b"rocksdb.stats").decode())
print(db.get_property(b"rocksdb.num-files-at-level0").decode())
print(db.get_property(b"rocksdb.num-files-at-level1").decode())
EOF
```

---

## 6. Self-Check

1. A MemTable holds 256MB before flushing. The WAL is 256MB. On crash, what is the maximum data recovered, and what's potentially lost?
2. Why does a point read check L0 SSTables differently from L1+ SSTables?
3. Size-tiered compaction has lower WA than leveled. Why do most production systems default to leveled?
4. A key is deleted in RocksDB. When is the storage reclaimed?

## 7. Answers

1. All data in the MemTable (256MB) was first written to WAL. On crash: WAL replayed → MemTable reconstructed → 0 data loss (for WAL-synced writes). Data NOT in WAL (acknowledged before WAL sync) could be lost — but this only happens if `sync=false` (async WAL). With sync WAL: no data loss possible.
2. L0 SSTables may overlap in key ranges (they're flushed from MemTable independently without regard to existing L0 files). Must check ALL L0 files for a key. L1+ SSTables are non-overlapping within a level (compaction ensures this). For L1+: binary search finds exactly which one file could contain K → check only that one file.
3. Leveled compaction has lower read amplification: at each level, exactly one file can contain a key (non-overlapping). Size-tiered has many files per tier, all potentially containing the same key range → must check more files per read. For most production workloads with mixed reads and writes, lower read amplification (faster reads) outweighs the higher WA cost.
4. Delete writes a "tombstone" record for the key. Storage is reclaimed only when compaction processes the tombstone down to the lowest level (where it's certain no older version exists below). This can be delayed: a tombstone at L3 reclaims storage only when compacted through L4, L5, etc. Full reclamation may take hours or days on a heavily loaded system.

---

# Day 3: B-tree vs LSM-tree — The Amplification Tradeoffs

## Learning Objectives
- Precisely quantify Read, Write, and Space amplification for both structures
- Know the "Dostoevsky" framework for tuning LSM-trees
- Know WiscKey's insight: separating keys from values
- Build a decision framework for any workload

---

## 1. The Three Amplification Factors

```
Read Amplification (RA):
  Number of I/Os required per point lookup
  
  B-tree: O(log_B N) where B = branching factor
    For 1TB, 8KB pages, 16-byte keys: B=500, N=1B keys
    RA = log_500(1B) ≈ 3.5 → ~4 I/Os
    (often 1-2 with page cache warming)
  
  LSM-tree (leveled): O(levels × bloom_fp_rate) amortized
    7 levels, 1% bloom FP rate: RA ≈ 7 × 0.01 × I/Os + root reads
    In practice: 2-4 I/Os for point read (bloom filters very effective)

Write Amplification (WA):
  Bytes written to storage / bytes written by application
  
  B-tree: page_size / record_size for random writes
    8KB page, 64-byte record: WA = 128× per update (must rewrite full page)
    Mitigated by: WAL (journal absorbs random writes as sequential)
    With WAL: WA ≈ 2× (WAL + page)... but then checkpoint rewrites page anyway
  
  LSM-tree (leveled): proportional to L × (L_i_size / L_{i-1}_size)
    L levels, ratio 10: WA ≈ L × 10 / 2 ≈ 30× for 7 levels
    Size-tiered: WA ≈ 10× (fewer compaction passes)
  
Space Amplification (SA):
  Storage used / actual data size
  
  B-tree: ~1.3-2× (fill factor overhead, fragmentation)
  LSM-tree (size-tiered): ~2× (old and new data during compaction)
  LSM-tree (leveled): ~1.1× (much less space overhead)
```

---

## 2. The RUM Conjecture

```
RUM Conjecture (Idreos et al., CIDR 2016):
  You can optimize for any two of:
    R: Read overhead
    U: Update overhead  
    M: Memory overhead (space amplification)
  
  But not all three simultaneously.
  
  B-tree: optimizes R + M (good reads, low space) → worse U
  LSM size-tiered: optimizes U + M (good writes, low space) → worse R
  LSM leveled: optimizes R + U (good reads, good writes) → worse M (during compaction)
  
  This is why no single structure dominates all workloads.
```

---

## 3. Dostoevsky: LSM Tuning Framework

```
Monkey (2017) + Dostoevsky (2018) key insight:
  In LSM trees, reads are expensive at the largest level (most data)
  Bloom filter memory should be allocated proportionally to level size
  
  Optimal bloom filter strategy:
    Largest level (most data, most lookups): most bits per key
    Smaller levels: fewer bits (less data = less benefit from filter)
  
  Result: same total memory, much lower false positive rate at large levels
  Improvement: read amplification reduced by 2-3× with same memory budget

LSM compaction tuning levers:
  Size ratio (T): ratio between level sizes (default 10)
    T=2: more levels, lower WA per level, higher RA
    T=10: fewer levels, higher WA per level, lower RA
    Optimize T for your read/write mix
  
  Level 0 compaction trigger: how many L0 files before compaction
    Lower: more frequent compaction, lower RA, higher WA
    Higher: fewer compactions, higher RA, lower WA
  
  MemTable size: larger = fewer flushes = lower WA
    Tradeoff: larger MemTable = more data lost on crash without WAL
```

---

## 4. WiscKey: Separating Keys from Values

```
LSM-tree WA problem for large values:
  Standard LSM: key + value stored together in SSTable
  Compaction: must rewrite large values even if keys change slightly
  WA for 1MB values: every compaction pass rewrites full values = very high WA

WiscKey insight (FAST 2016):
  Store only keys (+ value pointers) in LSM-tree
  Store values in a separate value log (vLog) — append-only
  
  Write path:
    Value → append to vLog → get (file, offset)
    Key + (file, offset) → LSM-tree as value
  
  Compaction:
    LSM compaction: only moves small keys (not large values) → WA drops dramatically
    vLog GC: separate background process cleans stale values (key no longer in LSM)
  
  Read path:
    Key lookup in LSM → get (file, offset) → read value from vLog
    Two I/Os instead of one (slight read amplification increase)
  
  When WiscKey helps:
    Large values (> 1KB): WA reduction > read amplification increase
    When writes dominate
  
  When WiscKey hurts:
    Small values (< 1KB): overhead of vLog lookup not worth it
    Range scans: values scattered in vLog → random reads (lose LSM's sequential scan benefit)

Adoption: TiKV Titan (RocksDB plugin), BadgerDB (full WiscKey implementation)
```

---

## 5. Decision Framework: B-tree vs LSM-tree

```
Choose B-tree when:
  ✓ Read-heavy (>80% reads): lower RA, better for OLTP
  ✓ Random point lookups dominate
  ✓ In-place updates (update same key repeatedly)
  ✓ Strong consistency required (easier with B-tree WAL)
  ✓ Small dataset (fits in page cache): B-tree RA advantage diminishes
  Examples: PostgreSQL, MySQL InnoDB, SQLite

Choose LSM-tree when:
  ✓ Write-heavy (>50% writes): lower WA, much better throughput
  ✓ Append-mostly (time-series, logs, events)
  ✓ Large dataset (LSM's bloom filters help when cache miss is common)
  ✓ Key range scans (sorted SSTable format is efficient for range)
  ✓ Can tolerate higher read amplification
  Examples: RocksDB, Cassandra, LevelDB, HBase, InfluxDB

Quantified decision:
  Write rate > X GB/day? where X = (drive_TBW / WA_btree) / 365
  If yes → LSM-tree's lower WA may be critical for drive endurance

  Read latency SLA < Y µs?
  If yes → B-tree's lower RA with hot page cache is safer
```

---

## 6. Self-Check

1. B-tree has WA of ~128× for random 64-byte record updates in 8KB pages. LSM-tree (leveled) has WA of ~30×. Which has better write throughput and why?
2. WiscKey reduces compaction WA for large values. What read performance regression does it introduce?
3. A time-series database writes 100K events/second (100 bytes each). Should it use B-tree or LSM-tree? Quantify why.
4. What is the RUM conjecture and why does it matter for storage engine selection?

## 7. Answers

1. LSM-tree has better write throughput. Despite similar WA numbers (30× vs 128×), LSM-tree WA is in sequential writes (compaction writes sequentially). B-tree WA is random writes (each random key = random page write). On HDD: random vs sequential write is 100× performance difference. On NVMe: still 5-10× difference. LSM-tree converts random writes to sequential writes — this is its fundamental architectural advantage.
2. WiscKey requires two I/Os for every point read: first to the LSM-tree (get value pointer), then to the vLog (read actual value). Standard LSM-tree: one I/O after bloom filter eliminates candidates. Additionally: range scans lose sequential access locality — values are scattered across vLog in insertion order, not key order. Range scan with WiscKey = random I/Os into vLog = much slower than standard LSM-tree range scan.
3. LSM-tree. Quantification: 100K × 100 bytes = 10MB/s write rate. Per day: 864GB. B-tree WA (random, 8KB pages, 100-byte records): 8192/100 = 82×. Daily NAND writes: 864GB × 82 = 70TB/day. For a 10TB NVMe rated 3 DWPD × 10TB = 30TB/day NAND limit → B-tree would destroy the drive in months. LSM-tree WA (leveled): ~30×. Daily NAND writes: 864GB × 30 = 26TB/day → borderline acceptable. Size-tiered LSM: ~10× WA → 8.6TB/day → comfortable. Clear winner: LSM-tree.
4. RUM Conjecture: any data structure can optimize at most two of (Read overhead, Update overhead, Memory/space overhead). It's impossible to minimize all three simultaneously. Implication: storage engine selection is always a tradeoff — no universal winner. Choose based on which two dimensions matter most for your workload. B-tree optimizes R+M, LSM size-tiered optimizes U+M, LSM leveled optimizes R+U at the cost of M.

---

# Day 4: Log-Structured Storage Patterns

## Learning Objectives
- Understand log-structured file systems (LFS) and why they work well for SSDs
- Understand segment cleaning and its cost model
- Know NOVA's approach to hybrid volatile/non-volatile storage
- Know when to apply log-structured patterns in storage design

---

## 1. The Log-Structured Design Principle

```
Core idea: treat storage as an append-only log
  Never overwrite data in place
  Write sequentially to end of log
  Mark old data as invalid (via index update)
  Background cleaning reclaims invalid space

Why this works for SSDs:
  SSDs love sequential writes (full-stripe writes, low WA)
  SSDs hate random writes (GC pressure, high WA)
  Log-structured turns all writes into sequential appends
  → SSD FTL sees sequential writes → lower WA → longer SSD life

Write path (pure log-structured):
  Write data → append to current log segment
  Update index: key → (segment, offset)
  Old location marked invalid
  
Read path:
  Lookup key in index → (segment, offset)
  Read data at that location
  (Direct I/O — no compaction needed for reads)
```

---

## 2. Segment Cleaning (LFS)

```
Original LFS (Rosenblum & Ousterhout, 1992):
  Log divided into fixed-size segments (~1MB)
  Write frontier: current segment being filled
  
  Segment states:
    Live: contains valid data (recently written or not overwritten)
    Dead: all data overwritten (can be erased/reused immediately)
    Partially live: mix of valid + invalid data (must clean before reuse)

Segment cleaning:
  Select victim segments (based on policy)
  Read live data from victim (via segment summary block)
  Write live data to current write frontier (compaction)
  Mark victim segments as free
  
Cost model (Rosenblum's analysis):
  u = utilization of segment (fraction of live data)
  Write cost = 1/(1-u)   (lower u = cheaper to clean)
  
  If u=0.9 (90% live): write cost = 10× (must write 10 segments to free 1)
  If u=0.5 (50% live): write cost = 2× (must write 2 to free 1)
  
Cleaning policy: cost-benefit
  Score = (1-u) / (age × u)
  Clean old segments with low utilization first
  (Similar to bcache's GC policy from Month 2)
```

---

## 3. NOVA: Log-Structured for Persistent Memory

```
NOVA (FAST 2016): log-structured FS optimized for NVDIMM/pmem
  
Key insight: pmem is byte-addressable → per-inode logs (not single global log)
  Traditional LFS: one global log → cleaning bottleneck
  NOVA: separate log per inode → parallel writes to different inodes
  
NOVA design:
  Per-inode log: each file has its own log in pmem
  Atomic updates: log entry written + pointer updated atomically (CPU instruction)
  No journal separate from log: log IS the journal
  
  Write to file:
    1. Allocate new DRAM page
    2. Write data to page
    3. Flush (clflush) to pmem
    4. Append log entry: {block, offset, length, version}
    5. Update inode tail pointer (atomic 8-byte write)
  
  Crash recovery:
    Walk per-inode logs → reconstruct file state
    No global journal to replay → faster recovery
  
Performance vs ext4/XFS:
  Sequential write: NOVA 2-5× faster (no journaling overhead)
  Random write: NOVA 10× faster (no RMW, append-only)
  Read: similar (reads go directly to data, not log)
```

---

## 4. Log-Structured Patterns in Modern Systems

```
Where log-structured thinking appears in 2026:

RocksDB WAL:
  WAL is a log → crash recovery
  MemTable is in-memory log → flushed to SSTable
  LSM-tree IS a log-structured structure

Kafka / distributed logs:
  Pure log-structured: append-only, immutable segments
  Consumers read from offset in log
  Segment cleaning: delete old segments based on retention policy

Object storage (S3, MinIO):
  Append-only by design (objects immutable)
  New version → new object (no in-place update)
  Log-structured at object level

Write-optimized databases (WiredTiger, TiKV):
  WAL + LSM-tree: two levels of log structure

Key insight for architects:
  When to apply log-structured pattern:
    ✓ Write-heavy workload (append > update)
    ✓ SSD storage (maximize sequential write efficiency)
    ✓ Need crash consistency (log is the journal)
    ✓ Immutable data (time-series, events, messages)
    ✗ Heavy random reads to latest version (extra index lookup)
    ✗ Frequent in-place updates (cleaning overhead = compaction)
```

---

## 5. Self-Check

1. Log-structured storage converts random writes to sequential writes. What background process converts this benefit back into a cost?
2. LFS cleaning policy prefers segments with low utilization. Why not always clean the lowest-utilization segment?
3. NOVA uses per-inode logs instead of a global log. What performance problem does this solve?
4. Kafka uses a pure log-structured design. What is Kafka's equivalent of LFS segment cleaning?

## 7. Answers

1. Segment cleaning (LFS) or compaction (LSM-tree). These background processes must read live data from fragmented segments and rewrite it sequentially. Every byte of user data may be rewritten multiple times during cleaning — this is write amplification from the log-structured design itself.
2. Cost-benefit: cleaning a very low utilization segment is cheap (few live bytes to copy) but may not free much space (it's already nearly empty). Cleaning a medium-utilization segment (50% live) frees more space per cleaning pass. Additionally: age matters — old cold data benefits more from cleaning because it's stable (won't be overwritten again soon). Pure lowest-utilization ignores this.
3. Global log: all writes go to one log → single write frontier → serialized writes from all inodes → bottleneck. Per-inode log: each file writes to its own log in pmem → parallel writes from different files don't conflict → scales with inode count. Especially important for pmem where per-inode parallelism can be exploited (byte-addressable → no disk seek penalty for multiple log positions).
4. Kafka's equivalent: log retention/deletion policy. Kafka deletes old segments based on: time-based retention (e.g., delete segments older than 7 days), or size-based retention (delete oldest segments when total log exceeds max size). Unlike LFS which must compact and copy live data, Kafka can simply delete old segments because data is immutable and consumers read forward (old segments are truly dead, not partially live). This is simpler than LFS cleaning.

---

# Day 5: Copy-on-Write Trees

## Key Content (Condensed — covered partially in Month 1 Day 20)

```
CoW B-tree recap (Btrfs model):
  Every modification: copy node → modify copy → update parent pointer
  Old node: becomes free (after transaction commit)
  Root pointer: atomically updated → commit is atomic

  Advantages:
    Snapshots: instant (just copy root pointer)
    Crash consistency: old tree always valid until new root committed
    Parallel readers: always see consistent version (no locks for reads)
  
  Disadvantages:
    Write amplification: every write copies O(log N) nodes (path from root to leaf)
    Fragmentation: CoW scatters data across free space → sequential read becomes random
    GC complexity: must track which old nodes are still referenced by snapshots

APFS (Apple File System, 2017):
  Uses CoW B-tree like Btrfs but designed for flash:
  - Container/volume model (multiple volumes share one pool)
  - Cloneable files (cp --reflink equivalent, native)
  - Case-insensitive + case-sensitive mode per volume
  - Encryption per volume (key per volume in container)
  - Snapshot support (like Btrfs)
  
  APFS vs Btrfs difference:
    APFS: designed for single-device (Mac, iPhone) → no RAID integration
    Btrfs: designed for Linux with integrated RAID (though RAID 5/6 buggy)

LMDB (Lightning Memory-Mapped Database):
  Uses append-only CoW B-tree
  No WAL needed: CoW provides crash consistency
  Memory-mapped: entire database mmap'd → reads are load instructions
  Single-writer, multi-reader: writer COWs → readers always see consistent tree
  Very fast reads (mmap + no locking)
  Use case: embedded key-value store (OpenLDAP, many config stores)

CoW B-tree vs LSM-tree:
  CoW B-tree: good for read-heavy, moderate writes, snapshot workloads
  LSM-tree: better for write-heavy (lower WA), higher read amplification

When to recommend CoW B-tree:
  ✓ Frequent snapshots required (VMs, container images)
  ✓ Read-heavy with occasional writes
  ✓ Need ACID transactions without separate WAL
  ✗ Very high write rates (CoW path per write = expensive)
  ✗ Large values (CoW copies entire node per write)
```

---

# Day 6: Bloom Filters, Fence Pointers & Learned Indexes

## Key Content (Condensed)

```
Bloom Filter in LSM-trees:
  Purpose: quickly answer "is key K NOT in this SSTable?"
  False positive rate: p = (1 - e^(-kn/m))^k
    k = number of hash functions
    n = number of keys
    m = number of bits
  
  Optimal k = (m/n) × ln(2) ≈ 0.693 × (m/n)
  
  Sizing rule:
    1 bit per key: FPR ≈ 61% (useless)
    8 bits per key: FPR ≈ 2% (RocksDB default)
    10 bits per key: FPR ≈ 1%
    16 bits per key: FPR ≈ 0.1%
  
  Memory cost: 8 bits/key × 1B keys = 1GB RAM
  RocksDB: bloom filters stored in SSTable → loaded on demand → bounded memory use
  
  Monkey paper insight: allocate more bits to larger levels
    Largest level has most keys → highest lookup probability → benefits most from low FPR
    Optimal: exponentially more bits per key at deeper levels
    Result: same total memory → 2-3× fewer I/Os for point reads

Fence Pointers (block index in SSTable):
  SSTable data is divided into 4KB-32KB data blocks
  Fence pointer: "smallest key in each data block"
  Stored in index block at end of SSTable
  
  Read: binary search fence pointers → find block → read block → binary search within
  Cost: 1 block index I/O + 1 data block I/O = 2 I/Os per level
  With bloom filter: most non-existent keys filtered in O(1)

Learned Indexes (Kraska et al., SIGMOD 2018):
  Insight: B-tree is essentially a model: given key → predict page location
  Replace B-tree with a learned model (linear regression, neural net)
  
  For sorted data: linear model predicts position
  Correction: small B-tree to handle prediction errors
  
  Results for read-only sorted data:
    70% smaller memory than B-tree
    2-3× faster lookups
    Limitation: poor for updates (model must be retrained)
  
  Practical adoption:
    TiKV: learned bloom filter replacement (BoF)
    PostgreSQL: learned index experiment
    Main use: read-only analytical data, static sorted datasets
    Not ready for: OLTP with heavy updates

Architect takeaway:
  Bloom filters: always use in LSM-trees (cheap, high ROI)
  Fence pointers: fundamental to SSTable design (already in every implementation)
  Learned indexes: evaluate for read-heavy analytical workloads, not OLTP
```

---

# Day 7: Week 1 Review — Storage Engine Selection Framework

## The Complete Framework

```
Given any storage workload → choose storage engine:

Step 1: Read/Write ratio
  >80% reads, <20% writes:
    → B-tree (lower RA, better for OLTP point reads)
    → CoW B-tree if snapshots needed
  
  >50% writes:
    → LSM-tree (lower WA, better throughput)
    → Choose compaction: leveled (balanced) or size-tiered (write-optimized)
  
  Append-only (new keys only, no updates):
    → LSM-tree with size-tiered (lowest WA)
    → Or pure log (time-series, event logs)

Step 2: Value size
  Small values (<1KB): standard LSM-tree or B-tree
  Large values (>4KB): WiscKey-style key-value separation
    (reduces compaction WA dramatically for large values)

Step 3: Range scan requirements
  Heavy range scans: LSM-tree (sorted SSTable) or B-tree
  Point lookups only: bloom filters make LSM-tree efficient
  WiscKey: hurts range scans (values scattered in vLog) — avoid if ranges matter

Step 4: Snapshot requirements
  Frequent snapshots: CoW B-tree (Btrfs/LMDB model)
  No snapshots needed: B-tree or LSM-tree

Step 5: Amplification budget
  Calculate: WA × daily_writes must fit within TBW/lifetime
  If WA is critical: LSM > B-tree
  If RA is critical: B-tree > LSM
```

## Design Scenario: Time-Series Storage Engine

**Brief:** New time-series database.
Writes: 500K events/second, 200 bytes each = 100MB/s
Reads: 10K range queries/second (last 1 hour window mostly)
Deletes: automatic after 90-day retention
No snapshots needed.

**Analysis:**
- Write rate: 100MB/s × WA = NAND writes/s. Budget: 3 DWPD × 4TB NVMe = 12TB/day = 139MB/s NAND budget
- B-tree WA: 8KB/200B = 41×. NAND writes: 100MB/s × 41 = 4.1GB/s → way over budget
- LSM size-tiered WA: ~10×. NAND writes: 100MB/s × 10 = 1GB/s = 86TB/day → still over budget
- WiscKey (large-ish values at 200B) + size-tiered: WA ≈ 3-5×. NAND writes: 300-500MB/s = 26-43TB/day → borderline
- Pure log-structured with time-based segment rotation: WA ≈ 1.1× (write once, delete whole segment after 90 days)

**Recommendation:** Log-structured with time-based segments (like Kafka/InfluxDB model)
- Each segment = one hour of data
- Sequential writes → minimal WA
- Range queries: read adjacent segments (sequential reads, efficient)
- 90-day retention: delete old segments (whole-segment deletion, no per-record GC)
- Result: WA ≈ 1.1×, NAND writes ≈ 110MB/s — within budget

**Key lesson:** Log-structured (pure append) often beats LSM-tree for time-series because time-based retention eliminates per-record deletion complexity.

---

## Tomorrow: Day 8 — Deduplication: Inline vs Post-Process

Week 2 begins: data reduction technologies. We start with deduplication
architecture — when to dedup, where in the I/O path, and what workloads
actually benefit vs which ones dedup hurts.
