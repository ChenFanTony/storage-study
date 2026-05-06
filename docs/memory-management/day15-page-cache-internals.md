# Day 15: Page Cache Internals — struct folio & address_space

## Learning Objectives
- Understand struct folio as the modern page cache unit
- Understand address_space xarray indexing and page cache lookup
- Use cachestat, vmtouch, and BPF to observe page cache behavior live
- Connect page cache to your storage layer knowledge

---

## 1. struct folio: The Modern Page Cache Unit

Before kernel 6.0, the page cache used `struct page`. The **folio** project (Matthew Wilcox, 2021–2022) replaced it. A folio is one or more physically contiguous pages treated as a single unit. For 4KB pages: folio = page. For large folios (filesystem block size, or THP): folio = multiple pages.

```c
// include/linux/mm_types.h
struct folio {
    union {
        struct {
            unsigned long flags;        // PG_dirty, PG_locked, PG_uptodate, etc.
            struct address_space *mapping;
            pgoff_t index;              // file offset >> PAGE_SHIFT
            union {
                void *private;
                swp_entry_t swap;
            };
            atomic_t _mapcount;         // number of page table mappings
            atomic_t _refcount;         // reference count
        };
        struct page page;               // compatible with old struct page
    };
    // For large folios only:
    unsigned long _flags_1;
    unsigned long _head;
    // ...
};
```

### Key Folio Flags
```c
PG_locked       // I/O in progress; others must wait
PG_uptodate     // contents are valid (read completed successfully)
PG_dirty        // modified, needs writeback
PG_writeback    // currently being written to disk
PG_lru          // on an LRU list
PG_active       // on the active LRU list
PG_referenced   // recently accessed (for LRU aging)
PG_reclaim      // being reclaimed
```

---

## 2. address_space: The xarray Index

```c
// include/linux/fs.h
struct address_space {
    struct inode        *host;
    struct xarray        i_pages;       // key: page_offset, value: struct folio *
    unsigned long        nrpages;       // total cached pages
    // ...
};
```

The xarray (`i_pages`) is indexed by **page offset** (file_offset >> PAGE_SHIFT). To look up the page at file offset 4096: look up index 1 in the xarray.

```c
// Page cache lookup (simplified):
struct folio *filemap_get_folio(struct address_space *mapping, pgoff_t index)
{
    return xa_load(&mapping->i_pages, index);
    // Returns NULL if not cached → major fault
}

// Page cache insert:
int filemap_add_folio(struct address_space *mapping, struct folio *folio,
                       pgoff_t index, gfp_t gfp)
{
    return xa_insert(&mapping->i_pages, index, folio, gfp);
}
```

---

## 3. Hands-On: Observing the Page Cache

```bash
# --- Page cache statistics ---
cat /proc/meminfo | grep -E 'Cached|Buffers|Dirty|Writeback'

# --- cachestat: real-time hit/miss rate ---
/usr/share/bcc/tools/cachestat 1
# HITS   MISSES  DIRTIES  HITRATIO  BUFFERS_MB  CACHED_MB
# 2048     128      512     94.12%        10.2     4096.5

# --- cachetop: per-process cache activity ---
/usr/share/bcc/tools/cachetop 5

# --- vmtouch: inspect specific files ---
vmtouch /path/to/database/file
# Pages: 1024/4096 (25.0%)  Resident: 262144  Elapsed: 0.003s

# Touch (load into cache):
vmtouch -t /path/to/file

# Evict from cache:
vmtouch -e /path/to/file
# (or: dd if=/path/to/file of=/dev/null status=none; echo 3 > /proc/sys/vm/drop_caches)

# --- BPF: trace page cache misses ---
bpftrace -e '
kprobe:pagecache_get_page {
    if (!retval) {
        @misses[comm] = count();
    }
}
interval:s:1 { print(@misses); clear(@misses); }
'

# --- BPF: trace page cache insertions ---
bpftrace -e '
kprobe:filemap_add_folio { @inserts[comm] = count(); }
interval:s:1 { print(@inserts); clear(@inserts); }
'

# --- Find largest page cache consumers ---
# (per inode — requires /proc/iomem or vmtouch per-file)
# Quick approximation via slab:
awk 'NR>2 { print $2*$4, $1 }' /proc/slabinfo | sort -rn | head -5
```

---

## 4. Page Cache for Block Devices

`Buffers` in `/proc/meminfo` = page cache for raw block device access (not through a filesystem). This is the old "buffer cache" — now unified with the page cache.

```bash
cat /proc/meminfo | grep Buffers
# Typically small on filesystems; grows if you do raw block reads

# Read raw block device (populates Buffers):
dd if=/dev/nvme0n1 of=/dev/null bs=1M count=100

cat /proc/meminfo | grep Buffers   # watch it grow
```

---

## 5. Key Source Files

```
mm/filemap.c            — filemap_get_folio(), filemap_add_folio(), filemap_fault()
include/linux/pagemap.h — page cache API
include/linux/mm_types.h — struct folio definition
include/linux/fs.h      — struct address_space
lib/xarray.c            — xarray implementation
```

---

## 6. Self-Check Questions

1. A file has 1000 pages cached. The process accesses page 500. Trace `filemap_get_folio()`: what data structure is searched, with what key, and what is returned on hit vs miss?

2. Two processes map the same file. Process A dirties page 0 (MAP_SHARED write). Does `PG_dirty` get set on the folio? Does process B see the dirty data? When does it reach disk?

3. `nrpages` in `struct address_space` = 10000. Each page is 4KB. How much RAM is this file consuming in the page cache? Is all of it necessarily resident in RAM?

4. Why is the page cache implemented as an xarray rather than a hash table? What operations benefit from the xarray's ordered structure?

5. `/proc/meminfo` shows `Cached: 80GB` but `vmtouch /var/lib/mysql/` shows only 20GB cached for the database files. Where is the other 60GB of Cached memory?

---

## Tomorrow: Day 16 — Dirty Pages & Writeback: The Full Pipeline
