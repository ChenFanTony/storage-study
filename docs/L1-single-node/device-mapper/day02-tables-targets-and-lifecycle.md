# Day 2: Tables, Targets, and Lifecycle

## Learning objectives

- Build simple linear and striped mappings.
- Distinguish active and inactive tables.
- Understand suspend, reload, resume, and remove.
- Interpret table output separately from status output.

## 1. Table versus status

```bash
dmsetup table  demo     # configuration: target and arguments
dmsetup status demo     # runtime target state and counters
dmsetup info   demo     # open count, suspension, event number, major:minor
```

Table syntax is target input. Status syntax is target output and differs by
target and kernel version. Parse the documented fields for the deployed
kernel; do not use a fixed token offset across every target.

## 2. Simple targets

`linear` maps a logical range onto an underlying device and offset:

```text
0 <length> linear <device> <offset>
```

`striped` rotates fixed-size chunks across devices and provides RAID-0-like
parallelism without redundancy:

```text
0 <length> striped <number-devices> <chunk-sectors>
  <device1> <offset1> <device2> <offset2> ...
```

`zero` returns zeroes for reads and discards writes. `error` fails I/O. They
are useful for testing table composition and failure handling without inventing
a custom block driver.

## 3. Atomic table switch

A mapped device has an active table and may have an inactive table prepared for
the next switch:

```text
dmsetup load demo --table '<new table>'  # prepare inactive table
dmsetup suspend demo                     # stop new I/O; drain or queue
dmsetup resume demo                      # atomically activate loaded table
```

Suspension is a correctness boundary. Targets may need messages or
target-specific preparation before the switch. Filesystems and applications
may require quiescing before changes that alter visible data.

Never replace a table with mappings to different data and assume suspension
makes the contents consistent. Suspend coordinates I/O; it does not migrate or
validate payload.

## 4. Safe Disposable Lab

Create two sparse files and loop devices in a test VM:

```bash
truncate -s 256M /tmp/dm-a.img /tmp/dm-b.img
sudo losetup --find --show /tmp/dm-a.img
sudo losetup --find --show /tmp/dm-b.img

# Record returned loop paths as LOOP_A and LOOP_B.
sudo blockdev --getsz "$LOOP_A"
```

Using a length no larger than the smaller loop device:

```bash
sudo dmsetup create dm-linear-a \
  --table "0 $SECTORS linear $LOOP_A 0"

sudo dmsetup table dm-linear-a
sudo dmsetup status dm-linear-a
sudo dmsetup deps dm-linear-a
```

Remove in dependency order after unmounting and closing users:

```bash
sudo dmsetup remove dm-linear-a
sudo losetup -d "$LOOP_A"
sudo losetup -d "$LOOP_B"
```

Resolve variables explicitly. Never paste a guessed `/dev/sdX` into a
destructive command.

## 5. Open counts and teardown

A mapping cannot normally be removed while a filesystem, process, swap area,
or upper dm device holds it open. Diagnose rather than forcing removal:

```bash
dmsetup info -c
lsblk
findmnt
swapon --show
dmsetup ls --tree
```

Deferred removal asks the kernel to remove when the final user closes it. It
does not make active I/O safe to abandon.

## Failure patterns

- Confusing the loaded inactive table with the active table.
- Reloading to a different backing device without copying data.
- Forcing removal while upper layers still depend on the mapping.
- Creating a striped length not divisible by stripe geometry.
- Assuming `status` fields are the same for all targets.
- Leaving loop devices and dm mappings behind after a lab.

## Self-check

1. What is the difference between `dmsetup table` and `dmsetup status`?
2. Why is table loading separate from activation?
3. What does suspend guarantee, and what does it not guarantee?
4. How do you find the user keeping a device open?

## References

- [dmsetup manual](https://man7.org/linux/man-pages/man8/dmsetup.8.html)
- [dm-linear documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/linear.html)
- [dm-stripe documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/striped.html)
- [dm-zero documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/zero.html)

---

## Previous / Next

[← Previous: Day 1 — Device Mapper core: mapped devices, tables, targets, and the bio path](day01-core-and-io-path.md) | [Device Mapper study index](README.md) | [Next: Day 3 — Snapshot models: classic exception-store CoW versus dm-thin shared mappings →](day03-classic-vs-thin-snapshots.md)
