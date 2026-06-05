# Distributed Training Checkpoint I/O — Architect Reference

Related: [memory-hierarchy-reference.md](memory-hierarchy-reference.md)

---

## 0. Terminology

| Term | Definition |
|------|-----------|
| Checkpoint | A consistent snapshot of all model state needed to resume training exactly |
| Model state | Weights, optimizer states (momentum, variance), LR scheduler state, RNG state |
| Rank | One process in a distributed training job; each rank has a shard of model state |
| DP | Data Parallelism — replicate model across ranks, each sees different data |
| TP | Tensor Parallelism — split weight tensors across ranks (Megatron-LM style) |
| PP | Pipeline Parallelism — split model layers across ranks |
| DCP | PyTorch Distributed Checkpoint — standard for distributed saves |
| Async checkpoint | Copy state to CPU DRAM, background-write to storage while training continues |
| EC shards | Erasure-coded checkpoint shards — tolerate node loss without full resave |
| MTBF | Mean Time Between Failures — ~50,000 hours per GPU, drops with cluster size |
| Consistent cut | A global snapshot where no in-flight message is captured mid-send |

---

## 1. Background: The Failure Arithmetic

### 1.1 Why Checkpoints Are Non-Negotiable

Training a 70B model takes ~30 days on 1024 GPUs. GPU MTBF ≈ 50,000 hours.

Expected failures during training:
```
P(≥1 failure in 30 days) = 1 - P(0 failures)
                         = 1 - (1 - 1/(50000/720))^1024
                         = 1 - (1 - 0.0144)^1024
                         ≈ 1 - e^(-1024×0.0144)
                         ≈ 1 - e^(-14.75)
                         ≈ 1.0  (essentially certain)
```

With a 15-minute checkpoint interval and 30-minute restart overhead, expected wasted
compute per failure = (7.5 + 30) min = 37.5 min. At 14+ failures over 30 days:
total wasted compute ≈ 37.5 × 14 / (30 × 24 × 60) ≈ 1.2% overhead.

Without checkpoints: one failure restarts 30 days of training from scratch.

### 1.2 Model State Size

For Llama-3-70B, mixed-precision training (BF16 weights + FP32 optimizer state):

```
Parameter count: 70 × 10⁹ parameters

Weights (BF16, 2 bytes): 140 GB
Optimizer states (Adam):
  - Momentum m (FP32, 4 bytes):  280 GB
  - Variance v (FP32, 4 bytes):  280 GB
  Total Adam states:             560 GB

Gradient buffer (BF16):          140 GB  (held during backward)
Total at checkpoint time:        700 GB  (weights + optimizer states)
```

With DP=8, TP=4, PP=4 (ZeRO-3): each of 1024 ranks holds 700GB/1024 ≈ 683 MB.
Total checkpoint = 700 GB written simultaneously by 1024 ranks.

---

## 2. Consistency Requirements

### 2.1 What "Consistent" Means

A checkpoint is consistent if resuming from it produces the same result as if the
training had never been interrupted. This requires:

1. All ranks capture state at the **same training step** (iteration N)
2. Optimizer state matches weights (partial Adam update → corrupt gradients on resume)
3. Data loader state matches (no sample seen twice or skipped)
4. RNG state matches (dropout, data augmentation must be deterministic)

A partial checkpoint (ranks saved at different steps) is **worse than no checkpoint**
because resuming from it silently produces wrong model weights.

### 2.2 Chandy-Lamport Snapshot Algorithm (Background)

The theoretical foundation for consistent distributed snapshots. For completeness:

```
In a distributed system with channels (message queues):

1. Process P1 initiates snapshot: record own state S1, send MARKER on all outgoing channels
2. Process Pj receives MARKER on channel Cij:
   - If first MARKER: record own state Sj, send MARKER on all outgoing channels,
                      start recording messages arriving on all other incoming channels
   - If subsequent MARKER on channel Cik: stop recording on Cik, Cik state = recorded msgs
3. Snapshot = {S1, S2, ..., Sn} ∪ {channel states}
```

This captures a **consistent cut**: no process records state after it has received a
message that was sent after another process took its snapshot.

### 2.3 Distributed Training Simplification

Training does not use Chandy-Lamport directly because:
- Training is **synchronous** (all ranks execute the same step in lockstep, with barriers)
- At the end of each gradient sync (AllReduce), all ranks are implicitly at the same
  logical time — the channel states are empty (no in-flight messages)

The checkpoint is simply: **all ranks save their shard at the same step boundary**,
after the AllReduce completes and before the optimizer step of step N+1.

```python
if step % checkpoint_interval == 0:
    dist.barrier()          # ensure all ranks at same step
    save_checkpoint(rank_shard, step)
    dist.barrier()          # ensure all ranks finished saving
```

The double barrier guarantees the consistent cut without implementing full Chandy-Lamport.

---

## 3. PyTorch Distributed Checkpoint (DCP)

### 3.1 Design Principles

DCP (PyTorch ≥ 2.1) solves the N-to-N checkpoint problem: training uses N ranks,
resumption may use M ≠ N ranks (scale-up or scale-down).

Key properties:
- **No coordinator:** each rank independently writes its own file(s)
- **Shard-independent:** each file contains metadata about tensor layout, enabling
  re-sharding on load
- **O(1/N) per-rank I/O:** total checkpoint time dominated by storage BW, not rank count
- **Elastic recovery:** load from N-rank checkpoint into M-rank training by redistributing
  tensor shards at load time

### 3.2 File Format

```
checkpoint_dir/
  .metadata                  ← global metadata: step, world_size, tensor registry
  __0_0.distcp               ← rank 0 shard
  __1_0.distcp               ← rank 1 shard
  ...
  __N-1_0.distcp             ← rank N-1 shard
```

Each `.distcp` file:
```
[header: JSON]
  {
    "version": "1.0",
    "tensors": [
      {
        "fqn": "model.layers.0.self_attn.q_proj.weight",
        "dtype": "bfloat16",
        "shape": [4096, 4096],
        "storage_offset": 0,     ← byte offset in this file's data blob
        "num_bytes": 33554432
      },
      ...
    ]
  }
[data blob: raw tensor bytes concatenated]
```

The `fqn` (fully qualified name) is the key for re-sharding: at load time, a rank that
needs `layers.0.q_proj.weight` can find which files contain which slices of it.

### 3.3 Save Algorithm

```python
def dcp_save(state_dict: Dict[str, Tensor], checkpoint_dir: str, rank: int):
    # 1. Flatten state_dict into per-rank tensor list
    local_tensors = get_local_shards(state_dict)  # only tensors local to this rank

    # 2. Write shard file
    with open(f"{checkpoint_dir}/__{rank}_0.distcp", "wb") as f:
        header = build_header(local_tensors)
        f.write(json.dumps(header).encode())
        for tensor in local_tensors:
            f.write(tensor.cpu().numpy().tobytes())  # blocking CPU copy + write

    # 3. Rank 0 writes global metadata after all ranks signal done
    dist.barrier()
    if rank == 0:
        metadata = {
            "step": global_step,
            "world_size": dist.get_world_size(),
            "tensor_registry": gather_tensor_list_from_all_ranks()
        }
        write_atomic(f"{checkpoint_dir}/.metadata", json.dumps(metadata))
```

The `.metadata` file is the **commit record**: it is written last, atomically. A checkpoint
directory without `.metadata` is incomplete and discarded on resume.

### 3.4 Load Algorithm with Re-sharding

```python
def dcp_load(checkpoint_dir: str, state_dict: Dict[str, Tensor], rank: int, world_size: int):
    metadata = load_metadata(checkpoint_dir)
    old_world_size = metadata["world_size"]

    for fqn, tensor in state_dict.items():
        # Determine which files contain data for this rank's slice of 'fqn'
        needed_slices = compute_needed_slices(fqn, tensor.shape, rank, world_size,
                                              old_world_size, metadata)
        for (file_idx, offset, length, dst_slice) in needed_slices:
            with open(f"{checkpoint_dir}/__{file_idx}_0.distcp", "rb") as f:
                f.seek(offset)
                data = f.read(length)
            tensor[dst_slice].copy_(torch.frombuffer(data, dtype=tensor.dtype))
```

If world_size changes (N→M), each rank reads from multiple old shard files and
assembles its new local tensor. This is a many-to-many redistribution — O(N/M + M/N)
file reads per rank in the worst case.

---

## 4. Asynchronous Checkpointing

### 4.1 Motivation

Synchronous checkpoint: GPU stalls while CPU writes 683 MB to NVMe/object storage.

```
NVMe sequential write BW: 7 GB/s
Time to write 700 GB total: 100 ms per rank if ranks write in parallel to separate NVMe
Time to write to object storage (S3): 700 GB / (50 GB/s aggregate) = 14 seconds
```

14 seconds of GPU idle time at $3/GPU-hour = $0.001 per checkpoint wasted per GPU,
or $1/checkpoint for 1024 GPUs. At 4 checkpoints/hour = $4/hour wasted → $2,880/month.

Async checkpointing eliminates this cost.

### 4.2 Algorithm

```python
def async_checkpoint(state_dict, step, cpu_buffer: Dict[str, Tensor]):
    # Phase 1: CPU snapshot (fast, GPU continues training)
    # GPU→CPU copy happens in a non-blocking CUDA stream
    copy_stream = torch.cuda.Stream()
    with torch.cuda.stream(copy_stream):
        for name, tensor in state_dict.items():
            cpu_buffer[name].copy_(tensor, non_blocking=True)
            # pin_memory=True on cpu_buffer enables async PCIe DMA

    # Phase 2: Background write (happens while GPU trains next steps)
    def write_worker():
        copy_stream.synchronize()  # wait for GPU→CPU copy to finish
        dcp_save(cpu_buffer, f"checkpoint_{step}/", rank)

    threading.Thread(target=write_worker, daemon=True).start()
    # GPU resumes immediately — no wait for write_worker
```

Timeline:
```
Step N:  [forward] [backward] [allreduce] [optimizer] [GPU→CPU copy (async)] [step N done]
Step N+1:[forward] [backward] [allreduce] [optimizer]                         [step N+1 done]
                                                            ↑ CPU→NVMe write happens here (background)
Step N+2:[forward] ...
```

GPU→CPU copy uses PCIe DMA (H100: 64 GB/s bidirectional). For 683 MB per rank:
```
683 MB / 32 GB/s = ~21 ms  (one rank's PCIe copy)
```

This 21 ms overlaps with the training compute of step N+1. Net overhead: ~0 if step N+1
takes longer than 21 ms (typical for large batches).

### 4.3 Double-Buffer Safety

The CPU buffer must not be overwritten while the background write is still running:

```python
buffers = [
    {name: tensor.cpu().pin_memory() for name, tensor in state_dict.items()},  # buffer A
    {name: tensor.cpu().pin_memory() for name, tensor in state_dict.items()},  # buffer B
]
write_pending = False
active_buf = 0

def checkpoint_step(state_dict, step):
    global write_pending, active_buf
    if write_pending:
        write_thread.join()  # wait for previous write before reusing buffer
        write_pending = False

    buf = buffers[active_buf % 2]
    snapshot_to_cpu(state_dict, buf)        # GPU→CPU into current buffer
    launch_background_write(buf, step)       # write from current buffer
    write_pending = True
    active_buf += 1
```

---

## 5. Erasure Coding for Checkpoint Shards

### 5.1 Problem

A 1024-rank training job writes checkpoint to 1024 files. Each file needs to be
readable on resume. If node 7 fails before the next checkpoint, rank 7's shard is
on a failed NVMe — the checkpoint is unreadable.

### 5.2 EC Schema

Apply k+m Reed-Solomon erasure coding (same as DAOS EC_4P2G1 = k=4, m=2):

```
Take 4 rank shards, compute 2 parity shards.
Store all 6. Any 4 of 6 suffice to recover all 4 data shards.
```

For 1024 ranks with k=4, m=2 EC groups of 6:
- Overhead: 2/4 = 50% extra storage
- Tolerance: 2 shard failures per group → 2 node failures per 4 ranks

```python
def ec_checkpoint_save(rank_shard: bytes, group_id: int, group_rank: int,
                        k: int = 4, m: int = 2):
    # Each rank sends its shard to the group coordinator
    all_shards = gather_group_shards(rank_shard, group_id)  # collective within group

    if group_rank == 0:  # coordinator computes parity
        data_shards = [shard for shard in all_shards]
        parity_shards = rs_encode(data_shards, k, m)  # Reed-Solomon encoding
        for i, shard in enumerate(data_shards + parity_shards):
            write_to_storage(shard, group_id, shard_id=i)
```

On recovery (node 3 in group 0 failed):
```
Read available shards 0, 1, 2, 4, 5 (5 of 6, only need 4)
rs_decode(shards=[s0, s1, s2, None, s4, s5], k=4, m=2)  → recovers s3
Resume rank 3 from recovered shard
```

This avoids restarting from the previous checkpoint (which may be hours old) just because
one node's local disk failed.

---

## 6. Checkpoint Storage Backend Tradeoffs

| Backend | Write BW | Read BW | Latency | Capacity | Consistency guarantee |
|---------|---------|---------|---------|---------|----------------------|
| Local NVMe | 7 GB/s/rank | 7 GB/s/rank | ms | 30 TB/node | None (node-local) |
| Parallel FS (GPFS/Lustre) | 100-500 GB/s aggregate | same | ms-10ms | PB | POSIX (rename = atomic) |
| Object Store (S3/DAOS) | 10-50 GB/s aggregate | same | 10-100ms | unlimited | eventual (no POSIX rename) |
| CPU DRAM (transient) | 200 GB/s/node | same | µs | 1-2 TB/node | volatile |

**Consistency on object stores:**
Object stores lack atomic rename → the `.metadata` commit record cannot be written atomically.
Workaround: use a versioned key (`.metadata.step_N`) and write an index record last:

```
Write all shards to: checkpoint/step_N/__rank_X.distcp
Write index record:  checkpoint/step_N/.metadata  (last write, idempotent)
Validate on resume:  check .metadata exists, then load shards
```

An incomplete checkpoint (no `.metadata`) is silently ignored on resume.

---

## 7. Architect Cheat Sheet

```
Scenario                           Solution                       Key number
──────────────────────────────────────────────────────────────────────────────
Checkpoint interval too short      Increase interval → more lost work per failure
Checkpoint takes too long          Async checkpoint               0 GPU stall overhead
Single node checkpoint loss        EC k=4 m=2 over shard groups   +50% storage, tolerate 2 failures/group
Changing cluster size on resume    DCP re-sharding                any N→M resharding, O(1/min(N,M)) per rank
Object store consistency           .metadata as commit record     write shards first, index last
Save optimizer state               Always include (Adam m,v)      2× weight size, 4× for FP32 Adam
Skip optimizer state               Only valid for eval/inference  saves 3× storage

Rule of thumb:
  checkpoint_interval = sqrt(2 × restart_overhead / expected_failure_rate)
  For restart=30min, MTBF=50K hours, 1024 GPUs:
    failure_rate = 1024/50000 = 0.02 failures/hour
    interval = sqrt(2 × 0.5 / 0.02) = sqrt(50) ≈ 7 hours  (too long for prod)
  In practice: 15-30 min interval with async checkpoint reduces overhead to <0.5%
```
