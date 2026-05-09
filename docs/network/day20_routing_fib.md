# Day 20 — Routing Internals: FIB, Policy Routing, and ECMP
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 3)

---

## 🎯 Goal
Understand how Linux makes routing decisions: the FIB trie structure, routing cache, policy routing tables, and ECMP (Equal-Cost Multi-Path) for load balancing.

---

## 1. Routing Decision Overview

```
ip_rcv_finish() or ip_queue_xmit()
  └── ip_route_input_noref()  or  ip_route_output_flow()
        └── fib_lookup(net, &fl4, &res, flags)
              └── fib_table_lookup(tb, &fl4, &res, fib_flags)
                    └── Longest-Prefix Match in FIB trie
                          → returns: nexthop IP, output device, scope
              └── __mkroute_input() or __mkroute_output()
                    → allocates struct rtable (route cache entry)
                    → stores in skb->_skb_refdst
```

---

## 2. FIB — Forwarding Information Base

**Source:** `net/ipv4/fib_trie.c`

The FIB stores all routing table entries. Linux uses a **Level-Compressed Trie (LC-Trie)** for O(1) amortized lookup.

```c
/* A FIB entry (route) */
struct fib_info {
    struct hlist_node   fib_hash;
    struct net          *fib_net;
    int                 fib_treeref;
    refcount_t          fib_clntref;

    unsigned int        fib_flags;
    unsigned char       fib_dead;
    unsigned char       fib_protocol;   // RTPROT_KERNEL, RTPROT_STATIC, RTPROT_BGP

    struct dst_metrics  *fib_metrics;
    int                 fib_nhs;         // number of nexthops (>1 for ECMP)
    bool                fib_nh_is_v6;

    struct fib_nh       fib_nh[0];       // array of nexthops
};

/* A single nexthop */
struct fib_nh {
    struct net_device   *fib_nh_dev;     // output interface
    __be32              fib_nh_gw4;      // gateway IP (0 = direct)
    unsigned char       fib_nh_scope;
    int                 fib_nh_weight;   // for ECMP weighted routing
    u32                 fib_nh_tclassid; // for traffic class
    /* ... */
};
```

### Trie structure
```c
/* fib_trie.c uses a Patricia/LC-Trie */
struct tnode {
    t_key           key;        // prefix bits
    unsigned char   bits;       // number of bits at this node
    unsigned char   pos;        // bit position
    struct tnode    *parent;
    unsigned long   child[0];   // array of 2^bits children
};

/* Leaf nodes hold the actual fib_alias (route) */
struct fib_alias {
    struct hlist_node   fa_list;
    struct fib_info     *fa_info;   // points to fib_info
    u8                  fa_tos;
    u8                  fa_type;    // RTN_UNICAST, RTN_BLACKHOLE, ...
    u8                  fa_state;
    u8                  fa_slen;    // prefix length
    u32                 fa_tb_id;   // table ID
};
```

---

## 3. Route Lookup: `fib_table_lookup()`

**Source:** `net/ipv4/fib_trie.c`

```c
int fib_table_lookup(struct fib_table *tb, const struct flowi4 *flp,
                     struct fib_result *res, int fib_flags)
{
    struct trie *t = (struct trie *)tb->tb_data;
    const t_key key = ntohl(flp->daddr);  // destination IP as key
    struct tnode *n;
    unsigned long index;

    /* Walk trie from root */
    n = get_root(t);
    while (IS_TNODE(n)) {
        /* Extract `bits` bits at position `pos` from key */
        index = (key >> n->pos) & ((1UL << n->bits) - 1);
        n = tnode_get_child_rcu(n, index);
        if (!n) goto failed;
    }

    /* Found leaf: check all aliases (multiple routes, different TOS/metrics) */
    hlist_for_each_entry_rcu(fa, &n->leaf, fa_list) {
        if (/* prefix match AND TOS match AND scope */) {
            res->prefix = htonl(n->key);
            res->prefixlen = KEYLENGTH - fa->fa_slen;
            res->fi = fa->fa_info;
            res->type = fa->fa_type;
            return 0;
        }
    }
failed:
    return -EAGAIN;
}
```

---

## 4. Multiple Routing Tables: Policy Routing

**Source:** `net/ipv4/fib_rules.c`

Linux supports **multiple routing tables** (default: `main`, `local`, `default`). Policy routing selects which table to use based on rules.

```bash
# List routing policy rules
ip rule list
# Output:
# 0:    from all lookup local       ← table 255 (local: lo, broadcast)
# 32766: from all lookup main       ← table 254 (main: your routes)
# 32767: from all lookup default    ← table 253 (empty by default)
```

### Adding policy rules
```bash
# Route traffic from 10.0.0.0/8 via a different table
ip rule add from 10.0.0.0/8 table 100 priority 100

# Route marked packets (from iptables -j MARK) via table 200
ip rule add fwmark 0x1 table 200

# Route traffic to specific destinations via a gateway
ip route add default via 192.168.2.1 table 100
```

### Kernel rule lookup
```c
/* net/ipv4/fib_rules.c */
int fib_lookup(struct net *net, struct flowi4 *flp,
               struct fib_result *res, unsigned int flags)
{
    struct fib_rules_ops *ops = net->ipv4.rules_ops;

    /* Walk policy rules in priority order */
    list_for_each_entry_rcu(rule, ops->rules_list, list) {
        /* Match: source IP, fwmark, iif, tos */
        if (fib4_rule_match(rule, flp, flags)) {
            /* Look up in the table specified by this rule */
            err = fib_table_lookup(fib_get_table(net, rule->table),
                                   flp, res, flags);
            if (err == 0) return 0;   /* found */
        }
    }
    return -ENETUNREACH;
}
```

---

## 5. ECMP — Equal-Cost Multi-Path Routing

ECMP allows multiple nexthops for one destination — the kernel load-balances across them.

```bash
# Add ECMP route with two nexthops
ip route add 10.0.0.0/8 \
    nexthop via 192.168.1.1 dev eth0 weight 1 \
    nexthop via 192.168.2.1 dev eth1 weight 1

# Weighted ECMP (3:1 ratio)
ip route add default \
    nexthop via 10.0.0.1 weight 3 \
    nexthop via 10.0.0.2 weight 1
```

### Kernel ECMP implementation
```c
/* net/ipv4/fib_semantics.c */
/* fib_info has fib_nhs > 1 for ECMP */

struct fib_nh *fib_select_multipath(const struct fib_result *res, int hash)
{
    struct fib_info *fi = res->fi;
    int total = 0;
    int w;

    /* Hash based on flow (src_ip, dst_ip, ports) for consistency */
    /* Same flow always picks same nexthop → connection coherence */

    for (int n = 0; n < fi->fib_nhs; n++) {
        struct fib_nh *nh = &fi->fib_nh[n];
        if (nh->fib_nh_flags & RTNH_F_DEAD)
            continue;
        total += nh->fib_nh_weight;
        if ((hash % total) < nh->fib_nh_weight)
            return nh;
    }
    return &fi->fib_nh[0];
}
```

**Flow hash for ECMP:**
```c
/* Same 4-tuple always picks the same nexthop */
hash = fib_multipath_hash(net, flp, skb, NULL);
/* → ensures TCP flows don't get reordered by switching paths mid-connection */
```

---

## 6. Route Cache: `struct rtable`

**Source:** `include/net/route.h`

```c
struct rtable {
    struct dst_entry    dst;    /* MUST be first */

    int                 rt_genid;
    unsigned int        rt_flags;
    __u16               rt_type;    // RTN_UNICAST, RTN_LOCAL, RTN_BROADCAST
    __u8                rt_is_input;

    __be32              rt_gateway;    // nexthop IP
    __be32              rt_dst;        // destination (for dst_entry)
    __be32              rt_src;        // source IP used

    struct list_head    rt_uncached;
};

struct dst_entry {
    struct net_device   *dev;           // output interface
    int (*input)(struct sk_buff *);     // ip_local_deliver or ip_forward
    int (*output)(struct net *net, struct sock *sk, struct sk_buff *skb);
    struct dst_ops      *ops;
    unsigned long       expires;
    /* metrics: RTT, cwnd_clamp, mtu... */
};
```

The `dst_entry` is stored in `skb->_skb_refdst` and used throughout the TX path:
```c
dst_input(skb)   → skb->dst->input(skb)   // ip_local_deliver() or ip_forward()
dst_output(skb)  → skb->dst->output(skb)  // ip_output()
```

---

## 7. Hands-On

### 7a. Explore routing tables
```bash
# Main routing table
ip route show table main

# Local table (loopback, broadcast)
ip route show table local

# Show all rules
ip rule list

# Get route for a specific destination (shows which nexthop chosen)
ip route get 8.8.8.8
ip route get 8.8.8.8 from 192.168.1.1  # with source IP
```

### 7b. FIB statistics
```bash
# Route cache stats
cat /proc/net/stat/rt_cache 2>/dev/null

# FIB trie stats
cat /proc/net/fib_triestat
# Shows: total leaves, internal nodes, trie depth
```

### 7c. Policy routing example
```bash
# Create a second routing table
echo "100 custom" | sudo tee -a /etc/iproute2/rt_tables 2>/dev/null

# Add a rule: traffic to 10.x.x.x uses table 100
sudo ip rule add to 10.0.0.0/8 table 100 priority 100 2>/dev/null

# Add default route in table 100
sudo ip route add default via $(ip route | grep default | awk '{print $3}') \
    table 100 2>/dev/null

# Test
ip route get 10.1.2.3
ip route get 8.8.8.8  # different table

# Clean up
sudo ip rule del to 10.0.0.0/8 table 100 2>/dev/null
```

### 7d. Read FIB trie lookup
```bash
grep -n "fib_table_lookup\|fib_lookup\|fib_select_multipath" \
    ~/linux/net/ipv4/fib_trie.c | head -15

grep -n "fib_nhs\|fib_select_multipath" \
    ~/linux/net/ipv4/fib_semantics.c | head -10
```

---

## 8. Concept Check

1. Why does Linux use an LC-Trie instead of a simple hash table for FIB lookups? What advantage does the trie give for IP routing specifically?
2. In policy routing, what fields of a packet can be matched by a rule? Why might you route based on source IP rather than destination?
3. How does ECMP ensure that packets of the same TCP flow always use the same nexthop? Why is this important?
4. What is `struct dst_entry` and why is it embedded in `struct rtable`? What does storing it in `skb->_skb_refdst` enable?

---

## 📚 References
- `net/ipv4/fib_trie.c` — FIB trie lookup
- `net/ipv4/fib_semantics.c` — `fib_info`, ECMP nexthop selection
- `net/ipv4/fib_rules.c` — policy routing
- `net/ipv4/route.c` — `rtable` allocation, route lookup entry points
- `include/net/route.h` — `struct rtable`, `struct dst_entry`
- Kernel docs: `Documentation/networking/policy-routing.rst` (historical)
- `ip-rule(8)`, `ip-route(8)` man pages
