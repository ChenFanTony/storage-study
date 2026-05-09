# Day 06 — TCP: Transmit Path and Congestion Control
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 1)

---

## 🎯 Goal
Understand how TCP sends data: `send()` → segmentation → congestion window → `ip_queue_xmit()`. Learn how TCP decides *when* and *how much* to send.

---

## 1. TCP Transmit Overview

```
send(fd, buf, len, 0)
  └── tcp_sendmsg()                      net/ipv4/tcp.c
        ├── lock_sock(sk)
        ├── copy data into sk_write_queue (sk_buff chain)
        └── tcp_push()
              └── tcp_write_xmit()       net/ipv4/tcp_output.c
                    ├── while (cwnd allows && skb available):
                    │     tcp_transmit_skb()
                    │       └── ip_queue_xmit()
                    └── (arms retransmit timer if needed)
```

---

## 2. `tcp_sendmsg()` — Copying Userspace Data

**Source:** `net/ipv4/tcp.c`

```c
int tcp_sendmsg(struct sock *sk, struct msghdr *msg, size_t size)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct sk_buff *skb;
    int err, copied = 0;

    lock_sock(sk);

    while (msg_data_left(msg)) {
        /* Reuse last skb if it has room (avoid small packet fragmentation) */
        skb = tcp_write_queue_tail(sk);
        if (!skb || !tcp_skb_can_collapse_to(skb)) {
            skb = sk_stream_alloc_skb(sk, 0, sk->sk_allocation, false);
            __skb_entail(sk, skb);  // add to write queue
        }

        /* Copy from userspace into skb */
        copy = min_t(int, skb_availroom(skb), msg_data_left(msg));
        err = skb_add_data_nocache(sk, skb, &msg->msg_iter, copy);

        copied += copy;

        /* Update sequence numbers */
        TCP_SKB_CB(skb)->end_seq += copy;
        tp->write_seq += copy;
    }

    /* Block if send buffer is full */
    if (sk->sk_wmem_queued >= sk->sk_sndbuf) {
        set_bit(SOCK_NOSPACE, &sk->sk_socket->flags);
        sk_stream_wait_memory(sk, &timeo);
    }

    tcp_push(sk, flags, mss_now, tp->nonagle, size_goal);
    release_sock(sk);
    return copied;
}
```

### Write queue structure
```
sk->sk_write_queue:
  [ skb1: seq 1000-2459 ]→[ skb2: seq 2460-3919 ]→[ skb3: seq 3920-... ]
         ↑
    already ACKed data stays here until ACK received (for retransmit)
```

---

## 3. `tcp_write_xmit()` — The Sending Engine

**Source:** `net/ipv4/tcp_output.c`

This function decides **what** to send based on:
- **Congestion window (`cwnd`)**: limits unacked bytes in flight
- **Receiver window (`rwnd`)**: receiver's advertised buffer space
- **Nagle algorithm**: avoid tiny packets

```c
static bool tcp_write_xmit(struct sock *sk, unsigned int mss_now,
                             int nonagle, int push_one, gfp_t gfp)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct sk_buff *skb;
    unsigned int sent_pkts = 0;

    while ((skb = tcp_send_head(sk))) {
        /* How much can we send? */
        unsigned int limit = tcp_cwnd_test(tp, skb);  // cwnd check
        if (!limit)
            break;  // congestion window full

        /* Receiver window check */
        if (tcp_snd_wnd_test(tp, skb, mss_now))
            break;

        /* Nagle: don't send tiny segments unless forced */
        if (tcp_nagle_test(tp, skb, mss_now, ...))
            break;

        /* Fragment if larger than MSS */
        if (skb->len > limit) {
            if (tcp_fragment(sk, TCP_FRAG_IN_WRITE_QUEUE, skb, limit, ...))
                break;
        }

        if (tcp_transmit_skb(sk, skb, 1, gfp))
            break;

        tcp_event_new_data_sent(sk, skb);
        sent_pkts++;
    }

    return (sent_pkts > 0);
}
```

---

## 4. Congestion Control

**Source:** `net/ipv4/tcp_cong.c`, `net/ipv4/tcp_cubic.c`

TCP uses a **pluggable congestion control** framework.

### Key variables in `tcp_sock`
```c
struct tcp_sock {
    /* Congestion window */
    u32  snd_cwnd;          // current congestion window (in MSS units)
    u32  snd_cwnd_clamp;    // max allowed cwnd
    u32  snd_ssthresh;      // slow start threshold

    /* Sequence numbers */
    u32  snd_una;           // oldest unacknowledged byte
    u32  snd_nxt;           // next byte to send
    u32  snd_wnd;           // receiver's window (from ACK)

    /* RTT measurement */
    u32  srtt_us;           // smoothed RTT (microseconds << 3)
    u32  mdev_us;           // mean deviation (for RTO calculation)
    u32  rto;               // retransmit timeout
};
```

### Congestion control phases

```
bytes in flight = snd_nxt - snd_una
allowed to send = min(snd_cwnd, snd_wnd) * MSS - bytes_in_flight
```

**Slow start** (`cwnd < ssthresh`):
```
per ACK: cwnd += 1 MSS
→ cwnd doubles each RTT (exponential growth)
```

**Congestion avoidance** (`cwnd >= ssthresh`):
```
per ACK: cwnd += MSS * MSS / cwnd
→ cwnd grows by ~1 MSS per RTT (linear growth)
```

**On packet loss** (timeout):
```
ssthresh = max(cwnd/2, 2)
cwnd = 1 MSS
→ restart slow start
```

**On triple duplicate ACK** (fast retransmit):
```
ssthresh = cwnd / 2
cwnd = ssthresh + 3   (CUBIC/Reno differs here)
→ fast recovery, don't go back to slow start
```

### Pluggable algorithm interface
```c
struct tcp_congestion_ops {
    void (*init)(struct sock *sk);
    void (*cong_avoid)(struct sock *sk, u32 ack, u32 acked);
    void (*set_state)(struct sock *sk, u8 new_state);
    void (*cwnd_event)(struct sock *sk, enum tcp_ca_event ev);
    u32  (*undo_cwnd)(struct sock *sk);
    u32  (*ssthresh)(struct sock *sk);
    /* ... */
    char name[TCP_CA_NAME_MAX];   // "cubic", "bbr", "reno"
};
```

```bash
# See available and active algorithms
cat /proc/sys/net/ipv4/tcp_congestion_control
ls /lib/modules/$(uname -r)/kernel/net/ipv4/ | grep tcp_
```

---

## 5. Retransmit Timer

```c
// Armed in tcp_transmit_skb() for every segment sent
inet_csk_reset_xmit_timer(sk, ICSK_TIME_RETRANS, rto, TCP_RTO_MAX);

// If timer fires before ACK:
tcp_retransmit_timer()
  └── if RTO expired:
        ssthresh = cwnd/2, cwnd = 1
        tcp_retransmit_skb(sk, tcp_write_queue_head(sk), 1)
        double RTO (exponential backoff)
```

---

## 6. `tcp_transmit_skb()` — Build TCP Header and Send

```c
static int tcp_transmit_skb(struct sock *sk, struct sk_buff *skb,
                             int clone_it, gfp_t gfp_mask)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct tcphdr *th;

    /* Clone skb (keep original for retransmit) */
    if (clone_it)
        skb = skb_clone(skb, gfp_mask);

    /* Build TCP header (pushed into headroom) */
    skb_push(skb, tcp_header_size);
    th = tcp_hdr(skb);
    th->source  = inet->inet_sport;
    th->dest    = inet->inet_dport;
    th->seq     = htonl(TCP_SKB_CB(skb)->seq);
    th->ack_seq = htonl(tp->rcv_nxt);
    th->window  = htons(tcp_select_window(sk));
    tcp_options_write((__be32 *)(th + 1), tp, &opts);

    /* Checksum (hardware or software) */
    th->check = ~csum_fold(csum_partial(th, tcp_header_size, skb->csum));

    /* Hand off to IP */
    return ip_queue_xmit(sk, skb, &inet->cork.fl);
}
```

---

## 7. Hands-On

### 7a. Read the congestion control ops
```bash
grep -n "struct tcp_congestion_ops" ~/linux/include/net/tcp.h
grep -n "cong_avoid\|ssthresh\|cwnd_event" ~/linux/net/ipv4/tcp_cubic.c | head -20
```

### 7b. Watch cwnd and RTT
```bash
# Per-connection TCP internals (Linux 4.1+)
ss -tin state established
# Look for: cwnd, rtt, retrans, rcv_space

# Or use ss with filter
ss -tin '( dport = :443 )'
```

### 7c. Observe retransmissions
```bash
# Global retransmit counter
cat /proc/net/snmp | grep "^Tcp" | tr '\t' '\n' | grep -A1 Retrans

# Per-socket retransmit count
ss -tn -e | grep retrans
```

### 7d. Change congestion algorithm (test environment)
```bash
sysctl net.ipv4.tcp_congestion_control
# Try: sysctl -w net.ipv4.tcp_congestion_control=reno
# (restore: sysctl -w net.ipv4.tcp_congestion_control=cubic)
```

---

## 8. Concept Check

1. What prevents TCP from sending all queued data at once? Name the two windows involved.
2. How does Nagle's algorithm decide whether to send a small segment? When is it disabled?
3. Why does `tcp_transmit_skb()` clone the `sk_buff` instead of sending the original?
4. Explain the difference between a retransmit timeout (RTO) and fast retransmit. Which is faster to recover?

---

## 📚 References
- `net/ipv4/tcp.c` — `tcp_sendmsg`
- `net/ipv4/tcp_output.c` — `tcp_write_xmit`, `tcp_transmit_skb`
- `net/ipv4/tcp_input.c` — ACK processing, cwnd updates
- `net/ipv4/tcp_cubic.c` — CUBIC implementation
- `net/ipv4/tcp_cong.c` — pluggable framework
- `include/net/tcp.h` — `tcp_sock`, constants
