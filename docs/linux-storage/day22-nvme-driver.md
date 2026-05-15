# Day 22: NVMe Driver — Queue Pairs, Multi-Namespace & Passthrough

## Learning Objectives
- Understand NVMe's queue pair model at source level (`drivers/nvme/host/pci.c`)
- Follow command submission and completion through SQ/CQ doorbells
- Understand multi-namespace management and namespace-level operations
- Know NVMe passthrough: when and why to bypass the block layer
- Map NVMe concepts to blk-mq structures from Day 2

---

## 1. NVMe Queue Pair Model

NVMe defines a fundamentally different interface from SATA/SCSI: no single
command queue shared by host and device. Instead:

```
NVMe Queue Pair:
  Submission Queue (SQ): host writes commands here
  Completion Queue (CQ): device writes completions here

  SQ and CQ are circular ring buffers in host memory (DMA-accessible)

  Protocol:
    1. Host places command in SQ[tail]
    2. Host writes SQ tail doorbell register (tells device "new command")
    3. Device reads command via DMA, executes it
    4. Device places completion in CQ[head]
    5. Device asserts interrupt (or host polls CQ)
    6. Host reads completion, processes result
    7. Host writes CQ head doorbell register (tells device "consumed")
```

```
NVMe queue counts:
  Admin Queue (AQ): 1 queue pair, management commands only
                    (identify, set features, format, create/delete queues)
  I/O Queues:       1 to 65535 queue pairs
                    Typical NVMe SSD: 1 I/O queue pair per CPU core (32-128)
                    Each queue: 64 to 65535 entries (queue depth)
```

**Mapping to blk-mq (from Day 2):**
```
NVMe concept       ←→  blk-mq concept
─────────────────────────────────────
I/O queue pair         blk_mq_hw_ctx
                       (one hardware context per NVMe queue pair)

Software staging   ←→  blk_mq_ctx
                       (per-CPU; merges, then dispatches to hctx)

Command ID (CID)   ←→  blk-mq tag
                       (uniquely identifies in-flight command)

Queue depth        ←→  SQ/CQ ring size
                       (max in-flight commands per queue)
```

---

## 2. NVMe Driver Source: Key Structures

```c
// drivers/nvme/host/pci.c

struct nvme_dev {
    struct nvme_queue   *queues;    // array of queue pairs: index 0=admin, 1+=I/O
    u32 __iomem         *dbs;       // doorbell registers (MMIO)
    struct nvme_ctrl    ctrl;       // shared controller state (across transports)
    unsigned int        online_queues;  // currently online queue count
    int                 io_queues[HCTX_MAX_TYPES];  // default/read/poll queue counts
    // ...
};

struct nvme_queue {
    struct nvme_dev     *dev;
    spinlock_t          sq_lock;
    struct nvme_command *sq_cmds;        // SQ ring buffer (host memory)
    volatile struct nvme_completion *cqes; // CQ ring buffer (host memory)
    dma_addr_t          sq_dma_addr;     // DMA address of SQ
    dma_addr_t          cq_dma_addr;     // DMA address of CQ
    u32 __iomem         *q_db;           // SQ doorbell register
    u16                 q_depth;         // SQ/CQ size
    u16                 sq_tail;         // host's SQ write pointer
    u16                 cq_head;         // host's CQ read pointer
    u16                 qid;             // queue ID (0 = admin)
    u8                  cq_phase;        // phase bit (toggles each ring wrap)
    // ...
};
```

The **phase bit** is how the host knows whether a CQE is new or stale.
Each ring traversal toggles the expected phase; a CQE matches "new" only
when its phase bit matches the current expected value. This avoids the
need for the device to explicitly invalidate CQ entries between traversals.

---

## 3. Command Submission Path

```c
// drivers/nvme/host/pci.c

// blk-mq calls this for each request:
static blk_status_t nvme_queue_rq(struct blk_mq_hw_ctx *hctx,
                                   const struct blk_mq_queue_data *bd)
{
    struct nvme_ns *ns = hctx->queue->queuedata;
    struct nvme_queue *nvmeq = hctx->driver_data;
    struct request *req = bd->rq;
    struct nvme_iod *iod = blk_mq_rq_to_pdu(req);

    // 1. Build NVMe command from blk-mq request
    nvme_setup_cmd(ns, req);
    // → fills struct nvme_command:
    //   opcode (read=0x02, write=0x01, flush=0x00, ...)
    //   namespace ID
    //   starting LBA (cdw10, cdw11)
    //   length in LBA units (cdw12)
    //   PRP list / SGL list (for DMA scatter-gather of data buffer)

    // 2. Map the data buffer for DMA
    nvme_map_data(dev, req, &iod->cmd);
    // → builds PRP (Physical Region Page) list pointing to user pages

    // 3. Place command in SQ ring buffer
    spin_lock(&nvmeq->sq_lock);
    nvme_sq_copy_cmd(nvmeq, &iod->cmd);
    // → memcpy to nvmeq->sq_cmds[nvmeq->sq_tail]
    // → nvmeq->sq_tail = (nvmeq->sq_tail + 1) % nvmeq->q_depth

    // 4. Ring the doorbell (tell device new commands are available)
    if (bd->last || !nvmeq->sq_tail_pending)
        nvme_write_sq_db(nvmeq, bd->last);
    // → writel(nvmeq->sq_tail, nvmeq->q_db)
    spin_unlock(&nvmeq->sq_lock);

    return BLK_STS_OK;
}
```

**The doorbell write is the critical moment:**
- Before doorbell: command is in host memory, device doesn't know
- After doorbell: device DMA-reads the command and executes it
- A doorbell write is an MMIO write — costs ~500 ns to 1 µs
- **Batching doorbells** (writing once after submitting multiple commands)
  is a meaningful optimization at high IOPS

```c
// The CID (command ID) in the NVMe command is set to the blk-mq tag:
nvme_setup_cmd():
    cmnd->common.command_id = nvme_cid(req);
// Later, on completion, the CID identifies the request to complete
```

---

## 4. Completion Handling

```c
// drivers/nvme/host/pci.c

// IRQ handler (interrupt-driven completion):
static irqreturn_t nvme_irq(int irq, void *data)
{
    struct nvme_queue *nvmeq = data;
    DEFINE_IO_COMP_BATCH(iob);

    if (nvme_poll_cq(nvmeq, &iob)) {
        if (!rq_list_empty(&iob.req_list))
            nvme_pci_complete_batch(&iob);
        return IRQ_HANDLED;
    }
    return IRQ_NONE;
}

static inline int nvme_poll_cq(struct nvme_queue *nvmeq,
                                struct io_comp_batch *iob)
{
    int found = 0;

    while (nvme_cqe_pending(nvmeq)) {
        // Read completion entry
        struct nvme_completion *cqe = &nvmeq->cqes[nvmeq->cq_head];

        // Advance CQ head; flip phase bit on wrap
        nvme_update_cq_head(nvmeq);

        // Find request by CID (= blk-mq tag)
        nvme_handle_cqe(nvmeq, iob, idx);
        found++;
    }

    if (found)
        nvme_ring_cq_doorbell(nvmeq);  // tell device we consumed these

    return found;
}
```

**The completion path under load:**
- One IRQ may complete many commands (batch processing)
- `nvme_pci_complete_batch()` calls `blk_mq_end_request()` for each
- One CQ doorbell write at the end (not one per completion) — important
  for high-IOPS efficiency

---

## 5. Multi-Namespace Management

NVMe namespaces are independent addressable storage units within a single
controller — analogous to LUNs in SCSI.

```bash
# List all namespaces on a controller
nvme list-ns /dev/nvme0
# [   0]:0x1
# [   1]:0x2
# ...

# Detailed namespace info
nvme id-ns /dev/nvme0 -n 1
# Shows: namespace size (nsze), capacity (ncap),
#        formatted LBA size, features, NGUID/EUI64

# Controller identity (shows namespace limits)
nvme id-ctrl /dev/nvme0 | grep -E "^nn|^mnan|^oncs|^vwc"
# nn   = total namespace count supported
# mnan = max namespace attachment count
# oncs = optional NVM command set bitmap
# vwc  = volatile write cache present (0 or 1)

# SMART log per-namespace (if supported)
nvme smart-log /dev/nvme0n1

# Create a namespace (requires admin, controller must support namespace management)
nvme create-ns /dev/nvme0 \
    --nsze=209715200 \    # size in LBA units (100 GB at 512B LBA)
    --ncap=209715200 \
    --flbas=0             # formatted LBA size index (0 = first LBA format)

# Attach namespace to controller
nvme attach-ns /dev/nvme0 --namespace-id=2 --controllers=0x1

# Detach and delete
nvme detach-ns /dev/nvme0 --namespace-id=2 --controllers=0x1
nvme delete-ns /dev/nvme0 --namespace-id=2
```

**Architectural uses for multiple namespaces:**

```
Single physical SSD partitioned into namespaces:
  nvme0n1: 1 TB → OS filesystem
  nvme0n2: 500 GB → database data
  nvme0n3: 100 GB → database WAL/log

Benefits over partitions:
  - Per-namespace QoS (some controllers support)
  - Per-namespace formatted LBA size (e.g., 4 KB for one, 512 B for another)
  - ANA (Asymmetric Namespace Access) — foundation of NVMe-oF multipathing
  - Per-namespace encryption keys (some controllers)
  - Independent namespace utilization tracking
```

---

## 6. NVMe Passthrough: Bypassing the Block Layer

NVMe passthrough lets userspace send raw NVMe commands directly to the
device, bypassing blk-mq, I/O schedulers, and the filesystem.

```c
// drivers/nvme/host/ioctl.c

// ioctl path: NVME_IOCTL_IO_CMD (for I/O commands)
//             NVME_IOCTL_ADMIN_CMD (for admin commands)
nvme_user_cmd(ctrl, ns, ucmd):
    // 1. Copy command from userspace
    memdup_user(ucmd->addr, sizeof(c))

    // 2. Submit directly to the appropriate queue (admin or I/O)
    nvme_submit_user_cmd(ctrl->admin_q or ns->queue, &c,
                         data_ptr, data_len, ...)

    // 3. Wait for completion
    // 4. Copy result back to userspace (result code + optional data)
```

```bash
# Send raw NVMe IDENTIFY (admin) command
nvme admin-passthru /dev/nvme0 \
    --opcode=0x06 \          # identify opcode
    --cdw10=1 \              # CNS=1 (identify controller)
    --data-len=4096 \
    --read

# Send raw READ (I/O) command
nvme io-passthru /dev/nvme0n1 \
    --opcode=0x02 \          # read opcode
    --cdw10=0 \              # starting LBA low 32 bits
    --cdw11=0 \              # starting LBA high 32 bits
    --cdw12=7 \              # number of LBAs - 1 (8 LBAs = 4 KB at 512 B LBA)
    --data-len=4096 \
    --read \
    --raw-binary > /tmp/sector0.bin
```

### Why passthrough matters for architects

1. **SPDK-style bypass**: SPDK-based storage stacks use passthrough to
   eliminate kernel I/O stack overhead entirely. They claim NVMe devices
   from the kernel and drive them from userspace.

2. **Vendor-specific commands**: NVMe vendor extensions (sanitize,
   firmware update, telemetry, custom log pages) require passthrough.

3. **io_uring + NVMe passthrough** (Day 25): combines async I/O with
   kernel-bypass for maximum performance without full SPDK complexity.
   The `IORING_OP_URING_CMD` opcode lets io_uring submit raw NVMe
   commands.

```bash
# Useful NVMe commands accessible via passthrough or wrapper tools

# Write Zeroes — faster than writing zeros manually (no DMA of data)
nvme write-zeroes /dev/nvme0n1 --start-block=0 --block-count=1023

# Dataset Management — TRIM/discard at the NVMe level
nvme dsm /dev/nvme0n1 --namespace-id=1 --ad --slbs=0 --nlbs=8191

# Flush — equivalent to fdatasync at NVMe protocol level
nvme flush /dev/nvme0n1 --namespace-id=1

# Sanitize — secure erase (caution: irreversible)
nvme sanitize /dev/nvme0 --sanact=2   # block erase
```

---

## 7. NVMe Features Architects Must Know

```bash
# 1. Volatile Write Cache (VWC)
nvme id-ctrl /dev/nvme0 | grep "^vwc"
# vwc:0x1 (bit 0 set) = device has a volatile write cache
# Acked writes may be in DRAM, not NAND
# Must flush via FUA bit on the bio or explicit FLUSH command

# 2. Error log — last N command errors
nvme error-log /dev/nvme0
# Shows: error count, LBA, opcode, status field, namespace
# Crucial for diagnosing drive misbehavior

# 3. SMART / Health log
nvme smart-log /dev/nvme0 | grep -E "percentage_used|temperature|unsafe_shutdowns|media_errors"
# percentage_used: wear indicator (0-100, where 100 = end of rated life)
# unsafe_shutdowns: count of power-loss events
# media_errors: uncorrected NAND errors

# 4. Power states
nvme id-ctrl /dev/nvme0 | grep -A2 "^ps "
# Multiple power states with different latency/power tradeoffs
nvme get-feature /dev/nvme0 --feature-id=0x02  # current power state

# 5. Firmware management
nvme fw-log /dev/nvme0           # firmware slot info
nvme fw-download /dev/nvme0 --fw=firmware.bin
nvme fw-activate /dev/nvme0 --slot=1 --action=1   # activate from slot 1

# 6. Format namespace (CAUTION: destructive)
# Change LBA size, secure erase, crypto erase
nvme format /dev/nvme0n1 --lbaf=1 --ses=0
# --lbaf: LBA format index (0..15, defined per-namespace)
# --ses:  Secure Erase Settings (0=none, 1=user data erase, 2=crypto erase)
```

---

## 8. Hands-On: NVMe Inspection

```bash
# System inventory
nvme list
# Shows: device, model, serial, firmware, size, format

# Deep dive on one controller
nvme id-ctrl /dev/nvme0 | head -60

# blk-mq queue count for this NVMe (should match online I/O queues)
cat /sys/block/nvme0n1/queue/nr_hw_queues
ls /sys/block/nvme0n1/mq/ | sort -n | wc -l

# IRQ affinity (which CPUs handle completions for which queues)
cat /proc/interrupts | grep nvme0q
# Each line: irq number, per-CPU counts, "PCI-MSI ... nvme0qN"

# Check IRQ affinity for queue 1 (first I/O queue)
QUEUE1_IRQ=$(grep nvme0q1 /proc/interrupts | awk -F: '{print $1}' | tr -d ' ')
cat /proc/irq/${QUEUE1_IRQ}/smp_affinity_list

# Monitor live submission/completion rates per opcode
bpftrace -e '
tracepoint:nvme:nvme_setup_cmd { @ops[args->opcode] = count(); }
interval:s:5 { print(@ops); clear(@ops); }
'
# Common opcodes:
#  0x00 = Flush
#  0x01 = Write
#  0x02 = Read
#  0x08 = Write Zeroes
#  0x09 = Dataset Management

# Latency distribution per opcode
bpftrace -e '
tracepoint:nvme:nvme_setup_cmd  { @start[args->cid] = nsecs; @op[args->cid] = args->opcode; }
tracepoint:nvme:nvme_complete_rq /@start[args->cid]/ {
    @lat_us[@op[args->cid]] = hist((nsecs - @start[args->cid]) / 1000);
    delete(@start[args->cid]); delete(@op[args->cid]);
}'
```

---

## 9. Source Reading Checklist

```
drivers/nvme/host/pci.c       — PCIe transport: queue setup, submission, IRQ
drivers/nvme/host/core.c      — common controller logic, namespace mgmt
drivers/nvme/host/ioctl.c     — passthrough via ioctl + uring_cmd
drivers/nvme/host/nvme.h      — host-side structs (nvme_ctrl, nvme_ns, nvme_queue)
include/linux/nvme.h          — NVMe spec definitions (commands, completions)
drivers/nvme/host/multipath.c — ANA multipathing (Day 23 topic)
```

Reading order: `nvme.h` (the protocol structures), then `pci.c` queue
setup + `nvme_queue_rq`, then `pci.c` completion path
(`nvme_irq` + `nvme_poll_cq`). The whole submission/completion lifecycle
is in those two files.

---

## 10. Self-Check Questions

1. What is the NVMe doorbell register and why is batching doorbell writes beneficial at high IOPS?
2. How does the NVMe command ID (CID) map to the blk-mq tag from Day 2, and where in `pci.c` is this mapping established?
3. What is an NVMe namespace and how does it differ architecturally from a partition?
4. Why would an application use NVMe I/O passthrough instead of normal block I/O? Name three distinct reasons.
5. A device's `id-ctrl` output shows `vwc:0x1`. What does this mean for data durability and what must software do?
6. On a 32-core server, an NVMe SSD creates 32 I/O queue pairs. What blk-mq structure corresponds to each queue pair, and where is it stored?
7. What is the CQ phase bit and why does it eliminate the need for explicit CQE invalidation?

## 11. Answers

1. The doorbell is an MMIO register that the host writes to signal the device of new SQ entries (or consumed CQ entries). An MMIO write costs ~500 ns to 1 µs. Batching: submit multiple commands to the SQ ring buffer, then write the doorbell once — one MMIO write for N commands instead of N. At 1M IOPS without batching, doorbells alone could consume a CPU. blk-mq's `dispatch()` exposes the `bd->last` flag so the NVMe driver can defer the doorbell write until the last command in a batch.
2. The CID field in the NVMe command (`cmnd->common.command_id`) is set to the blk-mq tag value via `nvme_cid(req)` in `nvme_setup_cmd()`. On completion, the device returns the CID in the CQE; the driver uses it via `nvme_find_rq()` to locate the corresponding `struct request` and complete it. This is the same tag→request lookup pattern from Day 2's blk-mq design.
3. A namespace is an independently addressable LBA space within an NVMe controller. Unlike a partition (a logical subdivision of a single block device, managed by the host), a namespace is managed at the NVMe controller level: it can have a different formatted LBA size from other namespaces, can be attached/detached at runtime, has independent QoS (on capable controllers), and has its own identity (NGUID/EUI64). Multiple namespaces share the controller's physical NAND pool.
4. (a) Access to vendor-specific commands not exposed through the block layer (firmware update, telemetry, sanitize). (b) Ultra-low latency by eliminating kernel I/O stack overhead — SPDK-style storage engines drive NVMe directly. (c) Custom command patterns not supported by standard bio (e.g., NVMe-MI, ZNS-specific commands, computational storage commands). (d, bonus) io_uring + uring_cmd combines async I/O with passthrough — a kernel-mediated middle ground.
5. `vwc:0x1` means the device has a volatile write cache — writes acknowledged by the device may still be in DRAM, not yet persisted to NAND. A power loss before the cache is flushed loses those writes. Software must either issue a FLUSH command (NVMe opcode 0x00) or set the FUA bit on critical writes. Filesystems do this automatically as part of `fsync()` / `fdatasync()` — those calls translate to FLUSH commands on the wire (or FUA writes for the data path).
6. Each NVMe I/O queue pair corresponds to one `struct blk_mq_hw_ctx`. The NVMe driver sets `tag_set->nr_hw_queues = nvme_dev->online_queues - 1` (subtract the admin queue) when registering with blk-mq. Each `hctx` stores a pointer to its `struct nvme_queue` in `hctx->driver_data`, set by the driver's `init_hctx()` callback. The Day 2 software queues (`blk_mq_ctx`, one per CPU) feed into these hardware queues.
7. The CQ phase bit is a 1-bit field in each CQE that the device toggles each time it wraps around the CQ ring. The host tracks the expected phase value (`cq_phase` in `struct nvme_queue`) and reads a CQE as "new" only when its phase matches. After the host reads a CQE and advances `cq_head`, the slot still contains the old data — but with the wrong phase bit, so it's not mistaken for a new completion. This eliminates the need for the device to explicitly clear or invalidate CQ entries — saves DMA writes and simplifies the protocol.

---

## Tomorrow: Day 23 — NVMe-oF: Architecture & Transport Comparison

We set up NVMe-oF/TCP loopback, measure latency vs local NVMe, and
understand the discovery protocol, queue allocation, and ANA multipathing
model that extends NVMe over a network fabric.
