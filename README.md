# Storage Study Knowledge Base

Curated summaries and references for Linux storage stack and distributed storage technologies.

**Browse the documentation:** <https://chenfantony.github.io/storage-study/>

The site is built from the Markdown files in `docs/`. To preview it locally:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements-docs.txt
.venv/bin/mkdocs serve
```

## Scope
- Linux kernel storage stack (block layer, device mapper, filesystem internals, io_uring)
- Distributed storage (Ceph, DRBD, DAOS)
- Broader ecosystem (NVMe-oF, SPDK, ext4/xfs/btrfs/bcachefs/zfs/juicefs)
- Tooling ecosystem (fio, blktrace, bpftrace, etc.)

## Learning Layers

- [L1 — Single-node internals](docs/L1-single-node/kernel-io/day01-storage-stack-gap-fill.md)
  - [Kernel I/O](docs/L1-single-node/kernel-io/day01-storage-stack-gap-fill.md)
  - [Filesystems](docs/L1-single-node/filesystems/filesystem-comparison-ext4-xfs-btrfs.md)
  - [Memory](docs/L1-single-node/memory/day01-physical-memory-model.md)
  - [Networking](docs/L1-single-node/network/day01_network_overview.md)
  - [SCSI](docs/L1-single-node/scsi/day01.md)
  - [Storage tiering](docs/L1-single-node/storage-tiering/day08-bcache-gc-ssd-wear.md)
- [L2 — Distributed storage](docs/L2-distributed/consensus/m2-day01-distributed-concepts.md)
  - [Consensus](docs/L2-distributed/consensus/m2-day01-distributed-concepts.md)
  - [Data placement and erasure coding](docs/L2-distributed/data-placement/m2-day08-14-erasure-placement.md)
  - [Merkle trees and replica repair](docs/L2-distributed/data-placement/merkle-trees.md)
  - [Storage protocols and NVMe-oF](docs/L2-distributed/protocols/m2-day15-21-storage-protocols.md)
  - [Ceph and object storage](docs/L2-distributed/systems/m2-day22-30-object-storage-review.md)
    - [Ceph service reference](docs/reference/ceph.md)
    - [CephFS for AI storage](docs/reference/cephfs.md)
    - [Ceph Object Storage (RGW/S3)](docs/reference/ceph-object-storage.md)
  - [DAOS](docs/L2-distributed/systems/daos-architect-reference.md)
- [L3 — AI storage](docs/L3-ai-storage/README.md)
- [L3 — Cluster scheduling](docs/L3-cluster-scheduling/README.md)
- [Architecture and design patterns](docs/architecture/all-flash-architecture.md)
  - [Cache design](docs/architecture/cache-design/cache-design-patterns.md)
  - [I/O latency and SPDK](docs/architecture/io-latency-cost-model.md)

## Curated Topic Indexes

- [SPDK](docs/categories/spdk.md)
- [Devices](docs/categories/devices.md)
- [Filesystems](docs/categories/filesystems.md)

## Curation Criteria
- Prefer primary sources (specs, official docs, maintainer posts, upstream repos).
- Avoid marketing-only links.
- Each entry must include at least one authoritative source.

## Maintenance
- Review entries quarterly for staleness.
- Mark deprecated or superseded items with a brief status note.

## Update Cadence
- Publish monthly updates by the 5th of the following month.
- Publish weekly category updates every Tuesday when relevant.
- If there are no significant updates, publish a brief note.

## Latest Updates
- [Monthly: 2026-03](docs/_meta/updates/2026-03.md)
- [Weekly: 2026-W14](docs/updates/2026-W14.md)
