# Day 25: bcache

## Learning Objectives
- Understand bcache architecture (cache set + backing device)
- Learn registration flow for cache and backing devices
- Understand writeback vs writethrough behavior
- Practice setting up and observing bcache on a lab system

---

## 1. What bcache Solves

bcache combines:
- a **fast cache device** (usually SSD/NVMe)
- a **slow backing device** (usually HDD)

to improve effective performance while preserving larger-capacity backing storage.

It operates at block layer and presents a cached block device to upper layers.

---

## 2. Core Architecture

Conceptual model:

```text
Application / FS
      |
   /dev/bcache0
      |
   bcache layer
   ├─ Cache set (SSD/NVMe)
   └─ Backing device (HDD)
```

Key terms:
- **Cache set**: one cache pool that may serve one or more backing devices
- **Backing device**: slower storage being accelerated
- **Bucket**: allocation unit inside cache device

---

## 3. Registration Flow

Typical lifecycle:
1. Prepare cache and backing devices
2. Register cache device into a cache set
3. Register backing device and attach it to cache set
4. bcache exposes `/dev/bcacheX`
5. Create filesystem / mount on `/dev/bcacheX`

At runtime, sysfs under `/sys/fs/bcache/` and `/sys/block/bcache*/bcache/` exposes status and policy knobs.

---

## 4. Write Policies

### Writethrough
- writes go to backing device (cache may be updated)
- safer durability profile
- lower write acceleration than writeback

### Writeback
- writes acknowledged after landing in cache, flushed later to backing
- higher write performance potential
- requires careful durability/risk management

### Writearound (if configured)
- writes bypass cache; reads may still benefit from cache

---

## 5. Read/Write Behavior (Simplified)

### Read path
- cache hit: serve from cache device
- cache miss: read from backing device and potentially promote into cache

### Write path (writeback mode)
- write lands in cache first
- later background writeback flushes dirty data to backing device

Policy and workload shape decide cache effectiveness.

---

## 6. Key Source Areas

From your plan, focus on:
- `drivers/md/bcache/super.c`
- `drivers/md/bcache/request.c`
- `drivers/md/bcache/writeback.c`

Study priorities:
- metadata/superblock registration
- request routing (hit/miss logic)
- dirty tracking and flush policy

---

## 7. Hands-On Exercises

### Exercise 1: Prepare test devices (lab only)
```bash
# Example: /dev/sdb = backing (slow), /dev/nvme1n1 = cache (fast)
# WARNING: this erases data on target devices
```

### Exercise 2: Create bcache superblocks
```bash
sudo make-bcache -B /dev/sdb
sudo make-bcache -C /dev/nvme1n1
```

### Exercise 3: Register devices
```bash
sudo sh -c 'echo /dev/sdb > /sys/fs/bcache/register'
sudo sh -c 'echo /dev/nvme1n1 > /sys/fs/bcache/register'
```

### Exercise 4: Attach backing to cache set
```bash
# discover UUIDs
ls /sys/fs/bcache/

# find bcache backing sysfs path
ls /sys/block | grep bcache

# attach (example path; adjust UUID/path)
sudo sh -c 'echo <cache_set_uuid> > /sys/block/bcache0/bcache/attach'
```

### Exercise 5: Verify state
```bash
cat /sys/block/bcache0/bcache/state
cat /sys/block/bcache0/bcache/cache_mode
cat /sys/block/bcache0/bcache/dirty_data
```

### Exercise 6: Compare sequential/random performance
```bash
fio --name=seqread --filename=/dev/bcache0 --rw=read --bs=128k --iodepth=16 --ioengine=libaio --direct=1 --size=2G --group_reporting
fio --name=randread --filename=/dev/bcache0 --rw=randread --bs=4k --iodepth=64 --ioengine=libaio --direct=1 --size=2G --group_reporting
```

### Exercise 7: Observe writeback behavior
```bash
# set writeback mode (if intended in lab)
sudo sh -c 'echo writeback > /sys/block/bcache0/bcache/cache_mode'

# generate writes
fio --name=randwrite --filename=/dev/bcache0 --rw=randwrite --bs=4k --iodepth=64 --ioengine=libaio --direct=1 --size=2G --group_reporting

# observe dirty data + writeback rate
watch -n1 'cat /sys/block/bcache0/bcache/dirty_data'
```

---

## 8. Source Navigation Checklist

Primary:
- `drivers/md/bcache/super.c`
- `drivers/md/bcache/request.c`
- `drivers/md/bcache/writeback.c`

Supporting:
- `drivers/md/bcache/bcache.h`
- sysfs interface under `drivers/md/bcache/sysfs.c`

---

## 9. Common Pitfalls

1. Using writeback mode without understanding durability risk
2. Testing with already-warm cache and misreading results
3. Wrong device registration/attach order
4. Running destructive setup on non-lab disks

---

## 10. Self-Check Questions

1. What are the two main device roles in bcache?
2. How does writeback differ from writethrough?
3. Where do you inspect bcache runtime state?
4. Which source file is central for request hit/miss routing?
5. Why can benchmark results vary between first and second runs?

## 11. Self-Check Answers

1. Cache device (fast) and backing device (slow).
2. Writeback acknowledges from cache then flushes later; writethrough writes through to backing immediately.
3. `/sys/block/bcache*/bcache/` and `/sys/fs/bcache/`.
4. `drivers/md/bcache/request.c`.
5. Cache warm-up changes hit ratio and observed latency/throughput.

---

## 12. Tomorrow’s Preview: Day 26 — Zoned Devices & ZNS

Next we study zone-based storage models:
- zone types and write-pointer semantics
- Linux zoned block interfaces
- testing with `null_blk` zoned mode and `zonefs`.
