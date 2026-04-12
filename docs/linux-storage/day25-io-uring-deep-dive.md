# Day 25: io_uring — Fixed Buffers, Registered Files & NVMe Passthrough

## Learning Objectives
- Understand io_uring's SQ/CQ ring mechanics at source level
- Understand fixed buffer registration: what cost it eliminates and why
- Understand registered files: what cost that eliminates
- Write programs using: basic io_uring, fixed buffers, NVMe passthrough
- Know when io_uring outperforms O_DIRECT and when it doesn't

---

## 1. SQ/CQ Ring Mechanics

io_uring uses two ring buffers shared between kernel and userspace via mmap.
No syscall needed per I/O — the kernel and userspace communicate through
shared memory.

```c
// io_uring/io_uring.c

// Setup: io_uring_setup() creates the rings
struct io_rings {
    struct io_uring_sq sq;    // submission queue metadata
    struct io_uring_cq cq;    // completion queue metadata
    // ...
};

// Submission Queue Entry (SQE) — one per I/O operation
struct io_uring_sqe {
    __u8    opcode;         // IORING_OP_READ, IORING_OP_WRITE, ...
    __u8    flags;          // IOSQE_FIXED_FILE, IOSQE_BUFFER_SELECT, ...
    __u16   ioprio;
    __s32   fd;             // file descriptor (or registered file index)
    __u64   off;            // file offset
    __u64   addr;           // buffer address (or fixed buffer index)
    __u32   len;            // transfer length
    __u32   buf_index;      // index into registered buffer table
    __u64   user_data;      // opaque user data, returned in CQE
    // ...
};

// Completion Queue Entry (CQE) — one per completed I/O
struct io_uring_cqe {
    __u64   user_data;      // matches SQE user_data (identifies the I/O)
    __s32   res;            // result: bytes transferred or -errno
    __u32   flags;
};
```

**The zero-syscall path:**
```
Submit I/O:
  1. Write SQE to sq.sqes[sq.tail & sq.ring_mask]
  2. Increment sq.tail (visible to kernel via shared memory)
  3. Call io_uring_enter(ring_fd, to_submit, ...) [one syscall for many I/Os]
     OR: if SQPOLL mode: kernel thread polls SQ — ZERO syscalls for submission

Receive completion:
  1. Poll cq.head != cq.tail (check shared memory — no syscall)
  2. Read CQE from cq.cqes[cq.head & cq.ring_mask]
  3. Increment cq.head (visible to kernel — no syscall)
```

---

## 2. Fixed Buffer Registration: The Key Optimization

Every normal I/O (read/write) requires the kernel to:
1. Map the user buffer into kernel address space (pin pages)
2. Set up DMA scatter-gather list
3. Perform DMA
4. Unmap buffer (unpin pages)

Steps 1 and 4 are expensive at high IOPS — `get_user_pages` and `put_page`
under lock pressure. At 500K IOPS: millions of pin/unpin operations per second.

**Fixed buffers pre-register buffers once:**

```c
// io_uring/rsrc.c

// Register buffers once at setup time:
io_uring_register(ring_fd, IORING_REGISTER_BUFFERS, iovecs, nr_iovecs)
    // Kernel: pin all pages in the iovecs NOW (once)
    //         build DMA maps for all registered buffers (once)
    //         store in ring->ctx->user_bufs[]

// Use pre-registered buffer in SQE:
sqe->opcode  = IORING_OP_READ;
sqe->flags   = IOSQE_BUFFER_FIXED;  // use fixed buffer
sqe->buf_index = 3;                  // index into registered buffer table
// NO addr field needed — kernel already has the DMA map

// Result: zero per-I/O buffer mapping cost
```

```c
// Example: fixed buffer read with liburing
#include <liburing.h>

struct io_uring ring;
io_uring_queue_init(32, &ring, 0);

// Allocate and register buffers (once at startup)
char *bufs[8];
struct iovec iovecs[8];
for (int i = 0; i < 8; i++) {
    posix_memalign((void**)&bufs[i], 4096, 65536);  // 64KB buffers
    iovecs[i].iov_base = bufs[i];
    iovecs[i].iov_len  = 65536;
}
io_uring_register_buffers(&ring, iovecs, 8);

// Submit reads using fixed buffers (no per-I/O mapping)
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_read_fixed(sqe, fd, bufs[0], 65536, offset, 0); // buf_index=0
sqe->user_data = 1;
io_uring_submit(&ring);

// Wait for completion
struct io_uring_cqe *cqe;
io_uring_wait_cqe(&ring, &cqe);
printf("Read %d bytes\n", cqe->res);
io_uring_cqe_seen(&ring, cqe);
```

---

## 3. Registered Files: Eliminating fd Table Lookups

Every I/O syscall performs `fdget()` — looks up the file from the fd table,
increments reference count. At 500K IOPS: 500K fdget/fdput pairs per second.

**Registered files pre-resolve file descriptors:**

```c
// Register files once:
io_uring_register(ring_fd, IORING_REGISTER_FILES, fds, nr_fds)
    // Kernel: resolve each fd → struct file* NOW (once)
    //         store file* array in ring context
    //         increment file refcount once

// Use registered file in SQE:
sqe->flags = IOSQE_FIXED_FILE;
sqe->fd    = 2;   // index into registered file table (not actual fd)

// Result: zero per-I/O fd table lookup
```

---

## 4. io_uring Kernel Path for Read/Write

```c
// io_uring/rw.c

io_read(req, issue_flags):
    // 1. Get iovec from SQE (or fixed buffer)
    // 2. Call iomap_dio_rw() or kiocb-based read
    //    (same as O_DIRECT for files opened with O_DIRECT)
    //    OR: go through page cache (for buffered files)
    // 3. Set up async completion callback
    // 4. Return to caller (non-blocking — I/O happens asynchronously)

// On I/O completion (interrupt/callback):
io_complete_rw():
    // Post CQE to completion ring
    io_cqring_add_event(req, res, 0)
    // User sees completion by polling CQ
```

---

## 5. NVMe Passthrough via io_uring (`uring_cmd`)

`uring_cmd` (kernel 5.19+) allows sending raw NVMe commands via io_uring,
combining async I/O with NVMe passthrough — the highest-performance
kernel-accessible I/O path.

```c
// io_uring/uring_cmd.c + drivers/nvme/host/ioctl.c

// SQE for NVMe passthrough:
sqe->opcode = IORING_OP_URING_CMD;
sqe->fd     = nvme_fd;      // open("/dev/ng0n1", O_RDWR)  ← note: ng0n1, not nvme0n1
sqe->cmd_op = NVME_URING_CMD_IO;
// The actual NVMe command is embedded in sqe->cmd (80 bytes)

struct nvme_uring_cmd *cmd = (void *)sqe->cmd;
cmd->opcode    = nvme_cmd_read;   // 0x02
cmd->nsid      = 1;
cmd->cdw10     = start_lba & 0xffffffff;
cmd->cdw11     = start_lba >> 32;
cmd->cdw12     = (nlb - 1);       // number of LBAs - 1
cmd->addr      = (uint64_t)buf;   // data buffer (or fixed buffer index)
cmd->data_len  = nlb * 512;
```

```c
// Example: NVMe passthrough read with io_uring
#include <liburing.h>
#include <linux/nvme_ioctl.h>

int ng_fd = open("/dev/ng0n1", O_RDWR);  // generic NVMe char device
struct io_uring ring;
io_uring_queue_init(32, &ring, 0);

struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_URING_CMD;
sqe->fd     = ng_fd;
sqe->cmd_op = NVME_URING_CMD_IO;

struct nvme_uring_cmd *cmd = (void *)sqe->cmd;
memset(cmd, 0, sizeof(*cmd));
cmd->opcode   = nvme_cmd_read;
cmd->nsid     = 1;
cmd->cdw10    = 0;          // LBA 0
cmd->cdw12    = 7;          // 8 LBAs = 4KB
cmd->addr     = (uint64_t)buf;
cmd->data_len = 4096;

sqe->user_data = 42;
io_uring_submit(&ring);

struct io_uring_cqe *cqe;
io_uring_wait_cqe(&ring, &cqe);
// cqe->res == 0 on success
```

**Why this matters:**
```
Normal block I/O path:
  Application → syscall → VFS → filesystem → blk-mq → NVMe driver → device

io_uring + NVMe passthrough:
  Application → SQ ring → io_uring → NVMe driver → device
                                   ↑ filesystem and blk-mq scheduler bypassed

Combined with fixed buffers: also eliminates per-I/O buffer mapping
→ Minimum possible kernel overhead for NVMe I/O without full SPDK userspace driver
```

---

## 6. Performance: When io_uring Wins vs O_DIRECT

```bash
# Benchmark 1: O_DIRECT with libaio (traditional async I/O)
fio --name=libaio-direct \
    --filename=/dev/nvme0n1 \
    --rw=randread --bs=4k \
    --ioengine=libaio \
    --iodepth=32 \
    --direct=1 \
    --time_based --runtime=30

# Benchmark 2: io_uring basic (same as O_DIRECT, async)
fio --name=iou-basic \
    --filename=/dev/nvme0n1 \
    --rw=randread --bs=4k \
    --ioengine=io_uring \
    --iodepth=32 \
    --direct=1 \
    --time_based --runtime=30

# Benchmark 3: io_uring with fixed buffers
fio --name=iou-fixedbuf \
    --filename=/dev/nvme0n1 \
    --rw=randread --bs=4k \
    --ioengine=io_uring \
    --iodepth=32 \
    --direct=1 \
    --registerfiles=1 \
    --fixedbufs=1 \
    --time_based --runtime=30

# Benchmark 4: io_uring with SQPOLL (zero-syscall submission)
fio --name=iou-sqpoll \
    --filename=/dev/nvme0n1 \
    --rw=randread --bs=4k \
    --ioengine=io_uring \
    --iodepth=32 \
    --direct=1 \
    --sqthread_poll=1 \
    --registerfiles=1 \
    --fixedbufs=1 \
    --time_based --runtime=30

# Expected results (fast NVMe, 32-core server):
# libaio:        ~800K IOPS
# io_uring basic: ~850K IOPS (slightly better CQ batching)
# io_uring fixed: ~950K IOPS (eliminates buffer mapping overhead)
# io_uring SQPOLL: ~1M+ IOPS (zero syscall overhead, dedicated kernel thread)
```

---

## 7. When io_uring Does NOT Help

```
io_uring adds complexity. Use it only when:
  - You're CPU-bound on syscall/buffer-mapping overhead
  - IOPS > 200K (below this, overhead difference is negligible)
  - You need async I/O with minimal latency (no thread pool needed)

io_uring does NOT help when:
  - Storage is the bottleneck (slow HDD, bcache-with-GC-pressure)
  - IOPS < 100K (syscall overhead is negligible vs I/O latency)
  - Application is already I/O-wait bound (adding async complexity won't help)
  - Simple sequential workload (buffered I/O or O_DIRECT + read() is fine)

io_uring with SQPOLL:
  - Dedicates a kernel CPU thread to polling SQ (burns 1 CPU even when idle)
  - Only worthwhile at sustained very high IOPS (>500K)
  - Must register files and buffers, or SQPOLL provides no benefit
```

---

## 8. Source Code Map

```
io_uring/io_uring.c     — ring setup, syscall entry, main dispatch
io_uring/rw.c           — read/write operations
io_uring/rsrc.c         — fixed buffer and file registration
io_uring/uring_cmd.c    — NVMe passthrough (uring_cmd)
io_uring/sqpoll.c       — SQPOLL kernel thread

Key functions to read:
  io_uring_setup()          — creates rings, validates params
  io_submit_sqes()          — processes SQEs from ring
  io_read() / io_write()    — buffered and direct I/O ops
  io_uring_cmd_import_fixed()  — fixed buffer for uring_cmd
  io_sq_thread()            — SQPOLL kernel thread main loop
```

---

## 9. Self-Check Questions

1. What does fixed buffer registration eliminate vs normal O_DIRECT, and at what IOPS does the saving become significant?
2. What is SQPOLL mode and what is its cost in terms of system resources?
3. NVMe passthrough via io_uring uses `/dev/ng0n1` rather than `/dev/nvme0n1`. What is the difference?
4. At 100K IOPS, is io_uring with fixed buffers significantly faster than O_DIRECT with libaio? Justify.
5. An application does 500K IOPS of 4K random reads on NVMe. It currently uses O_DIRECT + libaio and is CPU-bound. Which io_uring features would you enable first?
6. io_uring IORING_OP_URING_CMD bypasses the filesystem and blk-mq. What does this mean for I/O scheduler policies and cgroup I/O limits?

## 10. Answers

1. Fixed buffers eliminate `get_user_pages()` (pin) and `put_page()` (unpin) per I/O. These pin/unpin operations involve page table walking and atomic operations. At 100K IOPS: 100K pin+unpin pairs/sec — measurable but not dominant. At 500K IOPS: 500K pairs/sec — becomes significant CPU overhead. Rule of thumb: above 200-300K IOPS on fast NVMe, fixed buffers provide measurable throughput improvement.
2. SQPOLL creates a dedicated kernel thread that continuously polls the SQ ring for new submissions, eliminating the `io_uring_enter()` syscall for submission. Cost: one dedicated CPU core (or a fraction of one if idle timeout is configured). The SQPOLL thread is always running — burns CPU even when no I/O is submitted. Use only for sustained very high IOPS workloads that can justify the dedicated CPU.
3. `/dev/nvme0n1` is a block device managed by blk-mq — I/O goes through the full block layer. `/dev/ng0n1` (`ng` = NVMe generic) is a character device that allows direct ioctl and uring_cmd access to the NVMe controller, bypassing blk-mq entirely. `uring_cmd` requires the char device; regular block I/O uses the block device.
4. No — at 100K IOPS, buffer mapping overhead (~100K × ~1µs per pin/unpin ≈ 100ms/sec total CPU time) is small relative to I/O time and other overheads. The difference between libaio and io_uring fixed buffers at 100K IOPS is typically <5% and within measurement noise. The benefit becomes significant above 200-300K IOPS.
5. Enable in priority order: (1) `IORING_REGISTER_BUFFERS` (fixed buffers) — eliminates the per-I/O page pinning that's most likely causing CPU saturation. (2) `IORING_REGISTER_FILES` (registered files) — eliminates fd table lookup. (3) If still CPU-bound after (1) and (2): enable SQPOLL (`IORING_SETUP_SQPOLL`) — eliminates submission syscall, at cost of one dedicated CPU thread.
6. `uring_cmd` bypasses blk-mq entirely — the request goes from io_uring directly to the NVMe driver's ioctl handler. Consequences: (a) I/O scheduler is completely bypassed — no BFQ fairness, no mq-deadline ordering. (b) cgroup `io.max`, `io.latency`, and `io.weight` are NOT enforced (blk-cgroup enforcement happens in blk-mq, which is bypassed). (c) blktrace block layer events won't capture these I/Os. Architect implication: NVMe passthrough gives performance but sacrifices all kernel-level I/O management and isolation guarantees.

---

## Tomorrow: Day 26 — ZNS: Zone Types, Write Pointer & Zone Append

We understand Zoned Namespace NVMe devices, the zone model, and the
implications for storage software that was designed for random-write devices.
