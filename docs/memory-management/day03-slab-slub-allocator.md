# Day 3: Slab/Slub Allocator — Object-Level Allocation

## Learning Objectives
- Understand how slub manages fixed-size object caches on top of buddy pages
- Trace `kmalloc()` and `kmem_cache_alloc()` through the slub fast path
- Inspect storage-related slab caches: bio, request, inode, dentry
- Understand per-CPU slabs and why they exist
- Write a kernel module that uses a custom `kmem_cache`

---

## 1. Why a Slab Allocator?

The buddy allocator gives you pages (4KB minimum). Most kernel allocations are much smaller: a `struct bio` is ~200 bytes, a `struct inode` ~600 bytes. Wasting a 4KB page for a 200-byte object is unacceptable at scale.

The slab allocator solves three problems:
1. **Efficiency** — pack many objects into one page
2. **Speed** — per-CPU free lists avoid locks on fast path
3. **Cache warmth** — reusing recently-freed objects keeps CPU caches warm (constructor/destructor pattern)

Linux has had three implementations: SLAB (original), SLOB (tiny systems), SLUB (current default since ~2.6.23). We study SLUB.

---

## 2. SLUB Architecture

### kmem_cache: The Cache Descriptor
```c
// include/linux/slub_def.h
struct kmem_cache {
    struct kmem_cache_cpu __percpu *cpu_slab;  // per-CPU fast path
    unsigned long   flags;
    unsigned long   min_partial;
    unsigned int    size;       // object size (including metadata)
    unsigned int    object_size; // actual requested object size
    unsigned int    offset;     // free pointer offset within object
    unsigned int    cpu_partial; // per-CPU partial slab max count
    struct kmem_cache_order_objects oo; // slab order + objects per slab
    const char      *name;
    // ...
};
```

### Per-CPU Slab (Fast Path)
```c
struct kmem_cache_cpu {
    void      **freelist;   // pointer to next free object on this CPU's slab
    unsigned long tid;      // transaction ID (ABA prevention)
    struct slab *slab;      // current active slab page
    struct slab *partial;   // partial slabs list for this CPU
};
```

### Allocation Fast Path (lock-free)
```
kmem_cache_alloc(cache, gfp)
  → slab_alloc_node()
    → [read cpu_slab->freelist]    // atomic, lock-free
    → if freelist != NULL:
        object = *freelist
        freelist = *(freelist)     // pop from linked list embedded in objects
        return object              // ~5 ns, no lock
    → else: __slab_alloc()        // slow path: get new slab from buddy
```

The freelist is embedded *inside* the free objects themselves — no separate metadata array needed.

### Slab Life Cycle
```
buddy allocator (pages)
      ↓
  allocate_slab()     — get pages from buddy, initialize as slab
      ↓
  new_slab_objects()  — fill CPU partial list
      ↓
  [per-CPU fast path allocation]
      ↓  (slab full)
  put_cpu_partial()   — move to node partial list
      ↓  (all freed)
  discard_slab()      — return pages to buddy
```

---

## 3. kmalloc: General-Purpose Allocation

```c
// include/linux/slab.h
static __always_inline void *kmalloc(size_t size, gfp_t flags)
```

`kmalloc` uses a set of pre-created size-class caches:
`8, 16, 32, 64, 96, 128, 192, 256, 512, 1024, 2048, 4096, 8192` bytes

Each size class has two caches: one for `GFP_DMA` and one for normal allocations.

```bash
# See all kmalloc caches:
cat /proc/slabinfo | grep kmalloc
# kmalloc-8        active  total  objsize  ...
# kmalloc-16       ...
# kmalloc-32       ...
```

For sizes > 8192 bytes, `kmalloc` falls back to `alloc_pages()` directly.

---

## 4. Storage-Critical Slab Caches

These are the caches that matter most for storage architects:

```bash
cat /proc/slabinfo | grep -E 'bio|request|inode|dentry|ext4|xfs|blk'
```

| Cache name | Object | Typical size | Who uses it |
|-----------|--------|-------------|-------------|
| `bio-0` | `struct bio` (0 inline vecs) | ~200B | every block I/O |
| `bio-128` | `struct bio` + 128 vecs | ~2KB | large I/O |
| `request` | `struct request` | ~400B | block layer queue |
| `inode_cache` | `struct inode` | ~600B | VFS inode table |
| `dentry` | `struct dentry` | ~192B | directory entry cache |
| `ext4_inode_cache` | ext4 inode + VFS inode | ~1KB | ext4 fs |
| `xfs_inode` | XFS inode | ~1KB | XFS fs |
| `blkdev_queue` | `struct request_queue` | large | per block device |

### The bio_set: Guaranteed Allocation
The block layer doesn't just use a plain slab cache — it uses a **mempool** backed by a slab cache:

```c
// include/linux/bio.h
struct bio_set {
    struct kmem_cache *bio_slab;
    unsigned int front_pad;
    mempool_t bio_pool;        // guaranteed pool
    mempool_t bvec_pool;       // bio_vec pool
};
```

This guarantees that `bio_alloc_bioset()` will *always* succeed even under severe memory pressure — by drawing from the pre-allocated pool. This is how the block layer avoids deadlock during memory reclaim.

---

## 5. Hands-On Exercises

```bash
# --- Inspect slab caches ---

# All caches sorted by memory usage:
slabtop -o

# Detailed slabinfo:
cat /proc/slabinfo
# Format: name active_objs num_objs objsize objperslab pagesperslab ...

# Find storage-related caches and their memory usage:
awk 'NR>2 { used = $2 * $4; print used, $1 }' /proc/slabinfo \
  | sort -rn | head -30

# --- Watch slab activity during I/O ---
# Terminal 1: Run I/O workload
fio --name=slabtest --rw=randrw --bs=4k --size=1G --filename=/tmp/test.dat \
    --direct=0 --numjobs=4 --runtime=30 &

# Terminal 2: Watch slab changes
watch -n1 'cat /proc/slabinfo | grep -E "bio|request|inode"'

# --- BPF: trace kmem_cache_alloc for bio ---
bpftrace -e '
kprobe:kmem_cache_alloc {
    if (str(((struct kmem_cache *)arg0)->name) == "bio-0") {
        @bio_allocs = count();
    }
}
interval:s:1 { print(@bio_allocs); clear(@bio_allocs); }
'

# --- BPF: trace slab allocation latency ---
bpftrace -e '
kprobe:kmem_cache_alloc { @start[tid] = nsecs; }
kretprobe:kmem_cache_alloc {
    if (@start[tid]) {
        @lat = hist(nsecs - @start[tid]);
        delete(@start[tid]);
    }
}
interval:s:5 { print(@lat); clear(@lat); exit(); }
'

# --- Memory leak detection ---
# Requires kernel compiled with CONFIG_KMEMLEAK:
echo scan > /sys/kernel/debug/kmemleak
cat /sys/kernel/debug/kmemleak
```

---

## 6. Writing a Kernel Module with kmem_cache

```c
// example: custom_cache_module.c
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/ktime.h>

struct my_object {
    u64 id;
    char data[56];   // pad to 64 bytes total
};

static struct kmem_cache *my_cache;

static int __init my_init(void)
{
    ktime_t start, end;
    struct my_object *obj;
    int i;

    // Create cache: name, size, align, flags, ctor
    my_cache = kmem_cache_create("my_test_cache",
                                  sizeof(struct my_object),
                                  0,
                                  SLAB_HWCACHE_ALIGN,
                                  NULL);
    if (!my_cache)
        return -ENOMEM;

    // Measure allocation latency
    start = ktime_get();
    for (i = 0; i < 10000; i++) {
        obj = kmem_cache_alloc(my_cache, GFP_KERNEL);
        if (obj) kmem_cache_free(my_cache, obj);
    }
    end = ktime_get();

    pr_info("10000 alloc/free cycles: %lld ns avg\n",
            ktime_to_ns(ktime_sub(end, start)) / 10000);

    // Verify it appears in /proc/slabinfo:
    // cat /proc/slabinfo | grep my_test_cache

    kmem_cache_destroy(my_cache);
    return 0;
}

static void __exit my_exit(void) {}

module_init(my_init);
module_exit(my_exit);
MODULE_LICENSE("GPL");
```

Build with a simple Makefile:
```makefile
obj-m := custom_cache_module.o
KDIR  := /lib/modules/$(shell uname -r)/build
all:
	make -C $(KDIR) M=$(PWD) modules
```

---

## 7. Key Source Files

```
mm/slub.c               — main SLUB implementation
include/linux/slub_def.h — struct kmem_cache, struct kmem_cache_cpu
include/linux/slab.h    — kmalloc(), kmem_cache_create() API
mm/mempool.c            — mempool_t: guaranteed allocation pools
block/bio.c             — bio_alloc_bioset(), bio_set initialization
```

Key functions in `mm/slub.c`:
- `kmem_cache_alloc()` → `slab_alloc_node()` — fast path
- `__slab_alloc()` — slow path: get new slab
- `kmem_cache_free()` → `slab_free()` — return object to per-CPU freelist

---

## 8. LWN Background Reading
- "The SLUB allocator" — https://lwn.net/Articles/229096/
- "The SLAB allocator" — https://lwn.net/Articles/229984/
- "Memory pools" — https://lwn.net/Articles/23349/

---

## 9. Self-Check Questions

1. A `struct bio` is 200 bytes. SLUB packs them into 4KB pages. How many fit per page (approximately, ignoring metadata)? How does this compare to allocating each `struct bio` individually with `alloc_pages()`?

2. Why does the block layer use `mempool_t` for bio allocation rather than calling `kmem_cache_alloc()` directly? Describe the deadlock scenario that mempools prevent.

3. `slabtop` shows `inode_cache` consuming 8GB on your storage server. Is this a memory leak? How do you determine whether to be concerned?

4. You're writing a new block device driver. You need to allocate a per-I/O context structure (256 bytes) in the I/O submission hot path. Should you use `kmalloc()`, a dedicated `kmem_cache`, or a `mempool`? Justify your choice.

5. The per-CPU freelist is empty and `__slab_alloc()` is called. Trace what happens: where does the new slab come from, how is it initialized, and how does it end up in the per-CPU freelist?

---

## Tomorrow: Day 4 — GFP Flags & Allocation Context
The flags that control *how* memory is allocated — and why using the wrong flag in a storage driver causes deadlocks.
