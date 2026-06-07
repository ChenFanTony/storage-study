# AI Storage Memory Hierarchy — Architect Reference

Related: [kv-cache-reference.md](kv-cache-reference.md),
[checkpoint-reference.md](checkpoint-reference.md),
[training-data-reference.md](training-data-reference.md)

This is the foundational reference. All other AI storage topics map to a specific tier
or tier boundary in this hierarchy.

---

## 0. Terminology

| Term | Definition |
|------|-----------|
| HBM | High Bandwidth Memory — GDDR successor, stacked on GPU die; the fastest tier |
| Pinned memory | CPU DRAM pages locked (not swappable); PCIe DMA can access directly |
| GDR | GPU-Direct RDMA — RDMA NIC reads/writes GPU HBM via PCIe without CPU involvement |
| Bandwidth | Sustained sequential throughput (GB/s) |
| Latency | Time for first byte of a small random access |
| Arithmetic intensity | FLOPs per byte of memory traffic — determines if a workload is compute or BW bound |
| Roofline model | Graph of arithmetic intensity vs BW showing compute vs memory boundedness |
| Spill | Moving data from a fast/full tier to a slower/larger tier |
| Prefetch | Moving data from a slow tier to a fast tier ahead of demand |

---

## 1. Full Tier Stack

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                    AI Compute Node Memory Hierarchy                          │
│                                                                              │
│  Tier 0: GPU Registers / SRAM (L1/L2 cache)                                 │
│    BW: 50-100 TB/s (on-chip), Latency: 1-5 ns, Capacity: 50 MB (H100)      │
│    ↓ managed by GPU compiler/hardware, not software-visible                 │
│                                                                              │
│  Tier 1: GPU HBM                                                             │
│    BW: 3.35 TB/s (H100 SXM5), Latency: ~100 ns, Capacity: 80 GB           │
│    ↓ cudaMemcpy, tensor allocation                                           │
│                                                                              │
│  Tier 2: CPU DRAM (Pinned / Pageable)                                       │
│    BW: 200-300 GB/s (DDR5 multi-channel), Latency: ~100 ns                 │
│    Capacity: 1-2 TB / node, $/GB: ~$5                                       │
│    ↓ PCIe 5.0 (64 GB/s bidirectional), GDR optional                        │
│                                                                              │
│  Tier 3: Local NVMe SSD                                                     │
│    BW: 7-14 GB/s seq, Latency: ~100 µs, Capacity: 15-60 TB / node         │
│    $/GB: ~$0.3, IOPS: 1M+ random 4KB                                       │
│    ↓ PCIe, NVMeoF (RDMA)                                                   │
│                                                                              │
│  Tier 4: Network Storage / Distributed (Lustre, DAOS, GPFS, WekaFS)        │
│    BW: 10-500 GB/s aggregate, Latency: 100 µs - 1 ms                      │
│    Capacity: PB, $/GB: ~$0.05-0.1                                           │
│    ↓ InfiniBand / RoCE                                                      │
│                                                                              │
│  Tier 5: Object Storage (S3, GCS, Azure Blob)                               │
│    BW: 5-50 GB/s aggregate, Latency: 10-100 ms                             │
│    Capacity: unlimited, $/GB: ~$0.02                                        │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 1.1 Key Tier Ratios (H100 baseline)

| Metric | HBM → DRAM | DRAM → NVMe | NVMe → Object |
|--------|-----------|-------------|--------------|
| BW ratio | 3.35 TB/s → 200 GB/s = **17×** | 200 GB/s → 14 GB/s = **14×** | 14 GB/s → 50 GB/s = 0.3× (aggregate wins) |
| Latency ratio | 100 ns → 100 ns = **1×** | 100 ns → 100 µs = **1000×** | 100 µs → 10 ms = **100×** |
| Capacity ratio | 80 GB → 2 TB = **25×** | 2 TB → 60 TB = **30×** | 60 TB → PB = **20×+** |
| Cost ratio | $50/GB → $5/GB = **10×** | $5/GB → $0.3/GB = **17×** | $0.3/GB → $0.02/GB = **15×** |

Each tier boundary: ~1 OOM BW loss, ~3 OOM latency penalty (HBM→DRAM is exception: same latency).

---

## 2. The Roofline Model — Where Each AI Workload Lives

### 2.1 Arithmetic Intensity Definition

```
Arithmetic Intensity (AI) = FLOPs / Bytes of memory traffic

If AI > ridge_point: compute-bound (FLOPs are the limit)
If AI < ridge_point: memory-bandwidth-bound (BW is the limit)

H100 ridge point = peak_FLOPs / peak_BW = 989 TFLOPS / 3.35 TB/s ≈ 295 FLOPs/byte
```

### 2.2 Per-Operation Placement

```
Operation                      Arithmetic Intensity    Bound       Optimal tier
─────────────────────────────────────────────────────────────────────────────
Matrix multiply (large)        >1000 FLOPs/byte        Compute     HBM (fast enough)
Prefill attention (long seq)   ~100-1000 FLOPs/byte    Compute     HBM
Decode attention (one token)   ~1 FLOP/byte            BW          HBM BW is bottleneck
Embedding lookup               ~0.1 FLOPs/byte         BW          HBM BW is bottleneck
LayerNorm, activation          ~1-10 FLOPs/byte        BW          fused kernels help
JPEG decode (CPU)              ~10 FLOPs/byte          CPU BW      CPU DRAM or DALI (GPU)
Checkpoint write               ~0 FLOPs/byte           Pure I/O    async to NVMe
```

**Decode is the most BW-hungry operation:**
```
Llama-70B, one decode step, batch=1:
  Weight reads: 140 GB (all parameters, fp16)
  KV cache reads: variable by seq_len
  BW: 140 GB / (3.35 TB/s) = 41 ms  → HBM BW is the wall
```

Batch size helps: with batch=32 (32 concurrent sequences), weights are read once but
attention is computed for 32 queries → arithmetic intensity × 32 → better GPU utilization.

---

## 3. Data Movement Patterns per AI Workload

### 3.1 LLM Inference (Steady State)

```
Each decode step:
  HBM: read all weights (140 GB for 70B), read KV blocks for active sequences
  HBM: write new KV block (1 block per active sequence)

Hot path:
  KV blocks → HBM L2 (if fit) → attention kernel → HBM (new KV written)
  Weights    → HBM → linear layers → HBM

Cold path (long context, HBM full):
  Evicted KV blocks → CPU DRAM (spill)
  Prefix cache hits → CPU DRAM → PCIe → HBM (restore)
  Remote prefix hits → object store / shared KV tier → pinned DRAM → HBM (restore)

A Ceph/S3-backed KV cache extends this hierarchy one more step down:
- HBM holds hot active blocks
- CPU DRAM holds warm spill / staging buffers
- local NVMe may hold colder node-local prefix blocks
- object storage holds large shared cold KV blocks reusable across nodes

This path only wins when transfer plus copy overhead is lower than recomputing prompt
prefill. In practice, that usually requires long shared prefixes and large chunked reads,
not tiny random block fetches.

Throughput formula:
  tokens/sec = HBM_BW / bytes_per_token
  bytes_per_token = 2 × model_size_bytes / batch_size  (factor 2: read + write KV)
  For 70B, batch=32: bytes_per_token = 2 × 140GB / 32 = 8.75 GB/token
  Throughput = 3350 GB/s / 8.75 GB/token ≈ 383 tokens/sec
```

### 3.2 Distributed Training (Forward + Backward)

```
Tier movements per training step:

1. Data loading: NVMe/Object → CPU DRAM → PCIe → HBM
   (prefetched, ideally hidden)

2. Forward pass: HBM reads weights + activations, writes intermediate activations
   Activation memory: O(batch × seq_len × d_model × num_layers)
   For Llama-70B, batch=32, seq=2048: ~400 GB of activations (exceeds HBM!)
   → gradient checkpointing: recompute activations during backward instead of storing

3. Backward pass: HBM reads activations + weights, writes gradients
   Gradient checkpointing reduces activation memory 10-40× at cost of 1.33× compute

4. AllReduce (DP): each rank streams gradients over InfiniBand
   Volume: 140 GB (gradients, fp16) × 2 (ring AllReduce) / log₂(N_DP_ranks)
   For N_DP=8: 140 GB × 2 / 3 ≈ 93 GB per rank transferred

5. Optimizer step: HBM reads gradients + optimizer state (fp32), writes updated weights
   fp32 optimizer state: 560 GB for 70B → requires ZeRO sharding

6. Checkpoint (periodic): HBM → CPU DRAM → NVMe/Object (async, background)
```

### 3.3 Gradient Checkpointing Algorithm

The standard technique for fitting large models in HBM:

```
Without checkpointing (full activation storage):
  Store activations at every layer output during forward
  Use stored activations during backward
  Memory: O(num_layers × batch × seq_len × d_model)

With gradient checkpointing (recompute):
  Forward pass: discard all intermediate activations (save only layer boundaries)
  Backward pass: re-run forward through each "checkpoint" segment to recompute activations
  Memory: O(sqrt(num_layers) × batch × seq_len × d_model)  [with optimal placement]
  Compute: 1.33× extra FLOPs (re-run forward once)
```

```python
# PyTorch API
from torch.utils.checkpoint import checkpoint

def forward(self, x):
    # Instead of: x = self.layer1(x)
    x = checkpoint(self.layer1, x, use_reentrant=False)
    x = checkpoint(self.layer2, x, use_reentrant=False)
    return x
```

`use_reentrant=False` uses the newer saved-tensor hooks approach (more memory efficient,
compatible with compiled kernels).

---

## 4. Bandwidth Optimization Techniques

### 4.1 Tensor Parallelism — Splitting HBM Load

With TP=8 (8 GPUs sharing one model):
- Each GPU holds 1/8 of weight matrices
- Each GPU reads only 1/8 of weights per step
- HBM load per GPU: 140 GB / 8 = 17.5 GB per step
- Step time reduction: ~8× faster weight reads

Cost: all-gather/reduce-scatter communication between 8 GPUs per layer via NVLink
(H100 NVLink: 900 GB/s bidirectional aggregate → fast enough to not bottleneck).

### 4.2 FlashAttention — HBM Round-Trip Reduction

Standard attention materializes the N×N attention score matrix in HBM:
```
Standard:
  Q @ K^T → HBM write (N×N matrix) → softmax → HBM read → @ V → output
  HBM traffic: O(N² × d)  for N tokens, d head_dim

FlashAttention:
  Tile Q, K, V into SRAM blocks
  Compute attention score + softmax + V multiply within SRAM, never write N×N to HBM
  HBM traffic: O(N × d)  — linear in N, not quadratic

Speedup for long sequences (N=8192):
  Standard: 8192² × 128 × 2B = 17 GB of extra HBM traffic per attention layer
  FlashAttention: 0 extra HBM traffic for the attention matrix
  Speedup: 3-8× for attention (depends on N and head_dim)
```

### 4.3 Quantization Effects on Tier Utilization

| Dtype | Model size | Decode BW (H100) | Fits in HBM (70B) |
|-------|-----------|-----------------|-----------------|
| fp32 | 280 GB | 12.4 ms/step | No (3.5× over 80GB) |
| fp16/bf16 | 140 GB | 41 ms/step | No (1.75× over 80GB) |
| int8 | 70 GB | 21 ms/step | Yes (1 GPU) |
| fp4/int4 | 35 GB | 10 ms/step | Yes (1 GPU, comfortable) |

Quantization allows the model to fit in fewer GPUs (fewer GPUs = lower cost) and
reduces decode BW pressure (higher throughput per GPU).

---

## 5. Spill and Prefetch Policies

### 5.1 General Principle

Any tier transition should follow:
- **Spill down (fast → slow):** triggered when the fast tier is near-full
- **Prefetch up (slow → fast):** triggered when future demand is predicted
- **The goal:** the fast tier never stalls the consumer

### 5.2 LRU with Dirty Bit (KV Cache Eviction)

Applied at HBM → DRAM boundary for KV blocks:

```
State per KV block: {clean, dirty}
  clean: block content matches what's on DRAM/NVMe (or it's a cache-only block)
  dirty: block has been modified and DRAM/NVMe copy is stale (or doesn't exist)

Eviction priority:
  1. Clean blocks with ref_count=0 (lowest cost: just free the HBM slot)
  2. Dirty blocks with ref_count=0 (must write to DRAM before freeing)
  3. Blocks with ref_count>0 → cannot evict (would corrupt active sequence)

LRU ordering: maintain doubly-linked list sorted by last-access time
  On access: move to tail (O(1))
  On eviction: remove from head (O(1))

Implementation: same as OS page replacement; identical data structure to Linux's
  inactive/active LRU lists (see L1: page cache)
```

### 5.3 Predictive Prefetch for Training Data

Training data access is sequential with a known pattern (shard order). Prefetch strategy:

```
Prefetch depth = num_workers × prefetch_factor
  (number of batches kept in DRAM ahead of training)

Optimal prefetch_factor:
  prefetch_factor = ceil(data_loading_time / gpu_step_time)
  
  For ResNet-50, data_loading_time=20ms, gpu_step_time=50ms:
    prefetch_factor = ceil(20/50) = 1  (1 batch ahead is sufficient)
  
  For ViT-H, data_loading_time=80ms, gpu_step_time=200ms:
    prefetch_factor = ceil(80/200) = 1  (still 1, but use more workers)
```

Prefetch is bounded by CPU DRAM capacity. Each batch = ~256 × 3 × 224 × 224 × 4B ≈ 150 MB.
With 4 workers × prefetch_factor=2 = 8 batches in DRAM = 1.2 GB (negligible).

### 5.4 Adaptive Spill Threshold

For KV cache management, the spill trigger should account for allocation rate:

```python
SPILL_HIGH_WATERMARK = 0.90  # start evicting at 90% full
SPILL_LOW_WATERMARK  = 0.70  # stop evicting at 70% full

def maybe_evict(kv_pool):
    if kv_pool.utilization() > SPILL_HIGH_WATERMARK:
        while kv_pool.utilization() > SPILL_LOW_WATERMARK:
            block = kv_pool.lru_list.pop_oldest_clean()
            if block:
                kv_pool.free(block)
            else:
                block = kv_pool.lru_list.pop_oldest_dirty()
                dram_cache.write(block)  # async
                kv_pool.free(block)
```

The hysteresis (high/low watermark) prevents oscillation: without it, frequent
evict/allocate cycles saturate PCIe.

---

## 6. Numbers Reference Card

```
H100 SXM5:
  HBM BW:         3.35 TB/s
  HBM capacity:   80 GB
  FP16 TFLOPs:    989 TFLOPs
  BF16 TFLOPs:    989 TFLOPs
  INT8 TOPs:      1979 TOPs
  FP8 TOPs:       3958 TOPs
  NVLink BW:      900 GB/s (within node, 8 GPUs)
  PCIe 5.0 BW:    128 GB/s bidirectional
  IB NDR port:    50 GB/s (400 Gbps)

A100 SXM4:
  HBM BW:         2.0 TB/s
  HBM capacity:   80 GB
  FP16 TFLOPs:    312 TFLOPs

Decode throughput formula (BW-bound):
  tokens/sec = HBM_BW / (2 × model_params × dtype_bytes / batch_size)
  H100, Llama-70B, fp16, batch=32:
    = 3350 / (2 × 70e9 × 2 / 32) = 3350 / (8.75e9) ≈ 383 tokens/sec

PCIe copy latency (H100, 683 MB shard):
  683 MB / 32 GB/s = 21 ms

IB transfer (10.74 GB KV, Llama-70B, seq=4096):
  10.74 GB / 50 GB/s = 215 ms

NVMe read (42 MB KV block, seq:
  42 MB / 7 GB/s = 6 ms
```
