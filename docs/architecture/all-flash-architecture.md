# All-Flash Storage Architecture — Architect's Reference

**Audience:** Senior storage architect
**Context:** Why BlueStore is not all-flash native, Ceph's evolution toward it (Crimson/Seastore), projects designed ground-up for all-flash (DAOS, WekaFS, VAST), and what architects must design for under all-flash constraints
**Related:** architecture/io-latency-cost-model.md, L2-distributed/systems/, L3-cluster-scheduling/

---

## Why All-Flash Demands a Different Architecture

HDD-era storage design made one foundational assumption: **random I/O is catastrophically expensive** (4–8ms seek + rotational latency). Every architectural decision optimized around this:
- Convert random writes to sequential (journaling, WAL, log-structured)
- Coalesce small writes into large ones (write combining, buffering)
- Large block sizes to amortize seek overhead
- Prefetch aggressively to hide latency
- Minimize seek counts above all else

NVMe flash breaks every one of these assumptions:
- Random I/O = sequential I/O in latency (no seek, no rotation)
- Device latency = 20–70µs, not 4–8ms (100–400× faster)
- Software overhead (syscall, context switch, lock) = 10–40% of device latency (was 0.01%)
- Endurance is finite: every write consumes TBW budget
- Write amplification is the new enemy — not seek count

**The consequence**: architectures designed for HDD add write amplification (WA) and software overhead that are invisible at HDD latencies but dominate at NVMe latencies. A 5× WA from journaling adds ~50ms to an HDD write (fine). The same 5× WA on NVMe means 5× shorter SSD life and 5× higher write I/O load on the device.

---

## Part 1: Why BlueStore Is Not All-Flash Native

BlueStore (2016) was a major improvement over FileStore — it replaced the POSIX filesystem layer with direct block device management. But it was designed with HDD-backed Ceph clusters as the primary target. Several structural decisions create problems at NVMe speed.

### Problem 1 — RocksDB as Metadata Store: Write Amplification Compounding

BlueStore uses RocksDB (LSM-tree) for all object metadata: checksums, extent mappings, allocation bitmaps, onode (object inode). Every user write generates multiple RocksDB writes:

```
User write (1 object) →
  RocksDB WAL write          (1 write)
  RocksDB MemTable flush     (1 write, when MemTable full)
  RocksDB L0 → L1 compaction (2–4 reads + writes per key)
  RocksDB L1 → L2 compaction (10–30 reads + writes per key at steady state)
```

RocksDB write amplification alone: **5–30×** depending on compaction settings and key update rate. This compounds with NAND-internal GC write amplification (1.5–5×):

```
Total WA = App WA × BlueStore WAL WA × RocksDB WA × NAND GC WA
         = 1      × 2                × 10           × 3
         = 60× physical writes per logical write (worst case)
```

At 3 DWPD (Drive Writes Per Day) rated NVMe and 60× WA: effective user write rate before endurance exhaustion = 3/60 = 0.05 DWPD. A drive rated for 3 years at 3 DWPD wears out in 18 days at sustained max user writes.

**Root cause**: LSM-tree (RocksDB) is optimized to convert random writes to sequential — the right tool for HDD. For NVMe, random writes are not expensive; the compaction WA is the problem.

### Problem 2 — Single RocksDB Sync Thread Bottleneck

BlueStore has a single thread responsible for syncing metadata to RocksDB. On NVMe, the device is fast enough to expose this as a serialization bottleneck. The sync thread becomes the latency-limiting path for small random write workloads — a classic single-threaded bottleneck that only appears when the device is fast enough to reveal it.

### Problem 3 — Double-Write WAL for Small Objects

For writes smaller than `min_alloc_size` (default 64KB HDD, 32KB SSD), BlueStore uses a deferred write path:

```
Small write path:
  1. Write data to BlueStore WAL (sequential, on NVMe)
  2. Acknowledge to client
  3. Background: copy from WAL to final location (random, on NVMe)
  → 2 writes per user write = 2× WA just from WAL
```

For HDD: this converts one random write into two sequential writes — a win. For NVMe: random writes are not expensive, so you are paying 2× WA with no benefit.

### Problem 4 — Thread-Per-Request Classic OSD Model

The classic OSD threading model: messenger worker → message queue → PG worker → ObjectStore → transaction commit → reply queue → messenger. Each hop involves lock acquisition, queue push/pop, and potentially a context switch.

At HDD latency (5ms): ~50µs of thread overhead = 1% of total latency.
At NVMe latency (50µs): ~50µs of thread overhead = 100% of total latency.

The software stack is now as slow as the device.

### Problem 5 — min_alloc_size Misalignment with Flash Geometry

NVMe NAND organizes data into erase blocks (typically 4MB–16MB for 3D TLC, larger for QLC). The `min_alloc_size` in BlueStore determines allocation granularity. If min_alloc_size (32KB) is much smaller than the NAND erase block, internal fragmentation in the device FTL increases GC write amplification.

For optimal flash utilization, allocation granularity should match or exceed the FTL GC unit — but this is device-specific and not automatically tunable in BlueStore.

---

## Part 2: Ceph's Development Path Toward All-Flash

### Phase 1 — BlueStore Optimization (2018–2022)

Stop-gap tunings for NVMe deployments without architectural change:

| Tuning | Default → NVMe-tuned | Effect |
|--------|---------------------|--------|
| `min_alloc_size` | 64KB → 32KB | Reduce internal fragmentation |
| `bluestore_rocksdb_options` compaction | Default → tuned | Reduce RocksDB WA |
| RocksDB on separate NVMe | Same device → dedicated NVMe | Isolate metadata I/O |
| WAL on separate NVMe | Same device → dedicated NVMe | Reduce WAL latency |
| `bluestore_cache_size` | 1GB → 4–8GB | Reduce RocksDB read I/O |
| `osd_op_num_threads_per_shard` | Default → increase | More parallelism |

These improve performance 20–50% on NVMe but do not address the fundamental WA or thread model problems.

### Phase 2 — Crimson OSD Project (2019–present)

Complete rewrite of the OSD using Seastar (C++ async framework):

**Core architectural change: shared-nothing, run-to-completion**

```
Classic OSD:
  messenger thread → lock → PG queue → lock → worker thread → lock → ObjectStore
  Every hop: lock acquisition + potential context switch

Crimson OSD:
  All I/O for a PG runs on one shard (one CPU core)
  No cross-shard locking for I/O path
  No context switches within I/O handling
  Futures/continuations: cooperative async within one thread
```

**Seastar reactor model**:
- One pinned thread per CPU core (NUMA-aware)
- Each thread handles a subset of PGs (shard ownership)
- I/O: io_uring or SPDK (no blocking, no context switch)
- Memory: NUMA-local allocation, lockless per-core allocators
- Inter-shard: message-passing only (no shared mutable state)

**AlienStore bridge**: Crimson can run BlueStore as a backend via the AlienStore adapter (proxies Seastar async calls to BlueStore's blocking API). This allows testing Crimson's OSD layer before Seastore is production-ready.

**Performance (2025, August benchmarks)**:
- Random read 4K: Crimson+Seastore 400K IOPS vs Classic 130K IOPS (~3×)
- Random write 4K: Crimson+Seastore ~71K IOPS vs Classic 104K IOPS (active optimization)
- Sequential read/write 64K: comparable (within 10%)

**Status**: Tech preview as of 2025. Not production-ready. Random write regression under active work.

### Phase 3 — Seastore: Native All-Flash Object Store (2020–present)

Seastore replaces RocksDB and BlueStore's block allocator with a design built around NVMe flash geometry.

**Fundamental design principle**: all writes are sequential. Never overwrite in place.

**Segment-based allocation**:
```
NVMe device → divided into segments (100MB–10GB each)
Each shard streams writes to its own set of open segments
Segments written sequentially (append-only)
When segment fills → seal it, open new segment
Sealed segments persist until GC
```

This aligns with flash erase block geometry. The host-level segment GC eliminates most of the need for device-level FTL GC — the device sees predominantly sequential writes, which is optimal for NAND.

**Transaction + journal model**:
```
Each write transaction:
  1. New data blocks (appended to open segment)
  2. B-tree deltas (compact key insertions/removals, not full node rewrites)
  3. Both written sequentially to the segment journal
```

Key difference from BlueStore: instead of persisting full B-tree nodes to RocksDB, Seastore stores **compact deltas** inline in the segment journal. The in-memory B-tree is reconstructed from journal replay on recovery. When a segment nears capacity, dirty in-memory B-tree blocks are flushed proportionally — no compaction storm.

**Garbage collection (cleaner)**:
```
Segments accumulate dead data as objects are updated/deleted
Cleaner: small amount of cleaning work mixed into every write transaction
         (no dedicated GC thread, no latency spike)
When segment is 100% dead → free it for reuse
```

This avoids the compaction-induced latency spikes that RocksDB's compaction creates.

**Per-shard independence**:
Each CPU shard has its own segments. No cross-shard coordination for data writes. This directly enables the Crimson reactor model — each core is truly independent.

**Recovery**:
Crash recovery = replay the currently-open segment. Simple, fast, bounded time (only the last segment needs replay, not the entire journal).

**Seastore vs BlueStore summary**:

| Dimension | BlueStore | Seastore |
|-----------|-----------|---------|
| Metadata store | RocksDB (LSM-tree) | Inline B-tree deltas in segments |
| Write pattern | Overwrite in place + WAL | Always append to segments |
| WA source | RocksDB compaction (5–30×) | GC of dead segments (much lower) |
| Threading | Lock-based worker pools | Per-shard, no cross-shard locks |
| I/O backend | Linux AIO / io_uring | SPDK (user-space) |
| Recovery | WAL replay | Single segment replay |
| Flash alignment | min_alloc_size tuning | Segment size = flash geometry |
| Status | Production | Tech preview (2025) |

---

## Part 3: Projects Designed Ground-Up for All-Flash

### DAOS — Distributed Asynchronous Object Storage

**Origin**: Intel research project (~2015), now community-driven open source. Deployed in world's top supercomputers: Aurora (Argonne NL), LUMI, MareNostrum 5.

**Design mandate**: target SCM (Storage Class Memory / Optane) + NVMe. Treat latency in µs, not ms.

**Architecture**:

```
Compute nodes                Storage nodes (servers)
─────────────                ───────────────────────
DAOS client library          DAOS server (user-space)
  ↕ RDMA (InfiniBand/        ↕ SPDK (NVMe user-space driver)
    RoCE/TCP)                SCM (Optane/NVDIMM)  ← metadata + write buffer
                             NVMe SSDs             ← bulk data capacity
```

**Key architectural decisions**:

1. **Full user-space, zero kernel involvement on data path**
   - SPDK: user-space NVMe driver, no block layer, no VFS
   - libfabric (OFI): user-space network, RDMA-capable
   - No syscall on hot I/O path → eliminates 100–200ns syscall overhead
   - No context switch on data path → eliminates 5–50µs overhead

2. **Two-tier storage per server**
   - SCM tier: all metadata + small object data + write buffer (nanosecond access)
   - NVMe tier: large object data + overflow (microsecond access)
   - A write lands on SCM first (persistent, durable via ADR — Asynchronous DRAM Refresh)
   - Background: drain from SCM to NVMe

3. **Epoch-based transaction model** (no journaling)
   - All updates are epoch-stamped
   - No WAL: SCM is persistent by nature (non-volatile)
   - Crash recovery: replay in-progress epoch, discard incomplete epochs
   - Eliminates double-write overhead entirely

4. **Server-side fault tolerance**
   - Erasure coding: data distributed across servers and targets
   - Rebuild triggered automatically on failure
   - No RAID within a single server — protection is at the distributed layer

5. **Multiple APIs on one namespace**
   - DAOS array API (for HPC simulation data)
   - POSIX file API via `libioil` interception
   - HDF5 native connector (no POSIX)
   - MPI-IO native connector
   - S3-compatible object API

**Performance characteristics**:
- 270+ GB/s aggregate throughput demonstrated on single client
- Sub-10µs latency for small I/O (SCM path)
- Linear scaling: double nodes = double throughput
- Excellent for: AI/ML training data, HPC checkpoint, genomics, financial analytics

**DAOS for AI specifically**:
- Checkpoint: burst write → SCM absorbs burst instantly → drains to NVMe in background. GPU training not stalled waiting for checkpoint flush.
- Training data: POSIX compatible, high IOPS random reads from NVMe pool
- Dataset management: container model (versioned datasets)

### WekaFS (Weka.io)

**Design mandate**: parallel filesystem from scratch for NVMe, replacing Lustre/GPFS in AI and HPC.

**Architecture**:
- DPDK-based: kernel bypass for network and storage
- All-active distributed: every node runs both metadata and data services (no dedicated MDS)
- Metadata distributed by consistent hashing — no single metadata server bottleneck
- Tiered: NVMe (performance tier) ↔ S3/cloud (capacity tier, automatic)
- POSIX-compatible: drop-in for existing HPC applications
- RDMA and NVMe-oF support

**Key difference from Ceph**: WekaFS has no concept of a metadata server — metadata is distributed across all nodes and sharded by consistent hashing, eliminating MDS hot-spots that plague CephFS at scale.

**For AI**: strong story for training data (POSIX + high IOPS), GPUDirect integration.

### VAST Data — DASE Architecture

**Design mandate**: universal storage for all data types on QLC NVMe + NVMe-oF fabric.

**DASE (Disaggregated and Shared Everything)**:
```
CNodes (stateless compute servers)      DNodes (storage servers)
─────────────────────────────────       ──────────────────────────
No local storage                        NVMe SSDs (QLC flash)
Runs: VAST OS, protocol services        SCM write buffer (Optane)
Accesses DNode NVMe via NVMe-oF         Projects NVMe over fabric
```

**Key ideas**:
- CNodes are fully stateless: any CNode can handle any request
- DNodes hold flash, serve it over NVMe-oF to CNodes
- SCM on DNodes = persistent write buffer: absorbs bursts, persists across failures
- QLC flash with aggressive overprovisioning + VAST's GC algorithm: solves QLC endurance

**Insight on QLC**: QLC (4 bits/cell) has 4× lower endurance than MLC (2 bits/cell) but 2–3× lower cost per TB. VAST bet that sophisticated GC + overprovisioning can make QLC viable for enterprise — combining low cost with acceptable endurance through software control of write patterns.

---

## Part 4: What Architects Must Design For Under All-Flash

### 1. Model the Full Write Amplification Stack

Never look at WA at a single layer. The stack multiplies:

```
User write
  × Application WA (journaling, WAL):                    1–3×
  × Storage backend WA (BlueStore deferred write):        1–2×
  × Metadata store WA (RocksDB compaction):               5–30×
  × NAND internal GC WA (depends on OP%):                 1.5–5×
────────────────────────────────────────────────────────────────
Total: 7.5× (best case) to 300× (worst case)
```

**Impact on SSD endurance**:
```
SSD TBW rating = 5PB (typical enterprise 3.84TB NVMe)
At 5× total WA: effective user data written = 1PB before end-of-life
At 50× total WA: effective user data written = 100TB before end-of-life
```

Design target: total WA ≤ 5× for production all-flash. Any design exceeding this is burning through SSD endurance at unsustainable rates.

**Reduction strategies per layer**:

| Layer | WA cause | Mitigation |
|-------|---------|-----------|
| Application | WAL + double write | Group commit, write combining |
| Storage backend | Deferred write path | Eliminate WAL on NVMe (no need — NVMe is fast for random) |
| Metadata | RocksDB LSM compaction | Tune compaction aggressively; use Seastore/DAOS to eliminate RocksDB |
| NAND internal | GC of partially-filled blocks | Overprovisioning 20–30%; ZNS (eliminates device GC); aligned sequential writes |

### 2. Overprovisioning (OP) Is Not Optional

NAND GC WA is a function of how full the device is:

```
OP% = (raw_capacity - usable_capacity) / raw_capacity

At OP=0%  (100% full):   GC WA → ∞ (device stalls cleaning)
At OP=7%  (93% full):    GC WA ≈ 3–5× (consumer grade default)
At OP=20% (80% full):    GC WA ≈ 1.5–2×
At OP=28% (72% full):    GC WA ≈ 1.2–1.5× (enterprise target)
```

**Architect rule**: plan for 20–30% OP on all NVMe in an all-flash cluster. This means your usable capacity is 70–80% of raw. Model this in your TCO from day one — it is not recoverable after deployment.

### 3. ZNS — Eliminate Device-Level GC

Zoned Namespace (ZNS) NVMe SSDs expose the flash's zone structure to the host:
- Each zone = one erase unit (typically 512MB–2GB)
- Zones must be written sequentially (no random overwrite within a zone)
- Host controls when to reset (erase) a zone

**Effect**: the device FTL GC is eliminated. Host software GC takes its place.

```
Traditional NVMe:  FTL manages GC internally → unpredictable WA, latency spikes
ZNS NVMe:          Host controls zone writes → deterministic WA, no surprise GC spikes
```

**Seastore's segment model maps naturally to ZNS**: Seastore already writes sequentially to segments. A ZNS device where each zone = one Seastore segment is a perfect fit — no device-level GC at all, Seastore's cleaner handles all reclamation.

**RocksDB ZenFS**: a ZNS-aware storage backend plugin for RocksDB. Aligns L0/L1 SST files to zones, eliminates WAL double-write. Reduces RocksDB WA by 2–4× on ZNS devices.

**Adoption challenge**: ZNS requires zone-aware software. Existing applications that assume random write access cannot run on ZNS without a compatibility shim.

### 4. Software Stack Overhead Ratio Changes Everything

| Device | Device latency | Software overhead | SW overhead % |
|--------|---------------|------------------|--------------|
| HDD | 5–10 ms | 50–200 µs | <1% |
| SATA SSD | 50–100 µs | 10–50 µs | 10–50% |
| NVMe SSD | 20–70 µs | 5–20 µs | 10–40% |
| Optane SCM | 300 ns–3 µs | 5–15 µs | 200–500% |

For Optane and high-end NVMe: **software overhead exceeds device latency**. Every µs saved in the stack is as valuable as shaving µs off the device.

**Mandatory for sub-100µs targets**:
- User-space I/O (SPDK): eliminates kernel block layer (~3–8µs)
- Polling, not interrupts: eliminates IRQ latency (~3–8µs)
- io_uring with registered buffers: eliminates per-I/O syscall (~150ns)
- Huge pages: eliminates TLB pressure (~50–200ns/IO)
- NUMA-pinned I/O threads: eliminates remote NUMA penalty (~50–100ns)
- Lock-free data structures (RCU): eliminates lock bounce (~100–300ns)

### 5. NUMA Topology for NVMe

PCIe NVMe devices attach to a specific CPU socket (NUMA node). Accessing a NUMA-remote NVMe device adds 50–100ns per I/O (remote DRAM for DMA descriptor + completion polling).

```
2-socket server:
  CPU 0 + DRAM 0    ←→  NVMe 0, NVMe 1    (local = ~60ns DRAM)
  CPU 1 + DRAM 1    ←→  NVMe 2, NVMe 3    (local = ~60ns DRAM)
  
  CPU 0 thread accessing NVMe 2 = remote NUMA = +80–120ns per I/O
```

**Design rule**: pin I/O threads to the CPU socket that owns the PCIe root complex for the target NVMe device. Crimson's Seastar does this automatically. BlueStore does not. SPDK provides `spdk_env_opts.shm_id` for NUMA control.

Verify with: `cat /sys/block/nvme0n1/device/numa_node`

### 6. Queue Depth Must Match Flash Parallelism

NVMe SSDs contain multiple flash chips (dies) operating in parallel. To saturate all parallel channels, you need sufficient queue depth:

```
Typical enterprise NVMe: 8–16 flash channels × 4 dies per channel = 32–64 parallel units
To saturate: need QD ≥ 32–128 per device
```

Traditional storage stacks designed for HDD targeted QD=32 as sufficient. All-flash needs:
- Per-device QD: 128–1024 for maximum IOPS
- Per-CPU QD: 32–128 depending on core count and device count
- Multiple submission queues (blk-mq, SPDK): one queue per CPU to avoid queue lock contention

**io_uring advantage**: allows submitting large batches (QD=1024+) without per-I/O syscalls. Critical for saturating NVMe at low latency.

### 7. Erasure Coding Trade-offs on All-Flash

| Scheme | Storage overhead | Write amplification | Rebuild I/O | Suitable for |
|--------|-----------------|-------------------|-------------|-------------|
| 3-way replication | 3× | 3× (writes to 3 OSDs) | 1× data size | Small clusters, latency-critical |
| EC 4+2 | 1.5× | Higher (encode + partial stripe) | 2× data size | Capacity-critical, large clusters |
| EC 8+2 | 1.25× | Higher | 3.2× data size | Maximum capacity efficiency |
| EC 4+2 with ZNS | 1.5× | Lower (sequential zone writes) | 2× data size | Future: ZNS-native EC |

**All-flash EC problem**: partial-stripe writes. EC requires full stripe width. Smaller writes must either be padded (WA) or use a journal (double-write). On flash, both options amplify writes.

**Mitigation**: journal-based EC (as BlueStore implements it) — small writes go to journal, full stripes are rebuilt and committed. Adds ~2× WA for small random writes. This is one reason all-flash EC clusters need careful write-size distribution analysis.

**DAOS approach**: no partial-stripe problem — DAOS's erasure coding operates on full objects appended to targets. Small writes accumulate in SCM until they form full stripes, then flush to NVMe.

### 8. Metadata Architecture at Flash Speed

At HDD latency, metadata operations (stat, listdir, create) are fast compared to data I/O. At NVMe speed, metadata can become the bottleneck:

```
Data read:     20–70µs (NVMe, data already in cache miss path)
Metadata read: 5–50µs  (if metadata is in RAM)
               20–70µs (if metadata misses to NVMe — same as data)
```

For workloads with millions of files (AI training datasets with billions of samples), metadata performance is critical:

| Architecture | Metadata storage | Metadata latency |
|-------------|-----------------|-----------------|
| CephFS | MDS in RAM, backed by RADOS | 0.5–5ms (MDS can be bottleneck) |
| DAOS | SCM (Optane) on every server | 1–10µs |
| WekaFS | Distributed DRAM, all nodes | 100µs–1ms |
| VAST Data | SCM on DNodes | 1–10µs |

**Design decision**: for AI workloads with billions of training samples, metadata tier must be SCM-backed or fully in DRAM. A single MDS with HDD-backed state cannot keep up.

### 9. Flash-Specific Tail Latency Sources

All-flash systems have different tail latency sources than HDD:

| Source | Impact | Frequency | Mitigation |
|--------|--------|-----------|-----------|
| NAND GC (internal) | p99 spike 100µs–5ms | Every few seconds at high load | Overprovisioning, ZNS |
| Read disturb (retention check) | Rare but severe (ms) | Monthly per block | Low at OP=20%+ |
| XOR parity check (ECC) | +5–50µs per affected read | Proportional to wear | Replace aged drives |
| Host-level GC/compaction (RocksDB) | p99 spike 1–100ms | Tunable frequency | ZenFS, Seastore |
| Thermal throttling | Sustained +50–200% latency | Hot environment | Thermal design, airflow |

**ZNS eliminates NAND internal GC** — the single most impactful tail latency source. This is the strongest argument for ZNS in latency-sensitive all-flash clusters.

### 10. AI/ML Workload-Specific Design Points

**Checkpoint I/O**:
- Pattern: burst write of model state (10GB–1TB in seconds)
- Issue: NVMe write bandwidth is limited; checkpoint stalls GPU training
- Design: SCM write buffer (DAOS pattern) absorbs burst instantly
- Design: async checkpoint (serialize to CPU memory, flush in background while GPU continues)
- Design: incremental/delta checkpointing (only changed tensors) — reduces checkpoint size 10–100×

**Training data reads**:
- Pattern: random reads of shuffled training samples (batch size = 256–4096 samples)
- High IOPS required: at 256 samples × 1MB each → 256MB/batch, must complete in < 10ms for GPU to not stall
- Design: all-flash IOPS must exceed GPU consumption rate
- Design: prefetch buffer in host DRAM (hide storage latency)
- Design: data format: avoid millions of tiny files (HDF5, TFRecord, WebDataset — large container files with internal indexing)

**Model serving**:
- Pattern: large sequential model load at startup (5–100GB)
- Design: NVMe sequential bandwidth sufficient; DRAM cache after first load
- Design: model sharding across NVMe devices for parallel load

**Critical metric for AI storage**: not just IOPS or bandwidth, but **GPU stall rate** — what % of GPU compute cycles are wasted waiting for storage I/O.

---

## Summary: All-Flash Architecture Design Checklist

**Write Amplification:**
- [ ] Total WA modeled across all layers: target ≤ 5×
- [ ] RocksDB compaction WA calculated for metadata update rate
- [ ] NAND internal GC WA modeled against OP% target
- [ ] Overprovisioning ≥ 20% planned in capacity model

**Flash Geometry Alignment:**
- [ ] Allocation granularity aligned to flash erase block size
- [ ] Write sequentiality: storage backend writes large sequential chunks (Seastore segments, DAOS tiers)
- [ ] ZNS considered for latency-critical deployments

**Software Stack:**
- [ ] Software overhead ratio calculated: SW overhead / device latency
- [ ] If ratio > 20%: SPDK or io_uring required
- [ ] If ratio > 100% (Optane/SCM): user-space fully required
- [ ] NUMA topology mapped: I/O threads pinned to device-owning NUMA node
- [ ] Huge pages configured for I/O buffers

**Queue Depth:**
- [ ] Per-device queue depth ≥ 128 for NVMe saturation
- [ ] Multiple blk-mq or SPDK queues (one per CPU core)
- [ ] Async I/O submission: io_uring or SPDK (never synchronous at high IOPS)

**Metadata:**
- [ ] Metadata tier on SCM or RAM for sub-10µs metadata latency (AI/HPC)
- [ ] File count modeled: avoid billions of small files with POSIX directory semantics
- [ ] Data format: large container files (HDF5, TFRecord) for AI training datasets

**Tail Latency:**
- [ ] NAND GC tail latency modeled at peak write load
- [ ] Host-level GC/compaction (RocksDB) scheduled outside SLO-sensitive windows
- [ ] Fail-slow detection (Perseus-style) deployed to catch degraded drives early

**Erasure Coding:**
- [ ] EC partial-stripe write penalty modeled against write I/O size distribution
- [ ] If write size << stripe width: journal-based EC or replication instead
- [ ] EC rebuild I/O load modeled against background bandwidth budget

---

## References

- [Ceph Crimson performance comparison (2025)](https://ceph.io/en/news/blog/2025/crimson-seastore-vs-classic/)
- [Ceph Crimson multi-core scalability (2023)](https://ceph.io/en/news/blog/2023/crimson-multi-core-scalability/)
- [Seastore design doc](https://docs.ceph.com/en/latest/dev/seastore/)
- [Crimson tech preview docs](https://docs.ceph.com/en/latest/crimson/crimson/)
- [DAOS architecture v2.2](https://docs.daos.io/v2.2/overview/architecture/)
- [DAOS GitHub](https://github.com/daos-stack/daos)
- [VAST Data DASE architecture](https://www.vastdata.com/platform/how-it-works)
- [Understanding DAOS Storage Performance Scalability (HPC Asia 2023)](https://dl.acm.org/doi/fullHtml/10.1145/3581576.3581577)
