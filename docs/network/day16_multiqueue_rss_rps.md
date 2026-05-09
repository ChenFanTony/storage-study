# Day 16 — Multi-Queue NICs: RSS, RPS, RFS, and XPS
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 3)

---

## 🎯 Goal
Understand how modern NICs use multiple hardware queues to distribute packet processing across CPUs, and how the kernel's RSS/RPS/RFS/XPS stack scales network throughput on multi-core systems.

---

## 1. The Single-Queue Bottleneck

Early networking: one RX queue, one interrupt, one CPU handles all packets.

```
NIC HW → rx_ring[0] → IRQ → CPU 0 → netif_receive_skb()
                                 ↑
                        ALL packets handled here
                        → CPU 0 becomes the bottleneck at ~1M pps
```

Modern 10G/40G/100G NICs can receive millions of packets per second. Solution: **multiple hardware queues, one per CPU**.

---

## 2. RSS — Receive Side Scaling (Hardware)

**Source:** `net/core/dev.c`, driver code

RSS uses a **hardware hash** on the 4-tuple (src_ip, src_port, dst_ip, dst_port) to distribute packets across multiple RX queues, each assigned to a different CPU.

```
Packet arrives
  └── NIC hardware computes Toeplitz hash on 4-tuple
        └── hash % num_queues → queue index
              └── queue N → IRQ N → CPU N → NAPI poll N
```

```
CPU 0 handles: flows A, D, G (queue 0)
CPU 1 handles: flows B, E, H (queue 1)
CPU 2 handles: flows C, F, I (queue 2)
```

**Benefit:** Same flow always goes to same CPU → cache locality for `struct sock`.

### Kernel structures
```c
/* struct net_device has multiple RX queues */
struct net_device {
    struct netdev_rx_queue  *_rx;        // array of RX queues
    unsigned int            num_rx_queues;
    unsigned int            real_num_rx_queues;
    /* ... */
};

struct netdev_rx_queue {
    struct xdp_rxq_info xdp_rxq;
    struct napi_struct  *napi;
    struct net_device   *dev;
    /* ... */
};
```

### Configure RSS
```bash
# See current number of RX/TX queues
ethtool -l eth0

# Set number of queues (max is hardware limit)
ethtool -L eth0 rx 4 tx 4

# View IRQ affinity (which CPU each queue IRQ goes to)
cat /proc/interrupts | grep eth0
# Set CPU affinity for queue 0 IRQ
echo "1" > /proc/irq/<irq_num>/smp_affinity  # CPU 0 bitmask
```

---

## 3. RPS — Receive Packet Steering (Software RSS)

**Source:** `net/core/dev.c`

NICs without hardware multi-queue can use RPS: software computes the flow hash and **steers packets to the correct CPU** after the driver.

```c
/* net/core/dev.c - get_rps_cpu() */
static int get_rps_cpu(struct net_device *dev, struct sk_buff *skb,
                       struct rps_dev_flow **rflowp)
{
    struct rps_map *map;
    u32 hash;

    /* Compute software hash on 4-tuple */
    hash = skb_get_hash(skb);

    /* Map hash to CPU using rps_map */
    map = rcu_dereference(rxqueue->rps_map);
    if (!map || map->len == 0)
        return -1;

    /* Simple modular distribution */
    tcpu = map->cpus[reciprocal_scale(hash, map->len)];
    return tcpu;
}
```

When a different CPU is selected:
```c
/* Enqueue skb to target CPU's input queue via IPI */
enqueue_to_backlog(skb, target_cpu, ...);
/* → raise NET_RX_SOFTIRQ on target CPU */
/* → target CPU runs netif_receive_skb() */
```

### Enable RPS
```bash
# Enable RPS on eth0 queue 0, allow CPUs 0-3 (bitmask 0xf)
echo "f" > /sys/class/net/eth0/queues/rx-0/rps_cpus

# For all queues:
for q in /sys/class/net/eth0/queues/rx-*/rps_cpus; do
    echo "f" > $q
done
```

---

## 4. RFS — Receive Flow Steering

**Source:** `net/core/dev.c`

RPS distributes flows evenly across CPUs, but the application processing a flow might be on a different CPU → cache miss for the socket.

**RFS** tracks which CPU last processed a flow's `recvmsg()` and steers future packets to that CPU.

```c
/* Maintained by the kernel automatically */
struct rps_sock_flow_table {
    u32  mask;
    u32  ents[0];   // hash → CPU mapping, updated on recv()
};

/* Updated in tcp_recvmsg() / udp_recvmsg(): */
sock_rps_record_flow(sk);
  └── rps_record_sock_flow(sock_net(sk)->ipv4.rps_sock_flow_table,
                            sk->sk_rxhash);
      // stores current CPU for this flow's hash
```

```bash
# Enable RFS (set global flow table size)
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries

# Set per-queue RFS size
echo 4096 > /sys/class/net/eth0/queues/rx-0/rps_flow_cnt
```

**Combined RSS + RFS:** Hardware RSS puts packet on CPU N. RFS corrects it if the socket is being read on CPU M. Result: packets end up on the CPU where `recvmsg()` runs.

---

## 5. XPS — Transmit Packet Steering

**Source:** `net/core/dev.c`

XPS chooses which TX queue to use for outgoing packets, optimizing for:
- **CPU locality**: use TX queue associated with current CPU
- **Cache efficiency**: avoid cross-CPU TX queue contention

```c
/* net/core/dev.c - netdev_pick_tx() */
static u16 netdev_pick_tx(struct net_device *dev, struct sk_buff *skb,
                           struct net_device *sb_dev)
{
    struct sock *sk = skb->sk;
    int queue_index = 0;

    /* If socket has a cached TX queue, reuse it */
    if (sk) {
        queue_index = sk_tx_queue_get(sk);
        if (queue_index >= 0 && ...) {
            return queue_index;
        }
    }

    /* XPS: find TX queue for current CPU */
    queue_index = __netdev_pick_tx(dev, skb, sb_dev);
    if (sk)
        sk_tx_queue_set(sk, queue_index);

    return queue_index;
}
```

### Configure XPS
```bash
# Assign TX queue 0 to CPU 0 only (bitmask)
echo "1" > /sys/class/net/eth0/queues/tx-0/xps_cpus
echo "2" > /sys/class/net/eth0/queues/tx-1/xps_cpus
echo "4" > /sys/class/net/eth0/queues/tx-2/xps_cpus
echo "8" > /sys/class/net/eth0/queues/tx-3/xps_cpus
```

---

## 6. NUMA and Network Affinity

On multi-socket servers, NIC IRQs and memory must align with NUMA topology:

```
NUMA Node 0: CPUs 0-7,  memory bank 0
NUMA Node 1: CPUs 8-15, memory bank 1

NIC connected to PCIe on Node 0:
→ IRQs should go to CPUs 0-7 (local node)
→ sk_buff memory allocated from Node 0 (local DMA)
→ cross-node DMA adds ~50ns latency penalty
```

```bash
# Check NIC NUMA node
cat /sys/class/net/eth0/device/numa_node

# Check CPU NUMA topology
numactl --hardware

# Set IRQ affinity to NUMA-local CPUs
numactl --cpunodebind=0 <process>
```

---

## 7. `SO_REUSEPORT` — Multiple Sockets on Same Port

**Source:** `net/ipv4/inet_connection_sock.c`

With `SO_REUSEPORT`, multiple processes/threads each have their own socket on the same port. The kernel distributes incoming connections:

```c
/* Multiple server processes, each with own accept() loop */
for (int i = 0; i < num_cpus; i++) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
    bind(fd, &addr, sizeof(addr));   // all bind to same port!
    listen(fd, backlog);
    /* Each process calls accept() on its own fd */
}
```

**Kernel distribution:**
```c
/* net/ipv4/inet_hashtables.c */
/* For incoming SYN: select one of the REUSEPORT sockets */
/* Uses hash of 4-tuple for consistent selection */
struct sock *inet_lookup_listener(...)
{
    /* If SO_REUSEPORT group: */
    result = reuseport_select_sock(sk, phash, skb, doff);
    /* Optionally: BPF program controls selection */
}
```

```bash
# Nginx and modern servers use SO_REUSEPORT with worker_processes
grep reuseport /etc/nginx/nginx.conf 2>/dev/null
```

---

## 8. Hands-On

### 8a. Inspect multi-queue setup
```bash
# Number of queues
ethtool -l eth0 2>/dev/null || echo "ethtool not available or single-queue"

# IRQ affinity
cat /proc/interrupts | grep -i "eth\|ens\|eno" | head -10

# Per-queue stats
ethtool -S eth0 2>/dev/null | grep -E "queue|rx_|tx_" | head -20
```

### 8b. Check RPS/RFS configuration
```bash
# Current RPS CPU masks
cat /sys/class/net/*/queues/rx-*/rps_cpus 2>/dev/null

# RFS flow table size
cat /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null

# XPS TX CPU masks
cat /sys/class/net/*/queues/tx-*/xps_cpus 2>/dev/null
```

### 8c. Observe per-CPU softirq stats
```bash
# Per-CPU NET_RX and NET_TX softirq counts
cat /proc/softirqs | grep -E "NET_RX|NET_TX"

# Per-CPU network stats
cat /proc/net/softnet_stat
# columns: total, dropped, time_squeeze, 0, 0, 0, 0, 0, 0, cpu_collision, received_rps, flow_limit_count
```

### 8d. Find flow hash computation
```bash
grep -n "skb_get_hash\|skb_set_hash\|__skb_get_hash" \
    ~/linux/include/linux/skbuff.h | head -10
grep -n "flow_dissect\|__flow_hash" \
    ~/linux/net/core/flow_dissector.c | head -10
```

---

## 9. Concept Check

1. What is the fundamental difference between RSS (hardware) and RPS (software)? When would you use one over the other?
2. Why does RFS improve performance over plain RPS? What information does RFS track and where is it stored?
3. What performance problem does XPS solve on the transmit side? How does the kernel know which TX queue to pick?
4. With `SO_REUSEPORT`, how does the kernel decide which socket receives a new connection? Why is this more scalable than a single `accept()` with multiple threads?

---

## 📚 References
- `net/core/dev.c` — `get_rps_cpu`, `netdev_pick_tx`, `enqueue_to_backlog`
- `net/core/flow_dissector.c` — flow hash computation
- `net/ipv4/inet_hashtables.c` — `SO_REUSEPORT` socket selection
- `include/linux/netdevice.h` — `netdev_rx_queue`
- Kernel docs: `Documentation/networking/scaling.rst`
