# Cache Framework Design Part 2 — Multi-Tier, Coherency, Observability

**Audience:** Senior storage architect
**Context:** Continuation of cache-framework-design.md — multi-level architecture, partitioning, coherency, cold start, production observability, write amplification stacking
**Related:** cache-framework-design.md, Month 3 tiering automation (day22), Month 1 bcache (day08-10), dm-cache (day11), [working-set-measurement.md](working-set-measurement.md) (how to measure working set size in production)

---

## Multi-Level Cache Architecture

Single-tier caches leave performance on the table. Production systems stack tiers:

```
L1: DRAM buffer pool   (ns latency, GB scale)
L2: NVMe/Optane        (µs latency, TB scale)
L3: SSD array          (100µs latency, 10s TB)
L4: HDD / object store (ms latency, PB scale)
```

**The critical design question**: does data move *through* tiers (hierarchical) or *to* the right tier (flat placement)?

| Model | Mechanism | When to use |
|-------|-----------|-------------|
| **Hierarchical (cascade)** | L1 miss → check L2 → check L3 → fetch from L4, fill all levels on the way up | Hot data accumulates naturally at top |
| **Flat tiering** | Placement policy assigns data directly to the right tier based on heat score | Avoids double-caching; more complex to get right |
| **Bypass** | Hot data skips intermediate tiers (e.g., L1 miss goes straight to L3 if L2 miss rate is high) | Reduces latency when intermediate tier adds overhead without value |

**Double-caching problem**: if your app has a 32GB buffer pool and you put dm-cache in front of it, the SSD cache is caching what the app already caches in DRAM. The SSD only helps for data *not* in the app cache — which means your effective SSD working set is `total_working_set - DRAM_buffer_pool`. Size the SSD tier against that remainder, not the total dataset size.

---

## Cache Partitioning & Reservation

Unpartitioned caches let one workload starve another. Two patterns:

### Static Partitioning

Reserve a fixed fraction of cache for each tenant or workload:

```
Cache space:  [DB: 60%][OS page cache: 20%][metadata: 20%]
```

Simple, predictable, but wastes space when a partition is underused.

### Dynamic Partitioning with Minimums

Each partition has a `min_reserved` and competes for the rest:

```
partition.min    = guaranteed floor (never evicted below this)
partition.weight = relative share of free space above minimums
```

This is what **Intel CAT (Cache Allocation Technology)** does at the CPU L3 level, and what **RocksDB's block cache** does with `high_priority_pool_ratio` — keeps index and filter blocks from being evicted by data blocks.

**When metadata competes with data, metadata must win.** A cache miss on a data block costs one backing store read. A cache miss on a B-tree node or inode costs *n* reads (the whole lookup chain). Always reserve metadata with a hard floor.

---

## Cache Coherency

Relevant when multiple agents can write to the same backing data.

**Single-host tiered storage**: no coherency problem — all I/O goes through the same cache layer. The cache *is* the authoritative view of dirty data.

**Shared cache across hosts** (e.g., NVMe-oF with a cache tier on each initiator):
- Two hosts can each cache the same LBA
- Host A writes → its cache is dirty → Host B reads the stale version from its own cache
- This is a **split-brain cache** scenario

Solutions:

| Approach | Mechanism | Cost |
|----------|-----------|------|
| **No shared cache** | Each host caches only data it owns | Simplest; limits effectiveness for shared volumes |
| **Invalidation protocol** | Write triggers invalidation message to all other caches | Network overhead on every write |
| **Ownership-based** | Only one host can hold a dirty cache entry at a time (MESI analogy) | Complex state machine; correct but high coordination overhead |
| **Write-through everywhere** | No dirty entries; backing store always current | Eliminates the problem entirely; write latency limited by backing store |

**bcache and dm-cache are single-host only** for exactly this reason — they make no attempt at multi-host coherency. NVMe-oF with ANA handles path-level HA but not cache coherency across initiators.

---

## Cache Warming — Cold Start Problem

After a restart, cache is empty. Time to warm up to steady-state hit rate = minutes to hours depending on working set size and access rate.

**Impact**: applications that tolerate cold cache poorly (databases, object stores with hot metadata) suffer a latency cliff on every restart.

### Strategy 1: Persistent Cache Keys (Save/Restore)

On shutdown: serialize the list of cached block addresses to disk.
On startup: pre-populate cache by reading those blocks from backing store.

Used by: **Varnish** (HTTP cache), **RocksDB** (block cache warm-up via `secondary_cache`), some hypervisor disk cache implementations.

**Cost**: restart time increases. Cache keys may be stale if backing store was modified while cache was offline.

### Strategy 2: Ghost-Only Warm-Up

Replay the key list into ghost entries only (no data). First real access to each ghost promotes to a real cache entry. This gives the admission and eviction policy the correct frequency context without the cost of pre-reading everything.

### Strategy 3: Access Log Replay

Record all cache-miss block addresses during a warm-up window. Replay asynchronously in background. Effective but requires I/O bandwidth headroom during warm-up.

### Strategy 4: Accept the Cold Period

For many workloads, cold start lasts only a few minutes before DRAM buffer pool warms up. Only invest in warm-up infrastructure if your SLO cannot absorb the cold period.

---

## Production Observability — What to Instrument

A cache you cannot observe cannot be tuned. Minimum metrics:

| Metric | Formula | What it tells you |
|--------|---------|-------------------|
| **Hit rate** | hits / (hits + misses) | Core health; should be ≥90% for meaningful benefit |
| **Dirty ratio** | dirty_blocks / total_cached_blocks | Writeback pressure; alert at >60%, critical at >80% |
| **Eviction rate** | evictions/sec | Rising = workload exceeding cache size |
| **Ghost hit rate** | ghost_hits / total_misses | How often you evicted something you needed |
| **Promotion rate** | promotions/sec | Aggressiveness of data moving up tiers |
| **Demotion rate** | demotions/sec | Eviction pressure pushing data down tiers |
| **Write amplification** | bytes_written_to_cache / bytes_written_by_app | SSD wear indicator; >3× is a warning sign |
| **p99 miss latency** | 99th pct of backing store fetch time | What users feel during a cache miss |

**The ghost hit rate is the most underused metric.**
- Ghost hit rate high + hit rate low → cache has the right working set knowledge but not enough space → grow the cache
- Ghost hit rate low + hit rate low → eviction policy is wrong → review admission and eviction algorithm

### bcache sysfs paths

```bash
/sys/block/bcache0/bcache/stats_total/cache_hits
/sys/block/bcache0/bcache/stats_total/cache_misses
/sys/block/bcache0/bcache/stats_total/cache_bypass_hits
/sys/fs/bcache/<uuid>/dirty_data              # dirty bytes in cache
/sys/fs/bcache/<uuid>/cache_available_percent
```

### dm-cache status

```bash
dmsetup status <cache_name>
# outputs: <nr_read_hits> <nr_read_misses> <nr_write_hits> <nr_write_misses>
#          <nr_demotions> <nr_promotions> <nr_dirty> <nr_features> ...
```

---

## The Amplification Stack — Why It Compounds

Architects must reason about write amplification at every layer simultaneously:

```
App writes 1 block (4KB)
  → Cache WA: cache writes it + metadata update         ×1.1
  → SSD internal WA (GC inside NAND):                   ×3-10
  → RAID write penalty (RAID-5 partial stripe):          ×4
  → Replication (3× replica):                           ×3
─────────────────────────────────────────────────────────
Total WA: 1.1 × 6 × 4 × 3 ≈ 79× physical writes per logical write
```

This is why bcache in write-back mode on RAID-5-backed HDD with replication is a common design that silently destroys SSDs. Each layer's WA multiplies.

**Architect's rule**: model the full WA stack before choosing write-back. Write-through trades write latency for WA elimination at the cache layer. Sometimes that trade is correct.

### WA Reduction Strategies Per Layer

| Layer | WA source | Mitigation |
|-------|-----------|------------|
| Cache | Random writes to SSD | Write-through mode; larger cache block size to coalesce |
| SSD internal | NAND GC amplification | Over-provision SSD (leave 20-30% unallocated); sequential write pattern |
| RAID-5 | Read-modify-write on partial stripe | Full-stripe writes; use RAID-6 with journal; use RAID-10 instead |
| Replication | Every write goes to N replicas | Erasure coding instead of replication for cold data |

---

## Key Design Checklist

Before finalizing any cache layer design, answer these:

- [ ] What is the working set size? Is the cache large enough to hold it?
- [ ] What is the write rate at peak? Can the backing store absorb dirty flushes at that rate?
- [ ] Is the workload sequential, random, or mixed? Does the admission policy handle scans?
- [ ] What is the acceptable dirty data volume if the cache device fails? (Determines write-back vs write-through)
- [ ] Are there multiple tenants or workloads competing for cache? Do you need partitioning?
- [ ] Are there multiple hosts accessing the same backing store? (Coherency required?)
- [ ] What is the restart SLO? Does cold start need to be handled explicitly?
- [ ] Is write amplification modeled across all layers?
- [ ] What metrics are exported? Can you detect a hit rate collapse before users feel it?
