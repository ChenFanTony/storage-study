# Day 04 — IP Layer: Receive, Routing, and Transmit
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 1)

---

## 🎯 Goal
Follow a packet through the IP layer: `ip_rcv()` → routing decision → local delivery or forward, and the transmit path `ip_output()` → fragmentation → NIC.

---

## 1. IP Receive Path Overview

After `netif_receive_skb()`, the stack dispatches to protocol handlers registered via `dev_add_pack()`. For IPv4:

```
netif_receive_skb(skb)
  └── __netif_receive_skb_core()
        └── deliver_skb()
              └── ip_rcv()            ← net/ipv4/ip_input.c
                    └── NF_HOOK(PREROUTING)   ← netfilter hook
                          └── ip_rcv_finish()
                                └── ip_route_input_noref()  ← routing
                                      ├── local input → ip_local_deliver()
                                      └── forward     → ip_forward()
```

---

## 2. `ip_rcv()` — IP Header Validation

**Source:** `net/ipv4/ip_input.c`

```c
int ip_rcv(struct sk_buff *skb, struct net_device *dev,
           struct packet_type *pt, struct net_device *orig_dev)
{
    struct iphdr *iph;
    u32 len;

    /* Drop if not for us (promiscuous mode artifact) */
    if (skb->pkt_type == PACKET_OTHERHOST)
        goto drop;

    iph = ip_hdr(skb);

    /* Basic sanity: version must be 4, header length >= 20 bytes */
    if (iph->ihl < 5 || iph->version != 4)
        goto inhdr_error;

    /* Verify IP header checksum */
    if (unlikely(ip_fast_csum((u8 *)iph, iph->ihl)))
        goto csum_error;

    len = ntohs(iph->tot_len);
    if (skb->len < len || len < (iph->ihl * 4))
        goto too_short;

    /* Trim any padding added by Ethernet */
    if (pskb_trim_rcsum(skb, len))
        goto drop;

    /* Advance data pointer past IP header */
    skb->transport_header = skb->network_header + iph->ihl * 4;

    /* Pass through PREROUTING netfilter hooks (iptables -t nat PREROUTING) */
    return NF_HOOK(NFPROTO_IPV4, NF_INET_PRE_ROUTING,
                   net, NULL, skb, dev, NULL, ip_rcv_finish);
drop:
    kfree_skb(skb);
    return NET_RX_DROP;
}
```

---

## 3. Routing Decision

**Source:** `net/ipv4/route.c`

After validation, `ip_rcv_finish()` calls the routing subsystem:

```c
static int ip_rcv_finish(struct net *net, struct sock *sk, struct sk_buff *skb)
{
    const struct iphdr *iph = ip_hdr(skb);

    /* Routing lookup: fills skb->_skb_refdst */
    if (!skb_valid_dst(skb)) {
        int err = ip_route_input_noref(skb, iph->daddr, iph->saddr,
                                       iph->tos, skb->dev);
        if (unlikely(err))
            goto drop;
    }

    /* dst->input is set by routing:
       = ip_local_deliver  (packet is for us)
       = ip_forward        (packet needs to be forwarded)
       = ip_mr_input       (multicast)  */
    return dst_input(skb);   // calls skb->dst->input(skb)
}
```

### Routing table lookup
```bash
# See the main routing table
ip route show table main

# See all routing tables
ip route show table all

# Trace routing for a specific destination
ip route get 8.8.8.8
```

The kernel uses **FIB** (Forwarding Information Base) — a trie-based structure for fast longest-prefix match.

---

## 4. Local Delivery: `ip_local_deliver()`

When the destination is this machine:

```c
int ip_local_deliver(struct sk_buff *skb)
{
    /* Handle IP fragments: reassemble before delivery */
    if (ip_is_fragment(ip_hdr(skb))) {
        if (ip_defrag(net, skb, IP_DEFRAG_LOCAL_DELIVER))
            return 0;   // wait for more fragments
    }

    /* Pass through LOCAL_IN netfilter (iptables INPUT chain) */
    return NF_HOOK(NFPROTO_IPV4, NF_INET_LOCAL_IN,
                   net, NULL, skb, skb->dev, NULL,
                   ip_local_deliver_finish);
}

static int ip_local_deliver_finish(...)
{
    /* Dispatch to L4 protocol handler by IP protocol number */
    /* e.g., protocol=6 → tcp_v4_rcv, protocol=17 → udp_rcv */
    ipprot = rcu_dereference(inet_protos[protocol]);
    ret = ipprot->handler(skb);  // tcp_v4_rcv(skb) or udp_rcv(skb)
}
```

Protocol registration:
```c
// net/ipv4/af_inet.c
static const struct net_protocol tcp_protocol = {
    .handler    = tcp_v4_rcv,
    .err_handler = tcp_v4_err,
    .no_policy  = 1,
};
inet_add_protocol(&tcp_protocol, IPPROTO_TCP);
```

---

## 5. IP Transmit Path

```
tcp_write_xmit()
  └── ip_queue_xmit()           ← net/ipv4/ip_output.c
        ├── routing lookup (find nexthop, output device)
        └── ip_local_out()
              └── NF_HOOK(LOCAL_OUT)   ← iptables OUTPUT chain
                    └── ip_output()
                          └── NF_HOOK(POSTROUTING)  ← iptables POSTROUTING
                                └── ip_finish_output()
                                      ├── fragmentation if needed
                                      └── ip_finish_output2()
                                            └── neigh_output()  ← ARP lookup
                                                  └── dev_queue_xmit()
```

### `ip_queue_xmit()` key steps

```c
int ip_queue_xmit(struct sock *sk, struct sk_buff *skb, struct flowi *fl)
{
    struct inet_sock *inet = inet_sk(sk);
    struct rtable *rt;
    struct iphdr *iph;

    /* Use cached route if available */
    rt = skb_rtable(skb);
    if (!rt) {
        rt = ip_route_output_ports(net, fl4, sk, ...);
        skb_dst_set(skb, &rt->dst);
    }

    /* Build IP header */
    iph = ip_hdr(skb);
    iph->version  = 4;
    iph->ihl      = 5;      // 20 bytes, no options
    iph->tos      = inet->tos;
    iph->ttl      = inet->mc_ttl ?: net->ipv4.sysctl_ip_default_ttl;
    iph->protocol = sk->sk_protocol;   // IPPROTO_TCP
    iph->saddr    = fl4->saddr;
    iph->daddr    = fl4->daddr;
    iph->tot_len  = htons(skb->len);
    ip_select_ident(net, skb, sk);
    ip_send_check(iph);   // compute checksum

    return ip_local_out(net, sk, skb);
}
```

---

## 6. IP Fragmentation

When `skb->len > dev->mtu` (typically 1500 bytes):

```c
ip_finish_output()
  └── if (skb->len > ip_skb_dst_mtu(sk, skb))
        └── ip_fragment(net, sk, skb, mtu, ip_finish_output2)
              // splits skb into multiple fragments
              // each gets its own IP header with fragment offset
```

Key fields in IP header for fragmentation:
- `id` — same across all fragments of one datagram
- `frag_off` — byte offset / 8, plus MF (more fragments) bit
- Reassembly: `ip_defrag()` using hash table keyed on `(src, dst, id, proto)`

---

## 7. Hands-On

### 7a. Read `ip_rcv` and `ip_local_deliver`
```bash
grep -n "^int ip_rcv\|^int ip_local_deliver\|^static int ip_rcv_finish" \
    ~/linux/net/ipv4/ip_input.c
```

### 7b. Find all L4 protocol handlers
```bash
grep -n "inet_add_protocol" ~/linux/net/ipv4/af_inet.c
# See TCP, UDP, ICMP registration
```

### 7c. Watch IP statistics
```bash
# IP receive/transmit counters
cat /proc/net/snmp | grep -i "^Ip"

# More detailed IP stats
cat /proc/net/netstat | grep -i "^IpExt"

# Watch fragmentation
watch -n1 'cat /proc/net/snmp | grep Ip'
```

### 7d. Trace routing
```bash
# Where does traffic to 8.8.8.8 go?
ip route get 8.8.8.8

# TTL and path
traceroute 8.8.8.8

# MTU path discovery
ping -M do -s 1400 8.8.8.8   # DF bit set, size 1400
```

---

## 8. Concept Check

1. What is `NF_HOOK()` and at what points in the IP path does it appear? Why?
2. How does the kernel decide whether a packet is for local delivery vs. forwarding?
3. What is the `dst` (destination cache) entry in `sk_buff`, and why does it matter for performance?
4. At what layer does ARP come into play during IP transmit?

---

## 📚 References
- `net/ipv4/ip_input.c` — receive path
- `net/ipv4/ip_output.c` — transmit path
- `net/ipv4/route.c` — routing / FIB
- `net/ipv4/af_inet.c` — protocol registration
- Kernel docs: `Documentation/networking/ip-sysctl.rst`
