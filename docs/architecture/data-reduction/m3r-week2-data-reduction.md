# Month 3 Week 2: Data Reduction Technologies (Days 8–14)

---

# Day 8: Deduplication — Inline vs Post-Process

## Learning Objectives
- Understand the two deduplication architectures and their tradeoffs
- Know which workloads benefit from dedup vs which are harmed
- Know how to calculate dedup ratio and break-even storage savings
- Understand the dedup index scaling challenge

---

## 1. How Deduplication Works

```
Deduplication: identify duplicate data chunks, store only once

Basic flow:
  1. Split data into chunks (fixed-size or variable-size)
  2. Hash each chunk: SHA-256(chunk) → fingerprint
  3. Check fingerprint index: is this fingerprint already stored?
     YES → store only a pointer to existing chunk (no new data written)
     NO  → store new chunk, add fingerprint to index
  4. File metadata: list of (fingerprint, length) → reconstructs file

Dedup ratio: unique_bytes / total_bytes
  VM disk images (same OS): 70-85% duplicate → ratio 5-10×
  Database files: 10-30% duplicate → ratio 1.1-1.4×
  Already-compressed data: ~0% duplicate → ratio 1.0× (dedup adds overhead, no benefit)
  Encrypted data: ~0% duplicate (encryption makes identical data look unique) → 1.0×
```

---

## 2. Inline Dedup

```
Inline dedup: dedup happens synchronously during write

Write path:
  Application writes data
    → chunk data
    → hash chunks
    → lookup each hash in index
    → for new chunks: write chunk + update index
    → for duplicate chunks: write pointer only
    → return success to application

Latency impact:
  Hash computation: fast (~1-2 GB/s for SHA-256 with hardware acceleration)
  Index lookup: the bottleneck
    In-memory index: nanoseconds
    SSD-backed index: microseconds
    HDD-backed index: milliseconds (usually unacceptable)

When inline dedup works well:
  ✓ High dedup ratio (worth the latency cost)
  ✓ Index fits in RAM or fast NVMe
  ✓ Write latency tolerance > 100µs

When inline dedup hurts:
  ✗ Low dedup ratio (latency cost with no space benefit)
  ✗ Encrypted data (near-zero dedup, all overhead)
  ✗ Already-compressed data (same)
  ✗ Latency-sensitive writes (database commits)
  
Used by: ZFS (inline dedup), NetApp primary storage, EMC VMAX
```

---

## 3. Post-Process Dedup

```
Post-process dedup: dedup happens asynchronously after write

Write path:
  Application writes data → written as-is (no dedup)
  Application gets fast acknowledgment (no dedup overhead)

Background (scheduled or continuous):
  Scanner reads written data
  Hashes chunks, checks index
  Replaces duplicate chunks with pointers
  Frees original copy storage

Tradeoffs vs inline:
  + No write latency impact
  + Can be scheduled during low-load periods
  - Data temporarily stored in full (before dedup runs)
  - Requires enough space for un-deduped data initially
  - Background I/O competes with foreground workload

When post-process works well:
  ✓ Latency-sensitive writes (databases)
  ✓ Batch workloads (backup, replication)
  ✓ Dedup ratio predictable (can plan storage headroom)
  ✓ Dedup index can be rebuilt from data (tolerates index loss)

Used by: backup appliances, most enterprise backup software (Veeam, Veritas)
```

---

## 4. Dedup by Workload Type

```
High dedup ratio (dedup recommended):
  VM images (same template): 80-90% duplicate
    100 VMs from same template → 10-20× dedup ratio
    Inline or post-process both viable

  Virtual desktop infrastructure (VDI): 85-95% duplicate
    Thousands of near-identical OS images
    Best dedup use case in enterprise

  Backup data (daily backups of similar datasets): 95-99% duplicate
    Only changed blocks differ between backups
    10-100× dedup ratio typical

Low/no dedup ratio (dedup not recommended):
  Database data files: 5-20% duplicate
    Pages have metadata, timestamps → low duplication
    Dedup overhead likely exceeds space savings

  Video/media files: ~0% duplicate
    Already compressed, unique content
    Dedup only finds exact file duplicates, not similar content

  Encrypted data: ~0% duplicate
    Encryption randomizes bytes → no duplicate chunks
    Dedup AFTER encryption = useless
    Must dedup BEFORE encryption (or use convergent encryption)

  Scientific data (simulations, genomics): 0-5% duplicate
    Mostly unique data → dedup adds overhead, saves little
```

---

## 5. The Dedup Index Scaling Problem

```
Index size vs dataset size:
  1TB dataset, 8KB chunks = 128M chunks
  SHA-256 fingerprint = 32 bytes
  Pointer = 8 bytes
  Index entry = 40 bytes
  Total index size = 128M × 40 bytes = 5GB RAM

For 100TB dataset:
  Index size = 500GB RAM → expensive!

Production solutions:
  1. DRAM index with SSD backing:
     Hot fingerprints in DRAM (LRU cache)
     Cold fingerprints on SSD → 100-200µs lookup
     Effective for backup (working set is recent backups)

  2. Summary vector (Bloom filter index):
     Probabilistic: "is this chunk probably stored?"
     Small (1-2 bytes per chunk) but false positives = unnecessary lookups
     Used as first-stage filter before full index check

  3. Sampling dedup:
     Only hash/check every N-th chunk
     Reduces index lookup overhead × N
     Misses some duplicates (lower dedup ratio)

  4. Locality-preserving dedup:
     Exploit: duplicate data tends to be in same locality (same file region)
     Cache recent chunk hashes → check cache before index
     High hit rate for backup workloads (backup streams are local)
     Used by: Data Domain (now Dell), Quantum DXi
```

---

## 6. Break-Even Analysis

```
Dedup is worth it when: storage_savings > dedup_overhead_cost

Storage savings = data_size × (1 - 1/dedup_ratio)
  Example: 100TB data, 5× dedup ratio
  Savings = 100TB × (1 - 1/5) = 80TB saved
  At $0.30/GB NVMe: 80TB × $0.30/GB = $24,000 saved

Dedup overhead cost:
  - Additional CPU for hashing: ~1-5% (negligible with hardware SHA)
  - Index DRAM: ~40 bytes/chunk × (total_chunks) → GB of RAM
  - Read overhead: dedup fragments data → sequential read becomes random
    (metadata says "chunk X is stored at location Y" → random I/O to assemble)
  - Operational complexity: GC of orphaned chunks, index maintenance

Break-even rule of thumb:
  Dedup is worth it when dedup_ratio > 1.5× (50%+ duplicate data)
  Below 1.2×: overhead likely exceeds savings
  Above 3×: dedup is clearly beneficial

For backup systems: almost always worth it (typical ratio 10-50×)
For primary storage: evaluate carefully per workload
```

---

## 7. Self-Check

1. Why does encrypting data before deduplication destroy the dedup ratio?
2. An inline dedup system has SHA-256 fingerprint lookup taking 2ms (HDD-backed index). Write latency was 100µs. What happens to application-perceived write latency?
3. A backup system stores 500TB of daily VM snapshots. Dedup ratio is 40×. How much physical storage is needed?
4. Why does dedup cause read amplification and what pattern makes this worst?

## 8. Answers

1. Encryption transforms identical plaintext into different ciphertext (via random IV/nonce). Two identical 8KB blocks encrypted with different IVs → two completely different ciphertext blocks → different fingerprints → dedup cannot identify them as duplicates. The dedup ratio collapses to ~1× regardless of actual data duplication.
2. Write latency explodes: 100µs + 2ms = 2.1ms per chunk lookup. For a 1MB write with 8KB chunks: 128 chunks × 2ms = 256ms just for index lookups. This is completely unacceptable for any write latency requirement. Inline dedup with HDD-backed index is only viable for very low IOPS workloads or when the index fits in RAM.
3. Physical storage needed: 500TB / 40× = 12.5TB. Plus metadata and index overhead (~5-10%): ~14TB total. Compared to naive storage (500TB/day × retention): dedup is the only viable approach for backup at this scale.
4. Dedup stores each unique chunk at one physical location. When reading a file, chunks are assembled from multiple locations across the storage — random I/O instead of sequential. Worst pattern: reading a large file that has many duplicate chunks stored far apart (typical for VDI images where pages from thousands of VMs are combined). Sequential file read becomes hundreds of random I/Os → read throughput may drop 10-100×.

---

# Day 9: Deduplication — Chunking & Fingerprinting

## Learning Objectives
- Understand fixed-size vs content-defined (variable) chunking
- Understand Rabin fingerprinting for chunk boundary detection
- Know the chunk size tradeoff: dedup ratio vs index overhead
- Understand convergent encryption for dedup + encryption together

---

## 1. Fixed-Size Chunking

```
Split data into equal-size blocks (4KB, 8KB, 16KB):
  File: [block0][block1][block2]...[blockN]
  Each block → hash → check index

Problem: the boundary shift problem
  Original: [AAAAAAA][BBBBBBB][CCCCCCC]
  After inserting 1 byte at start:
  [xAAAAAA][ABBBBBB][BCCCCC]
  
  All chunks now have different content → no dedup matches!
  
  Consequence: inserting 1 byte into a 1TB file → zero dedup with original
  Backup use case: file changed by prepending → entire file looks unique → no dedup

This is why fixed-size chunking works poorly for general file data.
It works well for: block-level dedup (LBA-based), VM disk dedup (VMs share exact LBAs)
```

---

## 2. Content-Defined Chunking (CDC)

```
Rabin fingerprinting: find chunk boundaries based on content

Algorithm:
  Sliding window (e.g., 48 bytes) moves across data
  For each window position: compute Rabin polynomial hash of window
  If hash % D == r (some constant): this is a chunk boundary
  D controls average chunk size: avg_size = D bytes
  
  Result: chunk boundaries are determined by DATA content, not position
  Inserting bytes: only chunks near insertion point change
  Bytes far from insertion: identical to original → dedup matches!

Example with D=8192 (target 8KB average chunks):
  Original file: chunks at byte positions [0, 7834, 16102, 24519, ...]
  After 1-byte insertion at position 100: 
    Chunk 0: [0, 7834] → slightly different (contains insertion) → new hash
    All other chunks: IDENTICAL to original → dedup matches
  
  Dedup ratio improvement: 100× better than fixed-size for modified files

Chunk size distribution:
  Min chunk size: prevent tiny chunks (usually 512B-2KB minimum)
  Max chunk size: prevent huge chunks (usually 32KB-256KB maximum)
  Average chunk size: controlled by D
  Distribution: approximately geometric (exponential)
```

---

## 3. Chunk Size Tradeoffs

```
Effect of chunk size on dedup and overhead:

Smaller chunks (1-4KB):
  + Higher dedup ratio (more granular matching → more duplicates found)
  - Larger index (more chunks → more fingerprints to store)
  - Higher metadata overhead (more pointer entries per file)
  - More I/O fragmentation on read (more random I/Os to assemble file)

Larger chunks (32-256KB):
  + Smaller index (fewer chunks)
  + Less fragmentation (fewer I/Os to read file)
  - Lower dedup ratio (less granular matching)
  - Single changed byte in chunk → entire chunk stored as new

Production choices:
  Backup systems: 4-16KB (maximize dedup ratio, latency tolerance for reads)
  Primary storage: 64-256KB (balance dedup with read performance)
  VM image storage: 4-8KB (VM page size alignment, high dedup opportunity)

Quantified example (8KB vs 64KB chunks):
  100GB VM image, 20% changed from template:
    8KB chunks: ~97% dedup → 3GB stored
    64KB chunks: ~87% dedup → 13GB stored
  4× less storage with smaller chunks
  But: 8× more index entries, 8× more I/Os to read
```

---

## 4. Fingerprint Algorithm Choice

```
Requirements: collision resistance, speed, small output

SHA-256 (32 bytes):
  + Cryptographically secure (astronomically low collision probability)
  + Hardware acceleration (SHA-NI on modern CPUs): 4-8 GB/s
  - 32-byte fingerprint: large index
  Used by: most enterprise dedup systems, git

SHA-1 (20 bytes):
  + Faster than SHA-256
  - Known theoretical weaknesses (SHAttered attack)
  - Not recommended for new systems
  
xxHash / SHA-3 / BLAKE3 (32 bytes):
  + Faster than SHA-256 for non-crypto uses
  + BLAKE3: hardware-accelerated, 10+ GB/s
  - Less widely validated for dedup collision resistance
  
MD5 (16 bytes):
  - Cryptographically broken (collisions exist)
  - Should not be used for dedup (data corruption risk from collision)
  Used by: some legacy systems (mistake)

Collision probability:
  With SHA-256, 10^18 chunks: probability of collision < 10^{-58}
  For practical purposes: SHA-256 collision is impossible
  Use SHA-256 for new systems; BLAKE3 if performance matters more
```

---

## 5. Convergent Encryption

```
Problem: dedup + encryption seem incompatible
  Encryption: same plaintext + random IV → different ciphertext → no dedup
  
Convergent encryption solution:
  Key = hash(plaintext)  (key derived from content, not random)
  Ciphertext = encrypt(plaintext, key=hash(plaintext))
  
  Same plaintext → same key → same ciphertext → dedup works!
  Different plaintexts → different hash → different key → different ciphertext → secure
  
  Property: convergent = same plaintext always produces same ciphertext
  
Dedup with convergent encryption:
  1. Hash plaintext chunk → k = SHA-256(chunk)
  2. Encrypt chunk: ciphertext = AES-256(chunk, key=k)
  3. Fingerprint ciphertext for dedup: fp = SHA-256(ciphertext)
  4. Store ciphertext at fp → index fp → pointer
  
  Dedup works: two clients with same plaintext → same ciphertext → same fp → dedup matches
  Encrypted at rest: storage system only sees ciphertext
  
Convergent encryption weakness (theoretical):
  If attacker guesses plaintext, they can compute expected ciphertext and fingerprint
  → Confirm whether a specific file is stored (confirmation attack)
  Mitigation: add server-managed secret to key derivation
    k = SHA-256(plaintext || server_secret)
  
Used by: Perkeep, some backup systems
Not used by: most enterprise dedup (encryption done separately, dedup before encryption)
```

---

## 6. Self-Check

1. Why does content-defined chunking (CDC) outperform fixed-size chunking for modified files?
2. A backup system uses 8KB chunks with SHA-256 fingerprints. 100TB dataset, 10× dedup ratio. How large is the fingerprint index in RAM?
3. What is the security risk of using MD5 as the dedup fingerprint algorithm?
4. Convergent encryption enables dedup + encryption. What is its theoretical weakness?

## 7. Answers

1. Fixed-size chunking: boundaries at fixed byte positions. Insert 1 byte → all chunk boundaries shift → all chunks look different from original → zero dedup. CDC: boundaries determined by content patterns (Rabin hash). Insert 1 byte → only nearby chunk boundary shifts → only that chunk changes → all distant chunks remain identical → dedup matches them. For a 1TB file with 1% change, CDC achieves ~99% dedup; fixed-size achieves ~0%.
2. 100TB / 10× dedup = 10TB stored unique data. At 8KB chunks: 10TB / 8KB = 1.28 billion chunks. Each fingerprint = 32 bytes (SHA-256) + 8 bytes pointer = 40 bytes. Index size = 1.28B × 40 = 51GB RAM. For the full 100TB (before dedup): 100TB / 8KB = 12.8B chunks → 512GB index. In practice: dedup systems use tiered index (hot in RAM, cold on SSD).
3. MD5 has known collision attacks (SHAttered demonstrated SHA-1 collision; MD5 collisions are easier). Two different data chunks could have the same MD5 fingerprint → dedup system stores first chunk, serves it for both → data corruption: reading the second file returns the first file's content. This is silent data corruption — extremely dangerous. Use SHA-256 or BLAKE3.
4. Confirmation attack: if an attacker wants to know whether a specific file (e.g., a particular document) is stored in the system, they compute convergent_encrypt(target_file) → get the expected fingerprint → query the dedup index (if accessible). If that fingerprint exists → the file is stored. This leaks membership information. Mitigation: server-managed secret in key derivation (HMACed key) prevents attackers without the secret from performing this attack.

---

# Day 10: Compression — Tradeoffs in Practice

## Learning Objectives
- Know the compression algorithm landscape and when each wins
- Understand compression ratio vs CPU cost vs latency tradeoff
- Know when compression hurts performance
- Know how to benchmark compression for your specific data

---

## 1. Compression Algorithm Landscape

```
Algorithm comparison (typical data: text/logs/database pages):

Algorithm    Compress Speed  Decompress  Ratio   CPU Cost  Use Case
──────────────────────────────────────────────────────────────────
LZ4          500 MB/s        3000 MB/s   1.5-2×  Very low  Hot path, latency-sensitive
Snappy       250 MB/s        1500 MB/s   1.5-2×  Low       Google internal, databases
Zstd (1)     400 MB/s        1500 MB/s   2-3×    Low       Good default
Zstd (3)     200 MB/s        1500 MB/s   2.5-3×  Medium    Default for most storage
Zstd (9)     50 MB/s         1500 MB/s   3-4×    High      Cold data, batch jobs
Zlib/gzip    100 MB/s        400 MB/s    3-4×    Medium    Legacy compatibility
Brotli       10 MB/s         400 MB/s    4-5×    High      Web delivery, static content
LZMA/xz      5 MB/s          100 MB/s    5-7×    Very high Archival, installers

Key insight: decompress speed >> compress speed for most algorithms
  → Read-heavy workloads: decompression cost matters more than compression cost
  → LZ4/Snappy/Zstd: decompression is so fast it's often CPU-free on modern hardware
```

---

## 2. Compression Ratio by Data Type

```
Data type → typical ratio with Zstd level 3:

Database pages (mixed): 2-4× (depends on data types, NULLs)
JSON/XML API responses: 3-8× (very compressible)
Log files: 5-10× (repetitive structure)
Source code: 4-6×
VM disk images (OS): 2-3×
CSV/TSV data: 3-8× (depends on data)
Video (H.264/H.265): 1.0× (already compressed)
Images (JPEG/PNG): 1.0-1.1× (already compressed)
Encrypted data: 1.0× (encryption → incompressible)
Random data: 1.0× (incompressible by definition)
Scientific float arrays: 1.5-2× (Zstd), 3-10× (domain-specific codecs)

Rule: compressing already-compressed or encrypted data:
  Not only saves nothing → costs CPU and may EXPAND data slightly
  Always check if data is already compressed before applying compression
```

---

## 3. Where Compression Lives in Storage Stack

```
Options (each with different tradeoffs):

1. Application-level compression:
   App compresses data before writing to storage
   + Full control over algorithm and settings per data type
   + Compressed data benefits dedup IF same algorithm applied consistently
   - Application complexity
   - Dedup before compression is better (compress after dedup = higher ratio)
   Example: PostgreSQL TOAST compression, MongoDB compressed collections

2. Filesystem-level compression:
   Filesystem transparently compresses data blocks
   + Transparent to application
   + Can compress per-extent (adaptive)
   - Increased read latency (must decompress on read)
   - May reduce random write performance (block must be decompressed, modified, recompressed)
   Examples: Btrfs (LZO, Zlib, Zstd), ZFS (LZ4, Zstd), NTFS (LZNT1)

3. Block device / storage array compression:
   Compression in storage controller firmware or driver
   + Fully transparent to filesystem and application
   + Can be hardware-accelerated (Intel ISA-L, QAT)
   - Less control over algorithm
   Examples: ZFS vdev-level, Pure Storage, NetApp AFF

4. Object storage compression (S3, MinIO):
   Object stored compressed, decompressed on read
   + Simple (just set content-encoding header)
   - Must decompress entire object to access any byte
   - Bad for random-access patterns within large objects
```

---

## 4. When Compression Hurts

```
Case 1: Already-compressed data
  Compressing JPEG/MP4/ZIP/already-Zstd data:
  CPU overhead to attempt compression + possible slight expansion
  Detection: check magic bytes, file extension, or entropy estimate
  Fix: skip compression for known incompressible formats

Case 2: Random writes to compressed blocks (B-tree with compression)
  8KB database page → compressed to 3KB → stored as 3KB
  Update one row → must: read 3KB block → decompress to 8KB → modify → recompress
  Every random write = read-decompress-modify-compress-write
  Latency: 100µs (normal) → 500µs+ (with compress/decompress cycle)
  Fix: use larger compression blocks (tolerate more internal fragmentation) or LZ4 (fast enough to hide latency)

Case 3: Compression at high concurrency
  Many threads compressing simultaneously → CPU saturation
  100 threads × 200MB/s Zstd = 20GB/s CPU requirement → saturates server
  Fix: LZ4 (5× faster) or compress only during off-peak, or hardware compression

Case 4: Compression breaks dedup
  Must compress AFTER dedup (not before)
  Compress before dedup: same original data → different compressed output (different context window) → no dedup match
  Always: dedup → compress → encrypt (in that order)
```

---

## 5. Hands-On: Compression Benchmark

```bash
# Install compression benchmarking tools
apt install zstd lz4 pigz

# Generate test data (realistic database-like content)
python3 -c "
import random, string, json, sys
data = []
for i in range(100000):
    data.append({'id': i, 'user': ''.join(random.choices(string.ascii_lowercase, k=8)),
                 'value': random.randint(0, 1000000), 'ts': 1700000000 + i})
sys.stdout.buffer.write(json.dumps(data).encode())
" > /tmp/test_data.json

echo "Original size: $(wc -c < /tmp/test_data.json) bytes"

# Benchmark compression speed and ratio
for algo in "lz4" "zstd -1" "zstd -3" "zstd -9" "gzip -1" "gzip -9"; do
    cmd=$(echo $algo | cut -d' ' -f1)
    level=$(echo "$algo" | grep -o '\-[0-9]*' | head -1)
    
    start=$SECONDS
    eval "$algo -c /tmp/test_data.json > /tmp/compressed.$cmd$level" 2>/dev/null || \
    eval "$cmd $level -c /tmp/test_data.json > /tmp/compressed.$cmd$level" 2>/dev/null || true
    
    if [ -f "/tmp/compressed.$cmd$level" ]; then
        orig=$(wc -c < /tmp/test_data.json)
        comp=$(wc -c < /tmp/compressed.$cmd$level)
        ratio=$(echo "scale=2; $orig/$comp" | bc)
        echo "$algo: ratio=${ratio}x, size=$(du -sh /tmp/compressed.$cmd$level | cut -f1)"
    fi
done

# Decompress speed test
echo "=== Decompress speeds ==="
time lz4 -d -c /tmp/compressed.lz4 > /dev/null
time zstd -d -c /tmp/compressed.zstd-3 > /dev/null
```

---

## 6. Self-Check

1. LZ4 has a lower compression ratio than Zstd but is often preferred for hot storage paths. Why?
2. A database stores compressed B-tree pages (LZ4). A random 8-byte update to a page happens. What is the I/O path compared to uncompressed?
3. Should you apply compression before or after deduplication in a storage pipeline? Why?
4. Why does encrypting data before compression cause the compression to fail?

## 7. Answers

1. LZ4 decompression speed: ~3000 MB/s (often limited by memory bandwidth, not CPU). For a hot storage path, every read requires decompression. Zstd at ratio 3× saves 67% storage but adds 200µs decompression time per access. LZ4 at ratio 1.5× saves 33% storage but decompression is nearly free (3000 MB/s ≈ 1µs per 4KB block). For latency-sensitive reads, the 200µs vs 1µs difference dominates. LZ4 is preferred when read latency matters; Zstd when storage savings matter more.
2. Random update with compressed pages: read compressed page from disk (1 I/O) → decompress to full 8KB → modify 8 bytes → recompress to ~3KB → write compressed page back (1 I/O). Same I/O count as uncompressed (2 I/Os), but added CPU for decompress+compress cycles. LZ4: ~1µs total overhead (negligible). Zstd level 9: ~200µs overhead (significant for <500µs SLA).
3. Dedup before compression. Reason: dedup requires identical input data to produce identical fingerprints. If you compress first, two identical source chunks may compress to different byte sequences if they appear in different compression contexts (different preceding data → different LZ back-references). Dedup after compression = much lower dedup ratio. Correct order: chunk → dedup → compress → encrypt.
4. Encryption (AES-XTS etc.) produces high-entropy output that is statistically indistinguishable from random noise. Compression algorithms work by finding patterns and redundancy. Encrypted data has no patterns → compression ratio ≈ 1.0× → compressor outputs data at same size or slightly larger (due to compression headers). Compression must happen before encryption: plaintext → compress → encrypt → store.

---

# Day 11: Thin Provisioning at Scale

## Learning Objectives
- Understand overcommit ratio design and its risks
- Understand space reclamation (TRIM/discard) end-to-end
- Know pool exhaustion behavior and how to prevent it
- Design a thin provisioning policy with monitoring and alerts

---

## 1. Overcommit: The Promise and the Risk

```
Thin provisioning overcommit:
  Provision more virtual capacity than physical capacity exists
  Relies on: not all provisioned space will be used simultaneously
  
  Example: 
    Physical pool: 10TB
    Thin volumes provisioned: 50TB total (5:1 overcommit)
    Actual used space: 8TB (80% of physical → comfortable)
    
  Valid because:
    Databases often provision 2× expected data size (growth headroom)
    VMs provisioned for peak but average is 30% utilized
    Dev/test volumes often mostly empty
  
  Risk: overcommit materializes
    All tenants simultaneously use their full provisioned space
    Physical pool exhausts
    New writes fail: I/O errors on all thin volumes simultaneously
    ALL thin volumes affected (not just the active ones)

Overcommit ratio recommendations:
  Conservative: 2:1 (safe for most production workloads)
  Moderate: 3:1 (acceptable with good monitoring)
  Aggressive: 5:1 (high risk, only for dev/test or well-understood workloads)
  
  Never: overcommit without monitoring and automatic alerts
```

---

## 2. Space Reclamation: TRIM/Discard End-to-End

```
Problem: deleted data in thin volume doesn't automatically return space to pool

Without reclamation:
  VM deletes 1TB of files
  Filesystem marks LBAs as free
  But: thin provisioning layer still has physical blocks mapped to those LBAs
  Physical pool space: NOT returned

TRIM/Discard propagation:
  Application deletes file
  → Filesystem issues DISCARD command for freed LBAs
  → Thin provisioning layer receives DISCARD
  → Returns physical blocks to free pool
  → Pool space actually reclaimed

Configuring TRIM:
  Filesystem mount with discard option:
    mount -o discard /dev/mapper/thin_lv /mnt/data
    (synchronous discard: issued immediately on delete → adds latency)
  
  OR: periodic fstrim (better for latency-sensitive workloads):
    fstrim /mnt/data  # run weekly via cron
    
  dm-thin DISCARD passthrough:
    echo 1 > /sys/block/dm-X/queue/discard_passthrough
    (required for DISCARD to reach the thin pool)

Reclamation in practice:
  VM deletes large files → fstrim → physical space returned
  Database VACUUM + fstrim → freed DB pages returned to pool
  Without fstrim or discard: space never returned → pool fills even with "empty" volumes
```

---

## 3. Pool Exhaustion: Behavior and Prevention

```
dm-thin pool exhaustion behavior:
  Pool reaches 100% full
  Next write to ANY thin volume → dm-thin cannot allocate new block
  Write returns: -ENOSPC (no space left on device)
  Filesystem sees: write error
  Application sees: I/O error, potential data corruption (partial writes)
  ALL thin volumes simultaneously affected

Critical: even volumes with "available space" fail
  The pool is shared → one volume filling pool hurts all others

dm-thin pool error mode:
  Default ("error"): pool full → all I/O returns error
  Alternative ("queue"): pool full → I/O queued until space available
  
  Use "queue" mode for production (prevents immediate I/O errors):
  dmsetup message /dev/mapper/pool 0 "set_mode queue"

Prevention strategy:
  1. Alert at 70% pool utilization
  2. Alert at 85% pool utilization (urgent)
  3. Automated action at 90%: trigger reclamation (fstrim all volumes)
  4. Emergency action at 95%: stop non-critical workloads, add capacity
  
Monitoring:
  dmsetup status pool_name
  # Shows: used_data_blocks / total_data_blocks
  # Calculate: utilization% = used/total × 100
  
  Automatic monitoring script:
  lvs -o lv_name,data_percent vg_name/pool_name
  # Alert if data_percent > threshold
```

---

## 4. Thin Provisioning Architecture Design

```
Production thin provisioning design checklist:

Metadata device:
  □ Separate physical device from data device (different failure domain)
  □ RAID-1 metadata device (metadata loss = all thin volumes inaccessible)
  □ Size correctly: ~48 bytes per data block allocated
  □ Monitor metadata utilization separately (metadata full = same failure as data full)

Data device:
  □ Set overcommit ratio based on actual usage patterns (measure before setting)
  □ Enable discard passthrough
  □ Configure "queue" error mode (not "error")

Monitoring:
  □ Pool data utilization alert at 70%, 85%, 95%
  □ Pool metadata utilization alert at 70%, 85%
  □ Per-volume utilization monitoring
  □ DISCARD/TRIM activity monitoring (is reclamation working?)

Operations:
  □ Weekly fstrim on all thin volumes (or enable mount discard)
  □ Documented emergency procedure for pool exhaustion
  □ Tested thin snapshot backup and restore procedure
  □ thin_dump backup of metadata (daily) for disaster recovery
```

---

## 5. Self-Check

1. A thin pool at 90% full has 10 thin volumes. One volume starts writing heavily. What happens to the other 9 volumes?
2. A VM deletes 500GB of files. Why might the thin pool not recover that 500GB of space?
3. What is the difference between `mount -o discard` and `fstrim`?
4. Why must the thin pool metadata device be on a separate physical device from the data device?

## 7. Answers

1. When the heavy-writing volume exhausts the remaining 10%, all new block allocations fail. ALL 10 thin volumes (not just the one writing) receive I/O errors on their next write that requires new block allocation. The pool is shared — one volume exhausting it impacts all. This is the most important operational risk of thin provisioning: a single volume can take down all volumes.
2. Deleting files marks LBAs as free in the filesystem, but the thin provisioning layer doesn't know about filesystem-level operations. The physical blocks mapped to those LBAs remain allocated in the thin pool until either: (a) the filesystem issues DISCARD commands for freed LBAs (requires discard mount option or fstrim), or (b) the thin pool receives a DISCARD command via dm-thin DISCARD passthrough. Without explicit DISCARD, the pool never sees the freed space.
3. `mount -o discard`: every `unlink()`/`fallocate(FALLOC_FL_PUNCH_HOLE)` immediately issues a DISCARD to the underlying device. Synchronous, adds latency to every delete operation. `fstrim`: scans the filesystem for free space and issues one or more DISCARD commands for all free regions. Asynchronous (run periodically, e.g., cron). Better for latency-sensitive workloads; `fstrim` is generally preferred for production databases.
4. If metadata and data are on the same physical device: (a) device failure destroys both — data is physically present but unaddressable (metadata maps virtual→physical; without it, data is inaccessible). (b) write I/O to metadata competes with write I/O to data on same device — performance degradation. Separate device: metadata survives data device failure (thin_repair possible), and metadata I/O doesn't contend with data I/O.

---

# Days 12-14: Content-Addressable Storage, Data Reduction Stacking & Week Review

---

# Day 12: Content-Addressable Storage

## Key Content

```
CAS (Content-Addressable Storage): address = hash(content)

Properties:
  Immutable: content never changes (hash would change)
  Deduplicated by definition: same content = same address = stored once
  Verifiable: read address X → hash result → compare to X → detect corruption
  
Git object store (canonical CAS example):
  Every blob, tree, commit: SHA-1 (legacy) or SHA-256 hash of content
  Object path: .git/objects/ab/cdef1234... (first 2 chars = directory)
  No index needed: content address IS the storage location
  Garbage collection: objects not reachable from any ref → orphaned → gc
  
Perkeep (formerly Camlistore):
  CAS for personal data archival
  Chunk content → SHA-224 hash → content address
  "Blob" = one addressable unit
  "Schema blobs" = JSON describing how to reconstruct files from blobs
  GC: mark-and-sweep from root schemas

Venti (Bell Labs, 2002):
  Write-once archival CAS
  SHA-1 content address
  No GC (write-once → no orphans possible)
  Score = content address → look up in Venti server → get data

CAS GC challenge:
  Must track references: which blobs are reachable from live files?
  Mark phase: walk all file metadata → collect referenced content addresses
  Sweep phase: delete any stored blob not in the reachable set
  
  GC pause: during GC, cannot add new objects (would be incorrectly deleted)
  OR: concurrent GC with write barrier (complex)
  
  Production solution: run GC during low-activity windows
  Git: git gc runs periodically, pauses briefly

When to use CAS:
  ✓ Immutable data (backups, archives, content delivery)
  ✓ Deduplication required (same content = same address)
  ✓ Data integrity verification (hash = checksum)
  ✓ Content-based routing (CDNs, P2P networks)
  ✗ Mutable data requiring in-place updates
  ✗ Sequential access patterns (CAS is random-access by nature)
```

---

# Day 13: Data Reduction Stacking — Interaction Effects

## The Correct Pipeline

```
Data reduction must be applied in this order:
  DATA → DEDUP → COMPRESS → ENCRYPT → STORE

Why this order:

Dedup before compress:
  Identical chunks → same fingerprint → single physical chunk
  After compression: identical chunks may compress differently (context-dependent)
  Dedup after compress: may miss duplicates → lower dedup ratio
  
Compress before encrypt:
  Encrypted data is incompressible (high entropy, no patterns)
  Must compress plaintext before encrypting
  Encrypt after compress: ciphertext stored, cannot be further reduced

Never: encrypt before dedup
  Convergent encryption is the only exception (same plaintext → same ciphertext)
  Without convergent encryption: dedup after encrypt = ~1.0× ratio (useless)

Example pipeline for backup system:
  Source data (100TB)
    → Content-defined chunking (CDC)
    → Dedup: 100TB → 10TB (10× ratio for VM backups)
    → Zstd compression: 10TB → 4TB (2.5× ratio)
    → AES-256 encryption: 4TB (no size change)
    → Store: 4TB physical
  
  Total reduction: 100TB → 4TB = 25× reduction
  Note: 10× dedup + 2.5× compress = 25× total (multiplicative, not additive)

Stacking pitfalls:
  Thin provisioning + dedup: ensure TRIM/discard propagates through all layers
  Compression + dedup: if compression creates different output for same input,
    dedup fingerprints won't match (always dedup first)
  Encryption + dedup: must use convergent encryption or dedup before encryption
```

---

# Day 14: Week 2 Review — Data Reduction Architecture

## Decision Matrix

```
For any storage workload → data reduction decisions:

1. Is dedup worth it?
   Check workload type:
   VM images / VDI: YES (10-50× ratio)
   Backup data: YES (10-100× ratio)
   Database primary: MAYBE (measure ratio first, often 1.1-1.3×)
   Video/media: NO (already compressed)
   Encrypted data: NO (use convergent encryption first)
   
   Break-even: dedup_ratio > 1.5× to justify overhead

2. Inline or post-process dedup?
   Latency-sensitive (OLTP, databases): POST-PROCESS
   Write-heavy, latency-tolerant (backup): INLINE acceptable
   Index fits in RAM: INLINE viable
   Index on SSD (latency > 100µs): POST-PROCESS recommended

3. What compression?
   Hot path, latency sensitive: LZ4 (fast decompression)
   Warm path, balanced: Zstd level 3
   Cold/archival: Zstd level 9 or LZMA
   Already compressed data: SKIP (detect and bypass)

4. Chunk size for dedup?
   Backup workloads: 4-16KB (maximize ratio)
   Primary storage (VMs): 8-64KB (balance ratio vs metadata overhead)
   Object storage: 256KB-4MB (reduce metadata, tolerate lower ratio)

5. Thin provisioning overcommit ratio?
   Production databases: 1.5:1 (conservative)
   Mixed workloads with monitoring: 2-3:1
   Dev/test with auto-alerts: 3-5:1
   Never without monitoring and emergency procedures
```

## Design Scenario: Backup System for 1PB Dataset

**Brief:** Daily backups of 1000 VMs, 1TB average provisioned per VM.
Most VMs share common OS base (Ubuntu 22.04).
5% of data changes per day.
Retain 30 daily backups.
Storage budget: 200TB NVMe.

**Analysis:**
- Naive storage: 1000TB × 30 days = 30PB (impossible in budget)
- With dedup (VM images): ratio ~40× (95% similar to template)
  - Day 1 full backup: 1000TB / 40× = 25TB stored
  - Each subsequent day: only 5% changed = 50TB new data / 40× = 1.25TB
  - 30 days: 25TB + 29 × 1.25TB = 61.25TB
- With Zstd compression (after dedup): 2.5× ratio → 61.25TB / 2.5 = 24.5TB
- **Total physical: ~25TB** (fits in 200TB budget with huge margin)

**Architecture:**
- CDC chunking (4KB chunks for max dedup ratio)
- Post-process dedup (no write latency impact)
- Inline compression (LZ4 during backup window is acceptable — not latency-sensitive)
- SHA-256 fingerprints → index stored on NVMe (fast lookup)
- Pipeline: data → dedup → LZ4 compress → AES-256 encrypt → store

---

## Tomorrow: Day 15 — Chaos Engineering for Storage

Week 3 begins: reliability engineering. We design the chaos engineering
methodology for storage systems — how to systematically break things
to find weaknesses before production does.
