# Day 16: md/RAID — Resync, Bitmap Journal & Failure Recovery

## Learning Objectives
- Understand md's personality model and how RAID levels are implemented
- Deeply understand the partial-stripe write (RAID-5 write hole) problem
- Understand write-intent bitmap and its effect on resync time
- Follow RAID-1 resync and RAID-5 rebuild at source level
- Know the architect-level tradeoffs: RAID-5 vs RAID-6 vs RAID-10

---

## 1. md Architecture: Personalities

md (multiple devices) uses a **personality** plugin model — each RAID level
is a separate module implementing a common interface.

```c
// drivers/md/md.h

struct md_personality {
    char    *name;          // "raid1", "raid5", "raid10", etc.
    int     level;          // RAID level number

    // Core operations:
    void    (*make_request)(struct mddev *mddev, struct bio *bio);
    int     (*run)(struct mddev *mddev);        // start the array
    void    (*free)(struct mddev *mddev, void *priv);
    void    (*status)(struct seq_file *seq, struct mddev *mddev);
    void    (*error_handler)(struct mddev *mddev, struct md_rdev *rdev);
    int     (*hot_add_disk)(struct mddev *mddev, struct md_rdev *rdev);
    int     (*hot_remove_disk)(struct mddev *mddev, struct md_rdev *rdev);
    void    (*sync_request)(struct mddev *mddev, sector_t sector_nr,
                            int *skipped);      // resync/rebuild
    // ...
};
```

Personalities registered at module load:
```bash
# See loaded RAID personalities
cat /proc/mdstat | head -5
lsmod | grep -E "raid|md_mod"
```

---

## 2. RAID-5: The Partial-Stripe Write Problem

This is the most important RAID-5 concept for architects and the most
commonly misunderstood.

### Full-stripe write (good case)
```
RAID-5 with 4 data disks + 1 parity disk, stripe size 64KB

Full stripe write: 256KB data (fills all 4 data disks)
  Disk 0: 64KB  Disk 1: 64KB  Disk 2: 64KB  Disk 3: 64KB  Disk P: parity
  
  Operation: write all 4 data blocks + compute parity + write parity
  I/Os: 5 writes (all parallel)
  Write amplification: 1.25× (5 writes for 4 data blocks)
```

### Partial-stripe write (bad case — the write hole)
```
Partial stripe write: 4KB data (only updates 1 disk in the stripe)

Problem: must update parity to stay consistent
Two approaches:

Approach 1: Read-Modify-Write (RMW)
  1. Read old data block (1 read)
  2. Read old parity block (1 read)
  3. Compute new parity: new_parity = old_parity XOR old_data XOR new_data
  4. Write new data block (1 write)
  5. Write new parity block (1 write)
  I/Os: 2 reads + 2 writes for 1 block of user data
  Write amplification: 4× at worst case (4KB write → 4 I/Os)

Approach 2: Reconstruct-Write (RW)
  1. Read all OTHER data blocks in stripe (3 reads)
  2. Compute parity from scratch
  3. Write new data + parity (2 writes)
  I/Os: 3 reads + 2 writes
  Only better than RMW when most of the stripe is being updated
```

```bash
# Observe read-modify-write in action with blktrace
# Create RAID-5 on loopback devices
for i in 0 1 2 3 4; do
    dd if=/dev/zero of=/tmp/raid-disk${i}.img bs=1M count=512
    DISKS[$i]=$(losetup --find --show /tmp/raid-disk${i}.img)
done

mdadm --create /dev/md0 --level=5 --raid-devices=5 \
    ${DISKS[0]} ${DISKS[1]} ${DISKS[2]} ${DISKS[3]} ${DISKS[4]}

# Write a small random block (partial stripe) and observe the I/O pattern
blktrace -d ${DISKS[0]} -d ${DISKS[1]} -d ${DISKS[2]} -o - &
TRACE_PID=$!

dd if=/dev/urandom of=/dev/md0 bs=4k count=1 seek=100

kill $TRACE_PID
# Observe: one write on one disk triggers reads+writes on parity disk
```

### The Write Hole (crash between RMW steps)

```
Crash scenario during partial-stripe write:

Step 4 complete: new data written to disk 0
Step 5 incomplete: crash before parity written

After reboot:
  Disk 0: new data (updated)
  Disk P: old parity (stale — doesn't match new disk 0 data)
  
  RAID array appears consistent (no detected error)
  But: parity is WRONG for this stripe
  
  If disk 1 now fails:
    Reconstruct disk 1 using: disk 0 XOR disk 2 XOR disk 3 XOR disk P
    = new_data_0 XOR data_2 XOR data_3 XOR old_parity
    = CORRUPTED reconstruction (wrong answer)
    Silent data corruption — no error reported
```

This is the RAID-5 write hole. It's why RAID-5 without a write-intent
journal is not safe for critical data on systems that can crash.

---

## 3. Write-Intent Bitmap

The write-intent bitmap (WIB) tracks which stripes have been recently
written but not yet fully committed to all disks.

```c
// drivers/md/bitmap.c

// Bitmap structure: one bit per chunk (default 512KB chunks)
// Bit set = this chunk was recently written (in-flight or committed)
// Bit clear = this chunk is clean

// Write path:
bitmap_startwrite(bitmap, sector, sectors, behind):
    // Set bits for all chunks covered by this write
    // Written to disk before the actual data I/O

// Completion path:
bitmap_endwrite(bitmap, sector, sectors, success, behind):
    // Decrement in-flight counter for these chunks
    // When counter reaches 0: clear bits (chunk is clean)
    // Periodically flush bitmap to disk
```

**Effect on crash recovery:**
```
Without bitmap: after crash, must resync ENTIRE array
  (don't know which stripes are dirty)
  RAID-5, 10TB: resync time = 10TB / HDD_speed = 10TB / 150MB/s ≈ 18 hours

With bitmap: after crash, resync only dirty chunks
  Typical dirty chunks after crash: <1% of array
  Resync time: <1% × 18 hours ≈ 11 minutes
```

```bash
# Create RAID-1 with write-intent bitmap
mdadm --create /dev/md1 --level=1 --raid-devices=2 \
    --bitmap=internal \       # bitmap stored on array member devices
    /dev/sda /dev/sdb

# Or add bitmap to existing array
mdadm --grow /dev/md0 --bitmap=internal

# Check bitmap status
mdadm --detail /dev/md1 | grep -i bitmap
cat /proc/mdstat | grep bitmap

# Bitmap chunk size affects granularity vs memory usage
mdadm --create /dev/md1 --level=1 --raid-devices=2 \
    --bitmap=internal --bitmap-chunk=1MB \  # default 512KB
    /dev/sda /dev/sdb
```

---

## 4. RAID-5 Journal (md-level write-ahead log)

Since kernel 4.4, md RAID-5 supports a write-ahead log to close the write hole:

```bash
# Create RAID-5 with journal device
mdadm --create /dev/md0 --level=5 --raid-devices=4 \
    /dev/sda /dev/sdb /dev/sdc /dev/sdd \
    --write-journal /dev/nvme0n1p1    # fast SSD journal device

# Journal mode options:
# write-through: journal every write before committing to disk (safe, slower)
# write-back: batch writes in journal (faster, still safe if journal survives crash)
```

```
RAID-5 journal write path:
  1. Write data + parity to journal (NVMe — fast)
  2. Journal write committed (FUA/flush)
  3. Write data + parity to RAID disks (HDDs — slower)
  4. Mark journal entry as complete

On crash between steps 2 and 3:
  Replay journal → complete the RAID-5 write
  No write hole possible
```

---

## 5. md/RAID Source Code: Key Functions

```
drivers/md/md.c          — core md framework
drivers/md/raid1.c       — RAID-1 personality
drivers/md/raid5.c       — RAID-5/6 personality (largest, most complex)
drivers/md/bitmap.c      — write-intent bitmap
drivers/md/raid5-log.c   — RAID-5 write-ahead log (journal)

Key functions to read:

RAID-1:
  raid1_make_request()   — mirror write to all disks, read from one
  sync_request()         — resync: read from one mirror, write to other

RAID-5:
  raid5_make_request()   — dispatch to stripe cache
  handle_stripe()        — THE core function — manages one stripe's state machine
  ops_run_io()           — submit actual I/Os for a stripe
  raid5_build_block()    — reconstruct missing data (rebuild)
```

### The RAID-5 stripe cache

RAID-5 uses an in-memory **stripe cache** to collect partial-stripe writes
and convert them to full-stripe writes where possible:

```c
// drivers/md/raid5.c

struct stripe_head {
    // One per active stripe (sector range = one full RAID stripe)
    struct hlist_node   hash;       // hash table for lookup
    struct r5conf       *raid_conf;
    sector_t            sector;     // start sector of this stripe
    int                 pd_idx;     // parity disk index
    struct r5dev        dev[];      // one per disk in array
    // state machine: STRIPE_ACTIVE, STRIPE_SYNCING, etc.
};

// handle_stripe() processes a stripe through its state machine:
// EMPTY → LOCKED (collecting writes) → COMPUTING_P (parity calc) →
// WRITING (submitting I/Os) → CLEAN
```

```bash
# Tune stripe cache size
cat /sys/block/md0/md/stripe_cache_size
echo 32768 > /sys/block/md0/md/stripe_cache_size  # increase for write-heavy workloads
# Larger cache = more coalescing of partial writes = less RMW overhead
# Memory cost: ~5KB per stripe entry
```

---

## 6. Resync and Rebuild: Architect's View

```bash
# Monitor resync/rebuild progress
watch -n1 "cat /proc/mdstat"
# Shows: [====>................]  recovery = 23.5% (...)
#        finish=47.3min speed=142857K/sec

# Control resync speed (balance rebuild speed vs production I/O impact)
cat /sys/block/md0/md/sync_speed_min  # minimum resync speed (KB/s)
cat /sys/block/md0/md/sync_speed_max  # maximum resync speed (KB/s)

# Throttle resync to protect production workload
echo 10000  > /sys/block/md0/md/sync_speed_min   # 10 MB/s minimum
echo 100000 > /sys/block/md0/md/sync_speed_max   # 100 MB/s maximum

# For emergency rebuild (production down, need it fast):
echo 1000000 > /sys/block/md0/md/sync_speed_max  # 1 GB/s
```

**RAID-5 rebuild time estimation:**
```
Array: 4+1 RAID-5, 4TB per disk = 12TB usable
Failed disk: 4TB
Rebuild reads: 3 remaining disks × 4TB = 12TB reads
Rebuild writes: 4TB to new disk
At 150MB/s sustained HDD read: 12TB / 150MB/s ≈ 22 hours

During rebuild: second disk failure = total data loss
RAID-6 gives one more failure margin
```

---

## 7. RAID Level Decision Matrix

| RAID Level | Min Disks | Usable % | Write Penalty | Fault Tolerance | Best For |
|-----------|-----------|----------|---------------|-----------------|----------|
| RAID-1 | 2 | 50% | 1× (mirror) | 1 disk (N-1 with more) | Boot, small critical data |
| RAID-5 | 3 | (N-1)/N | 4× (partial) | 1 disk | Read-heavy, cost-sensitive |
| RAID-6 | 4 | (N-2)/N | 6× (partial) | 2 disks | Large arrays, high rebuild risk |
| RAID-10 | 4 | 50% | 1× (mirror) | 1 per mirror pair | Write-heavy, databases |

**RAID-5 is dangerous for large HDD arrays:**
```
12× 8TB HDD RAID-5 array:
  Usable: 88TB
  Rebuild time on failure: ~24-30 hours
  During rebuild: URE (Unrecoverable Read Error) probability per TB read:
    Consumer HDD: 1 in 10^14 bits = 1 error per 12.5TB read
    Rebuild reads 11 × 8TB = 88TB → ~7 URE events expected
  Each URE during rebuild = second failure = TOTAL DATA LOSS

Recommendation: RAID-6 for >6 disk arrays, or RAID-10 for write-heavy.
```

---

## 8. Hands-On: RAID-1 Failure and Rebuild

```bash
# Setup RAID-1 on loopback
dd if=/dev/zero of=/tmp/r1-disk0.img bs=1M count=1024
dd if=/dev/zero of=/tmp/r1-disk1.img bs=1M count=1024
D0=$(losetup --find --show /tmp/r1-disk0.img)
D1=$(losetup --find --show /tmp/r1-disk1.img)

mdadm --create /dev/md10 --level=1 --raid-devices=2 --bitmap=internal $D0 $D1
mkfs.ext4 /dev/md10
mount /dev/md10 /mnt/raid-test

# Write test data
dd if=/dev/urandom of=/mnt/raid-test/testfile bs=1M count=128
md5sum /mnt/raid-test/testfile > /tmp/raid-expected.md5

# Simulate disk failure
mdadm --fail /dev/md10 $D1
cat /proc/mdstat   # array is degraded

# Verify data still accessible
md5sum -c /tmp/raid-expected.md5 && echo "Data intact on degraded array"

# "Replace" failed disk (add spare)
dd if=/dev/zero of=/tmp/r1-disk2.img bs=1M count=1024
D2=$(losetup --find --show /tmp/r1-disk2.img)
mdadm --add /dev/md10 $D2

# Watch rebuild
watch -n1 "cat /proc/mdstat"

# Verify after rebuild
md5sum -c /tmp/raid-expected.md5 && echo "Data intact after rebuild"
mdadm --detail /dev/md10
```

---

## 9. Self-Check Questions

1. What is the RAID-5 write hole and under what exact condition does it cause data corruption?
2. Why does the write-intent bitmap reduce resync time from hours to minutes after a crash?
3. What is the read-modify-write sequence for a 4KB partial-stripe write on RAID-5?
4. A 10-disk RAID-5 array with 6TB HDDs: estimate rebuild time, and calculate the approximate probability of a URE during rebuild.
5. The stripe cache in RAID-5 serves what purpose in reducing write amplification?
6. Why is RAID-10 preferred over RAID-5 for write-heavy database workloads?

## 10. Answers

1. The write hole occurs when a crash happens between writing new data and writing the updated parity in a partial-stripe write. After reboot: the data block is updated but parity is stale. If another disk then fails, reconstruction using the stale parity produces corrupted data with no error reported.
2. Without bitmap: md doesn't know which stripes were in-flight at crash time, must verify the entire array (full resync). With bitmap: only stripes with set bits (recently written) need resync — typically <1% of the array after a normal crash.
3. (1) Read old data block from disk. (2) Read old parity block. (3) Compute new parity: `new_P = old_P XOR old_data XOR new_data`. (4) Write new data block. (5) Write new parity block. Total: 2 reads + 2 writes per user write.
4. 9 data disks × 6TB = 54TB usable. Rebuild reads: 9 × 6TB = 54TB at ~150MB/s = ~100 hours. URE rate (consumer): 1 per 12.5TB read. 54TB rebuild reads → ~4 URE events expected → high probability of data loss. RAID-6 or RAID-10 strongly recommended.
5. The stripe cache collects multiple partial writes to the same stripe and can merge them into a single full-stripe write, eliminating the need for read-modify-write and reducing write amplification from 4× to 1.25×.
6. RAID-10 has no partial-stripe write penalty (each write goes to a mirror pair — no parity computation needed). Write latency matches single-disk write latency. RAID-5's RMW adds 2 extra I/Os per partial write, severely impacting random write IOPS for databases.

---

## Tomorrow: Day 17 — XFS: AG Model, Log Design & Allocator

First of two XFS deep-dive days. We read `xfs_alloc.c`, `xfs_log.c`,
and understand why XFS dominates production Linux storage.
