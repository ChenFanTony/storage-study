# L3 AI Storage — Study Track

This track covers storage architecture for AI/ML infrastructure. It sits above L1/L2 in abstraction
but draws on all of them: local NVMe (L1), distributed object storage (L2), and adds the
AI-specific data access patterns that neither covers.

## Why AI Storage Is a Separate Domain

Traditional storage is measured by IOPS, throughput, and latency to a block or file.
AI storage adds a fourth dimension: **tensor access pattern** — the shape, stride, and
memory tier of tensors during training and inference. The bottleneck is not disk I/O
latency but HBM bandwidth, and the consistency model is not POSIX but "the checkpoint
is either complete or does not exist."

## Topics and Files

| File | Topic | Core Algorithm |
|------|-------|---------------|
| [kv-cache-reference.md](kv-cache-reference.md) | KV cache management in LLM inference | PagedAttention, prefix caching, LRU eviction |
| [kv-disaggregation-reference.md](kv-disaggregation-reference.md) | Prefill/decode disaggregation, cross-node KV transfer | RDMA zero-copy, Mooncake placement |
| [checkpoint-reference.md](checkpoint-reference.md) | Consistent checkpoint I/O for distributed training | Chandy-Lamport, async DCP, EC for shards |
| [training-data-reference.md](training-data-reference.md) | Training data pipeline: format, shuffle, prefetch | Reservoir sampling, double-buffer prefetch |
| [memory-hierarchy-reference.md](memory-hierarchy-reference.md) | HBM → DRAM → NVMe → object storage tier stack | Spill/prefetch policy, bandwidth math |

## Prerequisite Map

```
L1: NVMe/block I/O      → memory-hierarchy, kv-cache (NVMe offload path)
L1: page cache / VFS    → kv-cache (PagedAttention analogy)
L2: DAOS / object store → checkpoint (shard writes), training-data (dataset store)
L2: RDMA / CaRT         → kv-disaggregation (RDMA zero-copy KV transfer)
L2: consensus / 2PC     → checkpoint (distributed consistency)
```

## Reading Order

1. `memory-hierarchy-reference.md` — establishes the tier stack everything else refers to
2. `kv-cache-reference.md` — the central AI inference storage problem
3. `kv-disaggregation-reference.md` — extends KV cache to multi-node
4. `checkpoint-reference.md` — training fault tolerance
5. `training-data-reference.md` — data ingestion pipeline

## Key Numbers to Know

| Tier | BW | Latency | Capacity/node | $/GB |
|------|----|---------|----------------|------|
| GPU HBM (H100) | 3.35 TB/s | ~100 ns | 80 GB | ~$50 |
| CPU DRAM | 200–300 GB/s | ~100 ns | 1–2 TB | ~$5 |
| NVMe (local) | 12–14 GB/s | ~100 µs | 30–60 TB | ~$0.3 |
| NVMe over Fabric (NVMeoF) | 10–12 GB/s | ~300 µs | — | — |
| Object Storage (S3/Ceph) | 10–50 GB/s aggregate | ~10 ms | unlimited | ~$0.02 |
| InfiniBand NDR (400 Gbps) | 50 GB/s | ~1 µs | — | — |
