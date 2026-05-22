# Day 22: Transparent Huge Pages (THP)

## Learning Objectives
- Understand THP: 2MB anonymous pages managed transparently
- Understand khugepaged: the daemon that collapses base pages
- Know why databases disable THP and what latency pattern it causes
- Measure THP impact on storage benchmark results

---

## 1. What THP Does

THP automatically promotes groups of 512 contiguous 4KB pages into a single 2MB PMD-level page. From the application's perspective, nothing changes — it still allocates memory normally. The kernel handles the promotion transparently.

**Benefits:**
- 512× fewer TLB entries needed for same address range
- Fewer page faults (2MB at once instead of 4KB)
- Reduced page table overhead

**Costs:**
- Collapse requires 512 contiguous free pages (hard to get on fragmented systems)
- Split on partial access adds latency spike (splitting 2MB → 512 × 4KB)
- Compaction pressure to create contiguous regions

---

## 2. THP Configuration

```bash
# Global THP mode:
cat /sys/kernel/mm/transparent_hugepage/enabled
# [always] madvise never
# always   = THP for all anonymous VMAs (aggressive)
# madvise  = THP only for VMAs with MADV_HUGEPAGE hint (opt-in)
# never    = THP disabled system-wide

# Defragmentation mode (when to run compaction for THP):
cat /sys/kernel/mm/transparent_hugepage/defrag
# always defer defer+madvise [madvise] never

# Minimum scan interval for khugepaged (milliseconds):
cat /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs

# Max pages khugepaged scans per pass:
cat /sys/kernel/mm/transparent_hugepage/khugepaged/pages_to_scan
```

---

## 3. khugepaged: The Collapse Daemon

```c
// mm/huge_memory.c
static int khugepaged(void *none)
{
    for (;;) {
        // Sleep between scans:
        wait_event_interruptible_timeout(khugepaged_wait, ...);

        // Scan for collapsible regions:
        khugepaged_scan_mm_slot()
            → khugepaged_scan_pmd()
                // Check 512 consecutive PTEs:
                // - All present?
                // - All same permissions?
                // - No special flags (VM_IO, VM_PFNMAP)?
                // - Memory available for 2MB allocation?
                → collapse_huge_page()
                    → alloc_pages(GFP_TRANSHUGE, HPAGE_PMD_ORDER)  // order-9 = 2MB
                    → copy all 512 pages into new huge page
                    → replace 512 PTEs with single huge PMD
                    → free 512 old pages
    }
}
```

**The latency spike:** `collapse_huge_page()` must acquire the mmap semaphore and process cannot run during the copy. On a busy 2MB region with 512 active pages, this copy takes hundreds of microseconds.

---

## 4. THP and Databases: The Incompatibility

```bash
# Why PostgreSQL, MySQL, MongoDB disable THP:

# 1. Latency spikes from collapse/split:
#    - khugepaged collapses randomly while queries run
#    - split on partial page fault adds variable latency
#    - both are invisible to the application but visible in p99

# 2. Memory inflation:
#    - 1-byte allocation from a 4KB page wastes 4KB
#    - 1-byte allocation from a 2MB page wastes 2MB
#    - Database has many small allocations → huge overhead

# 3. False sharing:
#    - 2MB huge page shared between processes requires full TLB shootdown
#      for any change to any part of the page

# Disable THP for a specific process (madvise approach):
# In database code:
madvise(heap_start, heap_size, MADV_NOHUGEPAGE);

# Or system-wide for databases:
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled

# Check if database has disabled THP:
grep AnonHugePages /proc/$(pidof mysqld)/smaps | awk '{s+=$2}END{print s}'
# Should be 0 if disabled
```

---

## 5. Hands-On Exercises

```bash
# --- THP stats ---
grep -E 'AnonHugePages|ShmemHugePages' /proc/meminfo

# Per-process THP usage:
cat /proc/$(pidof fio)/smaps | grep AnonHugePages | awk '{s+=$2}END{print s, "kB"}'

# khugepaged activity:
cat /proc/vmstat | grep thp_
# thp_fault_alloc            — huge page faults satisfied
# thp_collapse_alloc         — khugepaged collapse successes
# thp_collapse_alloc_failed  — collapse failures (no contiguous 2MB)
# thp_split_page             — huge page splits (bad — latency event)
# thp_deferred_split_page    — deferred splits pending

# --- Measure THP latency impact ---
# Baseline: THP always (default)
echo always > /sys/kernel/mm/transparent_hugepage/enabled
fio --name=thp_on --rw=randrw --bs=4k --size=4G \
    --filename=/tmp/thp_test --direct=0 \
    --numjobs=4 --runtime=30 --percentile_list=50,90,99,99.9 \
    --output-format=json | python3 -c "
import json,sys; d=json.load(sys.stdin)
j=d['jobs'][0]
print('THP=always  lat p99:', j['lat_ns']['percentile']['99.000000']/1000, 'us')
"

# THP disabled:
echo never > /sys/kernel/mm/transparent_hugepage/enabled
fio --name=thp_off --rw=randrw --bs=4k --size=4G \
    --filename=/tmp/thp_test --direct=0 \
    --numjobs=4 --runtime=30 --percentile_list=50,90,99,99.9 \
    --output-format=json | python3 -c "
import json,sys; d=json.load(sys.stdin)
j=d['jobs'][0]
print('THP=never   lat p99:', j['lat_ns']['percentile']['99.000000']/1000, 'us')
"

# Restore:
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled

# --- Trace khugepaged collapses ---
bpftrace -e '
kprobe:collapse_huge_page { @start[tid] = nsecs; }
kretprobe:collapse_huge_page {
    if (@start[tid]) {
        @collapse_lat_ms = hist((nsecs - @start[tid]) / 1000000);
        delete(@start[tid]);
    }
}
interval:s:30 { print(@collapse_lat_ms); exit(); }
'
```

---

## 6. THP for Storage-Adjacent Workloads

```bash
# GOOD use of THP: large sequential buffers
# (e.g., streaming reads, video processing, ML training data)
python3 -c "
import mmap, os
# Opt-in to THP for specific buffer:
buf = mmap.mmap(-1, 1024*1024*1024)  # 1GB anonymous
import ctypes
libc = ctypes.CDLL('libc.so.6')
MADV_HUGEPAGE = 14
libc.madvise(ctypes.c_void_p(id(buf)), len(buf), MADV_HUGEPAGE)
# Now khugepaged will collapse this region → fewer TLB entries
"

# BAD use of THP: random access storage cache
# (e.g., database page cache, key-value store hash table)
# → use MADV_NOHUGEPAGE for these regions
```

---

## 7. Key Source Files

```
mm/huge_memory.c        — do_huge_pmd_anonymous_page(), collapse_huge_page(), khugepaged()
mm/khugepaged.c         — khugepaged scan and collapse logic
include/linux/huge_mm.h — THP helper macros
arch/x86/include/asm/pgtable.h — PMD huge page bit definitions
```

---

## 8. Self-Check Questions

1. khugepaged tries to collapse a 2MB region. 510 pages are present but 2 are swapped out. Does collapse succeed? What must happen first?

2. A process does `madvise(addr, 2MB, MADV_HUGEPAGE)`. khugepaged collapses it. The process then does `mprotect(addr+4096, 4096, PROT_NONE)`. What happens to the 2MB huge page?

3. A database shows `thp_split_page` incrementing at 100/sec in `/proc/vmstat`. Explain what is happening and why this causes p99 latency spikes.

4. THP is set to `madvise`. A process calls `mmap(MAP_ANONYMOUS)` without `madvise(MADV_HUGEPAGE)`. Does khugepaged collapse this region?

5. Storage benchmark runs on a host with THP=always. The benchmark uses many 4KB random I/Os. Does THP help or hurt? Explain the TLB and khugepaged effects.

---

## Tomorrow: Day 23 — HugeTLB Pages: Static Huge Page Allocation
