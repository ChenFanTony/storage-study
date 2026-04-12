# Day 4: Page Cache — Writeback Thresholds & Flusher Behavior

## Learning Objectives
- Understand dirty page accounting and the writeback cliff
- Follow `balance_dirty_pages()` logic and why it causes latency spikes
- Understand flusher thread wakeup conditions and inode dirty lists
- Instrument writeback behavior with bpftrace
- Know the tuning knobs and their tradeoffs at architect level

---

## 1. Why Writeback Cliff Matters for Architects

The writeback cliff is a classic latency problem in storage systems:

```
Write throughput (MB/s)
        │
  peak  │████████████████████████
        │                        ██
        │                          ██   ← cliff
        │                            ██
  floor │                              ████████ (throttled)
        └──────────────────────────────────────► dirty ratio
             ^                    ^
             background           hard dirty_ratio
             threshold            (writers blocked)
```

Applications write fast → dirty pages accumulate → when `dirty_ratio` is hit,
writers are **synchronously throttled** inside `balance_dirty_pages()`.
The application's `write()` call blocks for potentially hundreds of milliseconds
while flusher threads drain the dirty backlog.

This is the #1 cause of unexpected write latency spikes in production systems.

---

## 2. Dirty Page Accounting Architecture

```
Per-BDI (backing device info) accounting:
  bdi->wb.stat[WB_RECLAIMABLE]    — dirty pages that can be written back
  bdi->wb.stat[WB_WRITEBACK]      — pages currently being written

Global accounting:
  vm_stat[NR_FILE_DIRTY]          — total dirty file pages
  vm_stat[NR_WRITEBACK]           — total pages in writeback

Thresholds (computed from RAM size + sysctl):
  dirty_background_bytes/ratio    → start background flushing
  dirty_bytes/ratio               → throttle writers (balance_dirty_pages)
```

Key distinction:
- `dirty_background_*` — **advisory**: flusher wakes up, app continues
- `dirty_*` (no background) — **mandatory**: app is throttled until below threshold

---

## 3. `balance_dirty_pages()` — The Throttle Mechanism

This function is called from the buffered write path **before** marking a page dirty.
If dirty pages exceed threshold, it throttles the calling task.

```c
// mm/page-writeback.c (simplified logic)
static void balance_dirty_pages(struct address_space *mapping,
                                 struct bdi_writeback *wb,
                                 unsigned long pages_dirtied)
{
    // 1. Calculate current dirty level vs threshold
    dirty = global_node_page_state(NR_FILE_DIRTY);
    thresh = dirty_thresh;  // computed from dirty_ratio

    if (dirty < dirty_background_thresh)
        return;  // fine, no action

    if (dirty > thresh) {
        // 2. Kick flusher threads
        wb_start_background_writeback(wb);

        // 3. THROTTLE: pause this task
        // Pause duration proportional to how far over threshold we are
        pause = dirty_poll_interval(dirty, thresh);
        __set_current_state(TASK_KILLABLE);
        schedule_timeout(pause);
        // Application is BLOCKED here
    }
}
```

The throttle duration is **adaptive** — the farther over the threshold, the longer
the pause. At extreme dirty levels (approaching `dirty_bytes` hard limit),
pauses can reach hundreds of milliseconds.

---

## 4. Flusher Thread Architecture (`fs/fs-writeback.c`)

Each BDI (backing device) has a `bdi_writeback` structure with a kernel worker thread.

```
bdi_writeback:
  ├── wb_writeback_work queue     — pending writeback work items
  ├── b_dirty list                — dirty inodes for this bdi
  ├── b_io list                   — inodes currently being written
  └── b_more_io list              — inodes that need more I/O

Flusher wakeup conditions:
  1. dirty_background_thresh exceeded (periodic)
  2. balance_dirty_pages() kicks it (reactive)
  3. dirty_expire_centisecs elapsed for a dirty inode
  4. sync()/fsync()/syncfs() called explicitly
  5. Memory pressure (kswapd needs clean pages to reclaim)
```

```c
// fs/fs-writeback.c
wb_writeback(wb, work):
    // Loop: pick dirty inodes, call filesystem writeback
    while (!list_empty(&wb->b_io)) {
        inode = list_entry(wb->b_io.prev, struct inode, i_io_list);
        __writeback_single_inode(inode, wbc);
        // → filesystem's .writepages() → submit_bio()
    }
```

---

## 5. Key Sysctl Knobs and Their Interactions

```bash
# View current settings
sysctl vm.dirty_background_ratio \
       vm.dirty_ratio \
       vm.dirty_background_bytes \
       vm.dirty_expire_centisecs \
       vm.dirty_writeback_centisecs

# Note: bytes settings take priority over ratio settings if both are set
# default: bytes=0 (disabled), ratio settings active
```

| Knob | Default | Meaning | Architect Concern |
|------|---------|---------|-------------------|
| `dirty_background_ratio` | 10% | Start background flush at 10% of RAM dirty | Too high → delayed flush start |
| `dirty_ratio` | 20% | Throttle writers at 20% of RAM dirty | Too high → large cliff; too low → constant throttle |
| `dirty_background_bytes` | 0 | Absolute bytes version of background ratio | Prefer this for predictable behavior |
| `dirty_bytes` | 0 | Absolute bytes version of dirty ratio | Set to known value for tuning |
| `dirty_expire_centisecs` | 3000 (30s) | How old a dirty page must be before forced writeback | High value → data at risk longer |
| `dirty_writeback_centisecs` | 500 (5s) | Flusher wakeup interval | Lower → more frequent but smaller flushes |

**For latency-sensitive workloads (databases, etc.):**
```bash
# Use absolute bytes to avoid ratio scaling with RAM
# Example for a system doing heavy writes:
sysctl -w vm.dirty_background_bytes=67108864   # 64MB — start flushing early
sysctl -w vm.dirty_bytes=134217728             # 128MB — throttle threshold
# This gives predictable, small flush cycles rather than large rare ones
```

**For throughput-optimized workloads (bulk import, backup):**
```bash
# Allow more dirty accumulation for better sequential batching
sysctl -w vm.dirty_ratio=40
sysctl -w vm.dirty_background_ratio=20
```

---

## 6. How This Interacts with Tiering (bcache/dm-cache)

This is critical for your work with bcache:

When bcache operates in **writeback mode**, dirty data sits in the SSD cache
before going to the HDD backing device. The kernel's dirty page accounting
tracks pages dirty to the **bcache device** (the block device the filesystem sits on).

The writeback cliff behavior is the same — but now two writebacks happen:
1. Kernel flusher writes dirty pages to bcache device (SSD) — fast
2. bcache writeback thread writes dirty data from SSD to HDD — slow, background

```
VFS dirty pages → balance_dirty_pages() threshold
    → flusher writes to bcache block device (SSD fast)
    → bcache writeback: SSD dirty data → HDD (slower, controlled by bcache writeback_rate)
```

The `bcache writeback_rate` controls the second stage. If it's too slow,
SSD dirty fill grows → bcache may start throttling writes at the device level
even when the kernel's `dirty_ratio` isn't hit yet.

```bash
# Check bcache dirty fill and writeback rate
cat /sys/block/bcache0/bcache/dirty_data
cat /sys/block/bcache0/bcache/writeback_rate
cat /sys/block/bcache0/bcache/writeback_rate_debug
```

---

## 7. Hands-On: Instrumenting Writeback with bpftrace

```bash
# 1. Observe balance_dirty_pages call rate under load
bpftrace -e '
kprobe:balance_dirty_pages {
    @[comm] = count();
}
interval:s:5 {
    print(@); clear(@);
}'

# Run a heavy buffered write in another terminal:
dd if=/dev/zero of=/tmp/test bs=1M count=4096 &
```

```bash
# 2. Measure time spent throttled in balance_dirty_pages (latency)
bpftrace -e '
kprobe:balance_dirty_pages    { @start[tid] = nsecs; }
kretprobe:balance_dirty_pages {
    if (@start[tid]) {
        @throttle_us = hist((nsecs - @start[tid]) / 1000);
        delete(@start[tid]);
    }
}
interval:s:10 { print(@throttle_us); exit(); }
'
```

```bash
# 3. Watch dirty/writeback counters in real time
watch -n0.5 "grep -E '^(Dirty|Writeback|NFS_Unstable):' /proc/meminfo"
```

```bash
# 4. Observe flusher thread wakeups
bpftrace -e '
kprobe:wb_writeback {
    printf("flusher wakeup: bdi=%s reason=%d\n",
        ((struct bdi_writeback *)arg0)->bdi->dev_name,
        ((struct wb_writeback_work *)arg1)->reason);
}'
```

---

## 8. The Writeback Cliff in Production: War Story Pattern

This is the pattern you'll see in monitoring when a system hits the cliff:

```
Write latency (p99):
  Normal:  1–5ms  ████
  Cliff:   200ms+ ██████████████████████████████████████
                  ^
                  dirty_ratio hit at 00:32:17

/proc/vmstat:
  pgpgout rate spikes as flusher races to drain
  nr_writeback_temp high
  balance_dirty_pages_written counter climbing
```

**Diagnosis checklist:**
```bash
# Is balance_dirty_pages being called frequently?
sar -B 1 10 | grep -E "pgpgout|pgpgout"
cat /proc/vmstat | grep -E "dirty|writeback|balance"

# Are flusher threads keeping up?
iostat -x 1 | grep -E "util|await"   # is device saturated?

# What's the dirty fill over time?
while true; do
    grep -E "^Dirty:" /proc/meminfo
    sleep 0.1
done
```

---

## 9. Self-Check Questions

1. What is the difference between `dirty_background_ratio` and `dirty_ratio`? Which one blocks writers?
2. Why does a high `dirty_ratio` cause latency spikes rather than just high throughput?
3. In a bcache writeback setup, what are the two distinct writeback stages?
4. What kernel function throttles writers when dirty threshold is exceeded?
5. Why might setting `dirty_bytes` (absolute) be preferable to `dirty_ratio` for production tuning?
6. You see p99 write latency of 300ms periodically with no storage hardware issue. What's likely happening and how would you confirm?

## 10. Answers

1. `dirty_background_ratio` triggers background flusher (async, writers continue). `dirty_ratio` blocks writers in `balance_dirty_pages()` (synchronous throttle).
2. Dirty pages accumulate to the threshold, then all writers are throttled simultaneously while flusher catches up — a synchronization storm.
3. Stage 1: kernel flusher writes dirty pages to bcache SSD (fast). Stage 2: bcache writeback thread drains SSD dirty data to HDD backing device (slower, background).
4. `balance_dirty_pages()` in `mm/page-writeback.c`.
5. Ratio scales with RAM size — on systems with large RAM, `dirty_ratio=20%` could be hundreds of GB of dirty data, causing enormous cliff events. Absolute bytes gives predictable behavior regardless of RAM size.
6. `dirty_ratio` threshold being hit periodically. Confirm: bpftrace on `balance_dirty_pages` showing long throttle durations, + `/proc/meminfo` Dirty value oscillating around the threshold.

---

## Tomorrow: Day 5 — Read-ahead: Adaptive Algorithm & Tiering Implications

We focus on how read-ahead interacts with cache tiers — when it helps
(cold HDD reads) and when it destroys your cache hit rate (random workloads).
