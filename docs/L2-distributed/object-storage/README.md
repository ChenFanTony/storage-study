# Object Storage — Ten-Day Learning Path

This track develops object storage from the API contract down to metadata,
durability, operations, and AI workload design. Read it after the distributed
concepts and data-placement material.

The emphasis is not memorizing one vendor. The goal is to recognize which
guarantees belong to the S3 API, which belong to a particular implementation,
and which must be supplied by the application.

## Learning path

| Day | Topic | What you should be able to explain |
|-----|-------|------------------------------------|
| [1](day01-object-model-and-s3-api.md) | Object model and S3 API | Buckets, keys, prefixes, versions, metadata, and why an object is not a file |
| [2](day02-requests-consistency-and-concurrency.md) | Requests, consistency, and concurrency | SigV4, single-key atomicity, conditional writes, retries, and idempotency |
| [3](day03-multipart-versioning-lifecycle-lock.md) | Multipart, versioning, lifecycle, and Object Lock | Publication, delete markers, retention, and cleanup |
| [4](day04-metadata-indexes-and-small-objects.md) | Metadata and small objects | Bucket indexes, sharding, LIST fan-out, hotspots, and metadata amplification |
| [5](day05-durability-placement-and-repair.md) | Durability and repair | Replication, erasure coding, failure domains, scrub, healing, and rebuild risk |
| [6](day06-security-tenancy-and-encryption.md) | Security and tenancy | IAM, bucket policy, TLS, encryption, presigned URLs, quotas, and audit |
| [7](day07-ceph-minio-seaweedfs.md) | System architectures | How Ceph RGW, MinIO, and SeaweedFS implement different tradeoffs |
| [8](day08-multisite-replication-and-dr.md) | Multisite and disaster recovery | Replication lag, RPO/RTO, failover, conflict handling, and recovery testing |
| [9](day09-observability-benchmarking-capacity.md) | Operations and performance | Metrics, workload design, tail latency, capacity, and failure diagnosis |
| [10](day10-ai-data-and-checkpoint-patterns.md) | AI data and checkpoints | Sharding, range reads, caching, manifests, and atomic generation publication |

## How to use the track

For each day:

1. Read the mental model and request/data path.
2. Run the lab against a disposable S3-compatible endpoint.
3. Answer the self-check without reopening the page.
4. Record which behavior is an API guarantee and which is implementation-specific.

Commands use these placeholders:

```bash
export S3_ENDPOINT=http://127.0.0.1:9000
export LAB_BUCKET=object-study
export AWS_ACCESS_KEY_ID=lab-access-key
export AWS_SECRET_ACCESS_KEY=lab-secret-key
export AWS_DEFAULT_REGION=us-east-1
```

Use a dedicated test bucket. Versioning, lifecycle, retention, and destructive
failure labs should never be tried first on production data.

## Related material

- [S3 API and consistency overview](../protocols/m2-day15-21-storage-protocols.md#day-20-object-storage--s3-api--consistency-model)
- [Ceph RADOS, BlueStore, MinIO, and SeaweedFS review](../systems/m2-day22-30-object-storage-review.md)
- [Ceph Object Gateway reference](../../reference/ceph-object-storage.md)
- [Erasure coding and placement](../data-placement/m2-day08-14-erasure-placement.md)
- [AI training data pipelines](../../L3-ai-storage/training-data-reference.md)

---

## Start

[Day 1 — Object model and S3 API: buckets, keys, prefixes, versions, and metadata →](day01-object-model-and-s3-api.md)
