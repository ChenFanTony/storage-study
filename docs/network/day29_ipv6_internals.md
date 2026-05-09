# Day 29 — IPv6 Internals: Stack Differences, NDP, and `struct ipv6_pinfo`
> **Time:** 1–2 hours | **Track:** Linux Networking (Day 29/30)

---

## 🎯 Goal
Understand how IPv6 is implemented in the Linux kernel — where it mirrors IPv4, where it fundamentally differs, and how NDP replaces ARP for neighbor discovery.

---

## 1. IPv6 vs IPv4: Kernel Architecture Comparison

```
IPv4                            IPv6
──────────────────────          ──────────────────────────
net/ipv4/ip_input.c             net/ipv6/ip6_input.c
net/ipv4/ip_output.c            net/ipv6/ip6_output.c
net/ipv4/tcp_ipv4.c             net/ipv6/tcp_ipv6.c
net/ipv4/udp.c                  net/ipv6/udp.c
net/ipv4/arp.c                  net/ipv6/ndisc.c      ← NDP replaces ARP
net/ipv4/route.c                net/ipv6/route.c
net/ipv4/fib_trie.c             net/ipv6/ip6_fib.c    ← different trie
include/linux/ip.h              include/linux/ipv6.h
```

Both stacks live under the same socket and TCP layers — only the L3 implementation differs.

---

## 2. IPv6 Header

**Source:** `include/linux/ipv6.h`

```c
struct ipv6hdr {
    __u8        priority:4,    // traffic class (high nibble)
                version:4;     // must be 6
    __u8        flow_lbl[3];   // flow label (20 bits)
    __be16      payload_len;   // length of payload (NOT including header)
    __u8        nexthdr;       // next header: 6=TCP, 17=UDP, 58=ICMPv6, 43=routing...
    __u8        hop_limit;     // TTL equivalent
    struct in6_addr saddr;     // 128-bit source address
    struct in6_addr daddr;     // 128-bit destination address
};                             // fixed size: 40 bytes (no options field!)
```

### Key differences from IPv4 header
```
IPv4: variable length (20–60 bytes), has Options field, has checksum
IPv6: fixed 40 bytes, no checksum (L4 checksums cover pseudo-header),
      extensions via chained "Next Header" instead of options

IPv4 fragmentation: routers can fragment
IPv6 fragmentation: ONLY the source host (routers drop oversized → ICMPv6 Too Big)

IPv4 broadcast: yes
IPv6 broadcast: NO — replaced by multicast (ff02::1 = all nodes)
```

### Extension headers (chained via nexthdr)
```
40-byte base header
  → nexthdr=43: Routing Header (source routing)
        → nexthdr=60: Destination Options
              → nexthdr=6:  TCP payload

Kernel processes each extension header in ip6_rcv_finish():
  ip6_parse_exthdrs() walks the chain
```

---

## 3. `struct ipv6_pinfo` — IPv6 Socket State

**Source:** `include/net/ipv6.h`

IPv6-specific socket state is stored in `ipv6_pinfo`, embedded in protocol-specific structs:

```c
struct ipv6_pinfo {
    struct in6_addr saddr;          // source address (bound)
    struct in6_addr sticky_dst;     // cached destination

    /* Traffic class and flow label */
    __u8        tclass;             // DSCP/ECN
    __u8        min_hopcount;
    __u8        hop_limit;
    __u8        mcast_hops;
    __be32      flow_label;

    /* Multicast */
    struct ipv6_mc_socklist __rcu *ipv6_mc_list;
    struct ipv6_ac_socklist *ipv6_ac_list;
    struct ipv6_fl_socklist __rcu *ipv6_fl_list; // flow labels

    /* Options */
    struct ipv6_txoptions __rcu *opt;  // sticky options (routing hdr, etc.)
    struct sk_buff          *pktoptions;

    /* Flags */
    __u16       recverr:1,
                sndflow:1,
                repflow:1,
                pmtudisc:3,
                padding:2,
                srcprefs:3,
                dontfrag:1,
                autoflowlabel:1,
                autoflowlabel_set:1;
};
```

### Embedding in TCP/UDP sockets
```c
/* TCP over IPv6: */
struct tcp6_sock {
    struct tcp_sock  tcp;         // full TCP state
    struct ipv6_pinfo inet6;      // IPv6-specific state
    /* cast: tcp_inet6_sk(sk) → &tcp6_sock->inet6 */
};

/* UDP over IPv6: */
struct udp6_sock {
    struct udp_sock  udp;
    struct ipv6_pinfo inet6;
};

/* Access pattern: */
struct ipv6_pinfo *np = inet6_sk(sk);  // macro: gets &xxx6_sock->inet6
```

---

## 4. IPv6 Receive Path

**Source:** `net/ipv6/ip6_input.c`

```c
/* Registered as ETH_P_IPV6 handler in net/ipv6/af_inet6.c */
int ipv6_rcv(struct sk_buff *skb, struct net_device *dev,
             struct packet_type *pt, struct net_device *orig_dev)
{
    const struct ipv6hdr *hdr;
    u32 pkt_len;

    hdr = ipv6_hdr(skb);

    /* Version check */
    if (hdr->version != 6)
        goto err;

    /* Payload length check */
    pkt_len = ntohs(hdr->payload_len);
    if (pkt_len + sizeof(*hdr) > skb->len)
        goto drop;

    /* Unlike IPv4: no header checksum to verify */
    /* Unlike IPv4: no options to parse here (extension headers later) */

    /* Trim padding */
    if (pskb_trim_rcsum(skb, pkt_len + sizeof(*hdr)))
        goto drop;

    /* Set transport header pointer past IPv6 base header */
    skb->transport_header = skb->network_header + sizeof(*hdr);

    return NF_HOOK(NFPROTO_IPV6, NF_INET_PRE_ROUTING,
                   net, NULL, skb, dev, NULL, ip6_rcv_finish);
}

static int ip6_rcv_finish(struct net *net, struct sock *sk,
                           struct sk_buff *skb)
{
    /* Routing lookup */
    ip6_route_input(skb);   /* fills skb->_skb_refdst */

    return dst_input(skb);
    /* → ip6_input() for local delivery */
    /* → ip6_forward() for forwarding */
}
```

### Extension header processing
```c
/* net/ipv6/ip6_input.c - ip6_input_finish() */
static int ip6_input_finish(struct net *net, struct sock *sk,
                             struct sk_buff *skb)
{
    const struct ipv6hdr *hdr = ipv6_hdr(skb);
    u8 nexthdr = hdr->nexthdr;
    int nhoff = sizeof(*hdr);

    /* Walk extension header chain */
    /* Each extension header handler advances nhoff and updates nexthdr */
    /* Until we reach a non-extension nexthdr (TCP=6, UDP=17, etc.) */

    ipprot = rcu_dereference(inet6_protos[nexthdr]);
    if (ipprot)
        ret = ipprot->handler(skb);   /* tcp_v6_rcv() or udpv6_rcv() */
}
```

---

## 5. TCP over IPv6: `tcp_v6_rcv()`

**Source:** `net/ipv6/tcp_ipv6.c`

```c
INDIRECT_CALLABLE_SCOPE int tcp_v6_rcv(struct sk_buff *skb)
{
    const struct tcphdr *th;
    const struct ipv6hdr *hdr;
    struct sock *sk;

    hdr = ipv6_hdr(skb);
    th  = tcp_hdr(skb);

    /* 4-tuple lookup using IPv6 addresses */
    sk = __inet6_lookup_skb(&tcp_hashinfo, skb, __tcp_hdrlen(th),
                             th->source, th->dest,
                             inet6_iif(skb), sdif, &refcounted);
    if (!sk)
        goto no_tcp_socket;

    /* From here: identical to IPv4 — same tcp_rcv_established() */
    if (sk->sk_state == TCP_ESTABLISHED)
        return tcp_rcv_established(sk, skb);

    return tcp_v6_do_rcv(sk, skb);
}
```

**Key point:** Above the IPv6 header, TCP is identical. `tcp_rcv_established()`, congestion control, flow control, retransmit timers — all shared with IPv4.

---

## 6. NDP — Neighbor Discovery Protocol (replaces ARP)

**Source:** `net/ipv6/ndisc.c`

NDP uses ICMPv6 (nexthdr=58) instead of a separate EtherType like ARP. It's more powerful:

| ARP (IPv4) | NDP (IPv6) |
|---|---|
| ARP Request (broadcast) | Neighbor Solicitation (multicast) |
| ARP Reply (unicast) | Neighbor Advertisement (unicast) |
| Gratuitous ARP | Unsolicited Neighbor Advertisement |
| — | Router Solicitation (find default router) |
| — | Router Advertisement (router announces prefix) |
| — | Redirect |

### Solicited-node multicast address
Instead of broadcasting, NDP sends to a **solicited-node multicast** address derived from the target IP:

```
Target: 2001:db8::1234:5678
Solicited-node: ff02::1:ff34:5678  (last 24 bits of target)
```

Only the host with that specific suffix listens — dramatically reduces interrupt rate vs ARP broadcast.

### Neighbor Solicitation / Advertisement
```c
/* net/ipv6/ndisc.c */
void ndisc_send_ns(struct net_device *dev,
                   const struct in6_addr *solicit,  /* target IP */
                   const struct in6_addr *daddr,    /* solicited-node mcast */
                   const struct in6_addr *saddr,
                   u64 nonce)
{
    /* Build ICMPv6 Neighbor Solicitation message */
    /* Type=135 (NS), Target address, Source link-layer option */
    /* Send to solicited-node multicast address */
    icmpv6_send_skb(skb);
}

/* When NA received: */
static void ndisc_recv_na(struct sk_buff *skb)
{
    struct neighbour *neigh;
    /* Update neighbor cache — same struct neighbour as IPv4! */
    neigh = neigh_lookup(&nd_tbl, &msg->target, dev);
    neigh_update(neigh, lladdr, NUD_REACHABLE, ...);
}
```

### Same neighbor subsystem
```c
/* IPv6 uses the same struct neighbour and NUD state machine as IPv4 */
/* Just with a different neigh_table: */
struct neigh_table nd_tbl = {  /* vs arp_tbl for IPv4 */
    .family     = AF_INET6,
    .key_len    = sizeof(struct in6_addr),  /* 16 bytes vs 4 */
    .protocol   = cpu_to_be16(ETH_P_IPV6),
    .constructor = ndisc_constructor,
    .id         = "ndisc_cache",
    /* same NUD state machine, same timers */
};
```

---

## 7. IPv6 Routing

**Source:** `net/ipv6/route.c`, `net/ipv6/ip6_fib.c`

IPv6 uses a **radix tree** (not LC-Trie like IPv4) for the FIB, keyed on 128-bit prefixes:

```c
struct fib6_node {
    struct fib6_node    *parent;
    struct fib6_node    *left;
    struct fib6_node    *right;
    struct fib6_info    *leaf;   /* route(s) at this node */
    __u16               fn_bit;  /* bit position for branching */
    __u16               fn_flags;
};

struct fib6_info {
    struct fib6_table   *fib6_table;
    struct fib6_info    *fib6_next;     /* next route (same prefix) */
    struct rt6key       fib6_dst;      /* destination prefix */
    struct rt6key       fib6_src;      /* source prefix (policy routing) */
    struct fib6_nh      *fib6_nh;      /* nexthop(s) */
    u32                 fib6_metric;
    u8                  fib6_protocol; /* RTPROT_STATIC, RTPROT_RA, ... */
};
```

```bash
# IPv6 routing table
ip -6 route show

# Get specific route
ip -6 route get 2001:db8::1

# IPv6 neighbor cache (NDP cache)
ip -6 neigh show

# IPv6 socket stats
ss -6 -tin state established
cat /proc/net/tcp6
cat /proc/net/udp6
```

---

## 8. PMTU Discovery (IPv6 Mandatory)

In IPv6, **only the source** can fragment. If a packet is too large, routers send back ICMPv6 "Packet Too Big":

```c
/* net/ipv6/icmp.c */
/* Router sends: ICMPv6 type=2 (Packet Too Big), MTU field = router's link MTU */

/* Kernel handles incoming PTB: */
void icmpv6_rcv(struct sk_buff *skb)
{
    if (type == ICMPV6_PKT_TOOBIG) {
        /* Update PMTU for this destination */
        mtu = ntohl(icmp6h->icmp6_mtu);
        ip6_update_pmtu(skb, net, htonl(mtu), ifindex, mark, uid);
        /* → updates dst_entry metrics → future packets use smaller MTU */
    }
}
```

```bash
# Path MTU to a destination
ip -6 route get 2001:4860:4860::8888 | grep mtu
tracepath6 2001:4860:4860::8888  # discovers MTU at each hop
```

---

## 9. Hands-On

### 9a. Check IPv6 interface addresses
```bash
ip -6 addr show
# Link-local: fe80::/10 (auto-configured, always present)
# Global: 2xxx::/3 (assigned by SLAAC or DHCPv6)

# See all IPv6 socket stats
cat /proc/net/snmp6 | column -t | head -30
```

### 9b. Observe NDP in action
```bash
# NDP cache (equivalent of ARP cache)
ip -6 neigh show

# Flush and watch repopulation
sudo ip -6 neigh flush all
ping6 -c3 fe80::1%eth0 2>/dev/null || ping6 -c3 ::1
ip -6 neigh show

# Capture NDP packets (ICMPv6 type 135=NS, 136=NA)
sudo tcpdump -i eth0 -n 'icmp6 and (ip6[40]=135 or ip6[40]=136)' \
    2>/dev/null &
ping6 -c3 ::1 2>/dev/null
kill %1 2>/dev/null
```

### 9c. IPv6 receive path in source
```bash
grep -n "^int ipv6_rcv\|^static int ip6_rcv_finish\|^static int ip6_input" \
    ~/linux/net/ipv6/ip6_input.c | head -10

grep -n "tcp_v6_rcv\|tcp_v6_do_rcv" \
    ~/linux/net/ipv6/tcp_ipv6.c | head -10

grep -n "ndisc_send_ns\|ndisc_recv_na\|nd_tbl" \
    ~/linux/net/ipv6/ndisc.c | head -15
```

### 9d. IPv6 stats
```bash
# ICMPv6 stats (includes NDP)
cat /proc/net/snmp6 | grep -i "icmp6\|neigh" | head -20

# IPv6 counters
cat /proc/net/snmp6 | grep "^Ip6" | head -15
```

---

## 10. Concept Check

1. IPv6 has no header checksum. How does this affect TCP/UDP checksum computation for IPv6? (Hint: pseudo-header)
2. Why does NDP use solicited-node multicast instead of broadcast? What is the performance benefit at scale?
3. An IPv6 packet arrives at a router that needs to forward it but finds the MTU of the outgoing link is too small. What does the router do? What does the source host do when it receives the response?
4. `struct tcp_sock` is the same for both IPv4 and IPv6 connections. Where exactly is the IPv6-specific state stored, and how does the kernel access it from a `struct sock *`?

---

## 📚 References
- `net/ipv6/ip6_input.c` — IPv6 receive path
- `net/ipv6/ip6_output.c` — IPv6 transmit path
- `net/ipv6/tcp_ipv6.c` — TCP over IPv6
- `net/ipv6/ndisc.c` — NDP (Neighbor Discovery)
- `net/ipv6/route.c` — IPv6 routing
- `net/ipv6/ip6_fib.c` — IPv6 FIB radix tree
- `include/linux/ipv6.h` — `struct ipv6hdr`
- `include/net/ipv6.h` — `struct ipv6_pinfo`
- RFC 4861 — Neighbor Discovery for IPv6
- RFC 8200 — IPv6 specification
