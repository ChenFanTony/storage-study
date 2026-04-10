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
- Running a Ceph cluster: 24× HDD data OSDs + 3× NVMe for journals/WAL
- Considering adding SSD caching in front of HDDs for hot data
- 50TB total data, ~5TB hot working set
- Write-heavy: 60% write, 40% read
- Cannot tolerate data loss (financial data)
- One team member has bcache experience; nobody has dm-cache experience

**Design questions:**

1. Should they use bcache or dm-cache for SSD caching?

2. What cache mode is required given the RPO constraint?

3. The NVMe journals are already handling WAL — the SSD cache would be
   additional NVMe. Total SSD budget: 4TB. How would you size:
   - Cache device per OSD
   - Metadata device (if dm-cache)
   - sequential_cutoff / SMQ configuration

4. Ceph does a mix of 4MB sequential writes (replication) and 4KB random
   reads (client reads). How does this affect your tiering recommendation?

5. What monitoring would you put in place for the tiering layer?

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

## Reference Answers: Ceph Scenario

**1. bcache or dm-cache?**
dm-cache. Reasons: (a) Ceph is already LVM-managed — dm-cache integrates
natively via lvmcache; (b) The team's bcache experience is a soft benefit
offset by dm-cache's better operational tooling (lvmcache, lvs monitoring);
(c) dm-cache's SMQ handles Ceph's mixed 4MB sequential + 4KB random better
than bcache's manual sequential_cutoff tuning; (d) dm-cache supports separate
metadata devices for protection.

**2. Cache mode for RPO=0?**
Writethrough only. Writeback cannot guarantee RPO=0 — if the SSD fails while
dirty data hasn't been written back to HDD, that data is lost. Writethrough
ensures HDD always has the committed write before returning success.

**3. Sizing:**
- Total SSD: 4TB across 24 HDDs = ~170GB per OSD cache (use 128GB, reserve some)
- Cache block size: 512KB–1MB (matches Ceph's typical 4MB object size / 4MB replication writes being divisible by cache block)
- Metadata: 128GB cache at 512KB blocks = ~256K blocks × 48 bytes = ~12MB metadata per OSD. Use 1GB per OSD metadata device (headroom + RAID-1)
- sequential_cutoff: set to 4MB (matches Ceph's replication write size — sequential writes above 4MB bypass cache, protecting hot random-read data)

**4. Mixed 4MB sequential + 4KB random:**
This is the archetypal bcache/dm-cache challenge. 4MB sequential writes (replication)
will thrash the cache if not filtered. With dm-cache SMQ: SMQ's probabilistic
promotion will naturally reduce promotion rate for the sequential writes.
With bcache: set sequential_cutoff=4MB. Either way, the 4KB random reads are
the hot tier you want in cache — verify hit rate is high for those specifically.

**5. Monitoring:**
- dm-cache dirty block count (alert if >10% of cache is dirty in writethrough — means something is wrong)
- dm-cache hit rate (alert if drops >10% from baseline in 5-minute window)
- dm-thin metadata usage (alert at 80% — if it fills, all thin LVs get errors)
- SSD endurance: nvme smart-log wear indicator (alert at <20% remaining)
- bpftrace GC frequency if using bcache (alert if GC runs >10×/minute under load)
