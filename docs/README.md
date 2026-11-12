# Storage Study

Learn storage systems from one machine to distributed clusters and AI workloads.
The layers describe **where a problem lives**, not a strict calendar: choose a
track, then follow its own reading order.

| Layer | Start here | What you will learn |
|---|---|---|
| L1 · Single node | [Explore L1](L1-single-node/README.md) | Kernel I/O, Device Mapper, filesystems, memory, networking, SCSI, and SPDK |
| L2 · Distributed | [Explore L2](L2-distributed/README.md) | Consensus, placement, protocols, replication, object storage, Ceph, DRBD, and DAOS |
| L3 · Workloads and operations | [AI storage](L3-ai-storage/README.md) · [Cluster operations](L3-cluster-scheduling/README.md) | Training and inference data paths; scheduling and operating a storage fleet |

## Follow a component across layers

| Component | Start | Then study |
|---|---|---|
| SPDK | [L1 SPDK study index](L1-single-node/spdk/study-index.md) | [NVMe-oF and storage protocols](L2-distributed/protocols/m2-day15-21-storage-protocols.md); [SPDK reference](reference/spdk.md) |
| DRBD | [L2 DRBD guide](reference/drbd.md) | [Consensus and failure models](L2-distributed/consensus/m2-day01-distributed-concepts.md) to understand the different coordination problems |
| DAOS | [L2 DAOS architecture](L2-distributed/systems/daos-architect-reference.md) | [L3 AI storage](L3-ai-storage/README.md) for workload patterns that use distributed storage |
| Ceph | [L2 Ceph/RADOS](L2-distributed/systems/m2-day22-30-object-storage-review.md) | [CephFS](reference/cephfs.md), [RGW/S3](reference/ceph-object-storage.md), and [cluster operations](L3-cluster-scheduling/README.md) |

SPDK primarily explains a **single-node user-space I/O engine**. DRBD explains
**replicated block devices across nodes**. DAOS is a **distributed storage
system** whose servers use local technologies such as SPDK. These are related
building blocks, not three competing versions of the same layer.

## Choose a route

- New to the stack: [L1 kernel I/O](L1-single-node/kernel-io/day01-storage-stack-gap-fill.md)
  → [L2 distributed concepts](L2-distributed/consensus/m2-day01-distributed-concepts.md)
  → [L3 AI storage](L3-ai-storage/README.md) or [cluster operations](L3-cluster-scheduling/README.md).
- Interested in snapshots: [Device Mapper and dm-thin](L1-single-node/device-mapper/README.md)
  → [distributed replication with DRBD](reference/drbd.md).
- Interested in object and AI storage: [object storage](L2-distributed/object-storage/README.md)
  → [Ceph services](reference/ceph.md) or [DAOS](L2-distributed/systems/daos-architect-reference.md)
  → [AI data paths](L3-ai-storage/README.md).

Use the site search (press **S**) for a particular term. The
[architecture notes](architecture/all-flash-architecture.md) and
[topic indexes](categories/devices.md) are reference material you can consult
at any point.
