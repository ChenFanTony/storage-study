# Day 14: Week 2 Review — Tiering Architecture Decisions

## Objective
Produce a written "Tiering Architecture Decision Guide" you would actually
hand to a customer or use in a design review. This is your Week 2 output.

---

## 1. Week 2 Competency Check

Verify you can answer these without notes. Mark gaps for re-study.

| Question | Confident? |
|----------|-----------|
| bcache bucket lifecycle: free → open → closed → GC → free | |
| What causes bcache GC pressure and how to detect it | |
| What data is lost in bcache writeback on SSD hardware failure | |
| What the bcache journal protects and what it does NOT protect | |
| At what IOPS does bcache btree contention become visible | |
| How SMQ policy's probabilistic promotion protects against thrashing | |
| dm-cache cache block size vs bcache bucket size — what each controls | |
| Why dm-thin metadata device failure affects ALL thin LVs in the pool | |
| COW snapshot mechanics: when triggered, what cost | |
| The difference in RTO between SSD hardware failure and system crash | |

---

## 2. The Tiering Decision Guide (Produce This Today)

Write a document you would use in a real architecture review.
Reference answers are provided at the end — but write your version first.

### Section 1: Technology Selection

Fill in this decision matrix:

**Choose bcache when:**
(your criteria — minimum 4 conditions)

**Choose dm-cache when:**
(your criteria — minimum 4 conditions)

**Don't use block-level caching when:**
(your criteria — minimum 3 conditions)

### Section 2: Cache Mode Selection

| Requirement | Cache Mode | Reasoning |
|-------------|-----------|-----------|
| RPO=0 (no data loss) | | |
| Maximum write performance | | |
| Read acceleration only | | |
| Decommissioning cache | | |

### Section 3: Failure Tolerance Matrix

For each scenario, specify: data loss? recovery time? recovery procedure?

| Scenario | bcache writeback | bcache writethrough | dm-cache writeback | dm-cache writethrough |
|----------|-----------------|--------------------|--------------------|----------------------|
| SSD hardware failure | | | | |
| System crash | | | | |
| Graceful shutdown | | | | |

### Section 4: Sizing Guidelines

Fill in the sizing rules you learned this week:

**bcache bucket size:**
- Default: ?
- When to increase: ?
- Trade-off: ?

**dm-cache block size:**
- Default: ?
- For 4K random workload: ?
- For sequential workload: ?

**dm-thin metadata device:**
- Sizing formula: ?
- Protection requirement: ?

---

## 3. Scenario: Architecture Design Review

**Customer brief:**
A cloud provider is building a new storage tier for their VM fleet.
The design under discussion:

- 4× storage nodes, each with: 2× NVMe (fast tier) + 8× HDD (capacity tier)
- Each storage node exports NVMe-oF/TCP namespaces to 40 compute nodes
- Compute nodes run VMs with mixed workloads: OLTP databases, log ingestion,
  and nightly bulk analytics jobs
- Each storage node will run dm-cache: NVMe cache in front of HDD pool
- dm-thin provides thin provisioning; snapshots used for VM backups
- RPO: 1 hour (hourly snapshots) — NOT zero
- RTO: 30 minutes
- Total capacity per node: 64TB HDD, 4TB NVMe

**Design questions:**

1. **Cache mode:** RPO is 1 hour, not zero. Does this change your cache mode
   recommendation from writethrough to writeback? What is the exact risk you
   are accepting, and what mitigates it given the snapshot schedule?

2. **dm-thin + dm-cache interaction:** The stack is:
   `NVMe-oF namespace → dm-cache (NVMe cache / HDD origin) → dm-thin pool → thin LVs`
   A compute node's VM is doing heavy random writes. Walk through exactly what
   happens at each layer for a write that misses the cache. What is the
   write amplification factor in the worst case?

3. **Snapshot strategy:** Hourly thin snapshots are taken for backup.
   After 24 hours there are 24 snapshots per thin LV. The analytics job
   runs a full table scan at 02:00. What happens to the dm-thin COW overhead
   during the scan, and how does this interact with dm-cache behavior?

4. **Metadata sizing:** Each storage node has 200 thin LVs (VMs) with an
   average of 300GB provisioned each. NVMe cache is 4TB with 512KB dm-cache
   block size. Size both the dm-thin metadata device and the dm-cache
   metadata device. What RAID level for each?

5. **Failure scenario:** At 03:15, one NVMe device on a storage node fails.
   - dm-cache is in writeback mode with 80GB dirty
   - The failed NVMe was the cache device (not metadata)
   - There are 24 snapshots and 200 active thin LVs
   Walk through the complete failure impact and recovery sequence.
   What is the actual RTO? Does it meet the 30-minute target?

6. **Workload isolation:** The analytics job at 02:00 runs on the same storage
   node as OLTP VMs. Without any isolation, the scan will thrash the NVMe
   cache. Name three distinct mechanisms you would use to protect OLTP
   latency during the analytics window, at different layers of the stack.

**Reference answers at end of document.**

---

## 4. Hands-On: Produce the Reference Document

Using everything from Days 8–13, write a reference document in this format:

```markdown
# Tiering Architecture Reference
Version: 2026-04-xx
Author: [your name]

## Quick Decision: bcache vs dm-cache
[3-row decision table]

## Cache Mode by Requirement
[failure tolerance vs performance table]

## Failure Scenarios and Recovery
[your version of the failure matrix from Day 13]

## GC and Performance Tuning
### bcache
- bucket_size: [when to change, what value]
- sequential_cutoff: [for your common workloads]
- writeback_rate: [auto vs manual]

### dm-cache
- block_size: [for your common workloads]
- migration_throttle: [for production use]
- separate metadata device: [always/sometimes/never]

## Operational Runbooks
### bcache SSD Failure Recovery
[step-by-step]

### dm-thin Metadata Failure Recovery
[step-by-step]

## Monitoring Checklist
[bpftrace / sysfs paths to watch]
```

---

## 5. Tools Drill: Week 2 Commands

Run these without looking up syntax:

```bash
# bcache
cat /sys/block/bcache0/bcache/dirty_data
cat /sys/block/bcache0/bcache/stats_five_minute/cache_hit_ratio
cat /sys/block/bcache0/bcache/writeback_rate_debug
cat /sys/block/bcache0/bcache/sequential_cutoff
echo writeback > /sys/block/bcache0/bcache/cache_mode
echo writethrough > /sys/block/bcache0/bcache/cache_mode

# dm-cache
dmsetup status vg_data-cached_lv
lvchange --cachepolicy cleaner /dev/vg_data/cached_lv
lvs -o+cache_total_blocks,cache_used_blocks,cache_dirty_blocks vg_data

# dm-thin
lvs -o+metadata_percent vg_data/thin_pool
thin_check /dev/vg_data/pool_meta
thin_dump /dev/vg_data/pool_meta | head -30
dmsetup status vg_data-thin_pool

# GC monitoring (bcache)
bpftrace -e 'kprobe:bch_gc_thread { @gc++; } interval:s:5 { print(@gc); clear(@gc); }'

# Write amplification tracking
watch -n5 "awk '/bcache0/{print \"bcache:\", \$10} /nvme0n1/{print \"ssd:\", \$10}' /proc/diskstats"
```

---

## 6. Week 2 → Week 3 Bridge

Week 3 covers filesystems and device mapper from a production architecture
perspective. Coming in Week 3:

**Day 15** — dm-crypt encryption overhead at different queue depths; IV modes
and their security/performance tradeoffs.

**Day 16** — md/RAID: the partial-stripe write problem in RAID-5 and why it
matters more than people think; write-intent bitmap's effect on resync time.

**Days 17–18** — XFS: two full days. AG model, log design, delayed allocation,
reflink — this is the filesystem most of your production systems use.

Before starting Week 3, ask yourself:
- Can you explain why XFS outperforms ext4 on parallel metadata-heavy workloads?
- Do you know what the XFS log does differently from ext4's JBD2?
- What is the partial-stripe write penalty in RAID-5 and how does write caching mitigate it?

If not, Week 3 will answer these.

---

## Reference Answers: Disaggregated NVMe-oF Storage Node

**1. Cache mode with RPO=1 hour:**
Writeback is defensible here — but with explicit risk acceptance. The risk:
if the NVMe cache fails between hourly snapshots, dirty data written since
the last snapshot is lost. That's up to 1 hour of writes per VM. Mitigations:
(a) RAID-1 the NVMe cache device — eliminates single-device failure risk;
(b) Keep `dirty_data` monitored and ensure bcache/dm-cache writeback rate
drains aggressively so dirty window is always small (target <5 minutes of
dirty data, not 1 hour); (c) Document the risk explicitly in the design.
With RAID-1 NVMe + aggressive writeback rate, writeback mode is reasonable.
Without NVMe redundancy, writethrough is safer.

**2. Write path through the stack (cache miss):**
```
VM write → NVMe-oF TCP → storage node network stack
  → dm-cache: cache miss
    → dm-thin: virtual block → physical block lookup (B-tree)
      → if new block: allocate from HDD pool (update B-tree)
      → write to HDD (origin device) — slow
    → dm-cache: promote block to NVMe (async migration)
      → read from HDD → write to NVMe
      → update cache map metadata

Worst-case write amplification:
  1× write to HDD (origin)
  + 1× read from HDD for promotion
  + 1× write to NVMe for promotion
  + metadata updates (dm-thin B-tree COW + dm-cache metadata)
  = WA of ~3× on HDD, 2× on NVMe for a promoted miss
```
In steady state (warm cache), cache hits eliminate HDD writes entirely.
The WA is worst during cache warmup or after a cache flush.

**3. Analytics scan + snapshots + dm-thin COW:**
24 snapshots × 200 LVs = 4,800 snapshot entries per thin pool. The analytics
scan at 02:00 triggers massive COW: every block the scan touches that is shared
with any of the 24 snapshots must be copied before being read (if it was
written after the snapshot). In practice, analytics reads don't trigger COW
(COW is for writes to shared blocks) — BUT if the analytics job writes results
back to the same LV, every written block triggers COW × (number of snapshots
sharing that block). Meanwhile, dm-cache SMQ sees the sequential scan as
low-promotion-value traffic and reduces promotion. However, the HDD I/O from
COW + sequential scan competes for HDD bandwidth. Mitigation: schedule snapshot
rotation — keep only 6 snapshots (not 24) per LV to reduce COW overhead.

**4. Metadata sizing:**
dm-thin metadata:
- 200 VMs × 300GB / 512KB block size = 200 × ~600K blocks = 120M block mappings
- 120M × 48 bytes = ~5.7GB minimum
- With 24 snapshots: multiply by ~3 for snapshot overhead = ~17GB
- Use 32GB dm-thin metadata device, RAID-1 (two small NVMe partitions)

dm-cache metadata:
- 4TB NVMe / 512KB cache block = ~8M cache blocks
- 8M × 64 bytes (dm-cache metadata per block) = ~512MB
- Use 2GB dm-cache metadata device (headroom), RAID-1

Both metadata devices: RAID-1 mandatory. Metadata loss = all LVs inaccessible.

**5. NVMe cache device failure recovery:**
```
Timeline:
  03:15 — NVMe (cache device) fails
  03:15 — dm-cache enters error mode; 80GB dirty data LOST
  03:15 — dmsetup remove --force cached_device
  03:16 — HDD origin devices accessible directly (200 thin LVs still on HDD)
  03:16 — dm-thin pool still intact (metadata on separate RAID-1 NVMe)
  03:17 — Mount thin LVs directly from HDD — I/O works but slow (no cache)
  03:18 — VMs resume but with HDD-only performance (~150 IOPS vs 50K IOPS)
  03:20 — Alert: restore from last hourly snapshot or accept dirty data loss
  03:20–03:50 — Replace NVMe, rebuild RAID-1, reconfigure dm-cache
  03:50 — dm-cache warm-up begins (cold cache on new NVMe)

RTO assessment:
  LVs accessible: ~3 minutes ✓
  Full performance restored: 35+ minutes (device replace + RAID rebuild) ✗
  Meets 30-minute RTO for accessibility, but NOT for performance recovery.
  
Recommendation: pre-stage a spare NVMe per node to cut replace time to <10min.
```

**6. Three isolation mechanisms for analytics vs OLTP:**
1. **cgroup v2 `io.max`** on the analytics VM's cgroup: hard bandwidth cap on
   HDD I/O (e.g., 200MB/s max). Prevents scan from saturating HDD, protecting
   OLTP cache-miss latency. Works regardless of scheduler.

2. **dm-cache SMQ + `migration_throttle`**: reduce `migration_throttle` during
   the analytics window (e.g., `echo 64 > /sys/module/dm_cache/parameters/migration_throttle`).
   Limits how aggressively the analytics scan promotes blocks into NVMe cache,
   protecting OLTP working set from eviction.

3. **NVMe-oF QoS / separate namespace**: if the storage node supports NVMe
   namespace-level QoS (via `nvme set-feature` with I/O determinism), assign
   analytics VMs to a separate namespace with lower I/O priority. Alternatively,
   place analytics VMs on a dedicated dm-cache device (separate NVMe partition)
   so their cache thrashing doesn't affect the OLTP cache pool at all.
