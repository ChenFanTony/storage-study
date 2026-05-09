# Day 08 — Socket Buffers and Memory Pressure
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 2)

---

## 🎯 Goal
Understand how the kernel manages memory for socket send/receive buffers, what happens under memory pressure, and how to tune buffer sizes for performance.

---

## 1. Two Kinds of Socket Memory

Every TCP socket has two buffer limits:

```
struct sock {
    int  sk_rcvbuf;      // max bytes for receive buffer
    int  sk_sndbuf;      // max bytes for send buffer

    atomic_t sk_rmem_alloc;  // current receive memory in use
    atomic_t sk_wmem_alloc;  // current write memory in use
    int      sk_wmem_queued; // bytes in write queue (sk_write_queue)
    int      sk_forward_alloc; // pre-allocated forward budget
};
```

### Receive buffer: `sk_receive_queue`
```
sk_receive_queue:  [skb1][skb2][skb3]...
                     │
                     sk_rmem_alloc tracks total bytes here
                     capped at sk_rcvbuf
```

### Send buffer: `sk_write_queue`
```
sk_write_queue:    [skb1][skb2][skb3]...
                   ← unacked data stays here for retransmit →
                     sk_wmem_queued tracks bytes here
                     capped at sk_sndbuf
```

---

## 2. Buffer Sizing: Auto-Tuning

**Source:** `net/ipv4/tcp_input.c` (`tcp_rcv_space_adjust`)

Linux auto-tunes socket buffer sizes based on observed throughput:

```c
void tcp_rcv_space_adjust(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    u32 copied;

    /* How many bytes did we copy to userspace since last check? */
    copied = tp->copied_seq - tp->rcvq_space.seq;

    /* If throughput improved, grow the receive buffer */
    if (copied > tp->rcvq_space.space) {
        int rcvmem, rcvbuf;

        /* Target: hold 2x RTT worth of data */
        rcvbuf = min_t(u32, copied * 2,
                       sock_net(sk)->ipv4.sysctl_tcp_rmem[2]); // max

        if (rcvbuf > sk->sk_rcvbuf) {
            sk->sk_rcvbuf = rcvbuf;
            /* Also grow TCP receive window advertised to peer */
            tcp_set_window_clamp(sk, rcvbuf / 2);
        }
    }

    tp->rcvq_space.space = copied;
    tp->rcvq_space.seq   = tp->copied_seq;
    tp->rcvq_space.time  = tcp_jiffies32;
}
```

### Sysctl knobs
```bash
# tcp_rmem: [min, default, max] for receive buffer
sysctl net.ipv4.tcp_rmem
# e.g.: 4096  131072  6291456

# tcp_wmem: [min, default, max] for send buffer
sysctl net.ipv4.tcp_wmem

# Enable auto-tuning (default: on)
sysctl net.ipv4.tcp_moderate_rcvbuf
```

---

## 3. Global Socket Memory Accounting

**Source:** `net/core/sock.c`, `net/ipv4/tcp_memcontrol.c`

The kernel tracks **total** memory used by all sockets via protocol-level memory pressure:

```c
// In struct proto (e.g., tcp_prot):
struct proto tcp_prot = {
    .name           = "TCP",
    .memory_pressure = &tcp_memory_pressure,
    .sysctl_mem     = sysctl_tcp_mem,   // [min, pressure, max] in pages
    .sysctl_wmem    = sysctl_tcp_wmem,
    .sysctl_rmem    = sysctl_tcp_rmem,
    /* ... */
};
```

### Three-zone memory model
```
tcp_mem[0] (min):      below this → no pressure, allocate freely
tcp_mem[1] (pressure): enter memory pressure mode
tcp_mem[2] (max):      hard limit, refuse new allocations
```

```bash
sysctl net.ipv4.tcp_mem
# e.g.: 185688  247584  371376  (in 4KB pages)
```

### Memory pressure mode
```c
/* When total TCP memory exceeds tcp_mem[1]: */
tcp_enter_memory_pressure(sk)
  └── WRITE_ONCE(*tp->memory_pressure, 1)
        → tcp_memory_pressure = 1

/* Effects: */
// - sk_rcvbuf and sk_sndbuf clamped to minimum
// - new skb allocations may fail (sk_stream_alloc_skb returns NULL)
// - send() may block or return EAGAIN
```

---

## 4. `sk_buff` Memory Allocation

**Source:** `net/core/skbuff.c`

```c
struct sk_buff *alloc_skb(unsigned int size, gfp_t priority)
{
    struct sk_buff *skb;
    u8 *data;

    /* Allocate skb descriptor from slab cache */
    skb = kmem_cache_alloc(skbuff_head_cache, priority & ~__GFP_DMA);

    /* Allocate data buffer */
    data = kmalloc_reserve(size, priority, NUMA_NO_NODE, &pfmemalloc);

    /* Initialize pointers */
    skb->head = data;
    skb->data = data;
    skb->tail = data;
    skb->end  = data + size;

    return skb;
}
```

### Socket-aware allocation: `sk_stream_alloc_skb()`
```c
struct sk_buff *sk_stream_alloc_skb(struct sock *sk, int size, gfp_t gfp,
                                     bool force_schedule)
{
    /* Check: would this exceed sk_sndbuf? */
    if (sk->sk_wmem_queued + size >= sk->sk_sndbuf) {
        set_bit(SOCK_NOSPACE, &sk->sk_socket->flags);
        return NULL;  // caller will block
    }

    skb = alloc_skb_fclone(size + sk->sk_prot->max_header, gfp);
    if (skb) {
        skb->truesize = SKB_TRUESIZE(size);
        sk_wmem_reserve(sk, skb->truesize);  // account against sndbuf
    }
    return skb;
}
```

### `skb->truesize` vs `skb->len`
```
skb->len      = actual payload bytes (what the application sees)
skb->truesize = total memory consumed (skb descriptor + data buffer)
                ≈ SKB_TRUESIZE(skb->len) = sizeof(sk_buff) + len + headroom
```

---

## 5. Blocking When Buffer Is Full

**Source:** `net/ipv4/tcp.c` (`sk_stream_wait_memory`)

When `send()` can't allocate because the write buffer is full:

```c
int sk_stream_wait_memory(struct sock *sk, long *timeo_p)
{
    DEFINE_WAIT_FUNC(wait, woken_wake_function);

    add_wait_queue(sk_sleep(sk), &wait);

    for (;;) {
        /* Check if space freed up */
        if (sk_stream_memory_free(sk))
            break;

        /* Check for errors / socket closed */
        if (sk->sk_err || (sk->sk_shutdown & SEND_SHUTDOWN))
            break;

        /* Block until woken */
        *timeo_p = wait_woken(&wait, TASK_INTERRUPTIBLE, *timeo_p);
        if (!*timeo_p)
            break;  // timeout
    }

    remove_wait_queue(sk_sleep(sk), &wait);
    return sk->sk_err ? -sk->sk_err : 0;
}
```

Wake-up when space frees:
```c
/* In tcp_recvmsg, after copying data to userspace and freeing skbs: */
sk_mem_reclaim(sk);
if (sk_stream_is_writeable(sk))
    sk->sk_write_space(sk);   // → sock_def_write_space()
                               // → wake_up_interruptible(sk->sk_wq)
```

---

## 6. Receive Buffer and TCP Window

The receive buffer directly controls the **TCP receive window** advertised to the peer:

```
Advertised window = sk_rcvbuf - sk_rmem_alloc
                  = "how many more bytes you can send me"
```

If the application doesn't call `recv()` fast enough:
```
sk_receive_queue fills up
→ sk_rmem_alloc approaches sk_rcvbuf
→ advertised window shrinks → zero window
→ peer stops sending (flow control)
→ see Day 09 for zero-window probes
```

---

## 7. Hands-On

### 7a. Inspect per-socket buffer usage
```bash
# ss -m shows memory info per socket
ss -tm state established

# Fields: skmem:(r=rcv_alloc,rb=rcvbuf,t=snd_alloc,tb=sndbuf,
#                f=fwd_alloc,w=wmem_queued,o=opt_mem,bl=backlog)
```

### 7b. Global memory counters
```bash
# TCP memory usage in pages
cat /proc/net/sockstat | grep TCP

# Socket memory stats
cat /proc/net/sockstat

# Per-protocol memory
cat /proc/net/protocols | column -t
```

### 7c. Observe memory pressure
```bash
# Check if TCP is in memory pressure
cat /proc/sys/net/ipv4/tcp_mem

# Real-time socket memory
watch -n1 'cat /proc/net/sockstat'
```

### 7d. Tune buffers for a single socket (via setsockopt)
```bash
# Using python to show the pattern
python3 -c "
import socket
s = socket.socket()
print('Default rcvbuf:', s.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF))
print('Default sndbuf:', s.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF))
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024*1024)
print('After set rcvbuf:', s.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF))
s.close()
"
```

### 7e. Kernel-side: where setsockopt lands
```bash
grep -n "SO_RCVBUF\|SO_SNDBUF" ~/linux/net/core/sock.c | head -20
```

---

## 8. Concept Check

1. What is `skb->truesize` and why is it larger than `skb->len`? Why does this matter for buffer accounting?
2. What happens when `sk_wmem_queued >= sk_sndbuf`? Trace the path from `send()` to the process blocking.
3. How does the receive buffer size affect the TCP window advertised to the remote peer?
4. What are the three zones in `tcp_mem` sysctl? What behavior changes at each threshold?

---

## 📚 References
- `net/core/skbuff.c` — `alloc_skb`, `kfree_skb`
- `net/core/sock.c` — `sk_stream_wait_memory`, `SO_RCVBUF` handling
- `net/ipv4/tcp.c` — `tcp_sendmsg`, `tcp_recvmsg`
- `net/ipv4/tcp_input.c` — `tcp_rcv_space_adjust`
- `include/net/sock.h` — `struct sock` memory fields
