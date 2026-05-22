# Month 3 Week 4: Advanced Architecture Topics (Days 22–30)

---

# Day 22: Tiered Storage Automation — Heat Tracking Models

## Learning Objectives
- Design heat metrics that correctly capture access patterns
- Build promotion/demotion rules with hysteresis
- Understand pitfalls: oscillation, cold-start, bursty access
- Know production tiering systems and their approaches

---

## 1. What Makes Good Heat Metrics

```
Heat = how "valuable" data is for placement in fast tier

Naive approach: access frequency
  Problem 1: A file accessed 1000 times yesterday but not since = cold now
  Problem 2: A file accessed once today for a 10GB sequential scan = misleadingly "hot"
  Problem 3: A file accessed once for a critical operation = as "hot" as one accessed for idle reads

Better approach: recency-weighted frequency

Heat score = sum over recent accesses of: weight(time_since_access)
  Recent accesses contribute more to heat than old accesses
  Heat decays exponentially over time

Exponential decay model:
  H(t) = sum_i { 1 × e^(-λ(t - t_i)) }
  where t_i = time of each access, λ = decay rate
  
  λ = 0.1/hour: heat halves every ~7 hours (good for daily tiering)
  λ = 0.01/hour: heat halves every ~70 hours (good for weekly tiering)

Access type weighting:
  Read: weight = 1.0 (standard)
  Write: weight = 2.0 (write implies future reads likely)
  Sequential: weight = 0.2 (one access, large data — less per-byte value)
  Random: weight = 1.5 (random access = likely repeated, valuable to cache)
  
  Adjusted heat = sum { access_weight × time_decay }
```

---

## 2. Heat Tracking Implementation

```python
# Heat tracker for tiered storage
import time
import math
from collections import defaultdict

class HeatTracker:
    def __init__(self, decay_rate=0.1, tick_seconds=3600):
        """
        decay_rate: heat halves in ~ln(2)/decay_rate ticks
        tick_seconds: how often to decay heat values
        """
        self.decay_rate = decay_rate
        self.heat = defaultdict(float)
        self.last_decay = time.time()
        
        # Access type weights
        self.weights = {
            'read_random': 1.5,
            'read_sequential': 0.2,
            'write_random': 2.0,
            'write_sequential': 0.3,
        }
    
    def record_access(self, object_id, access_type='read_random'):
        """Record an access to an object."""
        self._maybe_decay()
        weight = self.weights.get(access_type, 1.0)
        self.heat[object_id] += weight
    
    def _maybe_decay(self):
        """Apply exponential decay if enough time has passed."""
        now = time.time()
        elapsed_ticks = (now - self.last_decay) / 3600  # hours
        if elapsed_ticks > 0.1:  # only decay if meaningful time passed
            decay_factor = math.exp(-self.decay_rate * elapsed_ticks)
            for obj_id in list(self.heat.keys()):
                self.heat[obj_id] *= decay_factor
                if self.heat[obj_id] < 0.001:  # prune cold objects
                    del self.heat[obj_id]
            self.last_decay = now
    
    def get_heat(self, object_id):
        self._maybe_decay()
        return self.heat.get(object_id, 0.0)
    
    def get_hot_objects(self, threshold):
        self._maybe_decay()
        return {obj: h for obj, h in self.heat.items() if h >= threshold}
    
    def get_cold_objects(self, threshold):
        self._maybe_decay()
        return {obj: h for obj, h in self.heat.items() if h < threshold}
```

---

## 3. Promotion and Demotion Rules with Hysteresis

```
Without hysteresis: oscillation problem
  Data promoted to fast tier when heat > 10
  Data demoted when heat < 10
  Data accessed irregularly: heat oscillates around 10
  → Data moves up/down constantly → excessive tiering I/O

With hysteresis: stable bands
  Promote to fast tier when heat > PROMOTE_THRESHOLD (e.g., 15)
  Demote to slow tier when heat < DEMOTE_THRESHOLD (e.g., 5)
  Objects with heat 5-15: stay where they are (stable band)
  
  Hysteresis gap = PROMOTE - DEMOTE = 10 (no oscillation unless heat swings >10)

Additional stability rules:
  1. Minimum dwell time: don't demote data promoted less than 24 hours ago
     (prevents immediate demotion of burst-accessed data)
  
  2. Cool-down period: don't promote data that was demoted less than 6 hours ago
     (prevents repeated promote/demote cycles for bursty data)
  
  3. Cost threshold: only tier if migration cost < expected savings
     Migration cost = bytes × migration_time + I/O opportunity cost
     Expected savings = heat × (slow_tier_latency - fast_tier_latency) × expected_accesses

Production tiering parameters:
  PROMOTE_THRESHOLD: set so top 10-20% of objects are promoted
    (adjust based on fast tier capacity vs total data size)
  DEMOTE_THRESHOLD: PROMOTE / 3 (typical: 3× hysteresis band)
  DWELL_TIME: 24-72 hours (longer = more stable, slower to react)
  BATCH_SIZE: tier N objects at a time (not one-by-one)
    (reduce I/O overhead of migration)
```

---

## 4. Pitfalls in Tiered Storage Automation

```
Pitfall 1: Cold-start problem
  New data: no heat history → placed in slow tier → first access is slow
  
  Mitigation: "warm placement" for new writes
  All new data goes to fast tier initially
  Starts decaying immediately → if not re-accessed → demoted
  
  Alternative: fast tier as write cache (always write to fast → lazy demote)

Pitfall 2: Sequential scan contamination
  Analytics job reads entire dataset sequentially → all objects get heat bump
  → All objects promoted to fast tier → fast tier thrashed
  
  Mitigation: weight sequential reads much lower (0.2× vs 1.0×)
  Detection: if access rate exceeds threshold for a short time → likely scan
  
  HINT: applications can provide hints (O_NOATIME semantics, fadvise)
  fadvise(POSIX_FADV_NOREUSE) → "I'm reading this once, don't cache it"

Pitfall 3: Capacity cliff
  Fast tier fills up → tiering system must demote everything to make room
  → Massive demotion storm → heavy I/O → slow tier saturated
  
  Mitigation: proactive demotion (start demoting at 80% fast tier capacity)
  High-water mark: 80% → start demoting cold objects
  Low-water mark: 60% → stop demoting
  Never wait until 100% full to start demoting

Pitfall 4: Heat metric mismatch
  Heat captures frequency/recency but not I/O size
  1MB object accessed 100 times = promoted
  1TB object accessed 5 times = demoted
  But 1TB object delivers 5TB of "fast tier value" vs 100MB for the small object
  
  Mitigation: heat per byte (normalize by object size)
  Or: separate policies for large vs small objects (large: never promote)
```

---

## 5. Self-Check

1. A tiering system uses access count as heat. A batch job accesses all 1M objects once. What happens and why is this wrong?
2. Why is hysteresis (separate promote/demote thresholds) necessary in a tiering system?
3. You set PROMOTE_THRESHOLD=15 and your fast tier is 80% full. What is the correct response?
4. An object was written 1 hour ago and not accessed since. Should it be promoted to fast tier?

## 6. Answers

1. All 1M objects get heat=1. If promote threshold is 0.5 (say), all 1M objects get promoted to fast tier → fast tier overwhelmed. Or if threshold is high enough, no objects get promoted from the batch but legitimate hot objects may have their relative heat diluted. The correct fix: weight sequential reads very low (0.2×) AND use recency-weighted scoring. After the batch run, legitimate hot objects' heat remains much higher than the batch-accessed objects.
2. Without hysteresis: an object with heat oscillating around threshold=10 gets promoted when heat=10.1 and demoted when heat=9.9. Each oscillation costs I/O (move data up tier, then move it back). With hysteresis (promote=15, demote=5): object stays where it is unless heat moves by more than 10 points. Prevents thrashing for borderline-hot objects.
3. Start proactive demotion — don't wait until 100% full. Switch to high-water-mark policy: demote cold objects (lowest heat first) until fast tier drops to 60% (low-water mark). Simultaneously, raise promote threshold slightly (15 → 20) to reduce new promotions until capacity is managed. Do NOT stop accepting new writes — prioritize keeping hot data in fast tier by being more selective about promotion.
4. It depends on context but general answer: yes, if the write-placement policy promotes new data to fast tier initially. A write implies future reads are likely (someone just created this data for a reason). The data should start in fast tier with initial heat and decay. If not accessed within dwell-time (e.g., 24 hours), it gets demoted. This "write-warm" approach prevents cold-start latency for newly written data.

---

# Day 23: Data Lifecycle Management

## Key Content

```
Data lifecycle: data has different value at different ages

Lifecycle stages (typical):
  Hot (0-30 days): active, frequently accessed → NVMe fast tier
  Warm (30-90 days): occasional access → NVMe capacity tier or SAS HDD
  Cool (90 days - 1 year): rare access → HDD or object storage IA
  Cold (1-7 years): archived, rarely accessed → object storage Glacier equivalent
  Frozen (7+ years): compliance retention, almost never accessed → tape

S3-style lifecycle policies:
  Transition: move objects to cheaper storage class after N days
  Expiration: delete objects after N days (or specific date)
  
  Example policy:
  {
    "Rules": [{
      "Status": "Enabled",
      "Transitions": [
        {"Days": 30, "StorageClass": "STANDARD_IA"},   # after 30d → infrequent access
        {"Days": 90, "StorageClass": "GLACIER"},         # after 90d → archive
        {"Days": 365, "StorageClass": "DEEP_ARCHIVE"}    # after 1yr → deep archive
      ],
      "Expiration": {"Days": 2555}  # delete after 7 years
    }]
  }

WORM (Write Once Read Many):
  Objects cannot be modified or deleted during retention period
  Required by: FINRA, SEC, HIPAA, SOX for financial/healthcare records
  Implementation: object lock (S3 Object Lock, NetApp SnapLock)
  Two modes:
    Compliance mode: even admin cannot delete before retention expires
    Governance mode: privileged users can delete (with audit trail)

Legal hold:
  Suspend normal lifecycle rules (no deletion even if expired)
  Used during: litigation, audit, investigation
  Implementation: object lock + legal hold flag

ILM (Information Lifecycle Management) policy design:
  Consider: regulatory requirements (data must be kept N years)
  Consider: cost optimization (older data → cheaper storage)
  Consider: access patterns (when is old data accessed? retrieval latency acceptable?)
  
  HSM (Hierarchical Storage Management) systems:
    Traditional enterprise: IBM Spectrum Protect, Veritas NetBackup
    Modern: S3-compatible with lifecycle + Glacier/tape
    Cloud-native: AWS S3 Intelligent-Tiering (automatic based on access)

Architect design considerations:
  Avoid: lifecycle rules that transition too aggressively (data needed → retrieval cost/latency)
  Avoid: no lifecycle rules (data accumulates, costs grow unboundedly)
  Include: retrieval time in SLO (Glacier: 3-5 hours standard, minutes for expedited)
  Include: cost of retrieval in total cost model (not just storage cost)
```

---

# Day 24: Storage for AI/ML — Checkpoint Patterns

## Learning Objectives
- Understand the checkpoint storage problem at scale
- Know optimal checkpoint frequency calculation
- Know parallel checkpoint architecture
- Know incremental checkpoint design

---

## 1. The Checkpoint Problem at Scale

```
Training a large model (GPT-4 class):
  1000+ GPUs, each with 80GB HBM
  Total model state: ~1TB (weights, optimizer state, activations)
  Training time: weeks-months
  Hardware failure probability per hour: 1000 GPUs × 0.1% failure/GPU/day = 4% chance/day
  
Without checkpoints:
  GPU failure at hour 500 → restart from scratch → 500 hours wasted
  
With checkpoints every 30 minutes:
  GPU failure at minute 15 after checkpoint → lose 15 minutes → restart from checkpoint
  Max loss: 30 minutes × GPU cost × 1000 GPUs
  
Checkpoint overhead:
  Write 1TB to storage every 30 minutes = 2TB/hr storage write rate
  At 10 GB/s write bandwidth: 1TB checkpoint takes 100 seconds = 2.7% overhead
  (100s / 1800s checkpoint interval = 5.5% overhead — significant!)
```

---

## 2. Optimal Checkpoint Interval

```
Young's formula for optimal checkpoint interval:

  T_opt = sqrt(2 × R × T_c)
  
  where:
    R = Mean Time Between Failures (MTBF) for the cluster
    T_c = time to write one checkpoint (checkpoint overhead)

Example:
  1000 GPUs, each MTBF = 1000 hours
  Cluster MTBF = 1000h / 1000 GPUs = 1 hour = 60 minutes
  T_c = 100 seconds (checkpoint write time)
  
  T_opt = sqrt(2 × 60min × 100sec) = sqrt(720,000 sec²)
  T_opt = 849 seconds ≈ 14 minutes
  
  Interpretation: checkpoint every 14 minutes minimizes total wasted time
  
  Tradeoff:
    Too frequent (5min): checkpoint overhead dominates (checkpoint every 5min, takes 2min = 40% overhead)
    Too infrequent (60min): failure loss dominates (average 30min lost per failure, failure every 60min)
    Optimal: balance checkpoint cost vs failure recovery cost
```

---

## 3. Parallel Checkpoint Architecture

```
Problem: 1000 GPUs writing 1TB checkpoint simultaneously → storage bottleneck

Naive sequential checkpoint:
  GPU0 writes 1GB → GPU1 writes 1GB → ... → GPU999 writes 1GB
  Time: 1000 × 100ms = 100 seconds (for 10 GB/s storage)
  
Parallel checkpoint (all GPUs write simultaneously):
  All 1000 GPUs write 1GB each at same time
  Time: max(100ms) = 100ms (if storage bandwidth supports 10TB/s → not realistic)
  
  Real constraint: storage cluster bandwidth
  If cluster has 100 GB/s write bandwidth:
  1000 GPUs × 1GB = 1TB total, at 100 GB/s = 10 seconds
  
  BUT: NVMe-oF fabric becomes bottleneck
  1000 clients hitting storage simultaneously → queue depth explosion
  
Solutions:
  1. All-reduce checkpoint (PyTorch DDP):
     Each GPU saves only its shard (not full model)
     1TB model / 1000 GPUs = 1GB per GPU → write 1GB each in parallel
     Time: 1GB / 100MB/s (per-GPU storage link) = 10 seconds

  2. Dedicated checkpoint nodes:
     Separate storage servers with fast NVMe-oF
     GPUs write to checkpoint nodes → checkpoint nodes flush to persistent storage
     Write to fast tier: 1 second; background flush: 60 seconds (not blocking training)

  3. Async checkpoint (copy-on-write in memory):
     Snapshot GPU memory (CoW), resume training immediately
     Write snapshot to storage asynchronously
     Risk: storage must complete before next checkpoint is needed
```

---

## 4. Incremental Checkpointing

```
Problem: full checkpoint every interval is expensive for large models

Incremental checkpoint (delta checkpoint):
  Track which tensors changed since last checkpoint
  Write only changed tensors (delta) instead of full model
  
  Implementation:
    Mark all tensors "clean" after checkpoint
    During training: when tensor updated → mark "dirty"
    At checkpoint time: only write dirty tensors
  
  Savings: if 10% of model changes per checkpoint interval:
    Full checkpoint: 1TB
    Incremental: 100GB (90% reduction in checkpoint size → faster)
  
  Challenge: dependency tracking
    If checkpoint A is lost → need to roll back to last full checkpoint
    Can't apply delta without base
    Solution: full checkpoint every N incremental checkpoints
    
  Example schedule:
    Full checkpoint: every 1 hour (100 second write time)
    Incremental checkpoint: every 15 minutes (10 second write time)
    Max loss on failure: 15 minutes (incremental interval)
    Storage overhead: much lower than full-every-15min

CheckFreq (FAST 2021):
  Adaptive checkpoint frequency based on loss curve gradient
  Checkpoint more often during rapid learning (high gradient)
  Checkpoint less often during plateau
  Reduces total checkpoint overhead by ~40% for same durability
```

---

## 5. Storage Architecture for ML Training

```
Recommended architecture for large-scale ML training:

Tier 1: Fast checkpoint storage (NVMe cluster, NVMe-oF)
  Size: 3-5× model size (store 3 recent checkpoints)
  Bandwidth: 100+ GB/s aggregate write (all GPUs simultaneously)
  Latency: p99 < 100ms for checkpoint writes
  
Tier 2: Training data (high-throughput object storage)
  Size: training dataset (hundreds of TB to PB)
  Bandwidth: 10 GB/s per training job (sequential reads, distributed)
  Protocol: S3-compatible, streamed (not random access)
  
Tier 3: Model registry (object storage, durable)
  Stores: validated checkpoints, final models, experiment metadata
  Durability: 11 nines (critical artifacts)
  Not performance-sensitive (infrequent access)

Key design decisions:
  Pre-fetch training data: stream batches ahead of GPU consumption
  Checkpoint to fast tier first: don't block training on persistent storage
  Verify checkpoints: write + read-back verify (corrupted checkpoint = worse than no checkpoint)
  Checkpoint retention: keep N most recent (auto-delete older) + milestone checkpoints
```

---

# Day 25: Storage for AI/ML — Vector Stores & Embedding Storage

## Key Content

```
Vector stores: storage systems optimized for ANN (Approximate Nearest Neighbor) search

Why vector storage is a different problem:
  Traditional query: "WHERE id = 1234" → point lookup → B-tree/hash
  Vector query: "find 10 vectors most similar to [0.1, 0.5, 0.3, ...]" → ANN search
  Problem: nearest neighbor in high-dimensional space → O(N) naive scan → too slow

ANN Index types:

HNSW (Hierarchical Navigable Small World):
  Graph-based: each vector → node, connected to nearby vectors
  Multi-layer: coarse upper layers + fine-grained lower layers
  Search: enter at top layer → greedy walk → descend to lower layers
  
  Properties:
    Build time: O(N log N)
    Query time: O(log N) amortized (practically fast)
    Memory: ~64-128 bytes per vector per graph edge
    Accuracy: tunable (more edges = better recall, more memory)
  
  Best for: medium datasets (millions), low-latency queries, frequent updates

IVF-PQ (Inverted File Index + Product Quantization):
  IVF: cluster vectors into Voronoi cells → index is inverted: cluster_id → vector_ids
  PQ: compress each vector from 512-float to 64-byte (8× compression)
  
  Properties:
    Memory: O(0.1×) original (10× compression possible)
    Accuracy: lower than HNSW (lossy compression)
    Build time: O(N)
    Query time: O(sqrt(N)) for typical parameters
  
  Best for: large datasets (hundreds of millions), memory-constrained

Faiss (Facebook AI Similarity Search):
  Library implementing HNSW, IVF-PQ, flat (exact) and many more
  GPU-accelerated index build and search
  Used by: most production vector databases

pgvector:
  PostgreSQL extension adding vector similarity search
  Supports: exact L2/cosine, approximate HNSW and IVF indexes
  Best for: small-medium datasets (<10M vectors), need SQL integration

Milvus, Weaviate, Qdrant, Pinecone:
  Purpose-built vector databases
  Distributed, sharded vector indexes
  Additional features: filtering, multi-tenancy, streaming updates

Architect selection guide:
  < 1M vectors, need SQL: pgvector (HNSW index)
  1-100M vectors, fast queries needed: Milvus or Qdrant (HNSW or IVF-PQ)
  > 100M vectors, memory constrained: Faiss IVF-PQ or Pinecone (managed)
  Need real-time updates: HNSW (can add vectors without full rebuild)
  Need highest accuracy: exact search (only if < 1M vectors)
  
Storage considerations:
  Vector index (HNSW): kept in RAM (fast access required)
  Raw vectors: can be on NVMe (for large datasets)
  Metadata + scalars: PostgreSQL / relational DB
  
  Memory sizing: HNSW needs ~64 bytes × connections × N vectors in RAM
  For 100M 1536-dim vectors (GPT-4 embeddings), HNSW (M=16): ~100GB RAM
```

---

# Day 26: Multi-Cloud Storage Architecture

## Key Content

```
Data gravity: compute follows data, not the other way around
  Once you store 1PB in AWS S3, your compute migrates to AWS (egress cost)
  Changing clouds becomes extremely expensive (1PB × $0.09/GB = $92K egress)

Egress cost model:
  AWS: $0.09/GB for first 10TB/month (then slightly cheaper)
  GCP: $0.08/GB (varies by destination)
  Azure: $0.087/GB
  
  Example: 100TB moved out of AWS per month = $9,000/month = $108K/year
  This cost ALONE locks many organizations into their cloud provider
  
  Architect implication: design your egress strategy before you have data

Multi-cloud storage patterns:

Pattern 1: Primary cloud + cold backup in second cloud
  Primary: AWS S3 (active data, near compute)
  Backup: GCP Cloud Storage (cross-cloud backup, different failure domain)
  Replication: async cross-cloud replication of important data only
  Cost: backup egress cost + GCP storage cost
  Risk mitigation: AWS entire-region failure (rare but happened)

Pattern 2: Active-active multi-cloud (complex, expensive)
  Data replicated in two clouds simultaneously
  Compute can run in either cloud
  Problem: write coordination (which cloud is authoritative?)
  Problem: egress cost for every cross-cloud sync
  Use: almost never justified unless regulatory requirement
  
Pattern 3: Edge + cloud (pragmatic)
  Hot data: on-premises NVMe (low egress cost = zero, low latency)
  Cold data: cloud object storage (cheap $/GB, high egress cost if needed)
  Access pattern: 80% of accesses hit on-premises → low egress bill
  Works for: organizations with stable high-volume data access

Vendor lock-in mitigation:
  Use S3-compatible API (Ceph RGW, MinIO) for on-premises data
  Avoids: proprietary APIs that make migration harder
  Enables: swap cloud provider without changing application code
  Doesn't solve: egress cost (data still needs to move)

Cost comparison (10PB, 5-year TCO):
  On-premises (enterprise NVMe): ~$1.5M hardware + $300K ops = $1.8M
  AWS S3 Standard: 10PB × $0.023/GB/month × 60mo = $14M
  AWS S3 IA: 10PB × $0.0125/GB/month × 60mo = $7.5M (+ retrieval fees)
  
  Break-even: at ~5PB, on-premises is cheaper over 5 years
  Below 5PB: cloud is cheaper (no capital, elastic scale)
  Above 5PB: on-premises may be cheaper (but requires ops expertise)
```

---

# Day 27: Cost Modeling — 5-Year TCO Framework

## The Framework

```
Total Cost of Ownership components:

Capital expenditure (CapEx):
  Hardware: servers + drives + networking
  Amortized over: 3-5 years (straight-line depreciation)

Operating expenditure (OpEx):
  Power: kW × hours × $/kWh
  Cooling: typically 1.0-1.5× power cost (PUE)
  Rack space: $/rack-unit/month in colo
  Staff: FTE cost for storage operations
  Software licenses: if applicable

Hidden costs often missed:
  Refresh cycle: hardware needs replacement at 3-5 years (full CapEx again)
  Maintenance contracts: 10-15% of hardware cost per year after warranty
  Drive replacement: 2-5% annual drive failure rate × replacement cost
  Network egress: if cloud (see Day 26)

Template calculation:

Storage system: 1PB NVMe in 4U storage server
  Hardware cost: 4 servers × $50K = $200K (NVMe heavy)
  Annual power: 4 servers × 500W × 8760h × $0.10/kWh = $1,752/yr
  Annual cooling (PUE 1.5): $1,752 × 0.5 = $876/yr
  Annual maintenance (10%): $20K/yr
  Annual drive replacement (3% failure): ~$3K/yr (estimated)
  Staff (0.25 FTE × $150K/yr): $37,500/yr

5-year TCO:
  CapEx (amortized): $200K / 5 = $40K/yr
  OpEx/yr: $1,752 + $876 + $20K + $3K + $37.5K = $63K/yr
  
  Year 1: $200K (upfront) + $63K = $263K
  Years 2-5: $63K/yr each
  Total 5-year: $263K + 4 × $63K = $515K
  
  Per GB per month: $515K / (1000TB × 1000 × 60 months) = $0.0086/GB/month
  Compare AWS S3: $0.023/GB/month
  On-premises: 2.7× cheaper per GB at 1PB scale
```

---

# Day 28: Capacity Planning — Growth Models

## Key Content

```
Growth model types:

Linear growth:
  New_capacity(t) = current + rate × t
  Use: mature product with stable growth (add 10TB/month)
  Risk: underestimates exponential phases

Exponential growth:
  New_capacity(t) = current × (1 + growth_rate)^t
  Use: fast-growing products (30% YoY growth)
  Example: 10TB today, 30% annual growth
    Year 1: 13TB, Year 2: 16.9TB, Year 3: 22TB, Year 5: 37TB

Seasonal growth (adjust exponential for seasonality):
  Monthly multiplier: peak months get 1.5× average, slow months 0.7×
  Example: e-commerce storage peaks in Nov/Dec (holiday backups, images)

Building the capacity plan:

Step 1: Baseline current usage
  df -h (filesystem level)
  du -sh /data/* (per-application)
  Historical trend from monitoring (last 12-24 months)

Step 2: Identify growth drivers
  What is driving storage growth?
  - User count growth: +20% users/year = +20% storage/year (if linear)
  - Data retention changes: extending retention 30→90 days = 3× storage
  - New features: video upload = sudden 10× storage for that data type
  - Regulatory: new compliance requirement = 7-year retention (was 1-year)

Step 3: Model with headroom
  Never plan to run at 100% capacity
  Alert threshold: 80% (start procurement)
  Maximum before impact: 90%
  
  Headroom = (max_capacity - alert_threshold) / daily_growth_rate = lead_time
  
  Example: 10TB capacity, 80% alert = 8TB threshold, 90GB/day growth
  At 8TB used, alert fires. Time until 90%: (9TB - 8TB) / 90GB/day ≈ 11 days
  Hardware lead time: 8-12 weeks → need to order at 8TB used (not wait for alert)

Step 4: Hardware procurement cycle
  Order hardware when: projected_usage(t + lead_time) > alert_threshold
  Lead time: 8-16 weeks for custom server build
  
  Automated trigger:
  if projected_capacity_in_90_days > 0.8 × current_max_capacity:
      create_procurement_ticket()
      alert_storage_architect()
```

---

# Day 29: Full Architecture Lab

## End-to-End Design: SaaS Platform Storage

**Brief:**
10,000 customers, average 1TB per customer, 3× annual growth.
Workloads: relational databases (40%), file storage (30%), object storage (20%), ML training data (10%).
5-year planning horizon.

**Year 1 Requirements:**
- Total: 10,000TB = 10PB
- Databases: 4PB NVMe (latency-sensitive)
- File storage: 3PB NVMe (mixed latency)
- Object storage: 2PB HDD (throughput-oriented)
- ML training: 1PB NVMe (sequential read-heavy)

**Storage Engine Decisions (Week 1):**
- Databases: PostgreSQL B-tree (read-heavy OLTP) + RocksDB (for key-value tenant data)
- Object storage: custom LSM-tree metadata + flat object files
- ML training: no storage engine (raw sequential reads from object storage)

**Data Reduction (Week 2):**
- Databases: compression (Zstd level 3) on cold pages — 2× ratio
- File storage: dedup (post-process, 10-day lag) + LZ4 compression — estimated 3× total
- Object storage: content-defined dedup — estimated 5× (many customers upload same files)
- ML training data: no dedup/compression (already preprocessed, incompressible)

**Physical capacity after reduction:**
- Databases: 4PB / 2 = 2PB NVMe
- File: 3PB / 3 = 1PB NVMe
- Object: 2PB / 5 = 400TB HDD
- ML: 1PB NVMe (no reduction)
- **Total physical: ~4.4PB**

**Tiering Policy (Day 22):**
- Database: all on NVMe (latency-sensitive, no tiering within DB tier)
- File storage: hot files (accessed last 7 days) → NVMe; cold → HDD
- Object storage: recent objects → NVMe cache; all others → HDD
- Heat tracking: exponential decay λ=0.1/hr, PROMOTE>15, DEMOTE<5

**Reliability Architecture (Week 3):**
- RAID-6 for all NVMe (tolerate 2 drive failures per array)
- 3-replica for object storage (Ceph pools)
- SLOs: p99 < 5ms for database storage, p99 < 50ms for file, p99 < 200ms for object
- Chaos experiments: quarterly game days, monthly automated OSD failure tests
- Runbooks: all failure modes from taxonomy covered

**5-Year Capacity Forecast (Day 28):**
- Year 1: 4.4PB physical
- Year 2 (+3×?): Actually 3× annual growth on USER DATA; reduction ratios stay same
  - Year 2: 4.4PB × 3 = 13.2PB physical → too aggressive, assume 3× data growth
  - More realistic: 30% annual data growth (3× over 5 years, not per year)
  - Year 5: 4.4PB × (1.3)^4 ≈ 12.5PB physical

**5-Year TCO:**
- Year 1 hardware: ~$5M (4.4PB mixed NVMe + HDD)
- Annual opex: ~$800K/yr (power, cooling, staff)
- Year 3 refresh: ~$3M (partial hardware refresh)
- Total 5-year: ~$12M
- Per customer per month: $12M / (10K customers × 60 months) = $20/customer/month (storage only)

---

# Day 30: Final Review & Month 4 Roadmap

## Month 3 Competency Check

**Storage Engines:**
- B-tree write amplification formula for random updates
- LSM-tree: why leveled compaction has lower RA than size-tiered
- WiscKey: when key-value separation helps vs hurts
- Log-structured: why time-series databases prefer it over LSM

**Data Reduction:**
- Correct pipeline ordering: dedup → compress → encrypt
- Why CDC outperforms fixed-size chunking for modified files
- Break-even analysis: when dedup is worth the overhead
- Thin provisioning: what happens at 100% pool utilization

**Reliability:**
- Gray failure vs hard failure: detection and impact difference
- Error budget: calculate from SLO
- Chaos hypothesis: what makes a good one
- Runbook: what makes it executable by on-call without expertise

**Advanced:**
- Young's formula: optimal checkpoint interval
- HNSW vs IVF-PQ: when each is appropriate
- Egress cost: why it causes vendor lock-in
- Heat tracking: why hysteresis prevents oscillation

---

## Final Scenario: The Executive Brief

**Prompt:** "You are the storage architect for a company about to IPO. The CTO asks: what is our storage strategy for the next 3 years?"

**Executive Brief (1 page):**

Our storage strategy over the next 3 years focuses on three pillars: efficiency, reliability, and flexibility.

**Efficiency:** We will implement data reduction across all tiers — content-defined deduplication for user files and object storage (targeting 4-5× reduction), Zstd compression for database and log data (2-3× reduction), and automated tiering that moves cold data to HDD while keeping hot data on NVMe. Combined, this reduces our storage cost by 60% versus naive storage, extending our current infrastructure to support 3× growth without proportional hardware spend.

**Reliability:** We will implement a comprehensive reliability framework including quarterly chaos engineering game days, per-device latency-based gray failure detection (alerting within 5 minutes of any drive showing fail-slow behavior), and fully tested runbooks for all failure modes. Our SLOs — p99 < 5ms for database storage, 99.99% availability — will be backed by automated error budget tracking and burn rate alerts. We will achieve zero unplanned outages related to storage in Year 2 after implementing this program.

**Flexibility:** We will adopt S3-compatible APIs for all object storage (using MinIO on-premises), avoiding cloud vendor lock-in while maintaining the option to migrate or burst to cloud. Our tiered storage design separates hot data (NVMe, on-premises) from cold data (HDD, potentially cloud) allowing cost optimization without architectural changes.

**Investment:** Year 1 infrastructure investment: $5M. 5-year TCO including opex: $12M. Alternative (AWS S3 equivalent): $35M over 5 years. Net savings: $23M, funding 2 additional engineering teams.

---

## Month 4 Roadmap

Based on completing Months 1-3, you now have:
- Deep Linux kernel storage knowledge (Month 1)
- Distributed storage internals (Month 2)
- Hardware essentials + design patterns (Month 3)

The remaining gap for a fully-rounded storage architect:

**Month 4 candidates (choose based on your current role):**

If your work involves **product/customer-facing architecture:**
→ Deep study of storage for specific verticals: databases (PostgreSQL/MySQL internals), Kubernetes storage (CSI, persistent volumes), and cloud-native patterns (object storage as primary store)

If your work involves **building storage systems:**
→ Kernel storage development: writing block device drivers, device mapper targets, eBPF storage tools, contributing to open source (Ceph, RocksDB)

If your work involves **enterprise/cloud architecture:**
→ Advanced cost modeling, multi-cloud storage strategy, storage for AI at hyperscale, storage benchmarking methodology (how to run rigorous benchmarks that hold up to peer review)

The foundation is solid. Month 4 should be driven by what you most need in your specific role — not by what's theoretically next in the curriculum.
