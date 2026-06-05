# Training Data Pipeline — Architect Reference

Related: [memory-hierarchy-reference.md](memory-hierarchy-reference.md)

---

## 0. Terminology

| Term | Definition |
|------|-----------|
| Sample | One training example (image+label, text chunk, etc.) |
| Shard | A file containing many samples (e.g., 1000 images in one tar) |
| Global shuffle | Random permutation of all samples before training starts |
| Local shuffle | Shuffle within a buffer window (bounded memory) |
| Epoch | One full pass through the dataset |
| Prefetch | Loading the next batch in background while GPU processes current batch |
| DataLoader | PyTorch's multi-process data loading subsystem |
| WebDataset | Tar-based streaming dataset format, no random access required |
| Parquet | Columnar binary format (Apache Arrow on disk), efficient for tabular/NLP |
| MDS | Mosaic Data Shard format (MosaicML) — optimized for random-access shuffle |
| DALI | NVIDIA Data Loading Library — GPU-accelerated decode pipeline |

---

## 1. Background: The Data Starvation Problem

### 1.1 GPU Compute Demand vs Storage Bandwidth

An H100 training a vision transformer (ViT-L) processes 256 images per step at 200 steps/sec:

```
Throughput demand: 256 × 200 = 51,200 images/sec
Each ImageNet image (JPEG): ~100 KB decoded, ~10 KB compressed
Compressed read rate: 51,200 × 10 KB = 512 MB/s
Decoded + preprocessed: 51,200 × 100 KB = 5 GB/s  (must happen in CPU before GPU)
```

A single NVMe delivers 7 GB/s sequential — barely enough. But training clusters use
object storage (S3, DAOS) at 10-50 GB/s aggregate with higher latency. Without careful
pipeline design, GPUs stall waiting for data.

### 1.2 The Shuffle Requirement

Stochastic gradient descent requires training data to be presented in random order
across epochs. Presenting data in the same order each epoch introduces bias and slows
convergence. The challenge: shuffling a 100TB dataset cannot fit in RAM.

Three approaches, increasing in quality:

```
1. Pre-shuffle: shuffle globally before training (one-time cost, perfect randomness)
   Cost: O(dataset_size) disk I/O, O(dataset_size) storage
   Quality: perfect

2. In-pipeline shuffle buffer: load samples into a buffer, randomly pop from it
   Cost: O(buffer_size) RAM, online
   Quality: correlated within buffer_size² samples

3. Shard shuffle: shuffle order of shards, sequential within each shard
   Cost: minimal (no sample movement)
   Quality: samples within a shard are correlated (order preserved)
```

---

## 2. Data Formats

### 2.1 WebDataset (Tar-based Streaming)

WebDataset stores samples as sequential tar entries:

```
dataset_00000.tar:
  000000.jpg         ← sample 0 image
  000000.cls         ← sample 0 label
  000001.jpg
  000001.cls
  ...
  999999.jpg
  999999.cls

dataset_00001.tar: ...
```

**Key property:** tar is a purely sequential format. Reading proceeds front-to-back,
no seek required. This maps directly to sequential NVMe/object storage reads.

**Access pattern:**
```
Sequential read at full NVMe/network BW → ~7 GB/s local, 5-50 GB/s object store
No random I/O → no seek penalty, predictable throughput
```

**Shuffle:** Shard-level shuffle (randomize order of shards) + per-shard buffer shuffle.

```python
dataset = (
    wds.WebDataset(urls, shardshuffle=True)   # shuffle shard order each epoch
       .shuffle(buffer_size=1000)              # buffer-shuffle within stream
       .decode("pil")
       .to_tuple("jpg", "cls")
)
```

`shardshuffle=True`: shard URLs are randomly permuted. Each DataLoader worker picks
a different shard, so cross-worker samples are from different shards (reduces correlation).

### 2.2 Parquet + Apache Arrow

Used for NLP/tabular datasets (text tokens, embeddings, metadata).

**Structure:**
```
Row group (128 MB default):
  Column A: [val_0, val_1, ..., val_N]   ← values stored contiguously per column
  Column B: [val_0, val_1, ..., val_N]
  ...
  Statistics: min/max per column per row group (enables predicate pushdown)
```

**Columnar advantage for NLP:**
```
Token ID column: int32 array, highly compressible (small vocabulary)
Attention mask:  binary array, 95%+ ones → RLE compresses 20×
Text length:     int32 array, locality for variable-length filtering
```

**Random access:** Parquet supports row-group-level random access. To read sample i:
```
row_group_id = i // row_group_size
row_within_group = i % row_group_size
seek to row_group offset in file, read row_group_size rows, slice [row_within_group]
```

This is O(1) seeks per sample access, enabling true random shuffle on disk.
Cost: each random access = one row group read (~128 MB) → catastrophic for random access
patterns. Cache row groups in DRAM to amortize.

### 2.3 MosaicML MDS (Mosaic Data Shard)

Designed to provide:
1. Global random access (like Parquet) without random I/O penalty
2. Streaming-friendly (like WebDataset)

**Format:**
```
shard_00000.mds:
  [index block: offset + length of each sample in this shard]
  [sample_0_bytes] [sample_1_bytes] ... [sample_N_bytes]
```

**Access pattern:**
```
To read sample i from a known shard:
  1. Read index[i] → (offset, length)   [index is cached in memory, O(1)]
  2. Seek to offset, read length bytes   [O(1) seek per sample]
```

The index is small (~16 bytes/sample × 1M samples = 16 MB) and fits in DRAM.
Once the index is warm, random access requires exactly one NVMe seek per sample.

**Shuffle algorithm:**
```
At epoch start, generate a global random permutation of all sample IDs: perm[0..N-1]
For rank r in world_size W:
  local_indices = perm[r * (N//W) : (r+1) * (N//W)]
  Sort local_indices by (shard_id, sample_within_shard) for sequential reads:
    → sample IDs 47, 93, 47_in_shard2, 93_in_shard2 → sorted to read shard2 sequentially
```

This provides global shuffle quality with sequential I/O access pattern —
the key insight that makes MDS efficient.

---

## 3. Prefetch Pipeline Design

### 3.1 The Pipeline Stages

```
Stage 0: Shard read (storage → CPU DRAM)         [storage-bound]
Stage 1: Decompression (JPEG decode, etc.)        [CPU-bound]
Stage 2: Augmentation (resize, crop, flip)        [CPU-bound]
Stage 3: Tensor conversion (PIL → torch.Tensor)   [CPU-bound]
Stage 4: Transfer to GPU (pinned DRAM → HBM)      [PCIe-bound]
Stage 5: GPU forward pass                         [compute-bound]
```

For GPU utilization = 100%, every stage must complete within one GPU step time.
If any stage is slower, GPU stalls.

### 3.2 PyTorch DataLoader Architecture

```
Main process (training loop):
  iter = DataLoader(dataset, num_workers=W, prefetch_factor=P)
  for batch in iter:
      batch.cuda(non_blocking=True)  # async PCIe transfer
      optimizer.zero_grad()
      loss = model(batch)            # GPU compute
      loss.backward()
      optimizer.step()
      # next batch is already prefetched

Worker processes (W parallel, forked):
  Each worker:
    - Has its own copy of dataset (after fork)
    - Reads from distinct shards (determined by DistributedSampler)
    - Puts batches into shared-memory queue (DRAM)

Queue between workers and main:
  Capacity: W × prefetch_factor batches
  When full: workers block (backpressure)
  When empty: main process blocks (starvation)

Non-blocking transfer:
  batch.cuda(non_blocking=True) posts a PCIe DMA to the CUDA stream
  GPU compute and PCIe DMA overlap if GPU has copy engine
```

### 3.3 Double-Buffer Prefetch (Ring Buffer Pattern)

```python
class PrefetchLoader:
    def __init__(self, loader, device):
        self.loader = loader
        self.stream = torch.cuda.Stream()
        self.next_batch = None

    def __iter__(self):
        self._preload()  # load first batch
        for batch in self.loader:
            current = self.next_batch
            self._preload()      # start loading next batch
            yield current        # return current to training loop

    def _preload(self):
        try:
            data = next(self._loader_iter)
        except StopIteration:
            self.next_batch = None
            return
        with torch.cuda.stream(self.stream):
            self.next_batch = data.cuda(non_blocking=True)
        # CUDA stream runs DMA in background; training loop uses default stream
        # torch.cuda.current_stream().wait_stream(self.stream) at yield time ensures
        # DMA is complete before GPU compute starts
```

The `self.stream.wait_stream(torch.cuda.current_stream())` at the yield point is the
synchronization: GPU compute cannot start on `next_batch` until the PCIe DMA is done.
But since DMA happens concurrently with the previous step's compute, the latency is hidden.

### 3.4 NVIDIA DALI (GPU-Accelerated Pipeline)

For vision workloads, CPU decode + augmentation can become the bottleneck.
DALI moves image decode (JPEG → RGB tensor) and augmentation to GPU:

```
CPU:  read JPEG bytes from storage
GPU:  nvJPEG decode → RGB tensor → resize → random crop → color jitter → normalize
```

This frees CPU workers for more I/O and eliminates the CPU augmentation bottleneck.
Typical speedup: 2-4× for ResNet/ViT training on high-throughput datasets.

```python
pipe = dali.Pipeline(batch_size=256, num_threads=4, device_id=0)
with pipe:
    images, labels = fn.readers.file(file_root=data_dir)
    images = fn.decoders.image(images, device="mixed")  # JPEG decode on GPU
    images = fn.random_resized_crop(images, size=224, device="gpu")
    images = fn.crop_mirror_normalize(images, device="gpu",
                                      mean=[0.485*255, 0.456*255, 0.406*255],
                                      std=[0.229*255, 0.224*255, 0.225*255])
pipe.build()
```

---

## 4. Global Shuffle Algorithms

### 4.1 Naive Global Shuffle (Pre-shuffle)

For datasets that fit the index in RAM:
```python
indices = list(range(N))
random.shuffle(indices)
# Write shuffled index to disk or use as permutation array
```

Reading in shuffled order from Parquet/MDS: each sample access = one random seek.
At 100 µs seek latency (NVMe) and 51,200 samples/sec demand:
```
Max random IOPS = 51,200
NVMe random 4KB IOPS = ~1,000,000 IOPS  → feasible for NVMe-local
Object store IOPS = ~10,000 IOPS → NOT feasible for object-store-backed random access
```

Global shuffle is only practical with local NVMe. For object storage: use shard shuffle.

### 4.2 Reservoir Sampling (Online, Unbounded Dataset)

For streaming datasets where total size is unknown or infinite:

**Algorithm (maintaining a shuffle buffer of size K):**
```python
def reservoir_shuffle(stream: Iterator, K: int) -> Iterator:
    buffer = []

    # Fill buffer initially
    for item in itertools.islice(stream, K):
        buffer.append(item)

    # Emit items, replacing each with the next from stream
    random.shuffle(buffer)
    for item in stream:
        # Replace a random position with new item, yield displaced item
        idx = random.randrange(K)
        yield buffer[idx]
        buffer[idx] = item

    # Drain remaining buffer
    random.shuffle(buffer)
    yield from buffer
```

Property: each sample is equally likely to appear at any position in the output,
within the correlation bound of the buffer size K.

Correlation: samples within K consecutive positions have 1/K chance of being from
the same local neighborhood in the original stream. For K=1000, adjacent emitted
samples are from different neighborhoods with probability 999/1000.

### 4.3 Quasi-Random Sampling for LLM Text Data

LLM training uses text documents, not fixed-size samples. A document is split into
`seq_len`-token chunks. Shuffling chunks globally would break document coherence.

Common strategy:
1. Shuffle document order (shard shuffle at document granularity)
2. Pack consecutive documents into fixed-length sequences with `<EOS>` separator
3. No intra-document shuffling

```
Doc shuffle → [doc_47, doc_93, doc_12, ...]
Pack:          [tok_0..tok_511|<EOS>|tok_0..tok_1023|<EOS>|tok_0..tok_255|...]
               [               seq 0                |          seq 1          ]
```

This preserves intra-document token order while shuffling at the document level.

---

## 5. Distributed Data Loading

### 5.1 DistributedSampler

With N training processes (ranks), each rank must see a disjoint subset of the dataset:

```python
class DistributedSampler:
    def __init__(self, dataset, num_replicas, rank, shuffle=True, seed=0):
        self.num_replicas = num_replicas
        self.rank = rank
        self.num_samples = math.ceil(len(dataset) / num_replicas)
        self.total_size = self.num_samples * num_replicas  # padded to divisible
        self.shuffle = shuffle
        self.seed = seed
        self.epoch = 0

    def __iter__(self):
        g = torch.Generator()
        g.manual_seed(self.seed + self.epoch)  # different shuffle each epoch
        indices = torch.randperm(len(self.dataset), generator=g).tolist()
        # Pad to total_size
        indices += indices[:(self.total_size - len(indices))]
        # Select this rank's subset
        indices = indices[self.rank : self.total_size : self.num_replicas]
        return iter(indices)

    def set_epoch(self, epoch):
        self.epoch = epoch  # called before each epoch to change shuffle seed
```

Critical: `set_epoch(epoch)` must be called before each epoch's DataLoader iteration,
otherwise all ranks see the same shuffle every epoch (broken).

### 5.2 Shard Assignment for Streaming

With WebDataset, shard assignment (not sample assignment) is used:

```python
# Each rank reads a different subset of shards
shards_per_rank = total_shards // world_size
my_shards = all_shard_urls[rank * shards_per_rank : (rank+1) * shards_per_rank]
dataset = wds.WebDataset(my_shards)
```

For multi-GPU nodes with multiple DataLoader workers:
```
Rank 0 (GPU 0), Worker 0: reads shards 0, 4, 8, ...
Rank 0 (GPU 0), Worker 1: reads shards 1, 5, 9, ...
Rank 1 (GPU 1), Worker 0: reads shards 2, 6, 10, ...
Rank 1 (GPU 1), Worker 1: reads shards 3, 7, 11, ...
```

Each worker reads sequentially within its shard list → full sequential BW per worker.

---

## 6. Architect Cheat Sheet

```
Scenario                       Format           Shuffle strategy        I/O pattern
─────────────────────────────────────────────────────────────────────────────────────
Vision, local NVMe             WebDataset/MDS   Shard + buffer shuffle  Sequential
Vision, object storage         WebDataset       Shard shuffle only      Sequential
NLP tokens, local              MDS              Global permutation      Sequential per shard
NLP text, object store         Parquet/WebData  Document shuffle        Sequential
Tabular, columnar queries      Parquet          Row-group based         Columnar sequential
Unknown size / streaming       Any              Reservoir sampling (K)  Streaming

Bottleneck diagnosis:
  GPU util low, CPU util high   → add more DataLoader workers (num_workers)
  GPU util low, CPU util low    → storage BW insufficient; switch format or add NVMe
  GPU util low, PCIe BW high    → prefetch_factor too low; increase to 4+
  GPU util ~100%, loss noisy    → shuffle quality issue; increase buffer or use MDS global

Key numbers:
  NVMe seq BW: 7 GB/s per device
  Prefetch buffer in DRAM: 8-16 batches typical (few hundred MB)
  num_workers rule of thumb: 4-8 per GPU; diminishing returns beyond 16
  prefetch_factor: 2-4 (controls queue depth between worker and training loop)
```
