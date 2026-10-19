# Device Mapper — Ten-Day Learning Path

Device Mapper is the Linux kernel framework behind LVM logical volumes,
dm-thin, dm-cache, dm-crypt, multipath, integrity, and verity. This track starts
with mapping tables and then concentrates on thin pools and snapshots.

## Learning path

| Day | Topic | Outcome |
|-----|-------|---------|
| [1](day01-core-and-io-path.md) | Core and I/O path | Explain mapped devices, tables, targets, bio splitting, and stacking |
| [2](day02-tables-targets-and-lifecycle.md) | Tables and lifecycle | Build, inspect, reload, suspend, resume, and remove safe test mappings |
| [3](day03-classic-vs-thin-snapshots.md) | Snapshot models | Distinguish classic dm-snapshot exception stores from dm-thin shared mappings |
| [4](day04-thin-pool-architecture.md) | Thin-pool architecture | Explain data/metadata devices, mappings, space maps, transaction IDs, and chunks |
| [5](day05-thin-snapshot-cow.md) | Thin snapshot CoW | Follow snapshot creation and first-write allocation for origin and snapshot |
| [6](day06-lvm-thin-snapshot-lab.md) | LVM lab | Create, snapshot, diverge, inspect, and remove thin LVs safely |
| [7](day07-capacity-discard-and-enospc.md) | Capacity and ENOSPC | Handle Data%, Meta%, discard, autoextension, queueing, and errors |
| [8](day08-monitoring-and-performance.md) | Monitoring and performance | Interpret status, events, latency, fragmentation, and snapshot workload costs |
| [9](day09-metadata-check-repair-and-recovery.md) | Metadata recovery | Use metadata snapshots, thin_check, thin_dump, thin_repair, and LVM repair |
| [10](day10-failure-lab-and-production-checklist.md) | Failure lab | Validate snapshot consistency, exhaustion behavior, recovery, and production controls |

## Prerequisites and safety

Complete the block-layer basics first. Labs require root and modify block-device
metadata, so use loop devices or disposable virtual disks only. Verify every
device path with `lsblk` before destructive commands.

Thin provisioning is overcommit:

```text
sum of virtual thin-LV sizes may exceed physical pool data space
```

It is safe only when data and metadata usage are continuously monitored and
the pool can extend before either reaches 100%.

## Related material

- [Existing dm-thin metadata lesson](../storage-tiering/day12-dm-thin-metadata.md)
- [dm-cache architecture](../storage-tiering/day11-dm-cache-architecture.md)
- [dm-crypt](../storage-tiering/day15-dm-crypt.md)
- [Device-mapper and multipath](../scsi/day14.md)
- [Reliability and dm-flakey](../../architecture/reliability/m3r-week3-reliability.md)

---

## Start

[Day 1 — Device Mapper core: mapped devices, tables, targets, and the bio path →](day01-core-and-io-path.md)
