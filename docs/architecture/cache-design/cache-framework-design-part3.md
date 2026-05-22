# Cache Framework Design Part 3 — Multi-Tier: Penetration & Pollution

**Audience:** Senior storage architect
**Context:** Designing a RAM → NVMe → Ceph/HDD multi-level cache that avoids cache penetration and cache pollution
**Related:** cache-framework-design.md, cache-framework-design-part2.md, Month 3 tiering automation (day22)

---

## The Core Problem Statement

In a 3-tier stack `RAM → NVMe → Ceph/HDD`:

- **Cache penetration**: a read misses all tiers and hits Ceph (10–100ms). Under load this cascades — each penetration adds latency, which queues up more requests, which generate more penetrations.
- **Cache pollution**: "wrong" data in the wrong tier evicts "right" data. A sequential scan fills NVMe with data that won't be re-read, evicting the random-access working set. Next random read → NVMe miss → Ceph.

They interact: pollution *causes* penetration. Fixing pollution is the upstream fix.

---

## Cache Penetration: Where It Comes From

### Type 1 — Cold Miss Cascade
A genuinely new block, not in any tier. Cost = Ceph latency. Unavoidable but manageable.

### Type 2 — Pollution-Induced Miss
A hot block was evicted from NVMe by scan traffic. Now it's "cold" again despite being hot. This is the dangerous one — it looks like a cold miss but is a design failure.

### Type 3 — Non-Existent Key Miss (metadata workloads)
A lookup for a block or object that doesn't exist yet. Every check goes all the way to Ceph: "does this exist?" Common in filesystems during `stat()`, `open()`, directory walks.

### Type 4 — Thundering Herd on Miss
100 threads simultaneously miss the same block. All 100 penetrate to Ceph. Ceph gets 100 reads for the same object. The first one fills cache — the other 99 were wasted.

---

## Penetration Defense: Layer by Layer

### Defense 1 — Bloom Filter at Each Tier Boundary

Before checking a slower tier, consult a bloom filter. No false negatives — if the filter says "absent", the block is definitely absent. Skips the tier lookup entirely.

```
RAM miss
  → check NVMe bloom filter
    → "definitely not in NVMe" → skip NVMe, go to Ceph directly
    → "might be in NVMe"       → check NVMe (may be false positive, small cost)
```

**Bloom filter sizing**: target false positive rate of 1–5%. For 1M cached blocks, a 10-bit bloom filter uses ~1.2MB — fits entirely in L3 cache.

**Critical property**: bloom filters must be updated on every eviction. Stale bloom filters produce false negatives (claim block is present when it was evicted) — worse than no filter at all.

### Defense 2 — Negative Caching (for Type 3 misses)

Cache the fact that a block or object does *not* exist. A tombstone entry in RAM returns "not found" without touching NVMe or Ceph.

```
first lookup: "does object X exist?" → Ceph says no → cache tombstone for X with TTL
next 1000 lookups: hit tombstone in RAM → return "not found" immediately
```

**TTL is critical**: tombstones must expire. If the object is created later, the stale tombstone blocks access. TTL = max acceptable staleness for your consistency model.

### Defense 3 — Request Coalescing (for Type 4 thundering herd)

Collapse concurrent misses for the same block into a single backing store fetch. All waiters block on the same in-flight request. When it completes, all are served.

```
Thread 1 misses block X → starts Ceph fetch, registers "X is in-flight"
Thread 2 misses block X → sees "X is in-flight" → waits on the same future
Thread 3 misses block X → same
...
Ceph responds → block X enters NVMe cache → all threads unblock
```

**Implementation**: a per-block mutex or promise/future map at each tier boundary. The first miss acquires the lock and fetches; subsequent misses queue behind it.

### Defense 4 — Circuit Breaker on Backing Store

If Ceph penetration rate exceeds a threshold, stop sending more requests — they will just queue and make latency worse.

```
penetration_rate > threshold:
  → reject new requests or serve stale data from cache
  → re-enable when penetration rate drops
```

This prevents Ceph overload from cascading into full system unavailability.

---

## Cache Pollution: All Forms

### Form 1 — Sequential Scan Pollution (most common and destructive)

A `dd`, backup job, or bulk ETL reads data sequentially. This data will never be re-read from cache. But it fills NVMe, evicting the random-access working set. Next OLTP read → NVMe miss → Ceph.

**Detection**: track the stride between consecutive block addresses per I/O stream. Consistent, small stride = sequential pattern.

**Mitigation**:
```
if (sequential_run_length > threshold):
    → bypass NVMe cache entirely
    → do not admit sequential blocks to any cache tier
```

Threshold tuning: bcache default `sequential_cutoff` = 4MB. For Ceph-backed systems with large objects, 64MB–256MB is more appropriate.

### Form 2 — One-Hit Wonder Pollution

A block is read once (analytics query, report, scan). Gets admitted to NVMe. Will never be read again. Evicts something read thousands of times.

**Mitigation**: second-chance admission — admit to NVMe only on second access within a time window. Requires a ghost entry after the first access.

```
first access to block X  → create ghost entry (metadata only, no data in NVMe)
second access within TTL → ghost hit → now admit X to NVMe
access after TTL expires  → ghost expired → treat as first access again
```

### Form 3 — Burst Traffic Pollution

A sudden spike (viral content, batch trigger) floods the cache with new data, evicting the steady-state working set. After the spike ends, the cache is cold for normal traffic.

**Mitigation**: W-TinyLFU's window design handles this exactly.

```
Window LRU (small, ~1%):  absorbs burst traffic here first
Main cache (large, ~99%): promoted only if frequency score passes gate

Burst data fills the window → evicted from window without polluting main cache
Steady-state data stays in main cache (high frequency score, survives the gate)
```

The window acts as a blast shield. Burst data that does not repeat gets dropped from the window and never touches the main cache.

### Form 4 — Tier-Inappropriate Data

Cold data (accessed once per day) sitting in RAM. Hot data (accessed 10,000×/day) stuck in NVMe because it never got promoted. This is a placement failure, addressed by the promotion/demotion design below.

### Form 5 — Cross-Workload Pollution (multi-tenant)

Application A's sequential scan evicts Application B's hot working set from the shared NVMe cache.

**Mitigation**: partitioned cache with per-tenant min/max allocation. Application A's scan can only pollute Application A's partition.

---

## The "Insert at Middle Tier" Principle

This is the most important structural insight for multi-tier pollution prevention.

**Naive design**: new data always enters at the fastest tier (RAM).
- Problem: you don't know if new data is hot or cold at admission time.
- Cold data enters RAM → eventually evicted to NVMe → eventually evicted to Ceph.
- Both RAM and NVMe are polluted during the cold data's journey down.

**Correct design**: new data enters at the **middle tier** (NVMe) by default. It only promotes to RAM after proven hot.

```
Cold miss → fetch from Ceph → insert into NVMe (not RAM)
NVMe hit (1st time)   → increment frequency counter
NVMe hit (Nth time)   → frequency threshold met → promote to RAM

Hot data earns RAM. Cold data stays in NVMe or gets evicted there.
```

**Why this works**: NVMe eviction is cheap (data is still in Ceph). RAM eviction is expensive (NVMe must absorb it). By inserting cold data into NVMe first, you protect RAM from pollution at the cost of a few extra NVMe reads for data that turns out to be hot — which is acceptable.

This extends what 2Q and ARC do *within* a single tier (A1in as probationary before promotion to Am) across physical tiers.

---

## Cross-Tier Ghost Entries

Ghost entries become the connective tissue between tiers:

```
RAM ghost list:   recently evicted from RAM, metadata only
NVMe ghost list:  recently evicted from NVMe, metadata only
```

**On RAM eviction of block X**:
- Should X go to NVMe or be dropped?
  - If dirty → must write to NVMe
  - If clean AND NVMe ghost entry exists → X was recently in NVMe → demote to NVMe
  - If clean AND no NVMe ghost → X never proved useful in NVMe → drop

**On NVMe cache hit when RAM had a ghost for that block**:
- RAM ghost hit = this block was recently hot in RAM but got evicted
- Promote from NVMe to RAM immediately, skip the frequency threshold

**On NVMe eviction of block X**:
- If no RAM ghost entry → block was never in RAM → probably cold → drop to Ceph
- Add X to NVMe ghost list

This creates a learning system across tiers: each tier's ghost list encodes recent eviction history, and the cross-tier logic uses that history to make smarter placement decisions without global coordination.

---

## Full Read/Write Path Design

### Read Path

```
1. RAM cache lookup
   ├── HIT  → return, increment frequency counter
   └── MISS → check RAM ghost list
              └── ghost present? note "recently hot in RAM"

2. NVMe cache lookup
   ├── HIT  → serve block
   │          if RAM ghost hit above         → promote to RAM immediately
   │          elif frequency ≥ threshold     → promote to RAM
   │          else                           → serve from NVMe, update counter
   └── MISS → check NVMe ghost list
              └── ghost present? note "was recently in NVMe"

3. Ceph fetch (penetration — minimize this path)
   → Coalescing:  is this block already in-flight? wait if yes
   → Bloom check: if NVMe bloom says "absent", note skip NVMe admission
   → Insert into NVMe (middle tier, not RAM)
   → If RAM ghost hit  → also insert into RAM
   → If NVMe ghost hit → flag for fast promotion track
```

### Write Path

```
Write-back mode:
  1. Write to RAM (dirty)
  2. Background: RAM dirty → NVMe  (durable across RAM loss)
  3. Background: NVMe dirty → Ceph (persistent)

Write-through mode:
  1. Write to Ceph synchronously
  2. Update RAM and NVMe cache entries (clean)

Write-around mode (sequential / bulk):
  1. Write to Ceph directly
  2. Do NOT populate RAM or NVMe
  3. Invalidate any existing cache entries for this block
```

---

## Ceph-Specific Considerations

Ceph has its own internal caching layers that interact with your multi-tier design:

- **RADOS client cache** (`rbd_cache`): enabled by default, caches in client process DRAM
- **BlueStore cache**: caches RocksDB metadata and data blocks on the OSD
- **RocksDB block cache**: caches BlueStore's metadata key-value index

**Double-caching trap**: if you have NVMe cache → Ceph client cache → BlueStore, you may be caching the same block in three places. The NVMe cache and Ceph client cache are both DRAM-backed, providing no latency advantage over each other.

**Correct configuration**: when a NVMe cache tier sits in front of Ceph, disable the Ceph client DRAM cache:

```bash
# librbd
rbd_cache = false

# kernel rbd
echo 0 > /sys/bus/rbd/devices/<id>/cache_size
```

Let the NVMe tier be the L2 cache. Let BlueStore cache handle OSD-side metadata. Do not stack two DRAM caches doing the same job.

**Ceph read amplification worst case**: NVMe miss → Ceph client → OSD HDD seek = 10–20ms. If NVMe cache miss rate is high, every miss generates an HDD read on the Ceph OSD side. This is your true tail latency floor — model it explicitly.

---

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────┐
│                    Unified Cache Manager                    │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  RAM Cache (DRAM)                                    │  │
│  │  Policy: W-TinyLFU  │  Partition: per workload      │  │
│  │  Ghost list ──────────────────────────────────────┐  │  │
│  └──────────────────────────────────────────────────────┘  │
│           ↑ promote (frequency ≥ threshold                  │
│           │         or RAM ghost hit on NVMe read)          │
│           ↓ demote  (eviction → check NVMe ghost)           │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  NVMe Cache                                          │  │
│  │  Policy: SMQ or 2Q  │  Bloom filter at boundary     │  │
│  │  Default insert point for all cold misses            │  │
│  │  Ghost list ──────────────────────────────────────┐  │  │
│  └──────────────────────────────────────────────────────┘  │
│           ↑ fetch on miss (request coalesced)               │
│           ↓ writeback dirty (rate-controlled PID)           │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Ceph / HDD (backing store)                         │  │
│  │  Circuit breaker: reject if penetration rate high   │  │
│  │  rbd_cache = false: no duplicate DRAM caching       │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## Design Checklist — Penetration & Pollution

**Penetration:**
- [ ] Bloom filter installed at NVMe tier boundary, updated on every eviction
- [ ] Negative caching (tombstones) for non-existent key workloads, with TTL
- [ ] Request coalescing for concurrent misses on the same block
- [ ] Circuit breaker on Ceph if penetration rate exceeds threshold
- [ ] Penetration rate monitored as a first-class alert metric

**Pollution:**
- [ ] Sequential bypass with tuned threshold for this object size / workload
- [ ] Second-chance (ghost entry) admission — no direct admit on first access
- [ ] Window buffer (W-TinyLFU or equivalent) to absorb burst traffic
- [ ] New data inserted at NVMe tier by default, not RAM
- [ ] Per-workload cache partitions if multi-tenant
- [ ] Cross-tier ghost entries wiring RAM ↔ NVMe eviction decisions

**Ceph integration:**
- [ ] `rbd_cache = false` (or equivalent) to eliminate duplicate DRAM caching
- [ ] Worst-case latency modeled: NVMe miss → OSD HDD seek
- [ ] Write policy chosen per workload (write-around for bulk, write-back for OLTP)
