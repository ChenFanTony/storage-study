# Day 19: ext4 — JBD2 Crash Recovery (Targeted)

## Context
You know ext4 layout and general journaling concepts. This day is targeted:
focus on exactly what JBD2 guarantees under each journal mode, and the
architect-level decisions that follow from those guarantees. Timebox: 2 hours.

---

## Learning Objectives
- Precisely characterize what each JBD2 journal mode guarantees on crash
- Understand JBD2's checkpoint mechanism and when it matters
- Know the ordered mode data=ordered guarantee and its subtle edge cases
- Know when to use journal mode despite the overhead
- Be able to defend a journal mode choice in a design review

---

## 1. JBD2 Journal Modes: Precise Guarantees

```bash
# Set journal mode at mount time
mount -o data=ordered  /dev/sda1 /mnt/ext4   # default
mount -o data=writeback /dev/sda1 /mnt/ext4  # fastest, least safe
mount -o data=journal  /dev/sda1 /mnt/ext4   # safest, highest overhead
```

### `data=writeback` — metadata journaled, data not

```
What is journaled: metadata only (inodes, directory blocks, bitmaps)
What is NOT journaled: file data blocks

Crash guarantee:
  - Filesystem STRUCTURE is consistent after recovery
  - File SIZES and TIMESTAMPS are correct
  - File DATA may be:
    a) The new data (write completed)
    b) The old data (write didn't complete)
    c) GARBAGE — old uninitialized blocks that were previously freed and reused
       ← this is the dangerous case

Why garbage is possible:
  1. File A deleted → blocks freed
  2. File B created → allocated those same blocks (metadata journaled)
  3. File B data write starts but crashes before completing
  4. After recovery: file B exists (metadata committed), data = File A's old data
     OR zeros OR garbage from even older data

Use writeback only when:
  - Application manages its own data integrity (databases with O_DIRECT + fsync)
  - Performance is critical and you understand the risk
  - Never for untrusted content (security issue: old data exposure)
```

### `data=ordered` — metadata journaled, data written before metadata commit

```
What is journaled: metadata only
What is guaranteed: data blocks written to disk BEFORE metadata commit

Mechanism:
  1. Write data blocks to disk (not to journal)
  2. Wait for data writes to complete (ordered dependency)
  3. Commit metadata to journal
  4. Only now is the transaction considered complete

Crash guarantee:
  - If crash before step 3: metadata not committed → recovery sees old state
    file appears truncated/not extended → data is old but consistent
  - If crash after step 3: metadata committed, data was already on disk
    → file has new data, everything consistent
  
  NEVER exposes uninitialized/garbage data (the writeback risk is eliminated)

The subtle edge case:
  data=ordered protects against garbage in NEW extents
  It does NOT protect against torn writes within an existing extent:
  
  Write 4KB to offset 0 of an existing file:
    1. Overwrite existing data block (no metadata change needed — block already allocated)
    2. Crash mid-write
    3. Recovery: metadata unchanged (no journal entry needed), data partially written
    → Half-written block — ordered mode doesn't help here
    → Application must use fsync or O_SYNC for data durability within existing extents

Use ordered (default) for:
  - General purpose workloads
  - Any workload where the garbage-data risk of writeback is unacceptable
  - Most production systems
```

### `data=journal` — both data and metadata journaled

```
What is journaled: EVERYTHING — all data blocks AND metadata

Write path:
  1. Write data to journal
  2. Write metadata to journal  
  3. Commit transaction (single atomic operation)
  4. Checkpoint: copy data+metadata from journal to final locations

Crash guarantee:
  - Everything committed to journal is recoverable
  - Last committed transaction is fully consistent
  - No torn writes visible after recovery

Cost:
  - Every data write goes to journal THEN to final location: 2× write I/O
  - Journal becomes the bottleneck for write throughput
  - Journal space fills quickly under write-heavy workloads

Use journal mode only when:
  - Absolute data integrity required without application-level fsync
  - Small, critical files (config files, databases that need OS-level guarantee)
  - Journal device is on fast SSD (makes 2× write cost acceptable)
  - NEVER for high-throughput write workloads on slow storage
```

---

## 2. JBD2 Transaction and Checkpoint Architecture

```c
// fs/jbd2/transaction.c

// Transaction states:
// T_RUNNING    — current transaction accepting new operations
// T_LOCKED     — transaction closed, waiting for space
// T_FLUSH      — transaction being written to journal
// T_COMMIT     — transaction commit in progress
// T_COMMIT_DFLUSH — waiting for data flush before commit (ordered mode)
// T_COMMIT_JFLUSH — waiting for journal flush
// T_FINISHED   — committed and checkpointed

// Checkpoint: write modified blocks from journal to their final locations
// Until checkpointed: journal space cannot be reclaimed

jbd2_journal_commit_transaction():
    // Phase 1: Lock transaction, prevent new handles
    // Phase 2: (data=ordered) submit data I/Os, wait for completion
    // Phase 3: Write journal descriptor blocks (list what's being committed)
    // Phase 4: Write journal data blocks (the actual metadata)
    // Phase 5: Write commit block (atomically marks transaction as committed)
    // Phase 6: Unblock next transaction

// The commit block is the atomic durability point:
// If crash before commit block written → transaction not recovered
// If crash after commit block written → transaction recovered fully
```

---

## 3. JBD2 Recovery Process

```bash
# Trigger a recovery (safely)
# After unclean unmount, mount will replay journal automatically
# Observe it with dmesg:
dmesg | grep -E "EXT4|JBD2" | grep -i "recov"
# Example output:
# EXT4-fs (sda1): recovery complete
# EXT4-fs (sda1): mounted filesystem with ordered data mode

# Manual recovery inspection
# (filesystem must be unmounted)
debugfs /dev/sda1 -R "logdump -c" | head -50
# Shows journal contents and recovery status
```

```
JBD2 recovery algorithm:
  1. Read journal superblock → find last valid commit block LSN
  2. Scan journal forward from tail to last commit:
     - For each committed transaction: replay all its blocks to final locations
     - Skip uncommitted transactions (commit block missing)
  3. Journal is now clean → mount proceeds

Key property: idempotent
  If recovery is interrupted (another crash during recovery):
  Just replay again — result is the same
```

---

## 4. Journal Sizing for Production

```bash
# Check current journal size
tune2fs -l /dev/sda1 | grep -i "journal"
dumpe2fs /dev/sda1 | grep "Journal size"

# Default journal size: 128MB (for filesystems >4GB)
# This is often too small for write-heavy workloads

# Resize journal (offline only)
tune2fs -J size=1024 /dev/sda1   # 1GB journal

# External journal on fast device:
tune2fs -J device=/dev/nvme0n1p1 /dev/sda1
# External journal: journal writes don't compete with data I/O on HDD
# Significant win for metadata-heavy workloads

# Signs journal is too small:
# - High commit frequency (check /proc/fs/ext4/sda1/journal*)
# - Journal checkpoint I/O visible in iostat for journal device
# - Metadata operation latency spikes when journal is being committed
```

---

## 5. ext4 Journal Mode: Architect Decision Table

| Scenario | Mode | Reason |
|----------|------|--------|
| Database with O_DIRECT + fsync | writeback | DB manages durability; ordered overhead wasted |
| General purpose application server | ordered | Default; protects against garbage-data exposure |
| NFS server (client data integrity) | ordered or journal | Clients assume server persistence on write return |
| Container image store | ordered | Small writes, need consistency |
| High-throughput log ingestion | writeback | Logs are append-only; no garbage-data risk |
| Critical config/state files | journal | Absolute data+metadata consistency |
| VM image on HDD | ordered | VMs do their own journaling; double-journal ok |

---

## 6. Hands-On: Journal Mode Comparison

```bash
# Setup: compare ordered vs writeback performance and crash behavior

# Create test ext4 filesystems
dd if=/dev/zero of=/tmp/ext4-ordered.img bs=1M count=2048
dd if=/dev/zero of=/tmp/ext4-writeback.img bs=1M count=2048
mkfs.ext4 /tmp/ext4-ordered.img
mkfs.ext4 /tmp/ext4-writeback.img

O_LOOP=$(losetup --find --show /tmp/ext4-ordered.img)
W_LOOP=$(losetup --find --show /tmp/ext4-writeback.img)

mount -o data=ordered  $O_LOOP /mnt/ext4-ordered
mount -o data=writeback $W_LOOP /mnt/ext4-writeback

# Benchmark: metadata-heavy workload
echo "=== ordered ==="
time for i in $(seq 1 10000); do
    echo "data" > /mnt/ext4-ordered/file_$i
done
sync

echo "=== writeback ==="
time for i in $(seq 1 10000); do
    echo "data" > /mnt/ext4-writeback/file_$i
done
sync

# Compare: writeback should be faster due to no data-before-metadata ordering

# Cleanup
umount /mnt/ext4-ordered /mnt/ext4-writeback
losetup -d $O_LOOP $W_LOOP
```

---

## 7. Self-Check Questions

1. In `data=ordered` mode, what exactly is the ordering guarantee and what crash scenario does it prevent?
2. Why can `data=writeback` expose garbage (previously deleted) data after a crash?
3. What is the JBD2 commit block and why is it atomic?
4. A database uses `O_DIRECT` for data and `fsync` after each transaction commit. Which ext4 journal mode would you recommend and why?
5. Your ext4 filesystem has a 128MB journal and shows periodic 200ms write latency spikes. What is likely happening and what would you change?
6. `data=journal` doubles write I/O. On what type of storage does this become acceptable, and why?

## 8. Answers

1. Ordered mode ensures data blocks are written to their final disk locations before the metadata that references them is committed to the journal. This prevents a crash from leaving metadata committed that references unwritten (or garbage-containing) data blocks. The crash scenario it prevents: file appears extended with uninitialized/garbage data in the new portion.
2. In writeback mode, metadata commits happen independently of data writes. Sequence: old file deleted (blocks freed, metadata committed), new file allocated those blocks (metadata committed), data write to new file starts but crashes. After recovery: new file's metadata is committed (file exists, correct size) but data blocks contain old file's data — garbage or sensitive old content.
3. The commit block is a single-sector write containing the transaction ID and checksum. The journal treats a transaction as committed only when this block is written and flushed. Since a sector write is atomic (all or nothing on standard storage), there's no partial commit state — either the commit block is there (transaction committed) or it's not (transaction rolled back).
4. `data=writeback` — the database uses O_DIRECT (bypasses page cache and journal data path entirely) and manages its own data durability with fsync. The ordered guarantee (data written before metadata commit) is irrelevant since O_DIRECT writes go directly to disk. `data=ordered` would add overhead with no benefit. `data=writeback` gives maximum metadata performance.
5. Journal commit I/O. As the 128MB journal fills, JBD2 forces a commit (flush to journal) and checkpoint (write to final locations). These cause periodic I/O spikes. Fix: increase journal to 512MB–1GB with `tune2fs -J size=1024`; or move to external journal on NVMe to remove journal I/O from HDD contention.
6. NVMe SSDs — at 3GB/s+ write throughput, 2× write cost is still fast in absolute terms (1.5GB/s effective). The additional latency from double-writing is hidden by the NVMe's deep internal queue. On HDD (150MB/s), journal mode halves throughput to ~75MB/s effective — unacceptable for most workloads.

---

## Tomorrow: Day 20 — Btrfs: CoW B-tree, Snapshots & Send/Receive

We cover Btrfs's core design: the CoW B-tree (`fs/btrfs/ctree.c`),
subvolume/snapshot mechanics, and the send/receive protocol for
incremental backup and replication.
