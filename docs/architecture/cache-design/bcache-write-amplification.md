# Write Amplification in bcache Writeback — Architect's Reference

**Audience:** Storage architect / senior engineer
**Context:** Sources and magnitude of write amplification (WA) in bcache operating in writeback mode without write bypass
**Related:** cache-framework-design-part2.md (WA amplification stack), cache-framework-design.md §3 (write policy), working-set-measurement.md

---

## The Core Question

In bcache writeback with no write bypass (all writes go through the SSD cache), how many physical writes does one logical application write generate?

**Answer: writes happen at four distinct levels, each adding its own WA.**

---

## Level 1 — bcache Journal WA (~1.02–1.05×)

bcache maintains a crash-recovery journal (typically 1–2% of SSD cache size). Every b-tree metadata change — "block X is now cached at SSD offset Y" — is logged to the journal before being committed to the b-tree.

```
App write of block X:
  → data written to SSD bucket   (sequential append)
  → b-tree mapping update logged to journal
  → journal committed periodically
  → on crash: journal replayed to reconstruct b-tree
```

Journal WA is small and amortized across many data writes per journal commit, but it is real. Every write produces at least one journal entry in addition to the data write itself.

---

## Level 2 — bcache B-tree Metadata WA (~1.1–1.2×)

bcache's block mapping is a B-tree: `(device, LBA) → (SSD bucket, offset)`. Every cached write adds or updates a leaf entry.

B-tree updates cause:
- **Leaf node rewrite**: the leaf node containing the updated key is read, modified, and written back — even if only one mapping changed in a 4 KB node
- **Node splits**: when a leaf is full it splits, forcing a parent node write too
- **Path-to-root writes**: worst case O(log N) node writes per insert

At high write throughput with a cold cache (many new mappings being created), B-tree metadata writes are a measurable fraction of total SSD writes.

---

## Level 3 — bcache GC / Bucket Reclaim WA (~1.1–1.5×)

This is the dominant source of WA in bcache writeback.

bcache writes to the SSD in a **log-structured** manner: all writes are appended sequentially to "buckets" (typically 512 KB–2 MB each, matched to SSD erase block size). When a bucket needs to be reclaimed, bcache must copy any still-live data out before freeing it:

```
Bucket before GC:
  [block A — still cached, live]
  [block B — overwritten by app, stale]
  [block C — still cached, live]
  [block D — flushed to HDD, stale]
  [block E — still cached, live]
  ← 3 of 5 blocks live (60% occupancy)

GC must:
  1. Read live blocks A, C, E from old bucket
  2. Write A, C, E to a new bucket   ← extra SSD writes
  3. Mark old bucket as reclaimable
```

**GC WA formula** (worst case, applies to any log-structured storage):

```
WA_gc = 1 / (1 - utilization)

At 30% SSD fill: WA_gc = 1 / 0.70 = 1.43×
At 50% SSD fill: WA_gc = 1 / 0.50 = 2.0×
At 70% SSD fill: WA_gc = 1 / 0.30 = 3.3×   ← bcache starts aggressive GC here
```

In practice bcache selects buckets with the lowest live-data ratio first (greedy GC), so average WA is better than the worst case — but the trend is the same: **the fuller the SSD, the worse the GC WA.**

### The no-write-bypass effect on GC

Without write bypass (`sequential_cutoff = 0` or very large), large sequential writes (backups, log ingestion, bulk imports) enter the SSD cache. Once those blocks are flushed to HDD, their SSD bucket entries become fully stale. GC can then reclaim those buckets for free — zero live data to copy. This mitigates GC WA for sequential-write patterns after flush. However, the initial write still consumes SSD bucket space and causes real NAND wear.

---

## Level 4 — SSD Internal FTL WA (~1.05–1.3×)

The SSD has its own Flash Translation Layer that manages NAND erase blocks independently of bcache. The FTL performs its own GC when an erase block contains mixed valid and stale pages.

**bcache's sequential bucket writes intentionally minimize FTL WA.** By appending whole buckets sequentially, bcache feeds the FTL a pattern similar to a log-structured filesystem — full erase blocks are written and invalidated together, leaving the FTL minimal relocation work.

Compare:
```
Random 4 KB writes direct to SSD  → FTL WA: 5–20×
bcache sequential bucket writes    → FTL WA: 1.05–1.3×
```

This is one of bcache's core design wins: the log-structured write discipline that causes bcache-level GC WA also buys low FTL-level WA.

---

## Level 5 — HDD Writeback Write (the coalescing level)

In writeback mode, dirty SSD blocks are eventually flushed to the HDD backing store:

```
App write:   1 write → SSD   (fast, acknowledged immediately)
Writeback:   1 write → HDD   (async, background)
Naive total: 2 physical writes per logical write
```

However, writeback provides **write coalescing** that can reduce HDD WA well below 1×:

```
Block X overwritten 10 times before flush:
  SSD receives: 10 writes (one per app update)
  HDD receives: 1 write (final version only)

HDD effective WA = 1/10 = 0.1× for that block
SSD WA           = 10× for that block
```

This trade — more SSD writes, fewer HDD writes — is the core value proposition of writeback mode for random-write-heavy workloads (OLTP, databases). The SSD absorbs the write pressure; the HDD sees only the durable final versions.

The coalescing ratio depends on the rewrite frequency of the working set. Cold data written once before flush sees 2× total WA. Hot data written repeatedly before flush approaches 1× total WA (SSD wears, HDD is spared).

---

## Total WA Stack

```
Source                     │ Typical WA    │ Notes
───────────────────────────┼───────────────┼───────────────────────────────
bcache journal             │ ~1.02–1.05×   │ Amortized b-tree log
bcache B-tree metadata     │ ~1.1–1.2×     │ Node rewrites and splits
bcache GC / bucket reclaim │ ~1.1–1.5×     │ Dominant; explodes above 70% fill
SSD internal FTL           │ ~1.05–1.3×    │ Minimized by sequential writes
───────────────────────────┼───────────────┼───────────────────────────────
Total SSD WA (compounded)  │ ~1.3–2.5×     │ Varies by fill %, access pattern
───────────────────────────┼───────────────┼───────────────────────────────
HDD writeback write        │ 0.1–1.0×      │ Coalescing reduces this below 1×
                           │               │ 0.1× if blocks rewritten 10×
                           │               │ 1.0× if write-once workload
```

**Practical compounded SSD WA for a well-tuned bcache writeback system:**
- SSD fill 30–50%, OLTP workload: **~1.3–1.6× SSD WA**
- SSD fill 60–70%, mixed workload: **~1.8–2.5× SSD WA**
- SSD fill > 70%: GC WA dominates, avoid this regime

---

## Architect Design Rules

### 1. Keep SSD fill below 70%

GC WA is the dominant term and accelerates non-linearly above 70%. Provision the SSD at 1.3–1.5× the target working set:

```
SSD_size = working_set × 1.4   (recommended headroom)
```

bcache begins aggressive GC at 70% by default (`gc_after_writeback`).

### 2. Enable sequential_cutoff to recover write bypass

Without write bypass, every sequential write (backup, ETL load, compaction output) consumes SSD capacity unnecessarily. Set `sequential_cutoff` to bypass large sequential runs:

```bash
# Bypass caching for sequential runs longer than 1 MB
echo 1048576 > /sys/block/bcache0/bcache/sequential_cutoff

# Check current value
cat /sys/block/bcache0/bcache/sequential_cutoff
```

Writes above this threshold go directly to HDD (writearound), eliminating their SSD WA entirely.

### 3. Writeback is WA-favorable for high-rewrite workloads

Writeback WA is beneficial when:
- Blocks are rewritten multiple times before being flushed → HDD WA < 1×
- The SSD tier is more endurance-limited than the HDD tier

Writeback WA is harmful when:
- Workload is write-once (logs, backups) → no coalescing benefit → 2× WA
- SSD is near capacity → GC WA amplifies everything

### 4. Monitor WA directly

```bash
# SSD bytes written (from iostat or /sys)
# App bytes written (from blkstat or application counters)
# WA = SSD_bytes_written / app_bytes_written

# bcache-specific counters
cat /sys/block/bcache0/bcache/stats_total/cache_hits
cat /sys/block/bcache0/bcache/stats_total/cache_misses
cat /sys/block/bcache0/bcache/stats_total/cache_bypass_hits
cat /sys/block/bcache0/bcache/stats_total/cache_bypass_misses

# Writeback rate (how fast dirty data is being flushed)
cat /sys/block/sdb/bcache/writeback_rate

# SSD dirty data currently held (flush backlog)
cat /sys/block/sdb/bcache/writeback_rate_debug
```

Real WA = `iostat bytes_written for SSD` ÷ `iostat bytes_written at application level`. Track both over a representative workload window.

### 5. The WA stack compounds

All four sources multiply:

```
Total_SSD_WA = WA_journal × WA_btree × WA_gc × WA_ftl
             ≈ 1.04 × 1.15 × 1.3 × 1.1
             ≈ 1.72×   (at 50% SSD fill, typical OLTP)
```

This is why the existing docs list "WA budget ≤ 5× total" as an all-flash design rule: each layer must be held tight, or the product of all layers exceeds the SSD's endurance budget.

---

## Comparison: writeback vs write-through WA

| Mode | SSD WA | HDD WA | Best for |
|------|--------|--------|----------|
| writeback | 1.3–2.5× SSD | 0.1–1.0× HDD | High-rewrite OLTP; HDD longevity matters |
| writethrough | 1.0× SSD (reads only cached) | 1.0× HDD (every write) | Read-heavy; consistency critical |
| writearound | 0× SSD (writes bypass) | 1.0× HDD | Write-once; sequential workloads |

Writeback trades SSD endurance for HDD write reduction. Whether that trade is worth it depends on relative endurance budgets of the two tiers.
