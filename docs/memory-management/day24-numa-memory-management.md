# Day 24: NUMA Memory Management

## Learning Objectives
- Understand NUMA memory policies and when each applies
- Use numactl and numastat to diagnose NUMA-related storage performance issues
- Understand NUMA balancing and its interaction with storage workloads
- Design NUMA-aware storage systems: NVMe affinity, DMA locality

---

## 1. NUMA Memory Policies

The kernel offers four memory allocation policies per-process or per-VMA:

```c
// include/uapi/linux/mempolicy.h
MPOL_DEFAULT        // allocate on the node of the CPU running the allocation
MPOL_BIND           // only allocate from specified nodeset; fail if unavailable
MPOL_PREFERRED      // prefer specified node; fall back to others if needed
MPOL_INTERLEAVE     // round-robin across nodeset (good for throughput)
MPOL_LOCAL          // always use local node (same as DEFAULT effectively)
```

### Setting Policies

```bash
# numactl: set policy for a command:
numactl --cpunodebind=0 --membind=0 ./storage_benchmark   # local only
numactl --interleave=all ./memory_intensive_workload       # striped
numactl --preferred=0 --cpunodebind=0,1 ./mixed_workload  # prefer node0

# Per-process policy (current shell):
numactl --show    # show current policy

# mbind(): per-VMA policy in code:
#include <numaif.h>
mbind(addr, length, MPOL_BIND, nodemask, maxnode, flags);
```

---

## 2. NUMA Balancing

NUMA balancing automatically migrates pages to the NUMA node that accesses them most frequently.

```bash
# Check status:
cat /proc/sys/kernel/numa_balancing   # 1=enabled, 0=disabled

# How it works:
# 1. Kernel periodically unmaps pages (sets PTE to PROT_NONE temporarily)
# 2. On next access: fault → kernel records which CPU faulted it
# 3. If CPU is on different node than page: schedule page migration
# 4. migrate_pages() moves page to faulting CPU's node
```

### When to DISABLE NUMA Balancing for Storage

```bash
# Disable NUMA balancing for storage workloads with pinned processes:
echo 0 > /proc/sys/kernel/numa_balancing

# Why disable for storage?
# 1. Periodic PROT_NONE faults add latency noise to I/O path
# 2. Storage processes that ARE correctly pinned don't benefit from migration
# 3. Page migration itself causes TLB shootdowns (latency)
# 4. For NVMe-bound workloads, DMA locality is set at queue setup time;
#    migrating application pages doesn't change DMA locality

# Make persistent:
echo "kernel.numa_balancing=0" >> /etc/sysctl.conf
```

---

## 3. numastat: Diagnosing NUMA Performance

```bash
# Overall NUMA stats:
numastat
# Per-node:
#                           node0           node1
# numa_hit               10000000         5000000  ← allocated on correct node
# numa_miss               2000000         3000000  ← allocated on wrong node (slow!)
# numa_foreign            3000000         2000000  ← allocated for another node
# interleave_hit           100000          100000
# local_node             10000000         5000000  ← local allocation
# other_node              2000000         3000000  ← remote allocation

# High numa_miss = processes allocating memory on wrong NUMA node
# This means their memory accesses cross the QPI/UPI interconnect

# Per-process NUMA stats:
numastat -p $(pidof fio)
numastat -p $(pidof mysqld)

# Per-node memory distribution:
numastat -m
# Shows: MemTotal, MemFree, FilePages, AnonPages per NUMA node

# Memory usage of a process per node:
cat /proc/$(pidof mysqld)/numa_maps | head -20
# Format: VA  policy  N0=pages N1=pages  anon/file  [path]
```

---

## 4. NVMe NUMA Affinity

NVMe controllers are attached to specific PCIe root complexes, which are NUMA-local to one CPU socket.

```bash
# Find which NUMA node your NVMe is on:
cat /sys/block/nvme0n1/device/numa_node
# Returns: 0 (node 0) or 1 (node 1) or -1 (unknown)

# Verify via PCI device:
lspci -d ::0108 -v | grep -E "NVMe|NUMA|Node"
# Check the PCIe slot NUMA affinity:
cat /sys/bus/pci/devices/$(lspci -d ::0108 | head -1 | awk '{print $1}')/numa_node

# Run storage benchmark on the correct NUMA node:
NVME_NODE=$(cat /sys/block/nvme0n1/device/numa_node)
numactl --cpunodebind=$NVME_NODE --membind=$NVME_NODE \
    fio --name=numa_local --rw=randread --bs=4k --size=10G \
    --filename=/dev/nvme0n1 --direct=1 --numjobs=8

# Compare with WRONG node:
WRONG_NODE=$([ $NVME_NODE -eq 0 ] && echo 1 || echo 0)
numactl --cpunodebind=$WRONG_NODE --membind=$WRONG_NODE \
    fio --name=numa_remote --rw=randread --bs=4k --size=10G \
    --filename=/dev/nvme0n1 --direct=1 --numjobs=8

# Throughput difference: typically 5-20% on modern servers
# Latency difference: more pronounced at high queue depths
```

---

## 5. NUMA-Aware NVMe Queue Setup

The NVMe driver creates one I/O queue per CPU. For NUMA-optimal performance, queue memory should be allocated on the same node as the CPU that owns the queue:

```bash
# Check NVMe queue affinity (kernel does this automatically):
cat /sys/block/nvme0n1/mq/*/cpu_list
# Should show CPUs local to the NVMe's NUMA node getting primary queues

# NVMe driver NUMA-aware queue allocation (source):
# drivers/nvme/host/pci.c: nvme_alloc_queue()
# → uses dev_to_node(dev) to allocate queue memory on device's node
# → dma_alloc_coherent() places SQ/CQ on device's NUMA node

# Verify interrupt affinity:
cat /proc/interrupts | grep nvme | head -8
# IRQs should be handled by CPUs on the NVMe's NUMA node
```

---

## 6. Hands-On Exercises

```bash
# --- NUMA topology inspection ---
numactl --hardware
cat /sys/devices/system/node/node*/distance   # NUMA distances

# --- Diagnose NUMA miss ---
# Run fio on wrong NUMA node intentionally:
NVME_NODE=$(cat /sys/block/nvme0n1/device/numa_node 2>/dev/null || echo 0)
WRONG_NODE=$([ $NVME_NODE -eq 0 ] && echo 1 || echo 0)

# Reset stats:
echo 0 > /proc/sys/vm/numa_stat  # (if available, kernel 5.4+)

# Run misaligned workload:
numactl --cpunodebind=$WRONG_NODE --membind=$WRONG_NODE \
    fio --name=wrong_numa --rw=randread --bs=64k \
    --filename=/tmp/test.dat --size=4G --direct=0 \
    --numjobs=4 --runtime=15 &

# Watch NUMA misses accumulate:
watch -n1 'numastat | grep -E "numa_miss|numa_hit"'
wait

# --- Correct NUMA alignment ---
numactl --cpunodebind=$NVME_NODE --membind=$NVME_NODE \
    fio --name=right_numa --rw=randread --bs=64k \
    --filename=/tmp/test.dat --size=4G --direct=0 \
    --numjobs=4 --runtime=15

# Compare latency and throughput

# --- numa_maps: per-process NUMA page distribution ---
cat /proc/$$/numa_maps | head -20
# See which nodes your process's memory is on
```

---

## 7. Key Source Files

```
mm/mempolicy.c          — do_mbind(), mpol_new(), NUMA policy implementation
kernel/sched/topology.c — NUMA topology detection
mm/migrate.c            — migrate_pages(): NUMA page migration
include/uapi/linux/mempolicy.h — MPOL_* constants
drivers/nvme/host/pci.c — NUMA-aware queue allocation (nvme_alloc_queue)
```

---

## 8. Self-Check Questions

1. A 2-socket server has NVMe on socket 0. Threads run on socket 1. `numastat -p fio` shows 90% of pages on node 1. `numastat` shows high `numa_miss`. Explain the exact performance penalty. What is the QPI/UPI bandwidth limit that bounds the miss penalty?

2. NUMA balancing is enabled. It periodically sets a page's PTE to `PROT_NONE`. The NVMe driver's interrupt handler accesses this page. What happens? Why is this a problem?

3. `numactl --interleave=all` is set for a database process. Its 100GB buffer pool is striped across node 0 and node 1. What is the expected memory bandwidth improvement vs node-local? When does interleave NOT help?

4. An NVMe SSD is on NUMA node 1. `dma_alloc_coherent()` is called during queue setup without specifying a node. Which node does the DMA memory land on? Is this optimal? How does the kernel choose?

5. `MPOL_BIND` is set to node 0 for a process on a 2-socket server. Node 0 runs out of free memory. What happens to the next `malloc()` call? How does this differ from `MPOL_PREFERRED`?

---

## Tomorrow: Day 25 — Memory cgroups: Container Storage Performance
