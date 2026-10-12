# Day 10: AI Data and Checkpoint Patterns

## Learning objectives

- Design object layouts that keep accelerators fed.
- Use range GET only with formats that support independent ranges.
- Add node-local caching without breaking version correctness.
- Publish multi-object datasets and checkpoints atomically at application level.

## 1. Training-data path

```text
manifest/catalog
      |
      v
trainer ranks -> S3 gateways -> object store
      |               |
      +-> prefetch     `-> large immutable shards
      +-> decode
      `-> node-local NVMe/DRAM cache
```

GPU utilization is the end-to-end metric. Storage bandwidth can look healthy
while workers stall on serialized LIST, tiny-object request overhead, Python
decode, cache misses, or load imbalance.

## 2. Shard for useful I/O

One object per sample is simple but can create extreme request and metadata
rates. Larger immutable shards amortize authentication, HTTP, metadata, and
placement costs.

Choose shard size by measuring:

- time to first sample;
- sequential and random sample access;
- retry cost when one transfer fails;
- worker/rank parallelism;
- cache granularity and eviction;
- dataset update and repair granularity.

Formats such as tar-based shards favor streaming. Indexed formats such as
Parquet support selective range reads when their footer and row-group layout
match the access pattern. A range GET cannot make an arbitrary compressed
stream randomly seekable.

## 3. Manifests instead of LIST

A dataset manifest should identify a stable generation:

```json
{
  "dataset": "images",
  "generation": "2026-10-12T08:00:00Z",
  "objects": [
    {"key": "datasets/images/g42/shard-0000.tar", "size": 1073741824,
     "checksum": "sha256:..."}
  ]
}
```

Workers fetch one small manifest and deterministically divide keys. This avoids
repeated broad LIST operations, produces reproducible epochs, and gives
integrity checks a trusted input.

Publish immutable shards first, validate them, write the manifest, then create
a final marker with a conditional write. Readers start only from a committed
generation.

## 4. Cache by immutable identity

A cache entry keyed only by bucket/key becomes stale when that key is
overwritten. Prefer immutable keys or include version ID/checksum in the cache
identity:

```text
cache key = endpoint + bucket + key + version ID or trusted checksum
```

Use bounded concurrency and admission. A cache miss from every rank at once can
create a thundering herd. One node-level fetch coordinator or request
coalescing can reduce duplicate transfers.

Cache correctness also requires eviction and disk-pressure behavior. The cache
must never consume space reserved for checkpoints, logs, or system recovery.

## 5. Multi-rank checkpoint publication

A checkpoint generation is not one object:

```text
checkpoints/run-7/step-420/rank-0000.bin
checkpoints/run-7/step-420/rank-0001.bin
...
checkpoints/run-7/step-420/manifest.json
checkpoints/run-7/step-420/COMMITTED
```

Protocol:

1. assign an immutable generation ID;
2. each rank uploads with multipart/checksum as needed;
3. ranks report key, size, checksum, and version to the coordinator;
4. coordinator verifies every expected rank;
5. coordinator writes the manifest;
6. coordinator conditionally creates `COMMITTED`;
7. readers restore only generations with a valid marker and manifest.

If a rank fails, leave the generation uncommitted and clean it later by a
carefully scoped policy. Never let readers infer completion from the number of
keys returned by LIST.

## 6. Object API or filesystem?

| Requirement | Object API | Shared filesystem |
|-------------|------------|-------------------|
| Immutable large shards | Strong fit | Good |
| Existing POSIX application | Adapter required | Natural fit |
| Atomic file rename | No general equivalent | Usually available |
| Fine-grained in-place update | Poor fit | Better fit |
| WAN/cloud tooling | Broad ecosystem | Deployment-specific |
| Lifecycle/versioning/retention | Native concepts | Separate mechanisms |
| Millions of tiny random reads | Pack/cache first | May be easier with tuned metadata |

FUSE mounting an object store may improve compatibility but does not magically
provide every POSIX guarantee. Verify rename, locking, fsync, consistency, and
failure behavior for the adapter.

## 7. Capstone lab

Build a small dataset publisher and reader:

1. create four immutable shard objects;
2. store explicit full-object checksums;
3. write a manifest listing exact versions and sizes;
4. conditionally create the commit marker;
5. have two readers split shards deterministically;
6. cache by checksum or version;
7. corrupt or omit one shard and confirm validation stops training;
8. leave one incomplete generation and prove readers ignore it;
9. measure GPU/data-loader stall or, without a GPU, consumer idle time.

Record the API guarantee used at each step. The final design should remain
correct if LIST is slow, a client retries, or a writer dies midway.

## Failure patterns

- One tiny object per sample without measuring request capacity.
- LIST before every epoch or batch.
- Range-reading a format with no independently decodable ranges.
- Reusing mutable keys behind a cache keyed only by name.
- Publishing a manifest before every rank is verified.
- Letting cleanup delete the current committed generation.
- Measuring object-store throughput without measuring accelerator starvation.

## Self-check

1. Why do immutable shards improve both caching and reproducibility?
2. When does range GET reduce transferred bytes?
3. What makes a checkpoint generation visible to readers?
4. Which identifier prevents stale cache reuse?

## References

- [Amazon S3 performance guidelines](https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance-guidelines.html)
- [Amazon S3 byte-range fetches](https://docs.aws.amazon.com/whitepapers/latest/s3-optimizing-performance-best-practices/use-byte-range-fetches.html)
- [Ceph Object Storage for AI workloads](../../reference/ceph-object-storage.md)
- [AI training data pipeline reference](../../L3-ai-storage/training-data-reference.md)
- [Checkpoint reference](../../L3-ai-storage/checkpoint-reference.md)

---

## Previous / Further Study

[← Previous: Day 9 — Observability and performance: metrics, benchmarking, capacity, and diagnosis](day09-observability-benchmarking-capacity.md) | [Object-storage study index](README.md) | [Continue: Ceph RADOS, BlueStore, MinIO, and SeaweedFS review →](../systems/m2-day22-30-object-storage-review.md)
