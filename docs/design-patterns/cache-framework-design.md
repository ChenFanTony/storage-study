# Cache Framework Design — Architect's Reference

**Audience:** Senior storage architect
**Context:** How to design a cache layer from first principles — admission, eviction, write policy, ghost entries, writeback scheduling, sizing
**Related:** Month 1 bcache (day08-10), dm-cache (day11), Month 3 tiering automation (day22)

---

## The Six Orthogonal Design Dimensions

A cache framework has six independent design decisions. Getting any one wrong kills performance or correctness.

1. Admission policy — what gets cached?
2. Eviction policy — what gets kicked out?
3. Write policy — what happens on writes?
4. Ghost entry infrastructure — how do you learn from your own evictions?
5. Dirty tracking & writeback scheduling — how do you flush safely?
6. Cache sizing — how big does it need to be?

---

## 1. Admission Policy

The naive answer: cache every miss. This is wrong.

**Problems it creates:**
- **Scan pollution**: a sequential `dd` or backup sweep evicts the hot working set
- **One-hit wonders**: data accessed once takes a slot from frequently-accessed data
- **Write amplification**: admitting every write to SSD cache degrades the SSD unnecessarily

**Admission strategies:**

| Strategy | Mechanism | When to use |
|----------|-----------|-------------|
| Always admit | Every miss fills cache | Only if workload is purely random |
| Sequential bypass | Track sequential run length; bypass above threshold | Mixed random/sequential (bcache `sequential_cutoff`) |
| Ghost entry / second-chance | Admit only on second access; keep ghost (metadata-only) after eviction | Protects against one-hit wonders; ARC, 2Q use this |
| Frequency filter (TinyLFU) | Count-min sketch tracks frequency; admit only if frequency > threshold | Write-heavy caches, high-churn workloads |
| Cost-benefit admission | Admit only if estimated hit savings > eviction cost | When backing store retrieval cost is heterogeneous |

**The ghost entry pattern is critical** — you cannot distinguish a "first-time" miss from a "was-hot-but-evicted" miss without it. Without ghost entries, you are blind to your own eviction mistakes.

---

## 2. Eviction Policy

### LRU — the baseline

```
[MRU end]  →  hot  →  warm  →  cold  →  [LRU end, evict here]
```

- Works for pure temporal locality
- **Fails on scans**: one sequential read evicts the entire working set
- **Fails on frequency**: a block accessed 1000 times yesterday but not today gets evicted before one accessed once today

### LFU — frequency-aware but broken

- Counts accesses per block
- **Fails on stale frequency**: blocks that were hot 6 hours ago but are now cold never get evicted
- **Fails on cold start**: new blocks have count=0 and get evicted immediately even if they will be hot

### ARC (Adaptive Replacement Cache) — the engineering insight

IBM's key contribution. Maintains **four lists**:

```
T1: recently used, seen only once      (recency track)
T2: frequently used, seen multiple times  (frequency track)
B1: ghost list for evicted T1 items   (metadata only, no data)
B2: ghost list for evicted T2 items   (metadata only, no data)
```

**Self-tuning parameter `p`** (0 ≤ p ≤ c where c = cache size):
- `p` = target size for T1
- Ghost hit in B1 (evicted-once item re-accessed) → increase `p` (workload wants more recency)
- Ghost hit in B2 (evicted-frequent item re-accessed) → decrease `p` (workload wants more frequency)

ARC *learns* whether the current workload is recency-favoring or frequency-favoring. That is what makes it production-grade.

**Patent issue**: ARC is IBM-patented. Linux avoids it. ZFS uses it (came from Sun/Oracle).

### 2Q — ARC without the patent

```
A1in:  FIFO queue (new arrivals, limited size)
Am:    LRU queue (promoted items, large)
A1out: ghost list for items evicted from A1in
```

Flow:
- New block → A1in (FIFO, not LRU — sequential scans do not pollute Am)
- Hit while in A1in → stays in A1in (not yet "frequently used")
- Hit while in Am → move to MRU end of Am
- Ghost hit in A1out → admit directly to Am (this block proved useful)
- Eviction from A1in (full) → to A1out ghost; from Am → drop

Simpler than ARC and nearly as good for most workloads.

### W-TinyLFU — state of the art for in-memory caches

Used in RocksDB block cache and the Caffeine Java library.

```
Window LRU (1% of space):  new arrivals
Main cache (99%):           SLRU (protected + probationary segments)
Frequency sketch:           Count-Min Sketch approximates per-key frequency
```

**Admission gate**: when promoting from Window LRU to Main, compare candidate frequency vs victim frequency. Only admit if candidate is at least as frequent.

**Age decay**: periodically halve all counters in the sketch — prevents "frequency fossils" from blocking new hot data.

Scan-resistant, burst-tolerant, adapts without explicit tuning.

### dm-cache SMQ (Stochastic Multi-Queue)

What Linux production tiered storage actually uses.

```
Hot queue    (high frequency/recency score)
Warm queue   (medium)
Cold queue   (low) ← eviction victim
```

**Stochastic promotion**: not every hit triggers a queue promotion. The probability of promotion decreases as a block gets hotter. This prevents promotion overhead from dominating under high-IOPS workloads.

**Why not just LRU?** At 1M IOPS on a large NVMe cache, maintaining strict LRU order requires a linked-list update on every single read — that is a serialized lock contention bottleneck. SMQ batches and probabilistically approximates LRU at far lower overhead.

---

## 3. Write Policy

| Policy | Write path | Read-after-write | Cache failure risk | SSD wear |
|--------|-----------|-----------------|-------------------|----------|
| **Write-through** | Cache + backing store simultaneously | Safe (data in both places) | None (backing store always current) | Low |
| **Write-back** | Cache only; flush lazily | Safe (read hits cache) | **Data loss** if cache fails before flush | Higher (random writes land on SSD, cause write amplification) |
| **Write-around** | Bypass cache entirely | Cache miss on next read | None | None |

**The write-back trap**: architects choose write-back for write performance, then discover SSD write amplification is 10×, destroying the SSD in months. This happens because random writes to SSD have internal GC amplification on top of the cache's own GC.

**Write-around is underused**. For write-heavy streaming workloads (backup, ETL, log ingestion), write-around is correct — the data will not be re-read from cache anyway.

---

## 4. Ghost Entry Infrastructure

When you evict a block, you have a choice:
- **Forget it completely**: next access is treated as a cold miss
- **Keep a ghost entry** (metadata only — key + stats, no data): next access is a "ghost hit"

Ghost hits let you answer: *"Was this block worth caching? Did we evict it too soon?"*

Without ghost entries, ARC and 2Q **cannot function** — their self-tuning depends entirely on ghost hits to measure eviction quality.

**Implementation cost**: ghost entries are cheap — just the block address and a frequency counter or list pointer. You can afford 2× as many ghost entries as data entries.

**bcache's weakness**: bcache has no ghost entries. It cannot distinguish cold misses from hot-but-evicted blocks. This is why bcache thrashes when working set exceeds cache — it has no mechanism to learn from its own eviction mistakes.

---

## 5. Dirty Tracking & Writeback Scheduling

For write-back caches, this is the operational complexity.

**Per-block state:**
```
[clean | dirty | writeback-in-progress]
```

**What bcache actually tracks** (`drivers/md/bcache/btree.h`):
- Each bucket has a `dirty` ratio
- The allocator prefers to GC buckets that are mostly clean
- The writeback thread uses a PID controller to keep dirty data % at target (`writeback_rate_p_term_inverse`, `writeback_rate_i_term_inverse`)

**The writeback cliff**: if dirty data accumulates to 100% of cache, then flushes suddenly:
1. All cache writes blocked (no clean space)
2. Burst of writeback I/O to backing store
3. Backing store saturated → cache reads for miss also blocked
4. Application stall

**Correct design**: start writeback **early** (at 30-40% dirty) and maintain a continuous low-rate flush. This is why `dirty_ratio` and `dirty_background_ratio` exist in the Linux VM, and why bcache has PID controller tuning knobs.

**Sizing the writeback rate**: at steady state, writeback rate must ≥ write rate × dirty_ratio target. If the backing store cannot absorb this rate, the cache fills and stalls regardless of eviction policy.

---

## 6. Cache Sizing & the Working Set Model

No eviction algorithm can save a cache undersized for the working set.

**Working set**: the set of blocks accessed in the last T seconds, where T = application request period or "think time."

**Practical sizing heuristics:**

| Workload | Cache size target |
|----------|-------------------|
| OLTP random reads | 10-20% of hot dataset |
| Database buffer pool | 100% of working set if possible |
| Metadata caching | 100% (metadata is small and always hot) |
| Object storage | Highly variable; model from access logs |

**Diminishing returns**: once cache exceeds the working set, you are caching cold data. Hit rate plateaus. Don't over-provision.

**Target hit rate**: ≥90% for meaningful latency benefit. Below ~80%, average latency is dominated by backing store latency — the cache is providing little value.

**bcache bucket size**: must match SSD erase block size (typically 512KB-2MB for modern NVMe). Misalignment causes write amplification inside the SSD on top of cache-level WA.

**Metadata overhead rule of thumb**: ~1-2% of cache size is consumed by mapping metadata (bcache B+tree, dm-cache metadata device).

---

## Architect Decision Tree

```
Workload type?
├── Pure random I/O, high reuse
│   └── ARC or W-TinyLFU eviction, always-admit, write-back
├── Mixed random + sequential
│   └── 2Q or SMQ eviction, sequential bypass admission, write-back for randoms
├── Write-heavy, reads are later
│   └── write-back, W-TinyLFU with frequency gate, ghost entries critical
├── Streaming (backup, ETL, log)
│   └── write-around for writes, sequential bypass or write-around for reads
└── Database workload (Postgres, MySQL, RocksDB)
    └── Application manages its own buffer pool — block cache adds L2
        └── Use O_DIRECT + write-around; let the app cache do the work
```

**Most common architect mistake**: choosing write-back without modeling the dirty data curve.

Always compute: `peak write rate × dirty ratio target = dirty flush rate required`

If backing store cannot absorb that flush rate, the cache fills and stalls. Model this before choosing write-back.

---

## bcache vs dm-cache Comparison

| Mechanism | bcache | dm-cache |
|-----------|--------|----------|
| Eviction | Bucket-level LRU + GC priority score | SMQ (stochastic multi-queue) |
| Admission | Sequential bypass (`sequential_cutoff`), priority hints | Policy-controlled (smq, cleaner) |
| Ghost entries | **No** (known weakness) | **No** |
| Write policy | write-through or write-back | write-through or write-back |
| Metadata store | B+tree on cache device | Separate metadata device |
| Promotion granularity | Full block (default 4KB) | Configurable block size |
| Lock contention at high IOPS | Higher (B+tree lock) | Lower (SMQ probabilistic) |

**bcache key weakness**: no ghost entries means no learning from eviction mistakes. Thrashes under working-set-exceeds-cache conditions.

**dm-cache SMQ key advantage**: stochastic promotion keeps metadata overhead bounded at high IOPS.

**Next level**: SPDK blobstore + user-space cache — no kernel lock contention at all, full control over all six dimensions.

---

## Key Papers and References

| Paper | Why it matters |
|-------|---------------|
| ARC (Megiddo & Modha, FAST 2003) | The adaptive recency/frequency balance |
| 2Q (Johnson & Shasha, VLDB 1994) | Practical ARC alternative without patent issues |
| TinyLFU (Einziger et al., SYSTOR 2014) | Frequency sketch admission filter |
| W-TinyLFU (Einziger et al., 2017) | Window + SLRU; what RocksDB uses |
| "bcache: Caching beyond just RAM" (Overstreet, 2013) | bcache design rationale |
| dm-cache design doc (kernel `Documentation/device-mapper/cache.md`) | SMQ policy details |
