# Day 29: MM Performance Tuning Reference Card

## Learning Objectives
- Build a complete, justified sysctl reference for production MM tuning
- Know the interaction between MM tunables and storage performance
- Understand when each knob matters and what the cost of getting it wrong is
- Have a ready-to-apply baseline for storage-focused servers

---

## 1. The Complete Production sysctl Reference

### Reclaim & Swappiness

```bash
# vm.swappiness (default: 60, range: 0-200)
# Controls preference for swapping anon pages vs evicting file cache.
# Lower = prefer evicting file cache; higher = prefer swapping.
vm.swappiness = 10
# RATIONALE: Storage servers should prefer evicting file cache (recoverable
# with another read) over swapping application data (adds latency spike).
# Exception: if you have fast NVMe swap and small working set, 30-60 is fine.
# WRONG VALUE COST: swappiness=60 on database → swap storms, multi-second stalls.

# vm.vfs_cache_pressure (default: 100, range: 0-1000+)
# Controls aggressiveness of reclaiming dentry/inode cache.
# 100 = balanced; <100 = keep dentries/inodes longer; >100 = reclaim faster.
vm.vfs_cache_pressure = 50
# RATIONALE: Storage servers with millions of small files (object storage, backup)
# benefit from keeping the dentry cache warm. Reduces stat()/open() latency.
# Exception: if slabtop shows dentry/inode consuming >20% RAM, increase to 200.
# WRONG VALUE COST: pressure=200 → constant dentry cache misses on metadata-heavy workloads.

# vm.min_free_kbytes (default: calculated ~0.4% RAM, min 128KB, max 64MB)
# Sets WMARK_MIN (emergency reserve). kswapd targets WMARK_HIGH above this.
# Formula: WMARK_HIGH ≈ min_free + (min_free × 2)
vm.min_free_kbytes = 1048576    # 1GB for a 256GB server
# RATIONALE: Too low → OOM before kswapd reacts to pressure (sudden death).
# Too high → wastes RAM as unusable reserve.
# Rule of thumb: ~0.4% of RAM, minimum 512MB for servers > 64GB RAM.
# WRONG VALUE COST: too low (64MB on 512GB server) → allocation failures
# during brief pressure spike before kswapd wakes.
```

### Writeback Thresholds

```bash
# vm.dirty_ratio (default: 20, %)
# Hard limit: writers STALL when dirty pages exceed this % of available memory.
vm.dirty_ratio = 5
# RATIONALE: Low dirty_ratio prevents large writeback bursts (storms).
# At 20% of 256GB = 51GB of dirty data — when writeback starts, I/O spike
# is enormous. 5% = ~12GB max dirty, more manageable bursts.
# EXCEPTION: batch/analytics workloads where latency doesn't matter: use 40%.
# WRONG VALUE COST: dirty_ratio=20 + fast writers → 20GB dirty suddenly
# flushed → p99 latency spike → missed SLOs.

# vm.dirty_background_ratio (default: 10, %)
# Soft limit: background writeback STARTS at this % of available memory.
vm.dirty_background_ratio = 2
# RATIONALE: Start background writeback early to avoid ever hitting dirty_ratio.
# Set to dirty_ratio/2.5 as a starting point.
# WRONG VALUE COST: background_ratio=10 with dirty_ratio=5 → impossible
# (background never starts before hard limit). Always set background < ratio.

# vm.dirty_expire_centisecs (default: 3000 = 30 seconds)
# Force writeback of pages older than this age.
vm.dirty_expire_centisecs = 1500    # 15 seconds
# RATIONALE: Prevents data loss window from being too large.
# Also ensures steady background writeback rather than bursty behavior.
# WRONG VALUE COST: too high (6000) → page accumulates dirt for 60s before
# forced writeback; all 60s of writes flush at once → burst.

# vm.dirty_writeback_centisecs (default: 500 = 5 seconds)
# How often the writeback thread wakes to check for work.
vm.dirty_writeback_centisecs = 200    # 2 seconds
# RATIONALE: More frequent wakeups = smoother writeback = fewer bursts.
# Cost: slightly more wakeups (negligible CPU).
# WRONG VALUE COST: too high (2000) → writeback thread barely runs → dirty
# pages accumulate → burst when it finally runs.
```

### Memory Reserve & Overcommit

```bash
# vm.overcommit_memory (default: 0)
# 0 = heuristic (allow reasonable overcommit)
# 1 = always allow (OOM kills when pages needed)
# 2 = never (CommitLimit = overcommit_ratio% × RAM + swap)
vm.overcommit_memory = 0
# RATIONALE: Mode 0 is correct for most storage servers.
# Mode 2 for databases that need predictable malloc behavior (Oracle, PostgreSQL).
# WRONG VALUE COST: mode=1 on a storage server → silent overcommit until
# sudden OOM kills storage daemons.

# vm.overcommit_ratio (default: 50, used only when overcommit_memory=2)
vm.overcommit_ratio = 80
# RATIONALE: With mode=2, this limits CommitLimit. 80 = can commit 80% RAM + swap.
# Tune based on your observed peak committed memory (Committed_AS in /proc/meminfo).

# vm.oom_kill_allocating_task (default: 0)
# 0 = kill highest-scoring process (may not be the one that triggered OOM)
# 1 = kill the task that triggered OOM
vm.oom_kill_allocating_task = 0
# RATIONALE: Default (0) kills the process that will free the most memory.
# Mode 1 may kill an innocent small process that just happened to allocate last.
```

### Huge Pages

```bash
# Transparent Huge Pages: always/madvise/never
# Set in: /sys/kernel/mm/transparent_hugepage/enabled
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
# RATIONALE: 'madvise' = only use THP when explicitly requested via
# madvise(MADV_HUGEPAGE). Avoids khugepaged latency spikes for databases.
# Applications that benefit (ML training, sequential scans) opt in explicitly.
# WRONG VALUE: 'always' → khugepaged collapses database pages →
# random 200μs spikes → p99 degradation.

# THP defrag:
echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag
# RATIONALE: 'defer+madvise' = for madvise regions, defer compaction to kcompactd
# (don't stall the faulting process for compaction). Avoids fault latency.

# Static HugeTLB pages (for SPDK, DPDK, Oracle):
# Calculate: (SPDK_mem_GB + DPDK_mem_GB + Oracle_SGA_GB) × 1024 / 2 pages
vm.nr_hugepages = 4096    # 4096 × 2MB = 8GB for SPDK + database
# RATIONALE: Pre-allocated at boot before fragmentation. Never fail.
# Set in /etc/sysctl.conf AND via kernel cmdline: hugepages=4096
# WRONG VALUE: too low → SPDK fails to initialize; too high → wastes RAM.
```

### NUMA

```bash
# kernel.numa_balancing (default: 1 = enabled)
kernel.numa_balancing = 0
# RATIONALE: For storage workloads with processes pinned to NUMA nodes via
# numactl or taskset: NUMA balancing adds latency (PROT_NONE faults) without
# benefit (pages are already on the right node).
# Enable if: running general-purpose workloads where NUMA placement isn't
# manually controlled.
# WRONG VALUE: enabled on pinned storage processes → random 10μs fault spikes
# during NUMA scanning → visible in p99 latency histograms.
```

### Page Table & Mapping

```bash
# vm.max_map_count (default: 65536)
# Maximum number of VMAs (memory map areas) per process.
vm.max_map_count = 262144
# RATIONALE: Java, Elasticsearch, and some storage engines exceed 65536 VMAs.
# Elasticsearch recommends 262144.
# WRONG VALUE: too low → mmap() returns -ENOMEM → application crash.

# vm.page-cluster (default: 3 = read-ahead 2^3=8 swap pages)
# Number of swap pages read at once during swap-in.
vm.page-cluster = 0
# RATIONALE: For random-access workloads (databases), pre-reading 8 swap pages
# wastes I/O bandwidth. Set to 0 for single-page swap-in.
# For sequential swap-heavy workloads: keep default (3).
```

---

## 2. Storage-Role-Specific Profiles

### Profile A: NVMe Database Server (PostgreSQL, MySQL)

```bash
# /etc/sysctl.d/99-nvme-database.conf
vm.swappiness = 10
vm.dirty_ratio = 5
vm.dirty_background_ratio = 2
vm.dirty_expire_centisecs = 1000
vm.dirty_writeback_centisecs = 200
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = 1048576
kernel.numa_balancing = 0
vm.overcommit_memory = 2
vm.overcommit_ratio = 80
vm.max_map_count = 262144
vm.page-cluster = 0
# THP: disabled in database startup scripts (madvise system-wide):
# echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
```

### Profile B: SPDK/DPDK Storage Server

```bash
# /etc/sysctl.d/99-spdk.conf
vm.swappiness = 0              # SPDK pins its memory; no swap needed
vm.nr_hugepages = 8192         # 16GB for SPDK queues and DMA
vm.hugetlb_shm_group = 0      # allow SPDK to use hugepages via shmget
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
vm.min_free_kbytes = 2097152   # 2GB reserve on large servers
kernel.numa_balancing = 0
# Also in hugepages: set per-node for NUMA-optimal DMA:
# /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages = 4096
# /sys/devices/system/node/node1/hugepages/hugepages-2048kB/nr_hugepages = 4096
```

### Profile C: Ceph OSD Server

```bash
# /etc/sysctl.d/99-ceph.conf
vm.swappiness = 10
vm.dirty_ratio = 10            # OSD manages its own writeback; allow page cache buffer
vm.dirty_background_ratio = 4
vm.dirty_expire_centisecs = 3000
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = 524288    # 512MB
vm.max_map_count = 262144
kernel.numa_balancing = 0      # if OSDs are NUMA-pinned
# OOM protection (via systemd unit):
# OOMScoreAdjust = -900
```

### Profile D: Object Storage / Lots of Small Files

```bash
# /etc/sysctl.d/99-object-storage.conf
vm.swappiness = 10
vm.vfs_cache_pressure = 30     # keep dentry/inode cache very warm
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.min_free_kbytes = 262144    # 256MB
vm.max_map_count = 524288      # many file descriptors = many VMAs
```

---

## 3. Validation: Before/After Measurement

Always measure before and after tuning:

```bash
#!/bin/bash
# Capture MM baseline before changes:

echo "=== Baseline $(date) ===" > /tmp/mm_baseline.txt
sysctl vm.swappiness vm.dirty_ratio vm.dirty_background_ratio \
       vm.vfs_cache_pressure vm.min_free_kbytes >> /tmp/mm_baseline.txt

cat /proc/meminfo >> /tmp/mm_baseline.txt
cat /proc/vmstat | grep -E 'pgsteal|pgscan|pgfault|pgmajfault|compact' \
    >> /tmp/mm_baseline.txt

# Run workload, then capture post:
fio --name=baseline ... (your benchmark)

echo "=== Post-workload $(date) ===" >> /tmp/mm_baseline.txt
cat /proc/vmstat | grep -E 'pgsteal|pgscan|pgfault|pgmajfault|compact' \
    >> /tmp/mm_baseline.txt
cat /proc/pressure/memory >> /tmp/mm_baseline.txt
cat /proc/pressure/io >> /tmp/mm_baseline.txt

# Apply tuning, re-run benchmark, compare:
diff <(grep pgmajfault /tmp/mm_baseline_before.txt) \
     <(grep pgmajfault /tmp/mm_baseline_after.txt)
# Fewer pgmajfault = better cache behavior
```

---

## 4. The 10 Most Common MM Tuning Mistakes

| Mistake | Symptom | Fix |
|---------|---------|-----|
| `dirty_ratio=20` on NVMe server | Periodic 2-5s write latency spikes | `dirty_ratio=5`, `dirty_background_ratio=2` |
| `swappiness=60` on database | Swap activity despite free RAM | `swappiness=10` |
| `min_free_kbytes` too low | Sudden OOM with RAM "available" | Set to 1% of RAM |
| THP=always on database | Random μs spikes in query latency | `echo madvise > .../enabled` |
| NUMA balancing on pinned processes | Intermittent 10μs fault spikes | `kernel.numa_balancing=0` |
| No `oom_score_adj` on storage daemons | Storage daemon OOM-killed | `OOMScoreAdjust=-900` in systemd |
| `nr_hugepages=0` for SPDK | SPDK initialization failure | Set before SPDK starts |
| `max_map_count=65536` for Elasticsearch | mmap() ENOMEM | `vm.max_map_count=262144` |
| `dirty_background_ratio > dirty_ratio` | Background writeback never starts | Always set background < ratio |
| `vfs_cache_pressure=100` on metadata-heavy | Constant open/stat cache misses | Set to 30-50 |

---

## 5. Hands-On: Apply and Validate a Profile

```bash
# Apply database profile:
cat > /etc/sysctl.d/99-storage-db.conf << 'EOF'
vm.swappiness = 10
vm.dirty_ratio = 5
vm.dirty_background_ratio = 2
vm.dirty_expire_centisecs = 1000
vm.dirty_writeback_centisecs = 200
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = 524288
kernel.numa_balancing = 0
vm.max_map_count = 262144
EOF

sysctl -p /etc/sysctl.d/99-storage-db.conf

# Validate applied:
sysctl vm.swappiness vm.dirty_ratio vm.dirty_background_ratio \
       vm.min_free_kbytes

# Validate effect under load:
fio --name=validate --rw=randrw --bs=4k --size=10G \
    --filename=/tmp/validate_test --direct=0 --numjobs=4 \
    --runtime=60 --group_reporting \
    --percentile_list=50,90,99,99.9 &

# Watch dirty behavior:
watch -n1 'grep -E "Dirty|Writeback" /proc/meminfo'

# Check PSI during test:
watch -n2 'cat /proc/pressure/memory && cat /proc/pressure/io'
```

---

## 6. Self-Check Questions

1. A server has 512GB RAM. Calculate the optimal `vm.min_free_kbytes` value. What happens if set to 64KB (default for small systems)? What happens if set to 10GB?

2. `vm.dirty_ratio=20` and `vm.dirty_background_ratio=25`. What is wrong? What observable behavior results?

3. A Ceph cluster shows constant OSD restarts. `dmesg` shows `Out of memory: Killed process ... ceph-osd`. What two changes do you make, and where?

4. THP is set to `always`. A MySQL server shows p99 latency degradation every 30-60 seconds. `cat /proc/vmstat | grep thp_collapse` is incrementing. What is causing the latency? What is the fix?

5. After applying `vm.swappiness=0`, the server still swaps occasionally. Is this a bug? Under what extreme condition does the kernel swap even with swappiness=0?

---

## Tomorrow: Day 30 — Capstone: Memory + Storage Integration
The final day. Four hands-on integration exercises that tie everything together: writeback storms, NUMA NVMe benchmarking, cgroup memory+IO interaction, and a complete diagnostic scenario.
