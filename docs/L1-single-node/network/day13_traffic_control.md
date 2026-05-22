# Day 13 — Traffic Control and the `qdisc` Layer
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 2)

---

## 🎯 Goal
Understand how Linux shapes, schedules, and limits outgoing traffic via the `qdisc` (queuing discipline) layer, and how `tc` commands map to kernel structures.

---

## 1. Where qdisc Fits in the Stack

```
tcp_write_xmit()
  └── ip_queue_xmit()
        └── dev_queue_xmit()         ← net/core/dev.c
              └── __dev_queue_xmit()
                    └── txq = netdev_pick_tx(dev, skb)
                          └── q = rcu_dereference(txq->qdisc)
                                └── q->enqueue(skb, q, &to_free)
                                      ↑
                                   THIS IS THE QDISC
                    └── __qdisc_run(q)
                          └── dequeue loop → ndo_start_xmit()
```

Every outgoing packet passes through a qdisc. The default is `pfifo_fast` (three-band FIFO based on DSCP).

---

## 2. `struct Qdisc` — The Core Object

**Source:** `include/net/sch_generic.h`

```c
struct Qdisc {
    int             (*enqueue)(struct sk_buff *skb,
                               struct Qdisc *sch,
                               struct sk_buff **to_free);
    struct sk_buff* (*dequeue)(struct Qdisc *sch);

    const struct Qdisc_ops  *ops;    // pfifo_fast_ops, tbf_ops, htb_ops, ...

    struct netdev_queue     *dev_queue;  // which TX queue this serves
    struct net_device       *dev_root;   // the device

    spinlock_t      busylock;
    spinlock_t      seqlock;

    /* Statistics */
    struct gnet_stats_basic_packed bstats;  // bytes, packets
    struct gnet_stats_queue         qstats; // drops, requeues, overlimits

    u32             handle;          // qdisc handle (e.g., 1:0)
    u32             parent;          // parent handle (e.g., 1:1)
    u32             limit;           // queue depth limit

    long            [privdata];      // qdisc-private data
};
```

### Qdisc operations table
```c
struct Qdisc_ops {
    struct Qdisc_ops    *next;
    char                id[IFNAMSIZ];    // "pfifo_fast", "tbf", "htb", ...
    int                 priv_size;

    int  (*enqueue)(struct sk_buff *, struct Qdisc *, struct sk_buff **);
    struct sk_buff* (*dequeue)(struct Qdisc *);
    struct sk_buff* (*peek)(struct Qdisc *);

    int  (*init)(struct Qdisc *, struct nlattr *, struct netlink_ext_ack *);
    void (*destroy)(struct Qdisc *);
    int  (*change)(struct Qdisc *, struct nlattr *, struct netlink_ext_ack *);
    void (*attach)(struct Qdisc *);
    int  (*dump)(struct Qdisc *, struct sk_buff *);
    int  (*dump_stats)(struct Qdisc *, struct gnet_dump *);
};
```

---

## 3. `pfifo_fast` — The Default Qdisc

**Source:** `net/sched/sch_generic.c`

Three bands (0=high, 1=medium, 2=low), prioritized FIFO:

```c
static const u8 prio2band[TC_PRIO_MAX + 1] = {
    1, 2, 2, 2, 1, 2, 0, 0,   // TC_PRIO_BESTEFFORT=0 → band 1
    1, 1, 1, 1, 1, 1, 1, 1,   // TC_PRIO_INTERACTIVE=6 → band 0
};

static int pfifo_fast_enqueue(struct sk_buff *skb, struct Qdisc *qdisc, ...)
{
    int band = prio2band[skb->priority & TC_PRIO_MAX];
    struct skb_array *q = band2list(priv, band);

    if (unlikely(skb_array_full(q))) {
        qdisc->qstats.drops++;
        return qdisc_drop(skb, qdisc, to_free);
    }
    skb_array_produce(q, skb);
    return NET_XMIT_SUCCESS;
}

static struct sk_buff *pfifo_fast_dequeue(struct Qdisc *qdisc)
{
    /* Always dequeue from lowest-numbered (highest-priority) band first */
    for (int band = 0; band < PFIFO_FAST_BANDS; band++) {
        skb = skb_array_consume(band2list(priv, band));
        if (skb) return skb;
    }
    return NULL;
}
```

---

## 4. Token Bucket Filter (`tbf`) — Rate Limiting

**Source:** `net/sched/sch_tbf.c`

TBF limits bandwidth to a specified rate using a token bucket:

```
Tokens refill at RATE (bytes/sec)
Bucket capacity = BURST (bytes)
Packet needs tokens to be sent; if not enough tokens → wait or drop
```

```c
static int tbf_enqueue(struct sk_buff *skb, struct Qdisc *sch, ...)
{
    struct tbf_sched_data *q = qdisc_priv(sch);

    /* Does packet fit in the queue? */
    if (qdisc_pkt_len(skb) > q->limit) {
        return qdisc_drop(skb, sch, to_free);
    }
    return qdisc_enqueue_tail(skb, sch);
}

static struct sk_buff *tbf_dequeue(struct Qdisc *sch)
{
    struct tbf_sched_data *q = qdisc_priv(sch);
    struct sk_buff *skb = qdisc_peek_head(sch);

    /* Refill tokens based on time elapsed */
    now = ktime_get_ns();
    toks = q->tokens + (now - q->t_c) * q->rate.rate_bytes_ps / NSEC_PER_SEC;
    toks = min_t(s64, toks, q->buffer);  // cap at burst size

    /* Can we send? */
    if (toks >= (s64)qdisc_pkt_len(skb)) {
        q->t_c = now;
        q->tokens = toks - qdisc_pkt_len(skb);
        return qdisc_dequeue_head(sch);
    }

    /* Not enough tokens: set watchdog timer to wake when tokens available */
    qdisc_watchdog_schedule_ns(&q->watchdog, now + delay);
    return NULL;
}
```

```bash
# Rate limit eth0 to 1 mbit/s with 10kb burst
tc qdisc add dev eth0 root tbf rate 1mbit burst 10kb latency 50ms
```

---

## 5. Hierarchical Token Bucket (`htb`) — Class-Based QoS

**Source:** `net/sched/sch_htb.c`

HTB is the standard for class-based traffic shaping:

```
1:0 root qdisc
 └── 1:1 htb class (ceiling: 100mbit)
       ├── 1:10 htb class (guaranteed: 30mbit, ceil: 100mbit) → for HTTP
       ├── 1:20 htb class (guaranteed: 20mbit, ceil: 100mbit) → for SSH
       └── 1:30 htb class (guaranteed: 10mbit, ceil: 30mbit)  → for bulk
```

```bash
# Set up HTB
tc qdisc add dev eth0 root handle 1: htb default 30

tc class add dev eth0 parent 1: classid 1:1 htb rate 100mbit burst 15k

tc class add dev eth0 parent 1:1 classid 1:10 htb rate 30mbit ceil 100mbit burst 15k
tc class add dev eth0 parent 1:1 classid 1:20 htb rate 20mbit ceil 100mbit burst 15k
tc class add dev eth0 parent 1:1 classid 1:30 htb rate 10mbit ceil  30mbit burst 15k

# Attach leaf qdiscs
tc qdisc add dev eth0 parent 1:10 handle 10: sfq perturb 10
tc qdisc add dev eth0 parent 1:20 handle 20: sfq perturb 10

# Classify traffic with filters
tc filter add dev eth0 protocol ip parent 1:0 prio 1 \
    u32 match ip dport 80 0xffff flowid 1:10
tc filter add dev eth0 protocol ip parent 1:0 prio 1 \
    u32 match ip dport 22 0xffff flowid 1:20
```

---

## 6. Network Emulation (`netem`) — Testing

**Source:** `net/sched/sch_netem.c`

`netem` adds artificial delay, loss, duplication, corruption — invaluable for testing:

```bash
# Add 100ms delay with 10ms jitter to all outgoing traffic on lo
tc qdisc add dev lo root netem delay 100ms 10ms

# Add 1% packet loss
tc qdisc change dev lo root netem delay 100ms loss 1%

# Add packet reordering (25% chance, correlated 50%)
tc qdisc change dev lo root netem delay 100ms reorder 25% 50%

# Remove
tc qdisc del dev lo root
```

Kernel implementation:
```c
/* Packets enter a sorted list, dequeued when their timestamp is reached */
/* Uses a red-black tree sorted by delivery time */
static int netem_enqueue(struct sk_buff *skb, struct Qdisc *sch, ...)
{
    u64 now   = ktime_get_ns();
    u64 delay = netem_delay(q);          // base ± jitter, maybe correlated
    cb->time_to_send = now + delay;

    /* Insert into sorted tree */
    netem_rb_insert(&q->t_root, cb);
}
```

---

## 7. Hands-On

### 7a. Inspect default qdisc
```bash
# Show current qdisc on all interfaces
tc qdisc show

# Show on specific interface
tc qdisc show dev eth0

# Show statistics
tc -s qdisc show dev eth0
```

### 7b. Add netem delay (safe, reversible)
```bash
# Add 50ms delay on loopback
sudo tc qdisc add dev lo root netem delay 50ms

# Verify (ping localhost should now show ~50ms)
ping -c5 127.0.0.1

# Show qdisc stats
tc -s qdisc show dev lo

# Remove
sudo tc qdisc del dev lo root
```

### 7c. Rate limiting test
```bash
# Limit loopback to 1mbit
sudo tc qdisc add dev lo root tbf rate 1mbit burst 32kbit latency 400ms

# Test with iperf (if available) or dd
dd if=/dev/zero bs=1M count=10 | nc -q1 127.0.0.1 9999 &
nc -l 9999 > /dev/null

# Remove
sudo tc qdisc del dev lo root
```

### 7d. Read qdisc source
```bash
ls ~/linux/net/sched/
grep -n "struct Qdisc_ops" ~/linux/net/sched/sch_tbf.c | head -5
grep -n "tbf_enqueue\|tbf_dequeue" ~/linux/net/sched/sch_tbf.c | head -10
```

---

## 8. Concept Check

1. What is the default qdisc in Linux and how does it prioritize packets? What kernel field does it read?
2. How does TBF achieve rate limiting without dropping packets if there's queue space? What wakes up the dequeue when tokens refill?
3. In an HTB hierarchy, what happens when a class exceeds its `rate` but hasn't hit its `ceil`? What does it borrow from?
4. What does `netem` use to correctly schedule delayed packets? Why is ordering important?

---

## 📚 References
- `net/core/dev.c` — `dev_queue_xmit`, `__qdisc_run`
- `net/sched/sch_generic.c` — `pfifo_fast`
- `net/sched/sch_tbf.c` — token bucket filter
- `net/sched/sch_htb.c` — hierarchical token bucket
- `net/sched/sch_netem.c` — network emulator
- `include/net/sch_generic.h` — `struct Qdisc`
- Kernel docs: `Documentation/networking/net-sysfs.rst`
