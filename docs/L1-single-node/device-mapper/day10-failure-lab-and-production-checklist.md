# Day 10: Failure Lab and Production Checklist

## Learning objectives

- Validate snapshot consistency and recovery with controlled failures.
- Observe data-space exhaustion without risking real storage.
- Turn findings into alerts and runbooks.
- Review a production thin-pool design end to end.

## 1. Lab controls

Use a disposable VM and loop-backed VG. Before each experiment:

```text
define expected result
record exact devices and mounts
save dm/LVM status
set a time and capacity abort limit
keep a cleanup shell open
never include host or production disks
```

Use separate runs for data exhaustion, metadata tooling, and snapshot
consistency so one failure does not contaminate every observation.

## 2. Experiment A: snapshot consistency

1. create a thin LV and filesystem;
2. run a writer that updates a sequence and checksum;
3. take one snapshot without application coordination;
4. take another using application flush plus filesystem freeze;
5. mount copies read-only;
6. run filesystem recovery/checks and validate sequence/checksum invariants;
7. document the difference between mountable and application-consistent.

A snapshot appearing mountable is not enough evidence for database recovery.

## 3. Experiment B: data-space exhaustion

Create a deliberately small pool and larger thin LV. Select and record the
no-space policy, then write unique data while watching:

```bash
watch -n1 'lvs -o name,data_percent,metadata_percent,seg_monitor dmstudy'
dmsetup status dmstudy-pool-tpool
dmesg --follow
```

Stop at the planned threshold unless the lab explicitly intends to reach
exhaustion. If testing exhaustion:

- record whether I/O queues or errors;
- measure application and filesystem reaction;
- extend the pool from reserved VG extents;
- verify whether I/O resumes;
- check filesystem and payload checksums.

Never run this experiment on the pool containing the host root filesystem.

## 4. Experiment C: snapshot-pinned capacity

1. write a large file;
2. snapshot;
3. delete and trim the origin;
4. confirm the snapshot pins old chunks;
5. overwrite other origin regions;
6. remove the snapshot;
7. trim and observe reclaimed pool space.

This connects logical deletion, discard granularity, sharing, and physical
capacity.

## 5. Experiment D: metadata recovery rehearsal

Use a clean metadata image rather than corrupting the only copy:

1. reserve/dump live metadata;
2. deactivate and run `thin_check`;
3. restore into a new empty metadata device;
4. check the restored metadata;
5. activate a cloned lab stack read-only;
6. validate thin device inventory and filesystems;
7. measure total recovery time.

A production runbook is incomplete if it only says "run thin_repair."

## 6. Production checklist

### Design

- Data and metadata devices have explicit resilience and failure domains.
- Chunk size follows workload and snapshot measurements.
- Virtual overcommit has an owner and limit.
- Pool data, metadata, and VG reserve are capacity-planned.
- Snapshot retention and independent backup are separate policies.
- External origins, if used, are immutable and protected.

### Runtime

- `dmeventd` monitoring and autoextension are enabled and tested.
- Alerts cover Data%, Meta%, allocation rate, VG free extents, `needs_check`,
  target mode, and device errors.
- No-space behavior is selected and tested with applications/filesystems.
- Discard policy and periodic trim match the lower storage.
- Snapshot jobs have quiesce, timeout, and guaranteed-thaw handling.
- Metadata tools and rescue instructions match deployed versions.

### Recovery

- Metadata spare/backup and independent payload backup exist.
- Offline check/repair steps preserve original metadata.
- Filesystem and application validation follow pool repair.
- Snapshot restore and full backup restore are exercised regularly.
- Capacity is reserved for repair and emergency extension.

## 7. Final mental model

```text
Device Mapper maps bios through target tables.
dm-thin maps many virtual block devices into one physical pool.
A thin snapshot creates shared mappings, not copied payload.
Later writes allocate new chunks; old mappings remain for other devices.
Data and metadata exhaustion are pool-wide risks.
A block snapshot is only as consistent as the quiesce protocol above it.
Metadata repair restores mappings, then upper layers still need validation.
Snapshots share a failure domain; backup must not.
```

## Self-check

1. Which experiment proves snapshot consistency rather than creation success?
2. How do you distinguish snapshot-pinned data from failed discard?
3. What evidence permits returning a repaired pool to write service?
4. Which controls prevent autoextension from being a false safety net?

## References

- [Kernel Device Mapper documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/index.html)
- [Kernel dm-thin documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/thin-provisioning.html)
- [LVM thin provisioning manual](https://man7.org/linux/man-pages/man7/lvmthin.7.html)
- [thin-provisioning-tools](https://github.com/jthornber/thin-provisioning-tools)
- [Existing storage reliability labs](../../architecture/reliability/m3r-week3-reliability.md)

---

## Previous / Further Study

[← Previous: Day 9 — Metadata recovery: live metadata snapshots, checking, dumping, repair, and validation](day09-metadata-check-repair-and-recovery.md) | [Device Mapper study index](README.md) | [Continue: dm-cache architecture and policy plugins →](../storage-tiering/day11-dm-cache-architecture.md)
