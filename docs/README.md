# Storage Study — Learning Path

Structured curriculum from kernel I/O internals to cluster fleet operations.
Each layer builds on the previous. Study in order for the first pass; use as reference after.

---

## Layer Map

```
L1  Single-Node Internals      ← maximize one machine
L2  Distributed Systems        ← coordinate many machines
L3  Cluster Scheduling         ← operate the fleet
↕
Architecture/                  ← design patterns that span all layers
```

---

## L1 — Single-Node Internals

> Goal: understand every hop an I/O takes from syscall to device, and how to maximize throughput and minimize latency on a single machine.

| Directory | Content | Days |
|-----------|---------|------|
| [L1-single-node/kernel-io/](L1-single-node/kernel-io/day01-storage-stack-gap-fill.md) | blk-mq, io_uring, I/O schedulers, NVMe driver, NVMe-oF host, ZNS, pmem/DAX, cgroup I/O, performance tuning | 30 |
| [L1-single-node/storage-tiering/](L1-single-node/storage-tiering/day08-bcache-gc-ssd-wear.md) | bcache (GC, failure semantics, limits), dm-cache (SMQ), dm-thin (metadata, snapshots), dm-crypt, md/RAID | 9 |
| [L1-single-node/filesystems/](L1-single-node/filesystems/day17-xfs-internals-part1.md) | XFS (AG model, delayed alloc, reflink), ext4/JBD2 (crash recovery), Btrfs (CoW B-tree, send/receive) | 5 |
| [L1-single-node/memory/](L1-single-node/memory/day01-physical-memory-model.md) | Physical memory model, buddy/SLAB/SLUB, vmalloc, mmap, page faults/CoW, page cache, writeback, kswapd, OOM, THP, HugePages, NUMA, DAX | 30 |
| [L1-single-node/network/](L1-single-node/network/day01_network_overview.md) | Socket layer, NIC/NAPI, IP, TCP rx/tx, netfilter, epoll, zero-copy, multiqueue/RSS/RPS, eBPF/XDP, DPDK/AF_XDP, kTLS, sk_buff, bridges/VXLAN | 30 |
| [L1-single-node/scsi/](L1-single-node/scsi/day01.md) | SCSI subsystem: command lifecycle, error handling, multipath, transport layers | 30 |

---

## L2 — Distributed Systems

> Goal: understand how multiple machines coordinate — consensus, data placement, failure tolerance, and storage protocols.

| Directory | Content |
|-----------|---------|
| [L2-distributed/consensus/](L2-distributed/consensus/m2-day01-distributed-concepts.md) | Raft (leader election, log replication, snapshots, production failures), Paxos variants, ZAB (ZooKeeper) |
| [L2-distributed/data-placement/](L2-distributed/data-placement/m2-day08-14-erasure-placement.md) | Erasure coding (Reed-Solomon, LRC), consistent hashing, CRUSH, rebalancing |
| [L2-distributed/protocols/](L2-distributed/protocols/m2-day15-21-storage-protocols.md) | iSCSI, NFS v4/pNFS, SMB3 multichannel, Fibre Channel/FCoE, NVMe-oF fabric protocols |
| [L2-distributed/systems/](L2-distributed/systems/m2-day22-30-object-storage-review.md) | Ceph RADOS/BlueStore, MinIO erasure sets, SeaweedFS/Haystack, object storage at scale |

---

## L3 — Cluster Scheduling & Fleet Operations

> Goal: operate, schedule, and manage a storage cluster at fleet scale — QoS enforcement, data placement topology, rolling upgrades, geo-replication, Kubernetes integration.

| Directory | Content | Status |
|-----------|---------|--------|
| [L3-cluster-scheduling/](L3-cluster-scheduling/README.md) | Cluster I/O QoS (mClock), rack-aware placement, rebalancing, fleet upgrades, geo-replication, CSI/Kubernetes, capacity planning | **Planned** — see README |

---

## Architecture — Design Patterns (spans all layers)

> Evergreen reference docs. Not study notes — return to these when making design decisions.

| Directory | Content |
|-----------|---------|
| [architecture/cache-design/](architecture/cache-design/cache-design-patterns.md) | Admission, eviction (LRU/ARC/2Q/W-TinyLFU/SMQ), write policy, ghost entries, writeback scheduling, multi-tier design, penetration/pollution defense |
| [architecture/storage-engines/](architecture/storage-engines/m3r-week1-storage-engines.md) | B-tree internals, LSM-tree (MemTable/SSTable/compaction), amplification analysis |
| [architecture/data-reduction/](architecture/data-reduction/m3r-week2-data-reduction.md) | Dedup (inline vs post-process, chunking), compression (LZ4/Zstd), pipeline ordering |
| [architecture/reliability/](architecture/reliability/m3r-week3-reliability.md) | Chaos engineering, fault injection, gray failure detection, SLO design, runbooks |
| [architecture/m3r-week4-advanced-architecture.md](architecture/m3r-week4-advanced-architecture.md) | Tiered storage automation, AI/ML storage, multi-cloud cost modeling, capacity planning |

---

## Reference

Quick-lookup summaries for specific systems and tools.
[reference/](reference/kernel-storage.md) — Ceph, DAOS, DRBD, NVMe-oF, SPDK, filesystems, tools ecosystem

---

## Meta

Study plans, design specs, monthly updates — internal artifacts.
[_meta/](https://github.com/ChenFanTony/storage-study/tree/main/docs/_meta/) — plans/, specs/, updates/
