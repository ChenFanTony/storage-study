# Ceph Object Storage (RGW) — Architect Reference for AI Storage

Ceph Object Gateway (RGW) exposes S3- and Swift-compatible APIs while storing
durable state in RADOS. It is a strong fit for immutable training shards, model
artifacts, and checkpoint bundles that do not require a mounted POSIX
namespace.

Related: [Ceph reference index](ceph.md), [CephFS](cephfs.md), and
[AI training data pipelines](../L3-ai-storage/training-data-reference.md).

---

## 0. Terminology

| Term | Meaning |
|------|---------|
| RGW | RADOS Gateway; Ceph's S3/Swift service |
| API object | The bucket/key object visible to an S3 or Swift client |
| RADOS head object | Object containing RGW metadata, a manifest, and optionally initial data |
| RADOS tail objects | Additional RADOS objects holding the remainder of a large API object |
| Bucket index | RADOS omap entries used for listing and object metadata coordination |
| Index shard | One RADOS object containing a hash partition of a bucket index |
| Placement target | Mapping from a bucket/storage class to RGW index and data pools |
| Realm | Top-level RGW multisite configuration and global namespace |
| Zonegroup | Group of zones that share a namespace and replication policy |
| Zone | One RGW deployment backed by a Ceph cluster or pool set |
| Multipart upload | S3 protocol for uploading parts independently and publishing one object on completion |

---

## 1. Architecture

```text
S3 clients
    |
    v
load balancer / DNS
    |
    +-------------------+-------------------+
    v                   v                   v
RGW instance A      RGW instance B      RGW instance C
    |                   |                   |
    +-------------------+-------------------+
                        |
                        v
                 RADOS pools
                   +-- RGW metadata
                   +-- bucket indexes
                   +-- object data
                   `-- multipart temporary data
```

RGW instances authenticate requests, implement the S3/Swift API, update bucket
indexes, and stream object data to or from RADOS. Durable state is in RADOS, so
request-serving gateways can be scaled horizontally behind a load balancer.
Gateway CPU, memory, TLS, request parsing, and network bandwidth can still
become bottlenecks before the OSDs do.

---

## 2. Object Write and Read Paths

### PUT object

```text
1. Client sends a signed PUT request to an RGW instance.
2. RGW authenticates the identity and evaluates authorization.
3. RGW selects the bucket's placement target and bucket-index shard.
4. RGW prepares the bucket-index transaction.
5. RGW streams data into one or more RADOS data objects.
6. RGW writes the head object last, making the new API object visible.
7. RGW commits the bucket-index transaction.
8. RGW returns success to the client.
```

An API object can map to a head RADOS object plus multiple tail objects. The
head stores metadata such as the manifest, ACL, content type, ETag, and
user-defined metadata. The manifest describes where tail data is stored.

RGW coordinates the head object and bucket index so that successful object
writes provide read-after-write consistency in a zone, including object
listing. A reader must see the new value, a later value, or a later delete; it
must not fall back to the overwritten value.

### Multipart upload

```text
CreateMultipartUpload
    |
    +-- UploadPart 1 ----> temporary RADOS data
    +-- UploadPart 2 ----> temporary RADOS data
    +-- UploadPart N ----> temporary RADOS data
    |
CompleteMultipartUpload
    |
    `-- publish one API object and its manifest
```

Multipart upload is the normal choice for large model or checkpoint artifacts.
Parts can be retried independently, and incomplete uploads are not exposed as
the completed object. Operators still need lifecycle rules or cleanup jobs for
abandoned multipart uploads.

### GET and range GET

```text
1. RGW resolves bucket, key, and version.
2. RGW reads the head object and manifest.
3. RGW maps the requested byte range to head/tail RADOS objects.
4. RGW reads from the relevant OSD placement groups.
5. RGW streams the response to the client.
```

Range GET helps when a shard format has an external or embedded index. It does
not make an arbitrary compressed stream randomly seekable; the file format's
compression blocks and indexes must support independent ranges.

---

## 3. Pool Layout and Erasure Coding

RGW conceptually separates:

| Pool role | Contents | Typical media/protection |
|-----------|----------|--------------------------|
| Metadata | Users, buckets, configuration, periods | Low-latency replicated pool |
| Bucket index | Key listings and basic object metadata in omap | Low-latency replicated pool |
| Data-extra | Multipart and other non-data state | Replicated pool |
| Object data | Head/tail object payload | Replicated or erasure-coded capacity pool |

Placement targets map bucket storage classes to concrete pools. The placement
target is selected when a bucket is created and is not a casual per-request
tuning knob.

Erasure coding is attractive for multi-petabyte immutable datasets because it
reduces raw-capacity overhead. The tradeoffs are wider failure domains,
additional CPU/network work, slower degraded reads, and more expensive small
updates. Keep index and control metadata on storage optimized for latency; use
EC for data only after measuring the real object-size distribution.

S3 lifecycle rules can move objects between storage classes whose placement
targets use different pools, for example from replicated NVMe-backed storage to
erasure-coded capacity storage.

---

## 4. Bucket Index Scaling

Every normal bucket has an index used by listing and other metadata operations.
The index can be divided into multiple RADOS objects called shards:

```text
hash(object key) % shard_count
       |
       +-- shard 0 -> index RADOS object 0
       +-- shard 1 -> index RADOS object 1
       `-- shard N -> index RADOS object N
```

Sharding increases update parallelism because independent index RADOS objects
can be modified concurrently. Dynamic resharding detects an overloaded bucket
index and increases its shard count. Resharding is transparent to clients, but
writes can pause briefly while reads continue.

Do not treat more shards as free performance:

- too few shards create hot index objects and serialized updates;
- too many shards increase listing fan-out, memory use, and operational work;
- one enormous bucket has a different failure and maintenance profile from
  many workload-scoped buckets;
- object-name prefixes do not by themselves guarantee separate index or OSD
  placement because hashing and CRUSH determine placement.

For AI data lakes, choose bucket boundaries around ownership, lifecycle,
security, and failure isolation—not just directory-like naming.

---

## 5. AI Workload Patterns

### Immutable training shards

```text
Recommended:
  object = dataset/version/shard-000123.tar
  size   = hundreds of MiB to several GiB
  access = sequential GET or indexed range GET
  write  = upload once, validate, then treat as immutable

Avoid when possible:
  one object per tiny sample
  repeated LIST before every batch
  overwrite-heavy objects shared by many writers
```

Large shards amortize HTTP, authentication, index, and RADOS-object overhead.
Workers should receive a manifest or precomputed shard list rather than
repeatedly listing a bucket during the training hot path.

### Parallel readers

Cluster-wide capacity is useful only when object names map across enough
placement groups and OSDs and when gateways are not saturated:

```text
trainer ranks
    |
    +-- persistent HTTP connections
    +-- bounded concurrent GETs
    +-- deterministic shard assignment
    `-- node-local NVMe/DRAM cache
```

Measure RGW request latency, gateway CPU/network, OSD latency, and GPU input
stall time together. Increasing client concurrency after a gateway or OSD is
saturated only increases queueing and tail latency.

### Checkpoints and model artifacts

Use multipart upload for large per-rank objects. A complete multipart upload
atomically publishes one key, but a checkpoint generation containing many keys
still needs a manifest protocol:

```text
checkpoints/run-42/step-1042/rank-0000.bin
checkpoints/run-42/step-1042/rank-0001.bin
...
checkpoints/run-42/step-1042/manifest.json
checkpoints/run-42/step-1042/COMMITTED
```

The coordinator writes `COMMITTED` only after verifying every expected
object's size, checksum, and version/ETag. Readers never discover a generation
by assuming that a partial prefix listing is complete.

### CephFS or RGW?

| Workload | CephFS | RGW/S3 |
|----------|--------|--------|
| Existing POSIX application | Natural fit | Requires an object-aware adapter |
| Immutable dataset shards | Good | Excellent |
| Fine-grained random file writes | Better semantic fit | Poor fit for in-place mutation |
| Cross-language and cloud tooling | Mount/client dependent | Broad S3 ecosystem |
| Atomic rename of one file | Yes | No rename; publish a new key/marker |
| Lifecycle and object versioning | Filesystem/snapshot workflow | Native S3-style APIs |
| WAN or multisite distribution | Snapshot mirroring | RGW multisite |

---

## 6. Consistency, Versioning, and Disaster Recovery

### Local-zone consistency

RGW provides read-after-write consistency for object operations in a zone.
This is single-object consistency, not a transaction spanning many keys.
Applications must use manifests, generation IDs, or markers when a logical
dataset consists of multiple objects.

### Versioning and retention

- Bucket versioning preserves distinct versions when a key is overwritten or
  deleted.
- Lifecycle rules can expire old versions, incomplete multipart uploads, or
  transition objects to another storage class.
- Object Lock can enforce retention where supported and correctly configured.

Versioning is not free backup: accidental bulk writes, lifecycle errors,
credential compromise, and capacity exhaustion still require independently
tested recovery controls.

### Multisite

RGW multisite organizes configuration into realms, zonegroups, and zones.
Data and metadata changes propagate asynchronously between zones. Remote zones
are therefore eventually consistent with the source and can lag during
network, gateway, or cluster failures.

```text
successful PUT in zone A
        |
        +--> immediately readable according to zone A's local consistency
        |
        `--> async replication log --> zone B
                                      remote visibility occurs later
```

Design failover around measured replication lag and conflict policy. Multisite
does not provide a zero-RPO synchronous write across distant clusters.

---

## 7. Security and Tenant Boundaries

- Terminate TLS at RGW or a trusted load balancer; do not expose access keys on
  plaintext networks.
- Prefer short-lived or scoped credentials and bucket policies over sharing
  administrator keys with training jobs.
- Separate teams by users, tenants, buckets, and policies according to the
  required isolation level.
- Treat presigned URLs as bearer credentials until they expire.
- Validate encryption-at-rest and key-management behavior for both object data
  and all replicas or remote zones.
- Rate-limit or isolate bulk training traffic so it cannot starve control-plane
  or artifact-publication requests.

---

## 8. Operations and Failure Diagnosis

```bash
# Cluster and backing-pool health
ceph health detail
ceph df detail
ceph pg stat

# Bucket layout, object count, usage, and placement
radosgw-admin bucket stats --bucket=<bucket>

# Dynamic resharding state
radosgw-admin reshard status --bucket=<bucket>
radosgw-admin reshard list

# Multisite replication state
radosgw-admin sync status

# User accounting
radosgw-admin user stats --uid=<user>
```

Monitor at least:

- GET/PUT request rate, bytes, latency, and error codes;
- RGW CPU, memory, network, connection counts, and queues;
- bucket-index shard utilization and resharding;
- incomplete multipart upload growth;
- multisite metadata/data sync lag and errors;
- OSD commit/apply latency, degraded PGs, recovery, and fullness;
- application retry rate and GPU input starvation.

| Symptom | Likely layer | First checks |
|---------|--------------|--------------|
| High HTTP latency but OSDs are idle | RGW/frontend | CPU, TLS, connections, load balancing |
| PUT latency rises for one large bucket | Bucket index | shard count, resharding, hot keys |
| GET throughput is low across all gateways | OSD/network/data layout | PG distribution, EC/degraded reads, network |
| LIST is slow but direct GET is fast | Bucket index | index shard count and listing fan-out |
| Remote zone returns stale/missing key | Multisite sync | sync status, lag, failed shards |
| Storage grows after failed jobs | Multipart/versioning | incomplete uploads, old versions, lifecycle |
| Retries amplify an incident | Client behavior | timeouts, exponential backoff, concurrency limits |

---

## 9. Production Checklist

- Put RGW instances behind health-checked load balancing.
- Keep bucket-index and control metadata on low-latency protected storage.
- Choose replicated versus EC data pools from object sizes and recovery goals.
- Define bucket ownership, lifecycle, versioning, and retention before ingest.
- Use large immutable dataset shards and avoid LIST in the training hot path.
- Use multipart upload plus manifest/checksum/final-marker publication.
- Bound client retries and concurrency to prevent retry storms.
- Test gateway loss, OSD degradation, resharding, and multisite lag.
- Maintain headroom for recovery and old checkpoint generations.
- Benchmark end-to-end GPU delivery, not just isolated S3 throughput.

## References

- [Ceph Object Gateway S3 API](https://docs.ceph.com/en/latest/radosgw/s3/)
- [RGW bucket index and consistency](https://docs.ceph.com/en/latest/dev/radosgw/bucket_index/)
- [RGW data layout](https://docs.ceph.com/en/latest/radosgw/layout/)
- [RGW pool placement and storage classes](https://docs.ceph.com/en/latest/radosgw/placement/)
- [RGW dynamic bucket-index resharding](https://docs.ceph.com/en/latest/radosgw/dynamicresharding/)
- [RGW multisite](https://docs.ceph.com/en/latest/radosgw/multisite/)
- [RGW metrics](https://docs.ceph.com/en/latest/radosgw/metrics/)
- [Ceph erasure coding](https://docs.ceph.com/en/latest/architecture/erasure-coding/)
