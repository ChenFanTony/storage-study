# Day 16: md/RAID — Partial-Stripe Writes, Bitmaps, and the Write Hole

## Learning Objectives
- Understand the RAID-5/6 partial-stripe write problem and why it matters more than people think
- Understand the write hole and the three md mechanisms that close it (raid5-cache, PPL, write-intent bitmap)
- Know how md's stripe cache interacts with the block-layer plug
- Be able to size, tune, and reason about RAID-5/6 in production
- Know when to use which redundancy mechanism

---

## 1. The RAID-5/6 Architecture, Briefly

```
RAID-5 (4 disks, chunk size 64KB):

         disk0       disk1       disk2       disk3
stripe 0 [data A0]   [data A1]   [data A2]   [parity Ap]
stripe 1 [data B0]   [data B1]   [parity Bp] [data B3]
stripe 2 [data C0]   [parity Cp] [data C2]   [data C3]
stripe 3 [parity Dp] [data D1]   [data D2]   [data D3]
                                              ^
                                  parity rotates across stripes
```

Each stripe is `(N-1) × chunk_size` of data plus one chunk of parity.
The parity location rotates so no single disk becomes a bottleneck for parity writes.

Stripe size matters: with chunk_size=64K and 4 disks, one full stripe = 192K
of data + 64K parity. RAID-6 has two parity chunks per stripe.

---

## 2. The Partial-Stripe Write Problem

This is the single most important performance fact about RAID-5/6:

### Full-stripe write (the good case)
The caller writes data covering an entire stripe. md can compute parity from
the new data alone:
```
new_parity = data0 XOR data1 XOR data2
```
Cost: 1 read of nothing, N writes (data + parity). Optimal.

### Partial-stripe write (the problem)
The caller writes only part of a stripe. md must compute new parity, but it
doesn't have the unmodified blocks in memory. Two strategies:

**Read-Modify-Write (RMW):** read the old data being overwritten + the old parity:
```
new_parity = old_parity XOR old_data XOR new_data
```
Cost: 2 reads + 2 writes for one small write. **4× I/O amplification**.

**Reconstruct-Write:** read ALL the unmodified data chunks in the stripe:
```
new_parity = new_data XOR unmodified_data_0 XOR unmodified_data_1 ...
```
Cost: (N-2) reads + 2 writes. Worse when N is large.

md picks whichever has fewer I/Os. For a small write to a wide array, both are
expensive.

### Why this matters for architects

A naive RAID-5 of 8 HDDs doing small random writes will deliver something like
**1/4 to 1/8 the IOPS** of a single disk. Workloads that look fine on a JBOD
collapse on RAID-5. The fix is either: avoid RAID-5/6 for small-write
workloads, or aggregate writes into full stripes (the stripe cache and the
raid5-cache journal exist for exactly this).

---

## 3. The Stripe Cache

md keeps an in-memory cache of "stripe head" objects (`struct stripe_head`).
Each represents the in-flight state of one stripe. The cache enables:
- Coalescing multiple bios into full-stripe writes before issuing them
- Holding the read-old-data results during RMW
- Tracking sync state during reshape and rebuild

```bash
# View / tune stripe cache size
cat /sys/block/md0/md/stripe_cache_size       # default 256
cat /sys/block/md0/md/stripe_cache_active     # currently in use

# Each stripe head uses ~chunk_size × (N+1) bytes of memory.
# For 4-disk array with 64K chunks: 256 stripes ≈ 80MB.
# For heavy write loads, increase:
echo 4096 > /sys/block/md0/md/stripe_cache_size   # ~1.3GB at the same parameters

# Rule of thumb: large enough to absorb writes within a plug window.
# Too small: every partial-stripe write goes to disk immediately as RMW.
# Too large: memory wasted; cache management overhead increases.
```

The stripe cache and the block-layer plug (Day 3) interact directly: plugged
writes give md time to discover sequential adjacency and coalesce, turning
many partial-stripe writes into one full-stripe write. This is one place
where the block plug matters at the RAID layer, not just the device layer.

---

## 4. The Write Hole

The classic RAID-5/6 correctness problem:

```
A stripe spans N disks. Updating it requires writing to ≥2 disks
(one data + parity, or more for reconstruct-write). These writes are
NOT atomic across disks — the kernel issues independent bios.

If the system crashes between writing the data and writing the parity:
  - Some disks have the new data; others still have the old
  - Parity no longer matches the data
  - Array is in an "inconsistent" state

If, *while inconsistent*, another disk fails before resync:
  - Reconstructing the failed disk uses the bad parity
  - You get GARBAGE for blocks unrelated to the in-flight write
  - Silent data corruption
```

This is unique to redundancy levels that compute parity (RAID-4/5/6).
RAID-1 and RAID-10 don't have the parity inconsistency form of this problem,
but they have their own — if one mirror was written and another wasn't,
which one is "correct"? On reads, md just picks one; on resync, it copies
one to the other based on the write-intent bitmap.

By default, **md refuses to start a dirty + degraded RAID-5/6 array**
precisely because of this risk.

---

## 5. The Three Write-Hole Solutions in md

### Option A: Write-intent bitmap (always recommended)
```
A bitmap tracks which regions of the array have writes in progress.
On unclean shutdown + restart:
  - Bitmap shows which stripes were possibly in-flight
  - Only those stripes need resync (not the whole array)
  - Resync time: minutes instead of hours
```

The bitmap doesn't close the write hole — it just **reduces the resync
window**. During that smaller window, data corruption is still possible
if a disk fails. But for most workloads, the time-window reduction is
sufficient.

```bash
# Add bitmap to existing array
mdadm --grow --bitmap=internal /dev/md0

# Verify
cat /proc/mdstat | grep -A2 md0
# md0 : active raid5 ...
#       12345 blocks ... bitmap: 1/2 pages [4KB], 65536KB chunk

# Bitmap chunk size: power of 2 between 4K and array_size/2^16
# Smaller = more precise (less resync) but more bitmap update overhead
# Default works fine; tune only if you have a specific problem
mdadm --grow --bitmap=internal --bitmap-chunk=64M /dev/md0
```

The bitmap update is on the hot path of every write — md updates the bitmap
bit before issuing the data write. On fast NVMe arrays this can be a
measurable overhead; on HDDs it's noise.

### Option B: raid5-cache (write-through or write-back journal)
```
Dedicated journal device (typically a small SSD or NVMe):
  - All writes hit the journal first
  - Then propagate to the RAID disks
  - On crash: replay the journal; no inconsistent state can be observed
```

Two modes:
- **write-through** (default, since 4.4): IO completes only after data is on
  the RAID disks. Journal exists only to close the write hole; not for speed.
  Journal can be small (hundreds of MB).
- **write-back** (since 4.10): IO completes as soon as data is in the
  journal. Journal aggregates writes and flushes them to RAID disks as full
  stripes. Big speedup for small-write workloads. Journal must be large
  (several GB) and fast.

```bash
# Create RAID-5 with a journal device
mdadm --create /dev/md0 --level=5 --raid-devices=4 \
      --write-journal=/dev/nvme0n1p1 \
      /dev/sd[a-d]1

# Switch modes at runtime
echo write-back > /sys/block/md0/md/journal_mode

# Verify
cat /sys/block/md0/md/journal_mode
```

**Critical caveat for write-back mode:** the journal device becomes a
single point of failure for in-flight writes. If the journal SSD fails
while in write-back mode, you lose dirty data. Use a mirrored journal
(two SSDs in dm-raid1) for production write-back.

### Option C: PPL (Partial Parity Log)
```
Stores "partial parity" (XOR of unmodified chunks of a stripe) in the
metadata area on each member disk. No dedicated journal device needed.
```

Trade-offs:
- No dedicated journal device required — uses spare space in the per-disk metadata
- Distributed: no single journal bottleneck or SPOF
- **30–40% write performance penalty** (every partial-stripe write does
  an extra small write to log partial parity)
- **NOT a true journal**: protects against silent corruption from the write
  hole, but doesn't recover in-flight data. If a disk dies during the write,
  the stripe's data is gone — same as plain RAID-5.
- **Incompatible with write-intent bitmap.** You pick one or the other.

```bash
# Enable PPL on a RAID-5 (requires v1.x superblock)
mdadm --grow --consistency-policy=ppl /dev/md0

# Verify
mdadm --detail /dev/md0 | grep "Consistency Policy"
```

### Which one to use?

| Situation | Choice |
|-----------|--------|
| Most production | Write-intent bitmap; tolerate the small resync window |
| Need to start dirty-degraded array safely | raid5-cache (write-through) with a small dedicated SSD |
| Heavy small-write workload, can afford a fast journal SSD | raid5-cache write-back with mirrored journal |
| No spare device for journal, OK with 30–40% write hit | PPL |
| RAID-10, RAID-1 | Bitmap only (parity write hole doesn't apply) |

---

## 6. Resync Behavior and Tuning

After unclean shutdown or new disk insertion, md runs a sync_action across
the array.

```bash
# Watch resync progress
cat /proc/mdstat
# md0 : active raid5 sd[a-d]1[0]
#       12345 blocks ... [UUUU] resync = 23.4% (1234/5678) finish=12.3min speed=400000K/sec

# Resync speed limits — important for production!
cat /proc/sys/dev/raid/speed_limit_min   # 1000 KB/s — never go below this
cat /proc/sys/dev/raid/speed_limit_max   # 200000 KB/s — never exceed this

# On a busy production array, lower max so resync doesn't hammer disks:
echo 50000 > /proc/sys/dev/raid/speed_limit_max
```

These limits are **per-device**, not per-array. An 8-disk array doing resync
at speed_limit_max=200000 will move 1.6 GB/s across the bus.

```bash
# Manual scrub (re-verify all parity)
echo check > /sys/block/md0/md/sync_action     # read-only verification
echo repair > /sys/block/md0/md/sync_action    # also rewrite bad parity

# Cancel an in-progress sync
echo idle > /sys/block/md0/md/sync_action
```

Production rule: run `check` monthly on long-lived arrays. Silent disk
corruption is more common than people think; you want to know before
the second disk fails.

---

## 7. Chunk Size and Workload Alignment

```bash
# Show chunk size
cat /sys/block/md0/md/chunk_size

# Choosing chunk size at create time:
# Small chunks (16K–64K): better for small random I/O — more stripes
#   touched per workload, more parallelism, more partial-stripe writes
# Large chunks (256K–1M): better for sequential I/O — single workload thread
#   stays within one chunk longer, less inter-disk parity overhead
```

Match chunk size to the filesystem and workload:
- Random 4K database I/O on RAID-5 of SSDs: 64K chunks
- Sequential video/backup on RAID-6 HDDs: 256K–1M chunks
- ZFS/Btrfs handle this themselves; pure md+filesystem stacks should think
  about it.

Filesystem alignment matters too: ext4 and XFS both have stripe-aware
allocation. `mkfs.xfs` reads md's stripe geometry automatically; `mkfs.ext4`
takes `-E stride=,stripe-width=` to align allocations to chunk boundaries.

---

## 8. Hands-On: Observing the Partial-Stripe Penalty

```bash
# Build a small test RAID-5 from loop devices
for i in 0 1 2 3; do
    dd if=/dev/zero of=/tmp/disk$i.img bs=1M count=512
    losetup --find --show /tmp/disk$i.img
done > /tmp/loops
LOOPS=$(cat /tmp/loops)

mdadm --create /dev/md99 --level=5 --raid-devices=4 \
      --chunk=64 $LOOPS

# Wait for initial sync
while grep -q resync /proc/mdstat; do sleep 2; done

# Test 1: full-stripe writes (192K aligned)
fio --name=fullstripe --filename=/dev/md99 --rw=write --bs=192k \
    --direct=1 --time_based --runtime=15 --ioengine=libaio --iodepth=8 \
    --output-format=terse | grep -E 'bw|iops'

# Test 2: small partial-stripe writes (4K random)
fio --name=partial --filename=/dev/md99 --rw=randwrite --bs=4k \
    --direct=1 --time_based --runtime=15 --ioengine=libaio --iodepth=8 \
    --output-format=terse | grep -E 'bw|iops'

# Expect: full-stripe ~3× the bandwidth of partial-stripe
# Increase stripe_cache_size and re-run partial test:
echo 4096 > /sys/block/md99/md/stripe_cache_size
fio --name=partial2 --filename=/dev/md99 --rw=randwrite --bs=4k \
    --direct=1 --time_based --runtime=15 --ioengine=libaio --iodepth=8 \
    --output-format=terse | grep -E 'bw|iops'
# Larger stripe cache can help by absorbing writes into full stripes

# Cleanup
mdadm --stop /dev/md99
for l in $LOOPS; do losetup -d $l; done
rm /tmp/disk*.img /tmp/loops
```

---

## 9. Architect's Decision Reference

| Workload | RAID level | Notes |
|----------|-----------|-------|
| OLTP database (random small writes) | RAID-10 | Write hole doesn't apply; 2× space cost; predictable latency |
| Bulk storage, sequential | RAID-6 | Tolerate dual disk failure; partial-stripe penalty hidden by sequential pattern |
| Mixed read-heavy | RAID-5 with bitmap | Small write penalty acceptable if reads dominate |
| Mixed write-heavy | RAID-5/6 with raid5-cache write-back | Journal absorbs partial-stripe penalty |
| Critical, write-heavy | RAID-10 + LVM mirroring | Don't compose parity RAID with critical workloads |
| Don't use | RAID-0 with anything important | No redundancy at all |

### A note on hardware RAID controllers

Hardware controllers with battery-backed write cache (BBWC) close the write
hole the same way raid5-cache write-back does — the BBWC is the journal.
But you give up visibility (proprietary on-disk format) and flexibility.
mdadm + raid5-cache + a mirrored NVMe journal gives most of the same
performance with full Linux observability.

---

## 10. Self-Check Questions

1. What is the "write hole" and why is it specific to RAID-4/5/6?
2. Why does a 4K random write to a wide RAID-5 array cause 4× write amplification?
3. What does `stripe_cache_size` do and what's a reasonable value for a write-heavy workload?
4. What's the difference between raid5-cache write-through and write-back modes?
5. Why is PPL not compatible with write-intent bitmap?
6. A production RAID-5 of 8 HDDs is doing random 4K writes at ~50 IOPS total. Performance is unacceptable. What three things would you investigate?

## 11. Answers

1. After a crash, data + parity on a stripe may be inconsistent (some disks updated, others not). If a member disk fails before resync, reconstructing the failed disk's data uses the bad parity, producing garbage. It's specific to parity-based RAID because RAID-1/10 don't have the data/parity consistency constraint (only the mirror agreement question, which is handled differently).
2. RMW path: 1 read of old data + 1 read of old parity + 1 write of new data + 1 write of new parity = 4 I/Os for one 4K write. Reconstruct-write is the same order of magnitude for wide arrays.
3. It's the number of `stripe_head` objects md keeps in memory to coalesce writes and hold RMW intermediate state. For a write-heavy workload, increase to 2048–8192; calculate memory cost as `chunk_size × (N+1) × stripe_cache_size`.
4. Write-through: I/O completes only when data is on the RAID disks. Journal exists only to close the write hole. Write-back: I/O completes when data is in the journal; journal absorbs partial-stripe writes and flushes full stripes later. Write-back is faster but journal failure = data loss.
5. PPL stores partial parity in the per-disk metadata area, and that space is the same region the bitmap would occupy. The two features compete for the same on-disk space and are implemented as alternative consistency policies.
6. (1) Confirm it's partial-stripe penalty: check `iostat -x` — RAID disks should show 4× the IO rate of the array device. (2) Check `stripe_cache_size`; if it's the default 256, raise to 4096. (3) Look at the workload: 4K random writes on RAID-5 of HDDs is the wrong stack — recommend RAID-10 or adding a raid5-cache write-back journal on SSD. Also check for missing write-intent bitmap and missing FS-level stripe alignment (`-E stride=,stripe-width=` for ext4).

---

## Tomorrow: Day 17 — XFS Internals Part 1: AG Model and On-Disk Layout

We go deep on XFS's allocation group model, how it enables parallel
metadata operations, and what the on-disk superblock and AG headers
actually contain.
