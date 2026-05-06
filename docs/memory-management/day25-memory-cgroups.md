# Day 25: Memory cgroups — Container Storage Performance

## Learning Objectives
- Understand cgroup v2 memory controller: limits, protection, soft limits
- Trace why container memory limits degrade storage I/O performance
- Use memory.stat and memory.events to diagnose container memory issues
- Design correct memory limits for storage-intensive containers

---

## 1. cgroup v2 Memory Controller Interface

```bash
# Memory cgroup knobs (cgroup v2):
memory.max          # hard limit: OOM kill when exceeded
memory.high         # soft limit: aggressive reclaim above this level
memory.low          # protection: kernel avoids reclaiming below this
memory.min          # hard protection: never reclaim below this
memory.swap.max     # swap limit for this cgroup
memory.current      # current memory usage
memory.stat         # detailed breakdown
memory.events       # OOM events, high events count
memory.pressure     # PSI pressure for this cgroup
```

---

## 2. How Limits Affect Page Cache

This is the most important concept for storage architects working with containers:

```
Container with memory.max=4G running database:

Database reads 20GB of data files
    → filemap_fault() → page cache miss → read from NVMe
    → pages added to page cache: 4GB used... 4GB used...
    → memory.max=4G HIT
    → mem_cgroup_charge() fails
    → kernel must reclaim WITHIN the cgroup before retrying
    → reclaim evicts page cache pages from THIS cgroup
    → next database read = another major fault

Result:
    - Cache hit rate: near 0% despite host having 200GB free
    - Every DB read = NVMe I/O (100μs) instead of RAM access (100ns)
    - 1000× performance degradation
    - Host RAM shows 190GB free — wasted
```

```c
// mm/memcontrol.c — charge path:
int mem_cgroup_charge(struct folio *folio, struct mm_struct *mm, gfp_t gfp)
{
    // Find the memory cgroup for this allocation:
    memcg = get_mem_cgroup_from_mm(mm);

    // Check limits:
    ret = mem_cgroup_try_charge(folio, memcg, gfp);
    // → checks memory.max: if exceeded, trigger reclaim within cgroup
    // → checks memory.high: if exceeded, throttle allocation rate
    // → system memory may be plentiful, but cgroup reclaims anyway!
}
```

---

## 3. memory.low: Protecting Cache

`memory.low` tells the kernel to protect a cgroup's pages from global reclaim:

```bash
# Example: database container needs 8GB for its working set
echo "8G" > /sys/fs/cgroup/database/memory.low

# With memory.low=8G:
# - If container uses < 8GB: kswapd will NOT reclaim these pages
#   even if the rest of the system is under pressure
# - The 8GB acts as a "reserved" cache allocation
# - Container's page cache is protected up to this level

# memory.min: even stronger — prevents reclaim even during global OOM
echo "4G" > /sys/fs/cgroup/database/memory.min
```

---

## 4. Reading memory.stat and memory.events

```bash
# Current memory usage:
cat /sys/fs/cgroup/mycontainer/memory.current

# Detailed breakdown:
cat /sys/fs/cgroup/mycontainer/memory.stat
# anon       3221225472  ← anonymous pages (heap, stack) in bytes
# file       8589934592  ← file-backed pages (page cache) in bytes
# kernel     104857600   ← kernel memory (slab, stack, etc.)
# slab       52428800    ← slab allocations
# sock       1048576     ← socket buffers
# dirty      524288      ← dirty pages in this cgroup
# writeback  0           ← pages being written back
# pgfault    1234567     ← total page faults
# pgmajfault 45678       ← major faults (WATCH THIS: = NVMe reads)
# inactive_anon  512MB  ← swap candidates
# active_file    8GB    ← page cache in active LRU
# inactive_file  512MB  ← page cache eviction candidates

# OOM and limit events:
cat /sys/fs/cgroup/mycontainer/memory.events
# low        0           ← times low limit was crossed
# high       1234        ← times HIGH limit triggered throttling (watch this!)
# max        0           ← times MAX limit triggered
# oom        0           ← OOM kill count
# oom_kill   0           ← processes killed by OOM in this cgroup

# PSI within container:
cat /sys/fs/cgroup/mycontainer/memory.pressure
# some avg10=15.23 ...   ← high = container is memory-constrained
```

---

## 5. Hands-On Exercises

```bash
# --- Create memory-limited cgroup ---
mkdir /sys/fs/cgroup/storage-test
echo "512M" > /sys/fs/cgroup/storage-test/memory.max
echo "256M" > /sys/fs/cgroup/storage-test/memory.high
echo "128M" > /sys/fs/cgroup/storage-test/memory.low

# Add current shell to cgroup:
echo $$ > /sys/fs/cgroup/storage-test/cgroup.procs

# --- Observe cache thrashing ---
# Create large test file (larger than memory.max):
dd if=/dev/urandom of=/tmp/big_test bs=1M count=1024 2>/dev/null

# Monitor events in another terminal:
watch -n1 'cat /sys/fs/cgroup/storage-test/memory.events
           cat /sys/fs/cgroup/storage-test/memory.stat | grep -E "file|pgmajfault|high"'

# Read the file repeatedly (should cause cache thrashing):
for i in 1 2 3; do
    echo "Pass $i:"
    time cat /tmp/big_test > /dev/null
    cat /sys/fs/cgroup/storage-test/memory.events | grep high
done

# Compare: without cgroup limit (exit cgroup first):
echo $$ > /sys/fs/cgroup/cgroup.procs   # back to root cgroup
time cat /tmp/big_test > /dev/null      # should be much faster second time

# --- Fix with memory.low ---
echo $$ > /sys/fs/cgroup/storage-test/cgroup.procs
echo "450M" > /sys/fs/cgroup/storage-test/memory.low
# Now the first 450MB of cache is protected

# --- Monitor per-cgroup I/O correlation ---
# I/O events from within the cgroup:
cat /sys/fs/cgroup/storage-test/io.stat
# Format: major:minor rbytes=N wbytes=N rios=N wios=N ...
# rbytes growing = page cache misses causing reads

# PSI: memory pressure within container:
cat /sys/fs/cgroup/storage-test/memory.pressure
```

---

## 6. Designing Container Memory Limits

```bash
# Framework for storage-intensive containers:

# 1. Profile the working set:
#    Run workload without limits; observe memory.stat 'file' field at peak
#    This is your minimum memory.low value

# 2. Set memory.low to protect working set:
echo "${WORKING_SET_BYTES}" > memory.low

# 3. Set memory.max to leave headroom above working set:
echo "${WORKING_SET_BYTES * 1.5}" > memory.max

# 4. Set memory.high to trigger early reclaim (avoid hitting max):
echo "${WORKING_SET_BYTES * 1.2}" > memory.high

# 5. Monitor memory.events high counter:
#    If high > 0: container is reclaiming → investigate if working set is too large
#    If oom > 0: container is OOM killing → memory.max too small

# Example for a database container with 10GB working set:
echo "10G" > memory.low     # protect 10GB cache
echo "16G" > memory.high    # soft limit
echo "20G" > memory.max     # hard limit

# io.latency: protect I/O latency within cgroup (cgroup v2):
echo "8:0 target=10000" > io.latency   # 10ms target latency for device 8:0
```

---

## 7. Key Source Files

```
mm/memcontrol.c         — mem_cgroup_charge(), memory limit checking
mm/vmscan.c             — cgroup-aware reclaim: shrink_node_memcgs()
kernel/cgroup/cgroup.c  — cgroup hierarchy management
include/linux/memcontrol.h — mem_cgroup struct
Documentation/admin-guide/cgroup-v2.rst — official reference
```

---

## 8. Self-Check Questions

1. Container has `memory.max=2G`. It reads a 10GB database file. The host has 100GB free. Explain step-by-step why performance is terrible. What does `pgmajfault` in `memory.stat` show?

2. `memory.low=8G` is set for a database container. The host is under global memory pressure (kswapd running). The container has 8GB of page cache. Does kswapd evict it? Explain using the reclaim path in `mm/vmscan.c`.

3. `memory.events` shows `high=50000` over 1 hour. What is happening 50,000 times? Is this a problem? What does it mean for I/O latency?

4. A container has `memory.max=4G` and `memory.swap.max=0`. The container's anonymous memory grows to 4GB. It then tries to allocate 100MB more. What happens?

5. You have a storage cluster where each Ceph OSD runs in a container. What values would you set for `memory.low`, `memory.high`, and `memory.max` relative to the OSD's configured `osd_memory_target`?

---

## Tomorrow: Day 26 — mlock, madvise & Memory Pinning
