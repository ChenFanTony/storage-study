# Day 18: md/RAID

## Learning Objectives
- Understand the MD subsystem and RAID personality model
- Learn RAID-1 bio handling, rebuild, and bitmap journaling
- Create and manage a RAID-1 array with `mdadm`
- Observe rebuild behavior in practice

---

## 1. What is MD?

MD (Multiple Devices) is the Linux kernel's software RAID implementation. It combines multiple block devices into a single logical device with redundancy, striping, or both.

MD is distinct from Device Mapper:
- **MD** specializes in RAID personalities with built-in resync/rebuild
- **DM** is a generic remapping framework
- Both live under `drivers/md/` for historical reasons

---

## 2. RAID Personalities

MD supports multiple RAID levels through "personalities":

| Level | Name | Description | Min Disks |
|-------|------|-------------|-----------|
| RAID-0 | Striping | Data spread across disks, no redundancy | 2 |
| RAID-1 | Mirroring | Data duplicated on all disks | 2 |
| RAID-4 | Dedicated parity | Stripe + dedicated parity disk | 3 |
| RAID-5 | Distributed parity | Stripe + rotating parity | 3 |
| RAID-6 | Dual parity | Stripe + two parity blocks | 4 |
| RAID-10 | Striped mirrors | Combines striping and mirroring | 4 |
| Linear | Concatenation | Append disks sequentially | 2 |

Each personality registers its own `md_personality` with callbacks for I/O handling, error recovery, and reshape.

---

## 3. MD Architecture

```text
┌─────────────────────────────┐
│  /dev/md0 (mddev)           │  ← virtual RAID device
│    personality: raid1        │
│    rdev list:                │
│      /dev/sdb (active)       │
│      /dev/sdc (active)       │
└─────────────┬───────────────┘
              |
              v
    md_personality->make_request()
              |
    ┌─────────┴─────────┐
    v                   v
 /dev/sdb            /dev/sdc
 (mirror 0)          (mirror 1)
```

Key objects:
- **`struct mddev`** — the RAID array device
- **`struct md_rdev`** — one member device in the array
- **`struct md_personality`** — RAID level implementation (callbacks)

---

## 4. RAID-1 Bio Handling

Source: `drivers/md/raid1.c`

### Read path
```text
read bio → raid1_read_request()
    → select one mirror (load balancing / closest)
    → remap bio to selected member device
    → submit
```

RAID-1 reads go to only one mirror, chosen by a simple balancing algorithm.

### Write path
```text
write bio → raid1_write_request()
    → create write bios for ALL active mirrors
    → submit to all mirrors in parallel
    → wait for all completions
    → complete original bio
```

RAID-1 writes must reach all mirrors for redundancy.

### Failure handling
- If a mirror fails during I/O, it is marked faulty
- Reads are redirected to surviving mirrors
- Array continues in degraded mode

---

## 5. Resync and Rebuild

### When does resync happen?
- After creating a new array
- After replacing a failed disk
- After unclean shutdown (bitmap-guided)

### Resync process
```text
md_do_sync()
    → for each region in the array:
        read from good source
        write to target disk(s)
        update bitmap/progress
```

Resync runs in the background, throttled to avoid starving normal I/O.

### Bitmap journaling

The write-intent bitmap tracks which regions have pending writes:
- On write: set bitmap bit for the affected region
- On write completion: clear bitmap bit
- On recovery: only resync regions with set bitmap bits

Without a bitmap, a full resync is needed after any unclean shutdown. With a bitmap, only dirty regions need resync — dramatically faster.

---

## 6. Hands-On Exercises

### Exercise 1: Create a RAID-1 with loop devices

```bash
# Create backing files
dd if=/dev/zero of=/tmp/raid-disk0 bs=1M count=100
dd if=/dev/zero of=/tmp/raid-disk1 bs=1M count=100

# Set up loop devices
sudo losetup /dev/loop2 /tmp/raid-disk0
sudo losetup /dev/loop3 /tmp/raid-disk1

# Create RAID-1
sudo mdadm --create /dev/md0 --level=1 --raid-devices=2 \
    /dev/loop2 /dev/loop3

# Verify
cat /proc/mdstat
sudo mdadm --detail /dev/md0
```

### Exercise 2: Use the RAID device

```bash
sudo mkfs.ext4 /dev/md0
sudo mkdir -p /mnt/raid-test
sudo mount /dev/md0 /mnt/raid-test
sudo dd if=/dev/urandom of=/mnt/raid-test/testfile bs=1M count=10
md5sum /mnt/raid-test/testfile
```

### Exercise 3: Observe resync

```bash
# Watch resync progress
watch cat /proc/mdstat
```

### Exercise 4: Simulate disk failure and rebuild

```bash
# Mark one disk as faulty
sudo mdadm /dev/md0 --fail /dev/loop3

# Check degraded state
cat /proc/mdstat
sudo mdadm --detail /dev/md0

# Remove failed disk
sudo mdadm /dev/md0 --remove /dev/loop3

# Re-add (simulates replacement)
sudo mdadm /dev/md0 --add /dev/loop3

# Watch rebuild
watch cat /proc/mdstat
```

### Exercise 5: Verify data survived

```bash
md5sum /mnt/raid-test/testfile
# Should match the original checksum
```

### Exercise 6: Cleanup

```bash
sudo umount /mnt/raid-test
sudo mdadm --stop /dev/md0
sudo mdadm --zero-superblock /dev/loop2
sudo mdadm --zero-superblock /dev/loop3
sudo losetup -d /dev/loop2
sudo losetup -d /dev/loop3
rm /tmp/raid-disk0 /tmp/raid-disk1
```

### Exercise 7: Source navigation

```bash
grep -rn "raid1_read_request\|raid1_write_request" drivers/md/raid1.c | head -10
grep -rn "md_do_sync\|bitmap_start" drivers/md/md.c | head -10
```

---

## 7. Source Navigation Checklist

Primary:
- `drivers/md/md.c` — MD core: array management, sync thread
- `drivers/md/raid1.c` — RAID-1 personality
- `drivers/md/md-bitmap.c` — write-intent bitmap

Supporting:
- `drivers/md/raid5.c` — RAID-5/6 personality
- `drivers/md/raid10.c` — RAID-10 personality
- `include/linux/raid/md_p.h` — on-disk superblock format

---

## 8. MD vs DM-RAID

Note: Device Mapper also has a RAID target (`dm-raid`) that wraps MD personalities:

```bash
sudo dmsetup table | grep raid
```

LVM's RAID support uses dm-raid under the hood, which internally uses MD personalities. The key difference is management interface:
- `mdadm` manages MD arrays directly
- `lvcreate --type raid1` uses dm-raid (which uses MD code internally)

---

## 9. Common Pitfalls

1. No bitmap on RAID-1
   - Unclean shutdown triggers full resync instead of partial
   - Always use `--bitmap=internal` for production arrays

2. Resync starving normal I/O
   - Tune `speed_limit_min` / `speed_limit_max` in `/proc/sys/dev/raid/`

3. Mixing disk sizes in RAID-1
   - Array capacity limited to smallest disk
   - Remaining space on larger disks is wasted

4. Write hole in RAID-5/6
   - Power loss during stripe write can leave parity inconsistent
   - Bitmap or journal-based approaches mitigate this

---

## 10. Self-Check Questions

1. How does RAID-1 handle a read request?
2. How does RAID-1 handle a write request?
3. What is the purpose of the write-intent bitmap?
4. What happens when a mirror disk fails during operation?
5. What is the difference between MD and DM-RAID?

## 11. Self-Check Answers

1. It selects one mirror based on a balancing algorithm and reads from that single device.
2. It clones the write bio to all active mirrors and submits them in parallel.
3. It tracks regions with pending writes so that after unclean shutdown, only dirty regions need resync instead of the entire array.
4. The disk is marked faulty, removed from the active set, and the array continues in degraded mode using surviving mirrors.
5. MD is directly managed by `mdadm`. DM-RAID is a Device Mapper target that wraps MD personalities and is managed through DM/LVM tools. Internally, dm-raid uses the same MD personality code.

---

## 12. Tomorrow's Preview: Day 19 — ext4: Layout & Journal

Next we dive into filesystem internals with ext4:
- Block group layout and superblock structure
- JBD2 journaling subsystem
- Recovery and transaction commit model.
