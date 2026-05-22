# Day 18: Swap — Architecture & Storage Interaction

## Learning Objectives
- Understand swap slot allocation and swap entry PTEs
- Trace the swap-out and swap-in paths
- Understand zswap (compressed swap cache in RAM)
- Design swap appropriately for NVMe-based systems

---

## 1. Swap Data Structures

```c
// include/linux/swap.h
struct swap_info_struct {
    unsigned long   flags;          // SWP_USED, SWP_WRITEOK, etc.
    signed short    prio;           // priority (higher = preferred)
    struct file    *swap_file;      // the swap file or device
    unsigned int    max;            // total slots
    unsigned char  *swap_map;       // slot usage count (0=free, 1=in-use, >=2=shared)
    unsigned int    lowest_bit;     // search start for free slots
    unsigned int    highest_bit;    // search end
    unsigned int    cluster_next;   // next cluster for allocation
    // ...
};

// A swap entry in a PTE:
// When a page is swapped out, its PTE is replaced with a "swap entry":
// Bits 1:0  = 0 (_PAGE_PRESENT cleared)
// Bits 7:2  = swap type (which swap device)
// Bits 57:8 = swap offset (slot number on swap device)
```

---

## 2. Swap-Out Path

```
kswapd or direct reclaim:
  shrink_inactive_list()
    → for each anon page in inactive list:
        pageout(folio, mapping)
          → try_to_free_swap(folio)   ← if already has swap slot
          OR
          → add_to_swap(folio)        ← allocate new swap slot
              → get_swap_page()       ← find free slot in swap_map
              → PTE updated to swap_entry
          → swap_writepage(folio)
              → submit_bio(WRITE, swap_device, slot_offset)
              → I/O in progress (PG_writeback set)
          → folio removed from page table, freed from RAM
```

---

## 3. Swap-In Path (Major Fault)

```
Process accesses VA with swap PTE:
  do_swap_page(vmf)
    → look_up_swap_cache(entry)    ← is it in swap cache (RAM)?
        → if hit: use cached page (minor fault effectively)
    → alloc_page_vma(GFP_HIGHUSER_MOVABLE)  ← allocate new page
    → swap_readpage(folio, entry)
        → submit_bio(READ, swap_device, slot_offset)
        → process sleeps until I/O completes
    → set PTE to new page (PTE updated from swap_entry to page)
    → free swap slot if not shared
```

---

## 4. zswap: Compressed Swap Cache

zswap intercepts pages before they hit the swap device and compresses them into a RAM pool. Much faster than hitting swap storage.

```bash
# Check zswap status:
cat /sys/module/zswap/parameters/enabled      # Y or N
cat /sys/module/zswap/parameters/compressor   # lz4, zstd, lzo
cat /sys/module/zswap/parameters/max_pool_percent  # % of RAM for zswap
cat /sys/module/zswap/parameters/zpool        # zbud, z3fold, zsmalloc

# zswap stats:
cat /sys/kernel/debug/zswap/pool_total_size   # compressed pool size in bytes
cat /sys/kernel/debug/zswap/stored_pages      # pages in zswap
cat /sys/kernel/debug/zswap/written_back_pages # pages evicted to real swap

# Compression ratio:
stored=$(cat /sys/kernel/debug/zswap/stored_pages)
pool_size=$(cat /sys/kernel/debug/zswap/pool_total_size)
echo "Avg compressed size: $((pool_size / stored)) bytes per 4KB page"

# Enable zswap:
echo 1 > /sys/module/zswap/parameters/enabled
echo lz4 > /sys/module/zswap/parameters/compressor
```

---

## 5. Swap and NVMe: Design Considerations

```bash
# Create a swap file on NVMe:
fallocate -l 32G /nvme/swapfile
chmod 600 /nvme/swapfile
mkswap /nvme/swapfile
swapon -p 10 /nvme/swapfile   # priority 10

# NVMe swap performance characteristics:
# - Random read latency: ~100μs (swap-in)
# - Random write latency: ~50μs (swap-out)
# - Compare to HDD swap: ~10ms each direction

# Check swap activity:
vmstat 1 | awk '{print "si="$7, "so="$8}'  # si=swap_in pages/sec, so=swap_out

# Swap utilization:
swapon --show
# NAME       TYPE SIZE   USED PRIO
# /nvme/swap file  32G  1.2G   10

# Tune for NVMe swap:
# Higher swappiness acceptable (NVMe swap is fast):
sysctl -w vm.swappiness=30  # instead of 10 for HDD swap

# Enable zswap to further reduce NVMe wear:
echo 1 > /sys/module/zswap/parameters/enabled
```

---

## 6. Hands-On Exercises

```bash
# --- Observe swap under pressure ---
# First confirm swap is configured:
swapon --show

# Create memory pressure:
stress-ng --vm 1 --vm-bytes $(free -b | awk '/Mem/{print int($2*0.95)}') \
    --timeout 20s &

# Watch swap:
watch -n1 'cat /proc/meminfo | grep -E "SwapFree|SwapUsed|Shmem"'
vmstat 1 30

# --- Trace individual swap events ---
bpftrace -e '
tracepoint:mm:mm_vmscan_write_folio {
    printf("swap-out: pid=%d comm=%s\n", pid, comm);
    @swapout[comm] = count();
}
tracepoint:mm:mm_vmscan_swpin_start {
    printf("swap-in: pid=%d comm=%s\n", pid, comm);
    @swapin[comm] = count();
}
interval:s:5 { print(@swapout); print(@swapin); exit(); }
'

# --- zswap effectiveness ---
# Before enabling zswap, note swap device write rate:
iostat -x 1 | grep -E "nvme|sda"

# Enable zswap:
echo 1 > /sys/module/zswap/parameters/enabled

# Re-run pressure test; observe reduced swap device I/O:
# zswap absorbs compressed pages in RAM before they hit the device
```

---

## 7. Key Source Files

```
mm/swap_state.c     — swap cache: add_to_swap(), lookup_swap_cache()
mm/swapfile.c       — swap slot management: get_swap_page(), swap_map
mm/memory.c         — do_swap_page(): swap-in fault handler
mm/vmscan.c         — shrink_page_list(): swap-out path
mm/zswap.c          — zswap compressed swap cache
include/linux/swap.h — swp_entry_t, swap_info_struct
```

---

## 8. Self-Check Questions

1. A page has been swapped out. The PTE now contains a swap entry. The process accesses the VA. Trace the complete fault: what happens in `do_swap_page()`, what I/O is submitted, and what does the PTE look like when the process resumes?

2. zswap compresses pages at 3:1 ratio and stores them in a 4GB pool. How many 4KB pages can it hold? If these pages would otherwise hit NVMe swap, how much NVMe I/O is avoided?

3. `vm.swappiness=0` — can the kernel still swap? Under what extreme conditions?

4. A storage server runs with 256GB RAM and no swap. An unexpected memory allocation spike consumes all RAM. What happens? Contrast with having 64GB of NVMe swap.

5. Swap on NVMe has ~100μs random read latency. A process's working set is 10GB but only 8GB of RAM is available. 2GB gets swapped out. On each access to a swapped page: what is the additional latency? How does this compare to the process's expected page cache miss rate?

---

## Tomorrow: Day 19 — OOM Killer
