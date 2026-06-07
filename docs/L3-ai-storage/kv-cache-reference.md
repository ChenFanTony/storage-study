# KV Cache Management — Architect Reference

Related: [memory-hierarchy-reference.md](memory-hierarchy-reference.md),
[kv-disaggregation-reference.md](kv-disaggregation-reference.md)

---

## 0. Terminology

| Term | Definition |
|------|-----------|
| KV cache | Key and Value tensors from attention layers, cached across decode steps |
| Prefill | First forward pass: compute KV for all prompt tokens at once (compute-bound) |
| Decode | Autoregressive token generation: one step at a time, reusing cached KV (BW-bound) |
| Sequence | One inference request; has its own KV cache growing per decode step |
| Context length | Number of tokens in prompt + generated so far; KV cache grows with this |
| HBM | High Bandwidth Memory — GPU on-chip DRAM (80GB on H100) |
| Fragmentation | Memory wasted because KV tensors are not physically contiguous |
| PagedAttention | vLLM's algorithm: treats KV blocks like OS virtual pages (non-contiguous) |
| Prefix cache | Reusing KV blocks for a shared system prompt across requests |
| Chunked prefill | Splitting a long prompt prefill into chunks to bound GPU latency spike |

---

## 1. Background: Why KV Cache Exists

### 1.1 Attention Mechanism Recap

In the Transformer attention operation, for each layer l and each token position t:

```
Q_t = W_Q · x_t        (query for current token)
K_t = W_K · x_t        (key for current token)
V_t = W_V · x_t        (value for current token)

Attention(t) = softmax(Q_t · [K_0..K_t]^T / sqrt(d_k)) · [V_0..V_t]
```

When generating token t+1, the model needs `K_0..K_t` and `V_0..V_t` — exactly the
values computed in previous steps. Without a cache, every decode step recomputes all
prior KV, making generation O(n²) in time. With the KV cache, each decode step is O(n)
(just the attention dot product, no recompute).

### 1.2 KV Cache Size Math

For a single sequence:

```
KV_bytes_per_layer = 2 × seq_len × num_heads × head_dim × dtype_bytes
                       ^            ^                         ^
                       K+V          per head                  fp16=2, fp8=1
```

For Llama-3-70B (80 layers, 64 heads, head_dim=128, fp16):
```
KV_per_layer = 2 × seq_len × 64 × 128 × 2 = 32,768 × seq_len bytes
KV_total     = 80 layers × 32,768 × seq_len = 2,621,440 × seq_len bytes

At seq_len=4096 tokens: 10.74 GB per sequence
At seq_len=128K tokens: 335 GB per sequence — exceeds a single H100
```

This is the crux of the problem: long contexts exhaust HBM fast, limiting batch size and
throughput.

### 1.3 The Fragmentation Problem (Pre-PagedAttention)

Before vLLM (2023), inference engines pre-allocated a contiguous buffer for each sequence
at the **maximum possible context length**. This caused:

- **Internal fragmentation:** a 100-token request holds a 4096-token buffer → 97.6% waste
- **External fragmentation:** partially-filled buffers leave gaps that cannot be merged
- **Low GPU utilization:** HBM appears 60-80% occupied but only 20-40% holds live KV data
- **Head-of-line blocking:** a long sequence starves short ones from getting GPU time

---

## 2. PagedAttention — The Core Algorithm

### 2.1 Design Principle

PagedAttention maps the KV cache exactly onto OS virtual memory concepts:

| OS Concept | PagedAttention Equivalent |
|------------|--------------------------|
| Physical page (4KB) | KV block (e.g., 16 tokens × layer × K+V) |
| Virtual page | Logical block slot in a sequence |
| Page table | Block table per sequence |
| Page fault | Block allocation from free pool |
| LRU eviction | Block eviction to CPU/NVMe |
| Swap | KV offload to DRAM/NVMe |

### 2.2 Data Structures

```
KV Block Pool (GPU HBM):
  block_size = B tokens  (e.g., B=16)
  num_blocks = HBM_avail / (B × layers × 2 × heads × head_dim × 2 bytes)
  free_list: doubly-linked list of available block IDs

  For H100 80GB, Llama-70B, B=16:
    bytes_per_block = 16 × 80 × 2 × 64 × 128 × 2 = 42,304,000 bytes ≈ 42 MB
    num_blocks ≈ (80GB × 0.9) / 42MB ≈ 1,714 blocks

Per-sequence block table:
  block_table[seq_id] = [block_id_0, block_id_1, ..., block_id_n]
  length = ceil(context_len / B)
  physical blocks can be non-contiguous
```

### 2.3 Attention Kernel with Block Table

The attention computation must be modified to follow the block table indirection:

```python
# Pseudocode: paged attention for one query token
def paged_attention(q, block_table, kv_cache, seq_len, block_size):
    num_blocks = ceil(seq_len / block_size)
    attn_scores = []

    for i in range(num_blocks):
        block_id = block_table[i]
        k_block = kv_cache.k[block_id]   # shape: [block_size, heads, head_dim]
        v_block = kv_cache.v[block_id]

        # last block may be partially filled
        valid_len = min(block_size, seq_len - i * block_size)
        scores = q @ k_block[:valid_len].T / sqrt(head_dim)
        attn_scores.append((scores, v_block[:valid_len]))

    weights = softmax(concat([s for s, _ in attn_scores]))
    output = sum(w * v for w, (_, v) in zip(weights, attn_scores))
    return output
```

The GPU kernel uses the block_table as an indirection layer (similar to a TLB walk), fetching
non-contiguous physical blocks. This is the core memory access pattern change.

### 2.4 Allocation and Deallocation

```
Request arrives (prompt_len = P):
  blocks_needed = ceil(P / B)
  if len(free_list) < blocks_needed:
      → scheduler preempts a lower-priority sequence (evict its blocks)
  allocate blocks_needed blocks from free_list
  build block_table for this sequence

Each decode step (generates 1 token):
  cur_slot = (seq_len % B)
  if cur_slot == 0:  # need a new block
      allocate 1 block from free_list
      append to block_table

Request finishes or errors:
  return all block_table blocks to free_list
  (O(1) deallocation — just prepend to list)
```

### 2.5 Copy-on-Write for Beam Search / Parallel Sampling

When a request uses beam search (k beams) or n parallel samples, the prompt KV blocks
are shared:

```
Sequence A (beam 1): block_table = [blk_0, blk_1, blk_2_copy_A]
Sequence B (beam 2): block_table = [blk_0, blk_1, blk_2_copy_B]
                                     ↑       ↑
                              shared (ref_count=2)  — read-only
                                              ↑
                                     diverged after token split — CoW'd
```

Each shared block has a `ref_count`. When a sequence writes to a shared block (appends a new
token that fills the last slot of a shared block), it CoW's the block:
1. Allocate a new block from free_list
2. Memcpy the shared block into the new block
3. Decrement ref_count on the original
4. Update block_table to point to the new block

This is identical to OS CoW fork semantics.

---

## 3. Prefix Caching

### 3.1 The Opportunity

Many LLM deployments use a fixed system prompt (e.g., "You are a helpful assistant..."),
followed by user-specific context, followed by a question. The system prompt KV blocks
are identical across requests — they can be shared.

```
Request 1: [SYS_PROMPT | USER_CONTEXT_1 | QUESTION_1]
Request 2: [SYS_PROMPT | USER_CONTEXT_1 | QUESTION_2]  ← shares SYS+USER
Request 3: [SYS_PROMPT | USER_CONTEXT_2 | QUESTION_3]  ← shares SYS only
```

### 3.2 Content-Addressed Block Cache

Each KV block is identified by a hash of the **token IDs** that produced it:

```
block_hash = hash(token_ids[i*B : (i+1)*B] + parent_block_hash)
```

`parent_block_hash` ensures that the same token IDs in a different prefix context
produce a different hash (positional embeddings differ by position).

```python
class PrefixCache:
    def __init__(self):
        self.cache: Dict[int, BlockID] = {}  # hash → block_id
        self.ref_count: Dict[BlockID, int] = {}

    def lookup(self, token_ids: List[int]) -> List[BlockID]:
        matched = []
        h = INITIAL_HASH
        for i in range(0, len(token_ids), B):
            chunk = tuple(token_ids[i:i+B])
            h = hash((h, chunk))
            if h in self.cache:
                matched.append(self.cache[h])
                self.ref_count[self.cache[h]] += 1
            else:
                break  # prefix must be contiguous
        return matched

    def insert(self, token_ids: List[int], block_ids: List[BlockID]):
        h = INITIAL_HASH
        for i, bid in enumerate(block_ids):
            chunk = tuple(token_ids[i*B:(i+1)*B])
            h = hash((h, chunk))
            if h not in self.cache:
                self.cache[h] = bid
                self.ref_count[bid] = 1
```

On a cache hit, the matched blocks are directly included in block_table without recomputing
their KV. The prefill only runs on the *unmatched* suffix tokens.

### 3.3 Eviction Policy for Prefix Cache

Prefix blocks are evicted when HBM is full. Eviction order:

1. **Blocks with ref_count = 0** (not referenced by any live sequence)
2. Among those: **LRU** — evict the block least recently used as a prefix match

This is a two-level structure: active blocks (ref_count > 0, never evict) and cached
blocks (ref_count = 0, LRU pool). When a new request matches a cached block, it
transitions from cached → active (ref_count += 1).

```
LRU list for prefix cache (doubly-linked + hash map for O(1) ops):

  [oldest ... newest]
   blk_A  blk_B  blk_C  blk_D

  Cache miss → evict blk_A (oldest), add new block at tail
  Cache hit on blk_B → move blk_B to tail (most recently used)
```

Hit rate for a fixed system prompt shared across all requests approaches 100% once the
system prompt blocks are warm. Memory cost: `sys_prompt_tokens / B` blocks (pinned).

---

## 4. Remote Prefix Cache via Object Storage

### 4.1 Why Add a Remote Tier?

Local HBM prefix cache is fast but small. CPU DRAM and local NVMe extend capacity per node,
but they are still node-local: a cache hit only helps if the next request lands on the
same machine.

Large production systems often want a shared prefix-cache tier:
- one node computes KV for a long prompt once
- the resulting KV blocks are stored in a remote shared tier
- later requests on any node can fetch those blocks instead of recomputing prefill

This is the architectural role of systems such as LMCache with S3/Ceph backends.

### 4.2 Mapping to Classical Storage Concepts

| LLM Inference Concept | Storage Analogy |
|-----------------------|-----------------|
| KV block | Cache page / large object chunk |
| Block hash | Content address / object key |
| Prefix cache hit | Cache hit on previously materialized intermediate state |
| Prefill recompute | Cache miss penalty |
| GPU HBM | L1 cache / hottest tier |
| CPU pinned DRAM | DMA-friendly staging tier |
| Local NVMe | Per-node victim cache |
| Object storage (Ceph/S3) | Shared cold cache tier |

The key idea is that KV cache is not model state and not user data. It is derived,
reusable intermediate state. That makes it a good fit for a content-addressed cache.

### 4.3 Retrieval vs Recompute Tradeoff

Remote prefix caching only helps when:

```
remote_fetch_time < recompute_prefill_time
```

For a long shared prompt, prefill may take hundreds of milliseconds. If the matching KV
blocks can be fetched quickly enough from a remote tier, TTFT improves because the
system skips most or all of the prefix prefill.

Costs to account for:
- object-store latency for each fetch
- transfer bandwidth from remote tier to host
- copy overhead into pinned DRAM / GPU HBM
- any serialization or metadata lookup overhead

Benefits:
- cross-node cache sharing
- much larger effective prefix-cache capacity
- fewer duplicate prefill computations across a fleet

### 4.4 Practical Constraints

- Only full blocks are reusable. If two prompts diverge in the middle of a block,
  reuse stops at the previous full block.
- Large transfer units are important. Object storage is too latent for tiny random
  reads, but can be effective for multi-MiB KV chunks where bandwidth dominates.
- Copy count matters. A path like `Ceph/S3 -> userspace buffer -> /dev/shm -> pinned
  DRAM -> GPU HBM` may erase the benefit of a cache hit.
- A minimum useful hit length exists. Small prefix matches are often cheaper to
  recompute than to fetch remotely.

### 4.5 Reading the Ceph + vLLM + LMCache Design

A practical mental model for the Ceph blog post:

```
vLLM:
  - manages KV in fixed-size blocks (PagedAttention)
  - hashes prompt blocks for prefix matching

LMCache:
  - exposes external storage connectors for those blocks
  - stages blocks through CPU memory and GPU transfer buffers

Ceph/S3:
  - stores the hashed KV chunks as a shared remote cache tier
  - trades ms-scale latency for very large capacity and cross-node reuse
```

The blog's main claim is narrow and important: for repeated long prompts, fetching KV
from shared object storage can beat recomputing prefill on GPUs.

---

## 5. Chunked Prefill

### 5.1 The Prefill/Decode Latency Conflict

Prefill for a long prompt (e.g., 32K tokens) dominates GPU time for hundreds of milliseconds.
During this time, no decode steps run — live sequences stall, increasing tail latency (P99).

```
Without chunked prefill:
  t=0  [PREFILL 32K tokens ——————————————— 400ms ——]  ← blocks decode
  t=400ms  [decode step 1] [decode step 2] ...

With chunked prefill (chunk=1K tokens):
  t=0   [prefill chunk 1/32 — 12ms] [decode batch]
  t=12  [prefill chunk 2/32 — 12ms] [decode batch]
  ...32 iterations interleaved...
  t=384ms  prefill complete, decode continues uninterrupted
```

### 5.2 Scheduling Algorithm

```python
def schedule(running: List[Seq], waiting: List[Seq], chunk_size: int):
    batch = []
    remaining_tokens = MAX_BATCH_TOKENS

    # First: continue decode for all running sequences
    for seq in running:
        if remaining_tokens <= 0: break
        batch.append(DecodeStep(seq))
        remaining_tokens -= 1  # decode = 1 token per seq

    # Second: fill remaining budget with prefill chunks
    for seq in waiting:
        if remaining_tokens <= 0: break
        chunk = min(chunk_size, seq.remaining_prefill, remaining_tokens)
        batch.append(PrefillChunk(seq, chunk))
        remaining_tokens -= chunk
        if seq.remaining_prefill == 0:
            waiting.remove(seq)
            running.append(seq)

    return batch
```

The key insight: prefill chunks and decode steps are batched into a single GPU forward
pass. The GPU runs them in the same kernel invocation, amortizing launch overhead.

---

## 6. KV Cache Eviction to CPU DRAM / NVMe

### 6.1 When to Evict

The scheduler must evict when all of the following hold:
- Free block pool is empty
- A waiting sequence needs blocks for its prompt
- No running sequence can be preempted cheaply

Eviction choices:
1. **Preempt-and-recompute:** free a sequence's blocks, recompute KV from scratch when
   rescheduled. Cost: one full prefill recompute.
2. **Preempt-and-swap:** copy blocks to CPU DRAM, restore on reschedule. Cost: PCIe
   transfer (H100 = 64 GB/s bidirectional PCIe 5.0).
3. **Evict prefix-cache blocks:** (ref_count=0 blocks). Free immediately, no restore needed.

### 6.2 Swap Bandwidth Math

Swapping 1 sequence of Llama-70B at seq_len=4K:
```
KV_bytes = 10.74 GB  (from Section 1.2)
PCIe 5.0 BW = 64 GB/s bidirectional = 32 GB/s each direction
Swap-out time = 10.74 / 32 = 336 ms
Swap-in time  = 336 ms

Total round-trip = 672 ms — larger than typical decode latency
```

This means swapping is only viable for sequences that will not be rescheduled soon
(long waiting queue). For short queues, recompute is cheaper.

### 6.3 NVMe Offload (Extended KV Cache)

Some systems (e.g., LMDeploy, MLC-LLM) offload cold prefix-cache blocks to NVMe:

```
GPU HBM       → hot prefix blocks (ref_count=0, recently used)
CPU DRAM      → warm prefix blocks (evicted from HBM, may be needed soon)
NVMe          → cold prefix blocks (rarely reused long contexts)
```

NVMe sequential read BW = 12 GB/s. Restoring a cold prefix-cache block of 42 MB:
```
42 MB / 12 GB/s = 3.5 ms  (acceptable if done during prefill of new tokens)
```

The NVMe offload path is useful for **multi-turn conversation** where the earlier turns
(cold) are needed again when the user sends a new message.

---

## 7. KV Quantization

### 7.1 Why Quantize KV

KV tensors are read/written every decode step. Halving their size halves HBM BW pressure.
For BW-bound decode, this directly increases throughput.

| Dtype | Bytes/element | HBM BW saving | Quality loss |
|-------|--------------|---------------|-------------|
| fp16 | 2 | baseline | baseline |
| fp8 (e4m3) | 1 | 50% | negligible for K |
| int8 | 1 | 50% | small, needs per-head scale |
| int4 | 0.5 | 75% | noticeable, needs careful tuning |

### 7.2 Per-Head Dynamic Quantization

```
For each attention head h, each KV block b:
  scale_k[h,b] = max(|K[h,b]|) / 127   (int8 scale factor)
  K_quant[h,b] = round(K[h,b] / scale_k[h,b]).clamp(-128, 127)

On load:
  K[h,b] = K_quant[h,b] * scale_k[h,b]
```

Scale factors are stored per-head-per-block (O(small)). The quantization happens on
the GPU during KV write (post-attention on the key/value projection), and dequantization
happens on load into the attention kernel.

---

## 8. Architect Cheat Sheet

```
Problem                     Algorithm/Solution              Key Number
─────────────────────────────────────────────────────────────────────
HBM fragmentation           PagedAttention (block table)   ~90% utilization (vs ~40%)
Shared system prompt        Content-addressed prefix cache  near-100% hit rate when warm
Long prefill blocks decode  Chunked prefill                 chunk=512-2048 tokens typical
HBM full, queue waiting     Swap-to-DRAM or recompute      swap: 336ms round-trip (70B,4K)
Cold prefix across turns    NVMe offload                    3.5ms restore per 42MB block
HBM BW bottleneck           KV quantization fp8            50% BW saving, negligible loss
Cross-node KV sharing       → see kv-disaggregation-reference.md

Block size tradeoff:
  Small B (4 tokens):  less internal fragmentation, more block table entries, more overhead
  Large B (64 tokens): more fragmentation, simpler table, better GPU memory coalescing
  Typical B=16 tokens is a practical balance
```

---

## 9. Key Papers

- **PagedAttention**: Kwon et al., "Efficient Memory Management for Large Language Model
  Serving with PagedAttention", SOSP 2023 (vLLM paper)
- **Prefix caching**: SGLang (Zheng et al., 2024) — RadixAttention for tree-structured prefix
- **Chunked prefill**: Sarathi-Serve (Agrawal et al., 2024)
- **KV quantization**: KIVI (Liu et al., 2024), KVQuant (Hooper et al., 2024)
- **Remote/shared KV cache**: practical examples include LMCache integrations with
  object storage backends such as S3/Ceph
