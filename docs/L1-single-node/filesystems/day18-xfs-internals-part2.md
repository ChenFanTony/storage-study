# Day 18: XFS Internals Part 2 — Log, Delayed Allocation, Reflink

## Learning Objectives
- Understand XFS's delayed-logging architecture: CIL, checkpoints, log force
- Understand delayed allocation and why it produces low fragmentation
- Understand reflink (COW snapshots) and its on-disk implementation
- Know how the log force interacts with fsync latency
- Know the production tuning knobs and their trade-offs

---

## 1. The XFS Log, Briefly

Like ext4's JBD2, XFS has a journal — but the implementation philosophy is
quite different.

**JBD2 (ext4):** Block-oriented physical journaling. The journal stores
images of modified metadata blocks. On replay: read each block image from
the journal, write it to its final on-disk location.

**XFS log:** Logical, item-oriented journaling. The log stores "log items"
that describe individual changes (e.g., "this inode's i_size changed to
X"). On replay: walk the log, apply each item to its target structure.

The XFS approach is more compact (a small log item replaces a whole
modified block image) and supports a critical optimization: **the same
item can be modified many times before it's written to the log**, with
only the final state ending up on disk. This is "delayed logging,"
introduced in 2010.

---

## 2. The Committed Item List (CIL)

When a transaction commits, XFS doesn't write to the log immediately.
Instead, the modified log items are inserted into the in-memory
**Committed Item List (CIL)**. If an item is modified again before the
CIL is flushed, the existing CIL entry is updated in place — no extra
log write.

```
Application: many threads, each doing transactions:
   transaction 1: modify inode X (commit → CIL)
   transaction 2: modify inode X again (commit → in-place update CIL entry)
   transaction 3: modify inode Y (commit → CIL)
   ...

When CIL accumulates enough work, or when something forces a log write:
   → CIL is "pushed": entries are formatted into log records and written
     to the on-disk log as a single checkpoint
```

The key insight: **a hot metadata item (often-modified directory, inode in
heavy use) appears in the CIL exactly once between checkpoints, no matter
how many transactions touched it.** A workload modifying a single file
1000 times produces 1 checkpoint write of that inode, not 1000.

This is why XFS scales so well on metadata-heavy parallel workloads. As
documented in the kernel: "the current transaction commit code does not
break down even when there are transactions coming from 2048 processors
at once."

### When does the CIL push?

The CIL is pushed in these cases:
- **Size threshold:** CIL grows beyond a fraction of total log space —
  prevents one checkpoint from being too big to fit
- **Idle:** xfssyncd periodic log force (every 30s by default)
- **`fsync()`:** caller asked for durability; force the CIL to disk
- **Memory pressure:** kernel needs the memory the CIL items hold

```bash
# Look at log layout
xfs_info /mnt/xfs | grep log
# log = internal log bsize=4096 blocks=521728, version=2

# A 2GB log can hold a lot of CIL state — XFS sizes log automatically based on FS size
```

---

## 3. fsync() and the Log Force

This is where the architect-relevant interaction lives:

```
fsync(fd) on XFS:
  1. Ensure data pages for this file are flushed to disk
     (just like any FS)
  2. Force a CIL push covering this file's metadata changes
  3. Wait for the log writes to complete (with FUA/FLUSH so they're durable)
  4. Return to caller
```

Step 2 is the XFS-specific piece. A single `fsync()` may push CIL state
that includes many other files' metadata changes that happen to be in
the CIL at the time. This is the **shared fsync** behavior: a process
calling fsync on its file effectively durability-confirms other processes'
metadata changes too. Usually a feature; occasionally surprising.

```bash
# Watch log activity
xfs_io -c "stat" /mnt/xfs   # per-file
# Or globally:
grep -E "xs_log_writes|xs_log_blocks" /proc/fs/xfs/stat
# xs_log_writes: total log write operations
# xs_log_blocks: total blocks written to log

# Monitor in real time:
watch -n1 "grep xs_log /proc/fs/xfs/stat"
```

### Tuning for fsync latency

The default log is sized generously, which is what you want. The main
tunable that matters is `logbsize` (in-memory log buffer size):

```bash
mount -o remount,logbsize=256k /mnt/xfs
# Larger buffer = more CIL absorbed per checkpoint = less frequent log I/O
# But: larger memory footprint, and fsync waits longer for the next checkpoint

mount -o remount,logbufs=8 /mnt/xfs
# More log buffers = more in-flight checkpoints = more concurrency
```

For most production: defaults are fine. Touch these only if profiling
shows the log as the bottleneck.

---

## 4. Delayed Allocation

XFS doesn't allocate physical blocks at `write()` time. Instead:

```
write(fd, buf, 4096) on XFS:
  1. Reserve space (decrement free-block counter)
  2. Mark pages dirty in the page cache with a "delalloc" tag
  3. Return to caller
  → No physical block number assigned yet!

Later, when writeback fires (flusher thread):
  1. Look at all consecutive dirty pages for this inode
  2. Allocate a contiguous physical extent for the whole range
  3. Submit the bio
```

Why this matters:

- **Small writes coalesce into large extents.** A program writing 4K at a
  time, 1000 times sequentially, gets ONE big extent (4MB), not 1000 tiny ones.
- **Block allocation patterns are workload-aware.** XFS sees how big the
  write turned out to be before deciding where to put it.
- **Fewer fragmented files than ext4.** Default ext4 also has delalloc, but
  XFS's implementation is more aggressive about extent coalescing.

The cost: between `write()` and writeback, the data lives in the page
cache without a permanent disk location. After a crash, anything not yet
written back is lost — same as any buffered I/O — but the *space reservation*
also exists only in memory. XFS uses a small fudge factor in free-space
accounting to avoid claiming space it can't actually allocate.

```bash
# Check fragmentation
xfs_db -r -c "frag -f" /dev/sda1
# actual 12345, ideal 1234, fragmentation factor 90.00%
# (higher = more fragmented; ideally close to 0%)

# Free-space fragmentation
xfs_db -r -c "freesp" /dev/sda1
# Shows histogram of free-extent sizes
```

### Delayed allocation and ENOSPC

A subtle production issue: because allocation happens at writeback time,
`write()` can succeed with apparent free space, but writeback can fail
with ENOSPC if that space was concurrently consumed. XFS prevents this
in the common case via reservation, but corner cases exist (quota
exhaustion is the usual culprit).

---

## 5. Speculative Preallocation

XFS adds another layer: when writing to a growing file, it speculatively
preallocates extra extent past the current write point, in anticipation
of more writes coming.

```
First write to a growing file:
  app writes 100KB
  XFS allocates 100KB for the write + preallocates extra (e.g., +1MB)
  → next several appends use the preallocated space → one large extent
```

The preallocation is released on file close if unused, so this isn't
visible space waste. But it's the reason `du` and `df` can briefly
disagree on disk usage — preallocated-but-unused space still counts
against free blocks until the file is closed or `xfs_io fsx --punch`'d.

```bash
# View preallocation behavior
xfs_io -c "stat" /path/to/file
# stat.blocks shows allocated blocks (includes preallocation)
# stat.size shows logical file size

# Tune preallocation behavior
mount -o allocsize=64k /mnt/xfs     # smaller preallocation
mount -o allocsize=64m /mnt/xfs     # larger preallocation
# Default is dynamic, based on file size
```

---

## 6. Reflink: Copy-on-Write Snapshots

Reflink is XFS's COW mechanism, introduced as production-ready in kernel 4.16.
Two files can share the same physical extents until one of them writes —
at which point only the modified extent is copied.

```
Original state:
  file_A: extent at block 1000, size 10MB
  file_B is reflink of file_A:
  file_A's mapping: 1000 → 10MB
  file_B's mapping: 1000 → 10MB    (same physical blocks; refcount=2)

After: write to file_A offset 1MB
  XFS allocates new blocks for the modified range
  file_A's mapping: 1000–1MB (refcount=2) + new blocks (refcount=1)
  file_B's mapping: 1000 → 10MB (refcount adjusted)
  Only the modified extent was actually copied
```

This requires the **refcount B+tree** (refcntbt) per AG, which tracks
reference counts for every shared physical extent. XFS v5 with reflink
support is required.

```bash
# Check if reflink is enabled on a filesystem
xfs_info /mnt/xfs | grep -i reflink
# or
xfs_db -r -c "version" /dev/sda1 | grep -i REFLINK

# Enable at mkfs time (default since xfsprogs 5.1)
mkfs.xfs -m reflink=1 /dev/sda1

# Create a reflink
cp --reflink=always source.img copy.img
# Verify they share blocks:
xfs_io -c "fiemap -v" copy.img
# Look for SHARED flag in the extent list
```

### Production uses for reflink

- **VM image snapshots.** Clone a 100GB VM image instantly; pay for blocks
  only as the clone diverges.
- **Test environments.** Many test runs share a base dataset.
- **Backup.** `cp --reflink=auto` between filesystem and backup destination
  on the same XFS gives free deduplication.

### Reflink and the GC problem

Unlike Btrfs's COW, XFS reflink doesn't have a garbage collector — extents
are freed by ordinary refcount drops. The refcount btree per-AG keeps this
local. Performance scales well; there's no equivalent of Btrfs's "subvolume
delete is slow because reference walking takes forever" problem.

---

## 7. Hands-On: Observe Delayed Logging and Allocation

```bash
# Setup
mkdir -p /mnt/xfs-test
mount /dev/loop0 /mnt/xfs-test     # assume an XFS loop is already there

# Snapshot the log counters
grep xs_log /proc/fs/xfs/stat > /tmp/log_before

# Create many small files (heavy metadata)
for i in $(seq 1 10000); do
    touch /mnt/xfs-test/file_$i
done
sync

# Log counters after
grep xs_log /proc/fs/xfs/stat > /tmp/log_after

# Compare: how many log writes did 10000 file creations take?
diff /tmp/log_before /tmp/log_after
# Expect: log writes much smaller than file count — CIL absorbed many updates
```

```bash
# Delayed allocation in action
xfs_io -c "open -f -t /mnt/xfs-test/delalloc_demo" \
       -c "pwrite 0 4k"   \
       -c "stat"          \
       -c "fsync"         \
       -c "stat"

# First stat: shows blocks (preallocated/delalloc)
# After fsync: shows actual on-disk block range

# Or see delalloc state directly:
xfs_io -c "fiemap" /mnt/xfs-test/delalloc_demo
# Pre-fsync: extents marked DELALLOC
# Post-fsync: extents have real block numbers
```

```bash
# Reflink demo
xfs_io -c "open -f /mnt/xfs-test/big.dat" \
       -c "pwrite 0 100M"                  \
       -c "fsync"

cp --reflink=always /mnt/xfs-test/big.dat /mnt/xfs-test/big_clone.dat
du -sh /mnt/xfs-test/*.dat
df -h /mnt/xfs-test
# Two 100MB files; df shows only ~100MB used (shared)

xfs_io -c "fiemap -v" /mnt/xfs-test/big_clone.dat | head -5
# Look for "shared" or "0x2000" flag on extents
```

---

## 8. Production Tuning Reference

| Knob | When to use | Notes |
|------|-------------|-------|
| `logbsize=256k` | High-fsync workload (databases) | Larger log buffer = better aggregation |
| `logbufs=8` | Highly concurrent metadata workload | More in-flight log buffers |
| `allocsize=64m` | Big sequential file workloads | Larger preallocation reduces fragmentation |
| `inode64` (default) | Always | Spreads inodes across all AGs |
| `noatime` | Most workloads | Skips updating access times |
| `nobarrier` | DON'T (deprecated since 4.10) | The barrier semantics are always on now |
| `discard` | SSDs without periodic fstrim | Inline TRIM; can hurt write latency |

For databases specifically:
- Use `O_DIRECT` for data files: bypasses delalloc, predictable allocation
- WAL: buffered writes + fsync. XFS log force is the path that matters here.
- Match XFS's stripe alignment to underlying RAID: `mkfs.xfs` auto-detects md;
  for other RAID, pass `-d su=,sw=` explicitly

---

## 9. Source Reading Checklist

```
fs/xfs/xfs_log.{c,h}            # log infrastructure
fs/xfs/xfs_log_cil.c            # the CIL implementation — central to scalability
fs/xfs/libxfs/xfs_log_recover.c # log replay (mount-time recovery)
fs/xfs/xfs_iomap.c              # delayed allocation paths
fs/xfs/libxfs/xfs_bmap.c        # extent map operations
fs/xfs/libxfs/xfs_refcount.c    # reflink refcount btree
fs/xfs/xfs_reflink.c            # high-level reflink operations
```

Read `Documentation/filesystems/xfs-delayed-logging-design.rst` (in the
kernel source). It's one of the best-written kernel design documents and
explains the CIL in depth.

---

## 10. Self-Check Questions

1. What is the CIL and what scalability property does it provide?
2. Why does `fsync()` on one file potentially cause log writes covering many files?
3. What is "delayed allocation" and what fragmentation benefit does it produce?
4. A program writes 1MB to a new file in 256 separate 4K `write()` calls, then closes the file. How many extents does the file end up with on XFS, and why?
5. What does XFS's reflink store on-disk that makes COW snapshots cheap?
6. Why is `mount -o nobarrier` deprecated, and what is the modern equivalent?

## 11. Answers

1. The Committed Item List is an in-memory list of log items modified by committed transactions but not yet written to the on-disk log. Its key property: if an item is modified again before checkpoint, the existing CIL entry is updated in place. So a hot metadata item appears in the log exactly once per checkpoint regardless of how many transactions touched it — making metadata throughput scale linearly with CPU count instead of hitting a single-item bottleneck.
2. fsync forces a CIL push. The CIL contains all metadata changes from all concurrent transactions, not just those of the calling process. The whole batch gets durability-confirmed together. (Data writes for the specific file are separately flushed; metadata pushes share with the rest of the CIL.)
3. Allocation happens at writeback time, not write time. XFS sees the full extent of dirty pages before assigning physical blocks, so consecutive small writes get one large contiguous extent rather than many small ones. Fragmentation drops dramatically vs. allocate-immediately schemes.
4. Typically 1 extent. The 256 writes accumulate in the page cache as dirty pages with a delalloc tag. When writeback fires (or fsync, or close), XFS sees a contiguous dirty range and allocates one extent for the entire 1MB.
5. The refcount B+tree (refcntbt), one per AG. It tracks per-physical-extent reference counts. When two files share an extent, both inodes' mappings point at the same physical blocks and the refcount is ≥ 2. On write, XFS allocates a new extent for the modified range and decrements the refcount on the shared one.
6. `nobarrier` was a way to disable forced cache flushes on barrier writes for performance. Modern XFS (since 4.10) always uses cache flushes correctly via FUA/FLUSH bios; there's no "barrier" abstraction to disable. The option still parses but does nothing. If you previously used `nobarrier` for performance, the modern path is hardware with capacitor-backed write cache so the device honors FUA cheaply.

---

## Tomorrow: Day 19 — ext4: JBD2 Crash Recovery (Targeted)

One focused day on what JBD2 actually guarantees under each journal mode,
and the architect-level decisions that follow from those guarantees.
