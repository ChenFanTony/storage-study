# Day 20: Memory Pressure Profiling — Full Diagnostic Workflow

## Learning Objectives
- Master PSI (Pressure Stall Information) as the primary pressure signal
- Build a complete memory diagnostic runbook
- Correlate memory pressure with I/O latency spikes
- Use BPF tools to pinpoint the root cause of memory pressure

---

## 1. PSI: Pressure Stall Information

PSI was merged in kernel 4.20 (2018) and is the modern way to measure memory pressure. It measures time lost to stalls.

```bash
cat /proc/pressure/memory
# some avg10=1.23 avg60=0.45 avg300=0.12 total=45678901
# full avg10=0.00 avg60=0.00 avg300=0.00 total=0

cat /proc/pressure/io
# some avg10=5.67 avg60=2.34 avg300=0.89 total=123456789
# full avg10=2.11 avg60=0.89 avg300=0.23 total=67890123
```

### Interpreting PSI

| Field | Meaning |
|-------|---------|
| `some` | ≥1 task stalled waiting for this resource |
| `full` | ALL runnable tasks stalled (most severe) |
| `avg10` | 10-second rolling average (%) |
| `avg60` | 60-second rolling average (%) |
| `avg300` | 5-minute rolling average (%) |
| `total` | cumulative stall microseconds |

**Alert thresholds (typical production):**
- `memory.some avg60 > 10%` → investigate
- `memory.full avg10 > 5%` → immediate action
- `io.some avg60 > 20%` → storage bottleneck
- `io.full avg10 > 10%` → critical I/O stall

### PSI Within cgroups

```bash
# Per-cgroup PSI:
cat /sys/fs/cgroup/myservice/memory.pressure
cat /sys/fs/cgroup/myservice/io.pressure
# Same format as /proc/pressure/
```

---

## 2. The 60-Second Diagnostic Runbook

Receive "server is slow" alert. Run these in order:

```bash
#!/bin/bash
# Memory diagnostic runbook — 60 seconds

echo "============================================"
echo "STEP 1: Overall memory picture (5 sec)"
echo "============================================"
free -h
echo ""
cat /proc/meminfo | grep -E \
    'MemTotal|MemFree|MemAvailable|Dirty|Writeback|Slab|SReclaimable|SUnreclaim|SwapUsed|SwapFree'

echo ""
echo "============================================"
echo "STEP 2: PSI pressure stalls (5 sec)"
echo "============================================"
cat /proc/pressure/memory
cat /proc/pressure/io
cat /proc/pressure/cpu

echo ""
echo "============================================"
echo "STEP 3: Top memory consumers (10 sec)"
echo "============================================"
# By RSS:
ps aux --sort=-%mem | head -15
echo ""
# By slab:
echo "Top slab caches:"
slabtop -o | head -15

echo ""
echo "============================================"
echo "STEP 4: Reclaim activity (15 sec)"
echo "============================================"
echo "vmstat 1 15 (watch si/so for swap, bi/bo for block I/O):"
vmstat 1 15

echo ""
echo "============================================"
echo "STEP 5: Writeback state (10 sec)"
echo "============================================"
for i in $(seq 1 10); do
    printf "%-30s %-30s\n" \
        "Dirty: $(awk '/^Dirty/{print $2}' /proc/meminfo) kB" \
        "Writeback: $(awk '/^Writeback/{print $2}' /proc/meminfo) kB"
    sleep 1
done

echo ""
echo "============================================"
echo "STEP 6: OOM risk assessment"
echo "============================================"
cat /proc/meminfo | grep -E 'CommitLimit|Committed_AS'
echo "Top OOM candidates:"
for pid in $(ls /proc | grep -E '^[0-9]+$'); do
    score=$(cat /proc/$pid/oom_score 2>/dev/null)
    comm=$(cat /proc/$pid/comm 2>/dev/null)
    [ -n "$score" ] && printf "%5d %s\n" "$score" "$comm"
done 2>/dev/null | sort -rn | head -10
```

---

## 3. Correlating Memory Pressure With I/O Latency

```bash
# Tool: watch both memory and I/O simultaneously
# Terminal 1: memory pressure
watch -n1 'echo "=== Memory ===" && \
    cat /proc/meminfo | grep -E "MemFree|Dirty|Writeback" && \
    echo "=== PSI ===" && cat /proc/pressure/memory && \
    echo "=== Swap ===" && vmstat 1 1 | tail -1'

# Terminal 2: I/O latency histogram (BPF)
bpftrace -e '
tracepoint:block:block_rq_issue { @start[args->sector] = nsecs; }
tracepoint:block:block_rq_complete {
    if (@start[args->sector]) {
        @io_lat_ms = hist((nsecs - @start[args->sector]) / 1000000);
        delete(@start[args->sector]);
    }
}
interval:s:5 { print(@io_lat_ms); clear(@io_lat_ms); }
'

# If I/O p99 latency spikes correlate with PSI memory spikes:
# → memory pressure is driving I/O (reclaim writing dirty pages)
# → fix: reduce dirty_ratio, add RAM, or reduce working set

# Terminal 3: identify reclaim-triggered I/O
bpftrace -e '
kprobe:shrink_page_list {
    @reclaim_io[comm] = count();
}
kprobe:balance_dirty_pages {
    @writeback_throttle[comm] = count();
}
interval:s:5 {
    print(@reclaim_io);
    print(@writeback_throttle);
    clear(@reclaim_io);
    clear(@writeback_throttle);
}
'
```

---

## 4. Advanced BPF Memory Diagnostics

```bash
# --- Who is dirtying the most pages? ---
bpftrace -e '
kprobe:folio_account_dirtied {
    @dirty[comm] = count();
}
interval:s:5 { print(@dirty); clear(@dirty); exit(); }
'

# --- kswapd activity rate ---
bpftrace -e '
kprobe:shrink_lruvec {
    @kswapd_calls = count();
}
interval:s:1 {
    printf("kswapd shrink calls/sec: %d\n", @kswapd_calls);
    clear(@kswapd_calls);
}
'

# --- Direct reclaim latency per process ---
bpftrace -e '
kprobe:try_to_free_pages { @start[tid] = nsecs; }
kretprobe:try_to_free_pages {
    if (@start[tid]) {
        @reclaim_lat_ms = hist((nsecs - @start[tid]) / 1000000);
        @by_comm[comm] = hist((nsecs - @start[tid]) / 1000000);
        delete(@start[tid]);
    }
}
interval:s:30 {
    print(@reclaim_lat_ms);
    print(@by_comm);
    exit();
}
'

# --- Page cache eviction rate ---
bpftrace -e '
kprobe:__remove_mapping {
    @evictions[comm] = count();
}
interval:s:1 {
    printf("Cache evictions/sec:");
    print(@evictions);
    clear(@evictions);
}
'

# --- meminfo delta over time ---
while true; do
    ts=$(date +%H:%M:%S)
    free=$(awk '/MemFree/{print $2}' /proc/meminfo)
    dirty=$(awk '/^Dirty/{print $2}' /proc/meminfo)
    wb=$(awk '/Writeback:/{print $2}' /proc/meminfo)
    printf "%s free=%6dMB dirty=%6dkB wb=%6dkB\n" \
        "$ts" "$((free/1024))" "$dirty" "$wb"
    sleep 5
done
```

---

## 5. Systematic Root Cause Categories

| Symptom | Likely root cause | Check |
|---------|-----------------|-------|
| `Dirty` stays near `dirty_ratio × RAM` | Write rate exceeds writeback rate | `iostat` write throughput vs `dirty_writeback_centisecs` |
| `SUnreclaim` growing steadily | Kernel memory leak | `slabtop`; compare slab names; enable `kmemleak` |
| `SwapUsed > 0` on new events | Genuine memory shortage | Reduce working set or add RAM |
| `PSI memory.full > 0` | All CPUs stalled on memory | Immediate: identify top consumer, consider OOM |
| `PSI io.some` spikes with `memory.some` | Memory pressure driving I/O | Tune `dirty_ratio`, check kswapd write-out |
| `Cached` dropping during peak load | Page cache evicted under pressure | Check `cachestat` miss rate; tune cgroup `memory.low` |
| Page fault major rate increasing | Working set > available RAM | `perf stat -e major-faults`; reduce footprint |

---

## 6. Key Source Files

```
kernel/psi.c            — PSI accounting: psi_group_change()
mm/vmscan.c             — reclaim pressure accounting
mm/page-writeback.c     — writeback pressure accounting
fs/proc/meminfo.c       — /proc/meminfo field generation
```

---

## 7. Self-Check Questions

1. `/proc/pressure/memory` shows `full avg10=8%`. What does this mean exactly? Is this a crisis? What would you check next?

2. `PSI memory.some avg60=25%` but `PSI io.some avg60=2%`. Memory stalls are high but I/O stalls are low. What type of memory pressure is this? (Hint: what causes memory stalls without I/O?)

3. A storage server shows normal `Dirty` levels and `Writeback=0`, but `PSI io.full avg10=15%`. Memory is not the cause. What else causes `io.full` pressure?

4. `SUnreclaim` grows 500MB per hour. After 48 hours it's at 24GB. `slabtop` shows `bio-0` as the top growing cache. What is happening? What would you do?

5. Build a one-liner that alerts when memory is critically low (MemAvailable < 5% of MemTotal):

```bash
# Your answer here:
# Hint: use awk on /proc/meminfo
```

---

## Tomorrow: Day 21 — Week 3 Review: Reclaim Connective Tissue
