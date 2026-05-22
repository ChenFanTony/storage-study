# Day 13: Kernel Mappings — kmap, ioremap & DMA

## Learning Objectives
- Understand kmap/kmap_atomic for accessing struct page content in kernel
- Understand ioremap variants and when each is used in storage drivers
- Understand DMA mapping API and IOMMU interaction
- Trace NVMe's complete DMA setup: from queue allocation to I/O submission

---

## 1. kmap / kmap_atomic: Accessing Page Content

On 64-bit systems, all physical RAM is directly mapped in the kernel's virtual address space (the "direct map" at `0xffff888000000000`). So accessing a `struct page`'s content is simply:

```c
void *addr = page_to_virt(page);     // direct map address
// or equivalently:
void *addr = lowmem_page_address(page);
```

No mapping needed. This is why `kmap()` is mostly a 32-bit legacy:

```c
// On 64-bit: kmap() is a no-op essentially
static inline void *kmap(struct page *page)
{
    return page_address(page);  // returns direct-map address
}

// kmap_atomic(): used when you need a guaranteed mapping even in atomic context
// On 64-bit: also returns direct-map address (no real work)
// On 32-bit: would create a temporary fixmap entry
void *kmap_atomic(struct page *page);
void kunmap_atomic(void *addr);
```

**When you still see kmap_atomic:** In code that must be portable to 32-bit, or in code that explicitly signals "I'm in atomic context and need this mapping." Read it as documentation intent more than functional requirement on 64-bit.

---

## 2. ioremap: Device MMIO

Device registers are at physical addresses outside RAM. To access them, the kernel maps them into its virtual address space with `ioremap()`.

```c
// Variants and their cache attributes:
void __iomem *ioremap(phys_addr_t phys_addr, size_t size);
// → UC (uncached): reads always go to device; writes are not buffered
// Used for: device registers where you need to see current state

void __iomem *ioremap_wc(phys_addr_t phys_addr, size_t size);
// → WC (write-combining): writes may be buffered and combined
// Used for: device memory where throughput > latency (framebuffers, NVMe CMB)

void __iomem *ioremap_cache(phys_addr_t phys_addr, size_t size);
// → WB (write-back, cached): same as normal RAM
// Used for: RAM-like devices (PMEM, Controller Memory Buffers on high-end NVMe)

void iounmap(volatile void __iomem *addr);
```

### NVMe BAR Mapping (Real Code)

```c
// drivers/nvme/host/pci.c
static int nvme_pci_enable(struct nvme_dev *dev)
{
    struct pci_dev *pdev = to_pci_dev(dev->dev);

    // Enable bus mastering (allow device to initiate DMA):
    pci_set_master(pdev);

    // Map BAR 0 (NVMe registers: CAP, VS, CC, CSTS, AQA, ASQ, ACQ, doorbell):
    dev->bar = ioremap(pci_resource_start(pdev, 0),
                       pci_resource_len(pdev, 0));
    if (!dev->bar) return -ENOMEM;

    // Read controller capabilities register:
    dev->q_depth = min_t(int,
        NVME_CAP_MQES(readq(dev->bar + NVME_REG_CAP)) + 1,
        NVME_Q_DEPTH);

    // Controller Memory Buffer (CMB) — if NVMe supports it:
    if (readl(dev->bar + NVME_REG_CMBSZ)) {
        // CMB is on-device RAM; use ioremap_wc for higher throughput:
        dev->cmb = ioremap_wc(cmb_phys, cmb_size);
        // SQ entries can be placed here for even lower latency
    }
}
```

### Accessor Functions (MUST use these, not direct dereference)

```c
// Never: *dev->bar        (undefined behavior; compiler may reorder)
// Always use MMIO accessors:

u8  readb(const volatile void __iomem *addr);
u16 readw(const volatile void __iomem *addr);
u32 readl(const volatile void __iomem *addr);
u64 readq(const volatile void __iomem *addr);

void writeb(u8  val, volatile void __iomem *addr);
void writew(u16 val, volatile void __iomem *addr);
void writel(u32 val, volatile void __iomem *addr);
void writeq(u64 val, volatile void __iomem *addr);

// The __iomem annotation is checked by sparse (kernel static analysis)
```

---

## 3. DMA Mapping API

DMA allows the NVMe controller (or any device) to read/write system RAM directly without CPU involvement. The kernel must:
1. Give the device a physical address (or IOMMU-mapped address) for the buffer
2. Ensure CPU and device see consistent data (cache coherency)

```c
// Coherent DMA: device + CPU always see same data (no explicit sync needed)
// Used for: command/completion queues (frequently accessed by both CPU and device)
void *dma_alloc_coherent(struct device *dev, size_t size,
                          dma_addr_t *dma_handle, gfp_t flag);
void dma_free_coherent(struct device *dev, size_t size,
                        void *vaddr, dma_addr_t dma_handle);

// Streaming DMA: explicit sync required between CPU and device access
// Used for: data buffers (written by CPU, then DMA'd to device)
dma_addr_t dma_map_single(struct device *dev, void *ptr,
                            size_t size, enum dma_data_direction dir);
void dma_unmap_single(struct device *dev, dma_addr_t addr,
                       size_t size, enum dma_data_direction dir);

// Scatter-gather DMA: map multiple non-contiguous buffers
int dma_map_sg(struct device *dev, struct scatterlist *sg,
                int nents, enum dma_data_direction dir);
void dma_unmap_sg(struct device *dev, struct scatterlist *sg,
                   int nents, enum dma_data_direction dir);
```

### NVMe Queue Setup (Real DMA Code)

```c
// drivers/nvme/host/pci.c
static int nvme_alloc_sq_cmds(struct nvme_dev *dev, struct nvme_queue *nvmeq,
                               int qid)
{
    // Submission queue: CPU writes commands, NVMe reads them
    // Use dma_alloc_coherent: no explicit sync needed
    nvmeq->sq_cmds = dma_alloc_coherent(dev->dev,
        SQ_SIZE(nvmeq->q_depth),   // 64 bytes × depth
        &nvmeq->sq_dma_addr,       // DMA address written to NVMe controller
        GFP_KERNEL);

    // Completion queue: NVMe writes completions, CPU reads them
    nvmeq->cqes = dma_alloc_coherent(dev->dev,
        CQ_SIZE(nvmeq->q_depth),   // 16 bytes × depth
        &nvmeq->cq_dma_addr,
        GFP_KERNEL);
}

// For I/O data buffers:
static blk_status_t nvme_map_data(struct nvme_dev *dev,
                                    struct request *req, ...)
{
    struct scatterlist *sg = req->sg;
    // Map the bio's pages for DMA:
    int nents = dma_map_sg(dev->dev, sg, req->sg_cnt, DMA_BIDIRECTIONAL);
    // sg_dma_address(sg) now contains DMA addresses to program into NVMe PRPs
}
```

---

## 4. IOMMU: Virtualizing DMA Addresses

Without IOMMU: device uses raw physical addresses. A compromised device (or buggy driver) could DMA to any physical memory.

With IOMMU: device uses "IOVA" (I/O Virtual Addresses). IOMMU translates IOVA → physical address, enforcing boundaries. A device can only DMA to pages it's been given permission to access.

```bash
# Check IOMMU:
dmesg | grep -i iommu
# "DMAR: IOMMU enabled" or "AMD-Vi: Found IOMMU"

# IOMMU groups (devices that share IOMMU protection domain):
ls /sys/kernel/iommu_groups/

# Impact on DMA performance:
# dma_map_sg() with IOMMU: must update IOMMU page tables (overhead)
# dma_map_sg() without IOMMU: trivial (physical addr = DMA addr)
# IOMMU overhead: ~5-10% for high-IOPS NVMe on older hardware
# Modern IOMMUs (Intel VT-d v3+) have hardware ATS to reduce overhead
```

---

## 5. Hands-On Exercises

```bash
# --- Find NVMe ioremap regions ---
# BAR mapping appears in /proc/vmallocinfo:
grep -i ioremap /proc/vmallocinfo | head -10

# Correlate with NVMe BAR:
lspci -d ::0108 -v | grep -E "Memory at|Region"
# The physical address listed is what gets ioremap'd

# --- DMA memory allocated by NVMe ---
# Coherent DMA (queue memory) appears in:
cat /proc/iomem | grep -v "^  " | head -30
# Or in dmesg during driver probe:
dmesg | grep -i nvme | grep -i alloc

# --- Observe DMA mapping in action ---
bpftrace -e '
kprobe:dma_map_sg {
    printf("dma_map_sg: dev=%s nents=%d dir=%d\n",
           ((struct device *)arg0)->kobj.name, arg2, arg3);
    @[comm] = count();
}
interval:s:5 { print(@); exit(); }
'

# --- Check IOMMU overhead ---
perf stat -e iommu/iommu_map/,iommu/iommu_unmap/ -p $(pidof your_storage_proc)

# --- Page table memory from DMA ---
# dma_alloc_coherent uses special pages; track:
cat /proc/meminfo | grep -E 'Bounce|HardwareCorrupted'
```

---

## 6. Key Source Files

```
include/linux/io.h          — ioremap(), readl(), writel() declarations
lib/ioremap.c               — generic ioremap implementation
arch/x86/mm/ioremap.c       — x86 ioremap with cache attribute setup
include/linux/dma-mapping.h — DMA mapping API
kernel/dma/mapping.c        — dma_map_sg(), dma_alloc_coherent()
drivers/iommu/               — IOMMU subsystem
drivers/nvme/host/pci.c     — real NVMe DMA and ioremap usage
```

---

## 7. Self-Check Questions

1. Why must `readl()` be used instead of direct pointer dereference for MMIO registers? What compiler optimization does `volatile` prevent, and why is even `volatile` insufficient without the memory barrier implicit in `readl()`?

2. NVMe completion queues use `dma_alloc_coherent()` but data buffers use `dma_map_sg()`. What is the fundamental difference in usage pattern that drives this choice?

3. With IOMMU enabled, `dma_map_sg()` for a 512-entry scatter-gather list takes 10μs. Without IOMMU, it takes 100ns. Where is the 10μs going? What does the IOMMU need to do for each entry?

4. An NVMe driver uses `ioremap_wc()` for the Controller Memory Buffer (CMB). Submission queue entries are placed in CMB. Why is `ioremap_wc()` more appropriate than `ioremap()` for this use case?

5. `dma_alloc_coherent()` is called during NVMe queue setup with `GFP_KERNEL`. This is called once during driver probe (not in I/O path). Why is `GFP_KERNEL` safe here but would be dangerous in the I/O submission path?

---

## Tomorrow: Day 14 — Week 2 Review: Virtual Memory Connective Tissue
Synthesize mmap → VMA → page fault → page table → page cache into one unified mental model.
