# Day 21: Week 3 Review — Filesystem & Block Stack Architecture Reference

## Objective
Synthesize Days 15–20 into a defensible reference for designing the
filesystem and block-stack layer of a production system. As with Week 1
and 2 reviews: you produce a written output today, not just read.

---

## 1. What You Should Now Be Able to Defend

| Topic | Can defend? |
|-------|-------------|
| Whether to use dm-crypt and which options for a given workload | |
| dm-crypt sector size and workqueue flags — what each does | |
| RAID-5 partial-stripe write penalty in concrete numbers | |
| The three md write-hole solutions and when to pick each | |
| Why XFS scales on parallel metadata better than ext4 | |
| The CIL and what it provides architecturally | |
| When ext4 genuinely wins over XFS | |
| What `xfs_repair` and `e2fsck` actually do (and don't) | |
| The recovery sequence: state preservation → diagnosis → repair | |
| Which filesystem features need to be set at mkfs (cannot be changed later) | |

---

## 2. The Decisions Matrix You Take Forward

### Encryption layer (dm-crypt)

| Workload | Cipher | Sector size | Workqueue | Notes |
|----------|--------|-------------|-----------|-------|
| New NVMe-backed server | aes-xts-plain64 | 4096 | bypass both | Modern default; big perf gains |
| SATA SSD | aes-xts-plain64 | 4096 | usually bypass | Crypto less of a bottleneck |
| HDD | aes-xts-plain64 | 512 or 4096 | leave default | Disk dominates |
| Need integrity, not just confidentiality | capi:gcm(aes)-random + dm-integrity | — | — | Costs space and CPU |
| Legacy systems | aes-cbc-essiv:sha256 | 512 | leave default | Don't break working systems |

### Redundancy layer (md)

| Workload | Level | Write-hole solution | Notes |
|----------|-------|--------------------|----|
| OLTP DB, random writes | RAID-10 | bitmap (parity hole doesn't apply) | 2× space cost; predictable perf |
| Bulk seq storage | RAID-6 | bitmap | Tolerate dual disk failure |
| Mixed read-heavy | RAID-5 | bitmap | Acceptable if reads dominate |
| Heavy write, can afford journal SSD | RAID-5/6 + raid5-cache write-back | journal | Absorbs partial-stripe writes; SPOF unless journal mirrored |
| No journal disk available | RAID-5/6 | PPL | 30-40% write penalty; not a true journal |
| Don't compose | RAID-5/6 + critical workload | — | Use RAID-10 instead |

### Filesystem layer

| Decision driver | Pick |
|----------------|------|
| Default unless reason otherwise | XFS |
| Need shrinkability | ext4 |
| Very small partition (<10GB) on tight memory | ext4 |
| Many small files (mail, container, build) | XFS |
| Need reflink (VM images, snapshots) | XFS |
| Massive scale (100TB+) | XFS |
| `data=journal` durability requirement | ext4 |
| Team familiarity dominates | use what they know |

---

## 3. Decisions You Cannot Reverse

This list is the most-asked-about gotcha. Each of these is set at
creation time and cannot be changed without backup-restore:

| Decision | Where set |
|----------|-----------|
| XFS AG count | mkfs.xfs (can only grow) |
| XFS v4 vs v5 (CRC) | mkfs.xfs |
| XFS reflink support | mkfs.xfs -m reflink=1 |
| XFS block size | mkfs.xfs |
| XFS log location (internal vs external) | mkfs.xfs |
| ext4 inode count (bytes-per-inode) | mkfs.ext4 -i |
| ext4 vs ext3 features | mkfs.ext4 |
| dm-crypt cipher mode | cryptsetup luksFormat |
| dm-crypt sector size | cryptsetup luksFormat --sector-size |
| md RAID level | mdadm --create |
| md chunk size | mdadm --create (some grow-time changes possible but risky) |

These are the design-review questions that show up later as
"we'd love to change it but we can't without downtime and data restore."

---

## 4. Scenario: Design Review

**You are designing storage for a SaaS analytics platform.**
- Hardware per node: 2× NVMe (1TB each), 4× HDD (16TB each), 256GB RAM, 32 cores
- Workload: ingest 200GB/day raw events (mostly sequential append), then
  scan over the last 30 days to compute aggregates
- Customers: 100 tenants, each with their own dataset; want isolation
- Durability: cannot lose acknowledged ingest; backups are nightly
- Performance: ingest must keep up at sustained 50MB/s aggregate

Walk through these decisions and justify each:

1. **Layer stack:** What goes on the NVMe vs HDD? Where does dm-crypt sit?
   Do you use md RAID, dm-cache, or both?
2. **Filesystem choice:** XFS or ext4? AG count? Reflink?
3. **Encryption:** dm-crypt at which layer? Cipher? Sector size?
4. **Tenancy:** how do you give 100 tenants isolation? Per-tenant filesystem?
   Per-tenant directory with quotas? Separate dm-thin volumes?
5. **Durability/recovery:** what's your RPO/RTO for a single-disk failure?
   For a node failure?

Reference answer at end of document.

---

## 5. The Operational Runbook (Produce This Today)

Write a one-screen reference document. Cover, at minimum:

```markdown
# Filesystem & Block Stack Runbook
Version: 2026-MM-DD

## Mount-time errors
- "log replay required" on ext4: [steps]
- "log replay required" on XFS: [steps]
- "structure needs cleaning" on ext4: [steps]
- XFS metadata corruption shutdown: [steps]

## Before running any repair tool
1. [the preservation steps]
2. [the diagnosis steps]

## RAID resync in progress
- How to throttle: [commands]
- How to monitor: [commands]
- When to abort: [criteria]

## dm-crypt didn't open
- LUKS header damage: [recovery steps]
- Forgotten passphrase, have key in TPM: [steps]
- Forgotten passphrase, no backup: [you're done]

## Filesystem ran out of inodes (ext4)
- Diagnostic: df -i
- Short-term: [steps]
- Long-term: [reformat with -i value]

## XFS filling up faster than du suggests
- Likely: preallocation or reflink
- Diagnosis commands: [list]

## XFS AG contention (single CPU pegged on metadata)
- Diagnosis: [perf, /proc/fs/xfs/stat]
- Mitigation: [directory restructuring]
- Long-term: [reformat with higher agcount]
```

This is what someone on-call wants at 3am. Make it the kind of document
where you can scroll directly to the symptom you're seeing.

---

## 6. Hands-On Drill — Without Looking Anything Up

Build up the entire stack on loopback devices. No notes. Time yourself.

```bash
# Goal: build dm-crypt + md RAID-5 + XFS, mount, write a file, unmount cleanly

# 1. Create 4 loop devices for the RAID
for i in 0 1 2 3; do
    dd if=/dev/zero of=/tmp/d$i.img bs=1M count=256
    losetup --find --show /tmp/d$i.img
done

# 2. Build RAID-5 on the loops
# (write the command from memory before reading further)

# 3. Wait for initial sync to complete

# 4. dm-crypt the RAID device
# (LUKS format with sector-size=4096 and modern cipher)

# 5. Open the encrypted device

# 6. mkfs.xfs on top, with reflink

# 7. Mount, write data, sync, unmount

# 8. Tear it all down cleanly
```

If any step takes more than 30 seconds of thinking, that's the topic to
re-read.

---

## 7. The Filesystem-Independent Mistakes to Avoid

Some lessons that apply regardless of XFS / ext4 / Btrfs / ZFS:

1. **`fsync()` is not free.** Database "we sync every commit" is a major
   workload property. XFS log force vs ext4 JBD2 commit have different
   cost models; pick the FS that fits, then size the underlying device for
   the resulting fsync rate.

2. **The page cache hides the storage layer.** A workload that "works fine"
   on a single dev box might run from 256GB of RAM with cold disks barely
   touched. Cold-cache benchmarks reveal what the storage actually does.

3. **Allocation patterns set at mkfs time.** Block size, AG count, inode
   count, journal size — you live with these for the filesystem's lifetime.
   "Default options" is a defensible choice for general workloads; not for
   ones you know are unusual.

4. **`du` ≠ `df` for many reasons.** Reflink shares blocks; preallocation
   reserves space without using it; sparse files have logical >> physical
   size; XFS speculative preallocation; deleted-but-held-open files (`lsof
   +L1`). Don't panic when they disagree; understand why.

5. **TRIM/discard policy is a security knob.** dm-crypt swallows discards
   by default (privacy). Filesystem-level `discard` mount option does
   inline TRIM (latency). `fstrim` from cron is the usual compromise.

6. **Repair is not the first response to errors.** Errors mean: stop,
   capture state, diagnose, then decide. Reflexive `e2fsck -y` can turn
   a fixable problem into a restore-from-backup.

---

## 8. Week 3 → Week 4 Bridge

Week 4: Modern I/O path — NVMe, NVMe-oF, io_uring, ZNS, pmem, cgroup I/O.

**Day 22** — NVMe driver: queue pair model at source level
(`drivers/nvme/host/pci.c`), multi-namespace management, NVMe passthrough.

**Day 23** — NVMe-oF architecture: TCP vs RDMA transport comparison,
discovery protocol, queue allocation, ANA multipathing model.

**Day 24** — NVMe-oF failure handling + O_DIRECT gap-fill: simulating
path failure, reconnect behavior, and a targeted look at the O_DIRECT
kernel path (what BlueStore bypasses and why).

**Day 25** — io_uring deep dive: SQ/CQ rings, fixed buffers, registered
files, NVMe passthrough via `uring_cmd`.

**Day 26** — ZNS: zone types, write pointer, zone append, dm-zoned shim.

**Day 27** — Persistent memory / DAX: how DAX bypasses both page cache and
block layer, the durability model (clwb/sfence), tiering implications.

**Day 28** — cgroup I/O: `io.max`, `io.weight`, `io.latency` — three
distinct enforcement mechanisms and when to use each.

Before starting Week 4, ask yourself:
- You know virtio-blk's queue model. How does NVMe's queue pair model differ?
- You know O_DIRECT (from BlueStore). How does io_uring's fixed-buffer mode
  eliminate a cost that even O_DIRECT pays?
- You know NVMe. What does NVMe-oF/TCP add, and what latency cost does it impose?
- What is a ZNS zone and why can't bcache run on a ZNS device?
If you can answer comfortably, Week 4 will reinforce what you know and add
source-level depth. If not, Week 4 will fill the gaps.

---

## Reference Answer: SaaS Analytics Platform

**1. Layer stack.** The HDDs hold the bulk dataset (4× 16TB = 64TB raw,
~48TB after RAID-6). The NVMes accelerate. Reasonable layout:

```
Application: append-only event ingest, scan for aggregation
   │
   ▼
XFS (one big FS, with directories per tenant + project quota for isolation)
   │
   ▼
dm-cache writeback (using one NVMe partition for cache, other NVMe for metadata)
   │
   ▼
dm-crypt (aes-xts-plain64, sector=4096, no_*_workqueue, allow_discards)
   │
   ▼
md RAID-6 (4× 16TB HDDs, chunk=256K, write-intent bitmap)
```

Encryption at the bottom: every block on persistent media is encrypted,
including the cache. Cost: ~3-5% on NVMe (with workqueue bypass), nearly
invisible on HDD.

Skip md write-journal — RAID-6 partial-stripe penalty matters less for
append-mostly workloads. Bitmap is enough.

**2. Filesystem.** XFS. Reasons:
- Per-tenant directories with project quotas (XFS quota infrastructure is mature)
- No inode-count limit (each tenant may have many files)
- Reflink for nightly backups via `cp --reflink`
- Sequential-append workload benefits from XFS's larger extent sizes
- AG count: 32 — match the 32 cores, give each ingest thread room to run

`mkfs.xfs -m reflink=1 -d agcount=32 -l logdev=<separate nvme partition>`

External log on a small NVMe partition keeps log writes off the HDD —
metadata throughput stays high even as HDDs get pounded by reads.

**3. Encryption.** dm-crypt under everything:
- aes-xts-plain64 with sector_size=4096
- no_read_workqueue, no_write_workqueue (the cache-NVMe perf matters most)
- allow_discards (so dm-cache can free up SSD blocks when data ages out)

LUKS2 keys in TPM2 or sealed against PCRs, with a recovery passphrase
stored offline. Per-node key — losing one drive doesn't compromise the
others.

**4. Tenancy.** Per-tenant directories with XFS project quotas:
```bash
mkdir /data/tenant_42
xfs_quota -x -c "project -s -p /data/tenant_42 42" /data
xfs_quota -x -c "limit -p bsoft=400G bhard=500G 42" /data
```

100 separate filesystems would be wasteful (100 logs, 100 quotas, 100
metadata footprints). Project quotas give isolation without the overhead.

For data isolation (one tenant's data invisible to another), use ordinary
filesystem permissions + per-tenant containers with mount namespaces.

**5. Durability / recovery.**
- Single HDD failure: RAID-6 keeps the array online. Resync from spare
  takes ~6 hours on 16TB drive. RTO=immediate, RPO=0 for committed writes.
- Node failure (whole machine): need replication. RAID protects against
  disk failure, not node failure. RPO depends on application-level
  replication or backup cadence. Nightly backups give RPO ≤ 24h; if
  unacceptable, add Kafka-style replicated ingest.
- dm-cache NVMe failure: writeback mode → up to writeback_rate * latency
  worth of dirty data lost. To get RPO=0 from cache failure, use
  writethrough (acceptable for append-heavy ingest where writes are
  large enough to bypass cache anyway), OR mirror the NVMe cache.
- Filesystem corruption: XFS log recovers automatically. Major
  corruption: restore from backup; the application has nightly snapshots
  via reflink-based cp.

---

## Tomorrow: Day 22 — NVMe Driver: Queue Pairs, Namespaces & Passthrough

We start Week 4 by going deep on the NVMe driver itself: the queue pair
model at source level, multi-namespace management, and NVMe passthrough.
