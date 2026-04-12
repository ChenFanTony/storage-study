# Day 30: Final Review & Storage Architecture Roadmap

## Objective
This is your graduation day. Two deliverables: a complete storage stack
architecture diagram, and a "Storage Architecture Decision Guide" you
can use in real design reviews. Plus: your next 30-day roadmap.

---

## 1. Full Competency Audit

You should be able to answer every question below without notes.
Mark any gaps — those become Day 1 of your next 30-day plan.

### Week 1: Block Layer & Writeback
- How does a bio become a tagged request in blk-mq?
- What is a plug/unplug and when does plugging help?
- What causes the writeback cliff and how do you prevent it?
- When is read-ahead harmful to a bcache setup?
- Which scheduler for NVMe with multi-tenant containers, and which cgroup mechanism?

### Week 2: Tiering
- bcache GC: what triggers it, what it writes, how it causes SSD wear
- bcache writeback SSD failure: exactly what is lost and why
- At what IOPS does bcache btree contention become visible?
- dm-cache SMQ vs bcache LRU: one concrete behavioral difference
- dm-thin metadata failure: how many LVs affected and why

### Week 3: Filesystems
- RAID-5 write hole: exact crash sequence causing silent corruption
- XFS AG model: why it enables parallel metadata but ext4 doesn't
- XFS vs JBD2 logging: one concrete difference in how they achieve crash consistency
- ext4 data=ordered: what it orders, what gap remains
- Btrfs CoW B-tree: how instant snapshots are possible

### Week 4: Modern I/O Path
- NVMe doorbell: what it is, why batching helps
- NVMe-oF/TCP vs RDMA: latency difference and why
- ANA_NON_OPTIMIZED: when the kernel routes I/O through it
- io_uring fixed buffers: what cost they eliminate vs O_DIRECT
- ZNS zone append: why it enables parallelism without coordination
- DAX: what two layers it bypasses and what CPU instructions replace them
- io.latency vs io.max: fundamental enforcement model difference

---

## 2. The Architecture Diagram (Produce This)

Draw the complete Linux storage stack from system call to NAND,
annotated with your Week 1–4 knowledge. Include:

```
[Your diagram should cover all of these:]

User Space
  └── Applications: PostgreSQL (O_DIRECT), general (buffered), io_uring
  
System Call Interface
  └── read/write/pread/pwrite/io_uring_enter

VFS + Page Cache
  └── filemap_read, balance_dirty_pages, readahead
  └── DAX path: bypasses page cache → goes direct to pmem

Filesystem Layer
  └── XFS: AG model, delayed allocation, CIL, iomap
  └── ext4: JBD2, ordered/writeback/journal modes
  └── Btrfs: CoW B-tree, snapshots, send/receive

Block Layer (blk-mq)
  └── bio → tag allocation → software queue → hardware queue
  └── I/O schedulers: none / mq-deadline / bfq
  └── blk-cgroup: io.max (throttle), io.weight (BFQ), io.latency (iolatency)
  └── blk-crypto: inline encryption (hardware or software fallback)

Stacking Drivers
  └── Device Mapper: dm-crypt → dm-cache → dm-thin → dm-linear
  └── MD: RAID-1 / RAID-5 (write hole, WIB) / RAID-6 / RAID-10
  └── bcache: bucket model, GC, btree, writeback

Device Drivers
  └── NVMe: queue pairs, SQ/CQ doorbells, namespaces, passthrough
  └── NVMe-oF: fabric layer, TCP/RDMA transports, ANA multipath
  └── virtio-blk: (your existing knowledge)

Hardware
  └── NVMe SSD: FTL, queue pairs, SMART
  └── ZNS: zones, write pointer, zone append
  └── Persistent Memory: byte-addressable, clwb+sfence for durability
  └── HDD: mechanical, seek time, rotational latency
```

---

## 3. Storage Architecture Decision Guide (Produce This)

This is the document you would hand to a customer or use in a design review.
Minimum required sections:

### Section 1: Primary Filesystem

| Workload | Filesystem | Key Reason |
|----------|-----------|-----------|
| [fill in 6+ rows] | | |

### Section 2: Block Layer Configuration

| Device | Scheduler | Queue Depth | Read-ahead |
|--------|-----------|-------------|-----------|
| NVMe, single workload | | | |
| NVMe, multi-tenant | | | |
| HDD, database | | | |
| bcache composite | | | |
| NVMe-oF target | | | |

### Section 3: Tiering Technology Selection

| Condition | Technology | Mode |
|-----------|-----------|------|
| HDD + SSD cache, simple setup | | |
| NVMe + SSD cache, high IOPS | | |
| Thin provisioning + snapshots needed | | |
| RPO=0 required with SSD cache | | |

### Section 4: Failure Semantics Reference
[Your version of the Week 2 failure matrix — from memory]

### Section 5: cgroup I/O Policy

| Requirement | Mechanism | Configuration |
|-------------|-----------|--------------|
| Hard bandwidth cap | | |
| Protect latency-sensitive workload | | |
| Fair sharing between equals | | |

### Section 6: Modern I/O Decision Points

| Scenario | Recommendation |
|----------|---------------|
| >500K IOPS, CPU-bound on syscall | |
| Need NVMe vendor commands | |
| Disaggregated storage, >1ms latency acceptable | |
| Disaggregated storage, <500µs required | |
| ZNS device, LSM database | |
| DAX pmem, transaction log | |

---

## 4. Final Scenario: The Gauntlet

This is the capstone design question. Answer it in writing — full justification
for every decision. No reference to the course materials.

**Brief:**
You are the storage architect for a new cloud-native database service.

Infrastructure:
- Storage nodes: 4 nodes, each with 8× NVMe (2TB each) + 4TB pmem
- Compute nodes: 40 nodes, no local storage
- Network: 100GbE, dedicated storage VLAN, RoCE-capable NICs
- Workload: multi-tenant OLTP, 200 tenants, each gets a dedicated database instance

Requirements:
- p99 read latency: < 2ms per tenant
- p99 write latency: < 5ms per tenant
- Tenant isolation: one tenant's heavy workload must not impact others > 20%
- RPO: 1 hour (hourly snapshots)
- RTO: 15 minutes
- Encryption at rest: mandatory (AES-256)
- Expected growth: 20% annually

**Design the complete storage architecture. Justify every decision.**

Specifically address:
1. Local storage on storage nodes vs disaggregated NVMe-oF?
2. Filesystem choice on storage nodes?
3. Encryption placement in the stack?
4. Thin provisioning for tenant isolation?
5. SSD caching (bcache/dm-cache) — yes or no?
6. How do you achieve tenant I/O isolation at p99 <2ms?
7. How do you use the 4TB pmem per node?
8. Snapshot strategy for RPO=1hr?
9. What is your RTO=15min recovery path?
10. How does the architecture scale as tenants grow?

**Reference answer at end of this document.**

---

## 5. Your Next 30-Day Roadmap

Based on what you know and what you want to become, identify your next
deep-dive areas. Candidates:

```
Option A: User-Space Storage (SPDK/DPDK)
  - SPDK NVMe driver (kernel-bypass)
  - SPDK blobstore and bdev layer
  - DPDK memory management for storage
  - When SPDK beats io_uring and when it doesn't

Option B: Distributed Storage Internals
  - Raft and Paxos implementation details (not just concepts)
  - etcd/TiKV storage engine internals
  - CockroachDB Pebble (RocksDB fork) internals
  - Network erasure coding (EC) at scale

Option C: Storage Hardware Deep Dive
  - NAND flash physics: MLC/TLC/QLC tradeoffs
  - NVMe controller design internals
  - RDMA/RoCE programming model (rdma-core, libibverbs)
  - CXL (Compute Express Link): what it changes for storage architects

Option D: Kernel Storage Development
  - Writing a block device driver
  - Writing a device mapper target
  - Contributing to bcache or dm-cache
  - BPF storage tools development
```

---

## Reference Answer: The Gauntlet

**1. Disaggregated NVMe-oF vs local storage:**
NVMe-oF/RDMA. 40 compute nodes with no local storage → must use NVMe-oF.
RDMA (RoCE): 100GbE RoCE gives ~50-80µs fabric overhead vs ~50µs local NVMe.
Combined p99 <2ms is achievable. TCP adds 200-300µs — borderline for 2ms target
under load. Use RDMA; the NIC investment is justified at this scale.

**2. Filesystem on storage nodes:**
XFS. Multi-tenant OLTP = parallel metadata-heavy workload (many small files,
concurrent creates). XFS AG model scales with CPU count. External log on a small
NVMe partition per storage node to separate log I/O from data I/O.

**3. Encryption placement:**
dm-crypt above RAID/LVM, below XFS. Stack: XFS → dm-crypt → LVM/md → NVMe.
IV mode: aes-xts-plain64, key size 512 bits. LUKS2 with argon2id KDF.
dm-crypt above LVM means encrypted data at rest on NVMe; LUKS header on separate
protected device or in a secure key management service. Tenant-level encryption
keys (separate LUKS device per tenant) for key isolation.

**4. Thin provisioning:**
Yes — dm-thin. 200 tenants × variable-size databases on 4 storage nodes.
Thin provisioning allows overcommit (tenants don't use full allocation initially).
Metadata device: RAID-1 on two small NVMe partitions per node (must survive one NVMe failure). Pool metadata: thin_dump backup hourly (matches RPO).

**5. SSD caching:**
No. All storage is already NVMe — there's no slow tier to accelerate. Adding
dm-cache NVMe-on-NVMe adds bcache's btree contention overhead without benefit.
The pmem (4TB) serves as the hot tier (Day 27 architecture).

**6. Tenant I/O isolation for p99 <2ms:**
Two mechanisms layered:
- Per-tenant dm-thin namespace with io.latency on each tenant's cgroup: `echo "MAJ:MIN 2000000" > tenant_N/io.latency` — adaptively throttles noisy neighbors.
- Per-tenant `io.max` hard cap to prevent any single tenant from monopolizing bandwidth: `rbps=1073741824 wbps=1073741824` (1GB/s per tenant, prevents total monopolization).
20% impact budget: if a tenant causes others' latency to rise by 20% (2ms → 2.4ms), io.latency kicks in and throttles the offender.

**7. Persistent memory (4TB pmem per node):**
Use as transaction log (WAL) tier via DAX. Each tenant gets a portion of pmem for their WAL. WAL writes use mmap + MAP_SYNC + clwb+sfence — sub-microsecond write durability. This is the key to achieving p99 write <5ms: WAL fsync latency drops from 50µs (NVMe) to <1µs (pmem), leaving headroom for compute and network.

**8. Snapshot strategy (RPO=1hr):**
Hourly dm-thin snapshots per tenant thin LV. Store snapshots on same pool (fast) with retention: 24 hourly + 7 daily + 4 weekly. Metadata backup: `thin_dump` to object storage hourly (matches RPO for metadata). For offsite backup: Btrfs send/receive is not applicable (XFS). Use restic or Borg to deduplicate and ship changed blocks to object storage.

**9. RTO=15 minutes:**
Failure: NVMe device on storage node fails.
- dm-thin pool survives (metadata on RAID-1 separate NVMe partition).
- Affected tenants' data on failed NVMe: depends on RAID level under LVM.
- With RAID-10 under LVM across 8 NVMe: one NVMe failure = degraded, all data accessible, RTO = 0 (automatic).
- Tenant-level failover: NVMe-oF controller marks path as ANA_INACCESSIBLE, host fails over to second path (second storage node via ANA_NON_OPTIMIZED). RTO = reconnect time (~30 seconds).
- 15-minute RTO is comfortably met with NVMe-oF multipathing and RAID-10.

**10. Scaling as tenants grow:**
Architecture scales horizontally: add storage nodes, each exports NVMe-oF namespaces. New tenants placed on least-loaded storage node. dm-thin pool on each storage node expands as NVMe is added (LVM grows online). XFS grows online. NVMe-oF discovery service updated — compute nodes connect to new namespaces automatically. No downtime required for tenant addition.
