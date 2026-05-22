# Day 16: Dirty Pages & Writeback — The Full Pipeline

## Learning Objectives
- Trace the complete dirty page lifecycle: write() → dirty → writeback → clean
- Understand dirty_ratio, dirty_background_ratio, and when processes stall
- Read the bdi_writeback infrastructure per block device
- Reproduce and measure a writeback storm

---

## 1. How Pages Become Dirty

```c
// A write() call goes through:
// VFS → filesystem → address_space → mark page dirty

// Generic path (mm/filemap.c):
ssize_t generic_perform_write(struct kiocb *iocb, struct iov_iter *i)
{
    // For each page in the write:
    a_ops->write_begin(file, mapping, pos, len, &page, &fsdata);
    // copy user data into page
    a_ops->write_end(file, mapping, pos, len, copied, page, fsdata);
    // write_end calls:
    //   folio_mark_dirty(folio)   → sets PG_dirty, adds to writeback list
    //   balance_dirty_pages_ratelimited()  ← THROTTLE IF NEEDED
}
```

### balance_dirty_pages: The Throttle

This is the function that stalls writers when too many dirty pages accumulate:

```c
// mm/page-writeback.c
void balance_dirty_pages_ratelimited(struct address_space *mapping)
{
    // Calculate dirty pages as % of total memory
    // Compare to thresholds:
    //   background_thresh = dirty_background_ratio × available memory
    //   dirty_thresh      = dirty_ratio × available memory

    if (dirty_pages > dirty_thresh) {
        // STALL the writing process:
        // Calculate throttle delay (proportional to overshoot)
        // Sleep for calculated time (or until writeback catches up)
        balance_dirty_pages(mapping, wb, pages_dirtied);
    }

    // if dirty_pages > background_thresh but < dirty_thresh:
    // wake kworker/writeback thread (background writeback)
    // but DON'T stall the writing process
}
```

---

## 2. Writeback Thresholds: The Numbers

```bash
# Key sysctl values:
sysctl vm.dirty_ratio              # default: 20 (%)
sysctl vm.dirty_background_ratio   # default: 10 (%)
sysctl vm.dirty_expire_centisecs   # default: 3000 (30 seconds)
sysctl vm.dirty_writeback_centisecs # default: 500 (5 seconds)

# Or in absolute bytes (takes precedence over ratio if set):
sysctl vm.dirty_bytes              # 0 = use ratio
sysctl vm.dirty_background_bytes   # 0 = use ratio
```

### What Each Threshold Does

| Threshold | Behavior | Formula |
|-----------|----------|---------|
| `dirty_background_ratio` | Background writeback starts | = ratio × MemAvailable |
| `dirty_ratio` | Writer processes stall | = ratio × MemAvailable |
| `dirty_expire_centisecs` | Maximum page age before forced writeback | centiseconds |
| `dirty_writeback_centisecs` | How often writeback thread wakes | centiseconds |

**Example with 100GB RAM:**
- `dirty_background_ratio=10` → background writeback starts at 10GB dirty
- `dirty_ratio=20` → writers stall at 20GB dirty
- Between 10–20GB: writers continue, background writeback runs
- At 20GB: writers stall until dirty drops below threshold

---

## 3. bdi_writeback: Per-Device Writeback

Each block device has its own `bdi_writeback` (backing device info writeback) thread:

```c
// include/linux/backing-dev-defs.h
struct bdi_writeback {
    struct backing_dev_info *bdi;      // back pointer
    struct list_head b_dirty;          // dirty inodes waiting for writeback
    struct list_head b_io;             // inodes being written
    struct list_head b_more_io;        // more I/O needed
    struct list_head b_dirty_time;     // dirty time (for lazytime)
    unsigned long    avg_write_bandwidth; // EMA of write bandwidth
    struct delayed_work dwork;         // the writeback work item
    // ...
};
```

```bash
# Per-device writeback stats:
cat /sys/class/bdi/*/stats
# Or find NVMe bdi:
ls /sys/class/bdi/
# Format: Major:Minor

# Writeback bandwidth:
cat /sys/class/bdi/$(stat -c %t:%T /dev/nvme0n1)/stats
```

---

## 4. The Full Writeback Pipeline

```
1. folio_mark_dirty(folio)
   → set PG_dirty
   → add inode to wb->b_dirty list
   → account dirty page in zone counters

2. balance_dirty_pages_ratelimited()
   → if > dirty_background_ratio: wake writeback kworker
   → if > dirty_ratio: stall current process

3. writeback kworker wakes:
   wb_writeback(wb, &work)
   → writeback_sb_inodes()
     → __writeback_single_inode()
       → do_writepages(mapping, &wbc)
         → mapping->a_ops->writepages()   ← filesystem
           → ext4_writepages() or xfs_vm_writepages()
             → mpage_writepages() or iomap_writepages()
               → for each dirty page:
                   submit_bio()   ← block layer
                     → I/O scheduler
                     → NVMe driver
                     → device

4. I/O completes:
   end_page_writeback(page)
   → clear PG_writeback
   → if not dirty: page is clean, reclaimable

5. Page is now clean:
   → can be evicted by kswapd without writing
   → if evicted: space freed, major fault on next access
```

---

## 5. Hands-On: Reproduce and Observe a Writeback Storm

```bash
# --- Baseline setup ---
sysctl vm.dirty_ratio             # note current value
sysctl vm.dirty_background_ratio

# --- Induce a writeback storm ---
# Set tight dirty threshold:
sysctl -w vm.dirty_ratio=5
sysctl -w vm.dirty_background_ratio=2

# Generate dirty pages rapidly:
fio --name=dirty_test \
    --rw=write --bs=4k --size=20G \
    --filename=/tmp/dirty_test \
    --direct=0 --numjobs=4 --runtime=30 \
    --output-format=json+

# In parallel terminal, watch dirty pages:
watch -n0.5 'grep -E "Dirty|Writeback" /proc/meminfo'

# And iostat to see the I/O burst:
iostat -x 1 nvme0n1

# You should see:
# - Dirty climbing to ~5% of RAM
# - Writeback spiking
# - iostat showing write burst
# - fio latency spiking at the dirty_ratio threshold

# --- Measure writer stall ---
bpftrace -e '
kprobe:balance_dirty_pages {
    @start[tid] = nsecs;
}
kretprobe:balance_dirty_pages {
    if (@start[tid]) {
        $lat = nsecs - @start[tid];
        if ($lat > 1000000) {  // > 1ms stall
            printf("STALL: %s for %lld ms\n", comm, $lat / 1000000);
        }
        delete(@start[tid]);
    }
}
'

# --- Trace writeback events ---
bpftrace -e '
tracepoint:writeback:writeback_start {
    printf("writeback start: dev=%s reason=%d nr_pages=%lu\n",
           str(args->name), args->reason, args->nr_pages);
}
tracepoint:writeback:writeback_written {
    printf("writeback done: written=%lu\n", args->nr_pages);
}
'

# --- Restore sane values ---
sysctl -w vm.dirty_ratio=20
sysctl -w vm.dirty_background_ratio=10
```

---

## 6. Production Tuning Reference

```bash
# For databases (low dirty_ratio to prevent stalls):
sysctl -w vm.dirty_ratio=5
sysctl -w vm.dirty_background_ratio=2
sysctl -w vm.dirty_expire_centisecs=500    # write back older pages faster

# For throughput workloads (allow more buffering):
sysctl -w vm.dirty_ratio=40
sysctl -w vm.dirty_background_ratio=20
sysctl -w vm.dirty_writeback_centisecs=1000

# For NVMe (fast backend — can afford smaller buffers):
sysctl -w vm.dirty_bytes=1073741824        # 1GB absolute
sysctl -w vm.dirty_background_bytes=536870912  # 512MB background start

# Make persistent:
echo "vm.dirty_ratio=5" >> /etc/sysctl.conf
```

---

## 7. Key Source Files

```
mm/page-writeback.c     — balance_dirty_pages(), wb_writeback(), dirty thresholds
fs/fs-writeback.c       — writeback_sb_inodes(), __writeback_single_inode()
include/linux/writeback.h — struct writeback_control
mm/backing-dev.c        — bdi_writeback infrastructure
```

---

## 8. Self-Check Questions

1. `vm.dirty_ratio=20`, `MemTotal=128GB`. Calculate the exact dirty byte threshold that stalls writers. A fio job is writing at 3GB/s. How long before it stalls (assuming writeback can't keep up)?

2. You see `Writeback: 8GB` in `/proc/meminfo` but `iostat` shows only 500MB/s write throughput. The server has NVMe capable of 3GB/s. What is the bottleneck?

3. bcache operates as a write-back cache. Both bcache AND the page cache track dirty data. When `dirty_ratio` triggers, what gets written back — bcache dirty data, page cache dirty data, or both? What ordering issues arise?

4. `vm.dirty_expire_centisecs=3000` means pages older than 30 seconds are written back. A write-heavy server keeps all pages younger than 30 seconds. Does the periodic writeback thread ever run? What triggers writeback then?

5. A log-structured filesystem (like F2FS) intentionally accumulates many dirty pages before flushing to achieve sequential writes. How should `dirty_ratio` and `dirty_background_ratio` be tuned for this workload?

---

## Tomorrow: Day 17 — kswapd & Memory Reclaim: LRU Lists
