# Cache Framework Design Patterns — Architect's Reference

**Audience:** Storage architect / senior engineer
**Context:** Interaction patterns between cache and backing store — how to wire them together correctly
**Related:** cache-framework-design.md (algorithms), cache-framework-design-part2.md (multi-level), cache-framework-design-part3.md (penetration/pollution)

---

## The Eight Patterns Every Cache Architect Must Know

The existing docs cover eviction algorithms (LRU/ARC/W-TinyLFU), infrastructure (ghost entries, writeback), and multi-tier topology.
This document covers the orthogonal question: **how does the cache interact with application code and backing stores?**

---

## Pattern 1 — Cache-Aside (Lazy Loading)

The application owns cache population. On miss, the application loads from the backing store and writes into the cache itself.

```
Read:
  value = cache.get(key)
  if value is None:
      value = db.query(key)
      cache.set(key, value, ttl=T)
  return value

Write:
  db.write(key, value)
  cache.delete(key)      ← invalidate, not update
```

**Properties:**
- Cache contains only what was actually requested — no speculation
- Application code is coupled to cache knowledge
- Thundering herd on miss (mitigated by request coalescing / mutex-on-miss)
- Write path invalidates rather than updates → stale window between delete and next population

**Used by:** Redis in virtually every web application. Ceph librbd (rbd_cache in WriteAround mode). Most application-layer caches.

**Architect rule:** Cache-Aside is correct when the miss cost is acceptable and the cache acts as a best-effort acceleration layer, not a consistency guarantee.

---

## Pattern 2 — Read-Through

Cache sits inline; the application only talks to the cache. On miss, the cache itself loads from the backing store.

```
Read:
  return cache.get_or_load(key)   ← cache calls db internally on miss

Write:
  cache.set(key, value)           ← or write-through (Pattern 3)
```

**Properties:**
- Application is fully decoupled from backing store
- Cache can deduplicate concurrent misses (coalescing is natural here)
- Requires the cache to know how to fetch from backing store (coupling inside cache layer)

**Used by:** Linux page cache (read-through over disk), bcache (block-layer read-through to SSD), dm-cache. CPU L1/L2/L3 are hardware read-through caches.

**Architect rule:** Read-Through is the right pattern for block/storage-layer caches where the application cannot be modified. The cache transparently accelerates the backing store.

---

## Pattern 3 — Write-Through

Every write goes to cache AND backing store synchronously before ACK. Cache is always consistent with the store.

```
Write:
  backing_store.write(key, value)   ← sync
  cache.set(key, value)             ← sync
  return ACK

Read:
  return cache.get(key)             ← always a hit after first write
```

**Properties:**
- Cache and store always consistent — zero stale window
- Write latency = backing store latency (no write acceleration)
- High write amplification: every write hits both tiers
- Excellent read hit rate: cache always reflects current state

**Used by:** bcache in writethrough mode. NVMe-oF host-side cache in writethrough. CPU write-through caches (rare; write-back more common at L1).

**Architect rule:** Write-Through when consistency is mandatory and the workload is read-heavy. The write cost is paid; the read benefit is maximized. Never use for write-intensive workloads.

---

## Pattern 4 — Write-Back (Write-Behind)

Writes go to cache only; the cache asynchronously flushes to the backing store. Write latency = cache latency.

```
Write:
  cache.set(key, value, dirty=True)  ← fast, in-cache only
  return ACK                         ← before backing store write

Background:
  for dirty_entry in cache:
      if should_flush(dirty_entry):
          backing_store.write(dirty_entry.key, dirty_entry.value)
          dirty_entry.dirty = False
```

**The durability problem:** If the cache dies before flush, data is lost. Mitigations:

| Mitigation | Mechanism | Example |
|------------|-----------|---------|
| Battery-backed DRAM | Survives power loss | RAID controller cache, NVDIMM |
| WAL before ACK | Persistent log survives crash | bcache journal on SSD |
| Replication | Two nodes hold dirty data | Ceph primary + replica |

**Used by:** bcache in writeback mode. dm-cache with writeback. RAID controller write-back cache. Linux page cache (dirty pages flushed by writeback thread). Database buffer pool.

**Architect rule:** Write-Back is mandatory for write-intensive workloads. The durability risk is real — design explicitly for it. bcache's journal handles single-node crash; Ceph's replicated writes handle multi-node.

---

## Pattern 5 — Write-Around (Bypass on Write)

Writes go directly to the backing store, bypassing the cache. Cache is populated only on reads. Optimized for write-once / read-later workloads.

```
Write:
  backing_store.write(key, value)  ← bypass cache entirely
  return ACK

Read:
  value = cache.get(key)
  if miss:
      value = backing_store.read(key)
      cache.set(key, value)
  return value
```

**Properties:**
- No cache pollution from write traffic
- Cold read after write: first read is always a miss
- Ideal for write-heavy append patterns (logs, backups) where written data is rarely re-read

**Used by:** bcache in writearound mode. Linux `O_DIRECT` (bypasses page cache entirely). Object storage write paths (write once, serve reads from CDN).

**Architect rule:** Write-Around is the correct default for backup workloads, log ingestion, and cold-tier archiving. Do not pollute the hot cache with data that will not be re-read.

---

## Pattern 6 — Refresh-Ahead (Predictive Preload)

Cache proactively refreshes entries that are about to expire before TTL expires. Caller never sees a cold miss for hot entries.

```
on every cache.get(key):
  if entry.ttl_remaining < refresh_threshold:
      async: entry.value = backing_store.fetch(key)
             cache.update(key, new_value)
  return entry.value    ← serve current (possibly slightly stale)
```

**Properties:**
- Eliminates miss latency for hot keys with predictable access patterns
- Risk: refreshes items that will not be accessed again → wasted load on backing store
- Incorrect for random access patterns (refreshes the wrong items)

**Used by:** CDN prefetch on popular content. DNS TTL refresh. Ceph OSDMap epoch preload (clients refresh the map before epoch expires). Block read-ahead (not TTL-based but predictive by sequential pattern).

**Architect rule:** Refresh-Ahead works when access patterns are predictable and hot keys are known. Combine with frequency counters (W-TinyLFU sketch) to refresh only actually-hot entries.

---

## Pattern 7 — Cache Invalidation Strategies

Cache invalidation is the hardest problem. There are exactly four mechanisms:

### 7a — TTL Expiry (Time-To-Live)

```
cache.set(key, value, ttl=300)
# Entry expires automatically; next read is a miss → reload
```

- Stale window = up to TTL duration
- No coordination between cache and backing store required
- Breaks when immediate consistency is required
- **The default for most application caches**

### 7b — Write-Invalidate (Active Invalidation)

```
# Writer:
db.write(key, new_value)
cache.delete(key)          ← or cache.delete_by_tag([tag1, tag2])
```

- Cache is authoritative until explicitly invalidated
- Race: between delete and next population, two threads can both miss → second overwrites first with potentially stale data
- **Mitigate:** compare-and-swap on cache population (only set if key still absent)

### 7c — Event-Driven Invalidation (CDC / Pub-Sub)

```
db change → CDC stream → invalidation service → cache.delete(key)
```

- Backing store publishes changes; cache subscribes and invalidates
- Decoupled; scales to many cache nodes; invalidation is async (small lag)
- **Examples:** Facebook Memcache + McRouter, RocksDB ColumnFamily listeners, Ceph cache tiering promote/demote

### 7d — Version / ETag Invalidation

```
cache.set(key, (value, version=42))

on read:
  (cached_value, cached_version) = cache.get(key)
  current_version = store.get_version(key)   ← lightweight check
  if cached_version == current_version:
      return cached_value
  else:
      # re-fetch and update cache
```

- Reader verifies version on every access; backing store is authoritative on version number
- Serves cached data without full re-fetch when version matches
- **Examples:** HTTP ETag + If-None-Match. RocksDB Snapshot reads via sequence number.

**Invalidation selection:**

| Consistency requirement | Strategy |
|------------------------|----------|
| Loose (seconds of stale OK) | TTL expiry |
| Per-operation correctness | Write-Invalidate |
| Distributed correctness, decoupled systems | CDC / Event-Driven |
| Read-heavy, cheap version check possible | Version / ETag |

---

## Pattern 8 — Distributed Cache Topology

When a single node cannot hold the working set:

### 8a — Shared Remote Cache (Redis / Memcached cluster)

```
All app nodes → single Redis cluster (sharded via consistent hashing)
```

- One truth per key; eviction is global
- Hot key problem: one shard bottlenecks for popular keys
- **Mitigation:** key replication — store hot key on N shards with suffix `key#0 … key#N`; reader picks random suffix

### 8b — L1 / L2 Hybrid (Local + Remote)

```
App → L1 (in-process, ~100 MB, microsecond latency)
    → L2 (Redis cluster, ~100 GB, 200 µs latency)
    → Backing store (persistent)
```

- L1 absorbs hot-key traffic without network round-trips
- Coherency problem: when backing store changes, invalidate both L1 and L2
- **Mechanism:** broadcast invalidation via pub-sub
- **Examples:** Twitter, Netflix, Uber application stacks. Storage analog: page cache (L1) + bcache (L2) + spinning disk (L3)

### 8c — Consistent Hashing with Virtual Nodes

```
N cache nodes, each owns 1/N of the key space
key → hash(key) → find responsible node → cache operation
```

- Adding/removing nodes migrates only 1/N of keys (not all keys)
- Without virtual nodes: hotspots form when one node's ring arc covers popular keys
- Virtual nodes (150–300 per physical node) smooth the distribution
- **Examples:** Ceph CRUSH (consistent hashing with topology awareness), Cassandra virtual-node consistent hashing

---

## Pattern Selection Matrix

| Scenario | Pattern | Reason |
|----------|---------|--------|
| Web app, Redis, loose consistency OK | Cache-Aside + TTL | Simple, decoupled, correct enough |
| Block layer acceleration | Read-Through + Write-Back | App unaware of cache; write latency matters |
| Read-heavy, must-be-consistent | Write-Through | Consistency paid at write; reads are free |
| Log/backup writes, never re-read | Write-Around | Prevent pollution |
| Hot keys, many clients, distributed | L1/L2 Hybrid + Write-Invalidate CDC | Local latency + global consistency |
| Write-intensive database workload | Write-Back + WAL durability | Write acceleration; crash-safe |
| Distributed storage cluster | Consistent Hashing + Event-Driven Invalidation | Scale + decoupling |
| Predictable hot items | Refresh-Ahead + frequency filter | Zero miss latency for known-hot keys |

---

## The Fundamental Trade-off

Every cache pattern makes an explicit trade on two axes:

```
Consistency ←————————————————→ Performance
  (always correct)            (always fast)

Write-Through:  maximum consistency,  write cost paid
Write-Back:     eventual consistency, full write acceleration
Cache-Aside:    TTL-bounded staleness, read acceleration
Write-Around:   no write cache,       no write pollution
```

**There is no free lunch.** Every technique that improves hit rate or reduces write latency introduces a consistency window. The architect's job is to make that window explicit and match it to the SLA.

---

## Relationship to Storage-Layer Patterns

| Storage component | Cache pattern | Notes |
|-------------------|--------------|-------|
| Linux page cache | Read-Through + Write-Back | Dirty pages flushed by kswapd/writeback |
| bcache writeback | Write-Back | Journal on SSD for crash safety |
| bcache writearound | Write-Around | Correct default for sequential/backup |
| dm-cache | Read-Through + Write-Back or Write-Through | Configurable per volume |
| NVMe-oF host cache | Read-Through + Write-Through | Safety over performance for remote block |
| Ceph rbd_cache | Write-Back (default) | librbd side-cache before OSD |
| RocksDB block cache | Cache-Aside (managed by RocksDB) | W-TinyLFU eviction internally |
| Database buffer pool | Write-Back + WAL | WAL provides crash durability |

---

## References

- Facebook "Scaling Memcache at Facebook" (NSDI 2013) — Cache-Aside + invalidation at scale
- Google "Zanzibar" — version-based cache invalidation for authorization
- Twitter "Pelikan" — L1/L2 hybrid cache architecture
- Linux `mm/filemap.c` — page cache Read-Through implementation
- `drivers/md/bcache/` — Write-Back + Write-Around + Write-Through in one codebase
