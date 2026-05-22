# Day 6: Memory Debugging & Profiling Tools

## Learning Objectives
- Build a systematic memory diagnostic workflow for production systems
- Master `/proc/meminfo` — know what every field means
- Use BCC/BPF tools for live memory tracing
- Understand kmemleak and KASAN (know when to enable them)
- Build a 60-second memory triage runbook

---

## 1. /proc/meminfo — The Complete Reference

```bash
cat /proc/meminfo
```

Every field, explained for a storage architect:

```
MemTotal:       131072000 kB   # total RAM (physical)
MemFree:          2048000 kB   # completely unused pages (buddy free lists)
MemAvailable:    45000000 kB   # ESTIMATED available without swapping
                               # = MemFree + reclaimable cache - reserved
                               # This is what 'free -h' shows as "available"

Buffers:          1024000 kB   # page cache for block device metadata
                               # (raw block reads, not file data)
Cached:          60000000 kB   # page cache for file data
                               # Does NOT include SwapCached
SwapCached:        512000 kB   # pages that are in both swap and RAM
                               # (swapped out but re-read; can discard without I/O)

Active:          55000000 kB   # recently used pages (LRU active list)
Inactive:        20000000 kB   # less recently used (LRU inactive list, reclaim candidates)
Active(anon):    30000000 kB   # active anonymous pages (heap, stack)
Inactive(anon):   5000000 kB   # inactive anonymous (swap candidates)
Active(file):    25000000 kB   # active file-backed pages (page cache)
Inactive(file):  15000000 kB   # inactive file-backed (eviction candidates)
Unevictable:      1000000 kB   # mlock'd pages, ramfs, etc — cannot be reclaimed

Mlocked:          1000000 kB   # pages locked with mlock() (subset of Unevictable)

SwapTotal:       16000000 kB   # swap space size
SwapFree:        15000000 kB   # free swap space
Zswap:            500000 kB    # compressed swap cache in RAM
Zswapped:        1000000 kB    # total data in zswap (uncompressed size)

Dirty:            2000000 kB   # pages written but not yet flushed to disk
                               # WATCH THIS: if approaching dirty_ratio × MemTotal,
                               # writer processes will stall
Writeback:         100000 kB   # pages currently being written to disk

AnonPages:       35000000 kB   # anonymous pages mapped into userspace
Mapped:          10000000 kB   # files mapped with mmap() (subset of Cached)
Shmem:            2000000 kB   # tmpfs + shared memory

KReclaimable:    15000000 kB   # kernel memory that CAN be reclaimed under pressure
Slab:            20000000 kB   # total slab usage
SReclaimable:    15000000 kB   # reclaimable slab (inode/dentry caches)
SUnreclaim:       5000000 kB   # unreclaimable slab (driver buffers, kmalloc in drivers)

KernelStack:       200000 kB   # kernel stacks (8KB per thread typically)
PageTables:        500000 kB   # page table pages (grows with many mmap'd processes)
SecPageTables:          0 kB   # secondary page tables (arm64 stage-2)

NFS_Unstable:           0 kB   # NFS pages not yet committed to server (legacy)
Bounce:                 0 kB   # bounce buffers for low-mem DMA
WritebackTmp:           0 kB   # FUSE writeback

CommitLimit:    100000000 kB   # max allocatable with overcommit_ratio
Committed_AS:    80000000 kB   # total committed virtual memory
                               # If > CommitLimit, OOM risk under overcommit=2

VmallocTotal:  1000000000 kB   # total VA space for vmalloc (huge on 64-bit)
VmallocUsed:     2000000 kB    # currently used vmalloc
VmallocChunk:           0 kB   # largest contiguous free vmalloc chunk (deprecated)

Percpu:            50000 kB    # per-CPU memory allocations

HardwareCorrupted:      0 kB   # pages marked bad by hardware (ECC errors)
AnonHugePages:   4000000 kB   # anonymous pages backed by THP (2MB pages)
ShmemHugePages:        0 kB   # tmpfs pages using THP
ShmemPmdMapped:        0 kB   # tmpfs THP pages mapped into userspace

FileHugePages:         0 kB   # huge pages in page cache (rare)
FilePmdMapped:         0 kB   # page cache THP pages mapped

HugePages_Total:     512       # pre-allocated HugeTLB pages (2MB each)
HugePages_Free:      400       # available HugeTLB pages
HugePages_Rsvd:       10       # reserved but not yet allocated
HugePages_Surp:        0       # surplus pages (beyond nr_hugepages)
Hugepagesize:       2048 kB    # size of each HugeTLB page
Hugetlb:         1048576 kB    # total memory in HugeTLB

DirectMap4k:      500000 kB    # kernel direct map using 4KB pages
DirectMap2M:     60000000 kB   # kernel direct map using 2MB pages  ← most RAM
DirectMap1G:     70000000 kB   # kernel direct map using 1GB pages
```

### Quick Diagnostic Formulas

```bash
# Effective free memory (not MemFree — that's too conservative):
# Use MemAvailable

# Page cache size (what can be evicted):
# Cached + Buffers + SReclaimable - Mapped

# Real memory pressure indicator:
# (MemTotal - MemAvailable) / MemTotal

# Writeback pressure:
# Dirty / MemTotal vs vm.dirty_ratio

# Slab leak suspect:
# SUnreclaim growing over time = kernel memory not being freed
```

---

## 2. BCC/BPF Memory Tools

```bash
# --- cachestat: page cache hit/miss rate ---
/usr/share/bcc/tools/cachestat 1
# HITS   MISSES  DIRTIES HITRATIO
# 1024      50      200   95.35%
# Hits = served from page cache (no disk I/O)
# Misses = had to read from disk

# --- cachetop: per-process cache hit rate ---
/usr/share/bcc/tools/cachetop
# Like top but for page cache operations per process

# --- memleak: detect kernel memory leaks ---
/usr/share/bcc/tools/memleak -p $(pidof your_process) -a
# For kernel leaks (requires root + debug symbols):
/usr/share/bcc/tools/memleak -a --kernel-trace

# --- slabratetop: slab allocation rate ---
/usr/share/bcc/tools/slabratetop
# Shows which slab caches are being allocated to/from fastest

# --- drsnoop: direct reclaim events ---
/usr/share/bcc/tools/drsnoop
# Shows processes experiencing direct reclaim (latency source)

# --- oomkill: OOM kill events ---
/usr/share/bcc/tools/oomkill

# --- BPFtrace: custom memory tracing ---

# Track allocation sizes:
bpftrace -e '
kprobe:__kmalloc { @sizes = hist(arg0); }
interval:s:10 { print(@sizes); exit(); }
'

# Who is dirtying pages:
bpftrace -e '
kprobe:set_page_dirty { @[comm, kstack(5)] = count(); }
interval:s:5 { print(@); exit(); }
'

# Track page cache evictions:
bpftrace -e '
kprobe:__remove_mapping { @evictions[comm] = count(); }
interval:s:1 { print(@evictions); clear(@evictions); }
'
```

---

## 3. Per-Process Memory Analysis

```bash
# --- smem: proportional set size (PSS) ---
# PSS = RSS / number_of_processes_sharing_each_page
# More accurate than RSS for shared-memory processes
smem -r -s pss | head -20
smem -r -s rss | head -20

# --- /proc/PID/smaps: detailed VMA breakdown ---
cat /proc/$(pidof fio)/smaps | head -60
# For each VMA:
# Size:       virtual size
# RSS:        resident (in RAM) pages
# PSS:        proportional share
# Shared_Clean / Shared_Dirty
# Private_Clean / Private_Dirty
# Referenced / Anonymous / Swap

# Summary rolled up:
cat /proc/$(pidof fio)/smaps_rollup

# --- /proc/PID/status: quick overview ---
cat /proc/$(pidof fio)/status | grep -E 'VmRSS|VmSwap|VmPeak|VmLck|RssAnon|RssFile'

# --- pmap: virtual memory map ---
pmap -x $(pidof fio)
```

---

## 4. The 60-Second Memory Triage Runbook

When "server is slow" — run these in order:

```bash
#!/bin/bash
# Memory triage: 60 seconds

echo "=== Step 1: Big picture (5 sec) ==="
free -h
cat /proc/meminfo | grep -E 'MemAvailable|Dirty|Writeback|Slab|SwapUsed'

echo "=== Step 2: Memory pressure stall (5 sec) ==="
cat /proc/pressure/memory
cat /proc/pressure/io
# 'some' and 'full' > 5% over 10s = significant pressure

echo "=== Step 3: Who's using RAM (10 sec) ==="
smem -r -s rss -k | head -15

echo "=== Step 4: Slab breakdown (5 sec) ==="
slabtop -o | head -20

echo "=== Step 5: Reclaim activity (15 sec) ==="
vmstat 1 15
# Watch: si (swap in), so (swap out), bi (block in), bo (block out)
# si/so > 0 = swap activity = memory very tight
# bi spike without corresponding workload = page cache refill after eviction

echo "=== Step 6: Dirty/writeback (5 sec) ==="
while true; do
    grep -E 'Dirty|Writeback' /proc/meminfo
    sleep 1
done &
BGPID=$!
sleep 10
kill $BGPID

echo "=== Step 7: OOM score top suspects ==="
for pid in $(ls /proc | grep -E '^[0-9]+$' | head -100); do
    score=$(cat /proc/$pid/oom_score 2>/dev/null)
    comm=$(cat /proc/$pid/comm 2>/dev/null)
    [ -n "$score" ] && echo "$score $comm $pid"
done | sort -rn | head -10
```

---

## 5. Kernel Debug Tools (Require Special Kernel Config)

### kmemleak (CONFIG_DEBUG_KMEMLEAK=y)
Detects kernel memory leaks by tracking all allocations and marking orphaned ones.

```bash
# Scan for leaks:
echo scan > /sys/kernel/debug/kmemleak
sleep 60  # wait for scan
cat /sys/kernel/debug/kmemleak
# Reports: leaked object address, size, allocation stack trace

# Clear previous reports:
echo clear > /sys/kernel/debug/kmemleak
```

### KASAN (CONFIG_KASAN=y)
Kernel Address Sanitizer — detects use-after-free, out-of-bounds, buffer overflows. Massive memory overhead (~1.5× RAM for shadow mapping). Development/test kernels only.

### slub_debug (boot parameter: slub_debug=FZPU)
- `F` — sanity checks on each alloc/free
- `Z` — red zoning (detect over/under-run)
- `P` — poisoning (detect use-after-free)
- `U` — track allocation/free owner (user trace)

```bash
# Enable for specific cache:
echo 1 > /sys/kernel/slab/bio-0/sanity_checks
echo 1 > /sys/kernel/slab/bio-0/poison

# Or at boot: slub_debug=FZP,bio-0
```

---

## 6. Key Source Files

```
mm/page_alloc.c         — si_meminfo(): fills /proc/meminfo
mm/vmstat.c             — vm_stat tracking, /proc/vmstat
mm/slab_common.c        — /proc/slabinfo generation
mm/oom_kill.c           — /proc/$pid/oom_score calculation
kernel/fork.c           — /proc/$pid/status VmRSS etc.
```

---

## 7. Self-Check Questions

1. `/proc/meminfo` shows `MemFree: 500MB` but `MemAvailable: 40GB`. Explain the difference. Which one should you alert on?

2. `Dirty` is 18GB on a system with `vm.dirty_ratio=20` and `MemTotal=100GB`. What is about to happen? What will you observe in `iostat` and process latency?

3. `SUnreclaim` grows by 2GB over 6 hours and never decreases. What does this indicate? How would you identify which driver or subsystem is leaking?

4. `cachestat` shows 20% hit ratio during a sequential database scan. Is this expected? Is it a problem? What `madvise()` flag would fix it?

5. A process shows `VmRSS=4GB` but `smaps_rollup` shows `PSS=200MB`. How is this possible? What does it mean for memory accounting?

---

## Tomorrow: Day 7 — Week 1 Review & Physical Memory Connective Tissue
Synthesize the week: trace a `kmalloc(GFP_NOIO)` from entry through zone selection, buddy allocation, slub, and back. Build your physical memory reference card.
