# Day 23: HugeTLB Pages — Static Pre-allocated Huge Pages

## Learning Objectives
- Understand HugeTLB as statically reserved huge pages that never fragment
- Know why SPDK, DPDK, and databases require HugeTLB
- Configure and monitor HugeTLB reservations
- Understand 1GB pages and when to use them

---

## 1. HugeTLB vs THP

| Feature | THP | HugeTLB |
|---------|-----|---------|
| Allocation | Dynamic (khugepaged collapses) | Static (reserved at boot/early runtime) |
| Fragmentation risk | Can fail if not enough contiguous pages | Pre-allocated — guaranteed available |
| Application API | Transparent (no code change) | Explicit: `MAP_HUGETLB` or hugetlbfs |
| Memory cost | Uses regular memory pool | Reserved: unavailable to rest of system |
| DMA suitable? | No (may be split, migrated) | Yes (pinned, contiguous, never moved) |
| Best for | General anonymous memory | SPDK, DPDK, Oracle SGA, SAP HANA |

---

## 2. How HugeTLB Works

```c
// mm/hugetlb.c
struct hstate {
    unsigned int order;         // page order (9 for 2MB, 18 for 1GB)
    unsigned long mask;         // address alignment mask
    unsigned long max_huge_pages; // total reserved
    unsigned long nr_huge_pages;  // currently available
    unsigned long free_huge_pages; // free (not in use)
    struct list_head hugepage_freelists[MAX_NUMNODES]; // free list per node
};

// Two sizes on x86-64:
// hstates[0]: order=9  → 2MB  (default_hstate)
// hstates[1]: order=18 → 1GB  (requires hugepagesz=1G boot param)
```

### Allocation Path

```c
// When process mmap(MAP_HUGETLB):
hugetlb_fault()
    → alloc_huge_page(vma, address, avoid_reserve)
        → dequeue_huge_page_node_exact()  // take from freelists
        // Returns pre-allocated page: NO buddy allocator call
        // Guaranteed to succeed if free pages available
        → set_huge_pte_at()              // map into process page table as PMD
```

---

## 3. Configuration

```bash
# ── Reserve 2MB huge pages ────────────────────────────────────────────────
# At runtime (may fail if memory is fragmented):
echo 2048 > /proc/sys/vm/nr_hugepages   # reserve 2048 × 2MB = 4GB

# Per-NUMA node:
echo 1024 > /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages
echo 1024 > /sys/devices/system/node/node1/hugepages/hugepages-2048kB/nr_hugepages

# At boot (most reliable — allocated before fragmentation):
# Add to kernel command line: hugepages=2048

# Check allocation:
cat /proc/meminfo | grep -E 'HugePages|Hugepage'
# HugePages_Total:    2048   ← reserved
# HugePages_Free:     2048   ← available (shrinks as apps use them)
# HugePages_Rsvd:        0   ← reserved by mmap but not yet faulted
# HugePages_Surp:        0   ← surplus (above nr_hugepages, dynamically allocated)
# Hugepagesize:       2048 kB

# ── Reserve 1GB huge pages ────────────────────────────────────────────────
# Requires boot param: hugepagesz=1G hugepages=4
cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages

# ── hugetlbfs: filesystem interface ──────────────────────────────────────
mount -t hugetlbfs nodev /mnt/huge
# Files created here are backed by HugeTLB pages
# SPDK and DPDK use this interface
ls -la /mnt/huge/
```

---

## 4. Using HugeTLB from Applications

```c
// Method 1: MAP_HUGETLB
void *buf = mmap(NULL, 2 * 1024 * 1024,
                  PROT_READ | PROT_WRITE,
                  MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB,
                  -1, 0);
// → backed by 1 × 2MB HugeTLB page
// → 1 TLB entry covers entire 2MB

// For 1GB pages:
void *buf = mmap(NULL, 1UL * 1024 * 1024 * 1024,
                  PROT_READ | PROT_WRITE,
                  MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB | MAP_HUGE_1GB,
                  -1, 0);

// Method 2: hugetlbfs
int fd = open("/mnt/huge/myapp_dma_buf", O_CREAT | O_RDWR, 0600);
void *buf = mmap(NULL, 2 * 1024 * 1024,
                  PROT_READ | PROT_WRITE,
                  MAP_SHARED, fd, 0);
// Used by DPDK and SPDK for DMA buffer management
```

---

## 5. SPDK and HugeTLB: Why Required

SPDK (Storage Performance Development Kit) runs NVMe in userspace and requires HugeTLB for its DMA memory:

```bash
# SPDK setup allocates HugeTLB:
# scripts/setup.sh
HUGEMEM=4096  # MB
echo $((HUGEMEM / 2)) > /proc/sys/vm/nr_hugepages

# Why SPDK needs HugeTLB (not THP):
# 1. Physical contiguity guaranteed → DMA mapping is trivial (1 entry per 2MB)
# 2. Never fragmented or moved → DMA address stays valid for device lifetime
# 3. IOMMU mapping: 1 IOMMU page table entry per 2MB instead of 512 per 4KB
# 4. Predictable latency: no khugepaged collapse surprises
# 5. mlock equivalent: HugeTLB pages are never swapped or reclaimed

# Verify SPDK huge page usage:
ls -la /dev/hugepages/        # SPDK creates files here
cat /proc/meminfo | grep HugePages_Free  # drops as SPDK uses pages
```

---

## 6. Hands-On Exercises

```bash
# --- Reserve and test HugeTLB ---
# Reserve 512 × 2MB = 1GB:
echo 512 > /proc/sys/vm/nr_hugepages
cat /proc/meminfo | grep HugePages

# Test allocation:
python3 << 'EOF'
import mmap, ctypes

# Allocate 1 huge page (2MB):
try:
    MAP_HUGETLB = 0x40000
    buf = mmap.mmap(-1, 2*1024*1024,
                    mmap.MAP_PRIVATE | mmap.MAP_ANONYMOUS | MAP_HUGETLB,
                    mmap.PROT_READ | mmap.PROT_WRITE)
    buf[0] = 1   # fault in the page
    print(f"Allocated 2MB HugeTLB page, addr={id(buf):#x}")
    input("Check /proc/meminfo HugePages_Free (should be 511). Press enter...")
    buf.close()
except Exception as e:
    print(f"Failed: {e} (is nr_hugepages=0?)")
EOF

# After close, HugePages_Free should return to 512:
cat /proc/meminfo | grep HugePages_Free

# --- TLB miss comparison ---
# This requires perf and is best in a controlled environment:
echo 512 > /proc/sys/vm/nr_hugepages

# Run sequential access with 4KB pages:
python3 -c "
import array, time
buf = array.array('b', [0] * (512 * 1024 * 1024))  # 512MB
start = time.perf_counter()
for i in range(0, len(buf), 4096):
    buf[i] = 1
elapsed = time.perf_counter() - start
print(f'4KB pages sequential: {elapsed:.3f}s')
"

# Measure TLB misses:
perf stat -e dTLB-load-misses,dTLB-loads python3 -c "
import array
buf = array.array('b', [0] * (512 * 1024 * 1024))
for i in range(0, len(buf), 4096): buf[i] = 1
"

# --- Monitor HugeTLB in production ---
watch -n5 'cat /proc/meminfo | grep -E "HugePages|Hugepage"'

# Per-process HugeTLB usage:
cat /proc/$(pidof spdk_nvme)/smaps | grep -i huge
```

---

## 7. Key Source Files

```
mm/hugetlb.c            — hugetlb_fault(), alloc_huge_page(), hstate management
mm/hugetlb_vmemmap.c    — HugeTLB vmemmap optimization
include/linux/hugetlb.h — struct hstate, hugetlb API
fs/hugetlbfs/inode.c    — hugetlbfs filesystem
arch/x86/mm/hugetlbpage.c — x86 huge page PTE setup
```

---

## 8. Self-Check Questions

1. `nr_hugepages=1024` (2MB) is set. A process calls `mmap(MAP_HUGETLB)` for 4GB. How many HugeTLB pages does it consume? What happens to `HugePages_Rsvd`?

2. SPDK is running and has consumed all 1024 HugeTLB pages. A new process tries `mmap(MAP_HUGETLB, 2MB)`. What happens? How does this differ from regular `mmap` failure?

3. Why can't SPDK use THP instead of HugeTLB for its DMA buffers? What specific guarantee does HugeTLB provide that THP cannot?

4. `echo 2048 > /proc/sys/vm/nr_hugepages` fails to reserve all 2048 pages — only 1800 succeed. Why? What does the system state look like that prevents full reservation?

5. A database allocates its shared memory buffer pool (Oracle SGA) from HugeTLB. The buffer pool is 200GB using 1GB huge pages. What are the TLB implications vs using 2MB or 4KB pages?

---

## Tomorrow: Day 24 — NUMA Memory Management
