# Day 23 — Softirq and NAPI In Depth: The Linux Packet I/O Engine
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 4)

---

## 🎯 Goal
Understand the full softirq subsystem, how `NET_RX_SOFTIRQ` and `NET_TX_SOFTIRQ` work, and how NAPI ties together interrupt mitigation, CPU scheduling, and budget management.

---

## 1. Interrupt Context Problem

Hardware interrupts must be short — they block all other interrupts on that CPU. But packet processing is expensive (checksums, routing, socket demux). The solution: **defer work to softirq context**.

```
Hard IRQ (interrupt disabled):
  NIC raises IRQ → handler runs
    ├── Acknowledge interrupt in NIC hardware
    ├── Schedule NAPI poll (napi_schedule)
    └── Return  ← must be fast (<10μs)

Softirq (interrupt re-enabled, but non-preemptible):
  NET_RX_SOFTIRQ runs:
    └── napi_poll() ← actual packet processing
          └── netif_receive_skb() → full stack
```

---

## 2. The Softirq Subsystem

**Source:** `kernel/softirq.c`, `include/linux/interrupt.h`

```c
/* 10 softirq vectors, fixed priorities */
enum {
    HI_SOFTIRQ = 0,          // tasklets (high priority)
    TIMER_SOFTIRQ,            // timer wheel
    NET_TX_SOFTIRQ,           // network transmit
    NET_RX_SOFTIRQ,           // network receive ← our focus
    BLOCK_SOFTIRQ,            // block I/O completion
    IRQ_POLL_SOFTIRQ,         // block device polling
    TASKLET_SOFTIRQ,          // tasklets (normal priority)
    SCHED_SOFTIRQ,            // scheduler
    HRTIMER_SOFTIRQ,          // high-res timers
    RCU_SOFTIRQ,              // RCU callbacks
};
```

### Raising a softirq
```c
/* Called from hard IRQ handler: */
__raise_softirq_irqoff(NET_RX_SOFTIRQ);
/* Sets a bit in per-CPU __softirq_pending bitmask */
/* Softirq processing deferred until:              */
/*   - irq_exit() after hard IRQ returns           */
/*   - explicit local_bh_enable()                  */
/*   - ksoftirqd kernel thread                     */
```

### Softirq execution
```c
/* kernel/softirq.c */
static void __do_softirq(void)
{
    unsigned long pending = local_softirq_pending();

    /* Disable further softirq raises on this CPU */
    __local_bh_disable_ip(_RET_IP_, SOFTIRQ_DISABLE_OFFSET);

    /* Process pending softirqs */
    while (pending) {
        int vec_nr = __ffs(pending);  // find lowest set bit
        h = softirq_vec + vec_nr;
        h->action();                  // e.g., net_rx_action()
        pending &= ~(1 << vec_nr);
    }

    __local_bh_enable(SOFTIRQ_DISABLE_OFFSET);
}
```

### `ksoftirqd` — the softirq kernel thread
```c
/* When softirq work is excessive (>10 loops or >2ms), */
/* offload to per-CPU ksoftirqd thread */
/* Prevents starvation of regular kernel threads */

/* Check which CPU has ksoftirqd running */
ps aux | grep ksoftirqd
# ksoftirqd/0, ksoftirqd/1, ... one per CPU
```

---

## 3. `net_rx_action()` — The RX Softirq Handler

**Source:** `net/core/dev.c`

```c
static __latent_entropy void net_rx_action(struct softirq_action *h)
{
    struct softnet_data *sd = this_cpu_ptr(&softnet_data);
    unsigned long time_limit = jiffies +
        usecs_to_jiffies(netdev_budget_usecs);  // default 2ms
    int budget = netdev_budget;                  // default 300 packets
    LIST_HEAD(list);
    LIST_HEAD(repoll);

    /* Snapshot the poll list (NAPI instances to service) */
    list_splice_init(&sd->poll_list, &list);

    for (;;) {
        struct napi_struct *n;

        if (list_empty(&list)) {
            /* No more work */
            sd->in_net_rx_action = false;
            break;
        }

        n = list_first_entry(&list, struct napi_struct, poll_list);
        budget -= napi_poll(n, &repoll);     /* do the actual polling */

        /* Budget or time exhausted? Stop processing, wake ksoftirqd */
        if (unlikely(budget <= 0 ||
                     time_after_eq(jiffies, time_limit))) {
            sd->time_squeeze++;
            /* Re-add remaining NAPI instances to poll_list */
            __raise_softirq_irqoff(NET_RX_SOFTIRQ);
            break;
        }
    }

    /* Re-add instances that still have work (didn't drain) */
    list_splice_tail(&repoll, &sd->poll_list);
}
```

### Tuning the budget
```bash
# Total packets per NET_RX_SOFTIRQ invocation
sysctl net.core.netdev_budget        # default 300

# Time limit per invocation (microseconds)
sysctl net.core.netdev_budget_usecs  # default 2000

# If increasing: better throughput, worse latency
# If decreasing: better latency, worse throughput
```

---

## 4. `napi_struct` and the Poll Lifecycle

**Source:** `include/linux/netdevice.h`, `net/core/dev.c`

```c
struct napi_struct {
    struct list_head    poll_list;   // on sd->poll_list when scheduled
    unsigned long       state;       // NAPI_STATE_SCHED, NAPI_STATE_DISABLE
    int                 weight;      // max packets per poll (default 64)
    int                 (*poll)(struct napi_struct *, int); // driver callback
    struct net_device   *dev;
    struct gro_list     gro_list;    // GRO accumulation
    struct sk_buff      *skb;        // current GRO candidate
    struct list_head    dev_list;
};
```

### Full NAPI lifecycle
```
1. Driver init: netif_napi_add(dev, &napi, poll_fn, weight=64)

2. Hard IRQ fires:
   e1000_intr()
     ├── Mask NIC interrupts (stop more IRQs)
     └── napi_schedule(&adapter->napi)
           └── if (!napi_is_scheduled(n)):
                 list_add_tail(&n->poll_list, &sd->poll_list)
                 __raise_softirq_irqoff(NET_RX_SOFTIRQ)

3. NET_RX_SOFTIRQ runs:
   net_rx_action()
     └── napi_poll(n, &repoll)
           └── work = n->poll(n, budget)   ← e1000_clean()
                 ├── process ring buffer entries
                 └── call netif_receive_skb() for each packet

4. If ring drained (work < budget):
   napi_complete_done(n, work)
     ├── Remove from poll_list
     └── Re-enable NIC interrupts (allow new hard IRQ)

5. If budget exhausted (work == budget):
   ├── Return work (net_rx_action re-adds to repoll list)
   └── NIC interrupts remain disabled
       NET_RX_SOFTIRQ raised again
```

---

## 5. `softnet_data` — Per-CPU State

**Source:** `include/linux/netdevice.h`

```c
struct softnet_data {
    struct list_head    poll_list;      // NAPI instances to poll
    struct sk_buff_head process_queue;  // packets awaiting processing

    /* Statistics */
    unsigned int        processed;      // packets processed
    unsigned int        time_squeeze;   // budget exhausted
    unsigned int        received_rps;   // packets steered via RPS
    unsigned int        dropped;        // packets dropped (backlog full)

    /* RPS / backlog */
    struct backlog_dev  backlog;        // non-NAPI fallback
    unsigned int        input_queue_head;
    unsigned int        input_queue_tail;

    /* Throttle */
    struct Qdisc        *output_queue;  // TX qdisc list
    struct Qdisc        **output_queue_tailp;
};
DEFINE_PER_CPU_ALIGNED(struct softnet_data, softnet_data);
```

```bash
# Per-CPU softnet stats
cat /proc/net/softnet_stat
# Format: hex columns per CPU:
# total dropped time_squeeze 0 0 0 0 0 0 cpu_collision received_rps flow_limit_count
```

---

## 6. `NET_TX_SOFTIRQ` — Transmit Completion

**Source:** `net/core/dev.c`

```c
static void net_tx_action(struct softirq_action *h)
{
    struct softnet_data *sd = this_cpu_ptr(&softnet_data);

    /* 1. Free completed TX skbs */
    if (sd->completion_queue) {
        struct sk_buff *clist = sd->completion_queue;
        sd->completion_queue = NULL;

        while (clist) {
            struct sk_buff *skb = clist;
            clist = clist->next;
            /* Calls skb->destructor → sock_wfree() → wakes send() */
            __kfree_skb(skb);
        }
    }

    /* 2. Run queued qdiscs (TX scheduling) */
    if (sd->output_queue) {
        struct Qdisc *head = sd->output_queue;
        sd->output_queue = NULL;
        sd->output_queue_tailp = &sd->output_queue;

        while (head) {
            struct Qdisc *q = head;
            head = q->next_sched;
            qdisc_run(q);  /* dequeue and transmit */
        }
    }
}
```

---

## 7. GRO in NAPI Context

**Source:** `net/core/gro.c`

GRO (Generic Receive Offload) coalesces multiple small skbs into one large skb inside NAPI poll:

```c
/* Driver calls this instead of netif_receive_skb() for GRO: */
gro_result_t napi_gro_receive(struct napi_struct *napi, struct sk_buff *skb)
{
    /* Try to merge skb with an existing GRO candidate in napi->gro_list */
    ret = napi_gro_complete(napi, skb);   /* if flush needed */
    /* or: add to gro_list for later merging */
    return ret;
}

/* At end of NAPI poll, flush all GRO candidates: */
napi_complete_done(napi, work)
  └── napi_gro_flush(napi, false)
        └── for each skb in napi->gro_list:
              netif_receive_skb(skb)   /* deliver coalesced skb */
```

---

## 8. Hands-On

### 8a. Observe softirq counts per CPU
```bash
# NET_RX and NET_TX softirq counts per CPU
cat /proc/softirqs

# Watch in real-time
watch -n1 'cat /proc/softirqs | grep -E "NET_RX|NET_TX"'
```

### 8b. softnet_stat deep dive
```bash
python3 - << 'EOF'
import re

with open('/proc/net/softnet_stat') as f:
    for cpu, line in enumerate(f):
        fields = line.split()
        total      = int(fields[0], 16)
        dropped    = int(fields[1], 16)
        time_sq    = int(fields[2], 16)
        rps        = int(fields[9], 16) if len(fields) > 9 else 0
        print(f"CPU{cpu}: total={total:8d} dropped={dropped:6d} "
              f"time_squeeze={time_sq:6d} rps={rps:6d}")
EOF
```

### 8c. ksoftirqd activity
```bash
# Is ksoftirqd running hard?
top -b -n1 | grep ksoftirqd | head -8
# High CPU% = softirq overload → tune netdev_budget

# Per-CPU ksoftirqd threads
ps -eo pid,psr,comm | grep ksoftirqd
```

### 8d. NAPI weight and GRO
```bash
# GRO stats
ethtool -S eth0 2>/dev/null | grep -i "gro\|coales" | head -10

# Netdev budget setting
sysctl net.core.netdev_budget
sysctl net.core.netdev_budget_usecs

# Find NAPI weight in driver
grep -r "netif_napi_add\|napi_add" \
    ~/linux/drivers/net/ethernet/intel/e1000/e1000_main.c | head -5
```

---

## 9. Concept Check

1. Why must the hard IRQ handler be short? What would happen if all packet processing ran in hard IRQ context?
2. What is the `weight` field in `napi_struct`? What happens if a driver's poll function returns exactly `weight` packets every time?
3. When does `ksoftirqd` take over from inline softirq processing? What problem does this prevent?
4. What does `time_squeeze` in `/proc/net/softnet_stat` measure? What does a high value tell you about system performance?

---

## 📚 References
- `kernel/softirq.c` — softirq core: `__do_softirq`, `raise_softirq`
- `net/core/dev.c` — `net_rx_action`, `net_tx_action`, `napi_poll`
- `net/core/gro.c` — GRO implementation
- `include/linux/netdevice.h` — `napi_struct`, `softnet_data`
- `drivers/net/ethernet/intel/e1000/e1000_main.c` — real NAPI driver
- Kernel docs: `Documentation/networking/napi.rst`
