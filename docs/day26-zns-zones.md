# Day 26: ZNS — Zone Types, Write Pointer & Zone Append

## Learning Objectives
- Understand ZNS zone model and why it exists (what problem it solves)
- Know the four zone types and their constraints
- Understand zone append command and why it's needed for parallelism
- Use `null_blk` zoned mode for hands-on testing without ZNS hardware
- Know which software is zone-aware and which is not
- Connect ZNS to the tiering and bcache limitations from Week 2

---

## 1. Why ZNS Exists: The FTL Problem

Conventional NVMe SSDs have a Flash Translation Layer (FTL) that:
- Maps logical block addresses to physical NAND pages
- Manages garbage collection internally
- Hides NAND's erase-before-write requirement from the host

**The FTL costs:**
```
DRAM for FTL mapping table:
  1TB SSD at 4KB granularity = 256M mapping entries × 4 bytes = 1GB DRAM
  Consumer SSDs: use cheap DRAM, lose mapping on power failure (flush to NAND)
  Enterprise SSDs: expensive DRAM + capacitors for power loss protection

Write amplification from FTL GC:
  FTL must move live data when erasing blocks → WA of 1.5-3×
  WA wastes NAND endurance and reduces effective write throughput

Over-provisioning:
  SSDs reserve 7-28% of NAND for FTL GC headroom
  User doesn't see this space
```

**ZNS solution: move GC responsibility to the host**
```
ZNS device exposes zones (aligned to NAND erase blocks)
Host writes sequentially within zones → no FTL GC needed
Host resets zones (erase) when data is no longer needed
Result:
  - Minimal DRAM needed (zone state tracking, not per-LBA mapping)
  - No FTL write amplification (host controls data placement)
  - More usable capacity (less over-provisioning needed)
  - More predictable latency (no FTL GC pauses)
```

---

## 2. Zone Types

```c
// include/linux/blkzoned.h

enum blk_zone_type {
    BLK_ZONE_TYPE_CONVENTIONAL   = 0x1,  // random write, no write pointer
    BLK_ZONE_TYPE_SEQWRITE_REQ   = 0x2,  // sequential write REQUIRED
    BLK_ZONE_TYPE_SEQWRITE_PREF  = 0x3,  // sequential write PREFERRED
    BLK_ZONE_TYPE_SEQ_OR_BEFORE  = 0x4,  // sequential or before wp
};

enum blk_zone_cond {
    BLK_ZONE_COND_NOT_WP    = 0x0,  // not write pointer (conventional)
    BLK_ZONE_COND_EMPTY     = 0x1,  // zone is empty, wp at start
    BLK_ZONE_COND_IMP_OPEN  = 0x2,  // implicitly opened (host wrote to it)
    BLK_ZONE_COND_EXP_OPEN  = 0x3,  // explicitly opened by ZONE OPEN cmd
    BLK_ZONE_COND_CLOSED    = 0x4,  // closed (was open, no more writes for now)
    BLK_ZONE_COND_READONLY  = 0xD,  // read only
    BLK_ZONE_COND_FULL      = 0xE,  // zone full (wp at end)
    BLK_ZONE_COND_OFFLINE   = 0xF,  // offline (hardware error)
};
```

**Zone constraints that matter:**

```
Sequential write required zones (most NAND zones):
  - Writes MUST be sequential: each write starts at write pointer (WP)
  - Write to wrong location: device returns error
  - Cannot overwrite data in zone (must ZONE RESET first)
  - ZONE RESET: erases entire zone, moves WP to zone start

Conventional zones (small number, at start of device):
  - Random write allowed (like traditional block device)
  - No write pointer
  - Used for metadata, superblocks, journal
  - Typically 1-4% of device capacity

Open zones limit:
  - Device has max_open_zones limit (often 14-128)
  - An "open" zone is one being actively written
  - Exceeding open zone limit: must close a zone before opening another
  - Fundamental constraint for parallel write workloads
```

---

## 3. Zone Append: Parallelism Without Coordination

The write pointer constraint creates a parallelism problem:

```
Problem: two threads writing to same zone
  Thread A: write to zone 5 at WP=offset 0 ✓
  Thread B: write to zone 5 at WP=offset 0 ✗ (race — who gets the slot?)

Traditional solution: serialize writes to each zone (one writer at a time)
  → kills parallel write throughput

Zone Append solution:
  Instead of specifying exact LBA: "write at current WP, tell me where it went"

ZONE APPEND command:
  Input:  zone start LBA, data buffer
  Output: actual LBA where data was written (returned in completion)
  
  Device atomically:
    1. Places data at current WP
    2. Advances WP
    3. Returns actual LBA in completion

  Multiple zone append commands to same zone can be in-flight simultaneously
  Device serializes them internally — host doesn't need to coordinate
```

```c
// block/blk-zoned.c

// Zone append maps to REQ_OP_ZONE_APPEND operation:
bio->bi_opf = REQ_OP_ZONE_APPEND;
bio->bi_iter.bi_sector = zone_start;  // zone start, NOT specific offset
// Data goes wherever the device puts it
// On completion: bio->bi_iter.bi_sector contains actual written LBA
```

---

## 4. ZNS in the Linux Block Layer

```c
// block/blk-zoned.c — zone management functions

// Report all zones (get zone list from device)
blkdev_report_zones(bdev, sector, nr_zones, cb, data):
    // Sends REPORT ZONES command to device
    // Returns array of struct blk_zone

struct blk_zone {
    __u64   start;      // zone start sector
    __u64   len;        // zone length (sectors)
    __u64   wp;         // write pointer position
    __u8    type;       // BLK_ZONE_TYPE_*
    __u8    cond;       // BLK_ZONE_COND_*
    // ...
};

// Reset a zone (erase and reset write pointer)
blkdev_zone_mgmt(bdev, REQ_OP_ZONE_RESET, sector, nr_sectors, GFP_NOIO):
    // Sends ZONE RESET command
    // Zone becomes EMPTY, wp=zone_start
```

```bash
# Inspect zone layout
blkzone report /dev/nvme0n1 | head -20
# Shows: zone number, start, length, wp, type, condition

# Zone capacity (may be less than zone size)
blkzone report /dev/nvme0n1 | awk '{print $3, $5}' | head -5
# Some zones: capacity < length (NAND geometry constraint)

# Reset a zone
blkzone reset /dev/nvme0n1 --offset 524288 --length 524288
# Erases zone at offset 524288 sectors (256MB at 512B sectors)
```

---

## 5. Hands-On: null_blk Zoned Mode

```bash
# Create a zoned null_blk device (no real hardware needed)
modprobe null_blk

# Configure zoned device
echo 0 > /sys/module/null_blk/parameters/nr_devices  # remove existing

# Create zoned null_blk
modprobe -r null_blk
modprobe null_blk \
    gb=40 \           # 40GB device
    zoned=1 \         # enable zoned mode
    zone_size=256 \   # 256MB per zone
    zone_capacity=256 \ # zone capacity == zone size (for null_blk)
    zone_max_open=8   # max 8 open zones simultaneously

ls /dev/nullb*        # should show /dev/nullb0

# Verify zone configuration
blkzone report /dev/nullb0 | head -20
cat /sys/block/nullb0/queue/chunk_sectors   # zone size in sectors
cat /sys/block/nullb0/queue/max_open_zones
cat /sys/block/nullb0/queue/max_active_zones

# Write to zone sequentially (correct)
dd if=/dev/zero of=/dev/nullb0 bs=4096 count=1024  # 4MB at start of zone
blkzone report /dev/nullb0 | head -3
# wp should have advanced 4MB

# Attempt random write (incorrect - should fail on real ZNS)
# null_blk may not enforce this — real hardware does

# Reset zone
blkzone reset /dev/nullb0 --offset 0 --length $(cat /sys/block/nullb0/queue/chunk_sectors)
blkzone report /dev/nullb0 | head -3
# wp back to 0, condition EMPTY

# Test with fio (zone-aware sequential write)
fio --name=zns-write \
    --filename=/dev/nullb0 \
    --rw=write \
    --bs=128k \
    --ioengine=libaio \
    --iodepth=8 \
    --zonemode=zbd \          # zone block device mode
    --zoneskip=0 \
    --time_based --runtime=30
```

---

## 6. Zone-Aware Software Stack

```
Zone-aware (can use ZNS directly):
  ✓ f2fs        — flash-friendly filesystem, has ZNS mode
  ✓ btrfs       — experimental ZNS support (kernel 5.12+)
  ✓ zonefs      — simple filesystem: one file per zone
  ✓ RocksDB     — with ZenFS plugin (zone-aware LSM compaction)
  ✓ SPDK        — full zone support in NVMe driver
  ✓ fio         — zbd engine for testing
  ✓ dm-zoned    — device mapper target: makes ZNS look like random-write

Not zone-aware (cannot use ZNS directly):
  ✗ ext4        — random writes to journal and metadata
  ✗ XFS         — random writes to AG headers and log
  ✗ bcache      — GC compaction writes to arbitrary locations (Day 10)
  ✗ Most databases — require random write access
```

---

## 7. dm-zoned: Making ZNS Look Like Random-Write

For software that can't be made zone-aware, `dm-zoned` provides a shim:

```
dm-zoned architecture:
  Exposes: regular random-write block device
  Underneath: ZNS device

  Mechanism:
    - Uses small portion of conventional zones for metadata
    - Buffers random writes in sequential zones (like a log)
    - Background reclaim: compacts zones when they become sparse
    
  Cost: write amplification from compaction (similar to SSD FTL)
        defeats the purpose of ZNS for high-performance
  
  Use: compatibility layer for software not yet ZNS-aware
       NOT for production ZNS deployments where ZNS benefits are needed
```

---

## 8. ZNS Architecture Implications

**For storage architects:**
```
ZNS changes the storage software model fundamentally:
  Traditional: host writes anywhere → SSD FTL manages placement
  ZNS: host manages data placement → SSD executes sequentially

Applications that benefit most from ZNS:
  LSM-tree databases (RocksDB, LevelDB, Cassandra):
    - Already write sequentially (compaction output is sequential)
    - With ZenFS: RocksDB maps compaction levels to zones
    - No FTL GC conflict with application GC
    - Significantly lower write amplification

  Log-structured filesystems (f2fs, btrfs):
    - Already write sequentially by design
    - Natural fit for ZNS zone model

Applications that don't benefit:
  - Random-write databases (PostgreSQL, MySQL with InnoDB heap tables)
  - Need dm-zoned shim → loses ZNS benefits
```

---

## 9. Self-Check Questions

1. What problem does ZNS solve that conventional NVMe SSDs handle internally?
2. Why does zone append enable parallel writes to the same zone without host coordination?
3. What is the `max_open_zones` limit and why does it matter for parallel workloads?
4. bcache cannot run on ZNS device as the cache device (Day 10). Name the two specific operations that violate zone constraints.
5. A RocksDB deployment wants to use ZNS. What component makes this possible and what does it do?
6. You have a ZNS device and need to run an ext4 filesystem on it. What is your only option and what performance tradeoff does it impose?

## 10. Answers

1. ZNS eliminates the need for an FTL (Flash Translation Layer) that maps logical to physical addresses and manages internal GC. The FTL costs DRAM, causes write amplification (1.5-3×), requires over-provisioning, and causes unpredictable GC latency spikes. ZNS moves these responsibilities to the host, reducing device complexity and cost.
2. Zone append specifies the zone (not exact LBA). The device places data at the current write pointer and returns the actual LBA in the completion. Multiple in-flight zone append commands to the same zone are serialized internally by the device — the host doesn't need a lock or coordination mechanism. Each host thread just issues zone append and finds out where its data landed from the completion.
3. `max_open_zones` limits how many zones can simultaneously be in OPEN state (actively receiving writes). This limits write parallelism: if you want to write to 16 zones simultaneously but max_open_zones=8, you must close some zones before opening new ones. For parallel workloads (multi-threaded SST file writing in RocksDB), this is a key constraint in zone allocation design.
4. (1) GC compaction: bcache reads live data from a partially-full bucket and writes it to a new bucket at an arbitrary location — this random write violates zone constraints. (2) btree updates: bcache's btree node updates write to arbitrary SSD locations as the btree grows and rebalances — also random writes violating zone constraints.
5. ZenFS — a RocksDB plugin that implements a zone-aware file system abstraction for RocksDB's storage interface. ZenFS maps RocksDB's SST files and WAL to zones, ensuring compaction output goes to fresh zones (sequential writes), expired SST files trigger zone resets, and the open zone limit is respected by controlling compaction parallelism.
6. Use `dm-zoned` — a device mapper target that emulates a random-write block device on top of ZNS. You lose all ZNS benefits (write amplification returns due to dm-zoned compaction, similar to FTL), but ext4 can run on the dm-zoned device without modification. The tradeoff: essentially the same WA as a conventional SSD, no cost reduction, but you get to run unmodified software.

---

## Tomorrow: Day 27 — Persistent Memory / DAX Path

We understand how DAX bypasses BOTH page cache and block layer,
the implications for tiering architecture, and how to emulate pmem
for hands-on testing using kernel `memmap` parameter.
