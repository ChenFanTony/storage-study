# Day 2: Buddy Allocator — Page-Level Allocation & Fragmentation

## Learning Objectives
- Understand the buddy system: power-of-2 blocks, splitting, coalescing
- Read `alloc_pages()` call chain in `mm/page_alloc.c`
- Understand migrate types and how they combat long-term fragmentation
- Understand memory compaction and when it runs
- Connect fragmentation to NVMe/DMA allocation failures in real systems

---

## 1. The Buddy System

The buddy allocator manages physical pages in power-of-2 blocks called **orders**:

| Order | Pages | Size |
|-------|-------|------|
| 0 | 1 | 4 KB |
| 1 | 2 | 8 KB |
| 2 | 4 | 16 KB |
| ... | ... | ... |
| 9 | 512 | 2 MB |
| 10 | 1024 | 4 MB |

Each zone maintains a `free_area[MAX_ORDER]` array. Each entry is a list of free blocks of that order.

```c
// include/linux/mmzone.h
struct free_area {
    struct list_head    free_list[MIGRATE_TYPES];
    unsigned long       nr_free;
};

struct zone {
    struct free_area    free_area[MAX_ORDER]; // 11 orders: 0–10
    // ...
};
```

### Allocation: Splitting
To allocate order-N pages:
1. Check `free_area[N]` — if a block exists, return it.
2. If not, check `free_area[N+1]`. Split it: one half satisfies the request, the other half goes into `free_area[N]`.
3. Repeat up the order ladder until a free block is found or allocation fails.

### Freeing: Coalescing
When freeing an order-N block:
1. Calculate the "buddy" address (XOR the N-th bit of the page frame number).
2. If the buddy is also free and of the same order → merge into an order-(N+1) block.
3. Repeat up the ladder until the buddy is not free or we reach MAX_ORDER.

This maintains the largest possible contiguous free blocks over time — in theory.

---

## 2. Migrate Types: Fighting Fragmentation

The fundamental fragmentation problem: one long-lived UNMOVABLE page in the middle of a 4MB block prevents that block from ever being coalesced to order-10.

The solution: separate free lists by **migrate type** within each order:

```c
// include/linux/mmzone.h
enum migratetype {
    MIGRATE_UNMOVABLE,   // kernel data, page tables — cannot be moved
    MIGRATE_MOVABLE,     // user anonymous pages, file pages — can be moved/reclaimed
    MIGRATE_RECLAIMABLE, // slab pages, inode cache — can be reclaimed
    MIGRATE_PCPTYPES,    // per-CPU pages (internal)
    MIGRATE_HIGHATOMIC,  // GFP_ATOMIC reserve
    MIGRATE_CMA,         // contiguous memory allocator
    MIGRATE_ISOLATE,     // offline/migration in progress
    MIGRATE_TYPES
};
```

**Key insight:** By keeping UNMOVABLE allocations grouped together, the kernel ensures MOVABLE pages occupy separate physical regions. Over time, MOVABLE regions can be fully reclaimed, giving back large contiguous blocks.

This is how the kernel can allocate an order-9 (2MB) block even after hours of uptime — as long as the MOVABLE region was kept clean.

---

## 3. Core Allocation Path

```c
// mm/page_alloc.c — simplified call chain

struct page *alloc_pages(gfp_t gfp_mask, unsigned int order)
    → __alloc_pages(gfp_mask, order, preferred_nid, nodemask)
        → get_page_from_freelist()      // fast path: try zones in order
            → rmqueue()                 // pull from free_area
                → __rmqueue_smallest()  // find smallest sufficient order, split
        → __alloc_pages_slowpath()      // if fast path failed
            → wake_all_kswapd()         // wake reclaim
            → __alloc_pages_direct_compact()  // try compaction
            → __alloc_pages_direct_reclaim()  // try reclaim
            → __alloc_pages_may_oom()   // last resort: OOM killer
```

### Zone Fallback Order
When the preferred zone (e.g., ZONE_NORMAL on node 0) can't satisfy the request:
1. Try ZONE_NORMAL on node 0 (preferred)
2. Try ZONE_DMA32 on node 0
3. Try ZONE_NORMAL on node 1 (NUMA fallback)
4. ... etc.

The fallback order is in `mm/page_alloc.c:fallbacks[]`.

---

## 4. Memory Compaction

When high-order allocations fail due to fragmentation, the kernel runs **compaction**:
- Scans for MOVABLE pages in the lower part of a zone
- Migrates them to the upper part (using `migrate_pages()`)
- Creates a large contiguous free region in the lower part
- The order-10 allocation can now succeed

```c
// mm/compaction.c
compact_zone()          // main compaction loop
    → isolate_migratepages()    // find movable pages
    → migrate_pages()           // move them
    → isolate_freepages()       // find free pages to fill holes
```

Compaction is triggered by:
- `__alloc_pages_direct_compact()` during high-order allocation failure
- `kcompactd` daemon (background compaction)
- Manual: `echo 1 > /proc/sys/vm/compact_memory`

---

## 5. Hands-On Exercises

```bash
# --- Observe buddy allocator state ---

# Free pages per order per zone:
cat /proc/buddyinfo
# Example output:
# Node 0, zone   Normal  128  64  32  16  8  4  2  1  0  0  0
# Column headers: order 0, 1, 2, ..., 10
# Many order-0 but no order-9/10 = fragmented

# Watch fragmentation build up:
watch -n2 'cat /proc/buddyinfo'

# --- Induce fragmentation ---
# (Do this in a VM)
stress-ng --vm 4 --vm-bytes 80% --timeout 20s &
# While running, watch high-order pages disappear:
watch -n1 'cat /proc/buddyinfo | grep Normal'

# --- Trigger compaction ---
echo 1 > /proc/sys/vm/compact_memory
# Watch high-order pages reappear:
cat /proc/buddyinfo

# --- Compaction stats ---
cat /proc/vmstat | grep compact
# compact_migrate_scanned — pages scanned for migration
# compact_free_scanned    — free pages scanned
# compact_isolated        — pages isolated for migration
# compact_stall           — processes stalled waiting for compaction
# compact_success         — compaction succeeded

# --- Fragmentation index ---
# (Requires CONFIG_COMPACTION=y)
cat /sys/kernel/debug/extfrag/extfrag_index
# 0 = no fragmentation (allocation would succeed)
# 1 = fully fragmented (allocation would fail)

# --- Per-migrate-type free pages ---
cat /sys/kernel/debug/pagetypeinfo
# Shows free pages per order per migrate type per zone
# This is the most detailed fragmentation view available

# --- Allocation failure tracing ---
bpftrace -e '
kprobe:warn_alloc {
    printf("alloc failed: gfp=%lx order=%d\n", arg0, arg1);
}
'
```

---

## 6. Key Source Files

```
mm/page_alloc.c         — alloc_pages(), rmqueue(), free_pages_ok(), zone fallback
mm/compaction.c         — compact_zone(), kcompactd
include/linux/mmzone.h  — free_area, migratetype enum
include/linux/gfp.h     — GFP flags (preview; full study Day 4)
```

Key functions to read in `mm/page_alloc.c`:
- `get_page_from_freelist()` — the fast allocation path
- `__rmqueue_smallest()` — find and split a free block
- `__free_one_page()` — free and coalesce

---

## 7. LWN Background Reading
- "Memory compaction" — https://lwn.net/Articles/368869/
- "Memory fragmentation avoidance" — https://lwn.net/Articles/211505/
- "CMA: Contiguous Memory Allocator" — https://lwn.net/Articles/486301/

---

## 8. Storage Architecture Connections

| Scenario | Buddy allocator involvement |
|----------|----------------------------|
| NVMe driver allocating DMA scatter-gather lists | Needs physically contiguous pages; order ≥ 1 allocation from buddy |
| bcache allocating metadata buffers | Order-0 allocations; never needs contiguous blocks — avoids fragmentation entirely |
| SPDK allocating 2MB huge page DMA regions | Needs order-9 blocks; fails if system is fragmented — why SPDK allocates at startup |
| md/RAID stripe cache | Uses order-0 pages stitched together with scatter-gather — deliberately avoids high-order dependency |
| NVMe-oF RDMA registration | Needs physically contiguous pages for RDMA memory registration |

**Pattern:** Good storage driver design avoids high-order allocations in hot paths. Use order-0 + scatter-gather instead of assuming contiguous memory. bcache and the block layer learned this lesson.

---

## 9. Self-Check Questions

1. The buddy allocator has a free order-5 block (128KB) but needs to satisfy an order-3 request (32KB). Trace exactly what happens: how many splits occur, what goes back into the free lists, and what is returned?

2. After 48 hours of uptime, your server cannot allocate an order-9 block (2MB) even though `MemFree` shows 10GB free. Explain why. What does `/proc/buddyinfo` look like in this scenario? What would you do to recover?

3. Why does bcache use order-0 allocations for its bucket metadata rather than larger allocations? What problem does this solve?

4. `compact_stall` in `/proc/vmstat` is incrementing rapidly on your NVMe storage server. What is happening? Is this a problem? What is the root cause?

5. ZONE_DMA32 has only order-0 and order-1 free pages. An NVMe driver needs an order-2 (16KB) DMA buffer. What happens in `__alloc_pages_slowpath()`?

---

## Tomorrow: Day 3 — Slab/Slub Allocator
Object-level allocation on top of the buddy system. How `struct bio`, `struct request`, `struct inode` are allocated — and why the block layer uses dedicated slab caches rather than kmalloc.
