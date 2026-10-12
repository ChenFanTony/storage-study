# Day 4: Metadata Indexes and Small Objects

## Learning objectives

- Separate the object data path from the metadata/index path.
- Understand index sharding, LIST fan-out, and hot partitions.
- Explain why small objects are often metadata- or request-bound.
- Recognize safe object publication and garbage-collection boundaries.

## 1. Two coupled planes

An object service normally has at least two durable structures:

```text
bucket index / metadata                   object payload
key -> version, size, location, state     bytes or erasure shards
          |                                      |
          +------------ publication -------------+
```

A PUT must make payload and metadata converge after success, even though they
may be stored by different subsystems. Implementations commonly use temporary
names, intent records, prepare/complete states, or a head object written last.
The exact mechanism is system-specific.

Failure windows explain many background jobs:

- payload exists but is not referenced: orphan collection;
- index entry exists but payload is incomplete: repair or rollback;
- delete is recorded but old extents remain: asynchronous garbage collection;
- multipart parts outlive the client: incomplete-upload cleanup.

## 2. Bucket index and LIST

The bucket index maps keys to enough metadata to answer lookup and listing.
Large buckets partition that index:

```text
shard = hash(key) mod shard_count
```

Point lookup can target one shard. A lexicographically ordered LIST may need to
query multiple shards, merge results, enforce a limit, and return a
continuation token.

More shards improve concurrent update capacity but increase listing fan-out,
memory, recovery work, and resharding complexity. Dynamic resharding is useful,
but it is not free and should be monitored.

## 3. Hotspots

A balanced hash does not guarantee a balanced workload:

- one key may receive extreme overwrite traffic;
- one bucket may concentrate every tenant;
- LIST of a broad prefix may touch every index shard;
- a timestamp prefix may concentrate new writes in one logical range;
- a small number of popular objects may saturate gateway cache or network.

Measure request distribution by bucket, operation, status, key/prefix, and
backend shard. Avoid labels containing arbitrary keys in Prometheus because
that creates a second cardinality problem.

## 4. Why small objects are expensive

For a 4 KiB object, fixed work can dominate payload transfer:

```text
TLS + HTTP parsing + authentication + authorization
+ index update + object metadata + checksum
+ allocation + replication/EC bookkeeping + response
```

Capacity efficiency can also collapse when allocation units, replicas,
metadata records, journals, or EC stripe padding are much larger than the
payload.

Common responses include batching samples into larger immutable shards,
packing tiny blobs into containers, caching metadata, and choosing a system
designed for small objects. Each choice trades simple direct access for an
additional index or compaction lifecycle.

## 5. Publication invariant

A successful response should mean the object is reachable according to the
service contract and recoverable after a supported failure. It does not
necessarily mean every old physical extent has already been reclaimed.

For application-level multi-object data:

```text
write immutable objects -> verify each -> write manifest -> conditionally write COMMITTED
```

Readers begin from the final marker, then validate the manifest. They never
infer completeness from a prefix listing.

## 6. Lab: expose size-dependent overhead

Create 10,000 objects with the same total bytes in two layouts:

```text
layout A: 10,000 x 4 KiB
layout B:    10 x 4 MiB
```

Measure:

- total PUT time and requests per second;
- p50, p95, and p99 latency;
- bucket-index or metadata growth;
- raw backend consumption;
- LIST time and number of pages;
- delete completion and later reclaimed capacity.

The purpose is not a universal performance number. It is to reveal fixed
per-request and per-object costs in your chosen implementation.

## Failure patterns

- Increasing index shards without measuring LIST and recovery costs.
- Assuming key prefixes directly control physical placement.
- Publishing a dataset because all expected keys appeared in one LIST.
- Deleting metadata synchronously while leaking payload extents indefinitely.
- Measuring only logical bytes and missing metadata or allocation overhead.

## Self-check

1. Why can point lookup and LIST scale differently?
2. What creates an orphan object?
3. Why do small objects stress more than disk bandwidth?
4. What does the final commit marker protect?

## References

- [Ceph RGW bucket-index design](https://docs.ceph.com/en/latest/dev/radosgw/bucket_index/)
- [Ceph RGW dynamic resharding](https://docs.ceph.com/en/latest/radosgw/dynamicresharding/)
- [Ceph RGW data layout](https://docs.ceph.com/en/latest/radosgw/layout/)
- [SeaweedFS architecture](https://github.com/seaweedfs/seaweedfs/blob/master/README.md)

---

## Previous / Next

[← Previous: Day 3 — Multipart, versioning, lifecycle, and Object Lock](day03-multipart-versioning-lifecycle-lock.md) | [Object-storage study index](README.md) | [Next: Day 5 — Durability and repair: replication, erasure coding, placement, scrub, and healing →](day05-durability-placement-and-repair.md)
