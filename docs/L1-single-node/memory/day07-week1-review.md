# Day 7: Week 1 Review — Physical Memory Connective Tissue

## Learning Objectives
- Synthesize Days 1–6 into a single mental model
- Trace a complete allocation from API call to hardware
- Build your personal physical memory reference card
- Identify gaps before moving to virtual memory in Week 2

---

## 1. The Complete Allocation Trace

Trace `kmalloc(256, GFP_NOIO)` from the API call to the returned pointer. Follow this in `mm/slub.c` and `mm/page_alloc.c` with kernel 6.6 source open.

```
kmalloc(256, GFP_NOIO)
  │
  ├─ size=256 → kmalloc_caches[KMALLOC_NORMAL][8]  (size class index 8 = 256B)
  │  [include/linux/slab.h: kmalloc_index()]
  │
  └─ kmem_cache_alloc(kmalloc-256, GFP_NOIO)
       │
       └─ slab_alloc_node(s, NULL, GFP_NOIO, NUMA_NO_NODE, ...)
            │
            ├─ [FAST PATH] c = this_cpu_ptr(s->cpu_slab)
            │   freelist = c->freelist
            │   if freelist != NULL:
            │     object = freelist
            │     c->freelist = *(freelist + offset)   ← next free object
            │     return object    ← ~5ns, no lock, done
            │
            └─ [SLOW PATH] __slab_alloc(s, GFP_NOIO, ...)
                 │
                 ├─ try c->partial (CPU partial list)
                 │   if partial slab available: install as c->slab, retry fast path
                 │
                 └─ new_slab(s, GFP_NOIO, node)
                      │
                      └─ allocate_slab(s, GFP_NOIO, node)
                           │
                           └─ alloc_pages(GFP_NOIO | s->allocflags, s->oo.order)
                                │
                                └─ __alloc_pages(GFP_NOIO, order, preferred_nid, NULL)
                                     │
                                     ├─ get_page_from_freelist()
                                     │   │
                                     │   ├─ for each zone in zonelist:
                                     │   │   check watermarks (WMARK_LOW)
                                     │   │   if above watermark:
                                     │   │
                                     │   └─ rmqueue(zone, order, GFP_NOIO)
                                     │        │
                                     │        └─ __rmqueue_smallest(zone, order, MIGRATE_UNMOVABLE)
                                     │             │
                                     │             ├─ look in free_area[order].free_list
                                     │             ├─ if empty: try order+1, split
                                     │             └─ return page
                                     │
                                     └─ [if watermark check fails]:
                                         __alloc_pages_slowpath(GFP_NOIO, order)
                                           │
                                           ├─ wake kswapd (but GFP_NOIO: no I/O reclaim)
                                           ├─ try memory compaction
                                           └─ try direct reclaim (non-I/O pages only)
                                               → may return NULL if truly exhausted
```

**GFP_NOIO effect:** At `get_page_from_freelist()`, the zone watermarks are checked. If free pages are low, normally the allocator would try to reclaim by writing dirty pages to disk. With `GFP_NOIO`, `__GFP_IO` is absent → `can_direct_reclaim()` returns false for I/O paths → reclaim is limited to freeing clean pages only. No I/O is triggered. This prevents the deadlock chain.

---

## 2. Physical Memory Architecture Diagram

Draw this from memory, then verify against source:

```
┌─────────────────────────────────────────────────────────┐
│                    NUMA Node 0                          │
│  (struct pglist_data / pg_data_t)                       │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │  ZONE_DMA    │  │  ZONE_DMA32  │  │  ZONE_NORMAL │  │
│  │  (0-16MB)    │  │  (0-4GB)     │  │  (rest)      │  │
│  │              │  │              │  │              │  │
│  │ watermarks:  │  │ watermarks:  │  │ watermarks:  │  │
│  │  min,low,hi  │  │  min,low,hi  │  │  min,low,hi  │  │
│  │              │  │              │  │              │  │
│  │ free_area[]: │  │ free_area[]: │  │ free_area[]: │  │
│  │  [0] 4KB     │  │  [0] 4KB     │  │  [0] 4KB     │  │
│  │  [1] 8KB     │  │  [1] 8KB     │  │  [1] 8KB     │  │
│  │  ...         │  │  ...         │  │  ...         │  │
│  │  [10] 4MB    │  │  [10] 4MB    │  │  [10] 4MB    │  │
│  │              │  │              │  │              │  │
│  │ each order has MIGRATE_TYPES free lists          │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
└─────────────────────────────────────────────────────────┘

Each free page = struct page (64 bytes)
             ┌───────────────────────┐
             │ flags (PG_dirty, ...) │
             │ mapping               │
             │ index                 │
             │ _refcount             │
             └───────────────────────┘

SLUB sits on top of buddy:
  kmem_cache → per-CPU slab → objects packed into buddy pages
  kmalloc-256: 16 objects per 4KB page (4096/256)
```

---

## 3. Week 1 Reference Card

Build this and keep it. You will reference it throughout weeks 2–4:

### GFP Flag Quick Reference
| Context | Flag | Sleep? | I/O reclaim? | FS reclaim? |
|---------|------|--------|-------------|-------------|
| Normal kernel code | `GFP_KERNEL` | ✓ | ✓ | ✓ |
| Filesystem code | `GFP_NOFS` | ✓ | ✓ | ✗ |
| Block/storage driver | `GFP_NOIO` | ✓ | ✗ | ✗ |
| Interrupt handler | `GFP_ATOMIC` | ✗ | ✗ | ✗ |

### Allocator Decision Tree
```
Need memory in kernel?
  │
  ├─ Size < 8KB AND physically contiguous needed?
  │   └─ kmalloc(size, gfp)
  │
  ├─ Many objects of same type?
  │   └─ kmem_cache_create() + kmem_cache_alloc()
  │
  ├─ Must never fail (I/O path)?
  │   └─ mempool_t backed by slab cache
  │
  ├─ Large (>64KB), contiguity not needed?
  │   └─ vmalloc()
  │
  ├─ Device MMIO registers?
  │   └─ ioremap()
  │
  └─ Need pages directly (huge allocations, DMA)?
      └─ alloc_pages(gfp, order)
```

### /proc/meminfo Triage Priority
1. `MemAvailable` — is there usable memory?
2. `Dirty` vs `dirty_ratio × MemTotal` — writeback storm imminent?
3. `SwapUsed` > 0 — are we swapping? (check `si`/`so` in vmstat)
4. `SUnreclaim` — is kernel leaking memory?
5. `Writeback` — active writeback in progress?

---

## 4. Integration Exercises

### Exercise A: Observe Allocation in Real Time
```bash
# Watch buddy allocator as you load a module:
watch -n0.5 'cat /proc/buddyinfo | grep Normal'
# In another terminal:
modprobe dummy
# Observe order-0 pages consumed (module text goes to vmalloc, but slab cache grows)

# Watch slab growth during file creation:
watch -n1 'grep "inode_cache\|dentry" /proc/slabinfo | awk "{print \$1, \$2, \$4}"'
# In another terminal:
for i in $(seq 1 10000); do touch /tmp/testfile_$i; done
# Watch inode_cache and dentry slab active objects grow
rm /tmp/testfile_*
# Watch them stay (caches are lazy — memory is released under pressure, not immediately)
```

### Exercise B: Induce and Observe Fragmentation
```bash
# Step 1: Baseline
cat /proc/buddyinfo | grep Normal

# Step 2: Fragment
stress-ng --vm 2 --vm-bytes 70% --timeout 30s &
watch -n1 'cat /proc/buddyinfo | grep Normal'

# Step 3: Check high-order availability:
# Order 9 and 10 should drop toward 0 — this is fragmentation

# Step 4: Compact
echo 1 > /proc/sys/vm/compact_memory
cat /proc/buddyinfo | grep Normal
# High-order pages return

# Step 5: Check compaction cost:
cat /proc/vmstat | grep compact
```

### Exercise C: Identify Memory Consumer
```bash
# Scenario: system shows MemAvailable dropping, but top processes look normal
# Investigate slab:
slabtop -o | head -20
# If slab total > 20% of RAM: investigate SReclaimable vs SUnreclaim
cat /proc/meminfo | grep -E 'Slab|SReclaimable|SUnreclaim'

# Identify top slab consumer:
awk 'NR>2 { size=$3*$4; print size, $1 }' /proc/slabinfo | sort -rn | head -10

# If it's inode_cache or dentry: expected (reclaimable under pressure)
# If it's a driver-named cache (e.g., xfs_inode, bio-0): investigate that subsystem
# If SUnreclaim is growing: potential kernel memory leak → enable kmemleak
```

---

## 5. Self-Check: Week 1 Mastery Questions

Answer these without looking at notes:

1. What are the three levels of the Linux physical memory hierarchy? Name the kernel struct for each level.

2. You call `kmalloc(512, GFP_NOIO)` from a block device driver's request processing path. Trace the call through: size-class selection → slab fast path → (if miss) buddy allocation → zone selection → watermark check. Where exactly does `GFP_NOIO` affect behavior?

3. A storage server has `MemFree=500MB`, `MemAvailable=60GB`, `Dirty=8GB`, `vm.dirty_ratio=10`, `MemTotal=100GB`. What is about to happen? Calculate the threshold.

4. Why does the block layer use `mempool_t` for bio allocation? What specific failure mode does it prevent? Describe the deadlock chain.

5. `slabtop` shows `SUnreclaim=15GB` on a system that's been running for 3 days. The number grew by 200MB in the last hour. Is this normal? What do you do next?

6. An NVMe driver calls `ioremap(pci_bar_phys, 64*1024)`. Where does the returned virtual address come from? Show it in `/proc/vmallocinfo`. Is the mapping cached or uncached?

7. ZONE_DMA32 shows only order-0 and order-1 free pages in `buddyinfo`. A driver needs `alloc_pages(GFP_DMA32, 2)` (16KB contiguous). Trace what happens in `__alloc_pages_slowpath()`.

---

## 6. Checklist Before Week 2

Confirm you can do all of these without hesitation:

- [ ] Read and explain every field in `/proc/meminfo`
- [ ] Explain the buddy allocator splitting and coalescing with a concrete example
- [ ] Explain why `GFP_NOIO` prevents storage driver deadlocks
- [ ] Read `slabtop` and identify memory pressure sources
- [ ] Trigger and observe memory compaction
- [ ] Explain the difference between `MemFree` and `MemAvailable`
- [ ] Find a device's ioremap'd MMIO in `/proc/vmallocinfo`
- [ ] Explain when to use `kmalloc` vs `kmem_cache` vs `mempool` vs `vmalloc`

---

## Week 2 Preview: Virtual Memory & Address Spaces

Starting Day 8, we move from physical to virtual:
- How processes see memory: `mm_struct`, VMAs, page tables
- `mmap()` internals: from syscall to VMA creation
- Page fault handling: demand paging, COW, major vs minor faults
- The bridge to storage: file-backed VMAs and the page cache

All of this builds on Week 1: VMAs describe virtual ranges, but physical pages come from the Week 1 allocators. Page faults trigger slab allocations (page table pages) with GFP flags you now understand.
