# Month 2 Day 8: Erasure Coding — Reed-Solomon Math

## Learning Objectives
- Understand Galois Field GF(2^8) arithmetic and why it's used
- Understand the generator matrix approach to RS codes
- Implement RS(4,2): 4 data shards + 2 parity shards
- Verify that any 4 of 6 shards can reconstruct the original data

---

## 1. Why Galois Fields?

Erasure coding requires arithmetic where division always works (no fractions).
Ordinary integers: 3/2 = 1.5 (not an integer) → can't use for finite block arithmetic.
GF(2^8): a field of 256 elements where all arithmetic stays within 0..255.

```
GF(2^8) properties:
  256 elements: 0, 1, 2, ..., 255 (fit in one byte — perfect for storage)
  Addition: XOR (a ⊕ b) — no carries, always stays in 0..255
  Multiplication: polynomial multiplication modulo an irreducible polynomial
    Standard: x^8 + x^4 + x^3 + x^2 + 1 (0x11d)
  Division: multiply by multiplicative inverse (always exists for non-zero elements)
  
Why XOR for addition:
  In GF(2): 1+1=0, 0+1=1, 0+0=0 (no carry)
  GF(2^8) extends this to bytes: add coefficients mod 2 = XOR bits
  
Key property for erasure coding:
  Any k×k submatrix of the generator matrix is invertible
  → Any k shards from k+m can reconstruct all k original shards
```

---

## 2. Reed-Solomon Encoding

```
RS(k, m) parameters:
  k = number of data shards (original data split into k pieces)
  m = number of parity shards (redundancy)
  Total shards: k + m
  Can recover from any m shard losses

Encoding with generator matrix G (k+m rows × k columns):
  
  G = [I_k]     ← identity matrix (data shards = original data)
      [P  ]     ← parity matrix (parity shards = linear combinations)

  Encoded shards = G × data_vector (in GF(2^8))

Example: RS(4, 2)
  4 data shards: d0, d1, d2, d3
  2 parity shards: p0, p1

  G = [1 0 0 0]   d0 = d0 (identity)
      [0 1 0 0]   d1 = d1
      [0 0 1 0]   d2 = d2
      [0 0 0 1]   d3 = d3
      [1 2 4 8]   p0 = d0 ⊕ (2·d1) ⊕ (4·d2) ⊕ (8·d3)
      [1 3 5 f]   p1 = d0 ⊕ (3·d1) ⊕ (5·d2) ⊕ (f·d3)
  (multiplication is GF(2^8) multiplication)

Recovery: if shards i, j are lost:
  Select 4 rows from G corresponding to surviving shards
  Invert the 4×4 submatrix (always possible for Vandermonde-derived G)
  Multiply inverse by surviving shard data → recover d0..d3
```

---

## 3. Hands-On: RS(4,2) Implementation

```python
# Install: pip install galois
import galois
import numpy as np

GF = galois.GF(2**8)

# Data: 4 shards of 1 byte each (extend to blocks in practice)
data = GF([0x48, 0x65, 0x6c, 0x6c])  # "Hell"

# Generator matrix for RS(4,2) using Vandermonde construction
# Rows: k+m=6, Cols: k=4
k, m = 4, 2
alpha = GF.primitive_element  # generator element of GF(2^8)

# Vandermonde matrix: G[i][j] = alpha^(i*j)
G = GF([[alpha**(i*j) for j in range(k)] for i in range(k+m)])

# Encode
shards = G @ data  # GF(2^8) matrix multiplication
print("Encoded shards:", shards)

# Simulate losing shards 1 and 4 (indices 1, 4)
lost = [1, 4]
surviving_indices = [i for i in range(k+m) if i not in lost][:k]
print("Using shards:", surviving_indices)

# Select rows from G for surviving shards
G_sub = G[surviving_indices]

# Select corresponding shard data
shards_sub = shards[surviving_indices]

# Recover: data = G_sub^-1 × shards_sub
data_recovered = np.linalg.solve(G_sub, shards_sub)
print("Recovered data:", data_recovered)
print("Match:", np.array_equal(data, data_recovered))
```

---

## 4. Performance Characteristics

```
RS(k, m) storage overhead: (k+m)/k
  RS(4,2): 6/4 = 1.5× (50% overhead, like 3-way replication but less)
  RS(6,3): 9/6 = 1.5×
  RS(8,2): 10/8 = 1.25× (25% overhead, 2 failures tolerated)
  RS(12,4): 16/12 = 1.33× (Azure LRC baseline)

3-way replication: 3× overhead (tolerates 2 failures)
RS(4,2): 1.5× overhead (tolerates 2 failures) — less storage, more CPU
RS(8,2): 1.25× overhead (tolerates 2 failures) — even less storage

Decode CPU cost:
  k×k matrix inversion + k vector multiplications
  For 4KB blocks: microseconds on modern CPU with SIMD
  Intel ISA-L library: optimized RS for x86 with AVX2/AVX-512

Repair cost (the key difference vs replication):
  RS(4,2) repair of 1 lost shard: must read ALL 4 other data shards
  3-way replication repair: read just 1 surviving replica
  → RS repair traffic >> replication repair traffic (covered Day 9)
```

---

## 5. Self-Check

1. Why is GF(2^8) used rather than standard integer arithmetic for erasure coding?
2. RS(4,2): if shards 0 and 5 are lost, which shards are used for recovery?
3. What is the storage overhead of RS(6,3)? Compare to 3-way replication for the same failure tolerance.

## 6. Answers

1. Storage requires arithmetic over bytes (0..255). Standard integers: division produces fractions (e.g., 3/2 = 1.5), which can't be stored in a byte. GF(2^8) defines multiplication and division such that all operations stay within 0..255 (using polynomial arithmetic modulo an irreducible polynomial). This allows the matrix operations needed for encoding/decoding to work exactly over byte-sized data.
2. Surviving shards: 1, 2, 3, 4 (any 4 of the 6 work). Select rows 1, 2, 3, 4 from the generator matrix G, invert the resulting 4×4 submatrix, multiply by the 4 surviving shard values to recover d0..d3.
3. RS(6,3): (6+3)/6 = 1.5× storage overhead, tolerates 3 simultaneous shard losses. 3-way replication: 3.0× overhead, tolerates 2 node losses (the third copy is needed if 2 fail). RS(6,3) provides better failure tolerance (3 vs 2) at half the storage cost of 3-way replication.

---

# Month 2 Day 9: Erasure Coding — LRC & Production Variants

## Learning Objectives
- Understand why repair traffic, not storage overhead, drives EC scheme choice at scale
- Understand Local Reconstruction Codes (LRC) — Azure's innovation
- Understand Facebook's f-LRC and the tradeoff space
- Calculate repair traffic for RS vs LRC schemes

---

## 1. The Repair Traffic Problem

```
At scale, disk failures are frequent:
  1000 drives at 1% annual failure rate = 10 failures/year = 1 per 5 weeks
  50,000 drives (large cluster) = 500 failures/year = ~1.4/day

Each failure triggers repair:
  RS(k, m): repair 1 shard → read ALL k data shards
  For RS(12, 4) with 1MB stripe: repair = read 12MB to recover 1MB
  Repair bandwidth amplification = k = 12×

Network impact:
  50,000 drives × 1.4 failures/day = ~720TB/day of repair traffic on a 10PB cluster
  At RS(12,4): 720TB × 12 = 8.6PB of repair traffic per day
  This saturates 100GbE storage network
```

---

## 2. Local Reconstruction Codes (Azure LRC)

```
LRC insight: most failures are single-drive failures.
For a single failure, you don't need all k shards — only the local group.

Azure LRC(12, 2, 2):
  12 data shards (k=12)
  2 global parity shards (r=2, like RS parity, tolerate any 2 failures)
  2 local parity shards (l=2, each covers half the data shards)

Layout:
  Group 1: d0, d1, d2, d3, d4, d5 → local parity p_local1
  Group 2: d6, d7, d8, d9, d10, d11 → local parity p_local2
  Global:  d0..d11 → global parity pg0, pg1

Single failure repair (most common case):
  Lose d3: only read d0,d1,d2,d4,d5,p_local1 (6 shards, not 12)
  Repair traffic: 6× instead of 12× → 2× improvement for common case

Double failure requiring global parity:
  Lose d3 and d9: use global parities (pg0, pg1) → read all 12 shards
  Still correct, just slower (rare case)

Storage overhead: (12+2+2)/12 = 1.33× (same as RS(12,4))
Failure tolerance: same as RS(12,4) — any 4 failures tolerated
Repair bandwidth: 2× better for single failures (common case)
```

---

## 3. Repair Traffic Calculation

```python
# Compare repair traffic for common EC schemes

def repair_traffic(scheme):
    if scheme == "3-replication":
        # Read 1 full replica to reconstruct lost replica
        return 1.0  # read factor (relative to stripe size/k)

    elif scheme == "RS(4,2)":
        k = 4
        return k   # must read all k data shards

    elif scheme == "RS(12,4)":
        k = 12
        return k

    elif scheme == "LRC(12,2,2)":
        local_group_size = 6   # each local group has 6 data shards + 1 local parity
        return local_group_size  # single failure: read local group

    elif scheme == "RS(6,3)":
        k = 6
        return k

# Results:
# 3-replication: 1× (read 1 shard to repair)
# RS(4,2):       4× repair traffic
# RS(6,3):       6× repair traffic
# RS(12,4):      12× repair traffic
# LRC(12,2,2):   6× for single failure (2× better than RS(12,4))
```

---

## 4. Facebook's f-LRC (Xorbas)

```
Facebook's insight: can we do even better repair with more local groups?

f-LRC adds more local parity shards:
  Each data shard belongs to TWO local groups (not one)
  Repair can use either local group → smaller repair group

Example: Facebook's production scheme
  14 data shards
  Multiple local parities covering subsets of 7
  2 global parities

Single failure: read ~7 shards (instead of 14)
Double failure in same local group: use other local group → still small repair
Tradeoff: more storage overhead (more local parities) for less repair traffic

Key lesson for architects:
  EC scheme design is a 3-way tradeoff:
    Storage overhead vs repair traffic vs failure tolerance
  No scheme dominates all three simultaneously
  Choose based on your cluster's failure rate and network bandwidth cost
```

---

## 5. Self-Check

1. A cluster has RS(12,4) with 1TB stripes. How much data must be read to repair one failed shard?
2. LRC(12,2,2) is said to have "local" and "global" parities. What is the difference in when each type is used?
3. A cluster operator says: "I want to minimize repair traffic while tolerating 2 simultaneous failures." What EC scheme trade-off should you discuss?

## 6. Answers

1. RS(12,4): one stripe = 12 data shards + 4 parity. Each shard = 1TB/12 ≈ 83GB. To repair one failed shard: read all 12 data shards (or 12 surviving shards) = 12 × 83GB ≈ 1TB of read traffic to recover 83GB. Repair amplification = 12×.
2. Local parities cover a subset (local group) of data shards and are used for single-shard failures within that group — small repair group (6 shards instead of 12). Global parities span all data shards and are used when local parity can't help: when both a data shard and its local parity fail simultaneously, or for failures across different local groups. Global repair requires reading all 12 data shards.
3. Discuss LRC. RS(k,2) minimizes storage overhead (1 + 2/k) but repair traffic = k (grows with k). 3-way replication minimizes repair traffic (1×) but 3× storage. LRC provides a middle ground: storage overhead similar to RS, repair traffic ~k/2 for common single failures. The tradeoff: LRC adds more parity shards (higher storage overhead vs RS) but reduces repair traffic significantly. For a large cluster with frequent single failures and constrained network bandwidth, LRC is usually the right choice.

---

# Month 2 Day 10: Erasure Coding — Repair Traffic & Ceph EC Pools

## Learning Objectives
- Understand how Ceph implements EC pools (partial reads, recovery)
- Design EC placement for a 3-failure-domain cluster
- Understand the interaction between EC and PG (placement group) design
- Know when EC is preferable to replication in Ceph

---

## 1. Ceph EC Pool Architecture

```
Ceph EC pool vs replication pool:
  Replication: each object stored on k OSDs as full copies
  EC: each object split into k+m chunks, one chunk per OSD
  
Object write path (EC pool):
  1. Client sends full object to primary OSD
  2. Primary encodes: splits object into k data chunks + m parity chunks
  3. Primary sends each chunk to corresponding OSD
  4. All OSDs ack → primary acks to client

Object read path (EC pool):
  Partial read: if reading small region of large object:
    Only request the specific chunks covering that region
    Decode locally — no need to read all k chunks for a partial read
    More efficient than reading all k data shards

Recovery path (OSD failure):
  Lost OSD had chunk i of many objects
  For each affected object: read k surviving chunks → decode → re-encode chunk i
  Repair traffic: k reads per object
```

---

## 2. EC Placement Design for 3-Failure-Domain Cluster

```
Failure domains: datacenter (DC), rack, host, OSD
Goal: tolerate any 2 OSD failures without data loss

Naive RS(4,2) placement (wrong):
  6 chunks placed on 6 OSDs in same rack
  Single rack switch failure = all 6 chunks lost → data loss!

Correct placement: spread across failure domains

For RS(4,2) across 3 DCs:
  DC1: chunk 0, chunk 1
  DC2: chunk 2, chunk 3
  DC3: chunk 4 (parity 0), chunk 5 (parity 1)

  Single DC failure: lose 2 chunks → recoverable (m=2)
  Single rack failure within DC: lose at most 2 chunks (if 2 racks per DC)
  
CRUSH rule for this placement:
  rule ec_3dc {
    step take root
    step choose indep 3 type datacenter  # choose 3 DCs
    step chooseleaf indep 2 type host    # 2 hosts per DC
    step emit
  }
```

---

## 3. EC vs Replication: When to Use Each in Ceph

```
Use REPLICATION for:
  - Metadata (RBD headers, CephFS MDS journals) — low latency reads critical
  - Small objects (<4MB) — EC overhead per object is high
  - Write-heavy workloads — EC encodes on every write (CPU + latency)
  - Random read/write patterns — partial EC decode adds overhead

Use EC for:
  - Large objects (>4MB) — amortizes encoding overhead
  - Cold data (archives, backups) — rarely read, write-once
  - Cost-sensitive (less storage overhead vs 3× replication)
  - Sequential read workloads — no partial decode penalty

Practical Ceph configuration:
  Default pool: 3× replication (hot data, metadata)
  Archive pool: EC(8,3) or EC(6,3) (cold data, reduces storage 50%)
```

---

## 4. Hands-On: Ceph EC Pool

```bash
# Create EC profile
ceph osd erasure-code-profile set myec \
    k=4 m=2 \
    crush-failure-domain=host \
    plugin=jerasure \
    technique=reed_sol_van

# Create EC pool
ceph osd pool create ec-pool 64 erasure myec

# Verify profile
ceph osd erasure-code-profile get myec

# Write a large object
rados -p ec-pool put testobj /tmp/largefile.bin

# List object chunks across OSDs (shows which OSD has which chunk)
ceph osd map ec-pool testobj

# Force OSD failure and observe recovery
ceph osd out osd.3   # simulate OSD failure
watch -n1 "ceph health detail | grep -i recover"
# Observe: recovery reads k=4 chunks per affected object
```

---

# Month 2 Day 11: Consistent Hashing — Models & Tradeoffs

## Learning Objectives
- Understand consistent hashing, virtual nodes, CRUSH, and jump consistent hash
- Know the data movement calculation for each approach on node addition/removal
- Understand why CRUSH gives deterministic placement without a placement table
- Know when each approach is used in production systems

---

## 1. Basic Consistent Hashing

```
Problem: distribute N objects across K nodes such that
         adding/removing a node moves minimum objects.

Naive modulo: object i → node (hash(i) % K)
  Add node: need to move (K-1)/K of all objects (most objects)

Consistent hashing (Karger, 1997):
  Hash space: ring [0, 2^32)
  Node placement: each node mapped to one point on ring
  Object placement: object → hash → walk clockwise to first node
  
  Add node: only objects between new node and its predecessor move
  Average objects moved on add: N/K (optimal)

Problem with basic consistent hashing:
  Uneven load distribution (hot spots)
  Hash function may place nodes unevenly on ring
```

---

## 2. Virtual Nodes (vnodes)

```
Solution: each physical node maps to multiple points on ring (vnodes)

Cassandra: 256 vnodes per node by default
  Physical node A → vnode 0, vnode 73, vnode 141, ... (256 random points)
  Physical node B → vnode 7, vnode 89, vnode 200, ... (256 random points)
  Objects distributed across all 256×N_nodes points

Benefits:
  + Even load distribution (many points = smooth distribution)
  + Heterogeneous nodes: more powerful nodes → more vnodes → more load
  + Node addition/removal: moves objects from many small ranges (gradual)

Downsides:
  - Requires a placement table (node → vnode mapping stored somewhere)
  - Table size grows with cluster size
  - DynamoDB: uses a coordination service to maintain vnode table
```

---

## 3. CRUSH: Deterministic Placement Without a Table

```
CRUSH (Controlled, Scalable, Decentralized Placement):
  Ceph's placement algorithm — no placement table needed

Input:  (object_name, cluster_map, placement_rule)
Output: list of OSDs that store this object

cluster_map: describes physical cluster topology
  - Hierarchy: datacenter → rack → host → OSD
  - Weights: storage capacity of each OSD

placement_rule: describes how to traverse the hierarchy
  rule replicated_rule {
    step take root               # start at root of hierarchy
    step choose firstn 3 type host  # choose 3 distinct hosts
    step chooseleaf firstn 1 type osd  # from each host, choose 1 OSD
    step emit
  }

CRUSH algorithm (simplified):
  1. Traverse hierarchy level by level
  2. At each level: use CRUSH hash function to select children
     CRUSH_HASH(object_id, bucket_id, attempt) → deterministic selection
  3. Result: same input always gives same output (deterministic)
  4. No coordination needed — any client can compute placement

Benefits:
  + No placement table (scales to millions of objects automatically)
  + Any client/OSD can compute placement independently
  + Topology-aware: can constrain placement across failure domains
  + Weighted: large OSDs get proportionally more objects

Data movement on OSD addition:
  New OSD added with weight W in a bucket of total weight T_before
  Objects moved = N_objects × W/(T_before + W)
  Approximately: W/T_before fraction of the cluster's objects rebalance
```

---

## 4. Jump Consistent Hash

```
Jump consistent hash (Lamping & Veach, Google, 2014):
  Extremely fast O(ln K) algorithm for consistent hashing
  No ring, no table — purely mathematical

  int32_t JumpConsistentHash(uint64_t key, int32_t num_buckets) {
      int64_t b = -1, j = 0;
      while (j < num_buckets) {
          b = j;
          key = key * 2862933555777941757ULL + 1;
          j = (b + 1) * (double(1LL << 31) / double((key >> 33) + 1));
      }
      return b;
  }

Benefits: fast (< 100ns), even distribution, minimal data movement
Limitations: only supports adding/removing from the END of the server list
             (can't remove arbitrary servers — doesn't work for general clusters)
Use case: Google's internal cluster load balancing, not storage
```

---

## 5. Comparison Table

| Scheme | Placement Table | Data Movement on Add | Topology Awareness | Production Use |
|--------|----------------|---------------------|-------------------|----------------|
| Modulo | No | Nearly all data | No | Cache sharding (small scale) |
| Consistent Hash | No (ring) | Optimal (1/K fraction) | No | Original Akamai CDN |
| Virtual Nodes | Yes (vnode table) | Optimal, gradual | Partial | Cassandra, DynamoDB |
| CRUSH | No (cluster map) | Optimal | Yes (full hierarchy) | Ceph |
| Jump Consistent | No | Optimal | No | Internal Google load balancing |

---

## 6. Self-Check

1. Why do virtual nodes improve load balance compared to one hash point per node?
2. CRUSH can compute object placement without any coordination. What information does a client need to do this computation?
3. A 100-node cluster using consistent hashing adds 1 node. What fraction of objects must move?

## 7. Answers

1. With one hash point per node, the ring segment each node "owns" varies in size due to hash function distribution — some nodes get large segments (hot), others small (cold). With 256 vnodes per node, each node's total ring segment is the sum of 256 small segments scattered across the ring. By the law of large numbers, these sum to approximately equal total segments across nodes → even load.
2. The client needs: (1) the cluster map (hierarchy of datacenters/racks/hosts/OSDs and their weights), (2) the placement rule for the pool, (3) the object name/ID. With these three inputs, any client independently runs CRUSH and gets the same OSD list without contacting any coordinator.
3. 1/(100+1) ≈ 1% of objects. Consistent hashing achieves optimal movement: adding 1 node to K nodes requires moving N/(K+1) objects. For 100→101 nodes: move N/101 ≈ 1% of objects. Compare to modulo: would need to move ~99% of objects.

---

# Month 2 Days 12-14: Replication Models & Week 2 Review

## Day 12: Data Placement & Rebalancing

### CRUSH Map Design for 3-DC Cluster

```bash
# Ceph CRUSH map for 3-datacenter deployment
# Goal: tolerate any single DC failure (RF=3, one copy per DC)

# Start with current CRUSH map
ceph osd getcrushmap -o /tmp/crushmap.bin
crushtool -d /tmp/crushmap.bin -o /tmp/crushmap.txt

# Add datacenter buckets
# Edit crushmap.txt to add:
# datacenter dc1 { ... }  -- contains racks in DC1
# datacenter dc2 { ... }  -- contains racks in DC2
# datacenter dc3 { ... }  -- contains racks in DC3

# Rule for cross-DC replication:
rule cross_dc {
    id 1
    type replicated
    min_size 3
    max_size 3
    step take default
    step choose firstn 3 type datacenter   # one OSD per DC
    step chooseleaf firstn 1 type osd
    step emit
}

# Apply and verify
crushtool -c /tmp/crushmap_new.txt -o /tmp/crushmap_new.bin
ceph osd setcrushmap -i /tmp/crushmap_new.bin
ceph osd pool set mypool crush_rule cross_dc

# Simulate node addition and calculate data movement
# Before: 10 OSDs, 1000 PGs
# Add 1 OSD: PGs that must move = 1000 × (1/11) ≈ 91 PGs
# Each PG = 1GB data: 91GB must rebalance
ceph osd reweight-by-utilization  # auto-rebalance for utilization
```

---

## Day 13: Chain Replication

### Chain Replication vs Primary-Backup

```
Primary-Backup (Raft, Ceph default):
  Write: client → primary → all replicas in parallel → ack when quorum acks
  Read: client → primary → serve (leader serves all reads)
  Failure: primary failure → election → new primary catches up followers

Chain Replication (van Renesse & Schneider, 2004):
  Servers arranged in a chain: HEAD → server1 → server2 → TAIL
  Write: client → HEAD → chain propagates → TAIL acks client
  Read: client → TAIL (always consistent — tail has all committed writes)

Chain Replication properties:
  Strong consistency: reads always from tail (most up-to-date)
  Write throughput: pipelined — HEAD doesn't wait for tail before next write
  Read scalability: any server can serve reads (CRAQ extension)

CRAQ (Chain Replication with Apportioned Queries):
  Each server tracks "clean" vs "dirty" entries
  Read can be served by any server:
    If entry is clean at this server: serve immediately
    If entry is dirty: query tail for committed version
  Result: read throughput scales with chain length

When chain replication wins over primary-backup:
  + Read scalability (CRAQ): all servers serve reads
  + Write throughput: pipelining hides replication latency
  - Write latency: tail must ack before client sees success
    (chain length = k → write latency = k × RTT vs primary-backup = 1 RTT + ε)
  - Failure recovery: reconfiguring chain on failure is complex
  Production use: Amazon Aurora uses chain-like replication for log segments
```

---

## Day 14: Week 2 Review — Replication Architecture Decision Guide

### The Decision Matrix

| Requirement | Best Approach | Reason |
|-------------|--------------|--------|
| 2 failures, 50% storage overhead | RS(4,2) | Same failure tolerance as 3× replication at half cost |
| Minimize repair traffic, 2 failures | LRC(12,2,2) | Local groups halve repair traffic vs RS |
| 3 DC failure tolerance | RS(6,3) cross-DC or 3× replication | Each approach stores one full copy per DC |
| Small objects, low latency | 3× replication | EC encoding overhead unacceptable for small objects |
| Cross-rack failure isolation | CRUSH with rack failure domain | Topology-aware placement |
| Independent client placement | CRUSH | No coordination needed |
| Gradual rebalancing | Virtual nodes | Many small movements |
| Read scalability | Chain replication (CRAQ) | All servers can serve reads |

### Design Scenario: 5PB Object Store, 3 DCs, Minimize Repair Traffic

**Brief:** 3 datacenters, each with 20 storage nodes × 100TB each = 6PB raw per DC.
Total: 18PB raw. Target: 5PB usable. 2-DC failure tolerance. Minimize repair traffic.

**Answer:**

1. **EC scheme:** LRC(6,2,2) or LRC(12,2,2). Reasoning: RS(6,3) has 1.5× overhead and 6× repair traffic. LRC(12,2,2) has 1.33× overhead and 6× repair traffic for single failures (12× for double). For 3-DC, a cross-DC LRC where local groups map to racks within a DC is optimal.

2. **Cross-DC placement:** Place local group 1 in DC1, local group 2 in DC2, global parities split across DC1/DC2/DC3. Single DC failure: still have all global parities + one local group → recoverable. Single node failure within a DC: use local group parity → read only within that DC.

3. **Repair traffic:** Single-node failure in DC1: read 6 shards within DC1 (local group only). No cross-DC traffic. DC failure: read from DC2 and DC3 to reconstruct → cross-DC repair traffic unavoidable but rare.

4. **Usable capacity:** 18PB raw × (1/1.33) = 13.5PB usable (well over the 5PB target). Over-provisioned — could reduce DC size or use denser EC.

5. **CRUSH rule:** 3 steps: choose 3 DCs, within each DC choose 2 racks, within each rack choose 1 OSD. Ensures failure domain isolation automatically.

---

## Tomorrow: Day 15 — iSCSI Protocol Internals

Week 3 begins: storage network protocols. We read RFC 3720, trace
iSCSI PDU exchanges with Wireshark, and understand how iSCSI
manages sessions, command numbering, and multi-path.
