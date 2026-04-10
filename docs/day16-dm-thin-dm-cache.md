# Day 16: dm-thin & dm-cache

## Learning Objectives
- Understand thin provisioning concepts and dm-thin architecture
- Learn dm-cache target behavior and cache policy model
- Set up thin provisioning with LVM for hands-on study
- Understand metadata management in both targets

---

## 1. Thin Provisioning with dm-thin

### What is thin provisioning?

Thin provisioning allocates storage on demand rather than up front. A thin volume appears to have a large capacity but only consumes physical blocks when data is actually written.

Benefits:
- Overcommit storage capacity
- Efficient snapshots (shared blocks)
- Space reclamation when blocks are freed

### Architecture

```text
┌─────────────────────────────────┐
│  thin volume (/dev/mapper/thin) │  ← virtual, sparse
│    appears as e.g. 100GB        │
└───────────────┬─────────────────┘
                |
                v
┌─────────────────────────────────┐
│  thin-pool                      │
│    data device: actual blocks   │  ← e.g. 20GB physical
│    metadata device: mapping     │  ← btree mapping thin blocks → data blocks
└───────────────┬─────────────────┘
                |
                v
         physical storage
```

### Key concepts

- **Thin pool:** holds shared data blocks and metadata
- **Metadata device:** persistent btree mapping virtual blocks to physical data blocks
- **Data device:** actual block storage pool
- **Provisioning:** on first write to a thin block, a data block is allocated from the pool
- **Snapshots:** create instant copy-on-write clones of thin volumes

---

## 2. dm-thin Internals

Source: `drivers/md/dm-thin.c`, `drivers/md/dm-thin-metadata.c`

### Bio handling in dm-thin

```text
bio arrives at thin volume
    |
    v
thin_map()
    |
    v
lookup virtual block in metadata btree
    |
    ├── mapping exists → remap bio to data device + physical block
    │                     return DM_MAPIO_REMAPPED
    │
    └── no mapping (unprovisioned) →
        ├── READ: return zeros
        └── WRITE: allocate data block from pool
                   insert mapping in metadata
                   remap and submit bio
```

### Metadata structure

- Persistent btree on the metadata device
- Maps (thin_id, virtual_block) → physical_block
- Transaction-based updates for crash consistency
- Space maps track free/used data and metadata blocks

### Snapshots

- Snapshots share the metadata btree with the origin
- Copy-on-write: first write to a shared block copies it, then remaps
- Recursive snapshots are supported

---

## 3. dm-cache

Source: `drivers/md/dm-cache-target.c`, `drivers/md/dm-cache-policy*.c`

### Purpose

dm-cache places a fast device (SSD) in front of a slow device (HDD) to accelerate frequently accessed data.

### Architecture

```text
┌─────────────────────────────────┐
│  dm-cache device                │
│    origin: /dev/sdb (HDD)       │  ← slow backing
│    cache:  /dev/sda (SSD)       │  ← fast cache
│    metadata: mapping + dirty    │
└─────────────────────────────────┘
```

### Cache policies

dm-cache uses a pluggable policy model:

- **smq (Stochastic Multi-Queue):** default policy, low memory overhead, good general-purpose behavior
- **cleaner:** only writes back dirty blocks, used during cache teardown

Policy responsibilities:
- Decide which blocks to promote (move to cache)
- Decide which blocks to demote (evict from cache)
- Track hotness/access patterns

### Bio handling

```text
bio arrives at dm-cache device
    |
    v
cache_map()
    |
    v
lookup block in cache metadata
    |
    ├── cache hit → remap to cache device (SSD)
    │
    ├── cache miss + policy says promote →
    │     migrate block from origin to cache
    │     then serve from cache
    │
    └── cache miss + no promote →
          serve directly from origin (HDD)
```

### Writeback

- Dirty cached blocks must be written back to origin before eviction
- Background writeback reduces eviction latency
- `cleaner` policy forces full writeback (used before removing cache)

---

## 4. Hands-On Exercises

### Exercise 1: Create a thin pool and thin volume with LVM

```bash
# Prerequisites: LVM tools installed, a volume group (vg0) available
# Create a thin pool (adjust sizes for your environment)
sudo lvcreate -L 1G --thinpool thin_pool vg0

# Create a thin volume (virtual size can exceed pool size)
sudo lvcreate -V 5G --thin -n thin_vol vg0/thin_pool

# Verify
sudo lvs -a vg0
lsblk
```

### Exercise 2: Observe thin provisioning behavior

```bash
# Check actual usage before writing
sudo lvs -o+data_percent vg0/thin_pool

# Write some data
sudo dd if=/dev/urandom of=/dev/vg0/thin_vol bs=1M count=100

# Check usage after writing
sudo lvs -o+data_percent vg0/thin_pool
```

### Exercise 3: Create a thin snapshot

```bash
# Snapshot the thin volume
sudo lvcreate -s -n thin_snap vg0/thin_vol

# Verify
sudo lvs -a vg0

# Write to snapshot (triggers CoW)
sudo dd if=/dev/urandom of=/dev/vg0/thin_snap bs=1M count=10
sudo lvs -o+data_percent vg0/thin_pool
```

### Exercise 4: Inspect DM table for thin devices

```bash
sudo dmsetup table | grep thin
sudo dmsetup status | grep thin
```

### Exercise 5: Source navigation

```bash
# dm-thin key functions
grep -rn "thin_map\|provision_block\|process_bio" drivers/md/dm-thin.c | head -20

# dm-cache key functions
grep -rn "cache_map\|policy_map\|migration" drivers/md/dm-cache-target.c | head -20
```

### Exercise 6: Cleanup

```bash
sudo lvremove -f vg0/thin_snap
sudo lvremove -f vg0/thin_vol
sudo lvremove -f vg0/thin_pool
```

---

## 5. Source Navigation Checklist

Primary:
- `drivers/md/dm-thin.c` — thin target bio handling
- `drivers/md/dm-thin-metadata.c` — btree and space map management
- `drivers/md/dm-cache-target.c` — cache target core
- `drivers/md/dm-cache-policy-smq.c` — default cache policy

Supporting:
- `drivers/md/persistent-data/` — shared btree/space-map library used by dm-thin
- `drivers/md/dm-cache-metadata.c` — cache metadata management

---

## 6. Common Pitfalls

1. Thin pool full with no autoextend
   - Thin volumes become read-only or I/O errors occur when the pool is exhausted
   - Always monitor `data_percent` and configure autoextend or alerts

2. Metadata device too small
   - Metadata exhaustion is harder to recover from than data exhaustion
   - Size metadata proportionally to expected snapshot/mapping count

3. Snapshot accumulation overhead
   - Each snapshot increases CoW overhead on writes to shared blocks
   - Too many snapshots degrades write performance

4. dm-cache teardown without writeback
   - Removing cache device without flushing dirty blocks causes data loss
   - Always switch to `cleaner` policy and wait for writeback before removal

---

## 7. Self-Check Questions

1. What happens when a thin volume receives a write to an unprovisioned block?
2. How do thin snapshots achieve instant creation?
3. What is the role of the metadata device in a thin pool?
4. How does dm-cache decide whether to promote a block?
5. Why must you writeback before removing a dm-cache device?

## 8. Self-Check Answers

1. A data block is allocated from the pool, the mapping is inserted into the metadata btree, and the bio is remapped and submitted.
2. They share the metadata btree with the origin — no data copying at creation time. Copy-on-write happens only on subsequent writes to shared blocks.
3. It stores the persistent btree that maps virtual blocks to physical data blocks, plus space maps tracking allocation state.
4. The cache policy (e.g., smq) tracks access patterns and promotes blocks that appear to be hot or frequently accessed.
5. Dirty blocks in the cache contain the only up-to-date copy of that data. Removing without writeback means those updates are lost.

---

## 9. Tomorrow's Preview: Day 17 — dm-crypt & dm-verity

Next we examine security-focused DM targets:
- dm-crypt per-bio encryption model
- dm-verity Merkle-tree integrity verification
- practical LUKS volume setup with `cryptsetup`.
