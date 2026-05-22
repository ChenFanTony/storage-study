# Day 11: Page Tables & TLB Management

## Learning Objectives
- Understand 4-level x86-64 page table walk: PGD → P4D → PUD → PMD → PTE
- Understand TLB: what it caches, when it's invalidated, cost of shootdown
- Understand how huge pages (2MB, 1GB) reduce TLB pressure
- Measure TLB miss impact on storage benchmark throughput
- Know page table memory overhead for large mmap-heavy workloads

---

## 1. The 4-Level Page Table Walk

On x86-64, a virtual address is decoded as:

```
63       48 47    39 38    30 29    21 20    12 11      0
┌──────────┬────────┬────────┬────────┬────────┬────────┐
│  sign ext│  PGD   │  P4D   │  PUD   │  PMD   │  PTE   │ Page offset
│ (unused) │ index  │ index  │ index  │ index  │ index  │
└──────────┴────────┴────────┴────────┴────────┴────────┘
              9 bits   9 bits   9 bits   9 bits   9 bits    12 bits

Each index selects one of 512 entries in that level's table (512 × 8B = 4KB per table).
```

### The Walk (hardware does this on TLB miss):
```
CR3 register → PGD base physical address
PGD[bits 47:39] → PUD physical address
PUD[bits 38:30] → PMD physical address (OR 1GB huge page if bit 7 set)
PMD[bits 29:21] → PTE physical address (OR 2MB huge page if bit 7 set)
PTE[bits 20:12] → physical page base address
physical_page + bits[11:0] → final physical byte
```

**Memory cost:** Each table is 4KB. A fully populated 4-level tree mapping 512GB needs:
- 1 PGD
- 512 PUDs
- 512×512 = 262,144 PMDs
- ... it grows fast. Check `cat /proc/meminfo | grep PageTables`.

### Kernel Structs for Page Table Entries

```c
// arch/x86/include/asm/pgtable_types.h
typedef struct { pgdval_t pgd; } pgd_t;
typedef struct { p4dval_t p4d; } p4d_t;
typedef struct { pudval_t pud; } pud_t;
typedef struct { pmdval_t pmd; } pmd_t;
typedef struct { pteval_t pte; } pte_t;

// PTE bit layout (x86-64):
#define _PAGE_PRESENT    (1UL << 0)   // page is in memory
#define _PAGE_RW         (1UL << 1)   // writable
#define _PAGE_USER       (1UL << 2)   // user accessible
#define _PAGE_PWT        (1UL << 3)   // write-through cache
#define _PAGE_PCD        (1UL << 4)   // cache disable (MMIO)
#define _PAGE_ACCESSED   (1UL << 5)   // set by hardware on access
#define _PAGE_DIRTY      (1UL << 6)   // set by hardware on write
#define _PAGE_PSE        (1UL << 7)   // huge page at PMD/PUD level
#define _PAGE_GLOBAL     (1UL << 8)   // TLB entry survives CR3 switch (kernel)
#define _PAGE_NX         (1UL << 63)  // no-execute (NX bit)
// Bits 51:12 = physical page frame number
```

---

## 2. The TLB: Translation Lookaside Buffer

The page table walk above takes 4 memory accesses (PGD, PUD, PMD, PTE). At 100ns per access, that's 400ns overhead on every instruction that accesses a new virtual page. This is unacceptable.

**TLB:** Hardware cache of recent VA→PA translations.
- L1 TLB: ~64 entries, ~1 cycle hit
- L2 TLB: ~1024–4096 entries, ~5 cycles hit
- TLB miss: full page walk, ~100ns on cache-cold PTEs

### TLB Coverage
With 4KB pages and 4096 TLB entries: only 16MB of address space is "TLB hot". Storage workloads that scatter I/O across many pages will constantly miss.

With 2MB huge pages: same 4096 TLB entries cover 8GB. **This is why SPDK and databases use huge pages** — better TLB coverage means fewer walks means less CPU overhead per I/O.

---

## 3. TLB Shootdown: The NUMA Cost

When a PTE is modified (page unmapped, permission changed), the TLB entry on ALL CPUs that may have it cached must be invalidated. On multi-CPU/NUMA systems this requires IPIs (inter-processor interrupts):

```c
// arch/x86/mm/tlb.c
void flush_tlb_range(struct vm_area_struct *vma,
                     unsigned long start, unsigned long end)
{
    // Build tlbflush_info describing the range
    // Send IPI to all CPUs that may have this mm loaded:
    on_each_cpu_mask(mm_cpumask(vma->vm_mm), flush_tlb_func, &info, 1);
}
```

**Cost on large NUMA systems:** Each `munmap()`, `mprotect()`, COW fault, or page migration sends IPIs to potentially all CPU cores. On a 256-core system, this is expensive. This is why `munmap()` of large ranges can take milliseconds.

```bash
# Count TLB shootdowns:
perf stat -e tlb:tlb_flush sleep 10

# TLB miss rate:
perf stat -e dTLB-load-misses,dTLB-store-misses,dTLB-loads ./your_workload

# TLB miss cost relative to hits:
perf stat -e dTLB-load-misses,instructions ./fio_job
```

---

## 4. Page Table Memory Overhead

```bash
# Total page table memory:
cat /proc/meminfo | grep PageTables

# Per-process page table size:
cat /proc/$pid/status | grep VmPTE

# For a process with many VMAs (Java, Python):
cat /proc/$(pidof java)/status | grep VmPTE
# Common to see 50-200MB page tables for large JVM processes

# Page table overhead calculation:
# 1 GB of mapped space (4KB pages) = 262,144 PTEs × 8B = 2MB page tables
# 1 GB of mapped space (2MB pages) = 512 PMD entries × 8B = 4KB page tables
# Huge pages reduce page table memory by 512×
```

---

## 5. Hands-On Exercises

```bash
# --- Measure TLB impact on storage I/O ---

# Baseline: fio with 4KB pages (many TLB entries needed)
fio --name=tlb_4k --filename=/tmp/test.dat --size=4G \
    --rw=randread --bs=4k --numjobs=1 --runtime=30 \
    --direct=0 --ioengine=mmap

# Compare: fio with huge pages (fewer TLB misses)
# First reserve huge pages:
echo 4096 > /proc/sys/vm/nr_hugepages
fio --name=tlb_2M --filename=/tmp/test.dat --size=4G \
    --rw=randread --bs=4k --numjobs=1 --runtime=30 \
    --direct=0 --ioengine=mmap --hugepages=1

# Measure TLB miss rate for both:
perf stat -e dTLB-load-misses,dTLB-loads ./fio_run.sh

# --- Page table memory for mmap-heavy workload ---
python3 << 'EOF'
import mmap, os

maps = []
for i in range(1000):
    # Map 1MB each = 1000 VMAs = 1GB total mapped
    f = open('/tmp/testfile', 'r+b')
    m = mmap.mmap(f.fileno(), 1024*1024, offset=0)
    maps.append((f, m))

with open(f'/proc/{os.getpid()}/status') as f:
    for line in f:
        if 'VmPTE' in line:
            print(f"Page table memory: {line.strip()}")

for f, m in maps:
    m.close(); f.close()
EOF

# --- TLB shootdown observation ---
bpftrace -e '
kprobe:flush_tlb_mm_range {
    @shootdowns[comm] = count();
}
interval:s:5 { print(@shootdowns); clear(@shootdowns); }
'
```

---

## 6. Storage Architecture Connections

| Storage scenario | TLB/page table impact |
|-----------------|----------------------|
| `mmap(large_file, MAP_SHARED)` random access | Constant TLB misses; each page fault + each access to uncached page = miss |
| SPDK huge page DMA buffers | 2MB pages: 512× fewer TLB entries needed; measurably lower CPU% |
| io_uring registered buffers (fixed) | Pages pinned; TLBs stay warm across I/Os; no repeated fault+TLB-fill |
| `munmap(1GB)` | TLB shootdown IPI to all CPUs; can cause latency spike visible in p99 |
| NVMe driver ioremap (64KB BAR) | `_PAGE_PCD` set in PTE; cache disabled; CPU goes to device on every access |
| DAX huge page fault | Maps 2MB PMD directly to PMEM; one TLB entry covers 2MB of device |

---

## 7. Key Source Files

```
arch/x86/include/asm/pgtable_types.h  — PTE bit definitions
arch/x86/include/asm/pgtable.h        — pte_*() helper functions
arch/x86/mm/tlb.c                     — flush_tlb_range(), flush_tlb_mm()
mm/memory.c                           — __pte_alloc(), page table allocation
include/linux/pgtable.h               — cross-arch page table API
```

---

## 8. Self-Check Questions

1. A process maps 10GB of a file with `mmap(MAP_SHARED)`. How many 4KB page table pages are needed to hold the PTE level alone? How does this change if the filesystem uses 2MB huge pages in the page cache?

2. After `fork()`, the kernel must set all writable PTEs to read-only (for COW). Does this require a TLB shootdown? Why or why not?

3. `munmap(addr, 1GB)` on a 128-core NUMA system takes 5ms. Explain what is happening. How would you reduce this latency?

4. SPDK allocates its DMA memory from HugeTLB (2MB pages). The NVMe driver maps these for DMA. How many TLB entries does a 2GB DMA region consume with 2MB pages vs 4KB pages?

5. `_PAGE_PCD` (cache-disable) is set in the PTE for ioremap'd NVMe BAR pages. What happens at the CPU when the driver executes `readl(dev->bar + NVME_REG_CSTS)`? Why is this correct behavior for device registers?

---

## Tomorrow: Day 12 — Memory-Mapped Files & the Page Cache Bridge
The most critical connection between memory management and storage: how mmap and read() share the same physical pages via the page cache.
