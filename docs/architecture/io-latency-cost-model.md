# I/O Latency Cost Model — Performance vs Consistency Reference

**Audience:** Senior storage architect
**Context:** Quantified cost of every OS and hardware overhead affecting I/O latency — syscall, context switch, cache miss, lock, TLB, interrupts — and how they compound in distributed systems
**Related:** L1-single-node/kernel-io/ (blk-mq, io_uring, schedulers), L3-cluster-scheduling/ (fail-slow, fleet QoS), architecture/reliability/ (SLO design)

---

## Layer 0: Hardware Latency Baseline (Immovable Physics)

Software can only add overhead on top of these numbers. It can never beat them.

| Hardware | Latency | Notes |
|----------|---------|-------|
| L1 cache hit | 1–4 ns | 32–64KB per core |
| L2 cache hit | 4–12 ns | 256KB–1MB per core |
| L3 cache hit | 30–50 ns | 4–64MB shared |
| DRAM (local) | 60–80 ns | DDR4/DDR5 |
| DRAM (NUMA remote, 1 hop) | 120–150 ns | 2-hop = 200–250ns |
| NVMe SSD (QD=1) | 20–70 µs | Drops to ~10µs at QD=32 |
| Optane / Persistent Memory | 300 ns–3 µs | DAX path bypasses block layer |
| SATA SSD | 50–100 µs | |
| HDD (7200 RPM) | 4–8 ms | Seek + rotational latency |
| 100GbE same-rack (TCP) | 5–10 µs | Wire + switch forwarding |
| RDMA (RoCEv2) | 1–3 µs | Kernel bypass |
| Same-DC different rack | 20–50 µs | |
| Cross-DC WAN | 1–100 ms | Geography-bound |

---

## Layer 1: OS Overhead Catalog

### Syscall

| Scenario | Latency | Why |
|----------|---------|-----|
| Syscall (pre-Spectre, no KPTI) | ~25 ns | SYSCALL/SYSRET only |
| Syscall (post-Spectre + KPTI) | 100–200 ns | TLB flush on kernel entry + retpoline |
| `read()` full path (O_DIRECT, warm) | ~3–5 µs | Syscall + VFS + blk-mq + driver, no device wait |
| `read()` with NVMe device | ~25–80 µs | Above + device latency |
| io_uring (batched, amortized) | ~50–100 ns per I/O | One syscall per batch of N I/Os |

**Scale impact**: at 1M IOPS, 200ns × 1M = 200ms of pure syscall overhead per second across the machine. This is why io_uring and SPDK exist.

### Context Switch

The commonly quoted "5–15µs" depends entirely on working set size:

| Scenario | Cost | Mechanism |
|----------|------|-----------|
| Pure register save/restore | ~1–2 µs | Minimal — just the switch itself |
| + L1/L2 cache cold (small task) | ~3–8 µs | Hot data must be re-fetched |
| + L3 cache cold (medium working set) | ~10–30 µs | TLB + L3 miss cascade |
| + NUMA mismatch (wrong socket) | ~50–150 µs | Remote DRAM for every cache miss |
| IRQ handler → process context | ~2–5 µs | Interrupt returns to process |

**Real storage daemon cost**: a 64-thread storage server with 4MB per-thread working set — after a context switch, re-warming L3 takes 4MB / ~40GB/s L3 bandwidth = ~100µs. The "pure switch" cost of 1µs is irrelevant; cache re-warm is the real number.

**Elimination**: SPDK/DPDK polling dedicates one CPU core to spin on NVMe completion queue. Zero context switches. Eliminates 100% of this overhead at the cost of one dedicated core.

### CPU Cache Miss

| Cache level | Miss penalty | Storage implication |
|-------------|-------------|---------------------|
| L1 miss → L2 | ~4 ns | Hot path struct fields outside L1 |
| L2 miss → L3 | ~12 ns | Request queue head, tag bitmap |
| L3 miss → DRAM | 60–80 ns | Cold bio path, metadata for random I/O |
| False sharing (two cores, same cache line) | 40–100 ns | Lock word + data on same 64B line |
| Cache line bounce (lock contention) | 100–300 ns | Lock ping-pong between L3 domains |

**Hot path accumulation per NVMe I/O** (block layer structs touched):
- `bio` struct: 1 cache line
- `request` struct: 2–4 cache lines
- `blk_mq_ctx` (per-CPU software queue): 1–2 cache lines
- `blk_mq_hw_ctx` (hardware queue): 2 cache lines
- Tag bitmap word: 1 cache line
- NVMe SQE/CQE: 1 cache line each

All warm (L1/L2): ~10–30ns total. Any cold (random I/O, many concurrent queues): ~300–600ns in cache misses alone.

**Why blk-mq is per-CPU**: keeping `blk_mq_ctx` per-CPU means the software queue never bounces between cores. Cache stays warm at the cost of per-CPU memory.

### TLB Miss

| Scenario | Cost |
|----------|------|
| L1 TLB hit | 0–1 ns |
| L1 TLB miss → L2 TLB | ~5 ns |
| L2 TLB miss → page table walk (L3-resident) | ~50–100 ns |
| Page table walk → DRAM | ~200–300 ns |
| TLB shootdown (cross-CPU, IPI) | ~100–500 ns per CPU notified |

**O_DIRECT with 4KB pages on a 1GB buffer**: 262,144 page table entries. L2 TLB holds ~1500 entries. Every I/O to a different 4KB region = TLB miss + page walk = ~100–300ns overhead.

**Huge page fix**: 2MB huge pages reduce TLB pressure 512×. A 1GB buffer = 512 TLB entries — fits in L1 TLB. Saves 50–200ns per I/O on random workloads. This is why SPDK, DPDK, and production databases mandate huge pages.

### Lock Overhead

| Lock type | Uncontended | Contended (2 cores) | Contended (many cores) |
|-----------|-------------|--------------------|-----------------------|
| Spinlock | 5–10 ns | 50–200 ns | µs scale (O(N) bounce) |
| Mutex (uncontended) | 20–30 ns | — | — |
| Mutex (contended, sleep/wake) | — | 5–15 µs | 5–15 µs + scheduling |
| RWlock read | 10–20 ns | 50–200 ns | Degrades with core count |
| RCU read side | 2–5 ns | 2–5 ns | 2–5 ns (never contended) |
| Atomic CAS (uncontended) | 4–8 ns | 20–100 ns | µs scale |
| Semaphore | 30–50 ns | 5–20 µs | 5–20 µs |

**The spinlock trap**: at 1M IOPS with a global spinlock and 32 cores each submitting 31K IOPS: average wait = 31 × 10ns = ~310ns per I/O just in lock wait — before contention even shows up. Compounds super-linearly with core count.

**The RCU payoff**: NVMe namespace lookup and blk-mq hwqueue mapping cost 2–5ns regardless of how many cores read simultaneously. No scaling penalty at any core count.

### Memory Allocation

| Operation | Latency | Notes |
|-----------|---------|-------|
| kmalloc (slab cache, warm) | 100–200 ns | Per-CPU slab cache hit |
| kmalloc (slab, cold) | 500 ns–2 µs | New slab page required |
| GFP_ATOMIC (in interrupt) | 50–200 ns | No sleep, limited emergency pool |
| vmalloc | 10–100 µs | Page table setup overhead |
| Memory pressure → reclaim | 1–100 ms | kswapd wakes, writeback triggered |

**Why bio/request slabs matter**: at 500K IOPS, fast path bio allocation (~200ns) = 100ms/s overhead. Slow path fallback (~2µs) = 1000ms/s — 10× worse, immediately visible as latency spikes.

### Interrupt vs Polling

| Mechanism | Latency added | Throughput ceiling |
|-----------|--------------|-------------------|
| MSI-X interrupt (NVMe completion) | 3–8 µs | ~1M IOPS/device |
| Interrupt coalescing (batch 8) | 8–50 µs (higher latency) | ~8M IOPS/device |
| SPDK busy-poll | ~1–2 µs | Limited by CPU, not device |
| NAPI (network adaptive) | 2–5 µs | Adaptive interrupt→poll |

**Interrupt latency floor**: NVMe completion ISR → softirq → `blk_mq_complete_request` → `bio_endio` adds 3–8µs on top of device latency. Local NVMe hardware takes 20–70µs; application sees 25–80µs. The delta is pure interrupt overhead. SPDK polling drops this to ~1–3µs total stack overhead.

---

## Layer 2: Single-Node I/O Latency Budget (4KB O_DIRECT NVMe Read)

```
Syscall entry (post-Spectre)                  ~   150 ns
VFS lookup + file position check              ~   200 ns
Block layer (bio alloc + blk-mq dispatch)     ~ 1–3   µs
NVMe driver (SQE write + doorbell ring)       ~   500 ns
─── hardware boundary ─────────────────────────────────────
NVMe device processing                        ~ 20–70  µs   ← physics
─── hardware boundary ─────────────────────────────────────
NVMe completion interrupt                     ~ 1–2   µs
Softirq + blk_mq_complete_request             ~ 1–2   µs
bio_endio → wake up waiting reader            ~   500 ns
Context switch back to reader                 ~ 2–10  µs
Syscall return                                ~   150 ns
────────────────────────────────────────────────────────────
Total observed latency                        ~ 28–90  µs
  Device physics (immovable floor)            ~ 20–70  µs
  Software overhead                           ~  8–20  µs
```

**Software overhead is 10–40% of total** even for the fastest NVMe.
For Optane (300ns device latency), software overhead is **10–100× the device latency**. The device is faster than the I/O path built around it.

**io_uring improvement**: batching avoids per-I/O syscall + amortizes context switches → saves 1–5µs per I/O at high queue depth.

**SPDK improvement** (user-space + polling):
- Eliminates interrupt + softirq: −2–4µs
- Eliminates context switch: −2–10µs
- Eliminates syscall: −150ns
- Result: 30µs NVMe → ~15µs observed. ~50% stack overhead reduction.

---

## Layer 3: Distributed System — Cost Compounding

### Context Switches Per Distributed I/O

A single distributed storage I/O accumulates:

```
Client process → kernel (syscall)               ~ 5  µs  [1 switch]
Kernel → NIC driver softirq                     ~ 3  µs  [1 switch]
NIC softirq → TCP receive processing            ~ 3  µs  [1 switch]
TCP receive → server thread (epoll wakeup)      ~ 8  µs  [1 switch]
Server thread → NVMe submission                 ~ 5  µs  [1 switch]
NVMe completion IRQ → server thread             ~ 5  µs  [1 switch]
Server reply: TCP send                          ~ 1  µs  [internal]
Client NIC IRQ → TCP receive → epoll            ~ 10 µs  [2 switches]
Epoll → client thread wakeup                    ~ 8  µs  [1 switch]
────────────────────────────────────────────────────────────────────
Context switch overhead alone:                  ~ 48 µs
```

This 48µs sits on top of both network and device latency. It is why a 10µs RDMA path still shows 50–80µs end-to-end over TCP — the OS contributes more overhead than the wire.

**RDMA eliminates 3–4 of these switches**: kernel bypass on the data path drops OS overhead to ~5–10µs. RDMA's real value is not raw wire speed (100GbE is the same speed) — it is eliminating kernel context switches on the data path.

### Replicated Write Latency Stack (3-Way, Same Rack, NVMe)

```
Client:
  Syscall + VFS + blk-mq                       ~    5 µs
  Serialization                                 ~   10 µs
  TCP send + NIC TX                             ~    5 µs
Network (client → primary):                     ~   10 µs
Primary OSD:
  Context switch (recv → thread)                ~    5 µs
  Deserialize + validate                        ~   10 µs
  Write to NVMe journal/WAL                     ~   20 µs
  Replicate to 2 replicas (parallel):
    Network to each replica                     ~   10 µs
    Replica NVMe write                          ~   20 µs
    Replica ACK back                            ~   10 µs
  Wait for both replica ACKs (max of 2)         ~   40 µs
  ACK to client                                 ~   10 µs
Client:
  Context switch (wake from wait)               ~    5 µs
────────────────────────────────────────────────────────────
Total 3-way replicated write (same rack, NVMe): ~ 120–200 µs
Same with HDD journal:                          ~   5–15 ms
Same with cross-rack network (50µs RTT):        ~ 300–500 µs
```

A 20µs NVMe write becomes 120–200µs with 3-way replication on the same rack. Every network hop multiplies the base cost by the number of required round trips.

### Consistency Level vs Latency

```
Eventual consistency (Ceph async):
  Write:  20–70µs  (local NVMe, background replicate)
  Read:   20–70µs  (may read stale replica)
  Stale risk: 10–100ms replication lag

Read-your-writes (session consistency):
  Write: local + async replicate    ~  20–70µs
  Read:  route to same OSD          ~  20–70µs
  Stale risk: none for same client

Strong consistency (linearizable, Raft):
  Write: 2×RTT + flush
    Same rack:  2×10µs + 20µs  =  ~  60 µs
    Same DC:    2×50µs + 20µs  =  ~ 150 µs
    Cross-DC:   2×5ms  + 20µs  =  ~  10 ms
  Read: must go to leader           ~ 40–200 µs
  Stale risk: zero
```

**The cross-DC consistency tax**: strong consistency across datacenters costs a minimum of 2× RTT per write. At 5ms RTT, that is 10ms minimum latency floor — no amount of software optimization can beat the speed of light. This is why geo-distributed databases use eventual consistency or asynchronous replication by default.

### Fsync / Durability Cost

| Durability level | Mechanism | Latency | Data at risk |
|-----------------|-----------|---------|-------------|
| Page cache only | No sync | ~0µs | Seconds of writes on crash |
| Write barrier | Ordered write | +5–20µs (NVMe) | 0 (ordering guaranteed) |
| fdatasync | Flush data + metadata | +20–200µs (NVMe) | 0 |
| fsync | Full flush | +50–500µs (NVMe) | 0 |
| Power-loss protected NVMe (FUA) | On-die capacitor | +0µs | 0 |
| HDD fsync | Rotational flush | +4–10ms | 0 |

**Group commit payoff** (PostgreSQL WAL pattern):
- Per-transaction fsync at 50µs: max 20K commits/second
- Group commit (100 transactions per fsync): 2M commits/second at identical durability
- Group commit does not reduce durability — it amortizes the flush cost across N transactions

---

## Layer 4: Tail Latency Amplification at Scale

From "Tail at Scale" (Dean & Barroso, CACM 2013):

If one server has p99 = 1ms and a request fans out to N servers:
```
P(at least one server exceeds p99) = 1 - (1 - 0.01)^N

N=10:   1 - 0.99^10  = 10%
N=100:  1 - 0.99^100 = 63%
N=1000: 1 - 0.99^1000 = 99.996%
```

At 1000 servers, essentially every fan-out request hits at least one server at p99. Your system's effective tail latency is bounded by the single worst server in the fan-out.

**The fail-slow corollary** (from Perseus, FAST '23): 304 drives out of 248K (0.12% of fleet) caused 48% of p99.99 tail latency. At scale, even a tiny fraction of degraded components owns the tail entirely.

**Hedged requests** (mitigation — not a fix):
Send the same request to 2 servers; use whichever responds first. Cancel the other.
- Cost: 2× read bandwidth consumption
- Benefit: p99 of 2 independent requests = p99²
  - If one server p99 = 1ms: with hedging, p99 = P(both > 1ms) = 0.01² = 0.01%
- Use when: read bandwidth is cheap, latency SLO is tight, fail-slow is not yet detected

---

## Layer 5: Latency Budget Reference Card

**Single-node NVMe I/O (O_DIRECT):**
```
Best case  (SPDK polling, io_uring, warm):   ~ 15–25  µs
Typical    (interrupt, single syscall):      ~ 30–80  µs
Worst case (cold cache, lock contention):    ~ 100–500 µs
```

**Distributed — same rack, NVMe OSDs, TCP:**
```
Async read (nearest replica):                ~  50–150 µs
Async write (local + background replicate):  ~  30–80  µs
Sync write (3-way, wait for quorum):         ~ 120–300 µs
Strong consistency read (from leader):       ~  80–200 µs
```

**Distributed — same DC, different racks:**
```
Async read:                                  ~  80–200 µs
Sync write (Raft quorum):                    ~ 200–600 µs
```

**Distributed — cross-DC:**
```
Async read (local replica):                  ~  30–80  µs
Async write (replicate in background):       ~  30–80  µs
Sync write (strong consistency):             ~  10–200 ms
```

---

## Layer 6: Architect Decision Framework

### When Each Optimization Is Worth It

| Optimization | Latency saved | Complexity cost | When to apply |
|-------------|--------------|----------------|---------------|
| io_uring batching | 1–5 µs/IO | Low | Always for high-IOPS workloads |
| SPDK polling | 5–15 µs/IO | High (dedicated core, DPDK stack) | >500K IOPS, latency-critical |
| Huge pages | 50–200 ns/IO | Low | Any random-access workload |
| Per-CPU data structures | 50–200 ns/access | Medium | Any shared hot-path data |
| RCU for read-heavy config | 2–5 ns vs 10–200 ns | Medium | Per-I/O config lookups |
| RDMA instead of TCP | 30–50 µs/IO | Very high | <5µs RTT required, homogeneous fabric |
| Async replication | 1–10 ms/write | Low | Cross-DC, or where RPO > 0 is acceptable |
| Group commit / WAL batching | Amortize flush across N | Medium | Write-heavy OLTP |

### The Fundamental Tradeoff

```
Every consistency guarantee costs at minimum 1 network RTT per ordering level.

Same rack  (10µs RTT):  strong consistency adds ~20µs  → often worth it
Same DC    (50µs RTT):  strong consistency adds ~100µs → evaluate per SLO
Cross-DC   (5ms RTT):   strong consistency adds ~10ms  → almost never worth it
```

The only ways to avoid this:
1. **Relax consistency** — async replication, eventual consistency
2. **Co-locate replicas** — same rack, same node with battery-backed NVRAM
3. **Change the physics** — RDMA (cuts RTT 5–10×), not possible cross-DC

### Diagnostic Questions for Latency Investigation

| Symptom | Likely cause | Tool |
|---------|-------------|------|
| p99 >> p50 | Tail events: GC, lock contention, fail-slow disk | `biolatency`, Perseus metrics |
| Latency spikes at write rate threshold | Writeback cliff (dirty ratio hit) | `bpftrace balance_dirty_pages` |
| Latency proportional to core count | Lock contention (spinlock scaling) | `perf lock`, `bpftrace` |
| High latency only on NUMA-remote CPUs | NUMA mismatch | `numastat`, `perf c2c` |
| Latency floor higher than device spec | Software overhead (interrupt, ctx switch) | `blktrace`, `fio --lat_percentiles` |
| Periodic latency spikes (~every 100ms) | GC / compaction (RocksDB, bcache) | `iostat`, GC stats |
| Distributed p99 >> local p99 | Context switch accumulation, TCP overhead | Distributed tracing, `ss -i` |

---

## Summary: Numbers Every Storage Architect Must Know

```
Syscall overhead (post-Spectre):        100–200  ns
Context switch (cache effects):         5–50     µs  (working-set dependent)
L3 cache miss → DRAM:                  60–80    ns
False sharing / lock bounce:            100–300  ns
RCU read side:                         2–5      ns
Huge page TLB savings:                 50–200   ns/IO
NVMe interrupt overhead:               3–8      µs
SPDK polling saving:                   5–15     µs

Local NVMe I/O (typical):              30–80    µs
RDMA round trip:                       1–3      µs
100GbE TCP round trip (same rack):     10–20    µs

3-way replicated write (same rack):    120–300  µs
Raft commit (same rack):               60–150   µs
Raft commit (cross-DC):                10–200   ms

fdatasync (NVMe, power-loss prot.):    20–50    µs
fdatasync (NVMe, no protection):       200–500  µs
fdatasync (HDD):                       4–10     ms

Tail amplification (N=100, p99=1ms):   63% of requests hit tail
```
