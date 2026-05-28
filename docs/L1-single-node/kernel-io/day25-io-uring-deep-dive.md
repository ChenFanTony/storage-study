# Day 25: io_uring — Fixed Buffers, Registered Files & NVMe Passthrough

## Learning Objectives
- Understand io_uring's SQ/CQ ring mechanics at source level
- Understand fixed buffer registration: what cost it eliminates and why
- Understand registered files: what cost that eliminates
- Write programs using basic io_uring, fixed buffers, and NVMe passthrough
- Know when io_uring outperforms O_DIRECT + libaio (and when it doesn't)

---

## 1. SQ/CQ Ring Mechanics

io_uring uses two ring buffers shared between kernel and userspace via
mmap. The kernel and userspace communicate through shared memory —
no syscall per I/O.

```c
// io_uring/io_uring.c

// Setup: io_uring_setup() creates the rings
// Returns a file descriptor; userspace mmaps three regions:
//   IORING_OFF_SQ_RING — submission queue metadata + indices
//   IORING_OFF_CQ_RING — completion queue metadata + entries
//   IORING_OFF_SQES    — submission queue entries array

struct io_rings {
    struct io_uring        sq, cq;       // metadata + head/tail pointers
    u32                    sq_ring_mask, cq_ring_mask;
    u32                    sq_ring_entries, cq_ring_entries;
    // ...
    struct io_uring_cqe    cqes[];       // CQE array (flexible)
};
```

```c
// include/uapi/linux/io_uring.h

// Submission Queue Entry — one per I/O operation
struct io_uring_sqe {
    __u8    opcode;         // IORING_OP_READ, IORING_OP_WRITE, IORING_OP_URING_CMD, ...
    __u8    flags;          // IOSQE_FIXED_FILE, IOSQE_IO_LINK, IOSQE_ASYNC, ...
    __u16   ioprio;
    __s32   fd;             // file descriptor (or registered file index)
    __u64   off;            // file offset
    __u64   addr;           // buffer address (or fixed buffer index)
    __u32   len;            // transfer length
    union { __u16 buf_index; ... };
    __u64   user_data;      // opaque user data, returned in CQE (lets app
                            // correlate completions to requests)
    // ... 16 more bytes
};

// Completion Queue Entry — one per completed I/O
struct io_uring_cqe {
    __u64   user_data;      // matches SQE user_data (identifies the I/O)
    __s32   res;            // result: bytes transferred or -errno
    __u32   flags;          // IORING_CQE_F_BUFFER, IORING_CQE_F_MORE, ...
};
```

### The zero-syscall path

```
Submit I/O:
  1. Write SQE to ring->sqes[sq.tail & sq.ring_mask]
  2. Increment sq.tail (a store to shared memory — visible to kernel)
  3. Call io_uring_enter(ring_fd, to_submit, ...) — ONE syscall for N I/Os
     OR if SQPOLL mode: kernel thread polls SQ — ZERO syscalls

Receive completion:
  1. Poll cq.head != cq.tail (read shared memory — no syscall)
  2. Read CQE from ring->cqes[cq.head & cq.ring_mask]
  3. Increment cq.head (a store to shared memory — visible to kernel)
```

At sustained high IOPS, this design is dramatically more efficient than
libaio's `io_submit() / io_getevents()` pair, which always involves a
syscall.

---

## 2. Fixed Buffer Registration

Every normal I/O requires the kernel to:
1. `get_user_pages()` — pin user buffer pages (so they don't get swapped
   or moved while DMA is in flight)
2. Set up the bio's biovec scatter-gather list
3. Submit the bio; complete the I/O
4. `put_page()` — unpin the pages

Steps 1 and 4 involve atomic refcount operations, page table walking,
and mmap_lock contention under pressure. At 500K+ IOPS, this is
measurable CPU overhead.

**Fixed buffers pre-register buffers once, eliminating per-I/O pinning:**

```c
// io_uring/rsrc.c — fixed buffer registration

// Register buffers at setup time:
io_uring_register(ring_fd, IORING_REGISTER_BUFFERS, iovecs, nr_iovecs)
    →  __io_sqe_buffers_register():
        for each iovec:
            io_pin_pages(iov, &pages, &nr_pages)
            // Build io_mapped_ubuf struct holding the pinned pages

        // Store array in ctx->buf_table — accessed by index later

// Use fixed buffer in SQE:
sqe->opcode    = IORING_OP_READ_FIXED;   // not IORING_OP_READ
sqe->buf_index = 3;                       // index into ctx->buf_table
sqe->addr      = (uint64_t)buf;           // address within registered buffer
sqe->len       = 4096;

// On submission, io_uring uses ctx->buf_table[3] directly
// → no per-I/O get_user_pages / put_page
```

```c
// Example with liburing
#include <liburing.h>

struct io_uring ring;
io_uring_queue_init(32, &ring, 0);

// Allocate aligned buffers
char *bufs[8];
struct iovec iovecs[8];
for (int i = 0; i < 8; i++) {
    posix_memalign((void**)&bufs[i], 4096, 65536);  // 64 KB
    iovecs[i].iov_base = bufs[i];
    iovecs[i].iov_len  = 65536;
}

// Register once (kernel pins all 8 buffers now)
io_uring_register_buffers(&ring, iovecs, 8);

// Submit reads using fixed buffers (no per-I/O page pinning)
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_read_fixed(sqe, fd, bufs[0], 65536, offset, /*buf_index*/ 0);
sqe->user_data = 1;
io_uring_submit(&ring);

// Reap completion
struct io_uring_cqe *cqe;
io_uring_wait_cqe(&ring, &cqe);
// cqe->res = bytes read (or negative errno)
io_uring_cqe_seen(&ring, cqe);
```

---

## 3. Registered Files

Every normal I/O syscall does `fdget()` — looks up the file from the
process fd table, increments the file's reference count. At 500K IOPS:
500K fdget/fdput pairs per second, each involving an atomic operation.

**Registered files pre-resolve fds once, eliminating per-I/O lookup:**

```c
// io_uring/rsrc.c

// Register at setup time:
io_uring_register(ring_fd, IORING_REGISTER_FILES, fds, nr_fds)
    →  Resolves each fd → struct file* once
    →  Stores array of struct file* in ctx->file_table
    →  Increments each file's refcount once (not per I/O)

// Use registered file:
sqe->flags = IOSQE_FIXED_FILE;
sqe->fd    = 2;   // index into ctx->file_table (not the actual fd)

// io_uring uses ctx->file_table[2] directly — no fdget per I/O
```

**Direct descriptors** (a newer feature) extend this: an open operation
in io_uring can produce a "direct descriptor" — an index into the
registered table — without ever creating a normal kernel fd. Useful for
workloads with high fd-creation rates (network servers, file proxies).

---

## 4. SQPOLL: Eliminating Submission Syscalls Entirely

```c
// io_uring/sqpoll.c

// IORING_SETUP_SQPOLL creates a kernel thread that polls the SQ:
struct io_sq_data {
    struct task_struct  *thread;     // the kernel poller thread
    // ...
};

io_sq_thread():  // the kernel thread's main loop
    while (!kthread_should_park()) {
        // Check if userspace has added new SQEs
        if (sq_head != sq_tail) {
            io_submit_sqes(ctx, to_submit);
        } else if (idle_too_long) {
            // Park the thread; wake on next userspace activity
            schedule();
        }
    }
```

```c
// Setup: ring with SQPOLL
struct io_uring_params p = {
    .flags = IORING_SETUP_SQPOLL,
    .sq_thread_idle = 1000,   // park after 1 second idle
};
io_uring_queue_init_params(32, &ring, &p);

// Now submitting requires NO syscall:
//   userspace writes SQE → bumps sq.tail
//   kernel thread sees the new tail → submits
//   userspace polls CQ for completion
```

**Cost of SQPOLL:**
- One dedicated CPU thread burning cycles polling
- Park after `sq_thread_idle` ms of inactivity, but bursty workloads
  keep it busy
- Pin to a specific CPU with `IORING_SETUP_SQ_AFF` + `sq_thread_cpu`
- Worthwhile only for sustained very high IOPS (>500K) where the
  syscall overhead saved exceeds the cost of a dedicated CPU

---

## 5. The Kernel Path for io_uring Read/Write

```c
// io_uring/rw.c

// On SQE submission, for IORING_OP_READ:
io_read(req, issue_flags):
    // 1. Get iovec from SQE (or fixed buffer)
    // 2. Set up kiocb (kernel I/O control block)
    // 3. Call file->f_op->read_iter() — same as regular read syscall
    //    For O_DIRECT files: iomap_dio_rw() — same as O_DIRECT read
    //    For buffered:        generic_file_read_iter() — page cache path
    // 4. If async (typical for O_DIRECT): return -EIOCBQUEUED
    //    completion callback will post the CQE later
    // 5. If sync: complete immediately, post CQE

// io_uring is largely a thin layer over the existing file I/O paths.
// Its value is in submission/completion efficiency, not different I/O paths.
```

---

## 6. NVMe Passthrough via `uring_cmd`

`uring_cmd` (kernel 5.19+) lets io_uring submit raw device commands. For
NVMe, this combines async I/O with NVMe passthrough — the highest-
performance kernel-accessible I/O path.

```c
// io_uring/uring_cmd.c

// IORING_OP_URING_CMD wraps device-specific commands:
io_uring_cmd():
    // Dispatches to file->f_op->uring_cmd()
    // For NVMe character device: nvme_uring_cmd() in drivers/nvme/host/ioctl.c
```

```c
// SQE format for NVMe passthrough:
// Note: uring_cmd needs more space than a regular SQE — must set up ring
// with IORING_SETUP_SQE128 (128-byte SQEs, vs default 64).
// And IORING_SETUP_CQE32 if the command returns a 32-byte CQE.

struct io_uring_params p = {
    .flags = IORING_SETUP_SQE128 | IORING_SETUP_CQE32,
};
io_uring_queue_init_params(32, &ring, &p);

// Open the NVMe character device (NOT /dev/nvme0n1):
int ng_fd = open("/dev/ng0n1", O_RDWR);   // generic NVMe — passthrough target

// Build SQE
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_URING_CMD;
sqe->fd     = ng_fd;
sqe->cmd_op = NVME_URING_CMD_IO;

// The NVMe command is embedded in sqe->cmd (up to 80 bytes with SQE128):
struct nvme_uring_cmd *cmd = (void *)sqe->cmd;
memset(cmd, 0, sizeof(*cmd));
cmd->opcode   = nvme_cmd_read;   // 0x02
cmd->nsid     = 1;
cmd->cdw10    = lba & 0xffffffff;
cmd->cdw11    = lba >> 32;
cmd->cdw12    = nlb - 1;          // number of LBAs - 1
cmd->addr     = (uint64_t)buf;    // data buffer (or fixed-buffer ref)
cmd->data_len = nlb * 512;

io_uring_submit(&ring);
// ...
```

**Why this matters:**
```
Normal block I/O:
  Application → syscall → VFS → blk-mq → NVMe driver → device

io_uring + NVMe passthrough:
  Application → SQ ring → io_uring → NVMe driver → device
                                   ↑ VFS and blk-mq bypassed

Combined with fixed buffers (--fixedbufs in fio): also eliminates per-I/O
buffer mapping. Result: minimum possible kernel overhead for NVMe I/O
without going to a full SPDK userspace driver.
```

**What you give up with `uring_cmd`:**
- No I/O scheduler (BFQ fairness, mq-deadline ordering — all bypassed)
- No cgroup I/O enforcement (`io.max`, `io.weight`, `io.latency` are
  enforced in blk-mq, which is bypassed)
- No filesystem layer — you're talking directly to a namespace
- blktrace block-layer events don't see these I/Os
- bypasses dm-crypt, md, dm-cache — anything below the filesystem

For high-throughput single-tenant workloads on dedicated NVMe, this is
the cost-free choice. For shared, multi-tenant, or anything needing
the above features: stick with the normal block path.

---

## 7. Performance Comparison

```bash
# Setup
DEV=/dev/nvme0n1
RUNTIME=30

# 1. Synchronous (baseline)
fio --name=sync --filename=$DEV --rw=randread --bs=4k \
    --ioengine=psync --iodepth=1 --direct=1 \
    --time_based --runtime=$RUNTIME

# 2. libaio + O_DIRECT (traditional async)
fio --name=libaio --filename=$DEV --rw=randread --bs=4k \
    --ioengine=libaio --iodepth=32 --direct=1 \
    --time_based --runtime=$RUNTIME

# 3. io_uring basic
fio --name=iou-basic --filename=$DEV --rw=randread --bs=4k \
    --ioengine=io_uring --iodepth=32 --direct=1 \
    --time_based --runtime=$RUNTIME

# 4. io_uring with fixed buffers + registered files
fio --name=iou-fixed --filename=$DEV --rw=randread --bs=4k \
    --ioengine=io_uring --iodepth=32 --direct=1 \
    --fixedbufs=1 --registerfiles=1 \
    --time_based --runtime=$RUNTIME

# 5. io_uring with SQPOLL (zero-syscall submission)
fio --name=iou-sqpoll --filename=$DEV --rw=randread --bs=4k \
    --ioengine=io_uring --iodepth=32 --direct=1 \
    --fixedbufs=1 --registerfiles=1 --sqthread_poll=1 \
    --time_based --runtime=$RUNTIME

# 6. NVMe passthrough via uring_cmd (requires /dev/ng* and a recent kernel)
fio --name=iou-cmd --filename=/dev/ng0n1 --rw=randread --bs=4k \
    --ioengine=io_uring_cmd --cmd_type=nvme \
    --iodepth=32 --time_based --runtime=$RUNTIME

# Typical results on a fast NVMe + recent server (illustrative):
#   psync:                ~150K IOPS
#   libaio:               ~800K IOPS
#   io_uring basic:       ~850K IOPS
#   io_uring fixed:       ~950K IOPS
#   io_uring SQPOLL:      ~1M+ IOPS
#   io_uring uring_cmd:   ~1.1M+ IOPS (when block layer overhead is significant)
```

---

## 8. When io_uring Does NOT Help

```
io_uring adds complexity. Use it only when one of these applies:
  - You are CPU-bound on syscall overhead or buffer mapping
  - Sustained IOPS > 200K (below that, the differences are noise)
  - You need async I/O with minimal latency variance (no thread pool needed)

io_uring does NOT help when:
  - Storage is the bottleneck (slow HDD, GC-stalled SSD)
  - IOPS < 100K (syscall overhead is negligible vs I/O latency)
  - Application already I/O-wait bound (more async doesn't help)
  - Simple sequential workload — buffered I/O or O_DIRECT + read() works fine

SQPOLL specifically:
  Worthwhile only for sustained >500K IOPS workloads
  Burns one CPU continuously
  Don't enable for occasional bursts — it'll waste a core during idle periods
```

---

## 9. Source Reading Checklist

```
io_uring/io_uring.c     — ring setup, syscall entry, main dispatch
io_uring/rw.c           — read/write operations (io_read, io_write)
io_uring/rsrc.c         — fixed buffer and file registration
io_uring/uring_cmd.c    — NVMe passthrough infrastructure
io_uring/sqpoll.c       — SQPOLL kernel thread
include/linux/io_uring.h         — kernel-side structs
include/uapi/linux/io_uring.h    — UAPI (SQE, CQE, flags)

drivers/nvme/host/ioctl.c        — NVMe's uring_cmd implementation
```

Reading order: `io_uring.c` setup + entry (`io_uring_setup`, `io_uring_enter`),
then `rw.c` for the I/O paths, then `rsrc.c` for the buffer/file registration
paths. `sqpoll.c` and `uring_cmd.c` are smaller and read quickly once the
core is clear.

---

## 10. Self-Check Questions

1. What does fixed buffer registration eliminate vs normal O_DIRECT, and at what IOPS does the saving become significant?
2. What is SQPOLL mode and what is its cost in system resources?
3. NVMe passthrough via io_uring uses `/dev/ng0n1` rather than `/dev/nvme0n1`. What is the difference?
4. At 100K IOPS, is io_uring with fixed buffers significantly faster than O_DIRECT + libaio? Justify.
5. An application does 500K IOPS of 4 KB random reads on NVMe. It currently uses O_DIRECT + libaio and is CPU-bound. Which io_uring features would you enable, in what order?
6. `IORING_OP_URING_CMD` bypasses the filesystem and blk-mq. What does this mean for I/O scheduler policies and cgroup I/O limits?
7. Why does NVMe passthrough via io_uring require `IORING_SETUP_SQE128`?

## 11. Answers

1. Fixed buffers eliminate `get_user_pages()` (pin user pages for DMA) and `put_page()` (unpin on completion) per I/O. These involve atomic refcount operations and page table walking. At 100K IOPS the overhead is modest (~5-10% of CPU). At 500K IOPS it's significant (15-25%). Rule of thumb: above ~200K IOPS on fast NVMe, fixed buffers provide measurable throughput improvement; below that, the difference is within noise.
2. SQPOLL creates a dedicated kernel thread that continuously polls the SQ ring for new submissions, eliminating the `io_uring_enter()` syscall for submission. Cost: one CPU core fully (or partially, if `sq_thread_idle` parks it during quiet periods). The thread can be pinned to a specific CPU via `IORING_SETUP_SQ_AFF` + `sq_thread_cpu`. Only worthwhile for sustained very-high-IOPS workloads where the syscall savings exceed the dedicated-core cost.
3. `/dev/nvme0n1` is a block device managed by blk-mq — I/O goes through the full block layer (filesystem, dm layers, I/O scheduler, etc.). `/dev/ng0n1` (`ng` = NVMe generic) is a character device that allows direct ioctl and `uring_cmd` access to the NVMe controller, bypassing blk-mq entirely. `uring_cmd` requires the char device; regular block I/O uses the block device.
4. No — at 100K IOPS, the buffer mapping and syscall overheads are small relative to I/O time. The difference between libaio and io_uring fixed buffers at 100K IOPS is typically <5% and often within measurement noise. The benefit becomes significant above 200-300K IOPS, where per-I/O kernel overhead starts to dominate.
5. In priority order: (1) `IORING_REGISTER_BUFFERS` — fixed buffers eliminate the per-I/O page pinning that's most likely causing CPU saturation. (2) `IORING_REGISTER_FILES` — registered files eliminate per-I/O fd table lookup. (3) If still CPU-bound: enable SQPOLL (`IORING_SETUP_SQPOLL`) to eliminate submission syscalls. (4) If still bottlenecked and the workload doesn't need filesystem features: switch to `IORING_OP_URING_CMD` against `/dev/ng*` for full block-layer bypass.
6. `uring_cmd` bypasses blk-mq entirely — requests go directly from io_uring to the NVMe driver's ioctl handler. Consequences: (a) I/O scheduler completely bypassed — no BFQ fairness, no mq-deadline ordering. (b) cgroup `io.max`, `io.latency`, and `io.weight` are NOT enforced (those work in blk-mq). (c) blktrace block-layer events don't capture these I/Os. (d) Any device-mapper layers below the filesystem (dm-crypt, dm-cache, md) are bypassed too. Architect implication: passthrough gives performance but sacrifices kernel I/O management and isolation.
7. The standard `io_uring_sqe` is 64 bytes; only ~16 bytes are available for command-specific payload. NVMe passthrough requires sending a `struct nvme_uring_cmd` (72 bytes) embedded in the SQE. `IORING_SETUP_SQE128` doubles the SQE size to 128 bytes, providing room for the embedded NVMe command structure plus addressing fields. Without `SQE128`, there isn't enough space to fit the full passthrough command in the SQE.

---

## 12. Architect Perspective — Is io_uring a Syscall Path?

**Short answer: no. io_uring is specifically designed to eliminate syscalls from the hot I/O path.**

### Three operational modes

| Mode | Syscall per I/O | Mechanism |
|------|----------------|-----------|
| Default | ~1 per **batch** | `io_uring_enter()` submits N SQEs at once; amortized cost approaches zero at high IOPS |
| SQPOLL (`IORING_SETUP_SQPOLL`) | **0** | Kernel thread polls SQ ring; app writes SQE, kernel picks it up without any syscall |
| Hybrid | 0 when busy, 1 on idle wake | SQPOLL with `sq_thread_idle` timeout; `io_uring_enter()` only used to wake the sleeping thread |

Completion path is **always zero syscalls** — app polls the CQ ring directly via shared memory.

### Syscall overhead math

At 1M IOPS, syscall cost compounds fast:

```
read()/write():         1M syscalls/sec × 150ns = 150ms CPU/sec overhead per core
libaio io_submit():     1 syscall per submission (still 1M/sec at 1 SQE/call)
io_uring (batched):     1 syscall per 64 SQEs → ~16K syscalls/sec → ~2.4ms overhead
io_uring (SQPOLL):      0 syscalls → 0 overhead, but 1 dedicated CPU core spinning
```

This is why io_uring matters at NVMe speeds. At HDD speeds (100–200 IOPS), the syscall cost is invisible.

### SQPOLL trade-off

SQPOLL eliminates syscall overhead but burns a CPU core. Use it only when:
- Sustained I/O rate > ~500K IOPS where syscall savings exceed the dedicated-core cost
- The machine has spare CPU capacity (NVMe workloads on high-core-count servers)
- Workload is sustained, not bursty (a bursty workload wastes the spinning core during idle gaps)

For lower IOPS, default batched `io_uring_enter()` gives most of the benefit without the core cost.

### Comparison to other I/O APIs

```
read()/write()          → 1 syscall per I/O, blocking, data copied through kernel buffer
preadv2() + O_DIRECT    → 1 syscall per I/O, avoids buffer copy, still 1 syscall
libaio (aio_submit)     → 1 syscall per submission + 1 syscall per completion poll
io_uring (default)      → 1 syscall per batch of N I/Os; completions are syscall-free
io_uring (SQPOLL)       → 0 syscalls on hot path; completions are syscall-free
```

### The architectural insight

io_uring's design premise: **at NVMe speeds (~20µs device latency), a 150ns syscall per I/O is not free — it is 0.75% overhead per I/O, and it serializes across CPUs**. Shared-memory rings remove the syscall boundary entirely. The kernel and user space share the same physical memory for SQ/CQ — no copy, no context switch, no cache line bounce on the submission/completion path.

This is the same insight as DPDK (bypass kernel network stack) and SPDK (bypass kernel block stack) — the kernel boundary itself is the bottleneck, not just the kernel's internal logic.

---

## Tomorrow: Day 26 — ZNS: Zone Types, Write Pointer & Zone Append

We understand Zoned Namespace NVMe devices, the zone model, and the
implications for storage software that was designed for random-write
devices.
