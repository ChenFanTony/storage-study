# KV Cache Disaggregation — Architect Reference

Related: [kv-cache-reference.md](kv-cache-reference.md),
[memory-hierarchy-reference.md](memory-hierarchy-reference.md)

---

## 0. Terminology

| Term | Definition |
|------|-----------|
| Disaggregation | Separating two coupled roles (prefill + decode) onto different machines |
| Prefill node | Machine dedicated to computing KV for prompt tokens (compute-bound role) |
| Decode node | Machine dedicated to autoregressive generation (memory-BW-bound role) |
| KV transfer | Moving KV tensors from prefill node to decode node over the network |
| TTFT | Time-To-First-Token: latency from request arrival to first generated token |
| TBT | Time-Between-Tokens: latency between successive decode steps (= decode latency) |
| Mooncake | ByteDance's disaggregated KV cache system (2024) |
| PD disaggregation | Prefill-Decode disaggregation — the architectural pattern |
| KV pool | A distributed DRAM/NVMe pool holding KV blocks accessible by any decode node |
| Placement map | Which physical node holds which logical KV block |

---

## 1. Background: Why Disaggregate?

### 1.1 The Compute/Memory-BW Mismatch

Prefill and decode have fundamentally different resource bottlenecks:

```
Prefill (processing P prompt tokens):
  FLOPs per layer = 2 × P × d_model²  (matrix multiply, all P tokens in parallel)
  Memory reads    = weights only (all P queries share the same weight load)
  Bottleneck      = compute (FLOPs/s) — benefits from tensor parallelism

Decode (generating 1 token):
  FLOPs per layer = 2 × d_model²       (single token query)
  Memory reads    = weights + KV cache  (must read all KV for attention)
  Bottleneck      = HBM bandwidth (GB/s) — utilizes GPU at ~30-40% FLOPs
```

Arithmetic intensity:
```
Prefill: ~P × d_model FLOPs per byte of weight   (high, GPU efficient)
Decode:  ~1 FLOP per byte of weight + KV          (low, BW-bound, wastes FLOPs)
```

When both run on the same GPU pool, the decode phase under-utilizes compute while
the prefill phase starves decode of GPU time. The result: neither role gets optimal
hardware efficiency.

### 1.2 The Interference Problem

In a mixed prefill+decode system:
- A long prefill (400ms) blocks decode steps → P99 TBT spikes
- Chunked prefill (Section 4 of kv-cache-reference.md) mitigates but cannot fully hide the
  prefill cost

Disaggregation solves this cleanly: prefill and decode run on separate machines, no interference.

---

## 2. Disaggregated Architecture

### 2.1 Request Flow

```
Client
  │
  ▼
Load Balancer / Request Router
  │
  ├─── Prefill Cluster (high-compute GPUs, e.g., H100 SXM)
  │      │ 1. Receive prompt tokens
  │      │ 2. Run prefill forward pass → compute KV for all prompt tokens
  │      │ 3. Transfer KV blocks to decode node via RDMA
  │      │ 4. Send "KV ready" signal + first token to router
  │
  └─── Decode Cluster (can be cheaper GPUs with high HBM BW, e.g., A100)
         │ 5. Receive KV blocks from prefill node (via RDMA)
         │ 6. Insert into local KV block pool
         │ 7. Run autoregressive decode until EOS
         │ 8. Stream tokens back to client
```

### 2.2 KV Transfer Protocol

The KV tensor for a sequence at a given layer is:

```
shape: [num_layers, 2, seq_len, num_heads, head_dim]
size:  (for Llama-70B, seq_len=4096, fp16) = 10.74 GB
```

Transfer happens over InfiniBand (RDMA) or RoCE:

```
Prefill node (sender):
  1. After prefill completes, KV blocks are in GPU HBM
  2. Register GPU memory as RDMA MR (Memory Region) via ibv_reg_mr
  3. Post RDMA WRITE operation: direct GPU HBM → decode node GPU HBM
     (GPU-direct RDMA: no CPU copy, no intermediate buffer)
  4. Post completion signal to decode node via small message

Decode node (receiver):
  1. Pre-register a free KV block pool region as RDMA MR
  2. Receive completion signal
  3. Block is now live in local GPU HBM — insert into block_table
```

### 2.3 GPU-Direct RDMA (GDR) — The Zero-Copy Path

```
Traditional RDMA path (without GDR):
  GPU HBM → cudaMemcpy → CPU DRAM → RDMA NIC → network → RDMA NIC → CPU DRAM → GPU HBM
  Copies: 2 (GPU↔CPU each side), 4 total

GPU-Direct RDMA path:
  GPU HBM → PCIe → RDMA NIC → network → RDMA NIC → PCIe → GPU HBM
  Copies: 0 (RDMA NIC reads/writes GPU HBM directly via PCIe BAR)

Bandwidth:
  PCIe 5.0 (H100): 128 GB/s bidirectional = 64 GB/s per direction
  IB NDR 400Gbps:  50 GB/s
  Bottleneck:      IB link (50 GB/s < PCIe 64 GB/s)
```

Transfer time for Llama-70B, seq_len=4096:
```
10.74 GB / 50 GB/s = 215 ms
```

This is added to TTFT. The tradeoff: higher TTFT but better TBT (decode is not
interrupted by prefill).

### 2.4 Reducing Transfer Time

Several techniques reduce KV transfer latency:

**Pipelined transfer:** Transfer KV layer-by-layer. The decode node can start attention
computation on layer 0 KV while prefill is still running layer 1..N:

```
Prefill:  [L0 KV] → transfer → [L1 KV] → transfer → ... → [LN KV] → transfer
Decode:              [wait L0]  [attn L0]  [wait L1]  [attn L1] ...
```

Effective overlap: transfer of layer L+1 overlaps with decode attention on layer L.
If transfer BW ≥ prefill compute rate per layer, TTFT is determined by prefill time
alone (transfer is hidden).

**KV quantization before transfer:** Halve the transfer size by fp8 quantization:
```
10.74 GB (fp16) → 5.37 GB (fp8) → 107 ms transfer at 50 GB/s
```

**Token streaming:** Send KV as soon as each block of B tokens is prefilled, rather
than waiting for full prompt completion.

---

## 3. Mooncake Architecture (ByteDance, 2024)

Mooncake extends disaggregation with a **global distributed KV pool** backed by CPU DRAM
across all nodes, enabling cross-request KV sharing beyond what a single decode node can hold.

### 3.1 Architecture Components

```
┌─────────────────────────────────────────────────────────┐
│                   Mooncake System                       │
│                                                         │
│  ┌──────────────┐        ┌──────────────────────────┐  │
│  │ Prefill Nodes │        │      KV Pool Layer        │  │
│  │  (compute)   │──RDMA──▶  CPU DRAM across all nodes │  │
│  └──────────────┘        │  (global addressable space)│  │
│                           └────────────┬─────────────┘  │
│  ┌──────────────┐                      │ RDMA            │
│  │ Decode Nodes  │◀─────────────────────┘                │
│  │  (HBM-bound) │                                        │
│  └──────────────┘                                        │
│                                                         │
│  ┌───────────────────────────────────────────┐          │
│  │ Conductor (placement scheduler)           │          │
│  │  - tracks which node holds which KV block  │          │
│  │  - routes prefill requests to nodes with   │          │
│  │    matching prefix cache                   │          │
│  │  - implements early rejection under load   │          │
│  └───────────────────────────────────────────┘          │
└─────────────────────────────────────────────────────────┘
```

### 3.2 KV Pool as Distributed Memory

CPU DRAM across a 100-node cluster (1 TB DRAM/node) = 100 TB of KV pool. This holds
cold prefix-cache blocks from millions of historical requests:

```
Node 0 DRAM [prefix_A_blk_0, prefix_A_blk_1, prefix_B_blk_0, ...]
Node 1 DRAM [prefix_C_blk_0, prefix_D_blk_0, ...]
...
```

The Conductor maintains a hash map: `block_hash → (node_id, dram_offset)`.

When a decode node needs a block:
1. Lookup block_hash in Conductor → get (node_id, offset)
2. Issue RDMA READ from node_id's DRAM directly into decode node's GPU HBM
3. Block is now live for attention

DRAM-to-GPU RDMA (via GDR) on H100: effective ~40 GB/s per link.

### 3.3 Conductor Placement Algorithm

The Conductor routes incoming requests to prefill nodes that already hold matching prefix
cache blocks in their GPU HBM (or adjacent DRAM), minimizing KV transfer:

```python
def route_request(request: Request) -> PrefillNode:
    best_node = None
    best_match = 0

    for node in prefill_nodes:
        match_len = node.local_prefix_cache.longest_prefix_match(request.token_ids)
        if match_len > best_match:
            best_match = match_len
            best_node = node

    # Fallback: route to least-loaded node
    if best_match < MIN_USEFUL_MATCH:
        return min(prefill_nodes, key=lambda n: n.load)

    return best_node
```

Cache-affinity routing maximizes prefix cache hits, reducing KV recompute.

### 3.4 Early Rejection (Overload Control)

Under overload, Mooncake applies **early rejection** at the request router:

```
Estimated queue time = (queued_tokens / throughput) + prefill_latency(prompt_len)
If estimated queue time > SLA_threshold:
    return HTTP 429 (Too Many Requests) immediately
```

This prevents the system from accumulating unbounded queues that cause all requests
to miss SLA, rather than degrading gracefully.

---

## 4. Alternative Architectures

### 4.1 Disaggregated KV Store (IBM, 2024)

Uses a dedicated NVMe-backed KV store service (separate from both prefill and decode):
- Prefill writes KV to the KV store after computation
- Decode reads KV from the KV store on demand
- KV store is replicated for fault tolerance

Tradeoff vs Mooncake:
- Simpler placement (no GDR complexity)
- Higher latency (NVMe: ~100µs vs DRAM: ~1µs)
- Works with commodity network (no RDMA required)

### 4.2 MemServe / InfiniStore

Stores KV blocks in CPU DRAM of dedicated memory nodes, accessed via RDMA verbs.
Similar to Mooncake's KV pool but without the tight integration with the Conductor scheduler.

### 4.3 Remote Paging (FlexGen, 2023)

For single-GPU inference (no RDMA), FlexGen offloads KV to CPU DRAM and NVMe:
```
GPU HBM (active window) ← CPU DRAM (recent KV) ← NVMe (historical KV)
```
This enables serving 175B models on a single GPU with 16GB HBM by keeping only the
current attention window in HBM and streaming older KV from DRAM/NVMe. Throughput
is ~10× lower than full HBM but enables long-context serving on constrained hardware.

---

## 5. Failure Handling

### 5.1 Prefill Node Failure

If the prefill node fails mid-computation:
- KV blocks are partially computed → unusable
- Request must be rerouted to a new prefill node and fully recomputed
- State: only the original prompt is needed (no KV to restore) — resilient

### 5.2 Decode Node Failure

If the decode node fails mid-generation:
- Partially generated tokens are lost
- Partially filled KV blocks in HBM are lost
- Recovery options:
  1. **Recompute from prompt:** restart on new decode node (costs one full prefill)
  2. **Checkpoint KV to DRAM pool:** periodically write KV to the KV pool; restore on failover
  3. **Replication:** mirror KV to a standby decode node (2× HBM cost)

Option 1 is default; option 2 is used for very long sequences (>16K tokens) where
recompute is expensive.

### 5.3 KV Pool Node Failure

KV pool nodes holding prefix cache blocks: blocks are cold (cached, not active). Loss
is handled as a cache miss — new requests recompute the prefix. No correctness violation.

For hot KV (mid-decode swap), this is a decode-node failure case handled above.

---

## 6. Architect Cheat Sheet

```
Decision                            Criterion
──────────────────────────────────────────────────────────────────────
Use disaggregation?                 When TTFT and TBT are separate SLOs
                                    When batch size > 32 sequences
                                    When context > 8K tokens commonly

Transfer size reduction             fp8 quantization halves it
                                    Layer pipelining hides it

When prefix cache is worth building >20% requests share a common prefix >512 tokens

CPU DRAM KV pool size needed        sum(top-K prefix hashes × KV_per_prefix)
                                    Typical: 1-10 TB across a pod

IB bandwidth to provision           seq_len × KV_bytes / target_TTFT
                                    e.g., 4K tokens, 10.74GB, 500ms TTFT target
                                    → 10.74/0.5 = 21.5 GB/s → one 400GbE IB port

Fault model for KV pool             treat as a cache: loss = recompute, not data loss
```
