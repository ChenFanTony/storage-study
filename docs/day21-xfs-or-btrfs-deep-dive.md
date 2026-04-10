# Day 21: XFS or Btrfs Deep Dive

## Learning Objectives
- Compare two advanced Linux filesystem designs (XFS vs Btrfs)
- Understand XFS allocation-group and log architecture at a high level
- Understand Btrfs CoW B-tree, snapshot, and checksum model
- Run practical labs for one chosen track

---

## 1. Pick a Track for Today

You should focus deeply on **one** filesystem today:

- **Track A: XFS** (high-performance, mature metadata scaling)
- **Track B: Btrfs** (CoW, snapshots, checksums, integrated features)

You can read both overviews below, then do labs for your chosen track.

---

## 2. Track A — XFS Deep Dive

### 2.1 Core Design Ideas

XFS is designed for scalability and high parallelism, especially for large filesystems and heavy metadata workloads.

Key concepts:
- **Allocation Groups (AGs):** filesystem divided into semi-independent regions for parallel allocation
- **B+tree metadata structures:** free-space and inode indexing
- **Write-ahead logging (journal/log):** metadata consistency and fast recovery

### 2.2 Allocation Groups (AG)

Conceptually:

```text
Filesystem
 ├─ AG0
 ├─ AG1
 ├─ AG2
 └─ ...
```

Each AG contains local metadata/data structures, reducing global lock contention and enabling concurrent operations.

### 2.3 XFS Logging

XFS uses an internal log for metadata updates:
- transaction records are written to log
- metadata is later applied/checkpointed
- recovery replays log after crash

This supports quick mount-time recovery.

### 2.4 Recommended Source Focus

- `fs/xfs/xfs_alloc.c`
- `fs/xfs/xfs_bmap.c`
- `fs/xfs/xfs_log.c`
- `fs/xfs/xfs_inode.c`

---

## 3. Track B — Btrfs Deep Dive

### 3.1 Core Design Ideas

Btrfs is a CoW filesystem emphasizing integrity and advanced data management.

Key concepts:
- **CoW B-tree metadata/data references**
- **Checksums** (data + metadata integrity)
- **Snapshots/subvolumes**
- **Send/receive** for incremental replication

### 3.2 CoW Metadata Model

On update, Btrfs usually writes new tree blocks instead of overwriting existing ones.

Implications:
- strong snapshot semantics
- robust consistency model
- potential write amplification/fragmentation trade-offs in some workloads

### 3.3 Checksums and Integrity

Btrfs stores checksums in metadata trees and validates on read paths where possible.

Benefits:
- detect silent corruption
- support repair workflows in redundant profiles

### 3.4 Recommended Source Focus

- `fs/btrfs/ctree.c`
- `fs/btrfs/disk-io.c`
- `fs/btrfs/extent-tree.c`
- `fs/btrfs/volumes.c`

---

## 4. Side-by-Side Comparison (High Level)

| Area | XFS | Btrfs |
|------|-----|-------|
| Core update model | In-place metadata + log | CoW trees |
| Snapshot capability | External tooling model | Built-in subvolume snapshots |
| Integrity checksums | Not full end-to-end data checksum model like Btrfs | Built-in checksum model |
| Typical strengths | High throughput, mature scaling | Rich data management features |
| Trade-off focus | Operational simplicity/perf | Feature richness + CoW complexity |

---

## 5. Hands-On Labs (Choose One Track)

## Track A Labs — XFS

### Exercise A1: Create and inspect XFS
```bash
# test device only
sudo mkfs.xfs /dev/loop2
sudo mkdir -p /mnt/xfstest
sudo mount /dev/loop2 /mnt/xfstest
xfs_info /mnt/xfstest
```

### Exercise A2: Basic metadata workload
```bash
mkdir -p /mnt/xfstest/tree
for i in $(seq 1 5000); do touch /mnt/xfstest/tree/f$i; done
sync
```

### Exercise A3: Inspect usage/health
```bash
xfs_db -r /dev/loop2 -c 'sb 0' -c 'p'
```

### Exercise A4: Source navigation
```bash
grep -rn "xfs_alloc\|AG" fs/xfs/xfs_alloc.c | head -30
grep -rn "xlog\|log" fs/xfs/ | head -40
```

---

## Track B Labs — Btrfs

### Exercise B1: Create and mount Btrfs
```bash
# test device only
sudo mkfs.btrfs /dev/loop2
sudo mkdir -p /mnt/btrfstest
sudo mount /dev/loop2 /mnt/btrfstest
btrfs filesystem show /mnt/btrfstest
```

### Exercise B2: Create subvolume + snapshot
```bash
sudo btrfs subvolume create /mnt/btrfstest/data
echo "hello" | sudo tee /mnt/btrfstest/data/a.txt
sudo btrfs subvolume snapshot /mnt/btrfstest/data /mnt/btrfstest/data-snap
```

### Exercise B3: Send/receive demo
```bash
sudo mkdir -p /mnt/btrfs-recv
sudo btrfs send /mnt/btrfstest/data-snap | sudo btrfs receive /mnt/btrfs-recv
```

### Exercise B4: Inspect extent/checksum-related metadata (read-only inspection)
```bash
sudo btrfs filesystem df /mnt/btrfstest
sudo btrfs inspect-internal dump-super /dev/loop2 | head -80
```

### Exercise B5: Source navigation
```bash
grep -rn "cow\|ctree\|checksum" fs/btrfs/ | head -40
```

---

## 6. Source Navigation Checklist

XFS track:
- `fs/xfs/xfs_alloc.c`
- `fs/xfs/xfs_log.c`
- `fs/xfs/xfs_bmap.c`

Btrfs track:
- `fs/btrfs/ctree.c`
- `fs/btrfs/extent-tree.c`
- `fs/btrfs/disk-io.c`

---

## 7. Common Pitfalls

1. Treating XFS and Btrfs tuning knobs as interchangeable
2. Evaluating filesystem behavior with only one microbenchmark
3. Ignoring workload shape (metadata-heavy vs sequential large I/O)
4. Running destructive experiments on production data

---

## 8. Self-Check Questions

1. What are Allocation Groups in XFS and why are they useful?
2. What is the primary update strategy in Btrfs?
3. Why does Btrfs snapshotting work naturally with CoW?
4. Which filesystem emphasizes built-in checksums and subvolumes?
5. Which source file would you start with for Btrfs tree logic?

## 9. Self-Check Answers

1. Semi-independent filesystem regions enabling scalable parallel allocation and reduced contention.
2. Copy-on-write tree updates.
3. Old blocks remain referenced while new versions are written, preserving prior state.
4. Btrfs.
5. `fs/btrfs/ctree.c`.

---

## 10. Tomorrow’s Preview: Day 22 — NVMe Driver

Next we move into device-driver internals:
- NVMe queue setup and command lifecycle
- key files: `drivers/nvme/host/core.c`, `pci.c`
- inspect NVMe devices via `nvme-cli` and sysfs.
