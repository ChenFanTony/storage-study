# Day 12: Memory-Mapped Files & the Page Cache Bridge

## Learning Objectives
- Understand that `mmap(file)` and `read(file)` share the same physical pages
- Trace the bridge: VMA → fault handler → address_space → page cache page → PTE
- Understand `struct address_space` as the page cache root
- Understand read-ahead for file-backed VMAs
- Know O_DIRECT and DAX as page cache bypass paths

---

## 1. The Shared Physical Layer

This is the most important architectural insight connecting memory management to storage:

```
Process A: read(fd, buf, 4096)     Process B: mmap(fd, ...)
     │                                     │
     │                                     │ fault on access
     ▼                                     ▼
filemap_read()                      filemap_fault()
     │                                     │
     └──────────────┬──────────────────────┘
                    │
                    ▼
         struct address_space (inode->i_mapping)
         xarray of struct folio objects
                    │
              [page offset]
                    │
              struct folio (physical pages)
                    │
         ┌──────────┴──────────┐
         │                     │
    Process A's             Process B's
    copy_to_user()          PTE → same page
    (kernel copies          (zero-copy: VA maps
    from page to buf)        directly to this page)
```

**Key:** There is one copy of file data in RAM — in the page cache. Both `read()` and `mmap()` access the same physical pages. No data duplication.

---

## 2. struct address_space: The Page Cache Root

Every file-backed inode has one `address_space` (accessible as `inode->i_mapping`):

```c
// include/linux/fs.h
struct address_space {
    struct inode            *host;           // the inode this belongs to
    struct xarray           i_pages;         // xarray of cached folios
                                             // indexed by page offset (>>PAGE_SHIFT)
    struct rw_semaphore     invalidate_lock;
    gfp_t                   gfp_mask;        // GFP flags for page allocation
    atomic_t                i_mmap_writable; // count of MAP_SHARED writeable mappings
    struct rb_root_cached   i_mmap;          // tree of all VMAs mapping this file
    unsigned long           nrpages;         // total pages in cache
    unsigned long           writeback_index; // where writeback starts
    const struct address_space_operations *a_ops;  // filesystem operations
    unsigned long           flags;           // AS_EIO, AS_ENOSPC, etc.
};
```

The `i_mmap` rbtree connects page cache → all VMAs that map this file. This is the **reverse mapping** for file-backed pages: given a page, find all PTEs that map it (needed for COW, reclaim, migration).

```c
// address_space_operations: filesystem implements these
struct address_space_operations {
    int (*read_folio)(struct file *, struct folio *);  // read one page from disk
    int (*writepage)(struct page *, struct writeback_control *);
    int (*writepages)(struct address_space *, struct writeback_control *);
    bool (*dirty_folio)(struct address_space *, struct folio *);
    int (*write_begin)(struct file *, struct address_space *, ...);
    int (*write_end)(struct file *, struct address_space *, ...);
    // ...
};
```

---

## 3. The Fault → Page Cache Path in Detail

```c
// mm/filemap.c
vm_fault_t filemap_fault(struct vm_fault *vmf)
{
    struct file *file = vmf->vma->vm_file;
    struct address_space *mapping = file->f_mapping;
    pgoff_t offset = vmf->pgoff;  // which page of the file

    // Step 1: Look up in xarray (page cache)
    folio = filemap_get_folio(mapping, offset);

    if (folio) {
        // MINOR FAULT: page already in cache
        // No I/O needed; just map it into the faulting process
        goto page_found;
    }

    // MAJOR FAULT: page not in cache
    // Step 2: Allocate a new folio
    folio = filemap_alloc_folio(gfp, 0);

    // Step 3: Add to page cache (xarray)
    filemap_add_folio(mapping, folio, offset, gfp);

    // Step 4: Read from disk
    // Calls mapping->a_ops->read_folio(file, folio)
    // → filesystem submits bio → block layer → disk
    // → process sleeps (TASK_UNINTERRUPTIBLE) until I/O completes
    filemap_read_folio(file, mapping->a_ops->read_folio, folio);

page_found:
    // Step 5: Map the page into the faulting process's page table
    vmf->page = folio_file_page(folio, offset);
    // caller (handle_pte_fault) sets the PTE
    return VM_FAULT_LOCKED;
}
```

---

## 4. Read-Ahead for mmap

When a fault occurs at page offset N, the kernel assumes you'll access N+1, N+2, ... soon. It prefetches:

```c
// mm/filemap.c — triggered by filemap_fault()
page_cache_async_ra()
    → ondemand_readahead()
        → ra_submit()
            → read_pages()   // submits multiple pages in one I/O
```

The read-ahead window grows geometrically (2× each time) up to `vm.max_map_count` limit.

```bash
# Per-file read-ahead size (default 128KB):
blockdev --getra /dev/nvme0n1
cat /sys/block/nvme0n1/queue/read_ahead_kb

# Change:
blockdev --setra 256 /dev/nvme0n1  # 256 × 512B = 128KB

# madvise can override per-mmap:
# MADV_SEQUENTIAL: aggressive read-ahead (double default)
# MADV_RANDOM:     disable read-ahead (random access pattern)
# MADV_WILLNEED:   prefetch range NOW (useful before processing)
# MADV_DONTNEED:   drop range from cache (free memory after use)
```

---

## 5. O_DIRECT and DAX: Bypassing the Page Cache

### O_DIRECT
Bypasses page cache entirely. Data goes directly between userspace buffer and disk (via DMA).

```
read(fd_direct, buf, size)
    → direct_IO path
    → filesystem: ext4_direct_IO() or xfs_file_direct_write()
    → block layer: bio with userspace pages
    → DMA directly to/from userspace buffer
    → NO page cache involvement
```

Page cache is NOT populated. Subsequent reads from O_DIRECT are always from disk.
Use when: database buffer pool manages its own caching (MySQL innodb, PostgreSQL shared_buffers).

### DAX (Direct Access)
For PMEM/NVMe-backed-by-PMEM. No page cache, no block layer.

```
fault on DAX-mapped file
    → dax_iomap_fault()
    → filesystem: ext4_dax_fault() or xfs_dax_fault()
    → maps PMEM physical address directly into process page table
    → CPU accesses PMEM directly via LOAD/STORE
    → NO page cache, NO block I/O, NO DMA
```

Latency: ~300ns (PMEM access) vs ~4μs (NVMe) vs page cache hit (~100ns).

---

## 6. Hands-On Exercises

```bash
# --- Prove read() and mmap() share pages ---

# Create test file:
dd if=/dev/urandom of=/tmp/shared_test bs=1M count=100

# Drop caches:
echo 3 > /proc/sys/vm/drop_caches

# Check cache state (should be 0%):
vmtouch /tmp/shared_test

# Read with read():
dd if=/tmp/shared_test of=/dev/null bs=1M

# Check cache state (should be ~100%):
vmtouch /tmp/shared_test

# Now mmap: pages are already in cache → NO major faults
bpftrace -e 'software:major-faults:1 { @[comm] = count(); }' &
BPID=$!
python3 -c "
import mmap
f = open('/tmp/shared_test', 'rb')
m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
data = bytes(m)   # access every byte — all minor faults
f.close()
"
sleep 1; kill $BPID
# Major faults should be 0 — pages already in cache from read()

# --- cachestat: live page cache hit rate ---
/usr/share/bcc/tools/cachestat 1 &
CSPID=$!
# Generate mixed read workload:
fio --name=cache --rw=randrw --bs=4k --size=500M \
    --filename=/tmp/shared_test --direct=0 --runtime=10
kill $CSPID

# --- vmtouch: inspect cache state of specific files ---
vmtouch -v /var/lib/mysql/ibdata1 2>/dev/null | head -20
# Shows which pages are cached, % cached, total size

# --- O_DIRECT vs buffered: cache pollution comparison ---
# Buffered: pollutes page cache with sequential data
fio --name=buf --rw=read --bs=1M --size=4G \
    --filename=/tmp/big_test --direct=0
echo "After buffered read:" && cat /proc/meminfo | grep Cached

echo 3 > /proc/sys/vm/drop_caches

# O_DIRECT: no cache pollution
fio --name=dir --rw=read --bs=1M --size=4G \
    --filename=/tmp/big_test --direct=1
echo "After O_DIRECT read:" && cat /proc/meminfo | grep Cached
```

---

## 7. Key Source Files

```
mm/filemap.c            — filemap_fault(), filemap_read_folio(), page cache core
mm/readahead.c          — ondemand_readahead(), page_cache_async_ra()
include/linux/fs.h      — struct address_space, struct address_space_operations
fs/ext4/inode.c         — ext4_readpage(), ext4_writepage()
fs/dax.c                — dax_iomap_fault(): DAX fault path
fs/direct-io.c          — O_DIRECT path
```

---

## 8. Self-Check Questions

1. Process A calls `read(fd, buf, 4KB)` loading page 0 into page cache. Process B calls `mmap(fd)` and accesses page 0. How many physical pages hold page 0? Is process B's access a major or minor fault? Draw the page table entry.

2. A database uses `mmap(MAP_SHARED)` for its data files. When it writes to offset 0, is the write immediately visible in the file (as if `write()` was called)? Is it durable? When does it reach disk?

3. `vmtouch -v /path/to/file` shows 5% cached. A process then `mmap()`s the entire file and accesses it sequentially. Describe what happens in terms of: fault types, read-ahead, and final cache state after the scan.

4. Why does PostgreSQL use `O_DIRECT` for its data files by default? What problem with mmap does this solve? What does PostgreSQL's own `shared_buffers` replace?

5. DAX `mmap()` returns much lower latency than regular file `mmap()` for writes. Trace the write path for both: what layers are skipped in the DAX case? What durability guarantees change?

---

## Tomorrow: Day 13 — Kernel Mappings: kmap, ioremap, DMA Mapping
How the kernel maps device memory and manages DMA coherency — the hardware interface of memory management.
