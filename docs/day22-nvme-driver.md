# Day 22: NVMe Driver — Queue Pairs, Multi-Namespace & Passthrough

## Learning Objectives
- Understand NVMe's queue pair model at source level (`drivers/nvme/host/pci.c`)
- Follow command submission and completion through SQ/CQ doorbells
- Understand multi-namespace management and namespace-level operations
- Know NVMe passthrough: when and why to bypass the block layer
- Map NVMe concepts to blk-mq structures from Day 2

---

## 1. NVMe Queue Pair Model

NVMe defines a fundamentally different interface from SATA/SCSI:
no single command queue shared by host and device. Instead:

```
NVMe Queue Pair:
  Submission Queue (SQ): host writes commands here
  Completion Queue (CQ): device writes completions here

  SQ and CQ are circular ring buffers in host memory (DMA-accessible)

  Protocol:
    1. Host places command in SQ[tail]
    2. Host writes SQ tail doorbell register (tells device "new command")
    3. Device reads command, executes it
    4. Device places completion in CQ[head]
    5. Device asserts interrupt (or host polls CQ)
    6. Host reads completion, processes result
    7. Host writes CQ head doorbell register (tells device "consumed")
```

```
NVMe queue counts:
  Admin Queue (AQ): 1 queue pair, management commands only
                    (identify, set features, format, etc.)
  I/O Queues:       1 to 65535 queue pairs
                    Typical NVMe SSD: 1 per CPU core (32-64)
                    Each queue: up to 65535 entries (depth)
```

**Mapping to blk-mq (from Day 2):**
```
blk_mq_hw_ctx   ←→  NVMe I/O queue pair
blk_mq_ctx      ←→  per-CPU software staging queue
tag             ←→  command ID in SQ entry (CID field)
queue_depth     ←→  SQ/CQ ring buffer size
```

---

## 2. NVMe Driver Source: Key Structures

```c
// drivers/nvme/host/pci.c

struct nvme_dev {
    struct nvme_queue   *queues;    // array of queue pairs (admin + I/O)
    u32 __iomem         *dbs;       // doorbell registers (MMIO)
    struct nvme_ctrl    ctrl;       // common controller state
    // ...
};

struct nvme_queue {
    struct nvme_dev     *dev;
    struct nvme_command *sq_cmds;   // SQ ring buffer (host memory)
    volatile struct nvme_completion *cqes; // CQ ring buffer (host memory)
    dma_addr_t          sq_dma_addr;   // DMA address of SQ
    dma_addr_t          cq_dma_addr;   // DMA address of CQ
    u32 __iomem         *q_db;         // doorbell register for this queue
    u16                 q_depth;       // SQ/CQ size
    u16                 sq_tail;       // host's SQ write pointer
    u16                 cq_head;       // host's CQ read pointer
    u16                 qid;           // queue ID (0 = admin)
    // ...
};
```

---

## 3. Command Submission Path

```c
// drivers/nvme/host/pci.c

// blk-mq calls this for each request:
static blk_status_t nvme_queue_rq(struct blk_mq_hw_ctx *hctx,
                                   const struct blk_mq_queue_data *bd)
{
    struct nvme_queue *nvmeq = hctx->driver_data;
    struct request *req = bd->rq;

    // 1. Build NVMe command from blk-mq request
    nvme_setup_cmd(ns, req);
    // → fills struct nvme_command:
    //   opcode (read=0x02, write=0x01)
    //   namespace ID
    //   starting LBA
    //   length (in 512-byte units)
    //   PRP list (Physical Region Pages — DMA scatter-gather)

    // 2. Place command in SQ ring buffer
    nvme_sq_copy_cmd(nvmeq, &iod->cmd);
    // → memcpy to nvmeq->sq_cmds[nvmeq->sq_tail]
    // → nvmeq->sq_tail = (nvmeq->sq_tail + 1) % nvmeq->q_depth

    // 3. Ring the doorbell (tell device new commands are available)
    if (bd->last)
        nvme_write_sq_db(nvmeq, true);
    // → writel(nvmeq->sq_tail, nvmeq->q_db)
    // → single MMIO write — device sees the new tail pointer
}
```

**The doorbell write is the critical moment:**
- Before doorbell: command is in host memory, device doesn't know
- After doorbell: device fetches and executes command
- Batching doorbells (writing once after multiple commands) improves throughput

---

## 4. Completion Handling

```c
// drivers/nvme/host/pci.c

// IRQ handler (or polling loop):
static irqreturn_t nvme_irq(int irq, void *data)
{
    struct nvme_queue *nvmeq = data;
    nvme_process_cq(nvmeq);
    return IRQ_HANDLED;
}

static void nvme_process_cq(struct nvme_queue *nvmeq)
{
    while (nvme_cqe_pending(nvmeq)) {
        // Read completion entry
        struct nvme_completion *cqe = &nvmeq->cqes[nvmeq->cq_head];

        // Extract command ID → find in-flight request
        req = nvme_find_rq(nvmeq, cqe->command_id);

        // Complete the blk-mq request
        nvme_end_request(req, cqe->status);
        // → blk_mq_end_request(req, ...) → frees tag → wakes waiters

        // Advance CQ head
        nvmeq->cq_head = (nvmeq->cq_head + 1) % nvmeq->q_depth;
    }

    // Tell device we consumed completions
    writel(nvmeq->cq_head, nvmeq->q_db + nvmeq->dev->db_stride);
}
```

---

## 5. Multi-Namespace Management

NVMe namespaces are the equivalent of LUNs — independent addressable
storage units within a single controller.

```bash
# List all namespaces on a controller
nvme list-ns /dev/nvme0
# Output: [  0]:0x1  [  1]:0x2  ...  (namespace IDs)

# Detailed namespace info
nvme id-ns /dev/nvme0 -n 1
# Shows: namespace size, capacity, formatted LBA size, features

# Controller identity (shows namespace limits)
nvme id-ctrl /dev/nvme0 | grep -E "nn|mnan|oncs"
# nn = total namespace count
# mnan = max namespace attachment count
# oncs = optional NVM command set (shows supported features)

# SMART log per-namespace (if supported)
nvme smart-log /dev/nvme0n1
nvme smart-log /dev/nvme0n2
```

**Multi-namespace architecture uses:**
```
Single physical SSD → multiple namespaces:
  nvme0n1: 1TB  → OS filesystem
  nvme0n2: 500GB → database data
  nvme0n3: 100GB → database WAL/log

Benefits:
  - Separate QoS per namespace (if controller supports)
  - Independent formatting (different LBA sizes)
  - ANA (Asymmetric Namespace Access) for NVMe-oF multipathing
  - Namespace-level encryption keys (if controller supports)
```

```bash
# Create namespace (requires admin privilege, controller must support it)
nvme create-ns /dev/nvme0 \
    --nsze=209715200 \    # size in LBA units (100GB at 512B LBA)
    --ncap=209715200 \
    --flbas=0             # formatted LBA size index

# Attach namespace to controller
nvme attach-ns /dev/nvme0 --namespace-id=2 --controllers=0x1

# Detach and delete
nvme detach-ns /dev/nvme0 --namespace-id=2 --controllers=0x1
nvme delete-ns /dev/nvme0 --namespace-id=2
```

---

## 6. NVMe Passthrough: Bypassing the Block Layer

NVMe passthrough allows sending raw NVMe commands directly to the device,
bypassing blk-mq, I/O schedulers, and the filesystem.

```c
// drivers/nvme/host/ioctl.c

// ioctl path: NVME_IOCTL_IO_CMD
nvme_user_cmd(ctrl, ns, ucmd):
    // 1. Copy command from userspace
    memdup_user(ucmd->addr, sizeof(c))

    // 2. Submit directly to admin/IO queue
    nvme_submit_user_cmd(ctrl->admin_q or ns->queue, &c, ...)

    // 3. Wait for completion
    // 4. Copy result back to userspace
```

```bash
# Send raw NVMe IDENTIFY command
nvme admin-passthru /dev/nvme0 \
    --opcode=0x06 \          # identify opcode
    --cdw10=1 \              # CNS=1 (identify controller)
    --data-len=4096 \
    --read

# Send raw READ command (I/O passthrough)
nvme io-passthru /dev/nvme0n1 \
    --opcode=0x02 \          # read opcode
    --cdw10=0 \              # starting LBA low
    --cdw12=7 \              # number of LBAs - 1 (8 LBAs = 4KB)
    --data-len=4096 \
    --read \
    --raw-binary > /tmp/sector0.bin
```

**Why passthrough matters for architects:**

1. **SPDK-style bypass**: Applications (SPDK, DPDK-based storage) use
   passthrough to eliminate kernel overhead entirely for ultra-low latency

2. **Vendor-specific commands**: NVMe vendor extensions (sanitize,
   firmware update, telemetry) require passthrough

3. **io_uring + NVMe passthrough** (Day 25): combines async I/O with
   kernel-bypass for maximum performance without full SPDK complexity

```bash
# Check if namespace supports passthrough for specific features
nvme id-ctrl /dev/nvme0 | grep -i "vs"   # vendor specific capabilities

# NVMe Write Zeroes (faster than writing zeros manually)
nvme write-zeroes /dev/nvme0n1 --start-block=0 --block-count=1023

# NVMe Dataset Management (TRIM/discard at NVMe level)
nvme dsm /dev/nvme0n1 --namespace-id=1 --ad --slbs=0 --nlbs=8191
```

---

## 7. NVMe Features Architects Must Know

```bash
# 1. Volatile Write Cache (VWC)
nvme id-ctrl /dev/nvme0 | grep vwc
# vwc=1: device has volatile write cache
# Must flush with FUA bit or FLUSH command for durability guarantee

# Force flush (equivalent to fdatasync at NVMe level)
nvme flush /dev/nvme0n1 --namespace-id=1

# 2. Namespace Write Protection
nvme id-ns /dev/nvme0 -n 1 | grep wp
# wp: write protection state

# 3. NVMe Error Log
nvme error-log /dev/nvme0
# Shows: error count, LBA, opcode, status for each error

# 4. Firmware management
nvme fw-log /dev/nvme0       # firmware slot info
nvme fw-download /dev/nvme0 --fw=firmware.bin
nvme fw-activate /dev/nvme0 --slot=1 --action=1

# 5. Power states
nvme id-ctrl /dev/nvme0 | grep -A5 "ps "   # power state descriptors
nvme get-feature /dev/nvme0 --feature-id=0x02  # current power state
```

---

## 8. Hands-On: NVMe Inspection

```bash
# Full NVMe system inventory
nvme list
# Shows: device, model, serial, firmware, size, format

# Deep dive on one controller
nvme id-ctrl /dev/nvme0 | head -60
# Key fields:
# mn: model name
# fr: firmware revision
# tnvmcap: total NVM capacity
# unvmcap: unallocated NVM capacity (available for new namespaces)
# sqes/cqes: SQ/CQ entry sizes
# nn: number of namespaces

# Check queue depth and count
cat /sys/block/nvme0n1/queue/nr_hw_queues
ls /sys/block/nvme0n1/mq/ | wc -l
cat /sys/block/nvme0n1/queue/nr_requests

# Monitor NVMe error rate
watch -n5 "nvme error-log /dev/nvme0 --log-entries=5"

# Check media wear and temperature
nvme smart-log /dev/nvme0 | grep -E "percentage_used|temperature|unsafe_shutdowns"

# Trace NVMe command submission at blk-mq level
bpftrace -e '
tracepoint:nvme:nvme_sq {
    @cmds[args->opcode] = count();
}
interval:s:5 {
    print(@cmds); clear(@cmds);
}'
# opcode 0x01=write, 0x02=read, 0x00=flush
```

---

## 9. Self-Check Questions

1. What is the NVMe doorbell register and why is batching doorbell writes beneficial?
2. How does the NVMe command ID (`CID`) map to the blk-mq tag from Day 2?
3. What is an NVMe namespace and how does it differ from a partition?
4. Why would an application use NVMe I/O passthrough instead of normal block I/O?
5. A device has `vwc=1`. What does this mean for data durability and what must the application do?
6. On a 32-core server, a typical NVMe SSD creates 32 I/O queue pairs. What blk-mq structure corresponds to each queue pair?

## 10. Answers

1. The doorbell register is an MMIO register that the host writes to signal the device of new SQ entries (or consumed CQ entries). Writing a doorbell is a PCI MMIO write — relatively expensive (~1µs). Batching: submit multiple commands to the SQ ring buffer, then write the doorbell once — one MMIO write for N commands instead of N MMIO writes.
2. The CID (Command ID) in the NVMe SQ entry is set to the blk-mq tag value. On completion, the device returns the CID in the CQ entry. The driver uses the CID to find the corresponding in-flight request via `nvme_find_rq()` — exactly the tag→request lookup from Day 2.
3. A namespace is an independently addressable LBA space within an NVMe controller. Unlike a partition (a logical subdivision of a single block device), a namespace is managed at the controller level, can have different LBA sizes, can be attached/detached, and can have independent QoS and encryption. Multiple namespaces share the controller's physical NAND pool.
4. (a) Vendor-specific commands not exposed through the block layer. (b) Ultra-low latency by eliminating kernel I/O stack overhead (SPDK-style). (c) Custom scatter-gather patterns not supported by standard bio. (d) Accessing raw NVMe features (sanitize, telemetry, firmware update).
5. `vwc=1` means the device has a volatile write cache — writes acknowledged by the device may still be in DRAM, not persisted to NAND. A power loss before the cache is flushed loses those writes. Application must use `O_SYNC`/`fsync` (which triggers a FLUSH command or FUA bit) for durability. Without explicit flush, acknowledged writes are not guaranteed durable.
6. `struct blk_mq_hw_ctx` — one per NVMe I/O queue pair. The NVMe driver sets `nr_hw_queues=32` in `blk_mq_tag_set`, and each `blk_mq_hw_ctx` stores a pointer to the corresponding `struct nvme_queue` in `hctx->driver_data`.

---

## Tomorrow: Day 23 — NVMe-oF: Architecture & Transport Comparison

We set up NVMe-oF/TCP loopback, measure latency vs local NVMe,
and understand the discovery, queue allocation, and ANA multipathing model.
