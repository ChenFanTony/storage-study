# Day 6: LVM Thin-Snapshot Lab

## Learning objectives

- Create a thin pool and thin LV through LVM.
- Take a filesystem-consistent thin snapshot.
- Demonstrate origin/snapshot divergence.
- Inspect the dm stack and clean it up in dependency order.

## Safety boundary

Run this only in a disposable VM. The commands initialize block devices and
destroy their contents. Substitute only loop devices created for this lab.

## 1. Create disposable storage

```bash
truncate -s 8G /tmp/dm-thin-lab.img
LOOP_DEV=$(sudo losetup --find --show /tmp/dm-thin-lab.img)
printf 'using %s\n' "$LOOP_DEV"
lsblk "$LOOP_DEV"

sudo pvcreate "$LOOP_DEV"
sudo vgcreate dmstudy "$LOOP_DEV"
sudo lvcreate --type thin-pool -L 6G -n pool dmstudy
sudo lvcreate --type thin -V 20G -n origin dmstudy/pool
```

The 20 GiB virtual LV is backed by a 6 GiB pool. This overcommit is intentional
for the lab, not permission to ignore physical capacity.

Inspect:

```bash
sudo lvs -a -o name,attr,size,pool_lv,origin,data_percent,metadata_percent,devices dmstudy
sudo dmsetup ls --tree
sudo dmsetup table
sudo dmsetup status
```

## 2. Create data

```bash
sudo mkfs.xfs /dev/dmstudy/origin
sudo mkdir -p /mnt/dm-origin /mnt/dm-snapshot
sudo mount /dev/dmstudy/origin /mnt/dm-origin

printf 'before snapshot\n' | sudo tee /mnt/dm-origin/state.txt
sudo xfs_freeze -f /mnt/dm-origin
sudo lvcreate --snapshot -n snap dmstudy/origin
sudo xfs_freeze -u /mnt/dm-origin
```

Do not specify a snapshot size. With a thin origin, that creates a thin
snapshot in the same pool. Supplying a size can select a different snapshot
type depending on LVM syntax and version; verify with `lvs`.

Use a shell trap in real automation so a failed snapshot command cannot leave
the filesystem frozen.

## 3. Diverge origin and snapshot

XFS filesystems copied at block level have the same UUID, so mount the snapshot
read-only with `nouuid`:

```bash
sudo mount -o ro,nouuid /dev/dmstudy/snap /mnt/dm-snapshot
sudo cat /mnt/dm-snapshot/state.txt

printf 'after snapshot\n' | sudo tee /mnt/dm-origin/state.txt
sudo sync

sudo cat /mnt/dm-origin/state.txt
sudo cat /mnt/dm-snapshot/state.txt
```

The origin shows the new text; the snapshot retains the old text. Inspect
`Data%` and `Meta%`, then create a larger changed file and observe both rise.

## 4. Inspect relationships

```bash
sudo lvs -a \
  -o name,lv_attr,lv_size,pool_lv,origin,data_percent,metadata_percent,devices \
  dmstudy

sudo dmsetup ls --tree
sudo dmsetup table dmstudy-origin
sudo dmsetup table dmstudy-snap
sudo dmsetup status dmstudy-pool-tpool
```

Both visible LVs should use thin targets referencing the same pool. They have
different thin device IDs but may share physical mappings.

## 5. Remove safely

```bash
sudo umount /mnt/dm-snapshot
sudo umount /mnt/dm-origin

sudo lvremove -y dmstudy/snap
sudo lvremove -y dmstudy/origin
sudo lvremove -y dmstudy/pool
sudo vgremove -y dmstudy
sudo pvremove -y "$LOOP_DEV"
sudo losetup -d "$LOOP_DEV"
rm -f /tmp/dm-thin-lab.img
```

Confirm the variable expands to the lab loop device before every destructive
step. If the lab stops midway, inspect `findmnt`, `lvs`, and `dmsetup ls --tree`
rather than forcing removal.

## Lab observations to record

- active dm tables and thin device IDs;
- pool chunk size;
- Data% and Meta% before snapshot;
- percentages immediately after snapshot;
- percentages after origin divergence;
- whether deleting the snapshot releases data;
- filesystem freeze duration.

## Failure patterns

- Using a real disk instead of a lab loop device.
- Forgetting to thaw the filesystem after an error.
- Passing a size and accidentally creating a classic snapshot.
- Mounting duplicate XFS UUIDs without `nouuid`.
- Removing the pool before dependent thin LVs.
- Assuming virtual free space means the pool has data space.

## Self-check

1. Why is the virtual LV larger than the pool?
2. Why does snapshot creation consume little data space initially?
3. Why does divergence increase pool usage?
4. How did you prove this is a thin rather than classic snapshot?

## References

- [LVM thin provisioning manual](https://man7.org/linux/man-pages/man7/lvmthin.7.html)
- [lvcreate manual](https://man7.org/linux/man-pages/man8/lvcreate.8.html)
- [Kernel dm-thin cookbook](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/thin-provisioning.html#cookbook)

---

## Previous / Next

[← Previous: Day 5 — Thin snapshot CoW: mapping sharing, first writes, recursive snapshots, and consistency](day05-thin-snapshot-cow.md) | [Device Mapper study index](README.md) | [Next: Day 7 — Capacity and ENOSPC: Data%, Meta%, discard, autoextension, queueing, and errors →](day07-capacity-discard-and-enospc.md)
