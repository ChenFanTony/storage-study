# Day 21: Week 3 Review — Filesystem Architecture Decisions

## Objective
Produce a written filesystem decision guide and work through a full-stack
design scenario that integrates dm-crypt, RAID, and filesystem choice.
This is your Week 3 output.

---

## 1. Week 3 Competency Check

Verify you can answer without notes. Mark gaps for re-study.

| Question | Confident? |
|----------|-----------|
| What the RAID-5 write hole is and when it causes data corruption | |
| Write-intent bitmap: how it reduces resync time from hours to minutes | |
| XFS AG model: why it enables parallel metadata operations | |
| XFS logical logging vs JBD2 block logging: key difference | |
| XFS CIL: what it does and what durability tradeoff it makes | |
| When XFS log exhaustion occurs and how to prevent it | |
| ext4 data=ordered: exactly what is ordered and what gap remains | |
| ext4 data=writeback: why it can expose garbage data | |
| Btrfs CoW B-tree: how instant snapshots are possible | |
| Btrfs send/receive incremental: why transfer is small | |
| dm-crypt IV modes: security difference between plain and xts | |
| dm-crypt stack ordering with dm-cache: which protects cache at rest | |

---

## 2. Filesystem Decision Guide (Produce This Today)

Write your reference. Fill in these tables before checking answers.

### Primary Filesystem Selection

| Workload | Filesystem | Key Reason |
|----------|-----------|-----------|
| High-concurrency file creation (containers, builds) | | |
| Large sequential files (video, backups, databases) | | |
| Simple general purpose, ops team knows it well | | |
| Backup destination with incremental snapshots | | |
| Archival with bit-rot detection requirement | | |
| Database with O_DIRECT | | |

### ext4 Journal Mode Selection

| Application | Mode | Reason |
|-------------|------|--------|
| PostgreSQL with fsync | | |
| NFS server export | | |
| High-throughput log ingestion | | |
| Critical system config files | | |

### XFS Sizing Rules

Fill in your values:
- AG count for a 16-core server: ?
- Log size for busy metadata workload: ?
- When to use external log device: ?
- When to use reflink: ?

---

## 3. Scenario: Full-Stack Design Review

**Customer brief:**
A media company stores and serves video assets:
- 2PB total storage, growing 20TB/month
- 50,000 files averaging 40GB each (long-form video)
- Access pattern: write once (ingest), read many times (streaming)
- Compliance: files must be encrypted at rest (AES-256)
- Resilience: tolerate 2 simultaneous disk failures
- Team has strong Linux/XFS experience, no Btrfs experience
- Hardware: 4 nodes, each with 24× 20TB HDD + 2× 2TB NVMe

**Design questions:**

1. **RAID level:** Given 24 HDDs per node and the 2-failure tolerance requirement,
   which RAID level would you choose? Calculate usable capacity per node.
   At what array size does RAID-6 become mandatory over RAID-5?

2. **Filesystem choice:** XFS or Btrfs? The customer mentioned that detecting
   storage corruption over years is important. Does this change your answer?

3. **Encryption:** The stack is: `filesystem → dm-crypt → RAID → HDD`.
   Is this ordering correct for encrypt-at-rest? What IV mode and key size?
   What is the performance impact of dm-crypt on large sequential reads?

4. **XFS tuning for this workload:**
   - Large files (40GB), write-once, read-many
   - 2PB filesystem, 24-core nodes
   - What AG count and log size would you set?
   - What mount options?
   - `data=ordered` or `data=writeback`?

5. **NVMe role:** 2× 2TB NVMe per node, given the access pattern. Propose
   a specific use for each NVMe. Justify at the architecture level.

6. **Incremental backup strategy:** The customer wants daily backups with
   minimal storage cost. They currently do full rsync daily (expensive).
   You cannot change the primary filesystem (XFS). What backup mechanism
   would you propose that achieves incremental efficiency without Btrfs
   on the primary filesystem?

**Reference answers at end of document.**

---

## 4. Hands-On: Stack Verification

Build the full stack on loopback and verify it works end to end:

```bash
# 1. Create test "HDDs"
for i in $(seq 0 5); do
    dd if=/dev/zero of=/tmp/disk${i}.img bs=1M count=1024
    DISK[$i]=$(losetup --find --show /tmp/disk${i}.img)
done

# 2. RAID-6 (4 data + 2 parity)
mdadm --create /dev/md0 --level=6 --raid-devices=6 \
    ${DISK[0]} ${DISK[1]} ${DISK[2]} ${DISK[3]} ${DISK[4]} ${DISK[5]}
cat /proc/mdstat

# 3. dm-crypt on top of RAID
cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 --batch-mode \
    --key-file /dev/urandom /dev/md0

cryptsetup open /dev/md0 encrypted_raid --key-file /dev/urandom

# 4. XFS on top of dm-crypt
mkfs.xfs -d agcount=8 -l size=512m /dev/mapper/encrypted_raid
mount /dev/mapper/encrypted_raid /mnt/stack-test

# 5. Verify stack
dmsetup deps /dev/mapper/encrypted_raid
# Should show dependency on md0

xfs_info /mnt/stack-test

# 6. Write a large file and measure throughput
dd if=/dev/zero of=/mnt/stack-test/testfile bs=1M count=1024 \
    oflag=direct status=progress
# Measure: how much overhead does the full stack add?

# 7. Simulate one disk failure during read
mdadm --fail /dev/md0 ${DISK[2]}
dd if=/mnt/stack-test/testfile of=/dev/null bs=1M status=progress
# Should still read successfully (RAID-6 tolerates 1 failure)
md5sum /mnt/stack-test/testfile   # data integrity check

# Cleanup
umount /mnt/stack-test
cryptsetup close encrypted_raid
mdadm --stop /dev/md0
for d in "${DISK[@]}"; do losetup -d $d; done
```

---

## 5. Tools Drill: Week 3 Commands

Run without looking up syntax:

```bash
# dm-crypt
cryptsetup luksDump /dev/sda1
cryptsetup benchmark
cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 /dev/sda1

# md/RAID
cat /proc/mdstat
mdadm --detail /dev/md0
mdadm --fail /dev/md0 /dev/sdb
mdadm --add /dev/md0 /dev/sdc
echo 100000 > /sys/block/md0/md/sync_speed_max

# XFS
xfs_info /mnt/xfs
xfs_bmap -v /mnt/xfs/largefile
xfs_db -r /dev/sda -c "freesp -d"
xfs_logprint /dev/sda | tail -20
xfs_repair -n /dev/sda    # dry run

# ext4/JBD2
tune2fs -l /dev/sdb | grep -E "Journal|journal"
debugfs /dev/sdb -R "logdump -c"
mount -o data=ordered /dev/sdb /mnt/ext4

# Btrfs
btrfs subvolume snapshot -r /mnt/btrfs/data /mnt/btrfs/snap_$(date +%Y%m%d)
btrfs send -p /mnt/btrfs/snap_yesterday /mnt/btrfs/snap_today | wc -c
btrfs scrub start /mnt/btrfs
btrfs filesystem defragment -r /mnt/btrfs/data
```

---

## 6. Week 3 → Week 4 Bridge

Week 4: Modern I/O path — NVMe, NVMe-oF, io_uring, ZNS, pmem.

Before starting, ask yourself:
- You know virtio-blk's queue model. How does NVMe's queue pair model differ?
- You know O_DIRECT (from BlueStore). How does io_uring's fixed-buffer mode
  eliminate a cost that even O_DIRECT pays?
- You know NVMe. What does NVMe-oF/TCP add, and what latency cost does it impose?
- What is a ZNS zone and why can't bcache run on a ZNS device?

Week 4 will answer the last two in depth. The first two will be fast-pass
given your existing knowledge — focus will be on the source-level details
and the architect's decision points that blogs don't cover.

---

## Reference Answers: Media Storage Scenario

**1. RAID level:**
RAID-6 (requires 2-failure tolerance — RAID-5 cannot meet this).
24 disks RAID-6: usable = (24-2) × 20TB = 440TB per node × 4 nodes = 1.76PB usable.
RAID-5 becomes inadequate at any array size where rebuild time × URE probability
exceeds acceptable risk. For 20TB HDDs: rebuild reads ~22 × 20TB = 440TB per failed
disk; at consumer URE rate (1/10^14 bits), ~5 URE events expected during rebuild.
RAID-6 is mandatory for any array with disks >4TB or >6 drives.

**2. Filesystem:**
XFS with external checksumming (or accept the gap). The team knows XFS, which
is the right answer for 40GB large files with parallel access. However, XFS does
not checksum file data (only metadata in newer versions). To address bit-rot
detection: add periodic `sha256sum` verification runs (cron), or use a checksumming
layer above the filesystem. Btrfs would give native checksums but the team
has no experience and Btrfs on 2PB with heavy write-once ingest is risky.
Pragmatic answer: XFS + periodic integrity verification.

**3. Encryption ordering:**
`filesystem → dm-crypt → RAID → HDD` — this IS correct. dm-crypt sits above
RAID, so all data written to RAID devices is encrypted. The filesystem sees
plaintext; dm-crypt encrypts before data reaches RAID.
IV mode: `aes-xts-plain64`, key size 512 bits (2×256-bit XTS keys).
Performance impact on large sequential reads: minimal with AES-NI hardware.
AES-XTS at 2-4GB/s on modern CPUs; 24×20TB HDD saturates at ~3.6GB/s aggregate —
dm-crypt will not be the bottleneck. Queue depth matters: run at iodepth≥32.

**4. XFS tuning:**
- AG count: 24 cores → 24 AGs (one per core for parallel allocation).
  But filesystem size constrains AG size: 440TB / 24 AGs = ~18TB per AG.
  18TB AG is within XFS limits (max ~16TB in older kernels, larger in 6.x).
  Use `agcount=24` or let mkfs auto-calculate for large filesystem.
- Log size: write-once ingest at 20TB/month = heavy metadata activity.
  Use 2GB internal log or external log on NVMe.
- Mount options: `noatime,nodiscard,logbufs=8,logbsize=256k,largeio`
- Journal mode: `data=ordered` (default, appropriate). For write-once video
  files, writeback gives marginal gain; ordered is safer and the overhead
  is irrelevant for large sequential writes.

**5. NVMe role:**
- NVMe 0 (2TB): XFS external log (`mkfs.xfs -l logdev=/dev/nvme0`).
  Separates journal I/O from data I/O — eliminates HDD head contention
  between log checkpoints and video ingest writes.
- NVMe 1 (2TB): Read cache (dm-cache) for hot video content.
  Video streaming is read-heavy once ingested. Cache recently accessed
  video segments in NVMe to reduce HDD read load. Use writethrough mode
  (write-once assets — no benefit from writeback; simpler failure semantics).

**6. Incremental backup without Btrfs on primary:**
Options in order of preference:
1. **LVM snapshots + `rsync --link-dest`**: Take LVM snapshot of XFS volume
   daily, rsync changed files to backup with hardlinks for unchanged files.
   Space-efficient on backup destination.
2. **Restic or Borg Backup**: Content-addressable backup with deduplication.
   Only changed blocks transferred; efficient incremental. Works on any filesystem.
3. **ZFS on backup destination**: Send data from XFS via rsync to ZFS backup
   server; ZFS manages incremental snapshots on the backup side.
   Best option: Restic to object storage (S3/Ceph RGW) gives scalable,
   content-deduplicated backups without filesystem constraints.
