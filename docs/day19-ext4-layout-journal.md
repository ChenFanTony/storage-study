# Day 19: ext4 — Layout & Journal

## Learning Objectives
- Understand ext4 on-disk layout and block-group organization
- Learn the role of ext4 superblock, group descriptors, and inode tables
- Understand JBD2 journal transaction flow and recovery model
- Practice inspecting ext4 metadata with `dumpe2fs` and `debugfs`

---

## 1. ext4 Big Picture

ext4 is a journaling filesystem designed for reliability and good general-purpose performance.

Core ideas:
- Disk is divided into **block groups** for locality
- Metadata is structured with superblock + group descriptors + inode tables + bitmaps
- Metadata updates are journaled through **JBD2** before being checkpointed to home locations

---

## 2. Block Group Layout

A simplified ext4 layout:

```text
Disk
┌───────────────────────────────────────────────────────────────┐
│ Group 0  │ Group 1  │ Group 2  │ ...                         │
└───────────────────────────────────────────────────────────────┘

Each block group typically contains:
- Block bitmap      (which data blocks are free/used)
- Inode bitmap      (which inodes are free/used)
- Inode table       (inode records)
- Data blocks       (file/dir contents)
```

Why groups matter:
- Keep related metadata/data close
- Reduce seek overhead (especially historically important on HDD)
- Improve allocator efficiency

---

## 3. Superblock and Group Descriptors

### Superblock
The ext4 superblock stores filesystem-wide parameters such as:
- block size
- total blocks / free blocks
- total inodes / free inodes
- feature flags (compat/incompat/ro-compat)
- UUID, mount/check info

Primary superblock is near filesystem start; backup superblocks may exist in selected groups.

### Group descriptors
Each block group has a descriptor that records locations of:
- block bitmap
- inode bitmap
- inode table
- per-group counters and flags

---

## 4. Inodes and Directories in ext4

Inode stores metadata (not filename):
- mode/permissions, owner
- timestamps
- size
- block mapping metadata (extents for modern ext4)

Directory entries map:
- filename → inode number

So pathname resolution goes through directory entries, then inode lookup.

---

## 5. JBD2 Journaling Model

ext4 journaling uses **JBD2** (Journaling Block Device v2), mostly for metadata consistency.

High-level flow:

```text
metadata update intent
  -> join current transaction
  -> write journal descriptors + data blocks + commit record
  -> once committed, transaction is durable in journal
  -> later checkpoint writes metadata to home location
```

Key benefit:
- After crash, replay committed journal transactions to restore consistent metadata state

---

## 6. Transaction Lifecycle (Conceptual)

1. **Handle start**: filesystem code reserves journal credits
2. **Modify metadata buffers** under journal control
3. **Close handle** when operation done
4. **Commit thread** writes transaction to journal with commit block
5. **Checkpoint** eventually writes metadata to home blocks

Crash semantics:
- Committed transaction in journal → recoverable by replay
- Uncommitted transaction → discarded

---

## 7. Journaling Modes (Important)

Common ext4 data modes:
- `data=ordered` (typical default): data blocks flushed before related metadata commit exposure
- `data=writeback`: weaker ordering, potentially higher performance, weaker post-crash data semantics
- `data=journal`: both data and metadata journaled (stronger consistency, more overhead)

Understand your mode before interpreting durability/performance behavior.

---

## 8. Recovery Process After Crash

On mount after unclean shutdown:
- ext4 detects journal needs recovery
- JBD2 scans journal for committed transactions
- replays those transactions
- filesystem reaches consistent metadata state quickly without full fsck in most cases

Journal replay is why ext4 recovery is usually fast compared to non-journaled designs.

---

## 9. Hands-On Exercises

### Exercise 1: Create and inspect ext4 filesystem
```bash
# Example on loop device or test disk only
sudo mkfs.ext4 /dev/loop2
sudo dumpe2fs -h /dev/loop2
```

Check key fields:
- block size
- inode count
- features
- journal info

### Exercise 2: View block-group details
```bash
sudo dumpe2fs /dev/loop2 | less
```

Look for per-group:
- block bitmap location
- inode bitmap location
- inode table location

### Exercise 3: Inspect inode metadata
```bash
sudo mkdir -p /mnt/ext4test
sudo mount /dev/loop2 /mnt/ext4test
echo "hello" | sudo tee /mnt/ext4test/a.txt
sudo debugfs -R "stat /a.txt" /dev/loop2
```

### Exercise 4: Directory entry inspection
```bash
sudo debugfs -R "ls -l /" /dev/loop2
```

Observe filename-to-inode mapping.

### Exercise 5: Journal info check
```bash
sudo tune2fs -l /dev/loop2 | grep -Ei "journal|features|Filesystem state"
```

### Exercise 6: Source navigation
```bash
grep -rn "ext4_fill_super\|ext4_put_super" fs/ext4/super.c | head -20
grep -rn "jbd2\|journal" fs/ext4/ fs/jbd2/ | head -40
```

---

## 10. Source Navigation Checklist

Primary:
- `fs/ext4/super.c`
- `fs/ext4/inode.c`
- `fs/jbd2/`

Useful supporting files:
- `fs/ext4/namei.c` (directory ops)
- `fs/ext4/extents.c` (extent mapping)
- `include/linux/jbd2.h`

---

## 11. Common Pitfalls

1. Assuming journaling always covers file data
   - often metadata-focused unless `data=journal`

2. Confusing journal commit with checkpoint completion
   - commit makes transaction durable in journal
   - checkpoint writes to final home location later

3. Ignoring mount mode when evaluating crash behavior
   - `ordered` vs `writeback` changes guarantees

4. Testing on production disks
   - always use loop devices or disposable test volumes for experiments

---

## 12. Self-Check Questions

1. What are the main structures inside an ext4 block group?
2. What does JBD2 provide to ext4?
3. What is the difference between journal commit and checkpoint?
4. Which journaling mode journals both data and metadata?
5. Why is post-crash recovery usually quick on ext4?

## 13. Self-Check Answers

1. Block bitmap, inode bitmap, inode table, and data blocks.
2. Transactional journaling for metadata consistency and crash recovery.
3. Commit records transaction durably in journal; checkpoint writes metadata to home blocks.
4. `data=journal`.
5. Because committed transactions are replayed from journal instead of scanning whole filesystem in most cases.

---

## 14. Tomorrow’s Preview: Day 20 — ext4 Extents & Delayed Allocation

Next we focus on ext4 allocation strategy:
- extent tree structure
- delayed allocation (`delalloc`)
- fragmentation behavior and `filefrag` analysis.
