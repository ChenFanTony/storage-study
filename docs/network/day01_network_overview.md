# Day 01 — Linux Network Stack Overview
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 1)

---

## 🎯 Goal
Understand the big picture of how a packet travels from NIC hardware to a user-space process, and map that journey to kernel source directories.

---

## 1. The Five-Layer Mental Model

```
User Space
  └── Application (read/write on socket fd)
──────────────────────────────────────────
Kernel Space
  ├── [L5] Socket Layer        net/core/sock.c, net/core/socket.c
  ├── [L4] Transport (TCP/UDP) net/ipv4/tcp.c, net/ipv4/udp.c
  ├── [L3] Network (IP)        net/ipv4/ip_input.c, ip_output.c
  ├── [L2] Link / Netfilter    net/core/dev.c, net/netfilter/
  └── [L1] Driver / NIC        drivers/net/ethernet/
```

A packet flowing **inbound**:
```
NIC HW → DMA → ring buffer → NAPI poll → netif_receive_skb()
       → ip_rcv() → tcp_v4_rcv() → sk_receive_queue → recv()
```

A packet flowing **outbound**:
```
send() → tcp_sendmsg() → ip_queue_xmit() → dev_queue_xmit()
       → driver tx ring → NIC HW → wire
```

---

## 2. Central Data Structure: `sk_buff`

Every packet in the kernel is wrapped in an `sk_buff` (socket buffer). Think of it as the networking equivalent of `struct page` in memory management.

**Source:** `include/linux/skbuff.h`

```c
struct sk_buff {
    /* --- routing / device --- */
    struct net_device   *dev;       // which NIC this belongs to
    struct sock         *sk;        // owning socket (NULL for forwarded pkts)

    /* --- timestamps --- */
    ktime_t             tstamp;

    /* --- data pointers (the "headroom/data/tailroom" model) --- */
    unsigned char       *head;      // start of allocated buffer
    unsigned char       *data;      // start of actual packet data
    unsigned char       *tail;      // end of packet data
    unsigned char       *end;       // end of allocated buffer

    unsigned int        len;        // total length
    unsigned int        data_len;   // length in frags (for non-linear skbs)

    /* --- protocol info --- */
    __be16              protocol;   // ETH_P_IP, ETH_P_IPV6, etc.
    __u16               transport_header;
    __u16               network_header;
    __u16               mac_header;
};
```

### Key layout diagram
```
[ head ][ headroom ][ data .............. tail ][ tailroom ][ end ]
                         ^                   ^
                       data                tail
```
- **headroom**: space to prepend headers (e.g., IP before TCP was added)
- **tailroom**: space to append (e.g., Ethernet FCS)

### Important `sk_buff` helpers
```c
skb->data                        // pointer to current protocol header
skb_transport_header(skb)        // pointer to L4 header
skb_network_header(skb)          // pointer to L3 header
skb_mac_header(skb)              // pointer to L2 header
skb_put(skb, len)                // extend tail by len, return old tail
skb_push(skb, len)               // extend head (prepend header)
skb_pull(skb, len)               // shrink head (consume header)
```

---

## 3. Key Source Directories

| Directory | What lives here |
|---|---|
| `net/core/` | `sk_buff` management, socket API, device abstraction |
| `net/ipv4/` | IPv4, TCP, UDP, ICMP implementation |
| `net/ipv6/` | IPv6 stack |
| `net/netfilter/` | iptables/nftables hook framework |
| `net/sched/` | Traffic control / QoS |
| `drivers/net/` | NIC drivers (e1000e, ixgbe, virtio_net, …) |
| `include/linux/skbuff.h` | `sk_buff` definition |
| `include/linux/netdevice.h` | `net_device` definition |
| `include/net/sock.h` | `struct sock` definition |

---

## 4. Hands-On Exploration

### 4a. Clone the kernel source (if not already done)
```bash
git clone --depth=1 https://github.com/torvalds/linux.git ~/linux
cd ~/linux
```

### 4b. Explore `sk_buff` size and fields
```bash
grep -n "struct sk_buff {" include/linux/skbuff.h
wc -l include/linux/skbuff.h          # see how big this file is
grep -c "inline" include/linux/skbuff.h  # count helper functions
```

### 4c. Trace packet flow with function names
```bash
# Find where IP receives a packet
grep -rn "ip_rcv" net/ipv4/ --include="*.c" | head -20

# Find where TCP receives a segment
grep -rn "tcp_v4_rcv" net/ipv4/ --include="*.c" | head -10

# Find NAPI polling entry point
grep -rn "napi_poll\|netif_receive_skb" net/core/dev.c | head -20
```

### 4d. Observe the live stack
```bash
# Socket statistics
ss -s

# Per-protocol counters
cat /proc/net/snmp | column -t

# Network interface stats
ip -s link show

# Active TCP connections with state
ss -tnp
```

---

## 5. Key Kernel Functions to Know (Week 1 Map)

| Function | File | What it does |
|---|---|---|
| `netif_receive_skb()` | `net/core/dev.c` | Entry point after NAPI poll |
| `ip_rcv()` | `net/ipv4/ip_input.c` | IP layer receive |
| `tcp_v4_rcv()` | `net/ipv4/tcp_ipv4.c` | TCP receive |
| `dev_queue_xmit()` | `net/core/dev.c` | Transmit path entry |
| `ip_output()` | `net/ipv4/ip_output.c` | IP transmit |
| `tcp_sendmsg()` | `net/ipv4/tcp.c` | TCP send from userspace |

---

## 6. Concept Check

Answer these before moving to Day 2:

1. What are the four data pointers in `sk_buff` and what does each mark?
2. What is the difference between `skb_push()` and `skb_put()`?
3. Which function is the first kernel function called when an IP packet arrives after the driver hands it off?
4. What file would you look in to understand how `socket()` syscall works?

---

## 📚 References
- `include/linux/skbuff.h` — `sk_buff` structure
- `net/core/dev.c` — core device layer
- *Linux Kernel Networking* — Rami Rosen, Ch. 1–2
- Kernel docs: `Documentation/networking/skbuff.rst`
