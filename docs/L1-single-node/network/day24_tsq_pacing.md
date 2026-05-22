# Day 24 — TCP Small Queues (TSQ) and Pacing
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 4)

---

## 🎯 Goal
Understand why bufferbloat is a real problem, how TCP Small Queues limit bytes in the driver/NIC, and how pacing spreads packets evenly over time instead of bursting.

---

## 1. The Bufferbloat Problem

Without TSQ, TCP pushes as much data as the congestion window allows into the qdisc/NIC ring buffer at once:

```
TCP cwnd = 1000 packets
→ tcp_write_xmit() loops 1000 times
→ 1000 skbs pile up in qdisc + NIC ring buffer
→ new traffic (ACKs, other flows) must wait behind 1000 packets
→ RTT inflates from 1ms → 100ms+
→ congestion signals are delayed → cwnd grows too large → more bufferbloat
```

This is **bufferbloat**: excessive queuing in the network stack hides from the transport layer.

---

## 2. TCP Small Queues (TSQ)

**Source:** `net/ipv4/tcp_output.c`, `include/net/tcp.h`

TSQ limits the number of bytes a single TCP socket can have "in flight" in the lower layers (qdisc + NIC ring) at any time.

### Key limit
```bash
sysctl net.ipv4.tcp_limit_output_bytes   # default: 1048576 (1MB) in recent kernels
# Older kernels: 131072 (128KB)
# This is the max bytes one flow can have queued below TCP
```

### Implementation in `tcp_write_xmit()`
```c
/* net/ipv4/tcp_output.c */
static bool tcp_small_queue_check(struct sock *sk, const struct sk_buff *skb,
                                   unsigned int factor)
{
    unsigned long limit;

    /* Limit = tcp_limit_output_bytes, but at least 2 * skb->truesize */
    limit = max_t(unsigned long,
                  sock_net(sk)->ipv4.sysctl_tcp_limit_output_bytes,
                  sk->sk_pacing_rate >> sk->sk_pacing_shift);
    limit = min_t(unsigned long, limit,
                  sock_net(sk)->ipv4.sysctl_tcp_limit_output_bytes << factor);

    /* How many bytes are already in the qdisc/NIC for this socket? */
    if (refcount_read(&sk->sk_wmem_alloc) > limit) {
        /* Too much queued below TCP — stop sending */
        set_bit(TSQ_THROTTLED, &sk->sk_tsq_flags);
        return true;   /* caller breaks out of send loop */
    }
    return false;
}
```

### What counts as "in the lower layers"?
```
sk_wmem_alloc tracks ALL sk_buff memory owned by this socket,
including skbs that have left tcp_write_queue and entered qdisc/NIC:

sk_wmem_alloc increases: when skb is allocated and linked to socket
sk_wmem_alloc decreases: when skb->destructor (sock_wfree) is called
                          = after NIC DMA completes and skb is freed
```

### TSQ wake-up: `tcp_tsq_handler()`
```c
/* Called from NET_TX_SOFTIRQ after skbs are freed: */
void tcp_tsq_handler(struct sock *sk)
{
    /* TSQ_THROTTLED was set — check if we can send more now */
    if (!sk_wmem_alloc_get(sk) ||
        sk_wmem_alloc_get(sk) <= sk->sk_pacing_rate >> sk->sk_pacing_shift) {
        /* Space available: retrigger TCP send */
        tcp_write_xmit(sk, tcp_sk(sk)->mss_cache, tcp_sk(sk)->nonagle,
                        0, GFP_ATOMIC);
    }
}

/* Scheduled from sock_wfree() → tcp_wfree() */
void tcp_wfree(struct sk_buff *skb)
{
    struct sock *sk = skb->sk;
    /* Decrement wmem_alloc */
    atomic_sub(skb->truesize, &sk->sk_wmem_alloc);

    if (test_bit(TSQ_THROTTLED, &sk->sk_tsq_flags) &&
        !test_and_set_bit(TSQ_QUEUED, &sk->sk_tsq_flags)) {
        /* Schedule tcp_tsq_handler via tasklet */
        list_add(&tp->tsq_node, &sd->tsq_sender_list);
        raise_softirq_irqoff(NET_TX_SOFTIRQ);
    }
}
```

---

## 3. Pacing

**Source:** `net/core/sock.c`, `net/ipv4/tcp_output.c`

Pacing spreads packet transmission evenly over time instead of bursting.

```
Without pacing (burst):
  t=0:    ████████████████ (cwnd × MSS bytes all at once)
  t=RTT:  ████████████████

With pacing (spread):
  t=0:    █ █ █ █ █ █ █ █ (one packet every pacing_interval)
  t=RTT:  █ █ █ █ █ █ █ █
```

**Benefits:**
- Reduces burst-induced queuing
- ACKs arrive steadily → smoother cwnd feedback loop
- Better coexistence with latency-sensitive flows

### Pacing rate calculation
```c
/* Set by congestion control (e.g., BBR) or by default: */
sk->sk_pacing_rate = 2 * bandwidth;   /* 2× bandwidth for slow start */

/* Default pacing (when CC doesn't set it): */
/* net/ipv4/tcp_output.c - tcp_update_skb_after_send() */
void tcp_update_pacing_rate(struct sock *sk)
{
    const struct tcp_sock *tp = tcp_sk(sk);
    u64 rate;

    /* rate = cwnd * mss / srtt */
    rate = (u64)tp->mss_cache * ((USEC_PER_SEC / 100) << 3);
    rate *= max(tp->snd_cwnd, tp->packets_out);
    /* Divide by srtt (smoothed RTT in usec) */
    if (tp->srtt_us)
        do_div(rate, tp->srtt_us);

    /* Apply pacing headroom factor */
    WRITE_ONCE(sk->sk_pacing_rate,
               min_t(u64, rate, sk->sk_max_pacing_rate));
}
```

### Pacing mechanism: `sk_pacing_shift` and `fq` qdisc
```c
/* In tcp_write_xmit(), after TSQ check: */
/* The pacing is enforced in two ways: */

/* 1. Hrtimer-based pacing in TCP itself (software pacing) */
if (sk->sk_pacing_status == SK_PACING_NEEDED) {
    delay = tcp_pacing_delay(sk);
    if (delay > 0) {
        /* Arm high-res timer, stop sending */
        hrtimer_start(&tcp_sk(sk)->pacing_timer,
                      ktime_add_ns(ktime_get(), delay),
                      HRTIMER_MODE_ABS_PINNED_SOFT);
        return false;
    }
}

/* 2. Hardware pacing via fq (Fair Queue) qdisc — preferred */
/* fq reads sk->sk_pacing_rate and enforces timing in qdisc layer */
```

### Enabling fq pacing (recommended)
```bash
# Replace default qdisc with fq (Fair Queue with pacing support)
tc qdisc replace dev eth0 root fq

# fq enforces sk->sk_pacing_rate automatically
# No software pacing timer needed in TCP

# Or: fq_codel (FQ + CoDel AQM for latency control)
tc qdisc replace dev eth0 root fq_codel
```

---

## 4. BBR — Pacing-Based Congestion Control

**Source:** `net/ipv4/tcp_bbr.c`

BBR (Bottleneck Bandwidth and RTT) is a pacing-first congestion control that estimates bandwidth and RTT independently, rather than reacting to loss:

```c
struct bbr {
    u32  min_rtt_us;         // minimum observed RTT
    u32  min_rtt_stamp;      // when min RTT was measured
    u32  probe_rtt_done_stamp; // when ProbeRTT ends

    u32  rtt_cnt;            // round trip count
    u32  next_rtt_delivered; // cwnd inflection point

    struct minmax bw;        // windowed max filter on bandwidth

    u32  lt_bw;              // long-term bandwidth (if loss-limited)
    u32  lt_last_lost;
    u32  lt_last_delivered;
    u32  lt_last_stamp;

    u32  gain;               // pacing gain (1.25 in BBR_STARTUP)
    u32  cwnd_gain;          // cwnd gain
    enum bbr_mode mode;      // STARTUP, DRAIN, PROBE_BW, PROBE_RTT
};

/* BBR sets pacing rate, not cwnd primarily */
static void bbr_set_pacing_rate(struct sock *sk, u32 bw, int gain)
{
    struct tcp_sock *tp = tcp_sk(sk);
    u64 rate = bw;
    rate = bbr_rate_bytes_per_sec(sk, rate, gain);
    rate = min_t(u64, rate, sk->sk_max_pacing_rate);
    WRITE_ONCE(sk->sk_pacing_rate, rate);
}
```

```bash
# Enable BBR
sysctl -w net.ipv4.tcp_congestion_control=bbr
sysctl -w net.core.default_qdisc=fq   # BBR needs fq for pacing

# Check if loaded
lsmod | grep tcp_bbr
```

---

## 5. CoDel — Active Queue Management

**Source:** `net/sched/sch_codel.c`

CoDel (Controlled Delay) drops packets based on **sojourn time** (time spent in queue) rather than queue length:

```c
/* Drop if packet has been queued > 5ms for at least 100ms */
#define CODEL_TARGET  5 * NSEC_PER_MSEC    /* 5ms target latency */
#define CODEL_INTERVAL 100 * NSEC_PER_MSEC  /* 100ms interval */

static struct sk_buff *codel_dequeue(...)
{
    skb = __dequeue(sch);
    now = ktime_get_ns();
    sojourn_time = now - codel_get_enqueue_time(skb);

    if (sojourn_time < state->target || sch->qstats.backlog <= MTU) {
        /* Queue is fine: reset */
        state->first_above_time = 0;
    } else {
        if (state->first_above_time == 0)
            state->first_above_time = now + state->interval;
        else if (after64(now, state->first_above_time)) {
            /* Been above target for interval → drop! */
            skb = codel_drop(sch, skb);
        }
    }
    return skb;
}
```

---

## 6. Hands-On

### 6a. Check TSQ limit
```bash
sysctl net.ipv4.tcp_limit_output_bytes

# Check wmem_alloc per socket (bytes in lower layers)
ss -tin state established | grep wmem | head -5
# Look for: wmem_alloc value
```

### 6b. Enable BBR + fq
```bash
# Check available CC algorithms
cat /proc/sys/net/ipv4/tcp_available_congestion_control

# Set BBR (if available)
sudo sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || \
    echo "BBR not available (needs kernel 4.9+)"
sudo sysctl -w net.core.default_qdisc=fq

# Verify
sysctl net.ipv4.tcp_congestion_control
tc qdisc show dev eth0 2>/dev/null
```

### 6c. Measure bufferbloat
```bash
# Add artificial delay to see bufferbloat effect
sudo tc qdisc add dev lo root netem delay 10ms 2>/dev/null

# Without pacing: burst + queuing
ping -c20 -i0.01 127.0.0.1 | tail -3

# Clean up
sudo tc qdisc del dev lo root 2>/dev/null
```

### 6d. Read TSQ in source
```bash
grep -n "tcp_small_queue_check\|TSQ_THROTTLED\|tcp_tsq_handler\|tcp_limit_output_bytes" \
    ~/linux/net/ipv4/tcp_output.c | head -20

grep -n "sk_pacing_rate\|SK_PACING" \
    ~/linux/include/net/sock.h | head -10
```

---

## 7. Concept Check

1. What does `sk_wmem_alloc` track in the context of TSQ? At what point does it decrease for a transmitted packet?
2. Without TSQ, why would high cwnd cause RTT inflation even on a lightly loaded link?
3. What is the fundamental difference between BBR and CUBIC's approach to congestion? What signal does each react to?
4. Why does CoDel drop based on sojourn time rather than queue length? What failure mode does queue-length-based dropping have?

---

## 📚 References
- `net/ipv4/tcp_output.c` — `tcp_small_queue_check`, `tcp_wfree`, pacing
- `net/ipv4/tcp_bbr.c` — BBR implementation
- `net/sched/sch_fq.c` — Fair Queue with pacing
- `net/sched/sch_codel.c` — CoDel AQM
- `net/sched/sch_fq_codel.c` — FQ+CoDel combined
- Kernel docs: `Documentation/networking/tcp-thin.rst`
- BBR paper: "BBR: Congestion-Based Congestion Control" (ACM Queue 2016)
