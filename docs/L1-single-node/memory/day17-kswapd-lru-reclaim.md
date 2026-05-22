# Day 17: kswapd & Memory Reclaim — LRU Lists

## Learning Objectives
- Understand the 4 LRU lists and how pages move between them
- Trace kswapd wake conditions and reclaim algorithm
- Understand direct reclaim vs background reclaim
- Explain exactly why memory pressure causes I/O spikes

---

## 1. The Four LRU Lists

Linux maintains four LRU (Least Recently Used) lists per memory zone:

```
Active(anon)    — recently accessed anonymous pages (heap, stack)
Inactive(anon)  — less recently used anonymous pages (swap candidates)
Active(file)    — recently accessed file-backed pages (page cache)
Inactive(file)  — less recently used file-backed pages (eviction candidates)
```

Plus `Unevictable` — mlock'd pages that can never be reclaimed.

```bash
# See LRU list sizes:
cat /proc/meminfo | grep -E 'Active|Inactive|Unevictable'
# Active(anon):     10 GB
# Inactive(anon):    2 GB   ← swap candidates
# Active(file):     30 GB
# Inactive(file):   15 GB   ← eviction candidates (clean=free, dirty=writeback first)
# Unevictable:       1 GB   ← never reclaimed

# Detailed per-zone LRU:
cat /proc/zoneinfo | grep -E 'nr_active|nr_inactive|nr_unevictable'
```

---

## 2. LRU Page Aging

New pages enter the **Inactive** list. On second access, they're promoted to **Active**. kswapd demotes pages from Active → Inactive over time.

```c
// mm/swap.c
void folio_mark_accessed(struct folio *folio)
{
    if (folio_test_referenced(folio)) {
        // Second access: promote to active list
        folio_activate(folio);
        folio_clear_referenced(folio);
    } else {
        // First access: mark referenced
        folio_set_referenced(folio);
    }
}

// mm/vmscan.c — kswapd aging:
shrink_active_list()
    // Scan active list; move unreferenced pages to inactive:
    folio_referenced()      // check hardware reference bit (PTE Accessed)
    if (!referenced):
        move to inactive list
```

---

## 3. kswapd: The Background Reclaim Daemon

One `kswapd` thread per NUMA node. Wakes when free pages drop below `WMARK_LOW`:

```c
// mm/vmscan.c
int kswapd(void *p)
{
    pg_data_t *pgdat = p;  // this NUMA node

    for (;;) {
        // Sleep until woken by allocator:
        wait_event_freezable(pgdat->kswapd_wait,
                             kswapd_condition(pgdat));

        // Reclaim until free pages reach WMARK_HIGH:
        balance_pgdat(pgdat, alloc_order, classzone_idx)
            → kswapd_shrink_node()
                → shrink_node()
                    → shrink_lruvec()    // scan LRU lists
                        → shrink_inactive_list()  // reclaim from inactive
                        → shrink_active_list()    // age active pages
```

### Reclaim Priority
kswapd prefers to reclaim **clean file pages** first:
1. Clean file pages (Inactive(file)) → free immediately, no I/O
2. Dirty file pages (Inactive(file)) → must write to disk first
3. Anonymous pages (Inactive(anon)) → must write to swap
4. Clean slab pages (SReclaimable) → drop inode/dentry caches

**This is why memory pressure causes I/O:** dirty file pages and anonymous pages must be written to persistent storage before RAM can be freed.

---

## 4. Direct Reclaim: When kswapd Isn't Fast Enough

If allocation fails even after kswapd runs, the **allocating process itself** does reclaim:

```c
// mm/page_alloc.c
__alloc_pages_direct_reclaim()
    → try_to_free_pages()
        → shrink_zones()
            → shrink_node() per node
                → [same path as kswapd]
```

**Direct reclaim adds latency directly to the process doing the allocation.** A storage daemon doing `kmalloc(GFP_NOIO)` that hits direct reclaim will have that call take milliseconds instead of nanoseconds.

```bash
# Observe direct reclaim events:
/usr/share/bcc/tools/drsnoop
# Shows: COMM  PID  LAT(ms)  PAGES

# BPF trace:
bpftrace -e '
kprobe:try_to_free_pages {
    @start[tid] = nsecs;
}
kretprobe:try_to_free_pages {
    if (@start[tid]) {
        printf("direct reclaim: %s took %lld ms, freed %d pages\n",
               comm, (nsecs - @start[tid])/1000000, retval);
        delete(@start[tid]);
    }
}
'
```

---

## 5. vm.swappiness: Tuning the Anon/File Balance

`vm.swappiness` controls preference for reclaiming anonymous pages vs file pages:
- Default: 60
- 0: strongly prefer evicting file cache over swapping (but won't completely disable swap)
- 200: strongly prefer swapping (added in 5.8)
- 10: typical for databases (keep anonymous pages, evict file cache)

```bash
sysctl vm.swappiness
# The calculation in vmscan.c:
# anon_prio = swappiness
# file_prio = 200 - swappiness
# Scans more of the higher-priority list type
```

---

## 6. Hands-On Exercises

```bash
# --- Watch kswapd in action ---
bpftrace -e '
kprobe:balance_pgdat {
    printf("kswapd working: order=%d\n", arg1);
    @[kstack(5)] = count();
}
interval:s:5 { print(@); exit(); }
'

# Simulate memory pressure:
stress-ng --vm 1 --vm-bytes 90% --timeout 30s &
# Watch:
watch -n1 'cat /proc/meminfo | grep -E "MemFree|Active|Inactive|SwapUsed"'
watch -n1 'vmstat 1 1 | tail -1'
# Watch 'si' (swap in) and 'so' (swap out) columns

# --- PSI: Pressure Stall Information ---
# Modern pressure measurement (5.2+):
cat /proc/pressure/memory
# some avg10=0.50 avg60=0.12 avg300=0.02 total=5432167
# full avg10=0.00 avg60=0.00 avg300=0.00 total=0

# 'some' = at least one task stalled
# 'full' = ALL tasks stalled (worst case)
# avg10/60/300 = rolling average over 10s/60s/5min windows

cat /proc/pressure/io    # I/O pressure (correlates with reclaim-driven I/O)

# --- vmstat reclaim stats ---
cat /proc/vmstat | grep -E 'pgsteal|pgscan|pgswap|pgfault|pgmajfault'
# pgsteal_kswapd_*   — pages reclaimed by kswapd
# pgsteal_direct_*   — pages reclaimed by direct reclaim
# pgscan_kswapd_*    — pages scanned by kswapd
# pgmajfault         — total major faults (each = storage I/O)
```

---

## 7. Key Source Files

```
mm/vmscan.c         — kswapd(), shrink_lruvec(), shrink_inactive_list()
mm/swap.c           — folio_mark_accessed(), LRU list management
mm/page_alloc.c     — __alloc_pages_direct_reclaim()
kernel/psi.c        — PSI pressure stall accounting
```

---

## 8. Self-Check Questions

1. kswapd scans 10,000 file-backed pages from the Inactive(file) list. 8,000 are clean, 2,000 are dirty. How many result in I/O? How many are immediately freed?

2. `vm.swappiness=10`. Under memory pressure, the system has 20GB anonymous pages and 40GB file cache. Which does kswapd prefer to reclaim? Calculate the scan ratio.

3. A storage benchmark shows random I/O latency spikes every 30 seconds. `vmstat` shows `si>0` during spikes. `/proc/pressure/memory` shows `some avg60=15%`. Construct a diagnosis and fix.

4. Direct reclaim stalls a process for 200ms. The system has NVMe capable of 1M IOPS. What was the reclaim thread doing during those 200ms that blocked the allocating process?

5. Why does `Inactive(file)` shrink before `Inactive(anon)` under memory pressure? Under what conditions does the kernel swap anonymous pages instead of evicting file cache?

---

## Tomorrow: Day 18 — Swap: Architecture & Interaction With Storage
