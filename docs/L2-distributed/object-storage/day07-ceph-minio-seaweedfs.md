# Day 7: Ceph RGW, MinIO, and SeaweedFS

## Learning objectives

- Trace the major request path in three object-storage architectures.
- Identify where metadata, payload, and placement state live.
- Compare placement groups, erasure sets, and volume-based lookup.
- Choose by workload and operational model rather than API compatibility alone.

## 1. Same API, different internals

S3 compatibility describes a request surface, not one architecture. Three
systems can accept similar PUT and GET requests while using very different
metadata, placement, and repair mechanisms.

## 2. Ceph Object Gateway

```text
S3 client -> load balancer -> RGW
                            |
                            +-> bucket index objects in RADOS
                            `-> head/tail data objects in RADOS
                                      |
                                      `-> PG -> CRUSH -> OSD set
```

RGW gateways are largely request-serving frontends; durable state lives in
RADOS. A logical S3 object may use a head object containing metadata and a
manifest plus tail objects containing additional data. Bucket indexes use
RADOS object-map entries and can be sharded.

Strengths include integration with Ceph placement, replicated or
erasure-coded pools, mature failure-domain controls, and sharing one RADOS
cluster with other Ceph services. The cost is a broad operational surface:
monitors, managers, OSDs, placement groups, pools, RGWs, resharding, and
possibly multisite synchronization.

Continue with the [Ceph RGW architect reference](../../reference/ceph-object-storage.md).

## 3. MinIO

```text
S3 client -> MinIO server set
                |
                +-> select erasure set
                +-> encode data/parity shards
                +-> write object metadata and shards
                `-> require write quorum
```

MinIO organizes drives into erasure sets. An object is placed within one set;
it is not striped across every drive in the deployment. Erasure geometry,
quorum, healing, and free-space balance within sets shape failure behavior.

The architecture is direct and S3-focused. It fits teams wanting a dedicated
object store without the full Ceph service family. Operators must still model
drive/server failure correlation, healing bandwidth, metadata behavior,
upgrade compatibility, and capacity imbalance across pools and sets.

## 4. SeaweedFS

```text
client -> S3 gateway -> filer -> metadata database
                              |
                              `-> chunk/file IDs
master: volume ID -> volume-server locations
volume servers: append payloads to volume files
```

SeaweedFS masters track volumes rather than every object payload. Volume
servers store blobs, while the filer provides directory-like metadata and the
S3 gateway maps buckets/objects onto that layer. After locating a volume,
content I/O goes to volume servers; masters are not the bulk data path.

This design targets many files/objects and simple horizontal growth. It adds an
explicit filer-metadata database and volume maintenance model. Replication,
erasure coding, vacuum, balancing, and repair must be understood at the volume
layer.

## 5. Comparison

| Question | Ceph RGW | MinIO | SeaweedFS |
|----------|----------|-------|-----------|
| Durable data substrate | RADOS objects on OSDs | Object shards in erasure sets | Blobs in volume files |
| Key metadata/index | RGW metadata and bucket-index pools | Per-object metadata with set-local layout | Filer metadata database |
| Placement abstraction | PG plus CRUSH rule | Erasure set | Volume ID and topology |
| Gateway model | RGW instances | MinIO servers serve API and storage roles | Stateless S3 gateway over filer |
| Small-object strategy | Tune RGW/RADOS layout and index | Request/object overhead remains important | Volume/needle design targets many small files |
| Operational scope | Broad distributed storage platform | Dedicated S3-centric system | Blob, file, and S3 layers |
| Best reason to choose | Existing Ceph and flexible pool/failure policy | Focused S3 deployment | Huge object/file counts and volume-based scaling |

This is a reasoning guide, not a benchmark result. Validate current feature
compatibility and failure semantics against the release you deploy.

## 6. Lab: draw the real path

For one PUT on each system you can access, record:

1. frontend process receiving the HTTP request;
2. authentication and policy component;
3. metadata/index update;
4. physical payload placement unit;
5. durability quorum;
6. success-response point;
7. repair owner after one drive fails;
8. metrics that expose each step.

If a step is unknown, locate it in official docs or source before tuning the
system. "S3-compatible" is not an answer to any of these implementation
questions.

## Failure patterns

- Assuming all S3 implementations have Amazon S3 consistency semantics.
- Treating a Ceph PG, MinIO erasure set, and SeaweedFS volume as equivalents.
- Scaling stateless gateways while the metadata or storage tier is saturated.
- Counting nominal drive failures without mapping server and rack correlation.
- Choosing from peak throughput while ignoring repair and upgrade operations.

## Self-check

1. Where does Ceph RGW durable state live?
2. Why does MinIO erasure-set balance matter?
3. What state do SeaweedFS masters track?
4. Which component is likely to limit LIST in each architecture?

## References

- [Ceph Object Gateway](https://docs.ceph.com/en/latest/radosgw/)
- [Ceph RGW data layout](https://docs.ceph.com/en/latest/radosgw/layout/)
- [MinIO repository and architecture entry points](https://github.com/minio/minio)
- [MinIO erasure coding](https://docs.min.io/aistor/operations/core-concepts/erasure-coding/)
- [SeaweedFS architecture and components](https://github.com/seaweedfs/seaweedfs/blob/master/README.md)
- [SeaweedFS REST API](https://github.com/seaweedfs/seaweedfs/blob/master/REST_API.md)

---

## Previous / Next

[← Previous: Day 6 — Security and tenancy: IAM, policies, encryption, quotas, and audit](day06-security-tenancy-and-encryption.md) | [Object-storage study index](README.md) | [Next: Day 8 — Multisite and disaster recovery: lag, RPO/RTO, failover, and conflicts →](day08-multisite-replication-and-dr.md)
