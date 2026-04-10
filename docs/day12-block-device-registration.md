# Day 12: Block Device Registration (`gendisk`, queue, and exposure)

## Learning Objectives
- Understand how a block device is represented in the kernel
- Learn the registration lifecycle from driver init to userspace visibility
- Understand `gendisk`, request queue, and major/minor number roles
- Study how `null_blk` demonstrates block driver patterns
- Verify registration effects in `/sys/block` and `/dev`

---

## 1. Why Registration Matters

Before a block device can serve I/O, it must be registered with kernel block infrastructure.

Registration creates the bridge from internal driver objects to user-visible interfaces like:
- `/dev/<device>` nodes
- `/sys/block/<device>/...`
- partition scanning and metadata exposure

No registration means no standard I/O path from userspace tools.

---

## 2. Core Objects in Block Device Registration

### `struct gendisk`
Represents a disk-like device in the block layer.

Key responsibilities:
- device naming (`disk_name`)
- major/minor mapping and capacity
- partition handling metadata
- linkage to request queue and operations

### Request queue (`struct request_queue`)
Holds request-processing context and limits for the device.

### Block device operations (`struct block_device_operations`)
Driver callbacks for open/release/ioctl and related operations.

### Major/minor numbers
Kernel namespace for device identification:
- major identifies driver/class
- minor identifies specific device/partition instance

---

## 3. High-Level Registration Flow

Conceptual flow in a block driver:

```text
driver/module init
  -> allocate/configure queue/tag set
  -> allocate gendisk
  -> set gendisk fields (name, fops, queue, capacity)
  -> register/add disk to block subsystem
  -> userspace sees /sys/block/<name> and /dev/<name>
```

On teardown:

```text
stop I/O + quiesce
  -> remove/unregister disk
  -> cleanup queue/tag set
  -> free driver resources
```

Order is important to avoid use-after-free during in-flight I/O.

---

## 4. `gendisk` and Queue Coupling

A usable block device generally requires both:
- identity/metadata (`gendisk`)
- I/O execution path (queue + request handling)

Typical driver setup includes:
- queue limits (max sectors/segments, alignment)
- logical/physical block size
- capacity setting in sectors

Incorrect limits/capacity setup can produce misaligned I/O behavior or tool-visible inconsistencies.

---

## 5. Userspace Visibility After Registration

After successful registration, you should observe:

- device in `/sys/block/`
- corresponding node under `/dev/`
- discoverability via `lsblk`, `blkid`, and partition tools

Examples:
- `/sys/block/sda`
- `/sys/block/nvme0n1`
- `/dev/sda`, `/dev/nvme0n1`

For test devices like `null_blk`, names depend on module parameters and instance config.

---

## 6. `null_blk` as Study Driver

`drivers/block/null_blk/` is ideal for understanding block registration and queueing because:
- it is intentionally simple and synthetic
- no real hardware dependency
- supports configurable queue/depth behaviors for experiments

Study goals in `null_blk`:
- where queue/tag set is initialized
- where disk object is created and registered
- how request completion is simulated

---

## 7. Partition and Capacity Notes

When a whole-disk device is registered:
- capacity determines addressable LBA range
- partition scanning may create child device nodes (e.g., `sda1`)
- changes in capacity/partition table require proper rescans/update workflows

Kernel and userspace tools coordinate via standard block subsystem interfaces.

---

## 8. Practical Exercises

### Exercise 1: Inspect current block devices
```bash
lsblk -o NAME,MAJ:MIN,SIZE,TYPE,MOUNTPOINT
cat /proc/partitions
```

### Exercise 2: Explore sysfs layout for one device
```bash
ls /sys/block/sda
cat /sys/block/sda/dev
cat /sys/block/sda/size
cat /sys/block/sda/queue/logical_block_size
cat /sys/block/sda/queue/physical_block_size
```

(Replace `sda` with your device, e.g., `nvme0n1`.)

### Exercise 3: Study `null_blk` module presence
```bash
modinfo null_blk
lsmod | grep null_blk
```

### Exercise 4: Load `null_blk` (lab environment)
```bash
sudo modprobe null_blk
lsblk -o NAME,MAJ:MIN,SIZE,TYPE | grep -E "nullb|NAME"
ls /sys/block | grep nullb
```

Then unload if needed:
```bash
sudo modprobe -r null_blk
```

### Exercise 5: Source navigation grep
```bash
grep -R "add_disk\|device_add_disk\|alloc_disk\|blk_mq_init" drivers/block/null_blk block -n
```

---

## 9. Source Navigation Checklist

Primary:
- `drivers/block/null_blk/`
- `block/genhd.c` (disk management core)
- `include/linux/blkdev.h`

Supporting:
- `block/blk-mq.c`
- `include/linux/blk-mq.h`

---

## 10. Common Pitfalls

1. Registering disk before queue is fully initialized
   - can expose partially initialized device state

2. Teardown order mistakes
   - removing resources while I/O is still possible can crash or corrupt state

3. Capacity/unit confusion
   - sectors vs bytes mistakes cause incorrect visible sizes

4. Ignoring queue limits
   - poor limits can silently degrade behavior/performance

---

## 11. Self-Check Questions

1. What kernel object represents a block disk to the VFS/block subsystem?
2. Why does a block device need both `gendisk` and a request queue?
3. Where can you confirm major/minor mapping for a device in sysfs?
4. Why is `null_blk` useful for study?
5. What is one teardown-order risk in block drivers?

## 12. Self-Check Answers

1. `struct gendisk`.
2. `gendisk` provides identity/metadata exposure; queue provides actual I/O execution path.
3. `/sys/block/<dev>/dev`.
4. It offers a simple, hardware-independent block driver model with configurable behavior.
5. Freeing queue/resources before device removal and I/O quiesce can cause unsafe access to freed objects.

---

## 13. Tomorrow’s Preview: Day 13 — blktrace & BPF Tools

Next we focus on observability tooling:
- interpreting `blktrace`/`blkparse` output
- using `bpftrace` block tracepoints
- building quick latency and issue/completion diagnostics
- converting traces into actionable bottleneck hypotheses.
