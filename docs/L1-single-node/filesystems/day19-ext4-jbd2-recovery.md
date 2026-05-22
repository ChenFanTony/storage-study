# Day 19: ext4 — JBD2 Crash Recovery (Targeted)

## Context
You know ext4 layout and general journaling concepts. This day is targeted:
focus on exactly what JBD2 guarantees under each journal mode, and the
architect-level decisions that follow from those guarantees. Timebox: 2 hours.

---

## Learning Objectives
- Precisely characterize what each JBD2 journal mode guarantees on crash
- Understand JBD2's transaction state machine and checkpoint mechanism
- Know the `data=ordered` guarantee and its subtle edge cases
- Know when to use `data=journal` despite the 2× write overhead
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
What is journaled:     metadata only (inodes, directory blocks, bitmaps)
What is NOT journaled: file data blocks

Crash guarantee:
  - Filesystem STRUCTURE is consistent after recovery
  - File SIZES and TIMESTAMPS are correct
  - File DATA may be:
    a) The new data (write completed)
    b) The old data (write didn't complete)
    c) GARBAGE — old uninitialized blocks that were previously freed and reused
       ← this is the dangerous case (stale data exposure)

Why garbage is possible:
  1. File A deleted → blocks freed
  2. File B created → allocated those same blocks (metadata journaled)
  3. File B data write starts but crashes before completing
  4. After recovery: file B exists (metadata committed),
     data = File A's old data, or zeros, or even older garbage
```

Use writeback only when:
- Application manages its own data integrity (databases with O_DIRECT + fsync)
- Performance is critical and you understand the risk
- Never for untrusted content (security issue: old data exposure to unprivileged users)

### `data=ordered` — metadata journaled, data written before metadata commit

```
What is journaled:    metadata only
What is guaranteed:   data blocks written to disk BEFORE metadata commit

Mechanism:
  1. Write data blocks to disk (not to journal, to final location)
  2. Wait for data writes to complete (the "ordered" dependency)
  3. Commit metadata to journal
  4. Only now is the transaction considered complete

Crash guarantee:
  - Crash before step 3: metadata not committed → recovery sees old state
    file appears truncated/not extended → data is old but consistent
  - Crash after step 3: metadata committed, data was already on disk
    → file has new data, everything consistent
  
  NEVER exposes uninitialized/garbage data (the writeback risk is eliminated)
```

**The subtle edge case ordered mode does NOT protect:**

```
data=ordered protects against garbage in NEW extents.
It does NOT protect against torn writes within an existing extent:

  Write 4KB to offset 0 of an existing file:
    1. Overwrite existing data block (no metadata change — block already allocated)
    2. Crash mid-write
    3. Recovery: metadata unchanged (no journal entry needed)
                 data partially written (half new, half old)
    → Torn write. Ordered mode doesn't help — there was no journal entry to order.
    → Application must use fsync, O_SYNC, or O_DIRECT for in-place data durability.
```

Use ordered (default) for general workloads — any case where the
garbage-data risk of writeback is unacceptable.

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
  - No torn writes visible after recovery (journal write was atomic at commit boundary)

Cost:
  - Every data write goes to journal THEN to final location: 2× write I/O
  - Journal becomes the bottleneck for write throughput
  - Journal space fills quickly under write-heavy workloads
```

Use journal mode only when:
- Absolute data integrity required without application-level fsync
- Small, critical files (config files, low-throughput databases that need OS-level guarantee)
- Journal device is on fast SSD (makes 2× write cost acceptable)
- NEVER for high-throughput write workloads on slow storage

---

## 2. JBD2 Transaction and Checkpoint Architecture

```c
// fs/jbd2/transaction.c — JBD2 transaction state machine

// Transaction states (from include/linux/jbd2.h):
// T_RUNNING        — current transaction accepting new operations
// T_LOCKED         — transaction closed, waiting for handles to complete
// T_FLUSH          — transaction being written to journal
// T_COMMIT         — transaction commit in progress
// T_COMMIT_DFLUSH  — waiting for data flush before commit (ordered mode)
// T_COMMIT_JFLUSH  — waiting for journal flush
// T_FINISHED       — committed and checkpointed

// At any time, the journal has:
//   - One T_RUNNING transaction (accepting modifications)
//   - Zero or one T_COMMIT-state transaction (being committed)
//   - Some number of T_FINISHED transactions waiting for checkpoint

// The core commit function:
jbd2_journal_commit_transaction(journal):
    // Phase 1: Lock transaction (T_RUNNING → T_LOCKED)
    //          prevent new handles from joining
    // Phase 2: (data=ordered) Submit data I/Os to final locations
    //          wait for completion (this is the ordered dependency)
    // Phase 3: Write journal descriptor blocks
    //          (lists what blocks are being committed)
    // Phase 4: Write journal data blocks
    //          (the actual metadata, or data+metadata in data=journal)
    // Phase 5: Write commit block (atomically marks transaction as committed)
    //          ← THE DURABILITY POINT — single sector write
    // Phase 6: Unblock next transaction
```

**The commit block is the atomic durability point:**

```c
// fs/jbd2/commit.c

// Phase 5: write the commit block
journal_submit_commit_record():
    // Allocate a buffer for the commit block
    // Fill in: transaction ID, checksum, magic number
    // Submit as a single bio with REQ_PREFLUSH | REQ_FUA
    // → device guarantees this write is durable before ack
    //
    // If crash before this bio completes:  transaction NOT recovered
    // If crash after this bio completes:   transaction fully recovered
```

A sector write is atomic on standard storage — either the entire sector is
the new content or the entire sector is the old content, never partially
updated. JBD2 relies on this: the commit block flips a transaction from
"in-progress" to "committed" with a single atomic write.

---

## 3. JBD2 Recovery Process

When ext4 mounts a filesystem with a dirty journal, JBD2 runs recovery:

```c
// fs/jbd2/recovery.c

jbd2_journal_recover(journal):
    // Three-pass recovery:

    // PASS_SCAN: walk journal forward, find latest valid commit
    //            (identifies how much to replay)
    jbd2_journal_skip_recovery() ; do_one_pass(journal, PASS_SCAN)

    // PASS_REVOKE: walk journal again, build list of revoked blocks
    //              (blocks that were freed and shouldn't be replayed)
    do_one_pass(journal, PASS_REVOKE)

    // PASS_REPLAY: walk journal a third time, replay committed transactions
    //              for each block in each committed transaction:
    //                if not revoked: write block from journal to final location
    do_one_pass(journal, PASS_REPLAY)
```

**Why three passes?**
The scan pass determines the valid range. The revoke pass identifies blocks
that should not be replayed (e.g., a block that was metadata, then freed and
reused as data — replaying the metadata image would corrupt the data block).
The replay pass actually applies changes.

**Recovery is idempotent:**
```
If recovery is interrupted (another crash during recovery):
  Just replay again — same input → same output.
  No state machine in the on-disk journal; the journal itself is the state.
```

```bash
# Observe recovery via dmesg after unclean shutdown
dmesg | grep -E "EXT4|JBD2" | grep -i "recov"
# EXT4-fs (sda1): recovery complete
# EXT4-fs (sda1): mounted filesystem with ordered data mode

# Manual recovery inspection (filesystem unmounted)
debugfs /dev/sda1 -R "logdump -c" | head -50
# Shows journal contents and which transactions exist
```

---

## 4. Checkpoint: When Journal Blocks Get Freed

A transaction is "committed" once the commit block is written, but the
journal blocks aren't reusable until **checkpoint** completes:

```c
// fs/jbd2/checkpoint.c

// Checkpoint: copy blocks from journal to final locations on disk
//             then free the journal space they occupied

__jbd2_journal_clean_checkpoint_list(journal):
    // Walk committed transactions
    // For each: check if all its journaled blocks have been written to final locations
    // If yes: remove from checkpoint list, free journal space

// Triggered by:
//   - Background thread (jbd2/sdaN-8 kernel thread)
//   - Journal space pressure (running out of space)
//   - Explicit flush (sync, unmount)
```

**Implication:** journal blocks remain occupied between commit and checkpoint.
If checkpoint is slow (slow disk, many dirty blocks), journal fills up even
though transactions are committed.

```bash
# Watch the JBD2 kernel thread for a device
ps aux | grep jbd2
# root  ...  [jbd2/sda1-8]   ← the checkpoint thread for /dev/sda1

# Per-filesystem JBD2 stats
cat /proc/fs/jbd2/sda1-8/info
# Shows:
#   N transactions, each up to M blocks
#   average commit time, max commit time
#   average / max transaction lifetime
```

---

## 5. Journal Sizing for Production

```bash
# Check current journal size
tune2fs -l /dev/sda1 | grep -i "journal"
dumpe2fs /dev/sda1 | grep "Journal size"

# Default journal size depends on FS size:
#   < 128MB FS:     no journal possible (use ext2)
#   < 4GB:          16MB journal
#   < 128GB:        64MB journal
#   ≥ 128GB:       1024MB journal (capped)

# Default is often too small for write-heavy workloads.
# Symptoms of undersized journal:
#   - Frequent jbd2 commit activity in iostat
#   - Write latency spikes correlated with journal commits
#   - "JBD2: barrier-based sync failed" in dmesg (different problem but related)

# Resize journal (offline only)
e2fsck -f /dev/sda1
tune2fs -O ^has_journal /dev/sda1      # remove old journal
tune2fs -J size=1024 /dev/sda1         # create 1GB journal

# External journal on separate fast device
mke2fs -O journal_dev /dev/nvme0n1p1   # create journal device
tune2fs -J device=/dev/nvme0n1p1 /dev/sda1
# External journal: journal writes don't compete with data writes on the HDD
# Significant win when data is on slower storage
```

---

## 6. The `commit` Mount Option: Trade Durability for Throughput

```bash
mount -o commit=5  /dev/sda1 /mnt/ext4   # default — commit every 5 sec
mount -o commit=30 /dev/sda1 /mnt/ext4   # commit every 30 sec
mount -o commit=1  /dev/sda1 /mnt/ext4   # commit every 1 sec (high overhead)
```

`commit=N` controls the maximum time between journal commits.

```
Lower commit interval (commit=1):
  + Less data lost on crash (up to 1 sec)
  - More journal I/O (commits more often)
  - More frequent latency spikes (commit pauses)

Higher commit interval (commit=30):
  + Less journal I/O overhead
  + Better throughput
  - Up to 30 sec of recent transactions lost on crash
```

`fsync()` is independent of this setting — fsync forces an immediate commit
regardless of the commit interval. The interval only governs background
commits (for transactions that no one explicitly synced).

---

## 7. `journal_async_commit`: For When the Commit Block Is the Bottleneck

```bash
mount -o data=ordered,journal_async_commit /dev/sda1 /mnt/ext4
```

Normally, JBD2 commit phase 5 (write commit block) uses a FUA write that
must complete before the transaction is considered committed. On slow
storage with high commit rates, the commit block writes become the
bottleneck.

`journal_async_commit` allows the commit block to be written without FUA,
relying on a subsequent flush to ensure durability. This relaxes
ordering and trades some crash-recovery robustness for better throughput
on slow storage. Use only on stable storage with battery-backed write
caches; risky on consumer SSDs.

---

## 8. ext4 Journal Mode: Architect Decision Table

| Scenario | Mode | Reason |
|----------|------|--------|
| PostgreSQL with O_DIRECT + fsync | `writeback` | DB manages durability; ordered overhead wasted |
| MySQL/InnoDB with O_DIRECT | `writeback` | Same reasoning |
| General-purpose application server | `ordered` | Default; protects against stale data exposure |
| NFS server export | `ordered` | Clients assume server persistence; stale data unacceptable |
| Container image store | `ordered` | Small writes; can't tolerate stale data |
| High-throughput log ingestion (append-only) | `writeback` | Logs are append-only; no garbage-data risk |
| Critical config files, low-throughput | `journal` | Absolute data+metadata consistency |
| VM image on HDD | `ordered` | VMs do their own journaling; double-journal harmless |
| Email maildir | `ordered` | Many small files; stale-data exposure unacceptable |

---

## 9. Hands-On: Journal Mode Comparison

```bash
# Compare metadata-heavy throughput across modes

# Create test ext4 filesystems
for mode in ordered writeback; do
    dd if=/dev/zero of=/tmp/ext4-${mode}.img bs=1M count=2048
    mkfs.ext4 -F /tmp/ext4-${mode}.img
done

O_LOOP=$(losetup --find --show /tmp/ext4-ordered.img)
W_LOOP=$(losetup --find --show /tmp/ext4-writeback.img)

mkdir -p /mnt/ext4-ordered /mnt/ext4-writeback
mount -o data=ordered   $O_LOOP /mnt/ext4-ordered
mount -o data=writeback $W_LOOP /mnt/ext4-writeback

# Benchmark: 10000 small file creates
echo "=== ordered ==="
time (
    for i in $(seq 1 10000); do
        echo "data" > /mnt/ext4-ordered/file_$i
    done
    sync
)

echo "=== writeback ==="
time (
    for i in $(seq 1 10000); do
        echo "data" > /mnt/ext4-writeback/file_$i
    done
    sync
)

# Expected: writeback faster (no data-before-metadata ordering)
# Magnitude depends on storage speed — large on HDD, small on NVMe

# Cleanup
umount /mnt/ext4-ordered /mnt/ext4-writeback
losetup -d $O_LOOP $W_LOOP
rm /tmp/ext4-ordered.img /tmp/ext4-writeback.img
```

---

## 10. Source Reading Checklist

```
fs/jbd2/transaction.c   — transaction state machine
fs/jbd2/commit.c        — jbd2_journal_commit_transaction()
fs/jbd2/recovery.c      — three-pass recovery
fs/jbd2/checkpoint.c    — checkpoint and journal block reclaim
fs/jbd2/journal.c       — journal lifecycle, format

fs/ext4/ext4_jbd2.h     — ext4's JBD2 interface
fs/ext4/inode.c         — where ordered-mode data is registered
                           (ext4_jbd2_inode_add_write — adds inode to
                            the transaction's ordered-mode inode list)
```

Reading order: `transaction.c` first (state machine), then `commit.c`
(the commit sequence with phases 1-6), then `recovery.c`. Recovery
is the most instructive — three passes show why journal format is what
it is.

---

## 11. Self-Check Questions

1. In `data=ordered` mode, what exactly is the ordering guarantee and what crash scenario does it prevent?
2. Why can `data=writeback` expose garbage (previously deleted) data after a crash?
3. What is the JBD2 commit block and why is its atomicity critical?
4. A database uses `O_DIRECT` for data and `fsync` after each transaction commit. Which ext4 journal mode would you recommend and why?
5. Your ext4 filesystem has a 128MB journal and shows periodic 200ms write latency spikes. What is likely happening and what would you change?
6. `data=journal` doubles write I/O. On what type of storage does this become acceptable, and why?
7. What does JBD2 recovery do across its three passes (SCAN, REVOKE, REPLAY) and why are three passes needed?

## 12. Answers

1. Ordered mode ensures data blocks are written to their final disk locations before the metadata that references them is committed to the journal. This prevents a crash from leaving metadata committed that references unwritten (or garbage-containing) data blocks. The scenario it prevents: a file appears extended/created with new metadata, but the underlying data blocks contain stale or uninitialized content from previously-freed blocks.
2. In writeback mode, metadata commits happen independently of data writes (no ordering enforced). Sequence: old file deleted (blocks freed, metadata committed), new file allocated those blocks (metadata committed), data write to new file starts but crashes. After recovery: new file's metadata is committed (file exists, correct size) but the data blocks still contain old file's data — exposing what was previously deleted.
3. The commit block is a single-sector write at the end of a transaction's journal records, containing the transaction ID, descriptor magic, and a checksum. Its atomicity is critical because sector writes are atomic on storage devices — the sector is either entirely the new content or entirely the old. JBD2 uses this as a single-bit "transaction committed?" flag: if the commit block exists with the correct transaction ID, the transaction is recovered; otherwise it's discarded.
4. `data=writeback` — the database uses O_DIRECT (bypasses page cache entirely) and manages its own data durability with fsync. The ordered guarantee (data written before metadata commit) is irrelevant since O_DIRECT writes go directly to disk on their own schedule, and the database's WAL provides its own consistency. `data=ordered` would add overhead with no benefit. `data=writeback` gives maximum metadata performance.
5. Journal commit I/O. As the 128MB journal fills, JBD2 forces a commit (flush to journal) and eventually a checkpoint (write modified blocks to final locations). These bursts cause periodic I/O spikes visible as latency stalls. Fix: increase journal to 512MB–1GB with `tune2fs -J size=1024` (after `tune2fs -O ^has_journal`); or move to external journal on NVMe (`tune2fs -J device=/dev/nvmeXn1pY`) to remove journal I/O from the data device's queue.
6. NVMe SSDs — at 3GB/s+ write throughput, 2× write cost is still fast in absolute terms (1.5GB/s effective for application). The additional latency from double-writing is hidden by the NVMe's deep internal queue and absorbed by typical workload patterns. On HDD (150MB/s), journal mode halves throughput to ~75MB/s effective, which is unacceptable for most workloads.
7. SCAN: walks the journal forward to find the latest valid commit block — establishes the range of transactions to consider. REVOKE: walks the journal again to build a list of revoked blocks (blocks that were metadata but later freed; replaying their old metadata images would corrupt subsequent uses). REPLAY: walks a third time, applying each committed block from the journal to its final on-disk location, skipping blocks on the revoke list. Three passes are needed because revoke information appears throughout the journal and must be fully collected before replay can correctly skip revoked blocks.

---

## Tomorrow: Day 20 — Btrfs: CoW B-tree, Snapshots & Send/Receive

We cover Btrfs's core design: the CoW B-tree (`fs/btrfs/ctree.c`),
subvolume/snapshot mechanics, and the send/receive protocol for
incremental backup and replication.
