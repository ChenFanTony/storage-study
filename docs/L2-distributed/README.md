# L2 · Distributed Storage

Study what changes when data and coordination cross machine boundaries. The
first group covers reusable mechanisms; the second shows systems that combine
them. [L1 · Single-Node Storage](../L1-single-node/README.md) provides the
local I/O background.

## Mechanisms

| Read next | Main question |
|---|---|
| [Distributed concepts and consensus](consensus/m2-day01-distributed-concepts.md) | How do nodes agree on state and survive failures? |
| [Placement, erasure coding, and repair](data-placement/m2-day08-14-erasure-placement.md) | Where are copies or shards stored, and how are they recovered? See also [Merkle trees](data-placement/merkle-trees.md). |
| [Storage protocols](protocols/m2-day15-21-storage-protocols.md) | How do clients access block and file storage over a network? |
| [Object storage 10-day study](object-storage/README.md) | What do S3 APIs, consistency, indexing, durability, and operations require? |

## Systems and interfaces

| System | Study entry point | Connect it to |
|---|---|---|
| Ceph | [RADOS and object-storage systems](systems/m2-day22-30-object-storage-review.md) | [Ceph service map](../reference/ceph.md), [CephFS](../reference/cephfs.md), [RGW/S3](../reference/ceph-object-storage.md) |
| DRBD | [DRBD replicated block-device guide](../reference/drbd.md) | Replication, write acknowledgements, quorum, and failover |
| DAOS | [DAOS architecture deep reference](systems/daos-architect-reference.md) | Distributed objects, placement, transactions, and an [SPDK](../L1-single-node/spdk/study-index.md) based local data path |

DRBD replicates a block device; it does not expose an S3 object API. DAOS
offers distributed object and file access; SPDK is one of the local I/O
technologies used beneath it. For workload and fleet concerns, continue with
[L3 · AI Storage](../L3-ai-storage/README.md) or
[L3 · Cluster Operations](../L3-cluster-scheduling/README.md).
