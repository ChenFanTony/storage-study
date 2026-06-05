# 3FS (Fire-Flyer File System) — Architect Reference

DeepSeek open-sourced 3FS in February 2025 (github.com/deepseek-ai/3FS).
It was the storage layer for DeepSeek-V3 and R1 training.

Related: [memory-hierarchy-reference.md](memory-hierarchy-reference.md),
[checkpoint-reference.md](checkpoint-reference.md),
[training-data-reference.md](training-data-reference.md)

---

## 0. Terminology

| Term | Definition |
|------|-----------|
| 3FS | Fire-Flyer File System — DeepSeek's RDMA-native distributed filesystem for AI |
| CRAQ | Chain Replication with Apportioned Queries — the core replication protocol |
| Chain | An ordered list of storage nodes [HEAD, ..., TAIL] holding replicas of one chunk |
| HEAD | First node in a CRAQ chain; receives all writes from clients |
| TAIL | Last node in a CRAQ chain; is the source of truth for committed state |
| Clean node | A chain node with no pending uncommitted writes — can serve reads directly |
| Dirty node | A chain node that received a write not yet committed by TAIL |
| Chunk | The unit of data distribution in 3FS (default 64 MB) |
| usrbio | 3FS user-space RDMA I/O library — kernel-bypass read path |
| Meta server | Handles namespace: directory tree, file inodes, chunk map |
| Storage server | Holds chunk data on local NVMe; participates in CRAQ chains |
| Placement map | Chunk ID → chain assignment; stored on meta servers |

---

## 1. Background: Why Build a New Filesystem for AI

### 1.1 The AI Training Storage Contract

AI training has a very specific and unusual I/O profile:

```
Checkpoint write:
  Pattern: 1024 ranks each write one large file (~700 MB) simultaneously
  Access: sequential, append-only, no overwrites
  Concurrency: N × 700 MB writes at the same instant (barrier-synchronized)
  Consistency: must be all-or-nothing (partial checkpoint = useless)
  Frequency: every 15-30 minutes

Training data read:
  Pattern: thousands of workers reading dataset shards sequentially
  Access: sequential, read-only, no locality between workers
  Concurrency: extremely high fan-out (1024 readers hitting same files)
  Consistency: eventual is fine (no writes during training)
  Frequency: continuous, every GPU step

Model weight load (at job start):
  Pattern: all ranks read the same weight files simultaneously
  Access: sequential, read-only, high fan-out
  Consistency: read-only, no issues
```

None of the existing filesystems were optimized for this pattern simultaneously:

| System | Checkpoint | Data read | Fan-out | RDMA native |
|--------|-----------|-----------|---------|------------|
| Lustre | Good (wide stripes) | Good | Limited by MDT | LNET (complex) |
| GPFS/GPFS | Good | Good | OK | RDMA optional |
| DAOS | Good | Good | Good | Yes (CaRT) |
| Ceph/CephFS | OK | OK | Limited by MDS | No |
| NFS | Poor | Poor | Very limited | No |
| **3FS** | **Excellent** | **Excellent (CRAQ)** | **Excellent** | **Yes (core)** |

### 1.2 The Read Fan-Out Problem

In training with 1024 GPUs, each reading the same 10 TB dataset:

```
Without replication (or with only 1 readable replica):
  Total read BW = 1 NVMe per shard × 7 GB/s = 7 GB/s per shard
  1024 readers saturate → serialized wait → GPU starvation

With 3× CRAQ replication (any replica can serve reads):
  Total read BW = 3 NVMe per shard × 7 GB/s = 21 GB/s per shard
  3× the fan-out capacity → GPU starvation much less likely

With N replicas, CRAQ scales read throughput linearly as O(N)
This is CRAQ's central AI advantage over Raft or plain chain replication
```

---

## 2. CRAQ Protocol — Background Theory

### 2.1 Chain Replication (Renesse & Schneider 2004)

The predecessor to CRAQ. Nodes arranged in a chain: N₁ → N₂ → N₃.

```
Write:
  Client → N₁ (HEAD) → N₂ → N₃ (TAIL) → ack → N₂ → N₁ → client
  Write is committed when TAIL has persisted it
  All nodes apply writes in the same order (the chain order)

Read:
  Client → N₃ (TAIL) only
  Only TAIL serves reads (ensures strong consistency: TAIL always has latest committed state)

Properties:
  Strong consistency: reads always see latest committed write
  Write throughput: limited by slowest link in chain (pipelined)
  Read throughput: ONLY TAIL serves reads → bottleneck at TAIL for high fan-out
  Read limitation: 3× replication does NOT give 3× read throughput
```

### 2.2 CRAQ (Terrace & Freedman 2009) — The Key Extension

CRAQ allows **any** node to serve reads, not just TAIL. The insight: a non-TAIL node
can serve a read if it is "clean" — if it has no uncommitted writes pending.

**Per-node version tracking:**
```
Each object O on each node stores:
  committed_version: the latest version TAIL has committed for O
  versions[]: list of (version, data) pairs for pending (uncommitted) writes

A node is clean for object O if len(versions) == 0
A node is dirty for object O if len(versions) > 0
```

**Write path (same as chain replication):**
```
Client → HEAD: write(O, data, version=v)
HEAD: append (v, data) to versions[] → propagate to next node
...
TAIL: append (v, data) to versions[] → fsync to NVMe
      committed_version = v
      send ACK back up chain

Each node on ACK receipt:
  remove all versions[] with version ≤ v (they are now committed)
  committed_version = v
  if this is HEAD: send commit ACK to client
```

**Read path — the CRAQ innovation:**
```
Client → ANY node N: read(O)

N checks: is O clean? (versions[] is empty)
  YES (clean): return data at committed_version  [fast path, no coordination]
  NO  (dirty): N sends version_query(O) to TAIL
               TAIL returns committed_version CV
               N returns data at version CV from its local versions[]
```

```
Timeline example (3 nodes, write in flight):

t=0: Client writes v=5 to O
t=1: HEAD receives write, versions=[5], propagates to MIDDLE
t=2: MIDDLE receives write, versions=[5], propagates to TAIL
t=3: TAIL receives write, versions=[5], fsyncs, committed_version=5
     TAIL sends ACK

During t=1 to t=3:
  Client reads from MIDDLE: MIDDLE.versions=[5] → dirty → query TAIL
  TAIL.committed_version = 4 (old, write not committed yet)
  MIDDLE returns data at version 4  [correct: client's write not yet committed]

After t=3, ACK arrives at MIDDLE:
  MIDDLE.versions=[] → clean → return data at committed_version=5  [correct]
```

**Consistency guarantee:** CRAQ provides **linearizability** — equivalent to Raft's
strong consistency, but with N× read throughput for clean reads.

**When does the dirty path activate?**
Only during an in-flight write. For read-heavy workloads (training data reading),
essentially all reads hit the fast (clean) path after the initial write is committed.

---

## 3. 3FS System Architecture

### 3.1 Component Overview

```
┌──────────────────────────────────────────────────────────────┐
│                      3FS Cluster                             │
│                                                              │
│  ┌─────────────────┐                                        │
│  │  Meta Servers   │  ← Raft consensus, 3-5 replicas       │
│  │  - namespace    │  ← directory tree, inode → chunk map   │
│  │  - chunk map    │  ← chunk_id → chain_id mapping        │
│  │  - chain table  │  ← chain_id → [node_0, node_1, ...]  │
│  └────────┬────────┘                                        │
│           │ (RPC, small metadata ops)                        │
│  ┌────────▼────────────────────────────────────────────┐   │
│  │  Storage Servers (10s to 1000s of nodes)             │   │
│  │                                                       │   │
│  │  Node A (HEAD of chain 0):  [chunk_0_v1] ─RDMA─▶    │   │
│  │  Node B (MID  of chain 0):  [chunk_0_v1] ─RDMA─▶    │   │
│  │  Node C (TAIL of chain 0):  [chunk_0_v1]             │   │
│  │                                                       │   │
│  │  Node D (HEAD of chain 1):  [chunk_1_v1] ─RDMA─▶    │   │
│  │  ...                                                  │   │
│  │                                                       │   │
│  │  Each node: local NVMe array + RDMA NIC               │   │
│  └───────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Clients (GPU training nodes)                           │ │
│  │  - FUSE mount: /mnt/3fs  (POSIX compatible)            │ │
│  │  - usrbio library: RDMA bypass (high performance)      │ │
│  └────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

### 3.2 Metadata Service

The meta server holds:
```
Inode table:
  inode_id → {
    size: u64,
    mtime: timestamp,
    permissions: u32,
    chunk_list: [(chunk_id, chain_id), ...]  # ordered by file offset
  }

Directory tree:
  dir_inode_id → {name → child_inode_id}  (hash map of directory entries)

Chain table:
  chain_id → [node_id_HEAD, node_id_MID, node_id_TAIL]
  (global, updated when nodes join/leave, replicated via Raft)

Placement map:
  chunk_id → chain_id
  Determined by: chunk_id % num_chains  (or consistent hashing)
```

Meta operations (open, stat, mkdir, rename) go through Raft-replicated meta servers.
Data operations (read, write chunk) go directly to storage nodes via RDMA.
This is the key latency isolation: metadata operations are rare for AI workloads.

### 3.3 Storage Server Internals

Each storage server manages local NVMe SSDs:

```
Storage node layout:
  NVMe array (e.g., 8× 7.68 TB = 60 TB per node)
  Chunk store:
    chunk_id → {
      data: raw bytes on NVMe
      committed_version: u64
      pending_versions: [(version, offset, data)]  # CRAQ dirty state
    }

Write pipeline on HEAD node:
  1. Receive RDMA WRITE from client (data lands directly in NIC memory)
  2. DMA from NIC → NVMe (via DMA engine, no CPU copy)
  3. Propagate to next chain node via RDMA WRITE
  4. On ACK from next node: advance committed_version

Read pipeline (clean node):
  1. Receive RDMA READ request from client (or usrbio READ)
  2. DMA from NVMe → NIC RDMA buffer
  3. NIC sends data directly to client GPU HBM (GPU-Direct RDMA)
```

---

## 4. Data Path (Detailed)

### 4.1 Write Path — Checkpoint Example

1024 training ranks each write a 683 MB checkpoint shard simultaneously:

```
Rank 0 write sequence for file /ckpt/step_1000/rank_0.bin:

Step 1: Open file
  Client → Meta server: create("/ckpt/step_1000/rank_0.bin")
  Meta server: allocate inode, allocate ceil(683MB / 64MB) = 11 chunks
               assign chunk_ids [c0..c10], assign to chains [ch0..ch10]
  Meta server → Client: inode_id, [(c0, ch0), (c1, ch1), ..., (c10, ch10)]

Step 2: Write chunk c0 (64MB) to chain ch0
  Chain ch0 = [NodeA (HEAD), NodeB (MID), NodeC (TAIL)]
  
  Client RDMA WRITE (GPU-Direct): data[0:64MB] → NodeA's registered MR
  NodeA: receive 64MB → write to local NVMe
         propagate via RDMA WRITE → NodeB's MR
  NodeB: receive 64MB → write to local NVMe
         propagate via RDMA WRITE → NodeC's MR
  NodeC: receive 64MB → fsync to local NVMe (durable)
         send ACK RDMA MSG → NodeB → NodeA → Client
  
  Client: chunk c0 write committed

Step 3: Repeat for chunks c1..c10 (pipelined — send c1 while c0 propagates)

Step 4: Close file
  Client → Meta server: update inode size = 683MB, mtime = now
  Meta server: replicate via Raft → durable commit record

Total write time (683 MB, one rank):
  NVMe write: 683 MB / 7 GB/s = 97 ms per node in chain
  Chain propagation (pipelined): ≈ 97 ms (TAIL durable = bottleneck)
  RDMA transfer per hop: 683 MB / 50 GB/s = 13.6 ms (hidden in pipeline)
  Aggregate for 1024 ranks: each writes to different chains → parallel → same 97 ms
```

### 4.2 Read Path — Training Data Example

Multiple training workers reading the same shard file simultaneously:

```
Scenario: 64 workers all open /data/imagenet/shard_00042.tar (1 GB file = 16 chunks)

Each worker reads a different byte range (by DistributedSampler assignment):
  Worker 0: chunks c0..c3 (256 MB)
  Worker 1: chunks c4..c7 (256 MB)
  ...

For chunk c0 on chain [NodeA, NodeB, NodeC]:
  Workers 0, 3, 6, ... all need c0

Without CRAQ: all go to TAIL (NodeC) → 7 GB/s bottleneck for all workers
With CRAQ:    worker 0 → NodeA, worker 3 → NodeB, worker 6 → NodeC
              NodeA is clean (no writes in flight) → serves directly from NVMe
              Total BW for c0: 3 × 7 GB/s = 21 GB/s

Client usrbio read path (kernel bypass):
  1. Client library calls usrbio_read(chunk_id, offset, length)
  2. Library selects target node (round-robin or least-loaded among chain nodes)
  3. Post RDMA READ: target NVMe → target NIC → IB → client NIC → client GPU HBM
     (GPU-Direct RDMA: 0 memcpy)
  4. Completion notification (CQE from IB NIC)
```

### 4.3 Large File Bandwidth Math

3FS cluster: 100 storage nodes, each with 8× NVMe (7 GB/s each), 3-way CRAQ.

```
Raw NVMe capacity: 100 nodes × 8 × 7 GB/s = 5.6 TB/s
With 3-way replication:
  Write BW = 5.6 / 3 = 1.87 TB/s (writes go to all 3 replicas)
  Read BW  = 5.6 TB/s  (all replicas serve reads independently via CRAQ)

Read/write ratio for AI training:
  Checkpoint writes: periodic, bursty (1 TB every 30 min = 556 MB/s)
  Training data reads: continuous (5-50 GB/s per GPU × 1024 GPUs)
  Net: heavily read-biased → CRAQ's read scaling is the dominant benefit
```

---

## 5. usrbio — Kernel Bypass Interface

### 5.1 The FUSE Tax

FUSE (3FS POSIX mount) adds:
```
Application → VFS → FUSE daemon (user-space) → 3FS client lib → RDMA
Latency tax: 2 context switches (to FUSE daemon and back) = ~10 µs per op
Copy: FUSE may add one userspace→kernel copy for large reads
```

For AI training with 50,000+ I/O ops/sec per worker, FUSE adds:
```
50,000 × 10 µs = 500 ms/sec overhead — significant for small reads
```

### 5.2 usrbio Design

usrbio is a C library that bypasses FUSE entirely:

```c
// Application links against libusrbio.so
#include "usrbio.h"

// Open a file handle (one metadata RPC to meta server)
int fd = usrbio_open("/data/shard_00042.tar", O_RDONLY);

// Issue RDMA READ directly to storage server
// dst_ptr must be in a registered RDMA memory region (GPU HBM or pinned DRAM)
ssize_t n = usrbio_pread(fd, dst_ptr, len, offset);
// Returns when RDMA READ completes: data is in dst_ptr, no CPU involvement
```

Internally:
```
usrbio_pread():
  1. Compute chunk_id = offset / chunk_size
  2. Look up chain from cached placement map
  3. Select a clean node (query clean status or assume clean for read-only files)
  4. Post ibv_post_send (RDMA READ verb) to NIC
  5. Poll CQ (completion queue) for CQE — busy-poll, no sleep/wake
  6. Return on CQE: data already in dst_ptr
```

The busy-poll model mirrors CaRT (DAOS) xstream architecture: no blocking syscalls,
no context switch on the critical I/O path.

**For GPU-Direct RDMA:**
```c
// Register GPU HBM as RDMA MR once at startup
cudaMalloc(&gpu_buf, BUF_SIZE);
struct ibv_mr *mr = ibv_reg_mr(pd, gpu_buf, BUF_SIZE, IBV_ACCESS_REMOTE_WRITE);

// usrbio reads directly into GPU HBM
usrbio_pread_gpu(fd, gpu_buf, BUF_SIZE, offset, mr->lkey);
// Path: NVMe → NIC RDMA engine → PCIe → GPU HBM (0 memcpy)
```

This eliminates the DRAM staging buffer entirely for training data reads.

---

## 6. Failure Handling

### 6.1 Storage Node Failure

**Case: TAIL fails**

The chain is broken. No new writes can commit. Recovery:

```
Chain was: [HEAD, MID, TAIL]
TAIL fails: chain becomes [HEAD, MID]

Meta server detects failure (heartbeat timeout ~1-5s)
Meta server updates chain table: chain_id → [HEAD, MID]  (MID becomes new TAIL)
Meta server propagates update via Raft → all clients get updated placement map

In-flight writes that HEAD had already sent to MID:
  MID has received them → MID (new TAIL) can commit them
  Client may need to retry if ACK was lost during failover (~1-5s pause)

Read availability during failover:
  HEAD is clean (no pending writes) → can serve reads immediately
  MID was dirty (had pending writes) → queries old TAIL (unreachable!) → falls back to
  serving committed_version before the failure (slightly stale but available)
```

**Case: HEAD fails**

```
Chain was: [HEAD, MID, TAIL]
HEAD fails: [MID, TAIL]  (MID becomes new HEAD)

All new writes go to MID (new HEAD)
In-flight writes from client → HEAD: lost → client retries to new HEAD
Any write that HEAD had propagated to MID before failure: MID has it → MID (new HEAD)
  propagates to TAIL → committed normally
```

**Case: MID fails (middle node)**

```
Chain was: [HEAD, MID, TAIL]
MID fails: chain becomes [HEAD, TAIL]

HEAD now propagates writes directly to TAIL
Recovery: meta server assigns a new MID, background re-replication from TAIL
```

In all cases, 3FS maintains **data availability** during single-node failure (the
surviving nodes continue serving reads for clean data). Write availability resumes
after failover (seconds, not minutes).

### 6.2 Re-Replication

When a node fails and a chain has only 2 nodes (replication factor drops to 2):
```
Background re-replication:
  TAIL is the source of truth
  Meta server assigns a new node to the chain
  New node joins chain at the END: reads chunks from TAIL via RDMA
  Once synchronized, becomes new TAIL (old TAIL becomes MID)
  
Rate-limited to avoid impacting training I/O:
  Typical: 1-4 GB/s re-replication per chain (background, throttled)
  For 64 MB chunk: 64 MB / 2 GB/s = 32 ms re-replication time
  For 100 failed chunks: ~3.2 seconds to full replication restoration
```

### 6.3 Meta Server Failure

Meta servers use Raft with 3-5 replicas:
- Leader election: ~1-2s (Raft timeout)
- During election: no new file creates, no chunk map changes
- Existing open files continue I/O (chunk map cached on client)
- Impact: brief metadata unavailability, data I/O unaffected

---

## 7. 3FS vs Alternative Storage Systems for AI

### 7.1 Feature Comparison

| Feature | 3FS | Lustre | DAOS | Ceph/CephFS | WekaFS |
|---------|-----|--------|------|------------|--------|
| Replication protocol | CRAQ | custom lock | DAOS epochs + EC | RADOS CRUSH | custom |
| Read fan-out scaling | O(N) replicas | limited | Good (DAOS obj) | Limited | Good |
| RDMA native | Yes (core) | LNET (optional) | Yes (CaRT) | No | Yes |
| Kernel bypass | usrbio | lnet/kfilnd | libioil | No | Yes |
| SCM (Optane) support | No | No | Yes (primary target) | No | No |
| POSIX compliance | Yes (FUSE) | Yes | Partial | Yes | Yes |
| Metadata design | Simple Raft | DNE (complex) | Per-pool service | MDS cluster | distributed |
| Open source | Yes (2025) | Yes | Yes | Yes | No |
| AI training focus | Primary | Secondary | Secondary | No | Yes |
| Snapshot support | No | No | Yes (CoW) | Yes (limited) | Yes |
| Multi-protocol | POSIX only | POSIX only | POSIX+native | POSIX+RBD | POSIX+S3 |

### 7.2 CRAQ vs Raft for Distributed Storage

This is the most important architectural distinction:

```
Raft leader handles all reads and writes:
  Write: client → leader → quorum of followers → commit → leader → client
  Read:  client → leader only (leader has latest committed state)
  Read throughput: 1× (only leader serves reads)
  Write throughput: limited by leader NVMe BW
  Failover: leader election (seconds)

CRAQ (3FS):
  Write: client → HEAD → chain → TAIL → commit → client  (same latency as Raft)
  Read:  client → ANY clean node in chain  (O(N) read throughput)
  Read throughput: N× (N = chain length)
  Write throughput: pipelined through chain (each node writes concurrently)
  Failover: chain shortening (faster than Raft leader election)

For read-heavy AI training:
  CRAQ gives 3× read BW for free (at no extra hardware cost vs Raft 3× replication)
  This directly doubles or triples training data throughput for free
```

### 7.3 3FS vs DAOS

```
DAOS target: HPC + AI, SCM (Optane) + NVMe hybrid, maximum IOPS for small I/O
3FS target:  AI training specifically, NVMe-only, maximum streaming BW

DAOS strengths:
  - SCM gives sub-µs write latency (Optane + ADR path)
  - MVCC epochs: snapshot isolation without locking
  - Object model: supports KV, array, byte-stream — flexible
  - EC at object level: space-efficient vs replication

3FS strengths:
  - Simpler: one protocol (CRAQ), one storage model (files+chunks)
  - CRAQ read scaling: 3× read BW vs DAOS replication (similar gain)
  - AI-native: designed around checkpoint/training-data patterns
  - Easier ops: no Optane requirement, commodity NVMe works

Choose DAOS when: mixed HPC/AI, need MVCC snapshots, or have SCM hardware
Choose 3FS when:  pure AI training, commodity NVMe cluster, need read fan-out
```

### 7.4 3FS vs Lustre

```
Lustre strengths:
  - Mature (20+ years), widely deployed in HPC
  - High aggregate bandwidth with many OSTs
  - File striping across many OSTs (single file parallelism)

Lustre weaknesses for AI:
  - Distributed Lock Manager (DLM): complex, can become bottleneck under high concurrency
  - Metadata bottleneck: single MDS (older Lustre) or complex DNE sharding
  - Not RDMA-native: LNET abstraction adds latency
  - No read fan-out from multiple OST replicas (stripes, not replicas)

3FS advantage:
  - CRAQ gives 3× read fan-out per chunk (Lustre stripes don't help read fan-out)
  - No DLM: simpler, scales better for the concurrent read-only training data pattern
  - RDMA is the only transport: no TCP fallback complexity
```

---

## 8. Integration with AI Training Stack

### 8.1 Checkpoint Integration (PyTorch DCP + 3FS)

```python
import torch.distributed.checkpoint as dcp
from torch.distributed.checkpoint.filesystem import FileSystemWriter

# 3FS FUSE mount — transparent to DCP
writer = FileSystemWriter("/mnt/3fs/checkpoints/step_1000/")
dcp.save(state_dict, storage_writer=writer)

# Each rank writes its shard to /mnt/3fs/checkpoints/step_1000/__rank_X_0.distcp
# Internally: FUSE → 3FS client → RDMA WRITE to HEAD node → chain propagation
# Rank-parallel: 1024 ranks write different files to different chains simultaneously
```

For maximum performance, use usrbio directly:
```python
import usrbio

# Write checkpoint shard directly via RDMA (bypasses FUSE)
fd = usrbio.open("/checkpoints/step_1000/rank_0.bin", "w")
usrbio.pwrite(fd, shard_tensor.data_ptr(), shard_size, offset=0)
usrbio.close(fd)
usrbio.fsync("/checkpoints/step_1000/rank_0.bin")
```

### 8.2 Training Data Integration (WebDataset + 3FS)

```python
import webdataset as wds

# 3FS FUSE mount — WebDataset reads tar files sequentially
# Sequential read = full NVMe BW from any CRAQ replica
dataset = wds.WebDataset("/mnt/3fs/imagenet/shard_{00000..01023}.tar")

# OR: use usrbio for kernel bypass
import usrbio_wds  # hypothetical: WebDataset with usrbio backend
dataset = usrbio_wds.WebDataset("/imagenet/shard_{00000..01023}.tar")
```

**Why sequential reads work well with CRAQ:**
After the initial writes (dataset preparation), all shards are clean on all replicas.
Sequential reads from a CRAQ chain node always hit the fast path (clean read, no TAIL query).
The read BW scales with the number of replicas × NVMe BW per node.

### 8.3 3FS and KV Disaggregation

3FS is positioned for the **persistent KV pool** tier (cold prefix cache):

```
GPU HBM (hot KV)  → eviction → CPU DRAM (warm KV, via Mooncake)
                                → eviction → 3FS NVMe (cold prefix cache)

3FS advantage for cold KV:
  - POSIX interface: easy to integrate (usrbio_pread)
  - CRAQ read fan-out: multiple prefill nodes can read same prefix KV simultaneously
  - NVMe BW: 7-14 GB/s per node × N nodes >> single-node NVMe cache

Access pattern:
  Read: prefix hash → 3FS file lookup → usrbio_pread → RDMA → GPU HBM
  Write: evicted warm KV → usrbio_pwrite → chain HEAD → CRAQ propagation
```

---

## 9. Operational Characteristics

### 9.1 Cluster Sizing

For a training cluster with:
- 1024 H100 GPUs (128 nodes, 8 GPUs each)
- Checkpoint: 700 GB every 30 min (write demand = 390 MB/s sustained)
- Training data: 5 GB/s per GPU × 1024 = 5 TB/s read demand

```
Storage nodes needed:
  Read: 5 TB/s ÷ (7 GB/s NVMe × 3 CRAQ replicas) = 238 NVMe drives
        With 8 NVMe per node: 30 storage nodes
  Write (checkpoint): 390 MB/s ÷ (7 GB/s × 0.33 write share) = 0.17 TB/s
        Far less than read demand; read-driven sizing

Network:
  Per-storage-node: 8 × 7 GB/s = 56 GB/s NVMe BW
  Need IB BW ≥ 56 GB/s: 2× IB NDR 400Gbps (2 × 50 GB/s) per storage node
  
Meta servers: 3-5 small nodes (metadata only, not data path)
```

### 9.2 Failure Impact on Training

```
Single storage node failure:
  Chains involving failed node: shortened to 2 replicas, chain rebuilt background
  Training: continues uninterrupted (other replicas serve reads)
  Checkpoint in-progress: retry write to new chain (seconds delay)

Network partition (split brain):
  CRAQ chains: TAIL becomes unreachable → dirty nodes fall back to serving stale reads
  Meta server: Raft quorum may be lost → brief metadata unavailability
  Mitigation: place meta servers on dedicated, reliable nodes

Meta server leader failure:
  Election: 1-2 seconds
  Impact: data I/O continues (cached chunk map), new file creates fail briefly
```

---

## 10. Architect Cheat Sheet

```
Core insight:
  CRAQ gives O(N) read throughput at N× replication — free read scaling.
  For AI training (heavily read-biased), this is the dominant advantage.

When to use 3FS:
  ✓ AI training with large model checkpoints (frequent large sequential writes)
  ✓ High GPU count (>128 GPUs) with high aggregate read demand
  ✓ Commodity NVMe cluster (no Optane requirement)
  ✓ Need POSIX + kernel-bypass (usrbio) in the same system
  ✗ Need MVCC snapshots → use DAOS
  ✗ Mixed small-file HPC workloads → use Lustre or GPFS
  ✗ Need multi-protocol (S3, NFS) → use Ceph

Critical numbers:
  CRAQ chain length: 3 (typical) → 3× read fan-out
  Chunk size: 64 MB (large sequential I/O, amortizes metadata overhead)
  Chain failover: seconds (chain shortening)
  Full re-replication: seconds per TB (background, throttled)
  usrbio latency vs FUSE: ~10× lower latency for small random reads

CRAQ vs Raft (one-line):
  Both give strong consistency; CRAQ gives N× read throughput, Raft gives 1×.
  For read-heavy AI: CRAQ wins. For write-heavy or OLTP: Raft is simpler.

Protocol decision tree:
  Read-heavy, sequential, replicated → CRAQ (3FS)
  Write-heavy, strong consistency, leader-based → Raft (etcd, DAOS pool service)
  Erasure-coded, large objects, space-efficient → EC + DAOS
  Eventual consistency, geographic distribution → Dynamo-style (Cassandra)
```
