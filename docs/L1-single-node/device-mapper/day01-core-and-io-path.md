# Day 1: Device Mapper Core and I/O Path

## Learning objectives

- Understand what a mapped device is.
- Follow a bio through a device-mapper table.
- Separate Device Mapper kernel mechanisms from LVM userspace policy.
- Recognize stacking and target boundaries.

## 1. The framework

Device Mapper creates a virtual block device whose sector ranges are handled by
targets:

```text
filesystem / database
        |
        v
/dev/mapper/vg-data
        |
        v
device-mapper core
        |
        +-- sectors 0..N      -> linear target -> /dev/nvme0n1 offset X
        `-- sectors N+1..end  -> linear target -> /dev/nvme1n1 offset Y
```

The kernel core owns device registration, tables, bio routing, suspension, and
lifecycle. A target implements one mapping policy such as `linear`, `striped`,
`thin`, `thin-pool`, `cache`, `crypt`, `multipath`, `integrity`, or `verity`.

LVM is a userspace volume manager that calculates and loads Device Mapper
tables. An LVM logical volume is commonly a stack of several hidden dm devices,
not a separate kernel I/O subsystem.

## 2. Table grammar

A table is a sequence of non-overlapping segments:

```text
<logical start sector> <length in sectors> <target> <target arguments>
```

Example:

```text
0 2097152 linear /dev/loop10 0
2097152 2097152 linear /dev/loop11 0
```

Device Mapper sectors are normally 512-byte units even when the physical
device has 4 KiB sectors. Segment boundaries and target-specific chunk sizes
must satisfy alignment requirements.

The logical range selects a target instance. The target translates the bio and
submits one or more child bios to lower devices. Completion propagates upward
only after the target's child work is complete.

## 3. Bio path

```text
submit_bio()
  -> mapped device request queue
  -> dm core finds table segment
  -> target map callback
       +-> remap bio to a lower device, or
       +-> split/clone bio and submit several children, or
       `-> queue work until target state permits progress
  -> lower device completion
  -> target end-I/O handling
  -> original bio completes
```

A bio crossing two table segments is split. Targets can also split for stripe,
chunk, integrity, or snapshot boundaries. One application I/O can therefore
become several lower-device operations.

Flush, FUA, discard, write zeroes, and zone operations require explicit target
support and correct propagation. Ordinary reads and writes working does not
prove crash-consistency or discard behavior.

## 4. Stacking

```text
filesystem
  -> dm-crypt
     -> dm-thin
        -> dm-cache
           -> dm-multipath
              -> physical paths
```

Stacking composes features but also composes queues, failure states, alignment,
and observability. Determine which layer owns:

- allocation and out-of-space behavior;
- encryption and integrity;
- path failover;
- cache durability;
- snapshot sharing;
- discard translation.

`lsblk` shows topology; `dmsetup ls --tree` shows dm dependencies; `dmsetup table`
shows active mappings.

## 5. Lab: inspect existing mappings

```bash
lsblk -o NAME,MAJ:MIN,TYPE,SIZE,FSTYPE,MOUNTPOINTS
dmsetup ls --tree
dmsetup info -c
dmsetup table
dmsetup status
```

For one mapped device, draw every lower device and label each target. Compare
the table with `lvs -a -o name,attr,devices` if LVM created it.

Do not infer on-disk location from `/dev/mapper` names alone. The active table
is the authoritative kernel mapping.

## Failure patterns

- Treating LVM and Device Mapper as the same layer.
- Reading table lengths as bytes instead of sectors.
- Assuming one bio maps to one lower I/O.
- Ignoring hidden LVM component devices.
- Testing reads/writes but not flush, FUA, or discard.
- Tuning the physical device while queueing occurs in an upper dm target.

## Self-check

1. What does the dm core provide versus a target?
2. When is a bio split?
3. Why can one LVM LV appear as several dm devices?
4. Which commands expose topology, active tables, and runtime status?

## References

- [Linux kernel Device Mapper documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/index.html)
- [Device Mapper kernel architecture paper](https://www.kernel.org/doc/mirror/ols2005v1.pdf)
- [dmsetup manual](https://man7.org/linux/man-pages/man8/dmsetup.8.html)

---

## Next

[Device Mapper study index](README.md) | [Next: Day 2 — Tables and lifecycle: targets, atomic reload, suspend, resume, and teardown →](day02-tables-targets-and-lifecycle.md)
