# 30-Day Distributed Storage Internals Study Plan

**Created:** 2026-04-11
**Status:** Active
**Audience:** Experienced storage engineer with deep Linux kernel storage knowledge, targeting Storage Architect role
**Prerequisite:** Month 1 (Linux kernel storage stack, VFS through NVMe)
**Goal:** Master distributed storage internals — consensus protocols at implementation level, erasure coding, consistent hashing, replication models, and object storage architecture

---

## Curriculum Modules

| Module | Topic | Key Source | Level |
|--------|-------|-----------|-------|
| 1 | Distributed Storage Concepts Gap-Fill | CAP, PACELC, linearizability | Fast-pass |
| 2 | Raft: Leader Election & Log Replication | Ongaro dissertation, TiKV source | Expert |
| 3 | Raft: Log Compaction, Snapshots & Membership | etcd/raft source | Expert |
| 4 | Raft: Production Failure Modes | TiKV, etcd incident reports | Expert |
| 5 | Paxos Variants & Multi-Paxos | Paxos Made Simple, Chubby paper | Deep |
| 6 | Viewstamped Replication & Zab | ZooKeeper internals | Deep |
| 7 | Consensus Week Review | Design a replicated log from scratch | Expert |
| 8 | Erasure Coding: Reed-Solomon Math | galois field arithmetic | Expert |
| 9 | Erasure Coding: LRC & Production Variants | Azure LRC, Facebook f-LRC | Expert |
| 10 | Erasure Coding: Repair Traffic & Placement | Ceph EC pools, partial reads | Deep |
| 11 | Consistent Hashing: Models & Tradeoffs | CRUSH, rendezvous, vnodes | Expert |
| 12 | Data Placement & Rebalancing | Ceph CRUSH vs Cassandra vnodes | Expert |
| 13 | Replication Models: Primary-Backup & Chain | CRAQ, chain replication paper | Deep |
| 14 | Replication Week Review | Placement design scenario | Expert |
| 15 | iSCSI Protocol Internals | RFC 3720, open-iscsi source | Deep |
| 16 | NFS v4 & pNFS Architecture | RFC 5661, Linux nfsd source | Deep |
| 17 | SMB3 & Multichannel | Samba source, MS-SMB2 spec | Deep |
| 18 | Fibre Channel & FCoE | FC-4 layer, zoning, NPIV | Deep |
| 19 | Storage Network Protocol Comparison | Design review scenarios | Expert |
| 20 | Object Storage: S3 API & Consistency Model | S3 consistency, MinIO source | Expert |
| 21 | Protocol Week Review | Storage network decision matrix | Expert |
| 22 | Ceph RADOS Deep Dive | RADOS paper, OSD source | Expert |
| 23 | Ceph BlueStore Internals | BlueStore design doc, source | Expert |
| 24 | MinIO & Erasure Set Architecture | MinIO source, healing | Deep |
| 25 | SeaweedFS & Haystack-style Object Storage | Haystack paper, SeaweedFS | Deep |
| 26 | Object Storage Metadata at Scale | HopsFS, CephFS MDS, POSIX limits | Expert |
| 27 | Distributed Storage Benchmarking | COSbench, s3-benchmark, fio | Expert |
| 28 | Capacity Planning & Cost Modeling | WA stacking, endurance models | Expert |
| 29 | Failure Domain Analysis | MTTF/MTTR modeling, correlated failures | Expert |
| 30 | Final Review & Month 3 Roadmap | Full distributed storage design | Expert |

---

## Week 1: Consensus Protocols

### Day 1 — Distributed Storage Concepts Gap-Fill (Half Day)
- **Read:** CAP theorem (precise version: network partitions are not optional), PACELC tradeoff, linearizability vs serializability vs eventual consistency
- **Goal:** Precisely define: linearizability, sequential consistency, causal consistency, eventual consistency. Know which storage systems provide which guarantee.

### Day 2 — Raft: Leader Election & Log Replication
- **Read:** Ongaro's Raft dissertation (Chapter 3-4), TiKV `raft-rs` source
- **Hands-on:** Run etcd single-node, then 3-node cluster; observe leader election via `etcdctl endpoint status`
- **Goal:** Follow a write from client → leader → followers → commit, precisely. Know what happens to in-flight writes during leader election.

### Day 3 — Raft: Log Compaction, Snapshots & Membership Changes
- **Read:** Ongaro dissertation Chapter 5-6, etcd `raft/log.go`, `raft/rawnode.go`
- **Hands-on:** Force a snapshot in etcd; observe log compaction; add/remove a member
- **Goal:** Understand snapshot transfer to lagging followers; joint consensus for membership changes

### Day 4 — Raft: Production Failure Modes
- **Read:** TiKV blog posts on Raft performance, etcd issue tracker (search "split brain", "leader lease")
- **Study:** Leader lease optimization (read without round-trip), pre-vote (prevents disruptive elections), check-quorum
- **Goal:** Know the 5 most common Raft production failure patterns and their mitigations

### Day 5 — Paxos Variants & Multi-Paxos
- **Read:** "Paxos Made Simple" (Lamport), "Paxos Made Live" (Google Chubby paper)
- **Study:** How Multi-Paxos reduces to 1 round-trip for stable leader; how it differs from Raft
- **Goal:** Explain Paxos phase 1/2 precisely; explain why Multi-Paxos and Raft are equivalent in steady state

### Day 6 — Viewstamped Replication & ZooKeeper's Zab
- **Read:** "Viewstamped Replication Revisited" (Liskov), ZooKeeper paper, Zab paper
- **Study:** Zab's epoch-based recovery; how ZooKeeper's Zab differs from Raft/Paxos
- **Goal:** Understand why ZooKeeper chose Zab over Paxos; know Zab's recovery protocol

### Day 7 — Consensus Week Review
- **Produce:** Comparison matrix: Raft vs Multi-Paxos vs Zab — leader election, log replication, recovery, membership change
- **Design scenario:** You must implement a replicated write-ahead log for a distributed database. Choose a consensus protocol and justify every design decision.
- **Goal:** Defend consensus protocol choice under technical cross-examination

---

## Week 2: Erasure Coding & Data Placement

### Day 8 — Erasure Coding: Reed-Solomon Math
- **Read:** "Erasure Codes for Storage Systems" (Plank), galois field GF(2^8) arithmetic
- **Hands-on:** Implement RS(4,2) encode/decode in Python using galois library; verify recovery
- **Goal:** Understand GF(2^8) multiplication, generator matrix, why k+m shards recover any k

### Day 9 — Erasure Coding: LRC & Production Variants
- **Read:** "Erasure Coding in Windows Azure Storage" (LRC paper), Facebook f-LRC
- **Study:** Local Reconstruction Codes: why repair traffic matters more than storage overhead at scale
- **Goal:** Calculate repair traffic for RS(k,m) vs LRC(k,l,r); know when LRC is worth the complexity

### Day 10 — Erasure Coding: Repair Traffic & Placement
- **Read:** Ceph EC pool documentation + source (`src/osd/ECBackend.cc`)
- **Study:** Partial reads for EC repair; placement group design for EC; why EC and replication have different placement constraints
- **Hands-on:** Create Ceph EC pool; force shard loss; observe repair traffic
- **Goal:** Design EC placement for a 3-failure-domain cluster

### Day 11 — Consistent Hashing: Models & Tradeoffs
- **Read:** Original consistent hashing paper (Karger), CRUSH paper (Weil), rendezvous hashing
- **Study:** Virtual nodes (Cassandra/DynamoDB); CRUSH rule DSL; jump consistent hash
- **Goal:** Explain why CRUSH gives deterministic placement without a placement table; when rendezvous hashing wins

### Day 12 — Data Placement & Rebalancing
- **Read:** Ceph CRUSH map design guide; Cassandra token assignment; DynamoDB paper (virtual nodes section)
- **Hands-on:** Design a CRUSH map for a 3-DC cluster with different failure domains; simulate node addition and measure data movement
- **Goal:** Calculate data movement on node addition for consistent hash vs CRUSH vs virtual nodes

### Day 13 — Replication Models: Primary-Backup & Chain Replication
- **Read:** "Chain Replication for Supporting High Throughput and Availability" (van Renesse), CRAQ paper
- **Study:** Primary-backup vs chain replication: write path, read path, failure recovery
- **Goal:** Know when chain replication outperforms primary-backup and when it doesn't

### Day 14 — Replication Week Review
- **Produce:** "Replication Architecture Decision Guide" — when to use RS erasure coding vs 3× replication vs LRC; CRUSH vs vnodes for placement
- **Design scenario:** 5-petabyte object store across 3 datacenters, 2-failure-domain tolerance, minimize repair traffic. Design the EC scheme and placement strategy.
- **Goal:** Defend EC and placement choices with math, not just intuition

---

## Week 3: Storage Network Protocols

### Day 15 — iSCSI Protocol Internals
- **Read:** RFC 3720 (iSCSI), open-iscsi source (`drivers/scsi/libiscsi.c`)
- **Study:** iSCSI PDU format, login sequence, command sequence numbers, error recovery levels, multipathing (DM-Multipath + iSCSI)
- **Hands-on:** Set up iSCSI target (targetcli) + initiator; trace PDUs with Wireshark
- **Goal:** Explain iSCSI session establishment, command numbering, and error recovery at protocol level

### Day 16 — NFS v4 & pNFS Architecture
- **Read:** RFC 5661 (NFSv4.1), pNFS layout types, Linux `fs/nfs/` source
- **Study:** NFSv4 stateful operations; pNFS parallel access; FLEXFILES layout vs BLOCK layout
- **Hands-on:** Set up NFSv4 server; observe compound operations with Wireshark; compare v3 vs v4 RPC patterns
- **Goal:** Understand how pNFS achieves parallel data access while maintaining metadata consistency

### Day 17 — SMB3 & Multichannel
- **Read:** MS-SMB2 specification (key sections), Samba source (`source3/smbd/`)
- **Study:** SMB3 multichannel (multiple TCP connections per session), encryption, persistent handles (survive server restart)
- **Hands-on:** Set up Samba SMB3; enable multichannel; observe session negotiation
- **Goal:** Know SMB3's key enterprise features vs NFSv4; when to choose each

### Day 18 — Fibre Channel & FCoE
- **Read:** FC-FS-4 standard overview, FCoE (802.1Qbb), NPIV, FC zoning
- **Study:** FC fabric initialization, FLOGI/PLOGI, zoning enforcement, NPIV for virtualization
- **Goal:** Understand FC zoning as storage security boundary; know why FC is still deployed and its replacement trajectory

### Day 19 — Storage Network Protocol Comparison
- **Produce:** Protocol comparison matrix: iSCSI vs NVMe-oF/TCP vs FC vs NVMe-oF/RDMA — latency, throughput, CPU overhead, failure model, operational complexity
- **Design scenario:** Greenfield enterprise storage network for mixed workload: 50% VMs, 30% databases, 20% backup. Choose protocols and justify.
- **Goal:** Defend storage network protocol choice for any workload

### Day 20 — Object Storage: S3 API & Consistency Model
- **Read:** S3 API documentation, "Amazon S3's Consistency Model" (2020 announcement), MinIO source (`cmd/object-api-*.go`)
- **Study:** S3 strong consistency (since 2020), multipart upload, object versioning, lifecycle policies, S3 Select
- **Goal:** Know precisely what S3 consistency guarantees, when multipart is needed, how versioning affects storage overhead

### Day 21 — Protocol Week Review
- **Produce:** Storage network decision guide for 4 common scenarios: enterprise SAN, cloud-native (containers), HPC (parallel FS), object storage
- **Goal:** Given any storage workload description, choose protocol and justify in 5 minutes

---

## Week 4: Object Storage Architecture

### Day 22 — Ceph RADOS Deep Dive
- **Read:** RADOS paper (Weil), Ceph OSD source (`src/osd/PrimaryLogPG.cc`)
- **Study:** PG (Placement Group) state machine, peering protocol, backfill vs recovery, scrub
- **Goal:** Trace a write from client → PG primary → replicas → ack; explain exactly what happens during OSD failure and PG recovery

### Day 23 — Ceph BlueStore Internals
- **Read:** BlueStore design document, `src/os/bluestore/BlueStore.cc`
- **Study:** RocksDB for metadata, raw NVMe for data (no filesystem), WAL design, deferred writes, checksum per block
- **Goal:** Explain why BlueStore replaced FileStore; understand the two-stage write (WAL then deferred write) and its failure semantics

### Day 24 — MinIO & Erasure Set Architecture
- **Read:** MinIO erasure set documentation, `cmd/erasure-*.go` source
- **Study:** Erasure sets (fixed-size groups), distributed locking (etcd-based), healing, versioning storage overhead
- **Hands-on:** Deploy 4-node MinIO cluster; force drive failure; observe healing
- **Goal:** Understand MinIO's erasure set model and how it differs from Ceph's PG model

### Day 25 — SeaweedFS & Haystack-Style Object Storage
- **Read:** Facebook Haystack paper, SeaweedFS architecture docs
- **Study:** Needle (object) format, volume files, master/volume server separation, Filer for POSIX
- **Goal:** Understand the needle-in-haystack model: why it's efficient for billions of small objects; tradeoffs vs Ceph

### Day 26 — Object Storage Metadata at Scale
- **Read:** HopsFS paper, CephFS MDS architecture, "To FUSE or Not to FUSE" paper
- **Study:** Why POSIX metadata at petabyte scale is hard; CephFS MDS subtree partitioning; HopsFS (Hadoop + NewSQL metadata); when to abandon POSIX
- **Goal:** Design a metadata architecture for 10 billion objects; know when POSIX namespace becomes the bottleneck

### Day 27 — Distributed Storage Benchmarking
- **Read:** "Benchmarking Cloud Serving Systems with YCSB", COSbench docs
- **Study:** How to benchmark distributed storage without being fooled: warmup, steady state, fill rate, latency vs throughput tradeoffs, how to isolate network vs storage vs metadata
- **Hands-on:** Run COSbench or s3-bench against MinIO; interpret results correctly
- **Goal:** Design a benchmarking methodology for a distributed storage system that isolates each bottleneck

### Day 28 — Capacity Planning & Cost Modeling
- **Study:** Write amplification stacking: application WA × filesystem WA × SSD FTL WA × erasure coding overhead. Model total bytes written to NAND per user byte written.
- **Study:** Cost modeling: $/GB raw vs $/GB usable vs $/IOPS vs $/GB-bandwidth for HDD/SSD/NVMe/pmem tiers
- **Produce:** Capacity planning template for a 5-year storage system lifecycle
- **Goal:** Given workload profile and growth rate, produce a 5-year hardware cost projection with confidence intervals

### Day 29 — Failure Domain Analysis
- **Study:** Formal MTTF/MTTR modeling for complex stacks; correlated failure modeling (power domain, network switch, rack); when additional redundancy layers are wasteful vs necessary
- **Study:** "Gray Failures" paper — partial failures that are worse than hard failures; detection and mitigation
- **Produce:** Failure domain analysis for a 3-datacenter storage cluster: identify correlated failure risks, quantify MTTDL (Mean Time To Data Loss)
- **Goal:** Given a storage architecture diagram, enumerate failure domains and calculate data loss probability

### Day 30 — Final Review & Month 3 Roadmap
- **Produce:** Complete distributed storage architecture decision guide
- **Final scenario:** Design a globally distributed object store: 5 regions, 99.999999999% (11 nines) durability, <100ms read latency globally, cost-optimized. Full design with EC scheme, placement, replication, consistency model, failure analysis.
- **Identify:** Month 3 focus areas (Storage Hardware Physics + SPDK)

---

## Daily Study Structure

```
Each Day (~3 hours)

[20 min]  Read primary source (paper, RFC, or key source file)
[30 min]  Read secondary source (blog, talk, or implementation)
[70 min]  Hands-on: implement, deploy, or instrument
[25 min]  Write architect-level notes: tradeoffs, failure modes, decision criteria
[15 min]  Review previous day's notes
```

## Weekly Milestones

| Week | Architect Capability Unlocked |
|------|-------------------------------|
| 1 | Design a replicated log; choose and defend consensus protocol for any workload |
| 2 | Design EC scheme and data placement for any failure domain requirement; calculate repair traffic |
| 3 | Choose storage network protocol for any workload; explain iSCSI/NFS/SMB/FC at protocol level |
| 4 | Design object storage architecture from scratch; benchmark, capacity plan, and failure-model it |

## Key References

- **Ongaro's Raft dissertation** — web.stanford.edu/~ouster/cgi-bin/papers/OngaroPhD.pdf
- **"Paxos Made Simple"** — Lamport, 2001
- **"Paxos Made Live"** — Chandra et al., Google, 2007
- **"Erasure Codes for Storage Systems"** — Plank, login: magazine
- **"CRUSH: Controlled, Scalable, Decentralized Placement"** — Weil et al.
- **"Chain Replication"** — van Renesse & Schneider, OSDI 2004
- **"Windows Azure Storage"** — Calder et al., SOSP 2011 (LRC erasure coding)
- **"Finding a Needle in Haystack: Facebook's Photo Storage"** — OSDI 2010
- **RADOS paper** — Weil et al., USENIX 2007
- **TiKV blog** — tikv.org/blog (best production Raft write-ups)
- **etcd source** — github.com/etcd-io/etcd
- **Ceph source** — github.com/ceph/ceph
- **MinIO source** — github.com/minio/minio
