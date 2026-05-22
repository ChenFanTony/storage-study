# Day 4: GFP Flags & Allocation Context

## Learning Objectives
- Master every significant GFP_* flag and when to use it
- Understand allocation contexts: process, softirq, hardirq, and why they constrain GFP flags
- Trace the deadlock scenario that GFP_NOIO and GFP_NOFS prevent
- Know which flags every major storage subsystem uses and why

---

## 1. What GFP Flags Control

GFP (Get Free Pages) flags pass two kinds of information to the allocator:

1. **Zone selection** — which physical address range to allocate from
2. **Reclaim behavior** — what the allocator is allowed to do if memory is tight

Getting them wrong in a storage driver causes either:
- Deadlock (wrong reclaim behavior → I/O triggered → waits for I/O → recursive)
- Allocation failure in interrupt context (sleeping when you can't)
- Performance degradation (excessive reclaim in hot path)

---

## 2. Zone Selection Flags

```c
// include/linux/gfp.h

#define __GFP_DMA       ((__force gfp_t)___GFP_DMA)
#define __GFP_HIGHMEM   ((__force gfp_t)___GFP_HIGHMEM)
#define __GFP_DMA32     ((__force gfp_t)___GFP_DMA32)
#define __GFP_MOVABLE   ((__force gfp_t)___GFP_MOVABLE)
```

| Flag | Zone | Use case |
|------|------|----------|
| (none) | ZONE_NORMAL | Default; kernel data structures |
| `__GFP_DMA` | ZONE_DMA (0–16MB) | Legacy ISA DMA (avoid) |
| `__GFP_DMA32` | ZONE_DMA32 (0–4GB) | 32-bit DMA devices |
| `__GFP_HIGHMEM` | ZONE_HIGHMEM | 32-bit kernels only; rare |
| `__GFP_MOVABLE` | ZONE_MOVABLE | Migratable user pages |

For NVMe and modern devices with 64-bit DMA, you rarely need zone flags. Use `dma_alloc_coherent()` which handles zone selection for you.

---

## 3. Reclaim Behavior Flags

These are the critical ones for storage drivers:

```c
// Key reclaim flags:
__GFP_IO        // allocator may start I/O to reclaim pages
__GFP_FS        // allocator may call into filesystem to reclaim
__GFP_RECLAIM   // = __GFP_DIRECT_RECLAIM | __GFP_KSWAPD_RECLAIM
__GFP_DIRECT_RECLAIM  // this process may do reclaim itself (can sleep)
__GFP_KSWAPD_RECLAIM  // kswapd may be woken to do reclaim
__GFP_NOWAIT    // return NULL immediately if not available (no reclaim, no sleep)
__GFP_NORETRY   // don't retry after reclaim fails
__GFP_RETRY_MAYFAIL // retry harder but still can fail
__GFP_NOFAIL    // keep trying until success (dangerous — can hang)
```

---

## 4. Compound GFP Flags

These are the ones you actually use:

```c
// include/linux/gfp.h

// The workhorse: can sleep, can reclaim, can do I/O, can call FS
#define GFP_KERNEL  (__GFP_RECLAIM | __GFP_IO | __GFP_FS)

// Process context, but NO filesystem reclaim (used in FS code itself)
#define GFP_NOFS    (__GFP_RECLAIM | __GFP_IO)

// Process context, but NO I/O at all (used in block layer)
#define GFP_NOIO    (__GFP_RECLAIM)

// Interrupt context: absolutely cannot sleep, no reclaim
#define GFP_ATOMIC  (__GFP_HIGH | __GFP_ATOMIC | __GFP_KSWAPD_RECLAIM)

// User page allocation: movable, can reclaim
#define GFP_USER    (__GFP_RECLAIM | __GFP_IO | __GFP_FS | __GFP_HARDWALL)

// User + huge pages
#define GFP_HIGHUSER_MOVABLE (GFP_HIGHUSER | __GFP_MOVABLE | __GFP_SKIP_KASAN)
```

---

## 5. The Deadlock Chain — Why GFP_NOIO Exists

This is the most important concept in this chapter. Read it carefully.

### Scenario: Block Driver Allocates with GFP_KERNEL

```
Process A: write() to file
  → VFS → page cache → mark page dirty
  → balance_dirty_pages() — too many dirty pages
  → writeback_inodes_wb() — start writing pages to disk
  → block layer: submit_bio()
    → block driver: needs to allocate metadata buffer
    → kmalloc(size, GFP_KERNEL)   ← THE PROBLEM
      → memory is tight
      → kernel tries reclaim (__GFP_RECLAIM)
      → tries to write back dirty pages (__GFP_IO)
      → submit_bio() — needs to allocate metadata buffer
      → kmalloc(size, GFP_KERNEL)
        → memory is tight → writeback → submit_bio → DEADLOCK
```

Process A is waiting for I/O to complete. That I/O needs a memory allocation. The allocator tries to free memory by doing more I/O. That I/O also needs a memory allocation. Infinite recursion / deadlock.

### The Fix: GFP_NOIO

```c
// In a block driver's I/O path:
buf = kmalloc(size, GFP_NOIO);   // correct
// GFP_NOIO = __GFP_RECLAIM only — can reclaim inactive pages,
//            but CANNOT start I/O to do so
//            → the deadlock chain is broken
```

### GFP_NOFS: For Filesystem Code

Similarly, if a filesystem's write path calls `kmalloc(GFP_KERNEL)`:
- Reclaim might call `->writepage()` on a dirty inode
- `->writepage()` calls back into the filesystem
- The filesystem tries to acquire a lock it already holds → deadlock

Fix: use `GFP_NOFS` — allows I/O reclaim but not filesystem reclaim.

```c
// In filesystem code:
inode = kmem_cache_alloc(inode_cachep, GFP_NOFS);  // correct
```

---

## 6. Allocation Contexts

The kernel has strict rules about what is allowed in each context:

| Context | Can sleep? | GFP flags allowed |
|---------|-----------|-------------------|
| Process context | Yes | GFP_KERNEL, GFP_NOFS, GFP_NOIO, GFP_ATOMIC |
| Softirq (e.g., tasklet) | No | GFP_ATOMIC only |
| Hardirq (interrupt handler) | No | GFP_ATOMIC only |
| NMI | No | Nothing (no allocation) |

Sleeping in interrupt context = kernel BUG/panic. `GFP_ATOMIC` never sleeps — it draws from an emergency reserve and returns NULL if that's exhausted.

```bash
# Detect wrong GFP usage at runtime (requires debug kernel):
# CONFIG_DEBUG_ATOMIC_SLEEP=y
# If a sleeping allocation is attempted in atomic context, you get:
# BUG: sleeping function called from invalid context
# followed by a stack trace showing exactly where

# Also: lockdep integration catches GFP_KERNEL in spinlock-held sections
```

---

## 7. GFP Flags in the Storage Stack

Here's exactly what each layer uses and why:

```c
// NVMe driver (drivers/nvme/host/core.c, pci.c)
kmalloc(size, GFP_KERNEL)     // probe/setup path — fine, not in I/O path
kmalloc(size, GFP_ATOMIC)     // interrupt completion handler
dma_alloc_coherent(dev, size, &dma, GFP_KERNEL)  // queue setup

// Block layer (block/bio.c, block/blk-core.c)
bio_alloc_bioset(gfp, ...)    // uses mempool — GFP_NOIO internally
mempool_alloc(pool, GFP_NOIO) // I/O submission path
kmalloc(size, GFP_NOIO)       // block driver internal allocations

// Device mapper (drivers/md/dm.c)
kmalloc(size, GFP_NOIO)       // I/O path
kmalloc(size, GFP_KERNEL)     // table load path (not I/O)

// bcache (drivers/md/bcache/)
kmalloc(size, GFP_NOIO)       // cache hit/miss path
mempool_alloc(&c->search, GFP_NOIO)  // search path

// XFS (fs/xfs/)
kmem_cache_alloc(xfs_inode_cache, GFP_NOFS)  // inode allocation
xfs_buf_alloc(): GFP_NOFS     // metadata buffer allocation

// ext4 (fs/ext4/)
kmem_cache_alloc(ext4_inode_cachep, GFP_NOFS)
```

---

## 8. Hands-On Exercises

```bash
# --- Trace GFP flags used during I/O ---
bpftrace -e '
kprobe:__alloc_pages {
    $gfp = arg0;
    // Check for GFP_NOIO pattern: has __GFP_RECLAIM but not __GFP_IO
    if (($gfp & 0x400) && !($gfp & 0x40)) {
        @noio[comm] = count();
    }
}
interval:s:5 { print(@noio); clear(@noio); exit(); }
'

# --- Watch GFP_ATOMIC usage (emergency allocations) ---
bpftrace -e '
kprobe:__alloc_pages {
    $gfp = arg0;
    // GFP_ATOMIC has __GFP_HIGH bit set
    if ($gfp & 0x20) {
        @atomic[comm, kstack(5)] = count();
    }
}
interval:s:10 { print(@atomic); exit(); }
'

# --- Allocation failure tracing ---
bpftrace -e '
tracepoint:kmem:mm_page_alloc_zone_locked {
    printf("alloc from locked zone: order=%d gfp=%x\n", args->order, args->gfp_flags);
}
'

# --- Check your storage driver's GFP usage ---
# (On a system with kernel source)
grep -r "GFP_KERNEL\|GFP_NOIO\|GFP_NOFS\|GFP_ATOMIC" \
    drivers/nvme/host/ | grep -v "\.h:"

grep -r "GFP_KERNEL\|GFP_NOIO\|GFP_NOFS" \
    drivers/md/bcache/ | grep "alloc\|kmalloc\|kzalloc"
```

---

## 9. Key Source Files

```
include/linux/gfp.h         — all GFP flag definitions (read this file top to bottom)
include/linux/gfp_types.h   — underlying type definitions
mm/page_alloc.c             — gfp_to_alloc_flags(), gfpflags_allow_blocking()
mm/internal.h               — gfp_pfmemalloc_allowed()
```

Essential read: `include/linux/gfp.h` — the comments in this file are excellent. Read the entire file, not just the flag definitions.

---

## 10. LWN Background Reading
- "GFP flags and reclaim" — https://lwn.net/Articles/627419/
- "Toward more readable GFP flags" — https://lwn.net/Articles/699623/

---

## 11. Self-Check Questions

1. Trace the exact deadlock that occurs if a block driver's I/O completion handler calls `kmalloc(GFP_KERNEL)` and memory is tight. Which specific `__GFP_*` bits cause the problem?

2. You're writing an NVMe target driver. In the command processing path (called from a work queue, not interrupt context), you need to allocate a 512-byte response buffer. Which GFP flag do you use and why?

3. An ext4 developer uses `GFP_KERNEL` instead of `GFP_NOFS` when allocating a new inode. Describe the deadlock. Which lock does ext4 hold that makes this dangerous?

4. `GFP_ATOMIC` succeeds but `GFP_KERNEL` fails. How is this possible? What is the "emergency reserve" that `GFP_ATOMIC` draws from?

5. You see `GFP_NOFAIL` in a driver's code during review. Should you be concerned? What does it mean, and when (if ever) is it acceptable?

---

## Tomorrow: Day 5 — vmalloc, Highmem & Memory Pools
Non-contiguous virtual allocations, device MMIO mapping, and how the block layer guarantees allocations never fail.
