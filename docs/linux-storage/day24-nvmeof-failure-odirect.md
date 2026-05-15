# Day 24: NVMe-oF Failure Handling, Multipathing & O_DIRECT Gap-Fill

## Context
Two topics today: NVMe-oF failure handling (new material) and a targeted
gap-fill on the O_DIRECT kernel path. You know O_DIRECT from BlueStore;
this confirms source-level understanding of what BlueStore bypasses
and what costs remain even with O_DIRECT.

---

## Part A: NVMe-oF Failure Handling & Multipathing

### Learning Objectives
- Understand NVMe-oF reconnect behavior and timeout parameters
- Simulate path failure and observe kernel response
- Understand ANA path selection in detail
- Design a resilient NVMe-oF multipath architecture
- Know the failure modes that NVMe-oF does NOT handle automatically

---

## A.1. Failure Detection Mechanisms

When an NVMe-oF path fails, the host driver detects it via three
mechanisms:

```
Detection mechanisms (any one triggers failure handling):

  1. Keep-alive timeout (KATO):
     Host periodically sends NVMe KEEP_ALIVE admin commands.
     If no response within the KATO window → path failure assumed.
     Default KATO: 10 seconds (configurable per controller).

  2. Transport-level disconnect:
     TCP RST or FIN → immediate failure detection.
     (Often faster than KATO — happens within seconds.)
     RDMA: link down event from the RDMA layer.

  3. I/O timeout:
     Pending I/O command exceeds io_timeout (default 30s).
     → controller reset → reconnect path.
```

```c
// drivers/nvme/host/core.c

nvme_timeout():
    // Called by blk-mq when a command exceeds its timeout
    // Actions, in order:
    //   1. Try to abort the specific command (controller may not support)
    //   2. If abort fails or unsupported: reset the controller
    //   3. If reset fails: mark controller as failed
    //   4. For fabric controllers: trigger reconnect
    //   5. Fail in-flight requests on this queue with -EIO

// drivers/nvme/host/fabrics.c
nvme_fabrics_reconnect_or_remove():
    // Called when a fabric controller fails
    // Reconnect loop with exponential backoff:
    //   delay = reconnect_delay (default 10s)
    //   On each failure: retry up to ctrl_loss_tmo elapsed
    //   On success: resubmit queued I/Os
    //   On giving up (ctrl_loss_tmo exceeded): remove controller,
    //     fail all pending I/Os with -EIO
```

```bash
# Key timeout parameters (set at connect time)
nvme connect -t tcp -a 192.168.1.10 -s 4420 -n testnqn \
    --keep-alive-tmo=5 \      # KATO: 5 seconds
    --reconnect-delay=10 \    # wait between reconnect attempts
    --ctrl-loss-tmo=60        # give up after 60 seconds total

# View current settings
cat /sys/class/nvme/nvme1/keep_alive_tmo      # in ms
cat /sys/class/nvme/nvme1/reconnect_delay
cat /sys/class/nvme/nvme1/ctrl_loss_tmo

# Monitor controller state in real time
watch -n0.5 "cat /sys/class/nvme/nvme1/state"
# States: new → connecting → live → resetting → reconnecting → deleting
```

**Tuning the timeouts:**
- Lower KATO (e.g., 5s) → faster failure detection, slightly more background traffic
- Lower `ctrl_loss_tmo` → faster application-visible failure (don't wait 10 min)
- These are application-RTO levers. Match them to your SLA.

---

## A.2. Simulating Path Failure

```bash
# Setup: a connected NVMe-oF/TCP device on 127.0.0.1:4420
nvme connect -t tcp -a 127.0.0.1 -s 4420 -n testnqn \
    --ctrl-loss-tmo=30 --keep-alive-tmo=5

# Verify connected
nvme list-subsys
cat /sys/class/nvme/nvme1/state    # "live"

# Start a small workload in the background
fio --name=load --filename=/dev/nvme1n1 --rw=randread --bs=4k \
    --ioengine=libaio --iodepth=4 --time_based --runtime=120 &

# Simulate target-side failure: block the port with iptables
iptables -A INPUT  -p tcp --dport 4420 -j DROP
iptables -A OUTPUT -p tcp --sport 4420 -j DROP

# Observe state transitions
for i in $(seq 1 30); do
    echo "$(date +%T) state=$(cat /sys/class/nvme/nvme1/state)"
    sleep 2
done
# Expect: live → resetting → connecting → connecting ... until reconnect or timeout

# Restore connectivity
iptables -D INPUT  -p tcp --dport 4420 -j DROP
iptables -D OUTPUT -p tcp --sport 4420 -j DROP

# Watch reconnect
# State transitions: connecting → live (within reconnect_delay window)

# Cleanup
kill %1 2>/dev/null
```

What this demonstrates:
- The kernel doesn't immediately fail I/Os on path loss — it queues them
- I/Os complete with -EIO only after `ctrl_loss_tmo` if reconnect fails
- Applications see the path loss as elevated latency, not immediate error
  (during the reconnect window)

---

## A.3. ANA: Asymmetric Namespace Access

ANA is NVMe-oF's multipathing mechanism. Each namespace can be accessed
through multiple paths, with different access states per path:

```
ANA states (NVMe spec):
  ANA_OPTIMIZED      — preferred path (direct local access on target)
  ANA_NON_OPTIMIZED  — works but suboptimal (cross-controller access)
  ANA_INACCESSIBLE   — path is down, don't use
  ANA_PERSISTENT_LOSS — path permanently gone
  ANA_CHANGE         — transitioning to new state
```

```
Example: active/passive HA storage array

  Controller A (target) → nvme0 on host
                          ns 1-4: ANA_OPTIMIZED
                          ns 5-8: ANA_NON_OPTIMIZED (proxied via A→B)
  
  Controller B (target) → nvme1 on host
                          ns 1-4: ANA_NON_OPTIMIZED (proxied via B→A)
                          ns 5-8: ANA_OPTIMIZED

  For ns 1-4: I/O via nvme0 = direct. Via nvme1 = controller A→B hop.
  When controller A fails: ns 1-4 paths via nvme1 transition from
  NON_OPTIMIZED to OPTIMIZED (since they're the only path).
```

```c
// drivers/nvme/host/multipath.c

nvme_round_robin_path():
    // Path selection for I/O:
    // 1. Filter: only OPTIMIZED paths (if any available)
    // 2. Round-robin (or queue-depth/numa policy) across OPTIMIZED paths
    // 3. If no OPTIMIZED paths: fall back to NON_OPTIMIZED
    // 4. If no accessible paths: return error to caller
```

```bash
# View ANA state from host
nvme ana-log /dev/nvme0
# Lists ANA groups and their state for each namespace

# List all paths to a subsystem
nvme list-subsys
# nvme-subsys0 - NQN=...
#  +- nvme0 tcp traddr=10.0.0.1 trsvcid=4420 live optimized
#  +- nvme1 tcp traddr=10.0.0.2 trsvcid=4420 live non-optimized

# Native NVMe multipath status
cat /sys/module/nvme_core/parameters/multipath
# "Y" = native multipath enabled (default in most modern distros)

# Path selection policy (kernel 5.0+)
cat /sys/class/nvme-subsystem/nvme-subsys0/iopolicy
# "numa" (default) | "round-robin" | "queue-depth"
echo round-robin > /sys/class/nvme-subsystem/nvme-subsys0/iopolicy
```

---

## A.4. Failure Modes NVMe-oF Does NOT Handle

```
Handled automatically:
  ✓ Single network path failure (TCP disconnect, RDMA link down)
  ✓ Target controller restart (if within ctrl_loss_tmo)
  ✓ ANA failover to non-optimized path
  ✓ Reconnect after transient failure

NOT handled automatically:
  ✗ Data corruption on the target (no end-to-end checksums by default
     in base NVMe-oF; data integrity field optional)
  ✗ Target storage device failure (if backing NVMe on target fails,
     the namespace fails — target must provide RAID/replication)
  ✗ Simultaneous loss of ALL paths (application sees -EIO)
  ✗ Write ordering across paths (application must use barriers/fsync)
  ✗ Write fencing between two hosts (NVMe Reservations are an optional
     feature, must be explicitly used; absent by default → silent
     corruption if two hosts write the same namespace)
```

---

## A.5. Resilient NVMe-oF Architecture

```
Production HA pattern:

Storage node A:
  12× NVMe (with internal RAID-6 or mirroring)
  Exports as subsystem A
    namespaces 1-4: optimized on port A1, non-optimized on port B1
    namespaces 5-8: non-optimized on port A1, optimized on port B1

Storage node B:
  12× NVMe (mirrors of node A's, or independent set)
  Exports as subsystem A (same NQN, different port)
    same ANA groups as above

Host:
  NIC 0 ──→ switch X ──→ node A port A1
  NIC 1 ──→ switch Y ──→ node B port B1

  For ns 1-4: optimized path = nvme0 (via NIC 0)
              non-optimized failover = nvme1 (via NIC 1)
  For ns 5-8: optimized path = nvme1
              non-optimized failover = nvme0

Failure response:
  NIC 0 fails:       all I/O via nvme1; ns 1-4 use non-optimized path
  Switch X fails:    same as NIC 0 failure
  Node A fails:      ns 1-4 served by node B (was non-optimized,
                     becomes optimized when peer fails)
  Both NICs fail:    no path → -EIO to application (HA must be at
                     application level)
```

**The key architectural point:** ANA multipathing handles network and
controller failures. Storage failures (a backing disk fails on the
target) must be handled by the target's local RAID or replication. The
host sees only namespaces; it has no insight into whether they are
backed by single drives or RAID.

---

## Part B: O_DIRECT Path — Gap-Fill

You know O_DIRECT from BlueStore. This section confirms the kernel-level
path and identifies the specific overheads it eliminates and what costs
remain.

### Learning Objectives (Part B)
- Confirm what O_DIRECT bypasses and what it does NOT bypass
- Understand the alignment requirements and where they're enforced
- Compare O_DIRECT + libaio with io_uring + O_DIRECT (preview for Day 25)

---

## B.1. What O_DIRECT Bypasses

```
Normal buffered I/O path:
  write() → page cache (allocate + copy) → dirty page → writeback
        → block layer → device → page cache holds clean copy for reads

O_DIRECT path:
  write() → alignment check → iomap_dio_rw() → block layer → device
                                            ↑ page cache COMPLETELY bypassed

What O_DIRECT eliminates:
  ✓ Page cache allocation and management
  ✓ Dirty page tracking and writeback machinery
  ✓ Page cache eviction pressure (no pages to evict)
  ✓ The copy from page cache to user buffer on read

What O_DIRECT does NOT eliminate:
  ✗ The block layer (blk-mq) — still goes through it
  ✗ The I/O scheduler — still subject to scheduling if not 'none'
  ✗ DMA itself — direct DMA from/to user buffer (not zero-copy in
     the RDMA sense, but no extra copies)
  ✗ The system call overhead (one syscall per I/O for synchronous;
     batched for libaio/io_uring)
  ✗ Page pinning — kernel must `get_user_pages()` for DMA
```

```c
// fs/iomap/direct-io.c — the modern direct I/O path

iomap_dio_rw():
    // 1. Validate alignment (offset, length, buffer)
    if (!IS_ALIGNED(pos, blksize) ||
        !IS_ALIGNED(count, blksize) ||
        !IS_ALIGNED(buf, blksize))
        return -EINVAL;

    // 2. Pin user pages for DMA
    iov_iter_get_pages2()

    // 3. Build bio(s) pointing directly at user pages
    iomap_dio_bio_iter()  →  bio_alloc + bio_add_page

    // 4. Submit bio(s) — same path as any block I/O from here
    submit_bio()

    // 5. On completion: unpin pages, complete request
    iomap_dio_complete()
```

---

## B.2. Alignment Requirements

O_DIRECT enforces strict alignment because DMA hardware requires it:

```c
// fs/iomap/direct-io.c

// O_DIRECT requires (all three):
//   1. buffer address (in memory) aligned to logical block size
//   2. file offset aligned to logical block size
//   3. transfer size a multiple of logical block size

// Typical logical block size: 512 B (legacy) or 4096 B (modern)

blksize = bdev_logical_block_size(bdev);

if (!IS_ALIGNED(offset, blksize) ||
    !IS_ALIGNED(count, blksize) ||
    !IS_ALIGNED((unsigned long)buf, blksize))
    return -EINVAL;
```

```bash
# Check logical and physical block size for a device
cat /sys/block/nvme0n1/queue/logical_block_size    # 512 or 4096
cat /sys/block/nvme0n1/queue/physical_block_size   # typically 4096

# O_DIRECT with misaligned buffer → EINVAL on the syscall
# Userspace allocation pattern:
#   posix_memalign((void**)&buf, 4096, 65536)
# BlueStore uses this; databases use this; anything doing O_DIRECT uses this.
```

---

## B.3. O_DIRECT + libaio vs O_DIRECT + io_uring

This bridges to Day 25:

```
O_DIRECT + libaio (the BlueStore model):
  - Bypasses page cache (good — application manages caching)
  - Async via io_submit() / io_getevents()
  - Each I/O still requires the kernel to pin user pages for DMA
    (get_user_pages on submit, put_page on completion)
  - At very high IOPS (>200K), the per-I/O page pinning becomes
    measurable CPU overhead

O_DIRECT + io_uring (the modern path):
  - Same page cache bypass
  - SQ/CQ rings — submission and completion in shared memory
  - Optional fixed buffer registration:
      Buffers registered ONCE at startup → kernel pins them ONCE
      Subsequent I/Os reference the buffer by index → no per-I/O pinning
  - This eliminates the per-I/O page pinning cost that libaio still pays
  - At 500K+ IOPS the difference is significant (Day 25 has measurements)
```

**The key insight:** O_DIRECT eliminates the page cache, but doesn't
eliminate the per-I/O buffer mapping cost — kernel still has to set up
DMA for each I/O. io_uring's fixed buffers eliminate that residual cost
by registering buffers once.

---

## C. Self-Check Questions

1. What is the NVMe keep-alive timeout (KATO) and what happens when it expires?
2. What is `ctrl_loss_tmo` and what happens to in-flight I/Os when it elapses without reconnect?
3. In ANA multipathing, what determines which path is used for I/O to a specific namespace?
4. Why doesn't NVMe-oF solve the "two hosts writing the same namespace" problem by default?
5. O_DIRECT bypasses the page cache. Does it bypass the I/O scheduler? Does it eliminate DMA?
6. What alignment requirements must a buffer meet for O_DIRECT, and what happens if any is violated?
7. What specific overhead does io_uring's fixed buffer registration eliminate that O_DIRECT + libaio still pays?

## D. Answers

1. KATO is a periodic admin command the host sends to the target to verify the connection is alive. If the target doesn't respond within the KATO window, the host assumes path failure and begins reconnect attempts. Default is 10 seconds. Set lower for faster failure detection (at the cost of slightly more background traffic and a small false-positive risk on briefly-loaded targets).
2. `ctrl_loss_tmo` is the maximum time the driver will keep attempting to reconnect after a failure. If reconnect doesn't succeed within this window, the driver gives up: removes the controller, fails all queued and in-flight I/Os with `-EIO`. Applications then see I/O errors. Set this based on your application's RTO: longer = more time for transient failures to recover; shorter = faster application-visible failure for hard outages.
3. The kernel's NVMe multipath layer selects paths with `ANA_OPTIMIZED` state first, applying the configured I/O policy (numa/round-robin/queue-depth) when multiple optimized paths exist. It falls back to `ANA_NON_OPTIMIZED` only when no optimized paths are available. The ANA state is set by the storage target and reflects whether that controller has direct local access to the namespace's physical storage.
4. The base NVMe spec has no mandatory write exclusion between hosts. SCSI had SCSI reservations for this purpose. NVMe-oF includes an optional Reservations feature (indicated by ONCS bits in id-ctrl), but it must be explicitly implemented by both target and host and explicitly used by applications. Without reservations, two hosts writing the same namespace will silently corrupt each other's data — there's no protocol-level coordination.
5. O_DIRECT does NOT bypass the I/O scheduler — requests still go through blk-mq and any configured scheduler (though with `none` on NVMe, this is near-zero overhead). DMA is still used — in fact, O_DIRECT enables DMA directly to/from the user's buffer (no intermediate kernel copy). What changes is that the user buffer is pinned and mapped for DMA without going through the page cache.
6. Buffer address, file offset, and transfer size must all be aligned to the device's logical block size (typically 512 B or 4096 B). Violation causes the syscall to fail immediately with `EINVAL` — no I/O is attempted. BlueStore handles this by allocating all buffers with `posix_memalign(buf, 4096, size)`.
7. Per-I/O `get_user_pages()` (pinning user buffer pages so they don't get swapped or moved during DMA) and `put_page()` (unpinning on completion). With libaio + O_DIRECT, every I/O calls these on submission and completion. With io_uring fixed buffers, the buffers are registered once at setup; the kernel pins them once and reuses the mapping for all subsequent I/Os referencing them by index. At sustained 500K+ IOPS, this difference is several percent of CPU time on a busy host.

---

## Tomorrow: Day 25 — io_uring Deep Dive: Fixed Buffers, Registered Files & NVMe Passthrough

We go from blog-level io_uring knowledge to source-level: the SQ/CQ ring
mechanics, fixed buffer registration, registered files, and `uring_cmd`
NVMe passthrough — the highest-performance kernel I/O path available
today.
