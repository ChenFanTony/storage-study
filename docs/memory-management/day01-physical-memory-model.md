# Day 1: Physical Memory Model — Nodes, Zones, Pages

## Learning Objectives
- Understand how the Linux kernel models physical RAM: NUMA nodes → zones → pages
- Read and understand `struct pglist_data`, `struct zone`, `struct page`
- Use `/proc` and `sysfs` to inspect the memory topology of a live system
- Connect zone watermarks to the I/O spikes you've seen in storage benchmarks

---

## 1. The Three-Level Hierarchy

Linux models physical memory in three levels:

```
NUMA Node (struct pglist_data)
  └── Zone (struct zone)
        └── Page Frame (struct page)
```

### NUMA Node
On a multi-socket server, each CPU socket has its own local DRAM. Accessing local DRAM is fast (~80ns); crossing the QPI/UPI interconnect to remote DRAM costs 2–3×. The kernel tracks this with one `struct pglist_data` per node.

```c
// include/linux/mmzone.h
typedef struct pglist_data {
    struct zone     node_zones[MAX_NR_ZONES];
    int             nr_zones;
    unsigned long   node_start_pfn;     // first page frame number
    unsigned long   node_present_pages; // actual RAM pages
    unsigned long   node_spanned_pages; // including holes
    int             node_id;
    // ...
} pg_data_t;

#define NODE_DATA(nid) (node_data[nid])
```

### Zone
Within each node, pages are divided into zones based on physical address constraints (historical — DMA hardware limitations):

| Zone | Purpose | Typical range (x86-64) |
|------|---------|------------------------|
| ZONE_DMA | Legacy ISA DMA devices | 0–16MB |
| ZONE_DMA32 | 32-bit DMA devices | 0–4GB |
| ZONE_NORMAL | General kernel use | 4GB–end of RAM |
| ZONE_MOVABLE | Migratable pages only | Configurable |

On a modern x86-64 server with NVMe, ZONE_NORMAL holds essentially all useful RAM. DMA zones exist for compatibility.

```c
struct zone {
    long            watermark[NR_WMARK];  // min, low, high
    unsigned long   nr_reserved_highatomic;
    long            lowmem_reserve[MAX_NR_ZONES];
    struct pglist_data *zone_pgdat;
    unsigned long   zone_start_pfn;
    unsigned long   managed_pages;
    // free_area: buddy allocator free lists by order
    struct free_area free_area[MAX_ORDER];
    // ...
};
```

### Watermarks — The Storage Connection
Zone watermarks directly control when `kswapd` wakes up:
- `WMARK_MIN` — emergency reserve; direct reclaim starts (processes stall)
- `WMARK_LOW` — `kswapd` wakes and starts reclaiming
- `WMARK_HIGH` — `kswapd` stops and goes back to sleep

**This is why memory pressure causes I/O spikes in your benchmarks.** When free pages fall below `WMARK_LOW`, kswapd starts writing dirty pages to disk to free memory. You see it as unexpected I/O. You'll understand exactly how in Week 3.

### struct page
Every 4KB physical page frame has a `struct page` — 64 bytes on 64-bit systems. On a 512GB server that's 8GB just for page descriptors.

```c
// include/linux/mm_types.h (simplified)
struct page {
    unsigned long flags;        // PG_locked, PG_dirty, PG_uptodate, ...
    union {
        struct address_space *mapping;  // if file-backed
        void *s_mem;                    // if slab
    };
    union {
        pgoff_t index;          // offset within file / slab
        unsigned long private;
    };
    atomic_t _refcount;
    // ... (union of many uses)
};
```

The `flags` field is critical — it encodes the page's state:
- `PG_dirty` — page has been written, needs writeback
- `PG_locked` — I/O in progress on this page
- `PG_uptodate` — page data is valid
- `PG_lru` — page is on an LRU list
- `PG_active` — page is on the active LRU list

---

## 2. Hands-On Exercises

```bash
# --- Basic memory topology ---

# Total memory by zone:
cat /proc/zoneinfo | grep -E 'Node|zone|pages free|min|low|high'

# Buddy allocator free pages per order per zone:
cat /proc/buddyinfo
# Format: Node N, zone ZZZ  <order-0> <order-1> ... <order-10>
# Order 0 = 4KB pages, Order 10 = 4MB contiguous blocks

# Overall memory picture:
cat /proc/meminfo | head -30

# --- NUMA topology ---
numactl --hardware
# Shows: nodes, distances, per-node memory

# Per-node memory stats:
cat /sys/devices/system/node/node*/meminfo
# (if single node VM, only node0 exists)

# NUMA distances (latency matrix):
numactl --hardware | grep -A10 'distances'

# --- Zone watermarks ---
# Calculate your system's watermarks:
cat /proc/zoneinfo | grep -E 'min|low|high' | head -20
# These are in pages. Multiply by 4 for KB.

# Current watermark setting:
sysctl vm.min_free_kbytes
# This controls WMARK_MIN; kernel calculates low/high from it.

# --- Page flags inspection (requires debug kernel or bpftrace) ---
bpftrace -e '
kprobe:mark_page_accessed {
    @[kstack(3)] = count();
}
interval:s:5 { print(@); clear(@); exit(); }
'
```

---

## 3. Key Source Files

```
include/linux/mmzone.h      — struct pglist_data, struct zone, struct free_area
include/linux/mm_types.h    — struct page (and struct folio in 6.x)
include/linux/page-flags.h  — all PG_* flag definitions
mm/page_alloc.c             — zone initialization, watermark calculation
arch/x86/mm/init.c          — x86 memory map setup
```

Read order: `mmzone.h` → `mm_types.h` → `page-flags.h`. These three headers are the vocabulary of everything that follows.

---

## 4. LWN Background Reading
- "Memory: the flat, the discontiguous, and the sparse" — https://lwn.net/Articles/789304/
- "ZONE_MOVABLE" — https://lwn.net/Articles/224829/

---

## 5. Storage Architecture Connections

| What you see in storage work | What's happening in MM |
|------------------------------|------------------------|
| Unexpected I/O spike during high memory usage | kswapd woke at WMARK_LOW, started writing dirty pages |
| bcache uses `GFP_NOIO` for allocations | Allocation from ZONE_NORMAL with no-reclaim constraint |
| NVMe DMA setup needs physically contiguous pages | ZONE_DMA32 allocation; buddy order > 0 |
| SPDK pre-allocates huge pages at startup | Locks pages in ZONE_NORMAL before fragmentation occurs |
| fio `-direct=1` bypasses page cache | Still uses struct page for DMA; just doesn't go through LRU |

---

## 6. Self-Check Questions

1. A server has 512GB RAM in a single NUMA node. How large (in GB) is the kernel's `struct page` array? (64 bytes per page, 4KB pages)

2. Why does ZONE_DMA32 cap at 4GB on x86-64, even though the server has 512GB of RAM? What would happen if you needed to do DMA with a device that can only address 32-bit physical addresses and ZONE_DMA32 was exhausted?

3. Your NVMe storage benchmark shows a sudden 200ms latency spike every ~30 seconds, with corresponding iostat showing burst writes. Memory utilization is at 75%. Explain the exact sequence of events using today's watermark knowledge. What `/proc` file would you check first?

4. On a 2-socket server (NUMA node 0 and node 1), your NVMe card is connected via PCIe to node 0. Your storage benchmark processes run on node 1 CPUs. What zone does the kernel try to allocate DMA buffers from? What penalty are you paying?

---

## Tomorrow: Day 2 — Buddy Allocator
How the kernel allocates and frees pages in power-of-2 blocks, how coalescing works, and why fragmentation matters for NVMe DMA buffer allocation.
