# Day 02 — Socket Layer: `struct sock` and the BSD Socket API
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 1)

---

## 🎯 Goal
Understand how a userspace `socket()` call maps to kernel structures, and how `struct sock` sits at the center of every connection.

---

## 1. The Socket Abstraction Stack

```
userspace fd  (int sockfd)
      │
      ▼
struct file          (fs/file.c)
      │  .private_data
      ▼
struct socket        (include/linux/net.h)   ← VFS-facing
      │  .sk
      ▼
struct sock          (include/net/sock.h)    ← protocol-facing
      │
      ▼ (embedded / cast)
struct tcp_sock / udp_sock / inet_sock       (protocol-specific)
```

The key insight: **`struct socket` is the VFS glue; `struct sock` is the actual network state machine.**

---

## 2. `struct socket` — The VFS Bridge

**Source:** `include/linux/net.h`

```c
struct socket {
    socket_state        state;       // SS_UNCONNECTED, SS_CONNECTED, …
    short               type;        // SOCK_STREAM, SOCK_DGRAM, …
    const struct proto_ops *ops;     // protocol operations table
    struct file         *file;       // back pointer to VFS file
    struct sock         *sk;         // the actual protocol sock
    struct fasync_struct *fasync_list;
};
```

### `proto_ops` — the protocol dispatch table
```c
// Example: TCP's proto_ops (net/ipv4/af_inet.c)
const struct proto_ops inet_stream_ops = {
    .family     = PF_INET,
    .bind       = inet_bind,
    .connect    = inet_stream_connect,
    .accept     = inet_accept,
    .sendmsg    = inet_sendmsg,
    .recvmsg    = inet_recvmsg,
    .poll       = tcp_poll,
    .listen     = inet_listen,
    .shutdown   = inet_shutdown,
    .release    = inet_release,
    // ...
};
```
This is the classic **operations table** pattern — same idea as `file_operations` in the VFS.

---

## 3. `struct sock` — The Heart of a Connection

**Source:** `include/net/sock.h`

Key fields (simplified):

```c
struct sock {
    /* --- addressing --- */
    struct sock_common  __sk_common;    // holds src/dst addr, port, family
    // convenience macros: sk_family, sk_state, sk_daddr, sk_rcv_saddr

    /* --- queues --- */
    struct sk_buff_head sk_receive_queue;   // inbound data waiting for recv()
    struct sk_buff_head sk_write_queue;     // outbound data waiting to send
    struct sk_buff_head sk_error_queue;

    /* --- socket buffer limits --- */
    int     sk_rcvbuf;      // max receive buffer (bytes)
    int     sk_sndbuf;      // max send buffer (bytes)
    atomic_t sk_rmem_alloc; // current receive memory
    atomic_t sk_wmem_alloc; // current write memory

    /* --- callbacks / waitqueue --- */
    void    (*sk_data_ready)(struct sock *sk);   // called when data arrives
    void    (*sk_write_space)(struct sock *sk);  // called when send buffer frees
    wait_queue_head_t sk_wq;                     // blocking recv/send waiters

    /* --- protocol --- */
    struct proto    *sk_prot;       // TCP/UDP/RAW protocol operations
    int             sk_type;        // SOCK_STREAM, SOCK_DGRAM, ...
    int             sk_err;         // last error

    /* --- state --- */
    unsigned char   sk_state;       // TCP_ESTABLISHED, TCP_LISTEN, ...
};
```

### Protocol hierarchy via embedding
```c
struct inet_sock {
    struct sock     sk;     // MUST be first — allows casting
    // inet-specific: ttl, tos, id, mc_ttl, ...
};

struct tcp_sock {
    struct inet_connection_sock inet_conn;  // which embeds inet_sock → sock
    // TCP-specific: snd_una, snd_nxt, rcv_nxt, cwnd, ssthresh, ...
};
```

Cast pattern used throughout the kernel:
```c
struct tcp_sock *tp = tcp_sk(sk);    // macro: (struct tcp_sock *)(sk)
struct inet_sock *inet = inet_sk(sk);
```

---

## 4. The `socket()` Syscall Path

**Source:** `net/socket.c`

```
socket(AF_INET, SOCK_STREAM, 0)
  └── __sys_socket()
        └── sock_create()
              └── __sock_create()
                    ├── sock_alloc()              // allocate struct socket + inode
                    └── inet_create()             // net/ipv4/af_inet.c
                          ├── sk_alloc()          // allocate struct sock
                          ├── sock->ops = &inet_stream_ops
                          └── tcp_v4_init_sock()  // TCP-specific init
```

### Explore it:
```bash
grep -n "__sys_socket\|sock_create\|__sock_create" net/socket.c | head -20
grep -n "inet_create" net/ipv4/af_inet.c | head -10
grep -n "sk_alloc" net/core/sock.c | head -10
```

---

## 5. Receive Path: Data → `sk_receive_queue` → `recv()`

```
packet arrives at tcp_v4_rcv()
  └── sk = __inet_lookup_skb()    // find the matching struct sock
        └── tcp_rcv_established()
              └── sk_receive_queue  ← skb enqueued here
                                       (via __skb_queue_tail)
                    ▲
userspace: recv() → tcp_recvmsg()
              └── skb_dequeue(&sk->sk_receive_queue)
                    └── copy data to userspace buffer
```

### Key: the wake-up mechanism
```c
// When data is enqueued, the socket notifies waiters:
sk->sk_data_ready(sk);
// Default impl: sock_def_readable() in net/core/sock.c
// → wake_up_interruptible(sk->sk_wq) → unblocks blocked recv()
```

---

## 6. Hands-On

### 6a. Read the socket syscall
```bash
grep -n "SYSCALL_DEFINE3(socket" net/socket.c
# Read ~30 lines from that point
```

### 6b. Count TCP sock fields
```bash
grep -n "struct tcp_sock {" include/linux/tcp.h
# Look at how many fields TCP needs to track a connection
```

### 6c. Watch socket buffer usage live
```bash
# Show recv/send buffer sizes for all TCP sockets
ss -tmn

# Watch socket memory globally
watch -n1 'cat /proc/net/sockstat'

# See per-socket queues (Recv-Q, Send-Q)
ss -tnp state established
```

### 6d. `strace` a simple connect
```bash
strace -e trace=network nc -z localhost 22 2>&1 | head -20
# Observe: socket() → connect() → syscall numbers
```

---

## 7. Concept Check

1. What is the difference between `struct socket` and `struct sock`? Why are there two?
2. How does the kernel find the right `struct sock` when a TCP segment arrives?
3. What happens (in kernel code) when `recv()` is called but no data is in `sk_receive_queue`?
4. Why does `struct tcp_sock` embed `struct inet_connection_sock` instead of `struct sock` directly?

---

## 📚 References
- `include/linux/net.h` — `struct socket`
- `include/net/sock.h` — `struct sock`
- `net/socket.c` — syscall implementations
- `net/ipv4/af_inet.c` — AF_INET socket creation
- `net/core/sock.c` — generic socket helpers
