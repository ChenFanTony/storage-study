# Day 15: Device Mapper Core

## Learning Objectives
- Understand Device Mapper's role as a generic block remapping framework
- Learn the dm table, target_type, and bio remapping model
- Follow `dm_submit_bio()` dispatch logic
- Create a `dm-linear` device with `dmsetup` for hands-on study

---

## 1. What is Device Mapper?

Device Mapper (dm) is a kernel framework that maps I/O from virtual block devices to one or more underlying block devices through configurable target modules.

It underpins:
- LVM (Logical Volume Manager)
- dm-crypt (LUKS encryption)
- dm-thin (thin provisioning)
- dm-cache, dm-verity, dm-integrity, and more

Core idea: **intercept bios at a virtual device, remap/transform them, and forward to real devices.**

---

## 2. Architecture Overview

```text
Userspace (dmsetup / LVM tools)
        |
        | ioctl: create device, load table
        v
┌───────────────────────────────┐
│  mapped_device (dm device)    │
│    /dev/dm-0, /dev/mapper/X   │
│                               │
│  dm_table                     │
│    ├── target 0: dm-linear    │ sector 0..1023 → /dev/sda offset 2048
│    ├── target 1: dm-linear    │ sector 1024..2047 → /dev/sdb offset 0
│    └── ...                    │
└───────────────────────────────┘
        |
        | remapped bios
        v
   /dev/sda, /dev/sdb (real devices)
```

Key objects:
- **`mapped_device`** — the virtual block device
- **`dm_table`** — maps sector ranges to targets
- **`dm_target`** — one entry in the table, references a `target_type`
- **`target_type`** — driver module providing map/endio callbacks

---

## 3. The `target_type` Interface

Each DM target module registers a `target_type` with callbacks:

```c
struct target_type {
    const char *name;           /* "linear", "crypt", "thin", ... */
    // ...
    int (*ctr)(struct dm_target *ti, unsigned int argc, char **argv);
    void (*dtr)(struct dm_target *ti);
    int (*map)(struct dm_target *ti, struct bio *bio);
    int (*end_io)(struct dm_target *ti, struct bio *bio, blk_status_t *error);
    // ...
};
```

The critical callback is **`map()`**:
- Receives original bio targeted at the mapped_device
- Remaps `bio->bi_bdev` and `bio->bi_iter.bi_sector` to the underlying device
- Returns `DM_MAPIO_REMAPPED` (forward bio) or `DM_MAPIO_SUBMITTED` (target handles submission)

---

## 4. Bio Remapping Flow

### `dm_submit_bio()`

When I/O arrives at a dm device:

```text
submit_bio(bio)   [bio targets /dev/dm-0]
    |
    v
dm_submit_bio(bio)
    |
    v
__split_and_process_bio()
    |
    v
For each dm_target covering the bio's sector range:
    -> clone bio (or use original if single target)
    -> call target->map(ti, clone_bio)
       -> target remaps bi_bdev, bi_sector
       -> returns DM_MAPIO_REMAPPED
    -> submit_bio_noacct(clone_bio)  [now targets real device]
```

Key points:
- If a bio spans multiple targets, it gets split at target boundaries
- Each clone is independently remapped and submitted
- Completion flows back through `dm_endio()` → original bio completion

---

## 5. dm-linear: The Simplest Target

`dm-linear` maps a sector range 1:1 to a contiguous region on another device with an optional offset.

Source: `drivers/md/dm-linear.c`

### Linear map function (conceptual)
```c
static int linear_map(struct dm_target *ti, struct bio *bio)
{
    struct linear_c *lc = ti->private;

    bio_set_dev(bio, lc->dev->bdev);              /* remap device */
    bio->bi_iter.bi_sector = lc->start +          /* remap sector */
        dm_target_offset(ti, bio->bi_iter.bi_sector);

    return DM_MAPIO_REMAPPED;
}
```

This is the simplest possible remap: change device + add offset.

---

## 6. dm Table and Table Swaps

A `dm_table` holds an ordered array of targets covering the full sector range of the mapped device (no gaps, no overlaps).

Table operations:
- **Load:** userspace sends a new table via ioctl
- **Resume:** activates the loaded table (atomic swap)
- **Suspend:** pauses I/O, prepares for table swap

This model enables live reconfiguration (e.g., LVM operations) without device destruction.

---

## 7. Hands-On Exercises

### Exercise 1: Create a dm-linear device

```bash
# Create a 100MB backing file
dd if=/dev/zero of=/tmp/dm-backing bs=1M count=100

# Set up loop device
sudo losetup /dev/loop0 /tmp/dm-backing

# Create dm-linear mapping: 204800 sectors (100MB) from loop0 offset 0
echo '0 204800 linear /dev/loop0 0' | sudo dmsetup create test-linear

# Verify
lsblk | grep dm
ls -la /dev/mapper/test-linear
sudo dmsetup table test-linear
sudo dmsetup status test-linear
```

### Exercise 2: Perform I/O on the dm device

```bash
# Write and read through DM layer
sudo dd if=/dev/urandom of=/dev/mapper/test-linear bs=4k count=10
sudo dd if=/dev/mapper/test-linear of=/dev/null bs=4k count=10

# Trace to see bio remapping
sudo bpftrace -e '
tracepoint:block:block_bio_remap {
    printf("remap: dev %d,%d -> %d,%d sector %lld -> %lld\n",
        args.dev >> 20, args.dev & 0xfffff,
        args.old_dev >> 20, args.old_dev & 0xfffff,
        args.sector, args.old_sector);
}'
```

### Exercise 3: Cleanup

```bash
sudo dmsetup remove test-linear
sudo losetup -d /dev/loop0
rm /tmp/dm-backing
```

### Exercise 4: Source navigation

```bash
# Key files
grep -rn "dm_submit_bio\|__split_and_process" drivers/md/dm.c | head -20
grep -rn "linear_map\|linear_ctr" drivers/md/dm-linear.c
```

### Exercise 5: Inspect DM internals via dmsetup

```bash
# List all DM devices
sudo dmsetup ls

# Show table for all devices
sudo dmsetup table

# Show detailed info
sudo dmsetup info
```

---

## 8. Source Navigation Checklist

Primary:
- `drivers/md/dm.c` — core mapped_device, bio dispatch
- `drivers/md/dm-linear.c` — simplest target reference
- `drivers/md/dm-table.c` — table management
- `include/linux/device-mapper.h` — dm_target, target_type definitions

Supporting:
- `drivers/md/dm-ioctl.c` — userspace control path
- `drivers/md/dm-core.h` — internal structures

---

## 9. Common Pitfalls

1. Confusing DM with MD (software RAID)
   - DM is a generic remapping framework; MD is specifically RAID
   - Both live under `drivers/md/` which is confusing historically

2. Table gaps or overlaps
   - DM tables must cover the full sector range contiguously
   - Misconfigured tables will be rejected by the kernel

3. Forgetting suspend/resume for live table swaps
   - Direct table replacement without suspend can lose in-flight I/O

4. Not understanding bio splitting
   - Bios crossing target boundaries are split, adding overhead

---

## 10. Self-Check Questions

1. What is the role of `target_type.map()` in Device Mapper?
2. What does `DM_MAPIO_REMAPPED` mean as a return value?
3. How does dm-linear remap a bio?
4. What happens when a bio spans two dm targets?
5. Why can DM tables be swapped atomically?

## 11. Self-Check Answers

1. It receives a bio targeted at the virtual device and remaps it to the appropriate underlying device and sector.
2. It tells the DM core that the bio has been remapped and should be resubmitted to the new device.
3. It changes `bio->bi_bdev` to the backing device and adds a sector offset to `bio->bi_iter.bi_sector`.
4. The bio is split at the target boundary, and each piece is independently mapped and submitted.
5. DM uses suspend (drain in-flight I/O) → swap table pointer → resume, ensuring no I/O sees a partially updated table.

---

## 12. Tomorrow's Preview: Day 16 — dm-thin & dm-cache

We'll examine thin provisioning and caching DM targets:
- dm-thin pool metadata and mapping tree
- dm-cache target and cache policies
- practical setup with `lvcreate --thin`.
