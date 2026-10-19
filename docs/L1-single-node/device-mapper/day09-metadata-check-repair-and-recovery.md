# Day 9: Metadata Check, Repair, and Recovery

## Learning objectives

- Distinguish live metadata inspection from offline checking.
- Reserve and release a consistent metadata root.
- Use thin_check, thin_dump, thin_restore, and thin_repair safely.
- Build a recovery sequence that also validates upper layers.

## 1. Protect the evidence

When a pool reports `needs_check`, `ro`, or `Fail`:

1. stop new application writes;
2. capture `lvs`, `dmsetup status`, kernel logs, and device health;
3. preserve the original metadata device or an image;
4. identify the last known-good metadata backup;
5. avoid experimental in-place writes.

Payload data is not useful without correct mappings. Treat `_tmeta` as critical
recovery state.

## 2. Offline check

The safest full check uses inactive metadata:

```bash
umount all-thin-filesystems
lvchange -an vg/pool
thin_check /dev/vg/pool_tmeta
```

LVM hides component LVs and may expose them under mapper names only in specific
activation modes. Follow the installed LVM recovery procedure instead of
guessing paths.

`thin_check` validates metadata structures and reports affected mappings. It
does not validate filesystem contents inside thin LVs.

## 3. Inspect live metadata safely

Do not run an ordinary dump against metadata while the kernel mutates it.
Reserve a stable metadata root:

```bash
dmsetup message vg-pool-tpool 0 reserve_metadata_snap
dmsetup status vg-pool-tpool
thin_dump -m /dev/mapper/vg-pool_tmeta > /secure/path/pool-metadata.xml
dmsetup message vg-pool-tpool 0 release_metadata_snap
```

`-m` tells the tool to use the held metadata root. Confirm exact device names
and tool syntax for the installed version. Always release the held root; it
pins metadata state.

This metadata snapshot is not a thin-LV data snapshot and not a complete
backup of payload.

## 4. Repair to a different device

The thin-provisioning-tools workflow is non-destructive:

```bash
thin_repair -i broken-metadata-device -o new-empty-metadata-device
thin_check new-empty-metadata-device
thin_dump new-empty-metadata-device > repaired.xml
```

Never choose the same input and output device. Preserve the original for
forensics and alternate recovery attempts.

LVM offers:

```bash
lvconvert --repair vg/pool
```

It may use the pool's metadata spare and thin-provisioning tools. Read the
command plan and logs, verify the resulting pool, and retain the old metadata
LV until recovery is validated.

## 5. Restore and validate

After metadata repair:

1. activate the pool read-only if the workflow permits;
2. verify thin devices and mappings expected by inventory;
3. run filesystem checks according to each filesystem's offline rules;
4. mount recovery copies read-only;
5. validate application checksums or database recovery;
6. copy critical data to independent storage;
7. restore normal writes only after evidence is clean.

The kernel documentation warns that metadata exhaustion can abort a
transaction around I/O already acknowledged to upper layers. A successful
`thin_check` therefore does not prove filesystem or application consistency.

## 6. Backups and metadata spare

Plan for:

- mirrored/redundant metadata storage where appropriate;
- LVM pool metadata spare;
- periodic metadata dumps or backups coordinated safely;
- exact VG/LV/device-ID inventory;
- independent payload backup;
- tested tool versions in rescue media;
- recovery time proportional to metadata size.

A metadata dump plus no payload data cannot recreate the pool. Payload backup
without mappings may also be unusable.

## Lab: rehearse without corruption

On a disposable clean pool:

1. create thin LVs and a snapshot;
2. reserve a live metadata snapshot;
3. run `thin_dump -m`;
4. release it;
5. deactivate all thin LVs and the pool;
6. run `thin_check`;
7. restore the XML into a new empty lab metadata device;
8. run `thin_check` on the result;
9. compare device IDs and mapping counts.

Do not introduce arbitrary bit flips; a corruption lab needs a preserved image
and a known expected failure.

## Failure patterns

- Running repair against active metadata.
- Repairing in place and destroying the only evidence.
- Forgetting to release a reserved metadata root.
- Treating a metadata-only backup as a data backup.
- Activating read-write before filesystem checks.
- Assuming `thin_check` validates database semantics.
- Discovering rescue media lacks compatible thin tools during an outage.

## Self-check

1. Why must normal metadata checking be offline?
2. What does `reserve_metadata_snap` preserve?
3. Why does `thin_repair` need a different output device?
4. What must be checked after pool metadata is repaired?

## References

- [thin-provisioning-tools](https://github.com/jthornber/thin-provisioning-tools)
- [Kernel dm-thin metadata snapshots and status](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/thin-provisioning.html)
- [LVM thin-pool metadata repair](https://man7.org/linux/man-pages/man7/lvmthin.7.html)

---

## Previous / Next

[← Previous: Day 8 — Monitoring and performance: status, events, fragmentation, and snapshot workload cost](day08-monitoring-and-performance.md) | [Device Mapper study index](README.md) | [Next: Day 10 — Failure lab and production checklist: prove snapshot, exhaustion, and recovery behavior →](day10-failure-lab-and-production-checklist.md)
