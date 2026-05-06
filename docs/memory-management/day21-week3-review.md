# Day 21: Week 3 Review — Reclaim Connective Tissue

## Learning Objectives
- Synthesize Days 15–20: complete dirty page lifecycle
- Trace a write() call from userspace all the way to disk and back through reclaim
- Build your production sysctl reference card for writeback tuning
- Confirm Week 3 mastery before Week 4 advanced topics

---

## 1. The Complete Dirty Page Lifecycle

Trace a `write(fd, buf, 4KB)` from start to reclaim:

```
Step 1: write() syscall
─────────────────────────
write(fd, buf, 4096)
  → vfs_write()
  → ext4_file_write_iter() / xfs_file_write_iter()
  → generic_perform_write()
    → a_ops->write_begin()        ← get/allocate page in page cache
    → copy_from_user(page, buf)   ← copy user data into kernel page
    → a_ops->write_end()
      → folio_mark_dirty(folio)   ← SET PG_dirty, add inode to wb->b_dirty
      → balance_dirty_pages_ratelimited()  ← check thresholds

Step 2: dirty accounting
─────────────────────────
  folio_mark_dirty():
    → set PG_dirty flag on folio
    → mapping->nrpages_dirty++  (approximate)
    → zone NR_FILE_DIRTY counter++
    → inode added to bdi_writeback->b_dirty list

Step 3: threshold check
─────────────────────────
  balance_dirty_pages_ratelimited():
    → dirty_pages = zone_page_state(NR_FILE_DIRTY)
    → if dirty_pages > dirty_background_thresh:
        → wakeup_flusher_threads()  ← wake bdi_writeback kworker
        → [no stall: writer continues]
    → if dirty_pages > dirty_thresh:
        → balance_dirty_pages()  ← STALL writer until writeback catches up

Step 4: background writeback
─────────────────────────────
  bdi_writeback kworker wakes:
    wb_writeback()
      → writeback_sb_inodes()
        → __writeback_single_inode()
          → do_writepages()
            → ext4_writepages() / xfs_vm_writepages()
              → for each dirty folio in address_space:
                  submit_bio(WRITE, ...) to block layer → NVMe

Step 5: I/O completes
─────────────────────────
  NVMe raises interrupt → nvme_irq()
    → bio_endio(bio)
      → end_page_writeback(folio)
        → clear PG_writeback
        → folio is now CLEAN
        → zone NR_WRITEBACK--

Step 6: page is now reclaimable
─────────────────────────────────
  Clean folio sits in Inactive(file) LRU list
  kswapd sees free pages < WMARK_LOW:
    → shrink_inactive_list()
      → page is clean → free immediately (no I/O)
      → __delete_from_page_cache(folio)  ← remove from address_space xarray
      → __free_pages(folio)               ← return to buddy allocator

Step 7: next access = major fault
──────────────────────────────────
  Process accesses the VA again:
    → filemap_fault()
    → filemap_get_folio() → NOT IN CACHE
    → MAJOR FAULT: read from NVMe → block I/O → process sleeps → data returns
```

---

## 2. Week 3 Production Sysctl Reference Card

Keep this. It's your tuning starting point for any new server:

```bash
# ── WRITEBACK THRESHOLDS ──────────────────────────────────────────────────
# For databases (low latency priority):
vm.dirty_ratio=5                # stall writers at 5% RAM dirty
vm.dirty_background_ratio=2     # start background writeback at 2% RAM
vm.dirty_expire_centisecs=500   # force write pages older than 5 seconds
vm.dirty_writeback_centisecs=200 # wake writeback thread every 2 seconds

# For throughput workloads (write buffering priority):
vm.dirty_ratio=40
vm.dirty_background_ratio=20
vm.dirty_expire_centisecs=3000
vm.dirty_writeback_centisecs=500

# For mixed (balanced default):
vm.dirty_ratio=20
vm.dirty_background_ratio=10
vm.dirty_expire_centisecs=3000
vm.dirty_writeback_centisecs=500

# ── RECLAIM BEHAVIOR ──────────────────────────────────────────────────────
vm.swappiness=10                # prefer file cache eviction over swap
                                # (use 30-60 if you have fast NVMe swap)
vm.vfs_cache_pressure=50        # default: balanced dentry/inode reclaim
                                # lower = keep dentries/inodes longer (good for many-files workload)
                                # higher = more aggressive reclaim (good if slab bloat)

vm.min_free_kbytes=524288       # 512MB minimum free (tune to 1% of RAM)
                                # too low: OOM before kswapd reacts
                                # too high: wastes RAM

# ── OVERCOMMIT ────────────────────────────────────────────────────────────
vm.overcommit_memory=0          # default heuristic (usually fine)
# vm.overcommit_memory=2        # strict: no overcommit (databases wanting predictability)
vm.overcommit_ratio=50          # 50% of RAM can be overcommitted (mode=2 only)
```

---

## 3. Integration Exercise: Writeback Storm

Reproduce the classic writeback storm and understand each phase:

```bash
# Setup: tight thresholds to make storm visible
sysctl -w vm.dirty_ratio=5
sysctl -w vm.dirty_background_ratio=2

# Monitoring in background:
(while true; do
    ts=$(date +%H:%M:%S)
    dirty=$(awk '/^Dirty/{print $2}' /proc/meminfo)
    wb=$(awk '/^Writeback:/{print $2}' /proc/meminfo)
    printf "%s dirty=%dMB wb=%dMB\n" "$ts" "$((dirty/1024))" "$((wb/1024))"
    sleep 0.5
done) &
MONPID=$!

# iostat in background:
iostat -x 1 nvme0n1 &
IOPID=$!

# Generate write load:
fio --name=storm \
    --rw=write --bs=128k --size=20G \
    --filename=/tmp/storm_test \
    --direct=0 --numjobs=2 \
    --runtime=60 --group_reporting

# You should observe:
# Phase 1: Dirty climbs rapidly (writers faster than writeback)
# Phase 2: dirty_ratio hit → writers stall → iostat shows burst
# Phase 3: Dirty drops → writers resume → repeat

kill $MONPID $IOPID 2>/dev/null

# Restore:
sysctl -w vm.dirty_ratio=20
sysctl -w vm.dirty_background_ratio=10
```

---

## 4. Week 3 Mastery Checklist

Answer each from memory before moving to Week 4:

- [ ] Draw the 4 LRU lists. Which gets reclaimed first? Under what conditions?
- [ ] Explain the dirty_ratio vs dirty_background_ratio distinction with a concrete number example.
- [ ] Trace `folio_mark_dirty()` to `end_page_writeback()` in sequence.
- [ ] Explain why clean file pages can be freed immediately but dirty pages cannot.
- [ ] Explain what kswapd does when it can't find enough clean pages to reclaim.
- [ ] Describe the OOM kill sequence from `__alloc_pages_slowpath()` to kill.
- [ ] Explain how `oom_score_adj=-1000` protects a process.
- [ ] Read `/proc/pressure/memory` and explain `some` vs `full`.
- [ ] Diagnose: "server is slow + vmstat shows si>0" → what does this mean?

---

## 5. Key Diagnostic Commands Summary

```bash
# Memory health check — run in order:
free -h                                          # big picture
cat /proc/pressure/memory                        # PSI pressure
awk '/^Dirty/{print $2}' /proc/meminfo           # dirty pages
vmstat 1 5                                       # reclaim activity (si/so)
slabtop -o | head -10                            # slab consumers
cat /proc/meminfo | grep SUnreclaim              # kernel leak check
cat /proc/meminfo | grep -E 'Committed|Commit'   # overcommit check

# During active pressure:
/usr/share/bcc/tools/drsnoop                     # direct reclaim events
/usr/share/bcc/tools/cachestat 1                 # cache hit rate
watch -n1 'cat /proc/pressure/memory'            # PSI live
```

---

## 6. Self-Check Questions

1. A write-heavy benchmark shows good average throughput but terrible p99 latency. `vmstat` shows periodic `bi` spikes correlating with latency spikes. `Dirty` sits near 19% of RAM with `dirty_ratio=20`. Diagnose and fix with specific sysctl changes.

2. After 72 hours of uptime, a server that was running fine starts having memory pressure. `MemAvailable` has dropped by 30GB. `SReclaimable` is unchanged. `SUnreclaim` has grown by 28GB. Diagnose.

3. kswapd is running continuously (visible in `top` as 10% CPU). `Dirty=0`. `SwapUsed` is growing. Explain what kswapd is doing and why dirty pages aren't involved.

4. Your ceph-osd process has `oom_score_adj=-900`. During OOM, it is NOT killed. Explain why, using `oom_badness()` scoring.

5. A storage server needs: (a) fast write acknowledgment (low dirty age), (b) no writer stalls, (c) sequential writeback pattern. Design the `vm.*` sysctl settings that balance all three.

---

## Week 4 Preview: Advanced — Huge Pages, NUMA, cgroups, DAX

Starting Day 22:
- THP and HugeTLB: 2MB pages for better TLB coverage
- NUMA memory policies: NVMe affinity, DMA locality
- Memory cgroups: container storage degradation explained
- DAX/PMEM: full persistent memory path
- mlock, FOLL_PIN: io_uring fixed buffers
- Week 4 Capstone: four integration exercises tying MM + storage
