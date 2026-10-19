# Day 4: dm-thin Pool Architecture

## Learning objectives

- Identify every thin-pool component and its ownership.
- Understand logical-to-physical mappings and shared-block accounting.
- Choose chunk size with metadata and snapshot costs in mind.
- Interpret transaction IDs, low-water events, and pool status.

## 1. The device stack

```text
/dev/mapper/vg-vm1        /dev/mapper/vg-vm1-snap
       thin target               thin target
       dev ID 1                  dev ID 2
             \                  /
              \                /
                 thin-pool target
                 /              \
          metadata device     data device
             _tmeta             _tdata
```

The pool data device holds payload blocks. The metadata device holds mapping
trees, device details, space maps, sharing information, and transaction state.
Thin LVs never access `_tdata` or `_tmeta` directly.

The pool does not store a thin device's virtual size. Userspace loads a `thin`
target with a logical length and device ID. Loading a smaller length hides
higher mappings; loading a larger length exposes new unprovisioned space.

## 2. Allocation path

An unmapped read returns zeroes, unless the thin device has an external origin.
On first write:

```text
logical block L is unmapped
  -> allocate free physical pool block P
  -> optionally zero according to pool policy
  -> write payload to P
  -> commit mapping (device ID, L) -> P
```

Later overwrites can reuse the mapped physical block when it is not shared.
When a snapshot also references that block, the writer allocates a new block
so the other device retains its point-in-time data.

## 3. Metadata structures

Conceptually, metadata contains:

- per-device mapping trees from logical blocks to physical data blocks;
- data and metadata space maps;
- device creation/snapshot times and mapped-block counts;
- shared-block reference information;
- superblock roots and transaction state.

The persistent-data library uses copy-on-write B-tree structures so a metadata
transaction can publish new roots atomically. Metadata commits occur on FLUSH
or FUA and periodically when neither arrives. The target must preserve metadata
consistency across a crash, but recent acknowledged upper-layer writes can
still require filesystem/application recovery semantics.

## 4. Chunk size

The data block (chunk) is fixed when the pool is created. Kernel documentation
allows 64 KiB through 1 GiB in 64 KiB multiples.

Small chunks:

- reduce copy/allocation amplification for random writes and snapshots;
- increase mapping count, metadata, and B-tree work.

Large chunks:

- reduce metadata entries;
- can allocate or zero far more data than a small write changes;
- increase snapshot divergence and internal fragmentation.

Select from measured write size, snapshot frequency, pool size, and metadata
budget. It cannot be changed in place later.

## 5. Metadata sizing

Kernel guidance provides an estimate:

```text
metadata bytes ~= 48 * data-device bytes / data-block bytes
```

Round up and add headroom for snapshot sharing and change rate. LVM may choose
a metadata size automatically, and the LVM manual documents the supported
metadata-size range and compatibility settings.

Metadata latency matters because allocation and mapping updates are on the
write path. Resilience matters more: losing mappings can lose access to all
thin LVs even when `_tdata` bytes remain intact.

## 6. Status and events

The thin-pool status contains:

```text
transaction-id
used-metadata/total-metadata
used-data/total-data
held-metadata-root
rw | ro | out_of_data_space
discard state
error_if_no_space | queue_if_no_space
needs_check | -
metadata-low-watermark
```

The data low-water event is edge-triggered after resume. Userspace must read
status when handling events rather than treating an event as a persistent
level signal.

## Lab: map LVM names to dm devices

```bash
lvs -a -o name,attr,size,pool_lv,origin,data_percent,metadata_percent,devices
dmsetup ls --tree
dmsetup table
dmsetup status
```

Find `_tdata`, `_tmeta`, the `thin-pool` target, each `thin` target, and device
IDs. Draw the exact stack before changing anything.

## Failure patterns

- Formatting or mounting `_tdata` directly.
- Sizing metadata only from current allocated bytes.
- Choosing chunk size from sequential throughput alone.
- Assuming thin virtual size reserves pool space.
- Losing the metadata device while considering data media redundant.
- Parsing status without checking the running kernel's documented format.

## Self-check

1. Which component stores payload and which stores mappings?
2. Why does an unmapped read return zeroes?
3. What makes chunk size immutable and workload-sensitive?
4. Why can metadata loss be worse than one data-block loss?

## References

- [Kernel dm-thin documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/thin-provisioning.html)
- [Kernel persistent-data library](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/persistent-data.html)
- [LVM thin provisioning manual](https://man7.org/linux/man-pages/man7/lvmthin.7.html)

---

## Previous / Next

[← Previous: Day 3 — Snapshot models: classic exception-store CoW versus dm-thin shared mappings](day03-classic-vs-thin-snapshots.md) | [Device Mapper study index](README.md) | [Next: Day 5 — Thin snapshot CoW: mapping sharing, first writes, recursive snapshots, and consistency →](day05-thin-snapshot-cow.md)
