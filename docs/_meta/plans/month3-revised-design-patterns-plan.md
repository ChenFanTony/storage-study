# 30-Day Storage Systems Design Patterns Study Plan

**Created:** 2026-04-11
**Status:** Active
**Audience:** Software storage architect with deep kernel storage (Month 1) and distributed storage (Month 2) knowledge
**Prerequisite:** Month 1 + Month 2 + Hardware Essentials reference
**Goal:** Master storage systems design patterns — storage engine internals, data reduction, reliability engineering, tiered storage automation, AI/ML storage, and cost modeling. Bridge from implementation knowledge to architecture judgment.

---

## Curriculum Modules

| Module | Topic | Key Source | Level |
|--------|-------|-----------|-------|
| 1 | B-tree Internals: Structure, Split, Merge | "Database Internals" Ch.2-3 | Expert |
| 2 | LSM-tree: MemTable, SSTables & Compaction | LevelDB/RocksDB source + paper | Expert |
| 3 | B-tree vs LSM-tree: Read/Write/Space Amplification | Comparative analysis | Expert |
| 4 | Log-structured Storage: Design Patterns & Tradeoffs | LFS paper, NOVA, WiscKey | Expert |
| 5 | Copy-on-Write Trees: Btrfs, APFS & Snapshot Efficiency | Btrfs design, APFS paper | Deep |
| 6 | Bloom Filters, Fence Pointers & Index Structures | Monkey paper, Dostoevsky | Expert |
| 7 | Week 1 Review: Storage Engine Selection Framework | Design scenario | Expert |
| 8 | Deduplication: Inline vs Post-Process | Chunk-based dedup design | Expert |
| 9 | Deduplication: Fingerprinting, Chunk Sizing & Index | Content-defined chunking | Expert |
| 10 | Compression: LZ4/Zstd/Snappy Tradeoffs | Compression benchmark analysis | Deep |
| 11 | Thin Provisioning at Scale: Overcommit & Reclamation | dm-thin + production issues | Expert |
| 12 | Content-Addressable Storage: Design & GC | Git objects, Perkeep, CAS patterns | Deep |
| 13 | Data Reduction Stacking: Dedup + Compress + Thin | Interaction effects | Expert |
| 14 | Week 2 Review: Data Reduction Architecture | Design scenario | Expert |
| 15 | Chaos Engineering for Storage: Methodology | Netflix/Google approaches | Expert |
| 16 | Fault Injection: Tools & Blast Radius Analysis | dm-flakey, libfiu, fault models | Expert |
| 17 | Gray Failure Detection: Patterns & Strategies | Gray failure paper + production | Expert |
| 18 | SLO Design: Choosing Percentiles & Error Budgets | SRE workbook | Expert |
| 19 | Runbook Design: Incident Response for Storage | Production runbook patterns | Expert |
| 20 | Post-Incident Analysis: Storage Failure Taxonomy | Real incident analysis | Expert |
| 21 | Week 3 Review: Reliability Architecture | Design scenario | Expert |
| 22 | Tiered Storage Automation: Heat Tracking Models | Heat-based tiering algorithms | Expert |
| 23 | Data Lifecycle Management: Policy Engines | ILM, object lifecycle, HSM | Expert |
| 24 | Storage for AI/ML: Checkpoint Patterns | Large model training storage | Expert |
| 25 | Storage for AI/ML: Embedding & Vector Stores | Faiss, Milvus, pgvector patterns | Deep |
| 26 | Multi-Cloud Storage: Data Gravity & Egress Costs | Architecture tradeoffs | Expert |
| 27 | Cost Modeling: 5-Year TCO Framework | Build vs buy, on-prem vs cloud | Expert |
| 28 | Capacity Planning: Growth Models & Headroom | Forecasting storage demand | Expert |
| 29 | Full Architecture Lab: End-to-End Design | Integrate all patterns | Expert |
| 30 | Final Review & Month 4 Roadmap | Synthesis | Expert |

---

## Week 1: Storage Engine Internals

### Day 1 — B-tree: Structure, Split & Merge
- **Read:** "Database Internals" (Petrov) Chapter 2–3; SQLite btree.c overview
- **Study:** Page structure, key ordering, split algorithm (half-full invariant), merge/rotate on delete, fill factor tuning
- **Goal:** Implement B-tree insert with split; explain why fill factor affects both space efficiency and update performance

### Day 2 — LSM-tree: MemTable, SSTables & Compaction
- **Read:** "The Log-Structured Merge-Tree" (O'Neil 1996); LevelDB implementation notes; RocksDB wiki
- **Study:** MemTable (in-memory write buffer), SSTable format (sorted key-value blocks + index + bloom filter), WAL for crash recovery, compaction (size-tiered vs leveled)
- **Goal:** Trace a write from MemTable to L0 to L1; explain why compaction must happen and what happens without it

### Day 3 — B-tree vs LSM-tree: The Amplification Tradeoffs
- **Read:** "Dostoevsky: Better Space-Time Trade-offs for LSM-Tree Based Key-Value Stores" (SIGMOD 2018); "WiscKey: Separating Keys from Values" (FAST 2016)
- **Study:** Read amplification (RA), write amplification (WA), space amplification (SA) for both structures; how workload mix determines winner
- **Goal:** Given any workload description, choose B-tree or LSM-tree and quantify the amplification tradeoffs

### Day 4 — Log-Structured Storage Patterns
- **Read:** "The Design and Implementation of a Log-Structured File System" (Rosenblum 1992); "NOVA: A Log-structured File System for Hybrid Volatile/Non-volatile Main Memories" (FAST 2016)
- **Study:** Segment cleaning (LFS's version of GC), write cost analysis, cleaning policy (cost-benefit), why LSS works well for SSDs (sequential writes)
- **Goal:** Explain why log-structured design helps SSD longevity; know the cleaning cost formula

### Day 5 — Copy-on-Write Trees
- **Read:** Btrfs design document; "APFS in Detail" (USENIX ATC 2019)
- **Study:** CoW B-tree mechanics (Month 1 Day 20 recap), snapshot efficiency, reflink, how COW interacts with garbage collection
- **Goal:** Compare Btrfs CoW vs LVM thin snapshots: performance, space efficiency, failure semantics

### Day 6 — Bloom Filters, Fence Pointers & Learned Indexes
- **Read:** "Monkey: Optimal Navigable Key-Value Store" (SIGMOD 2017); "The Case for Learned Index Structures" (SIGMOD 2018)
- **Study:** Bloom filter false positive rate vs size tradeoff; fence pointers in SSTables for binary search; learned indexes replacing B-trees for read-only workloads
- **Goal:** Calculate bloom filter size for given false positive rate; know when learned indexes outperform B-trees

### Day 7 — Week 1 Review: Storage Engine Selection Framework
- **Produce:** Decision guide: B-tree vs LSM-tree vs log-structured vs CoW-tree for 6 workload profiles
- **Design scenario:** A new time-series database needs a storage engine. Writes: 500K/s, Reads: 10K/s range scans, Deletes: rare. Choose storage engine and justify amplification tradeoffs.
- **Goal:** Defend storage engine choice with quantified amplification analysis

---

## Week 2: Data Reduction Technologies

### Day 8 — Deduplication: Inline vs Post-Process
- **Read:** "Primary Data Deduplication: Large Scale Study and System Design" (USENIX ATC 2012); ZFS dedup design
- **Study:** Inline dedup (on write path — latency impact), post-process dedup (background — no latency impact but storage temporarily used), dedup ratio by workload type
- **Goal:** Know which workloads benefit from dedup (VM images, backup) vs hurt (compressed media, encrypted data); calculate break-even storage savings

### Day 9 — Deduplication: Chunking & Fingerprinting
- **Read:** "Bimodal Content Defined Chunking for Backup Streams" (FAST 2010); Rabin fingerprinting
- **Study:** Fixed-size vs variable-size (content-defined) chunking; Rabin rolling hash for chunk boundary detection; fingerprint index design (RAM vs DRAM vs flash); dedup index scaling challenge
- **Goal:** Explain why content-defined chunking achieves better dedup ratios than fixed-size; know the index DRAM requirement per TB

### Day 10 — Compression: Tradeoffs in Practice
- **Read:** LZ4 and Zstd documentation; "Compression in Facebook's Data Lake" (blog)
- **Study:** LZ4 (fast, ~2× ratio), Zstd (configurable speed/ratio), Snappy (Google, balanced), Brotli (web), gzip (universal but slow); compression column storage (Parquet) vs row storage
- **Hands-on:** Benchmark LZ4 vs Zstd vs none on realistic data: database pages, logs, VM images
- **Goal:** Choose compression algorithm for any workload; know when compression hurts (random data, already-compressed)

### Day 11 — Thin Provisioning at Scale
- **Read:** dm-thin production issues (Red Hat KBase); "Overcommitment in Storage" analysis
- **Study:** Overcommit ratio design (2:1 typical, 5:1 risky), space reclamation (discard/TRIM propagation), metadata device failure risk (Day 12 Month 2 recap), pool exhaustion behavior
- **Goal:** Design a thin provisioning policy: overcommit ratio, monitoring thresholds, automatic reclamation, emergency runbook for pool-full events

### Day 12 — Content-Addressable Storage
- **Read:** Git object store design; "Venti: A New Approach to Archival Storage" (FAST 2002); Perkeep design
- **Study:** CAS architecture (hash → content), immutability, garbage collection (mark-and-sweep on reference graph), convergent encryption (dedup + encryption compatible)
- **Goal:** Design a CAS for backup storage: chunk size, hash algorithm choice, GC strategy, convergent encryption

### Day 13 — Data Reduction Stacking: Interaction Effects
- **Study:** Dedup then compress (correct order) vs compress then dedup (breaks dedup); thin provisioning + dedup: reclamation interaction; compression + encryption: compression must come first (encrypted data is incompressible)
- **Produce:** Data reduction pipeline design guide: correct ordering, interaction effects, total reduction estimation
- **Goal:** Given a storage workload, design the correct data reduction pipeline and estimate realistic space savings

### Day 14 — Week 2 Review: Data Reduction Architecture
- **Produce:** Decision matrix: inline dedup vs post-process vs no-dedup; compression algorithm selection guide
- **Design scenario:** A backup system stores 1PB of VM disk images (20% unique data) and SQL database dumps (40% unique). Design the data reduction pipeline. Estimate storage after reduction.
- **Goal:** Design and justify a complete data reduction architecture for any storage workload

---

## Week 3: Reliability Engineering

### Day 15 — Chaos Engineering for Storage: Methodology
- **Read:** "Chaos Engineering" (Basiri et al., IEEE Software 2016); Netflix Chaos Monkey blog; "Lineage-driven Fault Injection" (SOSP 2015)
- **Study:** Hypothesis-driven chaos: define steady state → inject fault → measure deviation; blast radius analysis (contain failure scope); game days; storage-specific chaos experiments
- **Goal:** Design a chaos engineering program for a distributed storage system; define 5 experiments with hypotheses and blast radius analysis

### Day 16 — Fault Injection: Tools & Techniques
- **Read:** dm-flakey documentation; libfiu; HDFS fault injection framework
- **Study:** dm-flakey (inject read/write errors on block device), libfiu (POSIX call injection), network fault injection (tc netem for latency/loss/corruption), application-level fault injection
- **Hands-on:** Set up dm-flakey to inject read errors, verify application handles them correctly
- **Goal:** Know which fault injection tool to use for which layer; design fault injection test suite for a storage component

### Day 17 — Gray Failure Detection
- **Read:** "Gray Failure: The Achilles' Heel of Cloud-Scale Systems" (HotOS 2017); "Fail-Slow at Scale" (FAST 2018)
- **Study:** Gray failure taxonomy (slow, intermittent, partial), detection strategies (timeout-based, comparison-based, probabilistic), fail-slow impact on tail latency, hedged requests
- **Goal:** Design gray failure detection for a storage cluster: what to measure, what thresholds to set, how to distinguish gray failure from load

### Day 18 — SLO Design for Storage
- **Read:** "Site Reliability Engineering" (Google) Ch. 4–5; "The Calculus of Service Availability" (Mogul)
- **Study:** Availability vs reliability vs durability distinctions; choosing the right percentile (p99 vs p99.9); error budget calculation; SLO cascading (storage SLO must be tighter than application SLO)
- **Goal:** Design a complete SLO framework for a storage service: availability, durability, latency percentiles, error budget, and burn rate alerts

### Day 19 — Runbook Design: Storage Incident Response
- **Study:** Runbook structure: trigger → diagnosis → remediation → escalation; storage-specific runbooks: disk failure, pool exhaustion, replication lag, metadata corruption, GC pressure
- **Produce:** Complete runbook for: (1) NVMe failure in RAID array, (2) thin pool nearing exhaustion, (3) bcache hit rate collapse
- **Goal:** Write runbooks that an on-call engineer can execute without storage expertise at 3am

### Day 20 — Post-Incident Analysis: Storage Failure Taxonomy
- **Read:** Post-mortems from Cloudflare, Dropbox, GitHub storage incidents (public blogs)
- **Study:** Common failure patterns: cascading GC, metadata bottleneck, correlated failures, thundering herd on recovery, split-brain
- **Produce:** Storage failure taxonomy: classify 10 failure modes, their detection, mitigation, and prevention
- **Goal:** Given any storage incident description, classify the failure mode and identify contributing factors

### Day 21 — Week 3 Review: Reliability Architecture
- **Produce:** Reliability architecture checklist: chaos engineering program, fault injection tests, SLO framework, runbooks, post-incident process
- **Design scenario:** A distributed object store has been having intermittent latency spikes of 5-10× p99. Design the investigation methodology, chaos experiment to reproduce, and architectural fix.
- **Goal:** Debug a storage reliability problem end-to-end using the week's methodology

---

## Week 4: Advanced Architecture Topics

### Day 22 — Tiered Storage Automation: Heat Tracking
- **Read:** "ORCA: An Orchestrator for Storage Tiering" (IBM); "Heuristics for Data Placement in Tiered Storage" (MSST)
- **Study:** Heat metrics: access frequency, recency, I/O size, read/write mix; heat decay models (exponential decay); placement policy: when to promote, when to demote, hysteresis to prevent oscillation
- **Goal:** Design a tiering policy with concrete heat thresholds, promotion/demotion rules, and hysteresis band

### Day 23 — Data Lifecycle Management
- **Read:** S3 Lifecycle documentation; Hadoop HDFS tiering (StoragePolicy); HSM (Hierarchical Storage Management) concepts
- **Study:** Object lifecycle policies (transition to IA/Glacier), WORM (Write Once Read Many), legal hold, retention enforcement; HSM tape integration; ILM (Information Lifecycle Management) policy design
- **Goal:** Design a complete data lifecycle policy for a 5-year retention requirement with cost optimization

### Day 24 — Storage for AI/ML: Checkpoint Patterns
- **Read:** "Efficient Large Scale Language Model Training on GPU Clusters" (Narayanan et al.); PyTorch checkpoint documentation; "CheckFreq: Frequent, Fine-Grained DNN Checkpointing" (FAST 2021)
- **Study:** Checkpoint frequency optimization (cost of checkpoint vs restart cost), parallel checkpoint (all GPUs write simultaneously), incremental checkpoint (delta only), checkpoint storage format (tensor sharding)
- **Goal:** Design a checkpoint storage architecture for a 1000-GPU training cluster; calculate optimal checkpoint interval

### Day 25 — Storage for AI/ML: Vector Stores & Embedding Storage
- **Read:** Faiss library documentation; "Billion-scale similarity search with GPUs" (Johnson et al.); pgvector design
- **Study:** ANN (Approximate Nearest Neighbor) indexes: HNSW, IVF-PQ, FAISS flat; vector storage scaling challenges (dimensionality, index size, update cost); hybrid scalar + vector storage
- **Goal:** Choose correct ANN index for given dataset size, query latency, and update frequency requirements

### Day 26 — Multi-Cloud Storage Architecture
- **Read:** "The Cost of Cloud" (a16z essay); data gravity analysis frameworks
- **Study:** Data gravity (compute follows data); egress cost modeling (AWS: $0.09/GB egress); active-active vs primary-secondary multi-cloud; cross-cloud replication costs; vendor lock-in mitigation
- **Goal:** Calculate 5-year total cost for on-premises vs AWS vs multi-cloud for a 10PB storage workload

### Day 27 — Cost Modeling: 5-Year TCO Framework
- **Study:** Total cost of ownership components: hardware (amortized), power, cooling, rack space, network, software licenses, operational staff time; capacity planning with growth model; hardware refresh cycle modeling
- **Produce:** Complete TCO spreadsheet template with formulas for: hardware cost per TB, power cost per TB, staff cost per TB, total $/GB/month
- **Goal:** Given any storage requirement, produce a defensible 5-year TCO comparison between at least two options

### Day 28 — Capacity Planning: Growth Models
- **Read:** "The Art of Capacity Planning" (Allspaw) relevant sections; Google capacity planning methodology (SRE book)
- **Study:** Growth model types: linear, exponential, seasonal; confidence intervals for forecasts; headroom calculation (how much buffer before saturation); lead time for hardware procurement (8-16 weeks typical)
- **Goal:** Build a 3-year capacity forecast for a storage system with seasonal patterns; identify when to order hardware to avoid saturation

### Day 29 — Full Architecture Lab: End-to-End Design
- **Workload:** Design a storage architecture for a SaaS platform: 10K customers, 1TB average per customer, 3× annual growth, mixed workloads (databases, file storage, backups, ML training)
- **Required decisions:** Storage engine selection, data reduction strategy, tiering policy, reliability architecture, cost model
- **Goal:** Produce a complete architecture document: diagrams, component choices, cost estimate, reliability analysis

### Day 30 — Final Review & Month 4 Roadmap
- **Produce:** Storage Systems Design Pattern Reference — one-page summary of all decision frameworks from this month
- **Final scenario:** "You are the storage architect for a company about to IPO. The CTO asks: what is our storage strategy for the next 3 years?" Write the answer as an executive brief + technical appendix.
- **Identify:** Month 4 areas based on your gaps from this month

---

## Daily Study Structure

```
Each Day (~2.5-3 hours)

[30 min]  Read primary source (paper, book chapter, or design doc)
[30 min]  Read implementation or case study (blog, open source code)
[60 min]  Design exercise or hands-on experiment
[30 min]  Write architect-level notes: decisions, tradeoffs, when to use
[10 min]  Review yesterday's notes
```

## Weekly Milestones

| Week | Architect Capability Unlocked |
|------|-------------------------------|
| 1 | Choose and justify storage engine for any workload with amplification analysis |
| 2 | Design data reduction pipeline; calculate realistic space savings |
| 3 | Design chaos engineering program; write production runbooks; define SLOs |
| 4 | Design tiered storage policy; model 5-year TCO; build capacity forecast |

## Key References

- **"Database Internals"** — Alex Petrov (storage engine bible for architects)
- **"Designing Data-Intensive Applications"** — Martin Kleppmann (system-level patterns)
- **"Site Reliability Engineering"** — Google SRE book (reliability engineering)
- **"The Art of Capacity Planning"** — John Allspaw
- **LevelDB implementation notes** — github.com/google/leveldb/blob/main/doc/impl.md
- **RocksDB wiki** — github.com/facebook/rocksdb/wiki
- **"Dostoevsky" paper** — SIGMOD 2018 (LSM-tree tuning)
- **"Monkey" paper** — SIGMOD 2017 (bloom filter optimization)
- **"WiscKey" paper** — FAST 2016 (key-value separation)
- **"Fail-Slow at Scale"** — FAST 2018 (gray failure)
- **"Gray Failure"** — HotOS 2017
- **"CheckFreq"** — FAST 2021 (ML checkpoint patterns)
