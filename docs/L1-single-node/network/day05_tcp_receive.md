# Day 05 — TCP: Receive Path and State Machine
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 1)

---

## 🎯 Goal
Follow a TCP segment from `tcp_v4_rcv()` through the state machine to `sk_receive_queue`, and understand how `recv()` wakes up userspace.

---

## 1. TCP Receive Entry Point

**Source:** `net/ipv4/tcp_ipv4.c`

```
ip_local_deliver_finish()
  └── tcp_v4_rcv(skb)
        ├── validate TCP header
        ├── lookup socket: __inet_lookup_skb()
        ├── if ESTABLISHED → tcp_rcv_established()   [fast path]
        └── else           → tcp_rcv_state_process()  [slow path]
```

### Socket lookup
```c
int tcp_v4_rcv(struct sk_buff *skb)
{
    const struct iphdr *iph = ip_hdr(skb);
    const struct tcphdr *th;
    struct sock *sk;

    th = tcp_hdr(skb);

    /* Sanity checks: data offset, checksum */
    if (th->doff < sizeof(struct tcphdr) / 4)
        goto bad_packet;

    /* 4-tuple lookup: (src_ip, src_port, dst_ip, dst_port) */
    sk = __inet_lookup_skb(&tcp_hashinfo, skb,
                           __tcp_hdrlen(th),
                           th->source, th->dest,
                           sdif, &refcounted);
    if (!sk)
        goto no_tcp_socket;  // send RST

    if (sk->sk_state == TCP_LISTEN)
        return tcp_v4_do_rcv(sk, skb);  // connection establishment

    /* Fast path for established connections */
    if (sk->sk_state == TCP_ESTABLISHED) {
        tcp_rcv_established(sk, skb);
        return 0;
    }

    return tcp_v4_do_rcv(sk, skb);
}
```

---

## 2. TCP State Machine

**Source:** `net/ipv4/tcp_input.c` (`tcp_rcv_state_process`)

```
                    ┌─────────────────────────────────┐
                    │           CLOSED                 │
                    └──────────────┬──────────────────┘
                    passive open   │    active open
                    (listen)       │    (connect → SYN sent)
                    ▼              ▼
               LISTEN          SYN_SENT
                    │              │
              rcv SYN        rcv SYN+ACK
              snd SYN+ACK    snd ACK
                    │              │
                    ▼              ▼
               SYN_RECEIVED   ESTABLISHED ◄──────────────┐
                    │                                      │
              rcv ACK                              data transfer
                    │
                    ▼
               ESTABLISHED
```

### TCP state values (from `include/net/tcp_states.h`)
```c
enum {
    TCP_ESTABLISHED = 1,
    TCP_SYN_SENT,
    TCP_SYN_RECV,
    TCP_FIN_WAIT1,
    TCP_FIN_WAIT2,
    TCP_TIME_WAIT,
    TCP_CLOSE,
    TCP_CLOSE_WAIT,
    TCP_LAST_ACK,
    TCP_LISTEN,
    TCP_CLOSING,
    TCP_NEW_SYN_RECV,
};
```

### Transition example: 3-way handshake (server side)
```
State: LISTEN

1. rcv SYN  → tcp_conn_request()
              → allocate request_sock, send SYN+ACK
              → state: SYN_RECV (on the request_sock, not full sock)

2. rcv ACK  → tcp_check_req()
              → allocate full struct sock via tcp_v4_syn_recv_sock()
              → add to accept queue
              → state: ESTABLISHED

3. accept() → inet_csk_accept()
              → dequeue from accept queue, return fd
```

---

## 3. Fast Path: `tcp_rcv_established()`

**Source:** `net/ipv4/tcp_input.c`

This is the hot path — most packets take it. Optimized heavily.

```c
void tcp_rcv_established(struct sock *sk, struct sk_buff *skb)
{
    struct tcp_sock *tp = tcp_sk(sk);
    const struct tcphdr *th = tcp_hdr(skb);
    unsigned int len = skb->len;

    /* Header prediction (fast path):
       Pure ACK with no data, or pure data with expected seq? */
    if ((th->ack && !th->fin && !th->syn && !th->rst) &&
        TCP_SKB_CB(skb)->seq == tp->rcv_nxt &&  // expected sequence
        !sk->sk_shutdown) {
        
        if (len == tcp_hdrlen(skb)) {
            /* Pure ACK — update snd_una, wake writers */
            tcp_ack(sk, skb, 0);
            goto no_ack;
        }
        
        /* In-order data — queue directly */
        __skb_queue_tail(&sk->sk_receive_queue, skb);
        tp->rcv_nxt += (len - tcp_hdrlen(skb));   // advance expected seq
        
        /* Wake up blocked recv() calls */
        sk->sk_data_ready(sk);   // → sock_def_readable()
        
        /* Send ACK */
        tcp_event_data_recv(sk, skb);
        __tcp_ack_snd_check(sk, 0);
        return;
    }

    /* Slow path: out-of-order, flags set, etc. */
    tcp_data_queue(sk, skb);   // may go to out-of-order queue
}
```

### Out-of-order queue
```c
// In struct tcp_sock:
struct rb_root  out_of_order_queue;  // red-black tree keyed on seq

// When a gap is filled, segments move to sk_receive_queue
```

---

## 4. `recv()` Syscall Path

**Source:** `net/ipv4/tcp.c`

```
recv(fd, buf, len, flags)
  └── tcp_recvmsg(sk, msg, len, flags, &addr_len)
        ├── lock_sock(sk)
        └── loop:
              ├── skb = skb_peek(&sk->sk_receive_queue)
              ├── if no data:
              │     sk_wait_data(sk, &timeo, last)  ← blocks here
              │     └── wait_woken() on sk->sk_wq
              ├── copy skb data to userspace: skb_copy_datagram_msg()
              ├── if fully consumed: __skb_unlink + kfree_skb
              └── update tp->copied_seq
```

### Wake-up chain
```c
// Called from tcp_rcv_established() when data arrives:
sk->sk_data_ready(sk)
  └── sock_def_readable()      // net/core/sock.c
        └── wake_up_interruptible_all(&sk->sk_wq->wait)
              └── wakes the task blocked in sk_wait_data()
                    └── recv() returns to userspace
```

---

## 5. TCP Control Block: `TCP_SKB_CB`

Each `sk_buff` carries TCP metadata via a control block:

```c
/* Stored in skb->cb[] — 48 bytes of private data per skb */
struct tcp_skb_cb {
    __u32   seq;        // starting sequence number
    __u32   end_seq;    // ending sequence number
    __u32   tcp_tw_isn; // for TIME_WAIT
    __u8    tcp_flags;  // SYN, FIN, RST, ACK, PSH, URG
    __u8    ip_dsfield;
    __u32   ack_seq;    // ACK number in this segment
    /* ... */
};
#define TCP_SKB_CB(skb) ((struct tcp_skb_cb *)(skb)->cb)
```

Usage:
```c
if (TCP_SKB_CB(skb)->tcp_flags & TCPHDR_SYN) { ... }
u32 seq = TCP_SKB_CB(skb)->seq;
```

---

## 6. Hands-On

### 6a. Read the fast path
```bash
grep -n "tcp_rcv_established\|header_prediction" \
    ~/linux/net/ipv4/tcp_input.c | head -20

# Read ~60 lines of tcp_rcv_established
```

### 6b. Trace state transitions
```bash
grep -n "TCP_ESTABLISHED\|TCP_SYN_SENT\|TCP_LISTEN\|sk->sk_state" \
    ~/linux/net/ipv4/tcp_ipv4.c | head -30
```

### 6c. Watch TCP state machine live
```bash
# All TCP sockets with states
ss -tan

# Watch connection counts per state
watch -n1 "ss -tan | awk '{print \$1}' | sort | uniq -c | sort -rn"

# TCP stats
cat /proc/net/snmp | grep "^Tcp"

# Retransmit and error counters
ss -tan -e | grep retrans
```

### 6d. Observe recv queue depths
```bash
# Recv-Q = bytes waiting in sk_receive_queue
# Send-Q = bytes not yet acked
ss -tnp
```

---

## 7. Concept Check

1. What is "header prediction" and why does TCP have a "fast path" vs "slow path"?
2. Where do out-of-order segments go, and when do they get delivered to userspace?
3. What wakes up a process blocked in `recv()`? Trace the exact function call chain.
4. Why does the kernel use `request_sock` during the 3-way handshake instead of a full `struct sock`?

---

## 📚 References
- `net/ipv4/tcp_ipv4.c` — `tcp_v4_rcv`, socket lookup
- `net/ipv4/tcp_input.c` — `tcp_rcv_established`, state processing
- `net/ipv4/tcp.c` — `tcp_recvmsg`
- `include/net/tcp.h` — `tcp_sock`, `TCP_SKB_CB`
- `include/net/tcp_states.h` — state enum
