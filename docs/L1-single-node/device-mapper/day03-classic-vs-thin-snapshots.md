# Day 3: Classic dm-snapshot versus dm-thin Snapshots

## Learning objectives

- Explain both snapshot implementations without mixing their terminology.
- Follow origin and snapshot writes in each model.
- Understand different capacity and failure boundaries.
- Choose the correct operational commands and expectations.

## 1. Classic dm-snapshot

Classic snapshots use three targets: `snapshot-origin`, `snapshot`, and
`snapshot-merge`.

```text
origin data device <---------------- current origin blocks
       |
origin write to chunk X
       |
       +-> first copy old X into snapshot COW device
       `-> write new X to origin
```

The snapshot reads changed chunks from its COW exception store and unchanged
chunks from the origin. Snapshot writes go to COW storage. If the COW device
fills, the snapshot becomes invalid and returns errors; the origin remains a
separate full-sized device.

Classic snapshot merge copies changed chunks back into the origin through the
`snapshot-merge` target.

## 2. dm-thin snapshot

A thin pool owns one data device and one metadata device. Every thin LV,
including a snapshot, has a device ID and logical-to-physical mappings:

```text
before snapshot:
  origin logical 7 -> physical block P

after snapshot:
  origin logical 7 -> P
  snap   logical 7 -> P
```

No old block is copied at snapshot creation. Metadata records sharing. On the
first later write to logical block 7, the writing thin device receives a new
physical block; the other mapping continues to reference P.

A thin snapshot is itself an independent thin LV after creation. It can be
writable, activated without its origin, deleted independently, and used as the
origin of another thin snapshot.

## 3. Key differences

| Property | Classic snapshot | Thin snapshot |
|----------|------------------|---------------|
| Base allocation | Full origin device | Shared thin-pool data space |
| Change tracking | Separate COW exception store | Pool mapping trees and shared-block accounting |
| Snapshot creation | Create exception-store relationship | Create new thin device sharing mappings |
| Snapshot write | Stored in COW device | Allocates a pool data block |
| Origin write | Save old chunk to every relevant COW store first | Allocate new block for writing thin device |
| Capacity failure | COW full invalidates that snapshot | Pool data/metadata exhaustion affects pool thin LVs |
| Deep snapshot chain | Lookup can depend on chain model | Single metadata design avoids O(depth) lookup |
| Merge model | `snapshot-merge` exists | Thin snapshots are peer thin LVs; use copy/restore workflows |

Do not use classic snapshot sizing, status, or merge assumptions for a thin
snapshot.

## 4. Consistency is above the block map

A snapshot freezes a block-device mapping at a point in time. It does not know
whether a database transaction, filesystem journal update, or application
write sequence is complete.

Consistency levels:

- crash-consistent: briefly suspend/quiesce block I/O so the image resembles a
  sudden power-loss point;
- filesystem-consistent: freeze the filesystem around creation;
- application-consistent: flush and quiesce the application, then the
  filesystem, then create the snapshot.

Always thaw/resume in reverse order and bound the pause.

## 5. External origin

A thin device can use a read-only block device outside the pool as an external
origin. Reads of unmapped regions fall through to that device; writes allocate
pool blocks.

The external origin must remain immutable for the entire lifetime of every
thin descendant. Changing it silently changes data visible through unmapped
regions.

## Lab: identify a snapshot implementation

For an LVM snapshot, inspect:

```bash
lvs -a -o name,attr,origin,pool_lv,data_percent,metadata_percent,devices
dmsetup ls --tree
dmsetup table
```

A classic snapshot stack shows `snapshot` and `snapshot-origin` targets plus a
COW device. A thin snapshot shows `thin` targets referencing the same
`thin-pool` and different device IDs.

## Failure patterns

- Calling both implementations "COW LV" and assuming identical behavior.
- Sizing a thin snapshot as though it had a fixed classic COW area.
- Using `lvconvert --merge` expectations for thin snapshots.
- Snapshotting an active origin without quiescing.
- Modifying an external origin.
- Protecting pool data but leaving thin metadata unprotected.

## Self-check

1. What is copied on the first classic origin write?
2. What changes on disk when a thin snapshot is created?
3. Why can thin snapshots be activated independently?
4. Which layer provides application consistency?

## References

- [Kernel classic snapshot documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/snapshot.html)
- [Kernel thin-provisioning documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/thin-provisioning.html)
- [LVM thin provisioning manual](https://man7.org/linux/man-pages/man7/lvmthin.7.html)

---

## Previous / Next

[← Previous: Day 2 — Tables and lifecycle: targets, atomic reload, suspend, resume, and teardown](day02-tables-targets-and-lifecycle.md) | [Device Mapper study index](README.md) | [Next: Day 4 — Thin-pool architecture: data, metadata, mappings, space maps, and chunks →](day04-thin-pool-architecture.md)
