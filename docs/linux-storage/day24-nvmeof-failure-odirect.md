# Day 24: NVMe-oF Failure Handling, Multipathing & Direct I/O Gap-Fill

## Context
Two topics today: NVMe-oF failure handling (new material) and a targeted
gap-fill on O_DIRECT kernel path (you know it from BlueStore — this confirms
source-level understanding of what BlueStore bypasses and why).

---

## Part A: NVMe-oF Failure Handling & Multipathing

### Learning Objectives
- Understand NVMe-oF reconnect behavior and timeout parameters
- Simulate path failure and observe kernel response
- Design a resilient NVMe-oF multipath architecture using ANA
- Know the failure modes that NVMe-oF does NOT handle automatically

---

## A.1. Failure Detection and Reconnect

When an NVMe-oF path fails, the host driver detects it via:

```
Detection mechanisms:
  1. Keep-alive timeout (KATO): host sends NVMe KEEP_ALIVE commands
     If no response within KATO period → path failure assumed
     Default KATO: 10 seconds (configurable)

  2. TCP connection reset: TCP RST or FIN → immediate failure detection
     (faster than KATO — happens within TCP timeout, usually seconds)

  3. I/O timeout: pending commands exceed timeout → mark path failed
```

```c
// drivers/nvme/host/core.c

nvme_timeout():
    // Called when a command exceeds timeout
    // Actions:
    //   1. Reset the controller (send NVMe reset)
    //   2. If reset fails → mark controller as failed
    //   3. Trigger reconnect (for fabrics)
    //   4. Mark in-flight requests as failed → return error to caller

// drivers/nvme/host/fabrics.c
nvmf_reconnect_or_remove():
    // Called when a fabric controller fails
    // Attempt reconnect loop:
    //   - Exponential backoff: 1s, 2s, 4s, ... up to ctrl_loss_tmo
    //   - If reconnect succeeds: resubmit queued I/Os
    //   - If ctrl_loss_tmo exceeded: remove controller, fail all I/Os
```

```bash
# Key timeout parameters (set at connect time)
nvme connect -t tcp -a 192.168.1.10 -s 4420 -n testnqn \
    --keep-alive-tmo=5 \     # KATO: 5 seconds
    --reconnect-delay=10 \   # wait between reconnect attempts
    --ctrl-loss-tmo=60       # give up after 60 seconds of failed reconnects

# View current timeout settings
cat /sys/class/nvme/nvme1/keep_alive_tmo
cat /sys/class/nvme/nvme1/reconnect_delay
cat /sys/class/nvme/nvme1/ctrl_loss_tmo

# Monitor controller state
watch -n1 "cat /sys/class/nvme/nvme1/state"
# States: new → connecting → live → resetting → reconnecting → deleting
```

---

## A.2. Simulating Path Failure

```bash
# Setup: two paths to same namespace (simulate with two TCP connections)
# Path 1: primary (localhost)
nvme connect -t tcp -a 127.0.0.1 -s 4420 -n testnqn --ctrl-loss-tmo=30

# Path 2: secondary (simulate with different port or second target)
# In real setups: two storage controllers, two network paths

# Check both paths
nvme list-subsys
# Should show: testnqn with two paths (nvme1, nvme2)

# Simulate path failure (kill target TCP listener)
# Method 1: Block the port with iptables
iptables -A INPUT -p tcp --dport 4420 -j DROP

# Observe reconnect behavior
watch -n0.5 "cat /sys/class/nvme/nvme1/state; \
             nvme list-subsys 2>/dev/null | head -10"

# I/O should fail over to second path (if ANA multipath configured)
# or return errors (if single path)

# Restore connectivity
iptables -D INPUT -p tcp --dport 4420 -j DROP

# Observe reconnect
# State transitions: live → resetting → reconnecting → live
```

---

## A.3. ANA Path Selection Logic

```c
// drivers/nvme/host/multipath.c

nvme_path_is_optimized():
    // Returns true if path has ANA_OPTIMIZED state for this namespace

nvme_round_robin_path():
    // Select path for I/O:
    // 1. Filter: only OPTIMIZED paths (if any available)
    // 2. Round-robin across OPTIMIZED paths
    // 3. If no OPTIMIZED paths: use NON_OPTIMIZED (failover)
    // 4. If no accessible paths: return error

// The /dev/nvmeXnY device the application sees is a multipath device
// Actual I/O is dispatched to one of the underlying paths
```

```bash
# ANA multipath device
# Application uses: /dev/nvme0n1 (the multipath namespace)
# Underlying paths: /dev/nvme0c0n1, /dev/nvme0c1n1 (per-controller)

# Check ANA groups and states
nvme ana-log /dev/nvme0
# Shows: group ID, state, namespace IDs in each group

# Force path selection (testing)
echo "round-robin" > /sys/block/nvme0n1/queue/io_policy
# Or use native NVMe multipath (nvme_core.multipath=1)
```

---

## A.4. Failure Modes NVMe-oF Does NOT Handle

Architects must know the limits:

```
Handled automatically:
  ✓ Network path failure (TCP disconnect, RDMA link down)
  ✓ Target controller restart (if within ctrl_loss_tmo)
  ✓ ANA failover to non-optimized path
  ✓ Reconnect after transient failure

NOT handled automatically:
  ✗ Namespace data corruption (NVMe-oF has no end-to-end checksums by default)
  ✗ Target storage failure (if NVMe device on target fails, namespace fails)
  ✗ Simultaneous loss of all paths (application sees I/O errors)
  ✗ I/O ordering guarantees across paths (application must use barriers)
  ✗ Write fencing (two hosts writing same namespace — no SCSI-style reservations
    in base NVMe spec; NVMe-oF reservations are optional feature)
```

---

## A.5. Resilient NVMe-oF Architecture

```
Recommended production NVMe-oF HA architecture:

Storage node A (controller A):
  12× NVMe → exports namespaces 1-4 as ANA_OPTIMIZED
              exports namespaces 5-8 as ANA_NON_OPTIMIZED

Storage node B (controller B):
  12× NVMe → exports namespaces 5-8 as ANA_OPTIMIZED
              exports namespaces 1-4 as ANA_NON_OPTIMIZED

Compute node (host):
  Path 1: NIC 0 → switch A → node A (primary for ns 1-4)
  Path 2: NIC 1 → switch B → node B (primary for ns 5-8)

Failure scenarios:
  Node A network failure: traffic failovers to node B via NON_OPTIMIZED
  Node A storage failure: namespace fails (need storage-level RAID on node A)
  Both paths to node A fail: failover to node B
  Both nodes fail: data unavailable (no NVMe-oF magic here — needs storage HA)
```

---

## Part B: O_DIRECT Path — Gap-Fill

### Context
You know O_DIRECT from BlueStore. This section confirms the kernel-level
path and identifies the specific overheads it eliminates (and those it doesn't).

---

## B.1. What O_DIRECT Bypasses

```
Normal buffered I/O path:
  write() → page cache → writeback → block layer → device

O_DIRECT path:
  write() → alignment check → iomap_direct_rw() → block layer → device
            ↑ page cache COMPLETELY bypassed

What O_DIRECT eliminates:
  ✓ Page cache allocation/management
  ✓ Dirty page tracking and writeback
  ✓ Page cache eviction pressure
  ✓ Copy from page cache to user buffer (one fewer memcpy on read)

What O_DIRECT does NOT eliminate:
  ✗ blk-mq overhead (still goes through block layer)
  ✗ I/O scheduler (still subject to scheduling if not 'none')
  ✗ DMA — still uses DMA, not zero-copy in the RDMA sense
  ✗ System call overhead
```

---

## B.2. Alignment Requirements

```c
// fs/direct-io.c / fs/iomap/direct-io.c

// O_DIRECT requires:
//   buffer address: aligned to logical block size (usually 512B or 4096B)
//   file offset: aligned to logical block size
//   transfer size: multiple of logical block size

// Check alignment:
blksize = bdev_logical_block_size(bdev);  // 512 or 4096

if (!IS_ALIGNED(offset, blksize) ||
    !IS_ALIGNED(count, blksize) ||
    !IS_ALIGNED((unsigned long)buf, blksize))
    return -EINVAL;
```

```bash
# Check logical block size for a device
cat /sys/block/nvme0n1/queue/logical_block_size    # 512 or 4096
cat /sys/block/nvme0n1/queue/physical_block_size   # usually 4096

# O_DIRECT with misaligned buffer → EINVAL
# BlueStore uses posix_memalign() to ensure alignment
```

---

## B.3. O_DIRECT vs io_uring: What io_uring Adds

This bridges to Day 25:

```
O_DIRECT:
  - Bypasses page cache
  - Still uses synchronous syscall (blocks until I/O completes, or uses libaio)
  - Each I/O: syscall + kernel processing + wait

io_uring + O_DIRECT equivalent:
  - Bypasses page cache (via IORING_OP_READ/WRITE with O_DIRECT fd)
  - Async: submits to SQ ring, completion via CQ ring (no blocking syscall per I/O)
  - Batches: multiple I/Os submitted per syscall (io_uring_enter)
  - Fixed buffers: eliminates per-I/O buffer mapping (major overhead)

The fixed buffer advantage (covered in depth Day 25):
  O_DIRECT with libaio: each I/O → kernel maps user buffer → DMA → unmap
  io_uring fixed buffers: buffers pre-registered → no per-I/O mapping cost
  At 500K IOPS: buffer mapping = major CPU overhead → fixed buffers = significant win
```

---

## C. Self-Check Questions

1. What is the NVMe keep-alive timeout (KATO) and what happens when it expires?
2. What is `ctrl_loss_tmo` and what happens to in-flight I/Os when it expires?
3. In ANA multipathing, what determines which path is used for I/O to a specific namespace?
4. Why doesn't NVMe-oF solve the "two hosts writing the same namespace" problem by default?
5. O_DIRECT bypasses the page cache. Does it also bypass the I/O scheduler? Does it eliminate DMA?
6. What alignment requirement must a buffer meet for O_DIRECT, and what happens if it's violated?

## D. Answers

1. KATO is a periodic command the host sends to the target to verify the connection is alive. If the target doesn't respond within the KATO window, the host assumes the path has failed and begins reconnect attempts. Default: 10 seconds. Set lower for faster failure detection (at cost of more background traffic).
2. `ctrl_loss_tmo` is the maximum time the driver will attempt to reconnect after a failure. If reconnect doesn't succeed within this window, the driver gives up, removes the controller, and fails all pending I/Os with an error. Applications see I/O errors. Set based on your RTO: longer tmo = more time for storage to recover; shorter = faster application-level failover.
3. The kernel's nvme multipath selects paths with `ANA_OPTIMIZED` state first, round-robin if multiple. Falls back to `ANA_NON_OPTIMIZED` only if no optimized paths are available. The ANA state is set by the storage controller and reflects whether that controller has direct access to the namespace's physical storage.
4. NVMe base spec has no mandatory write exclusion between hosts. SCSI had SCSI reservations for this. NVMe-oF has an optional "Reservations" feature (ONCS bit in id-ctrl), but it must be explicitly implemented and used. Without reservations, two hosts writing the same namespace will corrupt each other's data silently.
5. O_DIRECT does NOT bypass the I/O scheduler — requests still go through blk-mq and any configured scheduler (though with `none` scheduler on NVMe, this is near-zero overhead). DMA is still used — data moves between device and memory via DMA. What changes is that the user buffer is mapped for DMA directly instead of going through the page cache.
6. Buffer address, file offset, and transfer size must all be aligned to the device's logical block size (typically 512B or 4096B). Violation returns `EINVAL` — the system call fails immediately without attempting any I/O. BlueStore handles this by allocating all buffers with `posix_memalign(4096)`.

---

## Tomorrow: Day 25 — io_uring Deep Dive: Fixed Buffers, Registered Files & NVMe Passthrough

We go from blog-level io_uring knowledge to source-level: the SQ/CQ ring
mechanics, fixed buffer registration, and io_uring + NVMe passthrough
(`uring_cmd`) — the highest-performance kernel I/O path available today.
