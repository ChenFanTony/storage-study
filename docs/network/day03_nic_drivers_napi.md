# Day 03 — NIC Drivers, Ring Buffers, and NAPI
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 1)

---

## 🎯 Goal
Understand how a NIC driver receives packets from hardware, uses DMA ring buffers, and hands packets up via the NAPI polling mechanism.

---

## 1. The Hardware-to-Kernel Gap

When a packet arrives at the NIC:
1. NIC DMA's the frame into a **pre-allocated ring buffer** in RAM
2. NIC raises a **hardware interrupt**
3. Kernel interrupt handler fires, schedules **NAPI poll**
4. NAPI **polls** the ring buffer (disabling further interrupts temporarily)
5. For each frame: allocates `sk_buff`, calls `netif_receive_skb()`
6. `sk_buff` travels up the stack

```
NIC HW ──DMA──► rx_ring[tail] (struct e1000_rx_desc)
                      │
               HW interrupt (IRQ)
                      │
               e1000_intr() / napi_schedule()
                      │
               napi_poll() → e1000_clean_rx_irq()
                      │
               netif_receive_skb(skb)
                      │
               ip_rcv() → tcp_v4_rcv() → ...
```

---

## 2. The RX Ring Buffer

A ring buffer (descriptor ring) is a fixed-size circular array of **descriptors**, each pointing to a pre-allocated DMA buffer.

```
Index:   0        1        2        3   ...   N-1
       [ desc ][ desc ][ desc ][ desc ]...[ desc ]
          │       │       │
          ▼       ▼       ▼
        [buf]   [buf]   [buf]     ← pre-allocated DMA-mapped memory
```

### Descriptor structure (e.g., Intel e1000)
```c
/* drivers/net/ethernet/intel/e1000/e1000.h */
struct e1000_rx_desc {
    __le64  buffer_addr;    // physical address of DMA buffer
    __le16  length;         // bytes written by NIC
    __le16  csum;           // hardware checksum
    __u8    status;         // DD bit: descriptor done (NIC wrote data)
    __u8    errors;
    __le16  special;
};
```

### Ring buffer pointers
```
head (kernel reads from here) → [...][...][ ← NIC writes here] ← tail
```
- Kernel advances **head** after consuming a descriptor
- NIC advances **tail** after DMA-ing a packet
- When head == tail: ring is empty (nothing to read)

---

## 3. `net_device` — The NIC Abstraction

**Source:** `include/linux/netdevice.h`

Every NIC is represented as a `net_device`:

```c
struct net_device {
    char            name[IFNAMSIZ];     // "eth0", "lo", "ens3"
    unsigned char   dev_addr[MAX_ADDR_LEN]; // MAC address

    const struct net_device_ops *netdev_ops;  // driver operations
    const struct ethtool_ops    *ethtool_ops; // ethtool support

    unsigned int    mtu;            // max transmission unit
    unsigned int    flags;          // IFF_UP, IFF_BROADCAST, ...
    unsigned int    priv_flags;

    struct netdev_rx_queue  *_rx;   // RX queues (multi-queue NICs)
    struct netdev_queue     *_tx;   // TX queues

    struct net         *nd_net;     // network namespace
};
```

### Driver operations table
```c
static const struct net_device_ops e1000_netdev_ops = {
    .ndo_open           = e1000_open,       // ifconfig eth0 up
    .ndo_stop           = e1000_close,      // ifconfig eth0 down
    .ndo_start_xmit     = e1000_xmit_frame, // transmit packet
    .ndo_set_rx_mode    = e1000_set_rx_mode,
    .ndo_set_mac_address = e1000_set_mac,
    .ndo_change_mtu     = e1000_change_mtu,
};
```

---

## 4. NAPI — New API for Interrupt Mitigation

**Problem with pure interrupts:** At high packet rates, interrupt storms overwhelm the CPU (100k+ interrupts/sec).

**NAPI solution:** After first interrupt, **disable NIC interrupts** and **poll** the ring buffer in a budget loop instead.

```c
// Simplified NAPI poll loop (what the driver implements)
int e1000_clean(struct napi_struct *napi, int budget)
{
    struct e1000_adapter *adapter = container_of(napi, ...);
    int work_done = 0;

    // Process up to `budget` packets from the ring
    e1000_clean_rx_irq(adapter, &work_done, budget);
    e1000_clean_tx_irq(adapter);

    if (work_done < budget) {
        // Ring drained — re-enable interrupts and stop polling
        napi_complete_done(napi, work_done);
        e1000_irq_enable(adapter);
    }
    return work_done;
}
```

### NAPI lifecycle
```
1. Interrupt fires → e1000_intr()
2. Disable NIC interrupt
3. napi_schedule(&adapter->napi)
   └── adds napi to softirq poll_list
4. NET_RX_SOFTIRQ runs net_rx_action()
   └── calls napi->poll() == e1000_clean()
5. If ring empty: napi_complete() + re-enable IRQ
   If ring not empty (budget exhausted): reschedule next NAPI poll
```

### Key NAPI functions
```c
napi_schedule(napi)         // schedule poll (from interrupt context)
napi_complete_done(napi, n) // done polling, re-arm interrupts
netif_napi_add(dev, napi, poll_fn, weight) // register NAPI instance
```
**Source:** `net/core/dev.c`, `include/linux/netdevice.h`

---

## 5. From Ring Buffer to `sk_buff`

Inside the poll loop, for each received descriptor:

```c
// Simplified from e1000_clean_rx_irq()
skb = netdev_alloc_skb_ip_align(netdev, length);
// copy or map DMA buffer into skb->data
memcpy(skb->data, rx_buffer->data, length);
skb->protocol = eth_type_trans(skb, netdev);  // detect ETH_P_IP etc.
skb->ip_summed = CHECKSUM_UNNECESSARY;        // if HW verified checksum

netif_receive_skb(skb);  // hand off to network stack
```

After `netif_receive_skb()`, the driver no longer owns the `sk_buff`.

---

## 6. Hands-On

### 6a. Explore e1000 driver structure
```bash
ls ~/linux/drivers/net/ethernet/intel/e1000/
cat ~/linux/drivers/net/ethernet/intel/e1000/e1000_main.c | head -100

# Find NAPI setup
grep -n "netif_napi_add\|napi_schedule\|napi_complete" \
    ~/linux/drivers/net/ethernet/intel/e1000/e1000_main.c
```

### 6b. Find netif_receive_skb
```bash
grep -n "netif_receive_skb\|__netif_receive_skb" net/core/dev.c | head -20
```

### 6c. Observe NIC interrupt and NAPI stats
```bash
# Per-CPU interrupt counts
cat /proc/interrupts | grep -i eth

# NAPI poll stats (if driver supports)
ethtool -S eth0 2>/dev/null | grep -i "rx_poll\|napi"

# NIC ring buffer sizes
ethtool -g eth0

# Driver info
ethtool -i eth0
```

### 6d. Watch RX drops (ring overflows)
```bash
watch -n1 'ip -s link show eth0'
# Look for: RX errors, dropped, overrun
```

---

## 7. Concept Check

1. Why does NAPI disable interrupts after the first one fires? What problem does this solve?
2. What happens if NAPI processes all `budget` packets but the ring still has more? What if the ring is empty before budget?
3. How does a driver tell the kernel what protocol a received frame contains?
4. What is DMA and why must receive buffers be DMA-mapped before handing them to the NIC?

---

## 📚 References
- `drivers/net/ethernet/intel/e1000/e1000_main.c` — real driver example
- `net/core/dev.c` — `netif_receive_skb`, NAPI poll loop
- `include/linux/netdevice.h` — `net_device`, `napi_struct`
- Kernel docs: `Documentation/networking/napi.rst`
