# Ceph — Reference Index

Ceph provides object, block, and file interfaces over one distributed object
store: RADOS. The interfaces share OSDs, CRUSH placement, replication or
erasure coding, failure recovery, and cluster health, but they expose different
application contracts.

## Service Map

```text
Applications
    |
    +-- POSIX files/directories --------> CephFS clients
    |                                      |
    |                                      +--> MDS: namespace and capabilities
    |                                      `--> OSDs: file data as RADOS objects
    |
    +-- S3/Swift HTTP APIs -------------> RADOS Gateway (RGW)
    |                                      |
    |                                      `--> metadata, indexes, and data in RADOS
    |
    +-- virtual block devices ----------> RBD/librbd
    |                                      |
    |                                      `--> image extents as RADOS objects
    |
    `-- native object operations ------> librados
                                           |
                                           `--> RADOS pools and placement groups
```

| Interface | Contract | Best fit |
|-----------|----------|----------|
| RADOS | Native object API | Ceph-native services and specialized applications |
| RBD | Block device | VM disks, databases, and Kubernetes volumes |
| [CephFS](cephfs.md) | Shared POSIX filesystem | Shared datasets, checkpoints, source trees, and tools expecting paths |
| [Ceph Object Storage](ceph-object-storage.md) | S3/Swift object API through RGW | Data lakes, immutable dataset shards, model artifacts, and cross-platform access |

For the common storage substrate, read
[Day 22: Ceph RADOS Deep Dive](../L2-distributed/systems/m2-day22-30-object-storage-review.md).

## Ceph for AI Workloads

AI systems often use both CephFS and RGW rather than choosing one globally:

```text
                    control and publication
dataset producer ------------------------------+
       |                                       |
       | PUT immutable shards                  | write checkpoint files
       v                                       v
RGW/S3 data lake                         CephFS shared namespace
       |                                       |
       | parallel GET/range GET                | POSIX open/read/mmap
       v                                       v
training workers -----> local NVMe/DRAM cache <---- training workers
```

| Requirement | Prefer | Reason |
|-------------|--------|--------|
| Existing application requires POSIX paths | CephFS | Mountable shared namespace with directories, permissions, and rename |
| Large immutable WebDataset/Parquet shards | RGW/S3 | HTTP object access, multipart upload, lifecycle, and horizontal gateways |
| Thousands of tiny files with heavy directory scans | Neither by default | Pack samples into shards first; otherwise metadata/request overhead dominates |
| Per-rank checkpoint files followed by atomic publication | CephFS | Files plus a manifest and final atomic rename fit POSIX workflows |
| One checkpoint object or artifact bundle | RGW/S3 | Multipart upload followed by a final manifest or committed marker |
| VM or database volume | RBD | Block semantics rather than file or object semantics |
| Remote-site distribution | RGW multisite or CephFS snapshot mirroring | Both replicate asynchronously; design for non-zero recovery point |

### Checkpoint publication is an application protocol

Neither a filesystem nor an object store automatically makes a collection of
rank files atomic. A distributed training job should publish a checkpoint only
after every rank has completed and validated its part:

```text
1. Each rank writes checkpoint/<generation>/rank-<n>.tmp
2. Each rank flushes and reports its checksum
3. Coordinator verifies all expected ranks
4. Coordinator writes the manifest
5. Coordinator publishes one final marker:
     CephFS: rename manifest.tmp -> manifest.complete
     RGW:    PUT manifest.complete or COMMITTED
6. Readers ignore generations without the final marker
```

The marker makes discovery atomic; it does not replace flushing file data,
completing multipart uploads, validating checksums, or retaining older
generations for rollback.

## Shared Design Rules

- Separate CephFS metadata, CephFS data, RGW index, and RGW data into
  purpose-appropriate pools and CRUSH rules.
- Keep metadata and bucket-index workloads on low-latency replicated storage;
  use erasure coding primarily for capacity-heavy data where its read-modify
  and recovery costs are acceptable.
- Size the network for client traffic **and** recovery/backfill traffic.
- Treat degraded placement groups, near-full OSDs, and slow OSD operations as
  application latency risks even when the client-facing service is healthy.
- Benchmark the real object/file size distribution and concurrency. Aggregate
  bandwidth numbers alone do not predict metadata or tail-latency behavior.
- Put a node-local NVMe/DRAM cache in front of shared storage when epochs reuse
  immutable training shards.

## References

- [Ceph architecture](https://docs.ceph.com/en/latest/architecture/)
- [Ceph clients and service interfaces](https://docs.ceph.com/en/latest/architecture/ceph-clients/)
- [Ceph erasure coding](https://docs.ceph.com/en/latest/architecture/erasure-coding/)
