# Day 13: Tiering Failure Semantics — Full Analysis

## Learning Objectives
- Build a complete, precise failure matrix across all tiering modes
- Verify failure behavior by injection (using test devices)
- Produce the reference table usable in architecture documents and customer discussions
- Know the exact recovery procedure for each scenario

---

## 1. The Failure Matrix

This is the deliverable for today. Each row is a scenario you must be able
to explain precisely — not approximately.

### Complete Tiering Failure Semantics Table

| Technology | Mode | Failure Event | Data Lost | HDD/Origin State | Recovery Path | Time to Recovery |
|------------|------|---------------|-----------|-----------------|---------------|-----------------|
| bcache | writeback | SSD hardware failure | ALL dirty data on SSD | Stale (last flushed state) | Detach, fsck HDD, restore from backup | Hours (backup restore) |
| bcache | writeback | System crash / power loss | Uncommitted page cache writes only | Stale but btree recoverable | Reboot → journal replay → bcache resumes | Minutes |
| bcache | writeback | Forced detach (no flush) | All current dirty data | Stale | Mount HDD directly, fsck, expect corruption | Hours (fsck + restore) |
| bcache | writeback | Graceful stop | None | Current (flush waits) | None needed | N/A |
| bcache | writethrough | Any failure | None (from cache) | Always current | Detach/reboot, mount HDD directly | Minutes |
| dm-cache | writeback | SSD hardware failure | All dirty cache blocks | Stale | Uncache (if possible), fsck origin, restore | Hours |
| dm-cache | writeback | System crash | Uncommitted in-flight writes | Stale but metadata recoverable | Reboot → dm-cache metadata journal replay | Minutes |
| dm-cache | writeback | Metadata device failure | None (data) but ALL cache inaccessible | May be accessible directly | Emergency: bypass cache, mount origin directly | Minutes–Hours |
| dm-cache | writethrough | Any cache failure | None | Always current | Remove cache layer, mount origin | Minutes |
| dm-cache | writeback | Cleaner drain + remove | None | Current after drain | Normal decommission | Minutes–Hours (drain time) |
| dm-thin | N/A | Metadata device failure | None (data physically present but unaddressable) | Physically intact, logically inaccessible | thin_repair, restore from thin_dump backup | Hours |
| dm-thin | N/A | Data device failure | All data on failed device | Gone | Restore from backup | Hours |
| dm-thin | N/A | System crash | In-flight writes (last commit_period) | Consistent to last B-tree commit | Reboot → load last superblock | Minutes |

---

## 2. The Key Distinctions Architects Must Know

### bcache writeback vs dm-cache writeback on SSD failure

Both lose dirty data. But the recovery path differs:

```
bcache SSD failure recovery:
  1. bcache detects error → cache set in error state
  2. echo 1 > /sys/block/bcache0/bcache/detach
     (or use sysfs: bcache/unregister)
  3. HDD backing device (/dev/sda) becomes accessible
  4. Mount /dev/sda → expect filesystem errors (journal/metadata may reference unwritten blocks)
  5. fsck /dev/sda
  6. Data from before last writeback is intact

dm-cache SSD failure recovery:
  1. dm-cache detects error → target enters error mode
  2. dmsetup remove cached (force remove)
  3. Origin device (/dev/sda) is now accessible but dirty data is lost
  4. If separate metadata device survived: thin_check/thin_repair may recover metadata
  5. Mount origin directly → expect errors
  6. fsck origin device
```

### dm-thin metadata failure vs data failure

```
Metadata failure:
  Data is physically on disk — bits are there
  You just can't address them (no virtual→physical map)
  thin_repair can sometimes recover partial mapping
  thin_dump XML backup is the only reliable recovery

Data failure:
  Physical blocks are gone
  No software recovery possible
  Restore from backup
```

### bcache crash vs dm-cache crash (writeback, recoverable)

```
bcache crash recovery:
  bcache journal replays btree updates
  Dirty SSD data is still present
  bcache resumes writeback to HDD
  RTO: 2-5 minutes (journal replay + fsck if needed)

dm-cache crash recovery:
  dm-cache metadata journal replays
  Dirty cache blocks still on SSD
  dm-cache resumes writeback
  RTO: 2-5 minutes (similar)

Key difference: both recover dirty data from SSD because SSD survived.
The journal only needs to restore metadata consistency, not data.
```

---

## 3. Failure Injection Lab

```bash
# Setup: loopback devices for safe testing
dd if=/dev/zero of=/tmp/origin.img bs=1M count=2048   # 2GB origin (HDD sim)
dd if=/dev/zero of=/tmp/cache.img  bs=1M count=512    # 512MB cache (SSD sim)

ORIGIN=$(losetup --find --show /tmp/origin.img)
CACHE=$(losetup --find --show /tmp/cache.img)

# Initialize bcache
make-bcache -B $ORIGIN -C $CACHE --writeback
sleep 2

BCACHE=/dev/bcache0
mkfs.ext4 $BCACHE
mount $BCACHE /mnt/test
```

```bash
# Experiment 1: Verify writethrough = no data loss on cache failure

# Switch to writethrough
echo writethrough > /sys/block/bcache0/bcache/cache_mode

# Write data
dd if=/dev/urandom of=/mnt/test/data_wt bs=1M count=128 && sync
md5sum /mnt/test/data_wt > /tmp/wt_expected.md5

# "Kill" the cache device (simulate failure via loopback detach)
umount /mnt/test
losetup -d $CACHE   # detach cache loopback (simulates device gone)

# Can we still access via HDD directly?
mount $ORIGIN /mnt/test   # mount HDD directly
md5sum -c /tmp/wt_expected.md5 && echo "WRITETHROUGH: No data loss confirmed"
umount /mnt/test

# Re-attach cache loopback for next test
CACHE=$(losetup --find --show /tmp/cache.img)
```

```bash
# Experiment 2: Writeback mode — verify dirty data loss on cache failure

# Reinitialize bcache with writeback
make-bcache -B $ORIGIN -C $CACHE --writeback --force
sleep 2

BCACHE=/dev/bcache0
mount $BCACHE /mnt/test
echo writeback > /sys/block/bcache0/bcache/cache_mode

# Write and ensure dirty data exists (don't sync to HDD)
dd if=/dev/urandom of=/mnt/test/data_wb bs=1M count=128
# Don't sync — leave dirty on SSD
DIRTY=$(cat /sys/block/bcache0/bcache/dirty_data)
echo "Dirty data on SSD: $DIRTY"

md5sum /mnt/test/data_wb > /tmp/wb_expected.md5

# "Kill" cache — abandon dirty data
umount -l /mnt/test
echo 1 > /sys/block/bcache0/bcache/detach 2>/dev/null || true
losetup -d $CACHE

# Try to access via HDD
mount $ORIGIN /mnt/test 2>/dev/null || echo "Mount failed (expected — fs inconsistent)"
# If mounts: check if data is correct
md5sum -c /tmp/wb_expected.md5 2>/dev/null && echo "Data intact" \
    || echo "WRITEBACK: Data loss confirmed — dirty data was on SSD"

umount /mnt/test 2>/dev/null; true
```

---

## 4. dm-thin Metadata Failure Lab

```bash
# Setup thin pool on loopback
dd if=/dev/zero of=/tmp/thin_data.img bs=1M count=2048
dd if=/dev/zero of=/tmp/thin_meta.img bs=1M count=64

DATA=$(losetup --find --show /tmp/thin_data.img)
META=$(losetup --find --show /tmp/thin_meta.img)

# Create thin pool (manual dmsetup)
DATA_SIZE=$(blockdev --getsz $DATA)
echo "0 $DATA_SIZE thin-pool $META $DATA 128 0" \
    | dmsetup create test_pool

# Create thin LV (device id 1, 1GB)
echo "0 2097152 thin /dev/mapper/test_pool 1" \
    | dmsetup create thin_lv1

mkfs.ext4 /dev/mapper/thin_lv1
mount /dev/mapper/thin_lv1 /mnt/thin_test

dd if=/dev/urandom of=/mnt/thin_test/testfile bs=1M count=128
md5sum /mnt/thin_test/testfile > /tmp/thin_expected.md5
sync

# Take metadata backup NOW (before simulated failure)
umount /mnt/thin_test
dmsetup remove thin_lv1
dmsetup remove test_pool
thin_dump $META > /tmp/meta_backup.xml
thin_check $META && echo "Metadata clean before failure"

# Simulate metadata corruption
dd if=/dev/urandom of=$META bs=4096 count=1 seek=2 conv=notrunc
echo "Metadata corrupted"

# Attempt to start pool with corrupt metadata
echo "0 $DATA_SIZE thin-pool $META $DATA 128 0" \
    | dmsetup create test_pool 2>&1 && echo "Pool started (may have errors)" \
    || echo "Pool failed to start (expected)"

# Repair using backup
dmsetup remove test_pool 2>/dev/null; true
thin_restore -i /tmp/meta_backup.xml -o $META
thin_check $META && echo "Metadata restored"

# Restart pool
echo "0 $DATA_SIZE thin-pool $META $DATA 128 0" \
    | dmsetup create test_pool
echo "0 2097152 thin /dev/mapper/test_pool 1" \
    | dmsetup create thin_lv1

mount /dev/mapper/thin_lv1 /mnt/thin_test
md5sum -c /tmp/thin_expected.md5 && echo "Data recovered successfully"
```

---

## 5. Recovery Procedure Reference

### bcache Writeback SSD Failure
```bash
# 1. Detach failed cache
echo 1 > /sys/block/bcache0/bcache/detach
# or if bcache device is gone: echo <uuid> > /sys/fs/bcache/unregister

# 2. HDD is now /dev/sda (or whatever backing dev was)
# 3. Check filesystem
fsck /dev/sda

# 4. Mount HDD directly
mount /dev/sda /mnt/recovered
# Data as of last writeback flush is intact
```

### dm-cache Writeback SSD Failure
```bash
# 1. Force-remove the cached device
dmsetup remove --force cached

# 2. Origin device is now accessible
fsck /dev/sda

# 3. Mount origin
mount /dev/sda /mnt/recovered
```

### dm-thin Metadata Corruption
```bash
# 1. Deactivate pool
dmsetup remove thin_lv1 thin_snap1 ...  # all thin devs first
dmsetup remove test_pool

# 2. Check and attempt repair
thin_check /dev/meta_dev
thin_repair -i /dev/meta_dev -o /dev/meta_dev_repaired
thin_check /dev/meta_dev_repaired

# 3. If repair failed: restore from XML backup
thin_restore -i /backup/pool_meta_YYYYMMDD.xml -o /dev/meta_dev_new

# 4. Restart pool with restored metadata
```

---

## 6. Self-Check Questions

1. In bcache writeback mode, after a system crash (not SSD failure), is dirty data lost?
2. dm-cache writeback SSD failure vs bcache writeback SSD failure: what is the same and what differs?
3. A dm-thin pool has 50 thin LVs. The metadata device fails. How many thin LVs lose access?
4. What is the RTO difference between "bcache SSD hardware failure" and "bcache system crash" in writeback mode?
5. A customer wants zero-data-loss guarantee with SSD caching. What is the minimum architecture requirement?
6. You are asked to design a tiered storage system for a database that requires RPO=0 (no data loss). What caching mode and what additional safeguards would you specify?

## 7. Answers

1. No — dirty data that was already on the SSD survives (SSD survived the crash). The bcache journal replays to restore btree metadata consistency. Only writes that were in kernel page cache but not yet submitted to the SSD are lost — the same loss as any buffered write without fsync.
2. Same: all dirty cache data is lost, origin is stale, must fsck origin. Different: recovery tooling (bcache uses detach via sysfs; dm-cache uses dmsetup remove), and dm-cache with separate metadata device may retain metadata even if SSD fails.
3. All 50 — metadata maps all thin LVs. One metadata device failure takes down the entire pool.
4. SSD hardware failure: hours (backup restore). System crash: minutes (journal replay, bcache resumes). The SSD surviving is the critical difference.
5. Minimum: writethrough cache mode (SSD failure cannot cause data loss) + redundant metadata device for dm-thin + regular filesystem-level backups.
6. RPO=0 requires: (1) writethrough cache mode only — writeback has non-zero data loss risk. (2) Application-level fsync before acknowledging writes. (3) Redundant metadata device (RAID-1) for dm-thin if used. (4) Consider whether block-level SSD caching adds enough value vs the complexity and risk — application-level caching (shared_buffers in PostgreSQL) with NVMe direct may be simpler with better guarantees.

---

## Tomorrow: Day 14 — Week 2 Review: Tiering Architecture Decisions

We synthesize the week: produce the "Architect's Guide to Tiering Solutions"
document — covering workload fit, failure tolerance, GC tuning, and
operational complexity for bcache, dm-cache, and dm-thin.
