# Day 07 — Netfilter, iptables Hooks, and Week 1 Review
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 1)

---

## 🎯 Goal
Understand how Netfilter hooks intercept packets at strategic points in the stack, how iptables builds on these hooks, and consolidate the full Week 1 picture.

---

## 1. Netfilter Hook Points

**Source:** `include/linux/netfilter_ipv4.h`, `net/netfilter/`

Netfilter defines **5 hook points** in the IPv4 stack where packet processing can be intercepted:

```
                  ┌─────────────────────────────────────────┐
                  │           Linux Kernel                   │
  incoming        │                                          │
  packet    ──────►  PREROUTING ──► routing ──► FORWARD ───► POSTROUTING ──► wire
                  │      │           decision      │               │
                  │      │                         │               │
                  │      └──────────► INPUT        │               │
                  │                     │          │               │
                  │                  local process │               │
                  │                     │          │               │
                  │                  OUTPUT ───────┘               │
                  │                     └─────────────────────────►│
                  └─────────────────────────────────────────┘
```

| Hook | `NF_INET_*` constant | When it fires |
|---|---|---|
| PREROUTING | `NF_INET_PRE_ROUTING` | Before routing, all incoming packets |
| INPUT | `NF_INET_LOCAL_IN` | After routing, destined for local process |
| FORWARD | `NF_INET_FORWARD` | After routing, being forwarded |
| OUTPUT | `NF_INET_LOCAL_OUT` | Outgoing from local process, before routing |
| POSTROUTING | `NF_INET_POST_ROUTING` | After routing, all outgoing packets |

---

## 2. The `NF_HOOK()` Macro

Every hook point in the IP code looks like:

```c
/* From ip_input.c */
return NF_HOOK(NFPROTO_IPV4, NF_INET_PRE_ROUTING,
               net, NULL, skb, dev, NULL,
               ip_rcv_finish);
```

Expanded behavior:
```c
// If no registered hooks: call ip_rcv_finish(skb) directly
// If hooks registered: run each hook function in priority order
//   Each hook returns one of:
//     NF_ACCEPT  → continue to next hook / okfn
//     NF_DROP    → drop the packet (kfree_skb)
//     NF_STOLEN  → hook took ownership (don't touch skb)
//     NF_QUEUE   → queue for userspace (nfqueue)
//     NF_REPEAT  → re-run this hook
```

### Registering a hook
```c
static struct nf_hook_ops my_hook = {
    .hook     = my_hook_fn,      // the actual function
    .pf       = NFPROTO_IPV4,
    .hooknum  = NF_INET_PRE_ROUTING,
    .priority = NF_IP_PRI_FIRST, // hooks run in priority order
};
nf_register_net_hook(net, &my_hook);
```

### Hook function signature
```c
unsigned int my_hook_fn(void *priv,
                         struct sk_buff *skb,
                         const struct nf_hook_state *state)
{
    struct iphdr *iph = ip_hdr(skb);
    
    // Example: drop all ICMP
    if (iph->protocol == IPPROTO_ICMP)
        return NF_DROP;
    
    return NF_ACCEPT;
}
```

---

## 3. iptables Layered on Netfilter

iptables is a **userspace-controlled** set of Netfilter hooks. It maps **tables** to hook points:

| Table | Hook points used | Purpose |
|---|---|---|
| `raw` | PREROUTING, OUTPUT | Before connection tracking |
| `mangle` | All 5 hooks | Modify packet headers |
| `nat` | PREROUTING, OUTPUT, POSTROUTING | Address translation |
| `filter` | INPUT, FORWARD, OUTPUT | Packet filtering (main table) |

### Inside the kernel: `xt_table`
```c
// Each table registers at specific hooks with specific priority
// net/ipv4/netfilter/iptable_filter.c

static const struct xt_table packet_filter = {
    .name       = "filter",
    .valid_hooks = (1 << NF_INET_LOCAL_IN) |
                   (1 << NF_INET_FORWARD)  |
                   (1 << NF_INET_LOCAL_OUT),
    .me         = THIS_MODULE,
    .af         = NFPROTO_IPV4,
    .priority   = NF_IP_PRI_FILTER,
};
```

### Rule traversal
```c
ipt_do_table(skb, state, state->net->ipv4.iptable_filter)
  └── for each rule in chain:
        if ip_packet_match(skb, rule->ip):  // match IP header fields
          for each match module: match->match(skb, ...)  // -m tcp, -m state
          if all match:
            target->target(skb, ...)        // ACCEPT/DROP/RETURN/DNAT/...
```

---

## 4. Connection Tracking (`conntrack`)

**Source:** `net/netfilter/nf_conntrack_core.c`

Connection tracking sits at PREROUTING and OUTPUT, before the filter table. It maintains a table of all active connections.

```c
struct nf_conn {
    struct nf_conntrack_tuple_hash tuplehash[IP_CT_DIR_MAX];
    // tuplehash[ORIGINAL]: src→dst direction
    // tuplehash[REPLY]:    dst→src direction

    enum ip_conntrack_status status;  // IPS_ESTABLISHED, IPS_NAT_*, ...
    struct nf_ct_ext *ext;            // extensions: NAT, timeout, labels
    u32  timeout;
};
```

States visible to iptables `-m state`:
- `NEW` — first packet of a connection
- `ESTABLISHED` — part of known connection
- `RELATED` — related to existing (e.g., FTP data conn)
- `INVALID` — doesn't match any known connection

```bash
# View connection tracking table
conntrack -L 2>/dev/null | head -20
# or
cat /proc/net/nf_conntrack | head -10
```

---

## 5. NAT Implementation

**Source:** `net/netfilter/nf_nat_core.c`

DNAT (destination NAT) at PREROUTING:
```c
// Rule: -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to 192.168.1.10:8080
// Kernel stores NAT mapping in nf_conn->ext (NAT extension)
// Reply packets automatically get reverse translation (conntrack handles this)
```

MASQUERADE (source NAT) at POSTROUTING:
```c
// Rule: -t nat -A POSTROUTING -o eth0 -j MASQUERADE
// Rewrites src IP to the outgoing interface's IP
// conntrack tracks the mapping for reply packets
```

---

## 6. Hands-On

### 6a. Explore netfilter source
```bash
ls ~/linux/net/netfilter/ | head -20
grep -rn "NF_HOOK\|nf_hook" ~/linux/net/ipv4/ip_input.c
grep -rn "nf_register_net_hook" ~/linux/net/netfilter/ | head -10
```

### 6b. Inspect live iptables rules
```bash
# List all rules with line numbers
iptables -L -v -n --line-numbers 2>/dev/null

# List NAT table
iptables -t nat -L -v -n 2>/dev/null

# List raw table (conntrack bypass)
iptables -t raw -L -v -n 2>/dev/null
```

### 6c. Observe conntrack
```bash
# Connection tracking stats
cat /proc/net/stat/nf_conntrack 2>/dev/null

# Max connections tracked
cat /proc/sys/net/netfilter/nf_conntrack_max

# Current count
cat /proc/sys/net/netfilter/nf_conntrack_count
```

### 6d. Add a test rule and observe (safe, restores itself)
```bash
# Count packets to port 80
iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null
# Generate some traffic (curl http://localhost 2>/dev/null || true)
# Check counter
iptables -L INPUT -v -n 2>/dev/null
# Clean up
iptables -D INPUT 1 2>/dev/null
```

---

## 7. 🗺️ Week 1 Full Stack Review

```
USER SPACE
  send()/recv()
      │
──────┼──────────────────────────────────────────
KERNEL SPACE
      │
  [socket layer]     struct socket, struct sock
  tcp_sendmsg()      sk_write_queue, sk_receive_queue
  tcp_recvmsg()      sk_data_ready() wakeup
      │
  [TCP layer]        struct tcp_sock
  tcp_write_xmit()   cwnd, ssthresh, retransmit timer
  tcp_rcv_established() fast path, out-of-order queue
      │
  [IP layer]         struct iphdr, routing (FIB)
  ip_queue_xmit()    fragmentation, ttl, checksum
  ip_rcv()           validation, NF_HOOK points
      │
  [Netfilter]        NF_INET_* hooks, iptables tables
  nf_hook_slow()     conntrack, NAT, filter
      │
  [Device layer]     struct net_device, dev_queue_xmit()
  netif_receive_skb() → ip_rcv()
      │
  [NAPI / Driver]    ring buffer, sk_buff allocation
  napi_poll()        e1000_clean_rx_irq()
      │
  [NIC HW]           DMA, interrupt
      │
──────┼────────────────── wire ───────────────────
```

### The one structure to rule them all: `sk_buff`
```
head → [headroom][ETH HDR][IP HDR][TCP HDR][DATA][tailroom] ← end
                     ↑mac    ↑network  ↑transport  ↑data
```
Every layer pushes/pulls headers into this single buffer. No copies between layers.

---

## 8. Week 1 Final Concept Check

1. Draw the packet receive path from NIC interrupt to `recv()` returning to userspace. Include function names at each step.
2. Where exactly does Netfilter intercept packets in the transmit path? What tables apply?
3. What is the relationship between `struct sock`, `struct inet_sock`, and `struct tcp_sock`?
4. Why does NAPI outperform pure interrupt-driven packet reception at high packet rates?
5. At what point in the stack is the destination socket identified for an incoming TCP segment?

---

## 📚 Week 1 Key Files Summary

| Day | Key Source Files |
|---|---|
| 1 | `include/linux/skbuff.h`, `net/core/dev.c` |
| 2 | `include/net/sock.h`, `net/socket.c`, `net/ipv4/af_inet.c` |
| 3 | `drivers/net/ethernet/intel/e1000/e1000_main.c`, `net/core/dev.c` |
| 4 | `net/ipv4/ip_input.c`, `net/ipv4/ip_output.c`, `net/ipv4/route.c` |
| 5 | `net/ipv4/tcp_ipv4.c`, `net/ipv4/tcp_input.c`, `net/ipv4/tcp.c` |
| 6 | `net/ipv4/tcp_output.c`, `net/ipv4/tcp_cubic.c` |
| 7 | `net/netfilter/nf_conntrack_core.c`, `net/ipv4/netfilter/` |

---

## Week 2 Preview

Next week we go **deeper**:
- Day 08: Socket buffers and memory pressure
- Day 09: TCP flow control and zero-window probes
- Day 10: `epoll` and the event notification system
- Day 11: UDP and raw sockets
- Day 12: Network namespaces and `veth` pairs
- Day 13: `tc` (traffic control) and the qdisc layer
- Day 14: Mid-point review + eBPF/XDP introduction
