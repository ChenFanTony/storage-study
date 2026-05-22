# Day 30: Capstone — Memory + Storage Integration

## Learning Objectives
- Synthesize all 30 days into four end-to-end integration exercises
- Demonstrate mastery by diagnosing and fixing real storage-memory interaction problems
- Build the complete mental model connecting physical memory → virtual memory → page cache → reclaim → advanced features → storage performance
- Identify your remaining gaps and next study directions

---

## 1. Integration Exercise 1: Writeback Storm Diagnosis & Fix

**Scenario:** Production fio benchmark shows great average throughput but terrible p99. On-call says "disk is slow." You have 5 minutes.

### Step 1: Rapid Triage (60 seconds)

```bash
# Run all at once:
echo "=== Memory ===" && \
grep -E "MemAvailable|Dirty|Writeback" /proc/meminfo && \
echo "=== PSI ===" && cat /proc/pressure/memory && cat /proc/pressure/io && \
echo "=== Reclaim ===" && vmstat 1 3 && \
echo "=== Writeback config ===" && \
sysctl vm.dirty_ratio vm.dirty_background_ratio vm.dirty_expire_centisecs
```

**Diagnosis:** `Dirty: 40GB`, `dirty_ratio=20`, `MemTotal=200GB` → 40/200 = 20% → dirty_ratio threshold hit → writers stalling. `PSI io.some avg10=45%` confirms I/O stall.

### Step 2: Reproduce the Storm

```bash
# Reproduce in controlled environment:
sysctl -w vm.dirty_ratio=20
sysctl -w vm.dirty_background_ratio=10

# Write at high rate:
fio --name=storm --rw=write --bs=128k --size=50G \
    --filename=/tmp/storm --direct=0 --numjobs=4 --runtime=60 \
    --group_reporting --output-format=json+ > /tmp/storm_result.json &

# Monitor in parallel:
while kill -0 $! 2>/dev/null; do
    dirty=$(awk '/^Dirty/{print $2}' /proc/meminfo)
    wb=$(awk '/^Writeback:/{print $2}' /proc/meminfo)
    echo "$(date +%H:%M:%S) dirty=${dirty}kB wb=${wb}kB"
    sleep 1
done

# You will see: dirty climbs → hits threshold → Writeback spikes → dirty drops → repeat
```

### Step 3: Fix and Verify

```bash
# Apply fix:
sysctl -w vm.dirty_ratio=5
sysctl -w vm.dirty_background_ratio=2
sysctl -w vm.dirty_expire_centisecs=1000

# Re-run benchmark:
fio --name=fixed --rw=write --bs=128k --size=50G \
    --filename=/tmp/fixed --direct=0 --numjobs=4 --runtime=60 \
    --group_reporting --percentile_list=50,90,99,99.9

# Compare p99 latency: should be 5-20× lower
# Monitor: dirty should stay << 5% of RAM; steady writeback, no storm
```

### What You Know Now (that you didn't before this curriculum)
- `dirty_ratio` is the **stall threshold**, not the "start writing" threshold
- `dirty_background_ratio` is "start writing quietly" — must be < dirty_ratio
- The I/O spike is writeback flush, not random disk slowness
- Fix is reducing thresholds, not upgrading hardware

---

## 2. Integration Exercise 2: NUMA NVMe Alignment

**Scenario:** New 2-socket server with 2× NVMe (one per socket). Benchmark shows 15% lower throughput than expected. Team says "NVMe is defective."

### Diagnose

```bash
# Step 1: Find NVMe NUMA affinity:
for nvme in /sys/block/nvme*; do
    dev=$(basename $nvme)
    node=$(cat $nvme/device/numa_node 2>/dev/null || echo "unknown")
    echo "$dev: NUMA node $node"
done

# Step 2: Check current process affinity:
numactl --show
# If running with default policy: memory allocated on whichever node
# has free pages → potentially wrong node

# Step 3: Check NUMA miss rate:
numastat
# High numa_miss = wrong-node allocations

# Step 4: Measure baseline with misaligned access:
fio --name=misaligned --rw=randread --bs=4k --size=20G \
    --filename=/dev/nvme0n1 --direct=1 --numjobs=8 --runtime=30

# Step 5: Run with correct NUMA binding:
NVME0_NODE=$(cat /sys/block/nvme0n1/device/numa_node)
numactl --cpunodebind=$NVME0_NODE --membind=$NVME0_NODE \
fio --name=aligned --rw=randread --bs=4k --size=20G \
    --filename=/dev/nvme0n1 --direct=1 --numjobs=8 --runtime=30

# Expected: 10-20% throughput increase, lower CPU utilization
```

### Understand Why

```
Without numactl: CPU on node 1 submits I/O for NVMe on node 0
  → DMA buffer allocated on node 1 (where CPU is running)
  → NVMe (node 0) DMA crosses QPI/UPI to node 1 memory
  → QPI bandwidth: ~100GB/s; NVMe bandwidth: ~7GB/s → not the bottleneck
  → BUT: DMA descriptor fetch and interrupt handling still cross NUMA
  → Interrupt affinity mismatch: IRQ on wrong core → extra IPI

With numactl: CPU, DMA buffer, and NVMe all on node 0
  → All PCIe transactions local to node 0
  → Interrupt handled by local CPU
  → Optimal
```

### Fix for Production

```bash
# Pin storage daemon to NVMe's NUMA node:
NVME_NODE=$(cat /sys/block/nvme0n1/device/numa_node)

# systemd override:
systemctl edit your-storage-service
# [Service]
# ExecStart=
# ExecStart=numactl --cpunodebind=NVME_NODE --membind=NVME_NODE /usr/bin/your-daemon

# Or set NVMe IRQ affinity:
for irq in $(grep nvme /proc/interrupts | awk -F: '{print $1}'); do
    # Get CPUs local to NVMe's node:
    local_cpus=$(cat /sys/devices/system/node/node${NVME_NODE}/cpumap)
    echo $local_cpus > /proc/irq/$irq/smp_affinity
done
```

---

## 3. Integration Exercise 3: cgroup Memory + I/O Degradation

**Scenario:** Containerized PostgreSQL with `memory.max=8G`. Full table scan of 20GB table takes 60 seconds. Same query without container: 8 seconds. Engineers blame "container overhead."

### Diagnose

```bash
# Step 1: Check container memory stats during query:
CGROUP="/sys/fs/cgroup/postgres-container"

# Run query and monitor:
(while true; do
    current=$(cat $CGROUP/memory.current)
    events=$(cat $CGROUP/memory.events)
    stat=$(cat $CGROUP/memory.stat | grep -E "pgmajfault|file ")
    echo "$(date +%T) mem=$(( current / 1024 / 1024 ))MB | $events | $stat"
    sleep 1
done) &
MONPID=$!

# Run the query (in postgres container)...
kill $MONPID

# What you see:
# - memory.current hits 8GB quickly
# - memory.events: high=50000+ (hitting memory.high threshold constantly)
# - memory.stat pgmajfault climbing (every table page = NVMe read)
```

### Understand Why

```
Query reads 20GB table:
  Loop: filemap_fault() → page not in cache → READ from NVMe
       → page added to page cache
       → mem_cgroup_charge() → cgroup at 8GB = memory.high hit
       → kernel reclaims WITHIN cgroup → evicts recently-read pages
       → next page = another cache miss → another NVMe read
  
  Result: 20GB of sequential reads, each requiring a NVMe read
         (sequential on NVMe: ~3GB/s → 20GB / 3GB/s = ~7 seconds just I/O)
  
  But with reclaim thrashing:
         read → evict → read → evict ...
         effective throughput: 500MB/s (thrashing overhead)
         20GB / 500MB/s = 40 seconds
```

### Fix

```bash
# Option A: Increase memory.max (simplest):
echo "24G" > $CGROUP/memory.max    # larger than table

# Option B: Use memory.low to protect working set:
echo "7G" > $CGROUP/memory.low     # protect 7GB of cache within limit
echo "8G" > $CGROUP/memory.max     # keep container bounded
# Kernel will protect 7GB from reclaim even under system pressure

# Option C: Use O_DIRECT for sequential scans (PostgreSQL does this):
# In postgresql.conf:
# enable_hashagg = off   (for table scans specifically)
# PostgreSQL's own "work_mem" manages the scan buffer without page cache

# Validate fix:
# Run query again; check memory.events high count (should be near 0 with Option A)
cat $CGROUP/memory.events
# Also check pgmajfault rate: should drop dramatically
cat $CGROUP/memory.stat | grep pgmajfault
```

---

## 4. Integration Exercise 4: Complete Diagnostic Scenario

**Scenario:** Production NVMe storage server. Alert: "p99 I/O latency > 100ms for last 15 minutes." You are handed SSH access. Diagnose root cause and propose fix.

### Your Systematic Approach

```bash
# ── PHASE 1: 60-second triage ────────────────────────────────────────────
echo "=== 1. Memory overview ===" 
free -h
cat /proc/meminfo | grep -E 'MemAvailable|Dirty|Writeback|Slab|SUnreclaim|SwapUsed'

echo "=== 2. PSI pressure stalls ===" 
cat /proc/pressure/memory
cat /proc/pressure/io

echo "=== 3. Reclaim activity ===" 
vmstat 1 5

echo "=== 4. Who is using memory ===" 
ps aux --sort=-%mem | head -10

# ── PHASE 2: Focused investigation based on Phase 1 findings ─────────────

# IF Dirty is near dirty_ratio threshold:
echo "DIAGNOSIS: Writeback storm"
sysctl vm.dirty_ratio vm.dirty_background_ratio
# FIX: reduce thresholds (see Exercise 1)

# IF vmstat shows si>0 or so>0:
echo "DIAGNOSIS: Active swap I/O"
swapon --show
cat /proc/meminfo | grep -E 'SwapUsed|Inactive.anon'
# FIX: identify swap consumer, add RAM, or increase vm.swappiness if fast NVMe swap

# IF PSI memory.full > 0 and slab is large:
echo "DIAGNOSIS: Slab pressure"
slabtop -o | head -20
cat /proc/meminfo | grep -E 'SReclaimable|SUnreclaim'
# FIX: if SUnreclaim growing = kernel leak; if SReclaimable large = ok (reclaimable)

# IF pgmajfault rate is high (check /proc/vmstat):
echo "DIAGNOSIS: Page cache misses causing I/O"
cat /proc/vmstat | grep pgmajfault
/usr/share/bcc/tools/cachestat 1    # check hit rate
# FIX: identify which process is causing misses; check if cgroup limits are too tight

# IF numastat shows high numa_miss:
echo "DIAGNOSIS: NUMA misalignment"
numastat
cat /sys/block/nvme0n1/device/numa_node
# FIX: pin storage processes to NVMe's NUMA node

# IF THP collapse rate is high:
echo "DIAGNOSIS: khugepaged collapse latency"
cat /proc/vmstat | grep thp_collapse
# FIX: echo madvise > /sys/kernel/mm/transparent_hugepage/enabled

# ── PHASE 3: Apply fix, validate ─────────────────────────────────────────
# Apply appropriate fix from above
# Rerun fio benchmark or wait for next alert window
# Verify: PSI io drops, vmstat normalizes, p99 latency returns to baseline
```

---

## 5. The Complete MM → Storage Mental Model

Draw this from memory. This is your mastery test:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Physical Memory Layer                            │
│  NUMA Node → Zone (DMA/NORMAL) → Buddy allocator (order 0-10)     │
│  ↓ GFP_NOIO/NOFS flags prevent deadlock                           │
│  Slab/SLUB (bio, request, inode caches) + mempool (guaranteed)     │
│  vmalloc (non-contiguous) + ioremap (device MMIO → NVMe BAR)       │
└─────────────────────────┬───────────────────────────────────────────┘
                          │ physical pages
┌─────────────────────────▼───────────────────────────────────────────┐
│                    Virtual Memory Layer                             │
│  mm_struct → VMAs → page tables (PGD/PUD/PMD/PTE)                 │
│  mmap() → VMA created → demand paging (no pages yet)               │
│  Page fault → handle_mm_fault():                                    │
│    anon: do_anonymous_page() → buddy allocation                     │
│    file: filemap_fault() → PAGE CACHE LOOKUP ← (bridge below)      │
│    COW: do_wp_page() → copy on write                                │
│  TLB: caches VA→PA; shootdown on munmap/mprotect (NUMA cost)       │
│  FOLL_PIN: io_uring fixed buffers (immovable, no per-I/O DMA map)  │
└─────────────────────────┬───────────────────────────────────────────┘
                          │ struct folio / address_space
┌─────────────────────────▼───────────────────────────────────────────┐
│                    Page Cache Layer                                 │
│  struct address_space xarray → folios indexed by file offset        │
│  read() and mmap() share same physical pages (zero copy)            │
│  dirty pages: PG_dirty → bdi_writeback → block layer → NVMe        │
│  dirty_ratio threshold → writers stall → WRITEBACK STORM           │
│  dirty_background_ratio → background writeback (no stall)          │
└─────────────────────────┬───────────────────────────────────────────┘
                          │ LRU lists
┌─────────────────────────▼───────────────────────────────────────────┐
│                    Reclaim Layer                                    │
│  kswapd: wakes at WMARK_LOW → scans Inactive(file) first           │
│  clean pages: free immediately; dirty pages: write then free        │
│  → RECLAIM-DRIVEN I/O: the source of "memory pressure = I/O spikes"│
│  direct reclaim: allocating process reclaims (adds latency)         │
│  swap: anon pages → NVMe swap → zswap compression cache             │
│  OOM: last resort → oom_badness() score → kill victim               │
└─────────────────────────┬───────────────────────────────────────────┘
                          │ advanced features
┌─────────────────────────▼───────────────────────────────────────────┐
│                    Advanced Layer                                   │
│  THP: 2MB anon pages via khugepaged (disable for databases)         │
│  HugeTLB: pre-allocated 2MB/1GB (SPDK, DPDK, Oracle SGA)          │
│  NUMA: mempolicy → NVMe affinity → align CPUs, memory, device      │
│  memory cgroups: memory.max limits page cache → container thrash    │
│  mlock: pin against reclaim; FOLL_PIN: pin against migration too    │
│  DAX/PMEM: bypass page cache → CPU LOAD/STORE to persistent mem     │
│  userfaultfd: user-space fault handler (QEMU migration, CRIU)       │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 6. 30-Day Mastery Self-Assessment

Score yourself honestly. Each question = 1 point. 25+/30 = ready for production MM debugging.

**Physical Memory (Days 1–7):**
- [ ] Name the struct for each level of the physical memory hierarchy
- [ ] Explain buddy allocator splitting/coalescing with a concrete example
- [ ] Explain GFP_NOIO deadlock prevention
- [ ] Interpret slabtop output and identify memory pressure sources

**Virtual Memory (Days 8–14):**
- [ ] Trace mmap(file) from syscall to first byte read (every step)
- [ ] Explain COW with fork scenario
- [ ] Explain TLB shootdown cost on NUMA systems
- [ ] Prove that read() and mmap() share the page cache

**Page Cache & Reclaim (Days 15–21):**
- [ ] Explain dirty_ratio vs dirty_background_ratio
- [ ] Trace a dirty page from write() to disk to reclaim
- [ ] Explain why memory pressure causes I/O spikes (exact mechanism)
- [ ] Read /proc/pressure/memory and explain some vs full

**Advanced Features (Days 22–28):**
- [ ] Explain why databases disable THP
- [ ] Explain why SPDK requires HugeTLB (not THP)
- [ ] Diagnose NUMA miss rate and fix with numactl
- [ ] Explain container memory limit → page cache thrash mechanism
- [ ] Explain FOLL_PIN vs mlock distinction for io_uring

**Integration:**
- [ ] Given "p99 latency spike every 30s": run 5-command diagnosis
- [ ] Given "container I/O slow": identify memory.max as root cause
- [ ] Given "NUMA miss rate 40%": trace to fix in 3 steps
- [ ] Build production sysctl profile for a given storage workload

---

## 7. What Comes Next

You've now completed:
- **Month 1:** Linux kernel storage stack (VFS → NVMe)
- **Month 2:** Distributed storage internals (Raft, erasure coding, Ceph)
- **Month 3:** Storage design patterns (engines, reliability, cost modeling)
- **Month 4:** Linux memory management (physical → virtual → reclaim → advanced)

**Recommended next directions based on your architect role:**

**Path A: Kernel Contribution**
- Study a specific MM subsystem deeply: contribute a cleanup or small feature to `mm/vmscan.c` or `mm/compaction.c`
- Follow mm@ mailing list: https://lore.kernel.org/linux-mm/

**Path B: Storage + MM Integration Deep Dives**
- io_uring internals: how zero-copy works end-to-end (FOLL_PIN + NVMe SQ)
- CXL (Compute Express Link): the future of memory-storage convergence
- PMDK: Persistent Memory Development Kit for DAX-aware applications

**Path C: Production Systems Mastery**
- Linux Performance (Brendan Gregg's book): mm/ chapter in full
- Write a real memory diagnostic runbook for your team
- Instrument your production systems with PSI alerting

**Landmark papers worth reading:**
- "Reconsidering the OS design for persistent memory" (OSDI 2018)
- "The Storage Hierarchy is Not a Hierarchy" (HotStorage 2021)
- "FlexSC: Flexible System Call Scheduling" (OSDI 2010) — page fault context

---

## 8. Final Self-Check

Without notes, answer these:

1. A new engineer says "server has 256GB RAM but only 200GB is MemAvailable — where is the other 56GB?" Give a complete answer covering all possible consumers.

2. Production alert: "NVMe write latency p99 = 500ms, p50 = 100μs". What is the most likely root cause? What is your first command?

3. A containerized Ceph OSD is OOM-killed. The host shows 20GB free. The container has `memory.max=16G` and `memory.low=12G`. The OSD was using 14GB. Explain exactly what happened and what to fix.

4. SPDK fails to initialize with "cannot allocate hugepages". The server has 512GB RAM and 2GB free. Explain why and how to fix it without rebooting.

5. Draw the complete path of a 4KB `write()` from user buffer to NVMe SSD persistence, naming every kernel subsystem, data structure, and lock that is touched. Include the memory management layer.
