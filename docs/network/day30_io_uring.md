# Day 30 — `io_uring` and Network I/O
> **Time:** 1–2 hours | **Track:** Linux Networking (Day 30/30 — Final)

---

## 🎯 Goal
Understand how `io_uring` brings async, batched, zero-syscall I/O to network operations, how it integrates with sockets, and how it compares to `epoll` for high-performance servers.

---

## 1. The Problem `io_uring` Solves

Traditional network I/O has two costs per operation:

```
1. Syscall overhead:
   send() → trap → kernel mode → return → user mode
   Each syscall: ~1μs context switch + TLB flush

2. Per-syscall round-trip:
   Single send → single syscall
   100k sends/sec → 100k syscalls/sec → ~10% CPU just on syscalls

io_uring solution:
   Submit 64 operations in one syscall (or zero syscalls with SQPOLL)
   Collect 64 completions in one syscall
   → syscall cost amortized over batch
```

---

## 2. `io_uring` Architecture

**Source:** `io_uring/`, `include/uapi/linux/io_uring.h`

`io_uring` uses two **shared memory rings** between kernel and userspace — no data is copied through syscalls:

```
User Space                          Kernel Space
──────────────────────              ──────────────────────
Submission Queue (SQ)               io_uring instance
  [sqe][sqe][sqe][sqe]    ──────►   dequeue SQEs
  ↑ app writes here                 execute operations
  sq_tail                           │
  sq_head (kernel updates)          ▼
                                    Completion Queue (CQ)
Completion Queue (CQ)   ◄──────     [cqe][cqe][cqe][cqe]
  [cqe][cqe][cqe][cqe]              kernel writes here
  ↑ app reads here                  cq_tail (kernel updates)
  cq_head (app updates)
```

Both rings are **mmap'd** into userspace — the kernel and app share them directly. No data crosses the syscall boundary for the I/O itself.

---

## 3. Core Data Structures

**Source:** `include/uapi/linux/io_uring.h`

### SQE — Submission Queue Entry (app → kernel)
```c
struct io_uring_sqe {
    __u8    opcode;         // IORING_OP_RECV, IORING_OP_SEND, etc.
    __u8    flags;          // IOSQE_FIXED_FILE, IOSQE_IO_LINK, ...
    __u16   ioprio;
    __s32   fd;             // file descriptor
    union {
        __u64 off;          // offset (for file ops)
        __u64 addr2;
    };
    union {
        __u64 addr;         // pointer to buffer
        __u64 splice_off_in;
    };
    __u32   len;            // buffer length / number of vectors
    union {
        __kernel_rwf_t rw_flags;
        __u32 fsync_flags;
        __u16 poll_events;
        __u32 sync_range_flags;
        __u32 msg_flags;    // flags for send/recv (MSG_WAITALL, etc.)
        __u32 timeout_flags;
        __u32 accept_flags;
        __u32 cancel_flags;
        __u32 open_flags;
        __u32 statx_flags;
        __u32 fadvise_advice;
        __u32 splice_flags;
        __u32 rename_flags;
        __u32 unlink_flags;
        __u32 hardlink_flags;
        __u32 xattr_flags;
        __u32 msg_ring_flags;
        __u32 uring_cmd_flags;
    };
    __u64   user_data;      // returned unchanged in CQE — your correlation ID
    union {
        __u16 buf_index;    // for registered buffers
        __u16 buf_group;    // for buffer ring
    };
    __u16   personality;
    union {
        __s32 splice_fd_in;
        __u32 file_index;
    };
    union {
        struct { __u64 addr3; __u64 __pad2[1]; };
        __u8 cmd[0];
    };
};
```

### CQE — Completion Queue Entry (kernel → app)
```c
struct io_uring_cqe {
    __u64   user_data;   // matches sqe->user_data — correlation
    __s32   res;         // result: bytes transferred, or -errno on error
    __u32   flags;       // IORING_CQE_F_MORE, IORING_CQE_F_BUFFER, ...
};
```

---

## 4. Network Operations

### Key opcodes for networking
```c
IORING_OP_ACCEPT        // accept() — non-blocking accept on listening socket
IORING_OP_CONNECT       // connect() — async connect
IORING_OP_RECV          // recv() — receive data
IORING_OP_SEND          // send() — send data
IORING_OP_RECVMSG       // recvmsg() — receive with msghdr
IORING_OP_SENDMSG       // sendmsg() — send with msghdr
IORING_OP_RECV_MULTISHOT // keep re-arming recv without re-submission
IORING_OP_ACCEPT_MULTISHOT // keep accepting new connections
IORING_OP_POLL_ADD      // poll() equivalent — wait for fd readiness
IORING_OP_SEND_ZC       // zero-copy send (kernel 6.0+)
IORING_OP_SENDMSG_ZC    // zero-copy sendmsg (kernel 6.0+)
```

---

## 5. Lifecycle: Setup and Usage

### 5a. Setup
```c
/* 1. Create io_uring instance */
struct io_uring_params params = {};
int ring_fd = io_uring_setup(QUEUE_DEPTH, &params);
/* Returns fd; params filled with actual sizes and features */

/* 2. mmap the rings into userspace */
/* SQ ring */
sq_ptr = mmap(NULL, params.sq_off.array + params.sq_entries * sizeof(u32),
              PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE,
              ring_fd, IORING_OFF_SQ_RING);

/* CQ ring */
cq_ptr = mmap(NULL, params.cq_off.cqes + params.cq_entries * sizeof(struct io_uring_cqe),
              PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE,
              ring_fd, IORING_OFF_CQ_RING);

/* SQE array */
sqes = mmap(NULL, params.sq_entries * sizeof(struct io_uring_sqe),
            PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE,
            ring_fd, IORING_OFF_SQES);
```

### 5b. Submit a recv operation
```c
/* Get next SQE slot */
unsigned tail = *sq_tail;
struct io_uring_sqe *sqe = &sqes[tail & sq_mask];

/* Fill SQE */
sqe->opcode    = IORING_OP_RECV;
sqe->fd        = client_fd;
sqe->addr      = (uint64_t)recv_buf;
sqe->len       = sizeof(recv_buf);
sqe->user_data = (uint64_t)client_fd;  // correlation: which fd completed

/* Advance SQ tail (visible to kernel after io_uring_enter) */
(*sq_tail)++;

/* Submit to kernel (one syscall for many SQEs) */
io_uring_enter(ring_fd, 1 /*to_submit*/, 0 /*min_complete*/, 0 /*flags*/);
```

### 5c. Collect completions
```c
/* Check CQ (no syscall needed if CQEs are already there) */
unsigned head = *cq_head;
while (head != *cq_tail) {
    struct io_uring_cqe *cqe = &cqes[head & cq_mask];

    int fd   = (int)cqe->user_data;
    int res  = cqe->res;   /* bytes received, or -EAGAIN, -ECONNRESET, etc. */

    if (res > 0) {
        process_data(fd, recv_buf, res);
        /* Re-arm: submit another RECV for this fd */
    } else if (res == 0) {
        close(fd);   /* EOF */
    } else {
        handle_error(fd, -res);
    }

    head++;
}
*cq_head = head;  /* advance head — tell kernel we consumed these CQEs */
```

---

## 6. Key Features for Network Servers

### Fixed files (registered fds)
```c
/* Register fds once — kernel pins them, avoids per-op fd lookup */
int fds[MAX_CONNS] = { listen_fd, ... };
io_uring_register(ring_fd, IORING_REGISTER_FILES, fds, nfds);

/* Use registered fd index instead of actual fd: */
sqe->fd = 0;              /* index 0 = listen_fd */
sqe->flags = IOSQE_FIXED_FILE;
```

### Fixed buffers (registered buffers)
```c
/* Register buffers once — kernel pins pages, avoids per-op pinning */
struct iovec iovecs[NBUFFERS];
for (int i = 0; i < NBUFFERS; i++) {
    iovecs[i].iov_base = buffers[i];
    iovecs[i].iov_len  = BUFFER_SIZE;
}
io_uring_register(ring_fd, IORING_REGISTER_BUFFERS, iovecs, NBUFFERS);

/* Use registered buffer by index: */
sqe->opcode    = IORING_OP_READ_FIXED;
sqe->buf_index = 3;   /* index into registered buffers */
```

### Multishot accept (kernel 5.19+)
```c
/* One SQE → many CQEs (one per accepted connection) */
sqe->opcode = IORING_OP_ACCEPT_MULTISHOT;
sqe->fd     = listen_fd;
sqe->flags  = IOSQE_FIXED_FILE;
/* No need to re-submit after each accept() */
```

### SQPOLL — zero-syscall submission (kernel thread polls SQ)
```c
params.flags = IORING_SETUP_SQPOLL;
params.sq_thread_idle = 2000;  /* idle timeout ms */
/* Kernel thread polls SQ ring continuously */
/* App writes SQEs → kernel picks them up WITHOUT io_uring_enter() */
/* Cost: dedicated kernel thread (CPU core) */
```

---

## 7. Kernel Implementation

**Source:** `io_uring/net.c`, `io_uring/io_uring.c`

```c
/* io_uring/net.c — IORING_OP_RECV handler */
int io_recv(struct io_kiocb *req, unsigned int issue_flags)
{
    struct io_sr_msg *sr = io_kiocb_to_cmd(req, struct io_sr_msg);
    struct socket *sock;
    struct msghdr msg;
    struct kvec iov;
    int ret;

    sock = sock_from_file(req->file);

    /* Set up kvec from SQE addr/len */
    iov.iov_base = u64_to_user_ptr(sr->buf);
    iov.iov_len  = sr->len;
    iov_iter_kvec(&msg.msg_iter, ITER_DEST, &iov, 1, sr->len);

    msg.msg_flags = sr->msg_flags | MSG_DONTWAIT;

    /* Call the socket's recvmsg — same path as regular recv() */
    ret = sock_recvmsg(sock, &msg, msg.msg_flags);

    if (ret == -EAGAIN) {
        /* Not ready: arm poll and requeue */
        io_poll_add_prep(req);    /* → epoll-like wait on sk->sk_wq */
        return -EAGAIN;
    }

    /* Complete: write CQE */
    io_req_set_res(req, ret, 0);
    return IOU_OK;
}
```

**Key insight:** `io_uring` ultimately calls the same `sock_recvmsg()` / `sock_sendmsg()` path as `recv()` / `send()`. The win is in batching, zero-copy buffer registration, and avoiding per-op syscalls — not in bypassing the socket layer.

---

## 8. `io_uring` vs `epoll` Comparison

| | `epoll` | `io_uring` |
|---|---|---|
| Model | Readiness notification | Completion notification |
| Syscall per op | `epoll_wait` + `recv`/`send` | One `io_uring_enter` for many ops |
| Zero-copy | No (MSG_ZEROCOPY separate) | Yes (`SEND_ZC`, fixed buffers) |
| Kernel thread | No | Optional (SQPOLL) |
| Multishot | No | Yes (accept, recv) |
| Buffer management | App manages | Can use kernel-provided buffers |
| Complexity | Low | Higher |
| Best for | Many connections, low ops/conn | High ops/conn, latency-critical |

### When to prefer `io_uring`:
- Many simultaneous read/write ops per connection (databases, file+net mix)
- Latency-critical with high throughput requirements
- Want to eliminate all syscall overhead (SQPOLL)
- Mixing file I/O and network I/O in the same event loop

### When to prefer `epoll`:
- Simple server (nginx-style: wait for data, recv, send response)
- Portability / mature ecosystem
- Large number of idle connections (io_uring has per-ring memory cost)

---

## 9. `liburing` — The Userspace Library

In practice, use `liburing` rather than raw syscalls:

```c
#include <liburing.h>

struct io_uring ring;
io_uring_queue_init(QUEUE_DEPTH, &ring, 0);

/* Submit recv */
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_recv(sqe, fd, buf, sizeof(buf), 0);
io_uring_sqe_set_data(sqe, (void *)(intptr_t)fd);
io_uring_submit(&ring);

/* Collect completion */
struct io_uring_cqe *cqe;
io_uring_wait_cqe(&ring, &cqe);
int result = cqe->res;
void *user_data = io_uring_cqe_get_data(cqe);
io_uring_cqe_seen(&ring, cqe);

io_uring_queue_exit(&ring);
```

---

## 10. Hands-On

### 10a. Check io_uring support
```bash
# Kernel version (io_uring needs 5.1+, network ops 5.6+, multishot 5.19+)
uname -r

# io_uring in kernel config
grep IO_URING /boot/config-$(uname -r) 2>/dev/null

# Check if liburing is available
pkg-config --exists liburing && echo "liburing found" || echo "not found"
dpkg -l liburing-dev 2>/dev/null | grep ii
```

### 10b. Explore io_uring source
```bash
ls ~/linux/io_uring/
# net.c: network operations
# io_uring.c: core ring management
# poll.c: poll/epoll integration

grep -n "IORING_OP_RECV\|IORING_OP_SEND\|IORING_OP_ACCEPT" \
    ~/linux/io_uring/opdef.c 2>/dev/null | head -15

grep -n "^int io_recv\|^int io_send\|^int io_accept" \
    ~/linux/io_uring/net.c 2>/dev/null | head -10
```

### 10c. Minimal io_uring echo server (requires liburing)
```c
/* Save as echo_uring.c, compile: gcc -o echo_uring echo_uring.c -luring */
#include <liburing.h>
#include <netinet/in.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

#define PORT 9999
#define QUEUE_DEPTH 64
#define BUF_SIZE 4096

enum { OP_ACCEPT, OP_RECV, OP_SEND };

typedef struct { int fd; int op; char buf[BUF_SIZE]; } conn_t;

int main(void)
{
    struct io_uring ring;
    io_uring_queue_init(QUEUE_DEPTH, &ring, 0);

    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = { .sin_family=AF_INET,
                                .sin_port=htons(PORT),
                                .sin_addr.s_addr=INADDR_ANY };
    bind(lfd, (struct sockaddr*)&addr, sizeof(addr));
    listen(lfd, 128);
    printf("Listening on :%d\n", PORT);

    /* Submit first accept */
    conn_t *c = calloc(1, sizeof(conn_t));
    c->op = OP_ACCEPT;
    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
    io_uring_prep_accept(sqe, lfd, NULL, NULL, 0);
    io_uring_sqe_set_data(sqe, c);
    io_uring_submit(&ring);

    struct io_uring_cqe *cqe;
    while (1) {
        io_uring_wait_cqe(&ring, &cqe);
        conn_t *ctx = io_uring_cqe_get_data(cqe);
        int res = cqe->res;
        io_uring_cqe_seen(&ring, cqe);

        if (ctx->op == OP_ACCEPT) {
            /* Re-arm accept */
            conn_t *nc = calloc(1, sizeof(conn_t)); nc->op = OP_ACCEPT;
            sqe = io_uring_get_sqe(&ring);
            io_uring_prep_accept(sqe, lfd, NULL, NULL, 0);
            io_uring_sqe_set_data(sqe, nc);
            /* Submit recv for new client */
            ctx->fd = res; ctx->op = OP_RECV;
            sqe = io_uring_get_sqe(&ring);
            io_uring_prep_recv(sqe, ctx->fd, ctx->buf, BUF_SIZE, 0);
            io_uring_sqe_set_data(sqe, ctx);
            io_uring_submit(&ring);
        } else if (ctx->op == OP_RECV && res > 0) {
            ctx->op = OP_SEND;
            sqe = io_uring_get_sqe(&ring);
            io_uring_prep_send(sqe, ctx->fd, ctx->buf, res, 0);
            io_uring_sqe_set_data(sqe, ctx);
            io_uring_submit(&ring);
        } else {
            close(ctx->fd); free(ctx);
        }
    }
}
```

### 10d. Compare syscall counts: epoll vs io_uring
```bash
# Count syscalls for a simple server with strace
strace -c -e trace=network,io_uring \
    python3 -c "
import socket
s = socket.socket()
s.bind(('127.0.0.1', 19998))
s.listen(1)
c, _ = s.accept()
c.recv(128)
c.send(b'ok')
c.close()
s.close()
" &

sleep 0.2
echo "hello" | nc 127.0.0.1 19998
wait 2>/dev/null
```

---

## 11. Concept Check

1. What is the fundamental difference between `epoll`'s readiness model and `io_uring`'s completion model? How does this affect buffer management?
2. How does `IORING_SETUP_SQPOLL` eliminate syscalls entirely on the submission side? What is the CPU trade-off?
3. `io_uring` calls `sock_recvmsg()` internally — the same function as `recv()`. Where then does `io_uring` actually save CPU time?
4. What is the advantage of registered buffers (`IORING_REGISTER_BUFFERS`) over normal buffers? What kernel operation does registration avoid on each I/O?

---

## 🎓 Course Complete — 30/30 Days

```
Week 1 (Days 01–07):  Foundation
  sk_buff, sockets, NIC/NAPI, IP, TCP RX, TCP TX, Netfilter

Week 2 (Days 08–14):  Core Mechanisms
  Buffers/memory, flow control, epoll, UDP, namespaces, qdisc, eBPF

Week 3 (Days 15–21):  Advanced Topics
  Zero-copy, multi-queue, TIME_WAIT, kTLS, ARP, routing, tuning

Week 4 (Days 22–28):  Expert Internals
  sk_buff lifecycle, softirq engine, TSQ/pacing, AF_XDP, observability,
  bridges/VXLAN, final mental model

Days 29–30:           Completion
  IPv6 internals, io_uring network I/O
```

You now have a complete, source-code-anchored understanding of the Linux network stack from NIC hardware interrupt to userspace application — every layer, every key data structure, every critical function.

---

## 📚 References
- `io_uring/net.c` — network operation handlers
- `io_uring/io_uring.c` — ring management, syscall entry
- `io_uring/poll.c` — readiness integration
- `include/uapi/linux/io_uring.h` — userspace API
- `liburing` — https://github.com/axboe/liburing
- Kernel docs: `Documentation/block/io-uring.rst`
- Jens Axboe's io_uring papers: https://kernel.dk/io_uring.pdf
