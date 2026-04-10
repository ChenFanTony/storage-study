# Day 12: dm-thin — Thin Provisioning & Metadata

## Learning Objectives
- Understand dm-thin's mapping tree and how space is allocated on demand
- Follow snapshot COW mechanics at the block level
- Understand what happens when the metadata device fails (the catastrophic case)
- Use `thin_dump` and `thin_check` to inspect and validate thin pool metadata
- Know the architect-level failure risks and mitigations

---

## 1. dm-thin Architecture

```
dm-thin stack:

┌──────────────────────────────────────────────────┐
│  Thin Logical Volumes (thin LVs)                 │
│  /dev/vg/thin_lv1  /dev/vg/thin_lv2  ...        │
│  (each is a dm-thin device)                      │
└───────────────────┬──────────────────────────────┘
                    │ virtual → physical block lookup
                    ▼
┌──────────────────────────────────────────────────┐
│  Thin Pool (dm-thin-pool target)                 │
│  ├── Metadata device (small SSD/device)          │
│  │   └── Persistent B-tree mapping:              │
│  │       thin_dev_id + virtual block →           │
│  │       physical block on data device           │
│  └── Data device (large storage)                 │
│      └── Actual data blocks                      │
└──────────────────────────────────────────────────┘
```

The thin pool has two critical components:
- **Data device**: where actual data lives (can be large HDD, LV, etc.)
- **Metadata device**: B-tree mapping virtual→physical blocks (must be fast, reliable)

---

## 2. The Mapping Tree

```c
// drivers/md/dm-thin-metadata.c

// The persistent data structure: a B-tree of B-trees
//
// Top-level B-tree: thin_dev_id → (per-device B-tree root)
// Per-device B-tree: virtual_block → physical_block + transaction_id
//
// struct dm_thin_lookup_result {
//     dm_block_t  block;          // physical block on data device
//     bool        shared;         // is this block shared (snapshot COW needed)?
//     bool        zeroed;         // is this a new unwritten block?
// };

// On every write to a thin LV:
thin_map(bio):
    // 1. Look up virtual block in per-device B-tree
    dm_thin_find_block(td, block, can_block, &lookup_result)

    if (lookup_result.block found):
        if (lookup_result.shared):
            // COW: must copy before writing
            alloc new physical block
            copy old data to new block
            update mapping to new block
        else:
            // not shared — write directly
    else:
        // new block: allocate from pool's free list
        alloc new physical block
        update mapping
        zero the block (if required)
```

**Space allocation is truly on-demand:**
A 1TB thin LV with no data written to it consumes zero blocks on the data device.
Blocks are allocated only when first written (or read, if zeroing is required).

---

## 3. Snapshot COW Mechanics

```
Initial state: thin_lv1 has data at blocks 0..N
  thin_lv1 mapping: vblock 0 → pblock 100
                    vblock 1 → pblock 101
                    vblock 2 → pblock 102

Create snapshot: snap1 = snapshot of thin_lv1
  snap1 mapping: same as thin_lv1 (shared blocks, shared=true)
  vblock 0 → pblock 100 (shared=true)
  vblock 1 → pblock 101 (shared=true)
  vblock 2 → pblock 102 (shared=true)

Write to thin_lv1 (vblock 1):
  COW triggered (block 1 is shared):
  1. Allocate new pblock 200
  2. Copy pblock 101 → pblock 200
  3. Write new data to pblock 200
  4. Update thin_lv1 mapping: vblock 1 → pblock 200 (shared=false)
  5. snap1 mapping unchanged: vblock 1 → pblock 101 (still shared=true with others)

Result:
  thin_lv1: vblock 1 → pblock 200 (new data)
  snap1:     vblock 1 → pblock 101 (original data preserved)
```

**COW cost:**
- First write to any shared block: 1 extra read + 1 extra write
- Subsequent writes to same block: no extra cost (no longer shared)
- Many snapshots of same block: each new snapshot resets shared=true
  → more COW operations over time

---

## 4. Metadata Device: The Single Point of Failure

This is the critical architect concern with dm-thin:

```
Metadata device contains:
  - The B-tree mapping ALL virtual→physical block mappings
  - For ALL thin LVs in the pool
  - For ALL snapshots

Metadata device failure:
  - ALL thin LVs in the pool become inaccessible
  - Mapping data is gone → cannot translate virtual to physical blocks
  - Data on data device is physically present but unaddressable
  - EVERY thin LV in the pool is affected, not just one

This is a single point of failure for potentially many virtual volumes.
```

```bash
# How large is a metadata device?
# Rule of thumb: 48 bytes per block mapping
# Pool has 1TB data device with 64KB blocks = 1TB/64KB = ~16M blocks
# Metadata size: 16M × 48 bytes = ~768MB
# Add headroom: recommend 1–2GB metadata device

# LVM auto-calculates:
lvcreate --type thin-pool -L 1T --poolmetadatasize 2G \
    -n data_pool vg_data

# Check current metadata usage
lvs -o+metadata_percent vg_data/data_pool
```

---

## 5. Protecting the Metadata Device

```bash
# Option 1: RAID-1 metadata device (recommended for production)
# Create a mirrored LV for metadata
lvcreate --type raid1 -m1 -L 2G -n pool_meta vg_data
lvcreate -L 500G -n pool_data vg_data
lvconvert --type thin-pool \
    --poolmetadata vg_data/pool_meta \
    vg_data/pool_data

# Option 2: Separate fast SSD for metadata (reduces failure correlation)
# Put metadata on a different physical device than data

# Option 3: Regular metadata backups
thin_dump /dev/vg_data/pool_meta > /backup/pool_meta_$(date +%Y%m%d).xml
# Restore: thin_restore -i /backup/pool_meta_YYYYMMDD.xml -o /dev/vg_data/pool_meta
```

---

## 6. Inspecting and Validating Thin Pool Metadata

```bash
# IMPORTANT: pool must be inactive (deactivated) for these operations

# Deactivate the pool (unmount all thin LVs first)
umount /mnt/thin_lv1
lvchange -an vg_data/data_pool

# Check metadata integrity
thin_check /dev/vg_data/pool_meta
# Exit code 0 = clean, non-zero = corruption found

# Dump metadata to XML (human-readable inspection)
thin_dump /dev/vg_data/pool_meta | head -100
# Shows: <superblock>, <device id=X>, <range_mapping ...> entries

# Repair corrupted metadata (USE WITH CAUTION)
thin_repair -i /dev/vg_data/pool_meta -o /dev/vg_data/pool_meta_repaired
# Produces repaired version — always verify with thin_check after

# Show space map (free/used physical blocks)
thin_dump --dev-id 1 /dev/vg_data/pool_meta | grep -c "range_mapping"
```

---

## 7. Metadata Transaction Model

dm-thin uses a transactional metadata model for crash consistency:

```c
// dm-thin-metadata.c uses persistent-data library (lib/dm-thin-metadata.c)
// which implements a transactional B-tree with copy-on-write semantics

// Every metadata update:
// 1. COW B-tree node (write to new location, don't overwrite old)
// 2. Update parent pointers
// 3. Commit: write new superblock atomically
//    (superblock contains root of B-tree)
// 4. Old nodes become free space (reclaimed by space map)

// On crash: superblock may or may not be updated
// Recovery: load last committed superblock → consistent (but possibly old) state
// No journal needed: COW B-tree IS the journal
```

**What this means for architects:**
- dm-thin metadata is crash-consistent (no corruption from crash)
- But: writes between last commit and crash are lost
- Commit frequency: every `dm-thin-pool commit_period` (default 1 second)
- Data written in the last second before crash may lose its metadata → orphaned blocks

---

## 8. Hands-On: Thin Pool Lab

```bash
# Create thin pool on loopback (safe testing)
dd if=/dev/zero of=/tmp/pool_data.img bs=1M count=4096    # 4GB data
dd if=/dev/zero of=/tmp/pool_meta.img bs=1M count=64      # 64MB metadata

DATA=$(losetup --find --show /tmp/pool_data.img)
META=$(losetup --find --show /tmp/pool_meta.img)

# Initialize metadata
thin_pool_format $META  # or use dmsetup

# Create thin pool
POOL_SIZE=$(blockdev --getsz $DATA)
META_SIZE=$(blockdev --getsz $META)

echo "0 $POOL_SIZE thin-pool $META $DATA 128 0" \
    | dmsetup create test_pool

# Create thin LV
echo "0 $((1024*1024*2)) thin /dev/mapper/test_pool 1" \
    | dmsetup create thin_lv1   # 1GB thin LV (but only allocates on write)

# Check actual allocation
dmsetup status test_pool
# Shows: used_metadata_blocks/total, used_data_blocks/total

# Write some data
mkfs.ext4 /dev/mapper/thin_lv1
mount /dev/mapper/thin_lv1 /mnt/thin_test
dd if=/dev/urandom of=/mnt/thin_test/file bs=1M count=100

# Check how many data blocks are now allocated
dmsetup status test_pool

# Create a snapshot
echo "0 $((1024*1024*2)) thin /dev/mapper/test_pool 2 1" \
    | dmsetup create thin_snap1  # device 2, origin device 1

# Inspect metadata (after deactivating)
umount /mnt/thin_test
dmsetup remove thin_snap1 thin_lv1 test_pool
thin_dump $META | head -50
thin_check $META && echo "Metadata clean"
```

---

## 9. Self-Check Questions

1. If the metadata device fails in a dm-thin pool, which thin LVs are affected?
2. What is COW in snapshot context, and when is it triggered?
3. Why is the metadata device size much smaller than the data device?
4. dm-thin uses a COW B-tree for metadata. What does this mean for crash recovery?
5. A customer has 50 thin LVs in a pool with metadata on the same spinner as data. What risk would you raise?
6. After a crash, `thin_check` reports errors on the metadata device. What is your recovery procedure?

## 10. Answers

1. ALL thin LVs in the pool — the metadata device contains the virtual→physical mapping for every thin LV and snapshot in the pool. One metadata device failure takes down everything.
2. COW (copy-on-write) is triggered when a write targets a block marked `shared=true` (shared between a thin LV and at least one snapshot). The block is copied to a new physical location before the write, preserving the snapshot's view of the original.
3. Metadata stores only the mapping (virtual block number → physical block number), not the actual data. At ~48 bytes per mapping entry, even a 10TB pool with 64KB blocks needs only ~7.5GB of metadata.
4. The COW B-tree means every update writes to new blocks rather than overwriting old ones. The superblock atomically commits the new B-tree root. On crash, loading the last valid superblock gives a consistent (pre-crash) state — no separate journal needed, no corruption possible.
5. The metadata device and data device are on the same physical spindle — a single disk failure destroys both the data and the ability to address any data that survived. Metadata should be on a separate, preferably mirrored, device. Also: if data fills up the pool, metadata updates fail, which can cause I/O errors on all thin LVs.
6. (1) Deactivate the pool. (2) Run `thin_check` to assess damage. (3) Try `thin_repair -i <damaged> -o <new_device>` to recover what's possible. (4) Verify with `thin_check` on repaired output. (5) If repair fails, restore from last known-good `thin_dump` XML backup. (6) Accept data loss for any blocks allocated between last backup and crash.

---

## Tomorrow: Day 13 — Tiering Failure Semantics: Full Analysis

We combine Days 8–12 into a complete failure matrix across all tiering modes
and produce the reference table you'll use in architecture documents.
