# Day 09 — TCP Flow Control and Zero-Window Probes
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 2)

---

## 🎯 Goal
Understand TCP flow control: how the receiver's window controls the sender, what happens when the window reaches zero, and how the kernel handles window probes and updates.

---

## 1. Flow Control vs Congestion Control

| | Flow Control | Congestion Control |
|---|---|---|
| **Purpose** | Protect receiver buffer | Protect the network |
| **Signal** | Receiver's window (`rwnd`) | Packet loss / delay |
| **Controlled by** | Receiver | Sender |
| **Kernel variable** | `tp->snd_wnd` | `tp->snd_cwnd` |
| **Limits sending to** | `snd_wnd` bytes unacked | `snd_cwnd` × MSS bytes unacked |

**Effective send window:**
```c
// net/ipv4/tcp_output.c
u32 tcp_wnd_end(const struct tcp_sock *tp)
{
    return tp->snd_una + tp->snd_wnd;
    // can send bytes up to this sequence number
}

// Actual limit is the minimum:
u32 allowed = min(tp->snd_wnd, tp->snd_cwnd * tp->mss_cache)
              - (tp->snd_nxt - tp->snd_una);
```

---

## 2. How the Receiver Advertises Its Window

Every TCP segment carries a **window** field (16-bit, scaled by `tcp_wmscale`):

```c
/* In tcp_transmit_skb() / tcp_select_window(): */
u16 tcp_select_window(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    u32 old_win = tp->rcv_wnd;

    /* Available space in receive buffer */
    u32 cur_win = tcp_receive_window(tp);

    /* Never shrink the window (RFC 793 requirement) */
    if (cur_win < old_win)
        cur_win = old_win;

    /* Apply window scaling */
    u32 new_win = cur_win >> tp->rx_opt.rcv_wscale;

    /* Cap at 16 bits (before scaling) */
    if (new_win > 65535U)
        new_win = 65535U;

    tp->rcv_wnd = new_win << tp->rx_opt.rcv_wscale;
    return new_win;
}
```

### Window scaling (RFC 1323)
```c
/* Negotiated during SYN / SYN-ACK via TCP options */
/* Allows windows up to 2^30 bytes (1 GB) */
actual_window = wire_window << rcv_wscale;
```

---

## 3. Zero Window: When the Receiver Is Full

When `sk_receive_queue` is full:
```
sk_rmem_alloc ≈ sk_rcvbuf
→ tcp_receive_window(tp) returns 0
→ next ACK advertises window = 0
→ peer's snd_wnd becomes 0
→ peer cannot send any data
```

**Sender reaction:**
```c
/* In tcp_write_xmit(): */
if (tcp_snd_wnd_test(tp, skb, mss_now) == false) {
    /* Window is zero or too small for this segment */
    /* Start persist timer to probe */
    if (!tp->snd_wnd) {
        tcp_check_probe_timer(sk);
    }
    break;
}
```

---

## 4. Zero-Window Probes

**Source:** `net/ipv4/tcp_timer.c`

When the sender receives a zero window, it starts the **persist timer**. When it fires, a **window probe** is sent.

```c
/* Persist timer handler */
static void tcp_probe_timer(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    int max_probes;

    /* Have probes been answered? (window opened) */
    if (tp->packets_out || !tcp_send_head(sk)) {
        tp->probes_out = 0;
        return;
    }

    max_probes = sock_net(sk)->ipv4.sysctl_tcp_retries2;

    if (tp->probes_out > max_probes) {
        /* Give up — close the connection */
        tcp_write_err(sk);
        return;
    }

    /* Send a probe: 1-byte segment at snd_una */
    tcp_send_probe0(sk);
    tp->probes_out++;

    /* Exponential backoff on probe interval */
    inet_csk_reset_xmit_timer(sk, ICSK_TIME_PROBE0,
        min(tp->rto << tp->probes_out, TCP_RTO_MAX),
        TCP_RTO_MAX);
}
```

### Window probe packet
```c
void tcp_send_probe0(struct sock *sk)
{
    /* Send a 1-byte segment at the edge of the window
       This forces the receiver to send an ACK with current window */
    tcp_write_wakeup(sk, LINUX_MIB_TCPWINPROBE);
}
```

The receiver responds with an ACK containing the current window size. If window > 0, sending resumes.

---

## 5. Window Update ACKs

When the receiver reads data (freeing buffer space), it should send a **window update**:

```c
/* In tcp_recvmsg(), after copying data to userspace: */
static void tcp_cleanup_rbuf(struct sock *sk, int copied)
{
    struct tcp_sock *tp = tcp_sk(sk);
    bool send_win_update;

    /* Should we send a window update? */
    /* Heuristic: send if window grew by >= 1/2 MSS or 1/2 rcvbuf */
    send_win_update = tcp_win_from_space(sk, tp->rcvq_space.space) >
                      tcp_receive_window(tp);

    if (send_win_update) {
        /* Send a pure ACK to announce the new window */
        tcp_send_ack(sk);
    }
}
```

### Silly window syndrome (SWS) avoidance
**Problem:** Receiver advertises tiny window updates (e.g., 1 byte), causing sender to transmit tiny segments.

**Clark's algorithm (receiver side):**
```c
/* Don't advertise new window until we have significant space */
/* Threshold: max(1/2 MSS, 1/2 rcvbuf) */
if (new_window < min(tp->advmss / 2, sk->sk_rcvbuf / 2))
    new_window = 0;  // advertise zero rather than tiny
```

**Nagle algorithm (sender side, see Day 06):**
```c
/* Don't send tiny segments unless forced */
/* Only send if: full MSS, or FIN/PSH set, or idle connection */
```

---

## 6. Delayed ACKs

**Source:** `net/ipv4/tcp_input.c`

Linux does not ACK every segment immediately — it uses **delayed ACKs**:

```c
/* After receiving data, set the delayed ACK timer: */
inet_csk_schedule_ack(sk);

/* Timer fires after tcp_delack_min (default 40ms) */
/* or immediately if: */
//  - 2nd consecutive segment received
//  - full-sized segment (MSS)
//  - out-of-order segment
//  - window update needed
```

```bash
# Delayed ACK timeout (in ms, stored as HZ ticks internally)
sysctl net.ipv4.tcp_delack_min   # usually 40ms

# Disable delayed ACKs for a socket (setsockopt):
# TCP_QUICKACK option
```

### Delayed ACK implementation
```c
/* net/ipv4/tcp_input.c */
static void __tcp_ack_snd_check(struct sock *sk, int ofo_possible)
{
    struct tcp_sock *tp = tcp_sk(sk);

    /* Send immediately? */
    if (/* 2 unacked full-sized segments */ ||
        /* out-of-order */ ||
        /* window update needed */ ) {
        tcp_send_ack(sk);
        return;
    }

    /* Otherwise: schedule delayed ACK */
    tcp_send_delayed_ack(sk);
}
```

---

## 7. Hands-On

### 7a. Watch window sizes live
```bash
# snd_wnd and rcv_wnd per connection
ss -tin state established | grep -A1 "wscale\|rcv_wnd\|snd_wnd"

# Shorthand: look for 'rcv_space' and window info
ss -tin | grep -E "cwnd|wnd|rtt"
```

### 7b. Observe zero-window events
```bash
# TCPZeroWindowAdv: times we sent window=0
# TCPWantZeroWindowAdv: times we wanted to but didn't
# TCPToZeroWindowAdv: transitions to zero window
cat /proc/net/netstat | tr '\t' '\n' | grep -i "zero\|window" | head -20
```

### 7c. Window probe counters
```bash
# TCPWinProbe: zero window probes sent
cat /proc/net/snmp | grep "^Tcp" | tr '\t' '\n'
nstat | grep -i "probe\|window"   # if nstat is installed
```

### 7d. Delayed ACK counters
```bash
# DelayedACKs, DelayedACKLocked, DelayedACKLost
cat /proc/net/netstat | tr '\t' '\n' | grep -i "delayed"
```

### 7e. Read tcp_probe_timer
```bash
grep -n "tcp_probe_timer\|tcp_send_probe0\|ICSK_TIME_PROBE0" \
    ~/linux/net/ipv4/tcp_timer.c | head -20
```

---

## 8. Concept Check

1. What is the difference between `snd_wnd` (flow control window) and `snd_cwnd` (congestion window)? How do they interact?
2. Why does the TCP spec say a receiver must never shrink the advertised window? What bug would this cause?
3. Describe the zero-window probe mechanism: who sends it, what does it contain, and what triggers the sender to resume normal operation?
4. Why might delayed ACKs cause poor performance for certain workloads (e.g., request-response protocols)? How do you disable them?

---

## 📚 References
- `net/ipv4/tcp_output.c` — `tcp_select_window`, `tcp_send_probe0`
- `net/ipv4/tcp_timer.c` — `tcp_probe_timer`, `tcp_write_timer`
- `net/ipv4/tcp_input.c` — `tcp_cleanup_rbuf`, delayed ACK logic
- `include/net/tcp.h` — `tcp_receive_window`, `tcp_wnd_end`
- RFC 793 (TCP), RFC 1122 (SWS avoidance), RFC 1323 (window scaling)
