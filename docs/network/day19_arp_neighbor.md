# Day 19 — ARP, the Neighbor Subsystem, and the Link Layer
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 3)

---

## 🎯 Goal
Understand how Linux resolves IP addresses to MAC addresses via ARP, how the neighbor cache (`neigh`) subsystem works, and how Ethernet frames are built and delivered.

---

## 1. The Link Layer Problem

IP knows destinations by IP address. Ethernet needs MAC addresses. The bridge between them is ARP.

```
ip_finish_output2(skb, nexthop_ip)
  └── neigh = ip_neigh_for_gw(rt, skb, &is_v6gw)
        └── __ipv4_neigh_lookup_noref(dev, nexthop)
              ├── found in cache → neigh->output(neigh, skb)
              │                          → dev_queue_xmit()
              └── not found → neigh_resolve_output()
                                → send ARP request
                                → queue skb until resolved
```

---

## 2. The Neighbor Cache: `struct neighbour`

**Source:** `include/net/neighbour.h`, `net/core/neighbour.c`

```c
struct neighbour {
    struct neighbour __rcu  *next;          // hash chain
    struct neigh_table      *tbl;           // &arp_tbl for IPv4
    struct neigh_parms      *parms;

    /* The key: IP address this entry resolves */
    __be32                  primary_key[0]; // e.g., 192.168.1.1

    /* The value: resolved MAC address */
    unsigned char           ha[ALIGN(MAX_ADDR_LEN, sizeof(unsigned long))];

    /* State machine */
    unsigned char           nud_state;      // NUD_REACHABLE, NUD_STALE, etc.
    unsigned char           type;           // RTN_UNICAST, RTN_MULTICAST
    atomic_t                refcnt;

    /* Output function (changes with state) */
    int (*output)(struct neighbour *, struct sk_buff *);

    /* Queued packets waiting for resolution */
    struct sk_buff_head     arp_queue;
    unsigned int            arp_queue_len_bytes;

    /* Timers */
    unsigned long           confirmed;      // last reachability confirmation
    unsigned long           updated;        // last state change
    struct timer_list       timer;
};
```

---

## 3. NUD State Machine

**NUD = Neighbor Unreachability Detection**

```
                    ┌──────────────────────────────────┐
                    │            NONE / NOARP           │
                    └──────────────┬───────────────────┘
                                   │ first packet
                                   ▼
                              INCOMPLETE
                               (ARP sent,
                              waiting reply)
                             /             \
                    ARP reply           timeout
                        │                  │
                        ▼                  ▼
                    REACHABLE           FAILED
                   (use directly)     (send ICMP
                        │              unreachable)
                   timer expires
                        │
                        ▼
                      STALE
                   (use, but verify)
                        │
                   used again
                        │
                        ▼
                     DELAY
                   (send probe)
                   /          \
              probed OK     timeout
                  │              │
                  ▼              ▼
             REACHABLE        PROBE
                           (send ucast ARP)
```

```c
/* NUD states */
#define NUD_INCOMPLETE  0x01   /* ARP request sent, no reply yet */
#define NUD_REACHABLE   0x02   /* MAC known, recently confirmed */
#define NUD_STALE       0x04   /* MAC known, needs verification */
#define NUD_DELAY       0x08   /* Delay before probing */
#define NUD_PROBE       0x10   /* Sending unicast probes */
#define NUD_FAILED      0x20   /* Cannot resolve, drop packets */
#define NUD_NOARP       0x40   /* No ARP needed (e.g., loopback) */
#define NUD_PERMANENT   0x80   /* Static entry, never expires */
```

---

## 4. ARP Request/Reply Flow

**Source:** `net/ipv4/arp.c`

### Sending an ARP request
```c
/* net/ipv4/arp.c */
void arp_send(int type, int ptype, __be32 dest_ip,
              struct net_device *dev, __be32 src_ip,
              const unsigned char *dest_hw,
              const unsigned char *src_hw,
              const unsigned char *target_hw)
{
    struct sk_buff *skb;
    struct arphdr *arp;

    /* Allocate skb for ARP packet */
    skb = arp_create(type, ptype, dest_ip, dev, src_ip,
                     dest_hw, src_hw, target_hw);

    /* ARP header structure: */
    arp = arp_hdr(skb);
    arp->ar_hrd = htons(ARPHRD_ETHER);    // hardware: Ethernet
    arp->ar_pro = htons(ETH_P_IP);        // protocol: IPv4
    arp->ar_hln = dev->addr_len;          // HW addr length: 6
    arp->ar_pln = 4;                      // protocol addr length: 4
    arp->ar_op  = htons(type);            // ARPOP_REQUEST or ARPOP_REPLY

    /* Fill in sender/target addresses */
    /* ARP request: broadcast dest MAC (ff:ff:ff:ff:ff:ff) */
    /* ARP reply:   unicast to requester's MAC */

    arp_xmit(skb);   // → dev_queue_xmit()
}
```

### Receiving an ARP reply
```c
/* net/ipv4/arp.c */
static int arp_rcv(struct sk_buff *skb, struct net_device *dev, ...)
{
    arp = arp_hdr(skb);

    if (arp->ar_op == htons(ARPOP_REPLY)) {
        /* Update neighbor cache with sender's MAC */
        n = __neigh_lookup(&arp_tbl, &sip, dev, 1);
        neigh_update(n, sha, NUD_REACHABLE,
                     NEIGH_UPDATE_F_OVERRIDE | NEIGH_UPDATE_F_WEAK_OVERRIDE, 0);
        /* Flush queued packets waiting for this resolution */
        /* neigh_update() calls neigh->output() for each queued skb */
    }

    if (arp->ar_op == htons(ARPOP_REQUEST)) {
        /* If we own the target IP, send ARP reply */
        if (inet_addr_onlink(in_dev, tip, sip))
            arp_send(ARPOP_REPLY, ETH_P_ARP, sip, dev, tip,
                     sha, dev->dev_addr, sha);
    }
}
```

---

## 5. Building the Ethernet Frame

**Source:** `net/ethernet/eth.c`

After neighbor resolution, `neigh->output()` builds the Ethernet header:

```c
/* For NUD_REACHABLE: neigh_connected_output() */
int neigh_connected_output(struct neighbour *neigh, struct sk_buff *skb)
{
    struct net_device *dev = neigh->dev;
    unsigned char *ha = neigh->ha;   // resolved MAC address

    /* Prepend Ethernet header */
    dev_hard_header(skb, dev, ntohs(skb->protocol), ha,
                    dev->dev_addr, skb->len);

    /* Hand to driver */
    return dev_queue_xmit(skb);
}

/* eth_header() in net/ethernet/eth.c */
int eth_header(struct sk_buff *skb, struct net_device *dev,
               unsigned short type, const void *daddr,
               const void *saddr, unsigned int len)
{
    struct ethhdr *eth = skb_push(skb, ETH_HLEN);  // push 14 bytes

    eth->h_proto = htons(type);   // ETH_P_IP = 0x0800
    /* Copy destination MAC (from ARP cache) */
    memcpy(eth->h_dest, daddr, ETH_ALEN);
    /* Copy source MAC (our NIC's MAC) */
    memcpy(eth->h_source, saddr ? saddr : dev->dev_addr, ETH_ALEN);

    return ETH_HLEN;
}
```

### Ethernet header structure
```c
struct ethhdr {
    unsigned char h_dest[ETH_ALEN];   // 6 bytes: destination MAC
    unsigned char h_source[ETH_ALEN]; // 6 bytes: source MAC
    __be16        h_proto;            // 2 bytes: ETH_P_IP, ETH_P_ARP, ...
};                                    // total: 14 bytes
```

---

## 6. Neighbor Table: `neigh_table`

```c
/* The ARP table for IPv4 */
struct neigh_table arp_tbl = {
    .family     = AF_INET,
    .key_len    = 4,            // IPv4 address = 4 bytes
    .protocol   = cpu_to_be16(ETH_P_IP),
    .hash       = arp_hash,
    .constructor = arp_constructor,
    .proxy_redo = parp_redo,
    .id         = "arp_cache",
    .parms      = {
        .base_reachable_time = 30 * HZ,  // NUD_REACHABLE lifetime
        .retrans_time        = 1 * HZ,   // ARP retry interval
        .gc_staletime        = 60 * HZ,  // GC stale entries after 60s
        .reachable_time      = 0,        // computed from base_reachable_time
        .delay_probe_time    = 5 * HZ,   // DELAY→PROBE delay
        .queue_len_bytes     = SK_WMEM_MAX,
        .ucast_probes        = 3,
        .mcast_probes        = 3,
    },
};
```

---

## 7. Hands-On

### 7a. Inspect the ARP cache
```bash
# Current ARP table
ip neigh show
# or: arp -n

# Watch ARP state transitions
watch -n1 'ip neigh show'

# Flush ARP cache (all entries go to FAILED/removed)
sudo ip neigh flush all
```

### 7b. Add a static ARP entry
```bash
# Add permanent ARP entry (NUD_PERMANENT, never expires)
sudo ip neigh add 192.168.1.100 lladdr aa:bb:cc:dd:ee:ff dev eth0

# Change to different MAC
sudo ip neigh change 192.168.1.100 lladdr 11:22:33:44:55:66 dev eth0

# Delete
sudo ip neigh del 192.168.1.100 dev eth0
```

### 7c. Capture ARP packets
```bash
# Listen for ARP (requires tcpdump)
sudo tcpdump -i eth0 -n arp 2>/dev/null &

# Generate an ARP request
sudo arping -c3 -I eth0 192.168.1.1 2>/dev/null || \
    ping -c1 192.168.1.200 2>/dev/null  # unknown IP → ARP request

kill %1 2>/dev/null
```

### 7d. ARP stats
```bash
cat /proc/net/arp          # ARP cache contents
cat /proc/net/stat/arp_cache 2>/dev/null

# Neighbor cache stats
ip -s neigh show
```

### 7e. Read kernel ARP source
```bash
grep -n "arp_rcv\|arp_send\|ARPOP_REQUEST\|ARPOP_REPLY" \
    ~/linux/net/ipv4/arp.c | head -20

grep -n "neigh_update\|NUD_REACHABLE\|neigh_connected_output" \
    ~/linux/net/core/neighbour.c | head -15
```

---

## 8. Concept Check

1. Why does Linux use the `NUD_STALE → NUD_DELAY → NUD_PROBE` sequence instead of immediately re-ARPing a stale entry?
2. What happens to packets queued in `neigh->arp_queue` while an ARP request is in flight? When are they released?
3. How is the Ethernet header prepended to an `sk_buff`? What `sk_buff` operation is used and why?
4. What is the difference between a `NUD_PERMANENT` entry and a normal `NUD_REACHABLE` entry? When would you add a permanent entry?

---

## 📚 References
- `net/ipv4/arp.c` — ARP send/receive
- `net/core/neighbour.c` — neighbor subsystem
- `net/ethernet/eth.c` — Ethernet frame building
- `include/net/neighbour.h` — `struct neighbour`, NUD states
- `net/ipv4/ip_output.c` — `ip_finish_output2` (neigh lookup)
- Kernel docs: `Documentation/networking/arp.rst` (if present)
