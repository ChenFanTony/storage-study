# Day 19: OOM Killer — When Reclaim Fails

## Learning Objectives
- Understand the OOM kill sequence: how the kernel decides to kill a process
- Read `oom_badness()` scoring and `oom_score_adj` tuning
- Understand overcommit modes and their effect on OOM frequency
- Protect critical storage daemons from OOM
- Diagnose OOM events from kernel logs

---

## 1. When Does OOM Trigger?

OOM (Out of Memory) triggers when the kernel has exhausted all reclaim options:

```
__alloc_pages_slowpath()
  → wake_all_kswapd()           # try background reclaim
  → __alloc_pages_direct_compact()  # try compaction
  → __alloc_pages_direct_reclaim()  # try direct reclaim
  → [still failing after retries]
  → __alloc_pages_may_oom()
      → out_of_memory()          ← OOM kill starts here
```

```c
// mm/oom_kill.c
bool out_of_memory(struct oom_control *oc)
{
    // Check if we should really OOM (not just a transient spike):
    if (oom_killer_disabled)
        return false;
    if (!is_memcg_oom(oc) && sysctl_panic_on_oom)
        panic("out of memory");

    // Select victim:
    select_bad_process(oc);      // find highest oom_badness score
    if (oc->chosen)
        oom_kill_process(oc, "Out of memory");
}
```

---

## 2. oom_badness: Victim Selection

```c
// mm/oom_kill.c
long oom_badness(struct task_struct *p, unsigned long totalpages)
{
    long points;
    long adj;

    // Get oom_score_adj for this process (-1000 to +1000):
    adj = (long)p->signal->oom_score_adj;
    if (adj == OOM_SCORE_ADJ_MIN)  // -1000
        return LONG_MIN;            // never kill this process

    // Base score = physical pages used (RSS + swap):
    points = get_mm_rss(p->mm) + get_mm_counter(p->mm, MM_SWAPENTS)
             + mm_pgtables_bytes(p->mm) / PAGE_SIZE;

    // Apply adjustment:
    // adj = +1000 → points × 2 (most likely to be killed)
    // adj = -1000 → never killed
    // adj = 0     → base score (default)
    adj *= totalpages / 1000;
    points += adj;

    return points;
}
```

### oom_score_adj Range

| Value | Effect |
|-------|--------|
| `-1000` | Never kill (OOM_SCORE_ADJ_MIN) |
| `-900` | Very unlikely to be killed |
| `0` | Default — scored by memory usage |
| `+500` | Twice as likely to be killed |
| `+1000` | Most likely to be killed |

```bash
# Check OOM scores for all processes:
for pid in /proc/[0-9]*/; do
    pid=${pid%/}; pid=${pid#/proc/}
    score=$(cat /proc/$pid/oom_score 2>/dev/null)
    adj=$(cat /proc/$pid/oom_score_adj 2>/dev/null)
    comm=$(cat /proc/$pid/comm 2>/dev/null)
    printf "%5s %5s %-20s\n" "$score" "$adj" "$comm"
done 2>/dev/null | sort -rn | head -20
```

---

## 3. Protecting Storage Daemons

Critical storage daemons must never be OOM-killed:

```bash
# Protect multipathd (multipath I/O daemon):
echo -1000 > /proc/$(pidof multipathd)/oom_score_adj

# Protect iscsid (iSCSI daemon):
echo -1000 > /proc/$(pidof iscsid)/oom_score_adj

# Protect ceph-osd:
echo -1000 > /proc/$(pidof ceph-osd)/oom_score_adj

# Make it persistent via systemd unit override:
# /etc/systemd/system/multipathd.service.d/oom.conf
# [Service]
# OOMScoreAdjust=-1000

# Or via systemd:
systemctl set-property multipathd.service OOMScoreAdjust=-1000

# Verify:
cat /proc/$(pidof multipathd)/oom_score_adj
```

---

## 4. Overcommit Modes

```bash
cat /proc/sys/vm/overcommit_memory
# 0 = heuristic: allow reasonable overcommit, check large requests (default)
# 1 = always allow: never fail malloc(), OOM kills when pages needed
# 2 = never overcommit: committed_AS ≤ CommitLimit (overcommit_ratio × RAM + swap)

cat /proc/sys/vm/overcommit_ratio  # default 50 (%)
cat /proc/meminfo | grep -E 'CommitLimit|Committed_AS'
# CommitLimit = overcommit_ratio × MemTotal + SwapTotal
# Committed_AS = total virtual memory committed (mmap'd + brk'd)
```

| Mode | OOM likelihood | malloc fails? | Use case |
|------|---------------|---------------|----------|
| 0 (heuristic) | Medium | Rarely | Default: most servers |
| 1 (always) | High | Never | Specific workloads needing guaranteed malloc |
| 2 (never) | Low | Yes | Financial/database: predictable behavior |

---

## 5. Reading OOM Events

```bash
# After an OOM kill, dmesg shows:
dmesg | grep -i -A30 "oom\|out of memory\|kill process"

# Typical OOM log:
# [12345.678] kworker invoked oom-killer: gfp_mask=0x...
# [12345.679] Mem-Info:
# [12345.680] active_anon:500MB inactive_anon:100MB ...
# [12345.681] [ pid ]  uid  tgid total_vm      rss pgtables_bytes swapents oom_score_adj name
# [12345.682] [  1234]    0  1234   500000   400000        1234567        0          0 fio
# [12345.683] Out of memory: Killed process 1234 (fio) total-vm:2000MB, anon-rss:1600MB

# Live OOM monitoring:
/usr/share/bcc/tools/oomkill

# BPF: trace OOM kill events:
bpftrace -e '
kprobe:oom_kill_process {
    printf("OOM kill: victim=%s\n",
           ((struct task_struct *)arg1)->comm);
}
'
```

---

## 6. Hands-On Exercises

```bash
# --- Observe OOM scoring ---
# Find which processes have non-zero oom_score_adj:
grep -r "." /proc/*/oom_score_adj 2>/dev/null \
    | awk -F'/' '{print $3, $NF}' \
    | while read pid adj; do
        comm=$(cat /proc/$pid/comm 2>/dev/null)
        echo "adj=$adj pid=$pid $comm"
      done | grep -v "adj=0" | sort -t= -k2 -n

# --- Simulate OOM (in a VM!) ---
# Disable swap to make OOM happen faster:
swapoff -a

# Set overcommit=1 (always succeed):
sysctl -w vm.overcommit_memory=1

# Trigger OOM:
python3 -c "
import ctypes
chunks = []
try:
    while True:
        chunks.append(ctypes.create_string_buffer(10 * 1024 * 1024))  # 10MB
        print(f'Allocated {len(chunks) * 10}MB')
except MemoryError:
    print('MemoryError')
"

# Watch dmesg:
dmesg | tail -50 | grep -i oom

# --- Check memory commitment ---
cat /proc/meminfo | grep -E 'CommitLimit|Committed_AS'
# If Committed_AS > CommitLimit: you're overcommitted
# (normal for mode=0 or mode=1; dangerous for mode=2)
```

---

## 7. Key Source Files

```
mm/oom_kill.c           — out_of_memory(), oom_badness(), oom_kill_process()
mm/page_alloc.c         — __alloc_pages_may_oom()
mm/mmap.c               — vm_mmap(): overcommit check
mm/util.c               — __vm_enough_memory(): overcommit accounting
include/linux/oom.h     — OOM_SCORE_ADJ_MIN/MAX constants
```

---

## 8. Self-Check Questions

1. Process A uses 8GB RSS, process B uses 2GB RSS but has `oom_score_adj=+500`. System has 10GB total RAM. Which process does the OOM killer choose? Show the calculation.

2. A Ceph OSD is OOM-killed during a recovery operation. The system had 5% free memory. Why did OOM trigger before memory was fully exhausted? (Hint: zone watermarks)

3. `overcommit_memory=2` and `overcommit_ratio=50`. Server has 128GB RAM and 64GB swap. What is `CommitLimit`? A process tries to `mmap(150GB)`. What happens?

4. systemd sets `OOMScoreAdjust=-900` for a storage service. The OOM killer runs. Under what conditions could this service still be killed despite the protection?

5. After an OOM kill, the surviving processes still have high RSS. Memory is still tight. Why doesn't OOM immediately kill again? What condition must be met before OOM triggers a second time?

---

## Tomorrow: Day 20 — Memory Pressure Profiling: Full Diagnostic Workflow
