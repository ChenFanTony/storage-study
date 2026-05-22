# Day 5: vmalloc, ioremap & Memory Pools

## Learning Objectives
- Understand when to use vmalloc vs kmalloc and the tradeoffs
- Understand ioremap for device MMIO — how NVMe BAR registers are mapped
- Master mempool: guaranteed allocation for storage hot paths
- Read `/proc/vmallocinfo` and understand what's living in vmalloc space

---

## 1. vmalloc: Virtually Contiguous, Physically Scattered

### Why vmalloc Exists
`kmalloc` requires physically contiguous pages. On a fragmented system, large kmalloc allocations fail. `vmalloc` solves this by mapping physically scattered pages into a contiguous virtual address range using PTEs.

```
Physical memory (fragmented):
  page @  0x1000  ─┐
  page @ 0x50000  ─┼─ mapped to → vmalloc area: 0xffffc90000000000 – 0xffffc90000003000
  page @ 0x20000  ─┘   (contiguous in VA, scattered in PA)
```

### When to Use vmalloc
- Large allocations (> 1MB) where physical contiguity is not needed
- One-time setup allocations (driver load, module init) where TLB pressure doesn't matter
- Kernel modules themselves (loaded into vmalloc space)

### When NOT to Use vmalloc
- DMA buffers — DMA requires physical contiguity (or scatter-gather)
- High-frequency hot paths — every vmalloc access incurs TLB pressure (no huge pages)
- Small allocations — overhead of page table setup not worth it

```c
// API
void *vmalloc(unsigned long size);              // may sleep
void *vzalloc(unsigned long size);             // zeroed
void *vmalloc_node(unsigned long size, int node); // NUMA-aware
void vfree(const void *addr);

// Check if pointer is vmalloc'd:
bool is_vmalloc_addr(const void *x);
```

### vmalloc Internals
```c
// mm/vmalloc.c
void *__vmalloc_node(unsigned long size, unsigned long align, gfp_t gfp_mask,
                     int node, const void *caller)
    → __get_vm_area_node()     // reserve VA range in vmalloc space
    → __vmalloc_area_node()    // allocate physical pages (order-0 each)
    → vmap_pages_range()       // set up PTEs mapping PA → VA
```

---

## 2. /proc/vmallocinfo

Every vmalloc region is listed here:

```bash
cat /proc/vmallocinfo
# Format: VA_start-VA_end  size  caller  flags  phys_addr(for ioremap)
# Example lines:
# 0xffffc90000000000-0xffffc90000005000   20480 vmalloc_node+0x... pages=4 vmalloc
# 0xffffc90000010000-0xffffc90000012000    8192 __ioremap+0x...    phys=0xfe000000 ioremap
# 0xffffffffa0000000-0xffffffffa0010000   65536 module load        pages=16 vmalloc N0=16
```

```bash
# Total vmalloc space used:
cat /proc/meminfo | grep VmallocUsed

# Count vmalloc regions:
wc -l /proc/vmallocinfo

# Find largest regions:
awk '{print $2, $3}' /proc/vmallocinfo | sort -rn | head -20

# Find ioremap regions (device MMIO):
grep ioremap /proc/vmallocinfo

# Find module text regions:
grep "vmalloc N" /proc/vmallocinfo | head -10
```

---

## 3. ioremap: Mapping Device Registers

NVMe controllers expose their registers (doorbell, command/completion queues) via PCIe BAR (Base Address Register) MMIO. The driver must map this physical MMIO range into kernel virtual address space.

```c
// NVMe driver: drivers/nvme/host/pci.c
static int nvme_pci_enable(struct nvme_dev *dev)
{
    // Map BAR 0 into kernel VA space
    dev->bar = ioremap(pci_resource_start(pdev, 0),
                       pci_resource_len(pdev, 0));
    // Now dev->bar is a kernel VA that maps to the NVMe controller's registers
    // Reads/writes to dev->bar go directly to the controller
}

// Read NVMe controller register:
u32 status = readl(dev->bar + NVME_REG_CSTS);

// Write NVMe submission queue tail doorbell:
writel(sq->tail, dev->bar + NVME_REG_DBS + sq->doorbell_offset);
```

```c
// ioremap variants:
void __iomem *ioremap(phys_addr_t offset, size_t size);
    // Maps MMIO; cache-disabled (important: reads see device state, not cached copy)

void __iomem *ioremap_wc(phys_addr_t offset, size_t size);
    // Write-combining: batches writes for better throughput (used for NVMe data transfer)

void __iomem *ioremap_cache(phys_addr_t offset, size_t size);
    // Cacheable MMIO (rare; only for RAM-like devices like PMEM)

void iounmap(volatile void __iomem *addr);
```

```bash
# See all ioremap'd regions (device MMIO mappings):
grep ioremap /proc/vmallocinfo

# Correlate with your NVMe devices:
lspci -v | grep -A10 "Non-Volatile"
# Look for "Memory at" lines — those are BAR regions that get ioremap'd
```

---

## 4. Memory Pools: Guaranteed Allocation

`mempool_t` guarantees that allocation always succeeds, even under severe memory pressure. It does this by pre-allocating a minimum number of objects at creation time.

```c
// include/linux/mempool.h
typedef struct mempool_s {
    spinlock_t       lock;
    int              min_nr;      // minimum number of pre-allocated elements
    int              curr_nr;     // current pre-allocated elements
    void           **elements;    // array of pre-allocated elements
    void            *pool_data;   // slab cache or page order
    mempool_alloc_t *alloc;       // allocation function
    mempool_free_t  *free;        // free function
    wait_queue_head_t wait;       // threads waiting for element
} mempool_t;
```

### How mempool Guarantees Success

```
mempool_alloc(pool, gfp):
  1. Try normal allocation (slab/buddy) → if success, return
  2. If fails: take from pool->elements[] (pre-allocated reserve)
     → guaranteed to have min_nr elements
  3. If pool is empty and gfp allows sleeping:
     → wait until someone frees an element back to pool
     → guaranteed to eventually succeed (no spurious failure)
```

### Block Layer mempool Usage

```c
// block/bio.c
int bioset_init(struct bio_set *bs, unsigned int pool_size, ...)
{
    // Create slab cache for bio structs
    bs->bio_slab = kmem_cache_create("bio", sizeof(struct bio), ...);

    // Create mempool backed by the slab cache
    // pool_size = minimum pre-allocated bios
    mempool_init_slab_pool(&bs->bio_pool, pool_size, bs->bio_slab);
    mempool_init_slab_pool(&bs->bvec_pool, pool_size, bvec_slab);
}

// Every bio allocation:
struct bio *bio_alloc_bioset(gfp_t gfp, unsigned short nr_vecs, struct bio_set *bs)
{
    // Uses mempool — cannot fail if pool is healthy
    bvec = mempool_alloc(&bs->bvec_pool, gfp_no_fs(gfp));
    bio  = mempool_alloc(&bs->bio_pool,  gfp_no_fs(gfp));
}
```

### Creating Your Own mempool

```c
// In your driver's init:
#define MY_POOL_SIZE 64
mempool_t *my_pool;

// Option 1: slab-backed pool
my_pool = mempool_create_slab_pool(MY_POOL_SIZE, my_kmem_cache);

// Option 2: page-backed pool (order-0 pages)
my_pool = mempool_create_page_pool(MY_POOL_SIZE, 0);

// Option 3: kmalloc-backed pool
my_pool = mempool_create_kmalloc_pool(MY_POOL_SIZE, sizeof(my_struct));

// Allocate (guaranteed to succeed if pool is healthy):
my_struct *obj = mempool_alloc(my_pool, GFP_NOIO);

// Free (may replenish pool or return to underlying allocator):
mempool_free(obj, my_pool);

// Cleanup:
mempool_destroy(my_pool);
```

---

## 5. Hands-On Exercises

```bash
# --- vmalloc inspection ---
cat /proc/vmallocinfo | wc -l              # total regions
cat /proc/meminfo | grep -E 'Vmalloc'     # total/used/chunk

# Find what's consuming vmalloc space:
awk '{
    split($1, addr, "-");
    size = strtonum("0x"$2);
    caller = $3;
    print size, caller
}' /proc/vmallocinfo 2>/dev/null | sort -rn | head -20

# --- ioremap: find your NVMe's MMIO ---
# Find NVMe BAR:
lspci -d ::0108 -v | grep "Memory at"
# The physical address shown is what gets ioremap'd

# See it in vmallocinfo:
grep ioremap /proc/vmallocinfo | head -20

# --- mempool stats ---
# Mempools don't have direct /proc exposure, but you can trace them:
bpftrace -e '
kprobe:mempool_alloc {
    @[kstack(4)] = count();
}
interval:s:5 { print(@); clear(@); exit(); }
'

# --- DMA coherent allocation (what SPDK/NVMe use for queues) ---
# These appear in /proc/iomem and dmesg:
dmesg | grep -i "dma\|coherent" | head -20
cat /proc/iomem | grep -i "reserved\|pci"

# --- Module vmalloc usage ---
# Each loaded module uses vmalloc for its text/data:
cat /proc/vmallocinfo | grep "N0=" | \
    awk '{print $2, $0}' | sort -rn | head -20
```

---

## 6. Key Source Files

```
mm/vmalloc.c            — __vmalloc_node(), vmap_pages_range()
mm/mempool.c            — mempool_create(), mempool_alloc(), mempool_free()
include/linux/vmalloc.h — vmalloc API
include/linux/mempool.h — mempool_t definition and API
lib/ioremap.c           — ioremap() implementation
arch/x86/mm/ioremap.c   — x86-specific ioremap
drivers/nvme/host/pci.c — nvme_pci_enable(): real ioremap usage
block/bio.c             — bioset_init(): real mempool usage
```

---

## 7. LWN Background Reading
- "Memory pools" — https://lwn.net/Articles/23349/
- "vmalloc and vmap" — https://lwn.net/Articles/117965/

---

## 8. Self-Check Questions

1. An NVMe driver calls `ioremap()` to map the controller's 64KB BAR. Where does this mapping appear? In `/proc/iomem`? In `/proc/vmallocinfo`? In page tables? Explain where each one shows up.

2. Why can't NVMe DMA buffers (for I/O queues) use `vmalloc()`? What specific property does DMA require that vmalloc doesn't provide?

3. A `mempool_t` is created with `min_nr=32`. The system is under extreme memory pressure and the slab allocator returns NULL. How does `mempool_alloc(pool, GFP_NOIO)` still succeed? What happens when all 32 pre-allocated objects are in use?

4. `ioremap()` maps MMIO as uncached by default. Why is caching disabled for device register access? What would happen if the CPU cached a read from an NVMe doorbell register?

5. Why does the kernel load module code into vmalloc space rather than physically contiguous kernel memory? What problem would arise if modules were loaded with `kmalloc()`?

---

## Tomorrow: Day 6 — Memory Debugging & Profiling Tools
kmemleak, KASAN, slub_debug, BCC/BPF memory tools, and the full `/proc/meminfo` breakdown — your diagnostic toolkit for memory problems in storage systems.
