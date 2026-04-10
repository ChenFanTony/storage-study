# Day 26: Zoned Devices & ZNS

## Learning Objectives
- Understand zoned block device concepts (zone types, write pointer rules)
- Learn Linux zoned block interfaces and constraints
- Understand NVMe ZNS high-level model
- Practice zoned experiments with `null_blk` and `zonefs`

---

## 1. Why Zoned Storage Exists

Zoned storage exposes sequential-write constraints to improve device-level efficiency and media management.

Common motivations:
- better write amplification control
- improved internal media placement efficiency
- explicit host-device coordination for write ordering

Two common forms:
- **Host-Managed/Host-Aware zoned block devices** (SATA/SCSI zoned models)
- **NVMe ZNS** (Zone Namespace)

---

## 2. Core Zoned Concepts

A zoned device is split into fixed-size zones.

Each zone has:
- **start LBA**
- **length/capacity**
- **state** (empty/open/full/etc., model-dependent)
- **write pointer** (for sequential-write-required zones)

Key rule for sequential-write zones:
- writes must occur at current write pointer
- out-of-order writes are invalid

---

## 3. Zone Types (High-Level)

Typical zone types in Linux terminology:
- **Conventional zone**: random write allowed
- **Sequential-write-required zone**: must append at write pointer
- (Some models also include sequential-write-preferred semantics)

Operational consequences:
- application/filesystem must track write pointer progression
- reset/finish/open/close operations can be required depending on workflow

---

## 4. Linux Zoned Block Support

Primary user-facing interfaces:
- block layer zoned APIs and ioctls
- sysfs queue attributes for zoned capabilities
- tools like `blkzone`

Useful files and docs:
- `Documentation/block/zoned-blockdevices.rst`
- `block/blk-zoned.c`

Inspect device zoning info:
```bash
cat /sys/block/<dev>/queue/zoned
cat /sys/block/<dev>/queue/chunk_sectors
```

---

## 5. NVMe ZNS Model (Overview)

ZNS presents zones in an NVMe namespace with zone management commands.

Common operations:
- report zone state
- append/write within zone constraints
- reset zone write pointer
- finish/close/open zone (depending on operation/state model)

Conceptual difference from regular NVMe namespace:
- host must respect per-zone sequential semantics
- workload/log-structured design becomes more important

---

## 6. Filesystem/Stack Implications

Traditional random-overwrite patterns can clash with zoned constraints.

Common adaptation patterns:
- log-structured write design
- zone-aware filesystems/tooling
- `zonefs` as a simple zone-to-file exposure model for experiments

Why this matters:
- application/data layout strategy becomes part of correctness and performance.

---

## 7. Hands-On Exercises

### Exercise 1: Read zoned kernel docs
```bash
# from kernel source root
less Documentation/block/zoned-blockdevices.rst
```

### Exercise 2: Create zoned test device with null_blk
```bash
# unload first if already loaded
sudo modprobe -r null_blk || true

# Example zoned null_blk instance (parameters may vary by kernel)
sudo modprobe null_blk nr_devices=1 zoned=1 gb=2 bs=4096

lsblk -o NAME,SIZE,TYPE | grep nullb
```

### Exercise 3: Inspect zoned attributes
```bash
cat /sys/block/nullb0/queue/zoned
cat /sys/block/nullb0/queue/chunk_sectors
cat /sys/block/nullb0/queue/max_open_zones 2>/dev/null || true
cat /sys/block/nullb0/queue/max_active_zones 2>/dev/null || true
```

### Exercise 4: Report zones with blkzone
```bash
sudo blkzone report /dev/nullb0 | head -60
```

### Exercise 5: Reset zone and test sequential writes
```bash
# reset first zone
sudo blkzone reset -o 0 -l 1 /dev/nullb0

# sequential write at start
dd if=/dev/zero of=/dev/nullb0 bs=4096 count=128 oflag=direct

# (advanced) attempt out-of-order write and observe expected failure semantics
```

### Exercise 6: zonefs quick experiment (if available)
```bash
# create zonefs on zoned device in lab context only
sudo mkfs.zonefs /dev/nullb0
sudo mkdir -p /mnt/zonefs-test
sudo mount -t zonefs /dev/nullb0 /mnt/zonefs-test
ls -l /mnt/zonefs-test
```

### Exercise 7: Source navigation
```bash
grep -rn "zoned\|zone" block/blk-zoned.c include/linux/blkdev.h | head -50
```

---

## 8. Source Navigation Checklist

Primary:
- `Documentation/block/zoned-blockdevices.rst`
- `block/blk-zoned.c`

Supporting:
- `include/linux/blkzoned.h`
- `drivers/nvme/host/` (for ZNS-capable NVMe paths, if present in your kernel)

---

## 9. Common Pitfalls

1. Treating zoned devices like random-overwrite disks
   - sequential zone constraints must be respected

2. Ignoring zone reset/open/finish workflow
   - state transitions matter for correctness

3. Running zoned experiments on non-lab devices
   - always use disposable or synthetic devices first

4. Misreading throughput without zone-state context
   - full/closed zone behavior can skew results

---

## 10. Self-Check Questions

1. What is a zone write pointer?
2. Why can an out-of-order write fail on zoned devices?
3. Which kernel doc introduces Linux zoned block behavior?
4. What does `blkzone report` provide?
5. Why is zone-aware data layout important?

## 11. Self-Check Answers

1. It marks the next valid write position in a sequential-write zone.
2. Sequential-write-required zones only accept writes at current write pointer.
3. `Documentation/block/zoned-blockdevices.rst`.
4. Zone metadata/state information (start, length/capacity, condition, pointers).
5. Because correctness and performance depend on respecting zone semantics and minimizing invalid write patterns.

---

## 12. Tomorrow’s Preview: Day 27 — cgroup I/O Control

Next we study cgroup v2 I/O control:
- throttling and latency controls
- `io.max`, `io.weight`, `io.latency`
- practical per-workload isolation and tuning.
