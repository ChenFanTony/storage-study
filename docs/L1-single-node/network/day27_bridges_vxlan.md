# Day 27 — Bridges, VXLAN, and Overlay Networks
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 4)

---

## 🎯 Goal
Understand how the Linux bridge works at the kernel level, how VXLAN tunnels extend L2 networks over L3 infrastructure, and how these primitives underpin container and cloud networking.

---

## 1. Linux Bridge Internals

**Source:** `net/bridge/`

A Linux bridge is a software L2 switch: it learns MAC addresses and forwards frames between attached interfaces.

```
┌─────────────────────────────────────┐
│           Linux Bridge (br0)        │
│  ┌──────────────────────────────┐   │
│  │    FDB (Forwarding DB)       │   │
│  │  MAC → port (learned)        │   │
│  └──────────────────────────────┘   │
│                                     │
│  port: eth0    port: veth0   port: veth1
│    │               │              │
│  physical NIC  container1     container2
└─────────────────────────────────────┘
```

### `net_bridge` structure
```c
/* net/bridge/br_private.h */
struct net_bridge {
    spinlock_t          lock;
    spinlock_t          hash_lock;

    struct net_device   *dev;   // the bridge net_device itself

    /* Port list */
    struct list_head    port_list;

    /* Forwarding Database (MAC → port) */
    struct hlist_head   hash[BR_HASH_SIZE];  // hash table by MAC

    /* STP (Spanning Tree Protocol) state */
    bridge_id           designated_root;
    u32                 root_path_cost;
    u8                  root_port;
    u8                  bridge_max_age;
    u8                  max_age;
    u8                  topology_change;

    /* Flooding / multicast */
    u8                  multicast_disabled;
    struct hlist_head   mdb_list;    // multicast group table

    /* VLAN support */
    struct net_bridge_vlan_group *vlgrp;
};
```

### `net_bridge_port` — one port of the bridge
```c
struct net_bridge_port {
    struct net_bridge       *br;     // parent bridge
    struct net_device       *dev;    // attached device (eth0, veth, etc.)
    struct list_head        list;

    u8                      port_no;
    u8                      state;   // BR_STATE_FORWARDING, BR_STATE_BLOCKING
    u16                     port_id;
    port_id                 designated_port;

    /* MAC learning timer */
    struct net_bridge_fdb_entry *fdb; // last learned FDB entry
};
```

---

## 2. Bridge Receive Path

**Source:** `net/bridge/br_input.c`

```c
/* Frame arrives at a bridge port (e.g., veth0 attached to br0) */
/* Registered as rx_handler in br_add_if(): */
rx_handler_result_t br_handle_frame(struct sk_buff **pskb)
{
    struct sk_buff *skb = *pskb;
    struct net_bridge_port *p = br_port_get_rcu(skb->dev);

    /* Unicast to a known MAC? */
    if (!is_multicast_ether_addr(eth_hdr(skb)->h_dest)) {
        struct net_bridge_fdb_entry *dst;

        /* Learn source MAC → this port */
        br_fdb_update(p->br, p, eth_hdr(skb)->h_source, vid, false);

        /* Look up destination in FDB */
        dst = br_fdb_find_rcu(p->br, eth_hdr(skb)->h_dest, vid);
        if (dst) {
            /* Forward to specific port */
            br_forward(dst->dst, skb, false, true);
            return RX_HANDLER_CONSUMED;
        }
    }

    /* Unknown/multicast: flood to all ports except incoming */
    br_flood(p->br, skb, BR_PKT_UNICAST, false, true);
    return RX_HANDLER_CONSUMED;
}
```

### FDB entry
```c
struct net_bridge_fdb_entry {
    struct hlist_node   hlist;
    struct net_bridge_port *dst;     // which port this MAC is on
    unsigned char       addr[ETH_ALEN]; // MAC address
    __u16               vlan_id;
    unsigned char       is_local:1;  // local to this bridge
    unsigned char       is_static:1; // permanent entry
    unsigned long       updated;     // for aging (default 300s)
};
```

---

## 3. VXLAN — Virtual Extensible LAN

**Source:** `drivers/net/vxlan.c`

VXLAN encapsulates Ethernet frames in UDP packets, extending L2 networks over L3 infrastructure:

```
VM1 (10.0.0.1) ────► vxlan0 ─── encap ──► UDP/IP ──► vxlan0 ──► VM2 (10.0.0.2)
                       │                                  │
                    vtep1:4789                         vtep2:4789
                 (physical: 192.168.1.10)          (192.168.1.20)
```

### VXLAN packet format
```
Outer Ethernet | Outer IP | Outer UDP (dport 4789) | VXLAN Header | Inner Ethernet Frame
                                                         │
                                               ┌─────────▼──────────┐
                                               │ Flags (8 bits)     │
                                               │ Reserved (24 bits) │
                                               │ VNI (24 bits) ←── VXLAN Network Identifier
                                               │ Reserved (8 bits)  │
                                               └────────────────────┘
```

**VNI** (24 bits) = up to 16 million virtual networks (vs 4094 for VLANs).

### Creating a VXLAN interface
```bash
# VTEP (VXLAN Tunnel End Point) on host 192.168.1.10
ip link add vxlan0 type vxlan \
    id 42 \                          # VNI
    dstport 4789 \                   # standard VXLAN port
    remote 192.168.1.20 \           # unicast mode: known remote VTEP
    local  192.168.1.10 \
    dev    eth0                      # underlay interface

ip addr add 10.0.0.1/24 dev vxlan0
ip link set vxlan0 up

# On host 192.168.1.20:
ip link add vxlan0 type vxlan id 42 dstport 4789 \
    remote 192.168.1.10 local 192.168.1.20 dev eth0
ip addr add 10.0.0.2/24 dev vxlan0
ip link set vxlan0 up

# Now: ping 10.0.0.2 works (tunneled over UDP)
```

### VXLAN transmit path (kernel)
```c
/* drivers/net/vxlan.c */
static netdev_tx_t vxlan_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct vxlan_dev *vxlan = netdev_priv(dev);
    struct ethhdr *eth = eth_hdr(skb);
    struct vxlan_fdb *f;

    /* Look up inner destination MAC in VXLAN FDB */
    f = vxlan_find_mac(vxlan, eth->h_dest, vni);
    if (!f) {
        /* Unknown MAC: multicast or head-end replication flood */
        vxlan_flood(vxlan, skb, ...);
        return NETDEV_TX_OK;
    }

    /* Build outer headers: Ethernet/IP/UDP/VXLAN */
    vxlan_xmit_one(skb, dev, vni, &f->remote, did_rsc);
    return NETDEV_TX_OK;
}

static void vxlan_encap_skb(struct sk_buff *skb, ...)
{
    /* Push VXLAN header */
    vxh = skb_push(skb, sizeof(*vxh));
    vxh->vx_flags = htonl(VXLAN_HF_VNI);
    vxh->vx_vni   = vni_field;

    /* Push UDP header */
    uh = udp_hdr(skb);
    uh->dest   = htons(vxlan->cfg.dst_port);  // 4789
    uh->source = htons(src_port);
    uh->len    = htons(skb->len);

    /* Push outer IP header and send via ip_local_out() */
    ip_route_output_key(dev_net(dev), &rt, &fl4);
    ip_local_out(dev_net(dev), sk, skb);
}
```

---

## 4. Bridge + VXLAN: Container Networking Architecture

This is exactly how Docker's overlay network and Kubernetes Flannel/Calico work:

```
Node 1                              Node 2
──────────────────────              ──────────────────────
Pod A (10.244.0.2)                  Pod B (10.244.1.2)
  │ veth-pair                         │ veth-pair
  │                                   │
cni0 bridge (10.244.0.1)          cni0 bridge (10.244.1.1)
  │                                   │
flannel.1 (VXLAN VTEP)     ←UDP→  flannel.1 (VXLAN VTEP)
  │                                   │
eth0 (192.168.1.10)                eth0 (192.168.1.20)
```

**Packet path A → B:**
```
1. Pod A sends to 10.244.1.2
2. Route: via flannel.1 (VXLAN device)
3. flannel.1 FDB lookup: inner MAC → VTEP 192.168.1.20
4. Encapsulate: VXLAN header (VNI) + UDP + outer IP
5. Send via eth0 to 192.168.1.20
6. Node 2 eth0 receives UDP on port 4789
7. vxlan_rcv() decapsulates
8. Inner Ethernet frame delivered to cni0 bridge
9. Bridge forwards to Pod B's veth
```

---

## 5. Hands-On

### 5a. Create a bridge and connect two network namespaces
```bash
# Create bridge
sudo ip link add br0 type bridge
sudo ip link set br0 up

# Create two namespaces with veth pairs connected to bridge
for ns in ns1 ns2; do
    sudo ip netns add $ns
    sudo ip link add veth-$ns type veth peer name eth0-$ns
    sudo ip link set eth0-$ns netns $ns
    sudo ip link set veth-$ns master br0
    sudo ip link set veth-$ns up
    sudo ip netns exec $ns ip addr add 10.10.10.$((RANDOM%100+2))/24 dev eth0-$ns
    sudo ip netns exec $ns ip link set eth0-$ns up
    sudo ip netns exec $ns ip link set lo up
done

# Test L2 connectivity
sudo ip netns exec ns1 ip addr show
sudo ip netns exec ns2 ip addr show
# Now ping between them

# See FDB
bridge fdb show br br0

# Clean up
sudo ip netns del ns1
sudo ip netns del ns2
sudo ip link del br0
```

### 5b. Inspect bridge source
```bash
ls ~/linux/net/bridge/
grep -n "br_handle_frame\|br_fdb_update\|br_forward\|br_flood" \
    ~/linux/net/bridge/br_input.c | head -15
```

### 5c. Observe VXLAN encapsulation
```bash
# Create a VXLAN interface (no remote needed for inspection)
sudo ip link add vxlan100 type vxlan id 100 dstport 4789 \
    local 127.0.0.1 dev lo 2>/dev/null
sudo ip link set vxlan100 up
ip link show vxlan100

# See VXLAN FDB
bridge fdb show dev vxlan100

sudo ip link del vxlan100 2>/dev/null
```

---

## 6. Concept Check

1. How does a Linux bridge learn MAC addresses? What happens when it receives a frame for an unknown destination MAC?
2. What problem does VXLAN solve that VLANs cannot? What is the significance of the 24-bit VNI?
3. When a VXLAN device doesn't know which VTEP holds a destination MAC, what does it do? What are the two strategies?
4. Trace the complete path of a packet from Pod A on Node 1 to Pod B on Node 2 in a Flannel-based Kubernetes cluster, naming each kernel interface the packet passes through.

---

## 📚 References
- `net/bridge/br_input.c` — bridge receive/forwarding
- `net/bridge/br_fdb.c` — forwarding database
- `drivers/net/vxlan.c` — VXLAN driver
- `include/linux/if_vxlan.h` — VXLAN header structures
- Kernel docs: `Documentation/networking/vxlan.rst`
- RFC 7348 — VXLAN specification
