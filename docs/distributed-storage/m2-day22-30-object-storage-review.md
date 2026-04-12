# Month 2 Days 22–30: Object Storage Architecture & Final Review

---

# Day 22: Ceph RADOS Deep Dive

## Learning Objectives
- Understand RADOS: the distributed object store underlying all Ceph services
- Follow a write from client to committed object on all replicas
- Understand PG (Placement Group) state machine and peering
- Know exactly what happens during OSD failure and recovery

---

## 1. RADOS Architecture

```
Ceph services and their RADOS relationship:
  RBD (block): stores image as RADOS objects (default 4MB each)
  CephFS: stores file data and metadata as RADOS objects
  RGW (object): stores S3/Swift objects as RADOS objects

RADOS provides:
  Strongly consistent object store
  Automatic data distribution (CRUSH)
  Self-healing (automatic repair on failure)
  Scalability: add OSDs, CRUSH redistributes

Key concepts:
  Object: named byte sequence, operations: read/write/delete/xattr
  Pool: namespace for objects with shared replication/EC policy
  PG (Placement Group): unit of distribution
    Each pool divided into N PGs (default 64-4096)
    Each PG mapped to a set of OSDs (via CRUSH)
    Each OSD may host hundreds of PGs
  OSD: one process per physical drive (or partition)
```

---

## 2. Write Path: Client to Committed Object

```
Client write to object "foo" in pool "mypool":

1. Client computes PG:
   pg_id = hash("foo") % num_pgs
   osd_set = CRUSH(pg_id, cluster_map, pool_rule)
   primary = osd_set[0]

2. Client sends write to PRIMARY OSD:
   Message: CEPH_MSG_OSD_OP (write, object, offset, data)

3. Primary OSD (src/osd/PrimaryLogPG.cc):
   a. Check PG state (must be "active+clean" or similar)
   b. Write to local ObjectStore (BlueStore)
   c. Send replication messages to replica OSDs in parallel
   d. Wait for all replicas to ack
   e. Send ack to client

4. Replica OSDs:
   Receive replication message
   Write to local ObjectStore
   Send ack to primary

5. Primary receives all acks:
   Mark operation as committed
   Send final ack to client

Consistency: write is committed ONLY after ALL replicas ack
  Primary-copy replication: linearizable at PG level
```

---

## 3. PG State Machine

```
PG states (relevant subset):
  creating:       PG is being created (new pool)
  peering:        OSDs in PG are exchanging state to establish authoritative log
  active+clean:   normal, all replicas have all objects, ready for I/O
  active+degraded: some replicas missing, I/O continues but not all copies exist
  active+recovering: background recovery copying missing data
  active+backfilling: a new OSD is receiving all PG data (full backfill)
  stale:          PG primary not heard from — PG stuck
  down:           insufficient OSDs to be active (below min_size)

Peering: the process of OSDs agreeing on authoritative log for a PG
  Triggered by: OSD joining, OSD leaving, OSD crash
  Steps:
    1. New primary sends GetInfo to all OSDs in PG history
    2. OSDs respond with pg_info (epoch, last_update, log entries)
    3. Primary selects authoritative log (most recent complete log)
    4. Primary sends GetLog to OSDs with shorter logs
    5. OSDs replay missing log entries → converge to same state
    6. PG transitions to active+clean
```

---

## 4. OSD Failure and Recovery

```
OSD.5 fails:

1. OSDs detect failure:
   Heartbeat timeout → OSD.5 marked "down" in OSD map
   Monitor broadcasts new OSD map (epoch incremented)

2. PGs affected by OSD.5 begin peering:
   For each PG where OSD.5 was primary: another OSD takes over as primary
   For each PG where OSD.5 was replica: primary detects missing replica

3. Active+degraded:
   PG operates with fewer replicas
   Writes still accepted (replication factor temporarily reduced)
   Data is at risk until recovery completes

4. Recovery begins:
   Primary reads objects from surviving replicas
   Copies to new replica (replacement OSD or surviving OSD)
   Recovery rate: controlled by osd_recovery_op_priority
   
5. Scrub (background integrity check):
   Primary reads all objects in PG, checksums them
   Compares with replicas
   Repairs any bitrot detected
   Deep scrub: reads all data from disk (not just metadata)

Monitor watches recovery:
  ceph health detail — shows recovering PGs
  ceph pg stat — shows PG state distribution
  ceph osd df — shows per-OSD utilization
```

---

## 5. Hands-On: PG Observation

```bash
# Watch PG state distribution
watch -n1 "ceph pg stat"

# Detailed PG state
ceph pg dump | head -20

# Simulate OSD failure
ceph osd out osd.3    # mark out (start rebalancing)
ceph osd down osd.3   # mark down (trigger peering)

# Watch recovery
watch -n1 "ceph health detail"
watch -n1 "ceph pg stat"

# Check specific PG state
ceph pg 1.a query     # detailed state of PG 1.a

# Recovery speed tuning
ceph tell 'osd.*' injectargs '--osd-recovery-max-active 5'
ceph tell 'osd.*' injectargs '--osd-max-backfills 2'

# Re-add OSD
ceph osd in osd.3
```

---

## 6. Self-Check

1. How many OSDs must fail simultaneously to cause data loss in a 3-replica Ceph cluster?
2. What is PG peering and when is it triggered?
3. A PG is in "active+degraded" state. Can clients still write to objects in this PG?
4. CRUSH places a PG on {osd.1, osd.3, osd.7}. osd.3 fails. Which OSD becomes the new primary?

## 7. Answers

1. All 3 replicas of any PG must fail simultaneously. Since each PG is distributed across different OSDs (via CRUSH failure domain rules), 3 simultaneous OSD failures in different failure domains would be needed. With rack-aware CRUSH: losing 3 OSDs in 3 different racks simultaneously. In practice: the probability decreases dramatically with proper failure domain configuration.
2. Peering is the process where OSDs in a PG exchange their log history to agree on an authoritative state — which objects exist, which are up-to-date, and which need recovery. Triggered when: any OSD in the PG joins or leaves (OSD crash, restart, network partition, new OSD added).
3. Yes — "active+degraded" means the PG is active (accepts I/O) but degraded (fewer than the target replica count). Writes are accepted and replicated to the surviving replicas. The data is at risk (fewer copies than desired) until recovery completes, but I/O continues. The cluster operates at reduced durability temporarily.
4. OSD primary selection: Ceph uses the first OSD in the acting set. If osd.3 was primary (first in CRUSH output), osd.1 or osd.7 takes over. Specifically: during peering, the new acting primary is determined by the monitor — typically the next OSD in the sorted acting set. After osd.3 fails, the new acting set is {osd.1, osd.7}, and osd.1 (lowest ID) becomes primary.

---

# Day 23: Ceph BlueStore Internals

## Learning Objectives
- Understand why BlueStore replaced FileStore
- Follow BlueStore's two-stage write path (WAL + deferred write)
- Understand RocksDB's role in BlueStore metadata
- Know BlueStore's checksum and per-block integrity model

---

## 1. Why FileStore Failed (and BlueStore Was Built)

```
FileStore (original Ceph OSD storage backend):
  Stored objects as files on a local filesystem (XFS, ext4, btrfs)
  Journal: separate journal device for crash consistency
  
FileStore problems:
  Double write penalty:
    Write → journal (for crash safety) → journal replay → filesystem
    Every write written twice
  
  Metadata overhead:
    OS filesystem metadata (inodes, dentries) for every Ceph object
    At billions of small objects: excessive inode usage, slow directory listing
  
  No inline checksum:
    Filesystem doesn't checksum data — silent corruption undetectable
  
  Journal dependency:
    Journal device becomes bottleneck; full journal → stall

BlueStore solution:
  Raw block device: bypass filesystem entirely (like database on raw device)
  RocksDB: key-value store for ALL metadata (object→data mapping, omap, attrs)
  WAL: small WAL device (NVMe) for low-latency metadata writes
  No double write: data written directly to block device, no journal copy
  Per-block checksums: every 4KB or 64KB block has checksum stored in RocksDB
```

---

## 2. BlueStore Write Path

```
Object write "foo" at offset 0, length 4MB:

Case 1: Overwrite existing data (in-place)
  1. Compute new checksum for data
  2. Write new checksum to RocksDB WAL (small, fast)
  3. Write data to block device at existing allocation
  4. RocksDB WAL commit → checksum committed
  
  Issue: write data + write checksum are not atomic
  If crash between data write and checksum commit:
    Old checksum in RocksDB, new data on disk → checksum mismatch detected
    BlueStore knows write was incomplete → recovery

Case 2: New allocation (no existing data)
  1. Allocate new blocks (Allocator: bitmap or stupid allocator)
  2. Write data to newly allocated blocks
  3. Write metadata to RocksDB: object → new block mapping + checksum
  4. RocksDB WAL commit → both mapping and checksum committed atomically
  
  Atomicity: RocksDB commit is atomic → mapping and checksum always consistent

Deferred write (small writes):
  For writes that don't align to block boundaries:
  1. Write small data to RocksDB WAL (as value) — avoids read-modify-write
  2. RocksDB commits → data durable in WAL
  3. Background: "deferred" worker copies from WAL to actual block location
  4. Delete WAL entry after successful copy
  
  Benefit: small writes avoid slow read-modify-write of large blocks
  Cost: small writes written twice (WAL + block device)
```

---

## 3. RocksDB in BlueStore

```
BlueStore uses RocksDB for:
  Object metadata: onode (object → block mapping, size, attrs, checksums)
  omap: per-object key-value store (used by CephFS, RBD for metadata)
  Allocation: free block bitmap (some versions)
  Write-ahead log: small writes buffered before going to block device

RocksDB placement (performance critical):
  WAL device: fastest storage (NVMe), stores RocksDB WAL
  DB device: fast storage (NVMe SSD), stores RocksDB SST files
  Slow device: HDD, stores actual object data

Production BlueStore layout:
  /dev/nvme0n1: BlueStore WAL + RocksDB DB (fast metadata)
  /dev/sda:     BlueStore data (object content)
  
  ceph-osd --bluestore-block-db-path /dev/nvme0n1
           --bluestore-block-wal-path /dev/nvme0n1p2
           --bluestore-block-path /dev/sda
```

---

## 4. Per-Block Checksums

```
BlueStore checksums every data block:
  Default: crc32c per 64KB block (configurable: 4KB to 512KB)
  Checksum stored in RocksDB alongside block metadata

On read:
  1. Read block from disk
  2. Compute crc32c
  3. Compare with stored checksum in RocksDB
  4. If mismatch: return I/O error (don't serve corrupt data)
  5. Scrub: reads all blocks and verifies checksums → detects bitrot

This is the key BlueStore advantage over FileStore:
  Detects silent disk corruption (bitrot) automatically
  Can compare checksums between replicas → identify which is corrupt
  Repair: read from good replica → write to corrupt replica
```

---

## 5. Self-Check

1. Why does BlueStore avoid the "double write" problem that FileStore had?
2. What is a "deferred write" in BlueStore and when is it used?
3. BlueStore stores checksums in RocksDB, not alongside data on disk. What advantage does this have?

## 6. Answers

1. FileStore wrote to a journal first, then replayed to the filesystem — every write went to disk twice. BlueStore writes data directly to the raw block device once. Metadata (checksums, block mappings) goes to RocksDB, but data itself is written only once to its final location (except deferred writes for small unaligned I/O).
2. A deferred write is used for small writes that don't align to block boundaries (would require read-modify-write if written directly). Instead of reading the full block, modifying, and writing it back, BlueStore stores the small write as a value in RocksDB WAL. A background "deferred" worker later copies it to the correct block position. This trades one extra copy for avoiding the expensive read-modify-write cycle.
3. Storing checksums in RocksDB (alongside metadata) rather than inline on disk provides two advantages: (a) atomic consistency — the block mapping and its checksum are committed atomically in one RocksDB transaction, so they're always in sync; (b) no extra seek — the checksum is read with the metadata before reading the data block, allowing early detection of metadata corruption before doing the data I/O.

---

# Day 24: MinIO & Erasure Set Architecture

## Key Content

```
MinIO architecture:
  Distributed mode: N servers, each with M drives = N×M drives total
  Erasure set: a fixed subset of drives that form one RS erasure group
    Default erasure set size: automatically calculated (8 or 16 drives)
    Each erasure set is independent: different objects on different sets
  
  Object placement:
    Object → hash → erasure set → write k+m shards (one per drive in set)
    Read: contact any k drives in the erasure set
  
  vs Ceph:
    Ceph: PG model, objects distributed across all OSDs via CRUSH
    MinIO: erasure set model, objects assigned to one erasure set
    Ceph: better failure domain control (CRUSH rules)
    MinIO: simpler, faster single-operator deployment

MinIO healing:
  Continuous healing scanner: checks object integrity in background
  Healing trigger: drive failure, drive replacement, missing shards
  Healing process:
    1. Scan all objects in erasure set
    2. For each object: read surviving shards, reconstruct missing ones
    3. Write reconstructed shards to replacement drive

MinIO versioning:
  Object versioning: each PUT creates a new version
  Storage: each version stored as separate erasure-coded object
  Overhead: N versions = N × erasure overhead (no delta/incremental storage)
  Delete marker: logical delete (object not actually removed)

Hands-on:
  # 4-node MinIO cluster
  for node in node1 node2 node3 node4; do
      ssh $node "minio server \
          http://node1/data1 http://node2/data1 \
          http://node3/data1 http://node4/data1"
  done

  # Check erasure set info
  mc admin info myminio
  mc admin heal myminio/mybucket --recursive
```

---

# Day 25: SeaweedFS & Haystack-Style Object Storage

## Key Content

```
Facebook Haystack (2010) — the origin of needle-in-haystack design:

Problem at Facebook:
  Billions of photos, many small files (< 1MB)
  Traditional POSIX filesystem: each file = one inode = metadata overhead
  1 billion files × metadata reads = 1 billion disk seeks for cold photos

Haystack solution:
  Volume file: large file (100GB) containing many small objects ("needles")
  Needle format: {magic, cookie, key, alt_key, flags, size, data, checksum}
  Index file: in-memory map from (key, alt_key) → (offset, size) in volume

  Read path:
    1. Look up (key, alt_key) → offset in index (in memory if warm)
    2. Seek to offset in volume file
    3. Read needle header + data
    Result: ONE disk seek per photo (vs many for POSIX)

  Write path:
    Append needle to volume file end
    Update index
    No seek needed for writes (sequential append)

  Delete:
    Mark needle as deleted in index
    Compact volume (copy live needles to new volume) periodically

SeaweedFS (open source Haystack-inspired):
  Master server: assigns volume IDs, manages volume allocation
  Volume servers: store needle data in volume files
  Filer: optional POSIX-like interface (backed by volume servers + metadata store)
  
  Key advantage over Ceph for billions of small objects:
    No PG overhead, no RADOS protocol
    Direct HTTP to volume servers
    Simpler architecture, lower operational complexity
  
  When to choose SeaweedFS vs Ceph:
    SeaweedFS: billions of small objects, simple deployment, S3-compatible needed
    Ceph: need full POSIX (CephFS), RBD block, flexible failure domains, EC support
```

---

# Day 26: Object Storage Metadata at Scale

## Key Content

```
The metadata scalability problem:
  POSIX requires: directory entries, inode attributes, access control
  At 100 billion files: even 1KB per file = 100TB metadata
  Single metadata server: bottleneck for create/stat/list operations

CephFS MDS (Metadata Server) approach:
  Dynamic subtree partitioning:
    Different directories handled by different MDS instances
    Hot directories (many creates) split across more MDS instances
    Cold directories served by single MDS
  
  MDS journal: Raft-based journal for MDS state changes
  Inode cache: MDSs cache inodes; coordinate via locks (MDS Lock protocol)
  
  Scaling limit: subtree partitioning doesn't help for hot single directories
    (e.g., all creates in one directory — single MDS bottleneck)

HopsFS (Hadoop + NewSQL metadata):
  Replaced HDFS NameNode with distributed MySQL Cluster (NDB)
  Metadata stored in relational tables (not in-memory tree)
  Multiple NameNodes query same NDB cluster
  Scales metadata horizontally
  Production at Logical Clocks, used by some Hadoop deployments

When to abandon POSIX:
  Object storage (S3): no directories, no rename atomicity required
    → Scales trivially (metadata = just key → location mapping)
  Flat namespace: keys only, no hierarchy
    → Eliminates directory lock contention entirely
  
  The fundamental lesson: POSIX namespace (stat, rename, list) requires
  sequential consistency for the tree structure. Sequential consistency
  at scale requires coordination. Coordination is expensive.
  
  Most "big data" workloads don't need full POSIX:
    Write-once: no rename needed
    Batch reads: list is done once, not repeatedly
    No hard links, no symlinks, no permissions: S3 semantics sufficient

Design principle: if you have > 10 billion objects, reconsider POSIX.
```

---

# Day 27: Distributed Storage Benchmarking

## The Correct Methodology

```
Common benchmarking mistakes:
  1. Not warming up: first run fills cache → misleading results
  2. Not running long enough: misses GC/compaction effects (minutes, not seconds)
  3. Measuring throughput without measuring latency: hides p99 problems
  4. Single client: doesn't expose coordination bottlenecks
  5. Using filesystem cache: measures DRAM speed not storage speed
  6. Not controlling fill rate: measuring at 10% full vs 90% full gives different results

Correct methodology:
  1. Fill to target percentage (70-80%) before measuring
  2. Warm run: 5 minutes minimum, throw away results
  3. Measurement run: 10-30 minutes (must be long enough for GC cycles)
  4. Multiple percentile points: p50, p99, p99.9 (not just average)
  5. Multiple clients: at least as many as expected in production
  6. Steady state: verify GC/compaction not still in progress

Tools:
  fio: block device and filesystem benchmarking (most configurable)
  COSbench: object storage (S3/Swift) benchmarking (multi-client)
  s3-benchmark: simple S3 load generator
  warp (MinIO): purpose-built MinIO benchmark
  cosbench: Apache benchmark for cloud object storage

Key metrics to collect:
  Throughput: MB/s or IOPS
  Latency: p50, p99, p99.9 (NOT average)
  CPU: per-node CPU utilization during test
  Network: bytes sent/received per node
  Disk: iostat for each drive (utilization, await)

Isolating bottlenecks:
  CPU-bound: CPU at 100%, storage not saturated
    → Optimize codec, reduce protocol overhead, more cores
  Network-bound: network at 100%, CPU not saturated
    → Add network, reduce data size, compression
  Storage-bound: disk at 100%, CPU/network below limit
    → More drives, faster drives, better caching
  Metadata-bound: high latency even at low throughput
    → Metadata server bottleneck, check MDS/NameNode CPU
```

---

# Day 28: Capacity Planning & Cost Modeling

## The Write Amplification Stack

```
Total WA = WA_application × WA_filesystem × WA_EC × WA_FTL

Example: PostgreSQL on ext4 on RS(4,2) on SSD

WA_application (PostgreSQL):
  OLTP: writes page + WAL + checkpoint = ~3× amplification
  (1 user write → 1 WAL entry + 1 data page write + 1 checkpoint write)

WA_filesystem (ext4, data=ordered):
  Journal metadata: +5-15% overhead
  WA_filesystem ≈ 1.1

WA_EC (RS(4,2)):
  Every user byte → 1.5× storage (6 shards for 4 data shards)
  But: write amplification for repair = 4× (must read 4 shards to repair 1)
  Effective WA for repairs: 4× (amortized over life of drive)
  Daily WA: 1.5× (just the erasure coding storage overhead per write)

WA_FTL (NVMe SSD, enterprise):
  Enterprise SSD with 10-20% over-provisioning: WA ≈ 1.2-2.0
  Depends on write pattern (sequential=low WA, random=high WA)

Total daily WA (PostgreSQL + ext4 + RS(4,2) + enterprise SSD):
  3 × 1.1 × 1.5 × 1.5 = ~7.4×
  1TB of user data per day → 7.4TB written to NAND

SSD endurance check:
  Drive: 1TB NVMe, TBW rating = 600TB lifetime writes
  At 7.4TB/day NAND writes: 600 / 7.4 = 81 days? No — too low.
  Check: is 7.4TB/day of NAND writes realistic for 1TB of user data?
  1TB user data/day × 3 (app WA) × 1.5 (EC) = 4.5TB actual data written
  4.5TB / 1TB drive capacity = 4.5 DWPD (Drive Writes Per Day)
  Enterprise NVMe rated 3-10 DWPD → borderline, check drive spec
```

---

## Cost Modeling Template

```
For a 5-year storage system lifecycle:

Year 1 hardware cost:
  Raw capacity needed = user data / (1 - overhead)
  overhead = EC overhead + OS overhead + 20% headroom
  
  Example: 1PB user data, RS(4,2), 20% headroom
  Raw needed = 1PB / (1 - 0.5 - 0.05 - 0.2) = 1PB / 0.25 = 4PB raw
  At $100/TB NVMe: 4000TB × $100 = $400K hardware
  
  + Servers (2U, 24× NVMe each): 4PB / (24 × 8TB) = ~21 servers
  + Network (25GbE): 21 servers × $500 NIC = $10.5K
  + Power: 21 servers × 500W × $0.10/kWh × 8760h/yr = $9.2K/yr

5-year TCO:
  Year 1: $400K HW + $9.2K power = $409K
  Year 2-5: $9.2K/yr power + $40K/yr staff (part-time ops) = $49.2K/yr
  Total 5-year: $409K + 4 × $49.2K = $606K
  
  Per-TB-year: $606K / (1PB × 5yr) = $0.12/GB/year
  Compare to S3: ~$0.023/GB/month = $0.276/GB/year
  On-premises is ~2.3× cheaper at this scale
  (S3 advantages: no ops cost, elastic, no upfront capital)
```

---

# Day 29: Failure Domain Analysis

## MTTDL Calculation

```
MTTDL (Mean Time to Data Loss):
  The expected time before losing data permanently.

For 3-way replication (RF=3), independent failures:
  MTTF_drive = 100,000 hours (typical HDD)
  MTTDL calculation:
    Need 3 simultaneous failures in same PG
    MTTDL = MTTF^3 / (N_PG × MTTR × MTTR)
    where MTTR = time to recover one failed replica
    
    With 1hr MTTR: MTTDL >> age of universe for small clusters
    With 24hr MTTR: still astronomically long for most clusters
  
  Key insight: MTTDL is dominated by MTTR, not MTTF
  Faster recovery → exponentially longer MTTDL
  Slow recovery (backfill rate throttled) → much higher data loss risk

Gray failures (partial failures):
  "Finding the Gray Failures in Large Distributed Systems" key insights:
  
  Hard failure: drive completely dead → easy to detect, quick to recover
  
  Gray failure: drive intermittently returns errors, or is slow (1000ms reads)
    → Harder to detect (not completely dead)
    → May silently affect data quality (corrupted reads not detected without checksums)
    → Ceph scrub detects gray failures via checksum comparison
    → Systems without checksums (ext4, XFS) can silently accumulate corruption

  Gray failure examples:
    Bit rot: aging drive bit flips (detected by checksum)
    Slow drive: affects latency p99 for all PGs using that drive
    Network gray failure: occasional packet loss → TCP retransmits → latency spikes
    Memory gray failure: ECC correctable errors → system continues but degraded

Correlated failures:
  Power domain: all drives in one rack fail (PDU failure)
  Network domain: all drives behind one switch fail (switch failure)
  Firmware bug: all drives of same model fail simultaneously
  
  CRUSH rules must account for correlated failure domains:
    failure-domain=rack: PG never places two replicas in same rack
    failure-domain=datacenter: PG spans DCs (most durable, highest network cost)
  
  Real-world example: AWS S3 June 2008 outage
    Correlated failure of multiple availability zones in one region
    Highlighted need for geographic separation beyond datacenter-level
```

---

# Day 30: Final Review & Month 3 Roadmap

## Full Distributed Storage Competency Check

You should answer these without notes:

**Consensus:**
- Raft: what makes a log entry "committed"? What can a new leader not commit?
- Pre-vote: what problem does it solve and how?
- Zab vs Raft: one concrete protocol difference

**Erasure Coding:**
- RS(4,2) repair: how much data read to repair one shard?
- LRC: why does it reduce repair traffic for single failures?
- GF(2^8): why is it used instead of regular arithmetic?

**Placement:**
- CRUSH: what does it need to compute placement? What doesn't it need?
- Virtual nodes: why do they improve load balance?
- Data movement on adding 1 node to 100-node consistent hash cluster?

**Protocols:**
- iSCSI Error Recovery Level 2 vs Level 0: what survives Level 2?
- NFSv4 delegation: what does it enable and how is it revoked?
- When choose NVMe-oF/TCP over RDMA?

**Object Storage:**
- Ceph RADOS: PG peering — what does it establish?
- BlueStore: why no double write vs FileStore?
- MinIO erasure set: how does it differ from Ceph's PG model?

---

## Final Design Scenario: Global Object Store

**Brief:** Design a globally distributed object store:
- 5 regions (US-East, US-West, EU-West, Asia-Pacific, South America)
- 11 nines durability (99.999999999%)
- < 100ms read latency globally
- Cost-optimized (minimize storage overhead)
- Expected: 100PB total, growing 30% annually

**Key decisions required:**
1. EC scheme (balance durability, repair traffic, overhead)
2. Replication across regions (how many copies in how many regions)
3. Consistency model (strong vs eventual — tradeoff with latency)
4. Metadata architecture (where is object→location mapping stored?)
5. Failure domain analysis (what scenarios lose data? calculate probability)

---

## Reference Answer

**1. EC Scheme:** RS(6,3) within each region. 6 data + 3 parity = 1.5× overhead per region. Tolerates 3 simultaneous drive failures within a region.

**2. Cross-region replication:** 3 regions out of 5 store each object (erasure replicated across regions). Cross-region RS(3,2): 3 regions = data, 2 regions = parity (5 total). Any 3 regions available → full object recovery. Combined durability: drive failure (RS(6,3)) AND regional failure (RS(3,2)) modeled independently → 11 nines achievable with standard MTTF assumptions.

**3. Consistency:** Eventual consistency within a region for cross-region reads; strong consistency within a region. Trade-off: strong global consistency requires synchronous cross-region write (latency = max RTT between regions ≈ 150-200ms) — violates <100ms read. Solution: reads served from nearest region (eventual), writes acknowledged after local region commit (strong locally, eventually propagates). Use read-your-writes via sticky sessions or client-side write tokens.

**4. Metadata:** Distributed metadata service per region (etcd cluster per region). Object metadata stored in local region's etcd. Cross-region metadata: lazy replication (object is readable from local region immediately after write). A global metadata index (like S3's approach) handles cross-region discovery. Trade-off: global linearizable metadata = high latency; regional metadata = fast but needs eventual sync.

**5. Failure analysis:** 11 nines = MTTDL = 10^11 hours / expected_objects. At 100PB with 100KB average object size = 10^9 objects. With RS(6,3) within region + RS(3,2) across regions: must lose 3 drives in a region AND 2 entire regions simultaneously for data loss. Probability over 1 year: [P(3 drives fail in 1 hour)]^2 × P(2 regions fail in 1 month) ≈ effectively 0 for well-operated infrastructure. 11 nines is achievable.

---

## Month 3 Roadmap: Storage Hardware Physics + SPDK

Month 3 focuses on the two remaining gaps:

**Week 1-2: NAND Flash Physics**
- SLC/MLC/TLC/QLC cell physics: voltage levels, P/E cycles
- FTL internals: mapping table, GC algorithm, wear leveling
- Why different SSDs have different sustained write performance
- NVMe controller design: internal queues, DRAM cache, capacitors

**Week 3-4: SPDK (Storage Performance Development Kit)**
- User-space NVMe driver: how VFIO enables kernel bypass
- SPDK blobstore: user-space block storage abstraction
- SPDK NVMe-oF target: high-performance user-space target
- When SPDK beats io_uring and when it doesn't
- DPDK memory model: hugepages, lock-free rings

**Key references for Month 3:**
- NAND Flash Memory Technologies (Micron technical documentation)
- "The Unwritten Contract of Solid State Drives" (USENIX 2017)
- SPDK documentation: spdk.io/doc
- "SPDK: A Development Kit for High-performance Storage" (Intel)
- NVMe specification: nvmexpress.org
