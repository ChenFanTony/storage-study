# Day 26: ZNS — Zone Types, Write Pointer & Zone Append

## Learning Objectives
- Understand the ZNS zone model and the problem it solves
- Know the zone types, zone states, and the constraints each imposes
- Understand zone append and why it's needed for parallel writes
- Use `null_blk` zoned mode for hands-on testing without ZNS hardware
- Know which software is zone-aware and which needs a shim
- Connect ZNS to the bcache and dm-cache limitations from Week 2

---

## 1. Why ZNS Exists: The FTL Problem

Conventional NVMe SSDs have a Flash Translation Layer (FTL) that:
- Maps logical block addresses to physical NAND pages
- Manages garbage collection internally
- Hides NAND's erase-before-write requirement from the host

**The FTL costs:**

```
DRAM for the FTL mapping table:
  1 TB SSD at 4 KB granularity = 256M mapping entries × 4 bytes = 1 GB DRAM
  Consumer SSDs: cheap DRAM, may lose mapping on power failure (must rebuild)
  Enterprise SSDs: expensive DRAM + capacitors for power loss protection

Write amplification from FTL GC:
  FTL must relocate live data when erasing NAND blocks
  Typical WA: 1.5–3× (depending on workload pattern and overprovisioning)
  Wastes NAND endurance; reduces effective write throughput

Over-provisioning:
  SSDs reserve 7-28% of NAND for FTL GC headroom
  User doesn't see this space; you pay for unusable capacity
```

**ZNS solution: move GC responsibility to the host.**

```
ZNS device exposes zones (aligned to NAND erase blocks):
  Host writes sequentially within zones → no FTL GC needed
  Host resets a zone (an erase) when its data is obsolete
  Result:
    - Minimal DRAM needed (zone state, not per-LBA mapping)
    - No FTL write amplification (host controls data placement)
    - More usable capacity (less overprovisioning)
    - More predictable latency (no FTL GC pauses on the read path)
```

The tradeoff: software must be zone-aware. Random writes don't work
directly; the application or filesystem must place data sequentially.

---

## 2. Zone Types

```c
// include/linux/blkzoned.h

enum blk_zone_type {
    BLK_ZONE_TYPE_CONVENTIONAL   = 0x1,  // random write, no write pointer
    BLK_ZONE_TYPE_SEQWRITE_REQ   = 0x2,  // sequential write REQUIRED
    BLK_ZONE_TYPE_SEQWRITE_PREF  = 0x3,  // sequential write PREFERRED
};

enum blk_zone_cond {
    BLK_ZONE_COND_NOT_WP    = 0x0,  // not write pointer (conventional)
    BLK_ZONE_COND_EMPTY     = 0x1,  // zone empty, wp at zone start
    BLK_ZONE_COND_IMP_OPEN  = 0x2,  // implicitly opened (host wrote to it)
    BLK_ZONE_COND_EXP_OPEN  = 0x3,  // explicitly opened by ZONE OPEN cmd
    BLK_ZONE_COND_CLOSED    = 0x4,  // closed (was open, no writes for now)
    BLK_ZONE_COND_READONLY  = 0xD,  // read-only (degraded but readable)
    BLK_ZONE_COND_FULL      = 0xE,  // zone full (wp at zone end)
    BLK_ZONE_COND_OFFLINE   = 0xF,  // offline (hardware error)
};
```

**Zone constraints that matter:**

```
Sequential write required zones (most ZNS zones):
  - Writes MUST be sequential: each write starts at the write pointer (WP)
  - Write at any other LBA: device returns error (unaligned write error)
  - Cannot overwrite data in a zone (must ZONE RESET first, which erases all)
  - ZONE RESET: erases entire zone, moves WP back to zone start

Conventional zones (small number, typically at start of device):
  - Random write allowed (like a traditional block device region)
  - No write pointer
  - Used for metadata, superblocks, journal-like structures
  - Typically 1-4% of device capacity, depending on device

Open zones limit:
  - Device has a maximum number of simultaneously OPEN zones
    (typically 14, 32, or 128 depending on device)
  - An "open" zone is one being actively written
  - To open a new zone beyond the limit: close an existing one first
  - Hard constraint on parallel write fan-out

Zone capacity ≤ zone size:
  - Zone size is the LBA range a zone occupies
  - Zone capacity may be less (NAND alignment constraints)
  - LBAs past capacity within a zone are unusable
  - blkzone report shows both
```

---

## 3. Zone Append: Parallel Writes Without Coordination

The write pointer constraint creates a parallelism problem:

```
Two threads writing to the same zone:
  Thread A: write to zone 5 at WP=offset 0  ✓ (succeeds, advances WP)
  Thread B: write to zone 5 at WP=offset 0  ✗ (race — WP already advanced)

Traditional solution: serialize writes to each zone (one writer per zone)
  → kills parallel write throughput for workloads that span many threads
```

**Zone Append:**

```
Instead of specifying an exact LBA, the host says:
  "Write at the current WP of this zone; tell me where it landed."

ZONE APPEND command:
  Input:   zone start LBA + data buffer
  Output:  actual LBA where data was written (returned in completion)

Device atomically:
  1. Places data at the current WP
  2. Advances WP by the write length
  3. Returns the actual LBA in the completion

Multiple zone-append commands to the same zone can be in flight simultaneously.
The device serializes them internally — the host doesn't need a lock.
```

```c
// block/blk-zoned.c

// Zone append maps to REQ_OP_ZONE_APPEND:
bio->bi_opf = REQ_OP_ZONE_APPEND;
bio->bi_iter.bi_sector = zone_start;  // zone start, NOT a specific offset

// On completion:
//   bio->bi_iter.bi_sector contains the actual written LBA
//   (the location the device placed the data)
```

Zone append is the key enabler for using ZNS in concurrent-writer
workloads (LSM compaction in RocksDB, multi-stream logging, etc.).

---

## 4. ZNS in the Linux Block Layer

Kernel timeline:
- **4.10**: initial zoned block device support (SCSI ZBC, ATA ZAC for SMR HDDs)
- **4.13**: dm-zoned device mapper target (shim for non-zone-aware software)
- **5.6**: zonefs filesystem (one file per zone)
- **5.8**: zone append in the generic block layer
- **5.9**: NVMe ZNS command set support (`drivers/nvme/host/zns.c`)
- **5.12+**: Btrfs experimental ZNS support
- **5.14.0+**: f2fs production ZNS support

```c
// block/blk-zoned.c — zone management functions

// Report all zones from a device
blkdev_report_zones(bdev, sector, nr_zones, cb, data):
    // Issues REPORT ZONES command
    // Calls cb() for each zone with a struct blk_zone

struct blk_zone {
    __u64   start;      // zone start sector
    __u64   len;        // zone length (sectors)
    __u64   wp;         // write pointer position
    __u64   capacity;   // writable capacity (may be < len for ZNS)
    __u8    type;       // BLK_ZONE_TYPE_*
    __u8    cond;       // BLK_ZONE_COND_*
    // ...
};

// Zone management operations
blkdev_zone_mgmt(bdev, op, sector, nr_sectors, GFP_NOIO):
    // op ∈ { REQ_OP_ZONE_RESET, REQ_OP_ZONE_OPEN,
    //        REQ_OP_ZONE_CLOSE, REQ_OP_ZONE_FINISH }
```

```bash
# Inspect zone layout from userspace
blkzone report /dev/nvme0n1 | head
# Lists: start, length, capacity, wp, type, cond, ...

# Report capacity vs size for each zone
blkzone report /dev/nvme0n1 | awk '{print "zone len:", $3, "cap:", $5}' | head -3

# Reset a zone (the host-initiated erase)
blkzone reset /dev/nvme0n1 --offset 524288 --length 524288
# Erases zone at sector 524288 (256 MB at 512-B sectors)

# Reset all zones (clear the entire device)
blkzone reset /dev/nvme0n1 --offset 0 --count $(cat /sys/block/nvme0n1/queue/nr_zones)
```

---

## 5. Hands-On: null_blk Zoned Mode

null_blk's zoned mode emulates a ZNS device without hardware:

```bash
# Load null_blk
modprobe null_blk

# Remove default device, set up a zoned device manually
echo 0 > /sys/module/null_blk/parameters/nr_devices
modprobe -r null_blk
modprobe null_blk \
    gb=40 \             # 40 GB total
    zoned=1 \           # enable zoned mode
    zone_size=256 \     # 256 MB per zone
    zone_capacity=256 \ # capacity == size (no gap, for testing)
    zone_max_open=8     # max 8 zones can be open simultaneously

ls /dev/nullb*          # /dev/nullb0

# Verify zone configuration
blkzone report /dev/nullb0 | head -5
cat /sys/block/nullb0/queue/chunk_sectors   # zone size in 512-B sectors
cat /sys/block/nullb0/queue/max_open_zones
cat /sys/block/nullb0/queue/max_active_zones

# Sequential write to zone 0 (correct usage)
dd if=/dev/zero of=/dev/nullb0 bs=4096 count=1024 oflag=direct  # 4 MB
blkzone report /dev/nullb0 | head -3
# wp advanced 4 MB into the first zone

# Reset the zone
ZONE_SIZE=$(cat /sys/block/nullb0/queue/chunk_sectors)
blkzone reset /dev/nullb0 --offset 0 --length $ZONE_SIZE
blkzone report /dev/nullb0 | head -3
# Zone back to EMPTY, wp at start

# fio with zone-aware mode
fio --name=zns-seq \
    --filename=/dev/nullb0 \
    --rw=write --bs=128k \
    --ioengine=libaio --iodepth=8 \
    --zonemode=zbd \                # critical: enable zone constraints
    --time_based --runtime=15
# Without zonemode=zbd, fio would issue random writes and fail

# Cleanup
modprobe -r null_blk
```

---

## 6. Zone-Aware Software Stack

```
Zone-aware (can use ZNS directly):
  ✓ f2fs        — flash-friendly filesystem, native ZNS mode
                  (needs an additional small random-write device for SB/NAT)
  ✓ btrfs       — experimental ZNS support (5.12+)
  ✓ zonefs      — minimal filesystem: each zone exposed as a file
  ✓ RocksDB     — with the ZenFS plugin (zone-aware SSTable + LSM compaction)
  ✓ SPDK        — full zone support in its userspace NVMe driver
  ✓ fio         — zbd engine for benchmarking
  ✓ dm-zoned    — device mapper target: emulates random writes on ZNS
  ✓ Ceph        — RGW/RADOS zone-awareness (work in progress as of 2024-25)

Not zone-aware (cannot use ZNS without a shim):
  ✗ ext4        — random writes to journal and metadata
  ✗ XFS         — random writes to AG headers and log
  ✗ bcache      — GC compaction emits writes to arbitrary cache locations (Day 10)
  ✗ Most databases — InnoDB, PostgreSQL heap tables require random writes
```

---

## 7. zonefs: The Minimal Zone-Aware Filesystem

zonefs deserves special mention. It's deliberately minimal:

```
zonefs structure:
  /mnt/zns/
    seq/                  — one directory per zone type
      0, 1, 2, ...        — one file per sequential-write-required zone
    cnv/                  — conventional zones (if any)
      0, 1, 2, ...

Semantics:
  Each file represents exactly one zone (1:1 mapping)
  Sequential-zone files: write only via append (O_APPEND)
                         or O_DIRECT writes at end-of-file offset
  Truncate to 0 = zone reset (erase)
  Read: standard POSIX read from any offset
```

```bash
modprobe zonefs
mkfs.zonefs /dev/nvme0n1   # writes a superblock; no other metadata
mount -t zonefs /dev/nvme0n1 /mnt/zns

ls /mnt/zns/seq/
# 0  1  2  3  ...  (each is a file representing one zone)

# Append to a zone (must use O_APPEND or write at exact end)
echo "data" >> /mnt/zns/seq/0

# Reset a zone: truncate to 0
truncate -s 0 /mnt/zns/seq/0
```

zonefs is the right choice when an application wants ZNS access through
POSIX file APIs without the complexity of f2fs. RocksDB's ZenFS plugin
is conceptually similar (one zone per SSTable extent).

---

## 8. dm-zoned: Making ZNS Look Like Random-Write

For software that can't be made zone-aware, `dm-zoned` provides a
compatibility shim:

```
dm-zoned architecture:
  Exposes: a regular random-write block device
  Underneath: a ZNS device

  Mechanism:
    - Uses conventional zones (or a separate fast random-write device)
      for metadata
    - Buffers random writes in sequential zones (log-structured)
    - Background reclaim: compacts sparse zones to free space

  Cost: write amplification from compaction (similar to FTL GC)
        defeats the purpose of ZNS for performance
  
  Use: compatibility — run existing software on ZNS without rewrites
  Not for: high-performance ZNS deployments where the benefits are needed
```

The right way to think about dm-zoned: it makes "ZNS device + dm-zoned"
behave equivalently to a conventional SSD (with similar overhead), so
unmodified software works. It's a transitional tool, not a destination.

---

## 9. Architectural Implications

ZNS changes the storage software model fundamentally:

```
Traditional: host writes anywhere → SSD FTL manages placement
ZNS:         host manages data placement → SSD executes sequentially

Applications that benefit most:
  LSM-tree databases (RocksDB, LevelDB, Cassandra):
    - Already write sequentially (compaction output IS sequential)
    - With ZenFS: RocksDB maps compaction levels to zones explicitly
    - No FTL GC conflict with application-level compaction
    - Significantly lower write amplification, predictable latency

  Log-structured filesystems (f2fs, btrfs):
    - Already write sequentially by design
    - Natural fit for zone model

  Append-only ingest (Kafka brokers, log shippers):
    - Sequential append matches zone constraints

Applications that don't benefit:
  - Random-write databases (PostgreSQL heap, InnoDB)
  - Need dm-zoned → loses ZNS benefits
  - Conventional NVMe is the right choice
```

### Why bcache can't run on a ZNS cache device (recap from Day 10)

bcache violates zone constraints in two specific places:
- **GC compaction**: relocates live data from sparse buckets to fresh
  buckets at arbitrary cache locations — these are random writes from
  the device's perspective.
- **btree updates**: bcache's btree node updates write to arbitrary
  SSD locations as the tree grows and rebalances.

Both patterns violate the sequential-write requirement on ZNS sequential
zones. To run bcache on ZNS you'd need dm-zoned underneath, which defeats
the whole purpose.

---

## 10. Source Reading Checklist

```
block/blk-zoned.c            — generic zoned block device support
include/linux/blkzoned.h     — zone types, conditions, structs
drivers/nvme/host/zns.c      — NVMe ZNS command set integration
drivers/block/null_blk_zoned.c — null_blk zoned emulation
drivers/md/dm-zoned*.c       — dm-zoned target
fs/zonefs/*                  — zonefs filesystem
fs/f2fs/super.c, fs/f2fs/segment.c — f2fs zone awareness
```

Reading order: `blkzoned.h` first (the protocol-level structs and
states), then `blk-zoned.c` for the kernel's generic zone APIs, then
either `zns.c` (NVMe-specific) or `null_blk_zoned.c` (easier to read,
no hardware needed).

---

## 11. Self-Check Questions

1. What problem does ZNS solve that conventional NVMe SSDs handle internally with the FTL?
2. Why does zone append enable parallel writes to the same zone without host-level coordination?
3. What is `max_open_zones` and how does it constrain a parallel-writer workload?
4. Recap from Day 10: bcache cannot run on a ZNS device as the cache. Name the two specific bcache operations that violate zone constraints.
5. A RocksDB deployment wants to use ZNS for compaction. What component makes this work and what does it do?
6. You have a ZNS device and need to run an ext4 filesystem on it. What is your only option, and what performance tradeoff does it impose?
7. zonefs vs f2fs vs dm-zoned — which would you recommend for each of: (a) an LSM database, (b) an unmodified PostgreSQL, (c) a custom application that wants direct zone access via files?

## 12. Answers

1. ZNS eliminates the need for a host-side flash translation layer (FTL) that maps logical to physical addresses and manages internal GC. The FTL costs significant DRAM (~1 GB per TB at 4 KB granularity), causes write amplification (1.5–3×), requires overprovisioning (7-28% reserved capacity), and causes unpredictable GC latency spikes. ZNS moves these responsibilities to the host: the device is simpler, cheaper to manufacture, and gives the host control over data placement.
2. Zone append specifies the zone (not an exact LBA). The device places data at the current write pointer and returns the actual LBA in the completion. Multiple in-flight zone-append commands to the same zone are serialized internally by the device — the host doesn't need a lock or coordination mechanism. Each thread issues zone append and finds out where its data landed from the completion. This converts the zone's sequential-write requirement from a coordination problem to a return-value problem.
3. `max_open_zones` limits how many zones can simultaneously be in OPEN state (actively receiving writes). For parallel workloads — say, an LSM compaction wanting to write to 16 SSTables concurrently — if `max_open_zones=8`, you must close some zones before opening new ones. Zone allocation strategy must respect this limit; otherwise the device returns "too many open zones" errors. Choosing concurrency in the application means knowing the device's limit.
4. (1) **GC compaction**: bcache relocates live data from a partially-empty bucket to a new bucket at an arbitrary cache-device offset — this is a random write violating the sequential-write requirement. (2) **B-tree node updates**: bcache's internal btree updates write to arbitrary cache locations as the tree grows, rebalances, and updates entries — also random writes.
5. ZenFS — a RocksDB plugin that implements a zone-aware filesystem abstraction for RocksDB's storage interface. ZenFS maps RocksDB's SSTable files and WAL to zones: compaction output (a new SSTable) goes to a fresh zone (sequential write); expired SSTables trigger zone resets; the `max_open_zones` limit is respected by controlling compaction parallelism. The result is RocksDB on ZNS with near-zero device-level WA.
6. Use `dm-zoned` — a device mapper target that emulates a random-write block device on top of ZNS. You lose nearly all ZNS benefits (WA returns due to dm-zoned's own compaction overhead, similar in magnitude to an FTL), but ext4 runs unmodified on the dm-zoned virtual device. The tradeoff: similar overall WA to a conventional SSD; you get to run unmodified software, but you lose the cost reduction that motivated buying a ZNS device.
7. (a) **LSM database**: f2fs or zonefs+ZenFS. f2fs gives a normal POSIX-mounted filesystem; ZenFS is purpose-built for RocksDB and gives lower overhead. (b) **PostgreSQL**: dm-zoned (the only option — PostgreSQL is random-write). Accept the WA cost; PG can't use ZNS natively. (c) **Custom application wanting direct zone access via files**: zonefs. One file per zone, POSIX semantics for sequential append and zone reset, no filesystem metadata overhead.

---

## Tomorrow: Day 27 — Persistent Memory / DAX Path

We understand how DAX bypasses BOTH the page cache and the block layer,
the durability model (clwb/sfence instead of fsync), the implications
for tiering architecture, and how to emulate pmem for hands-on testing.
