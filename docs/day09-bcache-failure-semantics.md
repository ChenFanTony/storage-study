# Day 9: bcache — Cache Coherency Under Failure

## Learning Objectives
- Understand bcache's journal and its role in crash recovery
- Precisely characterize what data is lost under each failure scenario
- Simulate failures safely and verify backing device consistency
- Produce the failure semantics reference you will use in architecture decisions

---

## 1. bcache's Durability Architecture

Before analyzing failures, understand what bcache persists and when:

```
bcache persistence layers:
┌─────────────────────────────────────────────────────────┐
│  1. SSD Cache Device (nvme0n1)                          │
│     ├── superblock (offset 0) — cache set identity      │
│     ├── journal (ring buffer) — recent btree updates    │
│     └── data buckets — cached/dirty data                │
├─────────────────────────────────────────────────────────┤
│  2. HDD Backing Device (sda)                            │
│     ├── bcache superblock (offset 8) — device identity  │
│     └── data — authoritative copy (in writethrough)     │
│             — stale copy (in writeback, if dirty on SSD) │
└─────────────────────────────────────────────────────────┘
```

**The journal** is the key recovery mechanism:
- Logs btree updates atomically before they're written to the btree nodes
- Ring buffer on the SSD cache device
- On recovery: replay journal to restore btree consistency
- Does NOT contain data — only metadata (which data is cached where)

---

## 2. Cache Modes and Their Durability Implications

```bash
# Check/set cache mode
cat /sys/block/bcache0/bcache/cache_mode
# Options: writethrough, writeback, writearound, none

echo writeback    > /sys/block/bcache0/bcache/cache_mode
echo writethrough > /sys/block/bcache0/bcache/cache_mode
```

| Mode | Write goes to | HDD up-to-date? | Risk on failure |
|------|--------------|-----------------|-----------------|
| writethrough | SSD + HDD simultaneously | Always | No data loss (HDD always current) |
| writeback | SSD only (HDD updated later) | NO — may be stale | Data loss if SSD lost while dirty |
| writearound | HDD only (bypasses SSD cache) | Always | No data loss |
| none | HDD only (cache disabled) | Always | No data loss |

---

## 3. Failure Scenario Analysis

### Scenario A: Cache Device (SSD) Fails — Writeback Mode

```
State before failure:
  - 10GB dirty data on SSD cache (not yet written to HDD)
  - HDD backing device has stale data for those 10GB

Event: SSD fails (device error, physical failure, sudden removal)

bcache response:
  - I/O to bcache device returns errors
  - bcache detects cache failure: bch_cache_set_error()
  - Cache set goes into error state
  - bcache device becomes inaccessible

Data state on HDD:
  - All dirty data (10GB) is LOST
  - HDD contains whatever was last written in writeback
  - Filesystem on bcache device is in INCONSISTENT state
    (journal and metadata may reference blocks not yet on HDD)

Recovery path:
  - Cannot recover dirty data (it was only on SSD)
  - Must detach cache: echo 1 > /sys/block/bcache0/bcache/detach
    (this makes HDD backing device accessible directly as /dev/sda)
  - Run fsck on /dev/sda — expect significant corruption
  - Restore from backup
```

**Architect implication:** Writeback mode requires SSD redundancy (RAID-1 SSD)
or application-level durability (fsync before acknowledging writes) if data
loss is unacceptable.

### Scenario B: System Crash (Power Loss) — Writeback Mode

```
State before crash:
  - Some dirty data on SSD (not yet on HDD)
  - In-flight I/Os that haven't completed
  - Journal may have uncommitted updates

On reboot:
  1. bcache detects unclean shutdown
  2. Replays journal to restore btree consistency
  3. Dirty data on SSD is still there (SSD survived)
  4. bcache resumes writeback to HDD

Data state:
  - Journal replay restores metadata consistency
  - Dirty data that was safely on SSD: preserved
  - In-flight writes at crash moment: may be partially written
  - Filesystem needs journal recovery (handled by fs itself: ext4, XFS)

What is actually lost:
  - Writes that were in kernel page cache but NOT yet written to SSD
    (i.e., dirty pages above the filesystem layer, not yet submitted as bio)
  - These are the same writes that would be lost in any crash
    (bcache doesn't change this — the VFS writeback cliff is still relevant)
```

### Scenario C: Dirty Shutdown (echo 1 > /sys/block/bcache0/bcache/stop)

```
bcache stop with dirty data:
  - If writeback pending: bcache flushes dirty data to HDD before stopping
  - This can take a LONG time if dirty_data is large
  - Process is synchronous — stop blocks until flush completes

Forced detach (without flush):
  echo 1 > /sys/block/bcache0/bcache/detach
  - Immediately separates cache from backing device
  - Dirty data on SSD is ABANDONED
  - HDD backing device becomes accessible but with stale data
  - Data loss equivalent to Scenario A
```

### Scenario D: Writethrough Mode — Any Failure

```
All writes go to HDD immediately (SSD gets a copy simultaneously)

SSD failure:
  - Cache is gone but HDD has all data
  - bcache detects SSD failure, falls through to HDD directly
  - No data loss, some performance degradation

System crash:
  - No dirty data on SSD (writethrough doesn't buffer writes)
  - HDD has all committed writes
  - Recovery: filesystem journal replay only
  - No bcache-specific data loss

Dirty shutdown:
  - Same as crash — no dirty data to lose
```

---

## 4. The Journal: What It Protects and What It Doesn't

```c
// drivers/md/bcache/journal.c

// Journal entry structure:
struct jset {
    uint64_t    magic;
    uint64_t    seq;        // sequence number
    uint32_t    csum;       // checksum
    uint32_t    keys;       // number of btree updates in this entry
    struct bkey d[];         // the btree key updates
};

// Journal write path:
bch_journal_write():
    // 1. Collect pending btree updates
    // 2. Write to journal ring buffer on SSD
    // 3. Wait for journal write to complete (barrier/FUA)
    // 4. Then apply updates to btree nodes

// Journal replay on recovery:
bch_journal_replay():
    // 1. Find most recent complete journal entry
    // 2. Replay all updates since last btree checkpoint
    // 3. Restore btree to consistent state
```

**What the journal protects:**
- Btree metadata consistency (which data is cached where)
- Cache device structural integrity
- Prevents btree corruption from partial writes

**What the journal does NOT protect:**
- Actual data content (journal contains only btree keys, not data pages)
- Dirty data that hasn't been written to SSD yet (still in page cache)
- Writes that were in-flight to SSD at crash moment

---

## 5. Hands-On: Failure Simulation Lab

**WARNING: Use test devices only. These operations can cause data loss.**

```bash
# Setup: create test bcache on loopback devices
# (safe — uses files, not real hardware)

# Create backing "HDD" and cache "SSD" images
dd if=/dev/zero of=/tmp/hdd-backing.img bs=1M count=2048   # 2GB
dd if=/dev/zero of=/tmp/ssd-cache.img  bs=1M count=512    # 512MB

BACKING=$(losetup --find --show /tmp/hdd-backing.img)
CACHE=$(losetup --find --show /tmp/ssd-cache.img)

# Initialize bcache
make-bcache -B $BACKING -C $CACHE --writeback
sleep 2

# Identify bcache device
BCACHE=/dev/bcache0

# Create filesystem and mount
mkfs.ext4 $BCACHE
mkdir -p /mnt/bcache-test
mount $BCACHE /mnt/bcache-test
```

```bash
# Experiment 1: System crash simulation (writeback mode)
# Step 1: Write dirty data
dd if=/dev/urandom of=/mnt/bcache-test/testfile bs=1M count=64

# Step 2: Check dirty data on SSD cache
cat /sys/block/bcache0/bcache/dirty_data

# Step 3: Record MD5 of the file
md5sum /mnt/bcache-test/testfile > /tmp/expected.md5

# Step 4: Simulate crash (force umount without sync)
echo 3 > /proc/sys/vm/drop_caches  # flush page cache first to make dirty real
# In real scenario: echo b > /proc/sysrq-trigger  (DON'T do on production)
# For safe simulation: umount without sync, then remount
umount -l /mnt/bcache-test

# Step 5: Remount — bcache journal replays
mount $BCACHE /mnt/bcache-test

# Step 6: Verify data integrity
md5sum -c /tmp/expected.md5
```

```bash
# Experiment 2: Cache detach simulation (data loss scenario)
# Step 1: Ensure dirty data exists
dd if=/dev/urandom of=/mnt/bcache-test/testfile2 bs=1M count=64
sync   # flush to bcache device, but may still be dirty on SSD vs HDD

# Step 2: Check dirty data
cat /sys/block/bcache0/bcache/dirty_data

# Step 3: Detach cache IMMEDIATELY (abandon dirty data)
echo 1 > /sys/block/bcache0/bcache/detach
# Now $BACKING is accessible directly

# Step 4: Try to mount backing device directly
# (expect filesystem errors if dirty data was present)
mount $BACKING /mnt/bcache-test 2>&1 || echo "Mount failed — expected if dirty data lost"
fsck $BACKING  # check for corruption
```

---

## 6. Failure Semantics Reference Table

This is the table you produce from today's study:

| Scenario | Mode | Data Lost | HDD State | Recovery Path |
|----------|------|-----------|-----------|---------------|
| SSD hardware failure | writeback | All dirty data on SSD | Stale | Detach, fsck HDD, restore from backup |
| SSD hardware failure | writethrough | None | Current | Detach, mount HDD directly |
| Power loss / crash | writeback | Uncommitted page cache writes (same as no-cache) | Stale but btree recoverable | Reboot, journal replay, bcache resumes writeback |
| Power loss / crash | writethrough | Uncommitted page cache writes only | Current for all fsynced data | Reboot, fs journal replay only |
| Forced detach (no flush) | writeback | All current dirty data on SSD | Stale | Detach, fsck HDD, restore |
| Graceful stop | writeback | None (flush waits for drain) | Current after flush | Normal — no data loss |
| Backing device failure | either | In-flight I/Os | N/A — device gone | Replace HDD, rebuild from SSD dirty data (limited recovery) |

---

## 7. Self-Check Questions

1. In writeback mode, if the SSD cache device fails, what is the exact data loss?
2. What does the bcache journal contain, and what does it NOT contain?
3. After a system crash in writeback mode, why does bcache usually recover successfully?
4. What is the difference between `bcache/stop` and `bcache/detach`?
5. A customer says "our bcache system crashed and we lost data." You ask what cache mode they were using. Why does this matter?
6. An architect proposes using bcache writeback mode for a database with no application-level fsync. What risks would you raise?

## 8. Answers

1. All data that was dirty on the SSD at the time of failure is lost. The HDD has the last successfully written version — which could be significantly behind depending on writeback rate and dirty_data volume.
2. The journal contains btree key updates (metadata: which data is cached at which SSD location). It does NOT contain the actual data pages.
3. The SSD survived — dirty data is still there. The journal replay restores btree metadata consistency. bcache resumes and continues writeback of dirty data to HDD.
4. `stop` triggers a graceful shutdown: waits for dirty data to be flushed to HDD before stopping. `detach` immediately separates cache from backing device without flushing — dirty data is abandoned.
5. Writethrough: no data loss possible from cache failure (HDD always current). Writeback: all dirty data at time of failure is lost. The mode completely determines the failure impact.
6. Without fsync: data acknowledged to application may only be in page cache, then dirty on SSD in writeback mode. SSD failure = data loss. Even with bcache writeback, the combination of no-fsync + writeback mode means two layers of non-durable state. Recommend writethrough mode for databases, or require application-level fsync before acknowledging writes.

---

## Tomorrow: Day 10 — bcache: Limitations & Where It Breaks Down

We study the specific conditions where bcache fails: btree lock contention
on high-queue-depth NVMe, sequential scan cache thrashing, and ZNS
incompatibility — so you know when to recommend alternatives.
