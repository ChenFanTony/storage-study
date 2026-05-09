# Day 12 — Network Namespaces and `veth` Pairs
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 2)

---

## 🎯 Goal
Understand how Linux network namespaces isolate the network stack, how `veth` pairs connect them, and how containers (Docker/Kubernetes) build on these primitives.

---

## 1. What Is a Network Namespace?

A **network namespace** is an isolated instance of the entire network stack:

```
netns A                    netns B (container)
──────────────────         ──────────────────
lo (127.0.0.1)             lo (127.0.0.1)
eth0 (192.168.1.5)         eth0 (172.17.0.2)
routing table A            routing table B
iptables rules A           iptables rules B
socket table A             socket table B
conntrack table A          conntrack table B
```

Each namespace has its own: interfaces, routing table, ARP table, iptables, sockets, `/proc/net/`.

**Source:** `net/core/net_namespace.c`, `include/net/net_namespace.h`

---

## 2. `struct net` — The Namespace Object

**Source:** `include/net/net_namespace.h`

```c
struct net {
    refcount_t          passive;    // reference count
    spinlock_t          rules_mod_lock;

    /* Per-namespace network devices */
    struct list_head    dev_base_head;   // all net_device in this ns
    struct hlist_head   *dev_name_head;  // hash by name
    struct hlist_head   *dev_index_head; // hash by ifindex

    /* Routing */
    struct netns_ipv4   ipv4;       // IPv4 FIB, sysctl_* per-ns
    struct netns_ipv6   ipv6;

    /* Netfilter / conntrack */
    struct netns_nf     nf;
    struct netns_xt     xt;

    /* Sockets, protocols */
    struct sock         *rtnl;      // rtnetlink socket for this ns
    struct sock         *genl_sock;

    /* Proc and sysfs */
    struct proc_dir_entry *proc_net;    // /proc/net/ per namespace
    struct proc_dir_entry *proc_net_stat;

    /* Loopback device */
    struct net_device   *loopback_dev;

    /* User namespace owning this network namespace */
    struct user_namespace *user_ns;
};
```

Every `net_device` and `struct sock` has a pointer back to its namespace:
```c
struct net_device { struct net *nd_net; ... };
struct sock       { struct net *sk_net; ... };
```

---

## 3. Creating a Network Namespace

**Userspace:**
```bash
ip netns add myns
ip netns list
ip netns exec myns ip link show
```

**Kernel syscall path:**
```
unshare(CLONE_NEWNET)          # for current process
  or
clone(fn, stack, CLONE_NEWNET, ...) # for new process (containers)

  └── copy_net_ns()            # kernel/nsproxy.c
        └── setup_net(net, user_ns)
              ├── alloc struct net
              ├── init subsystems: ipv4, ipv6, netfilter, ...
              ├── create loopback device
              └── register /proc/net/ entries
```

**Source:** `net/core/net_namespace.c`
```c
static int setup_net(struct net *net, struct user_namespace *user_ns)
{
    const struct pernet_operations *ops, *saved_ops;
    int error = 0;

    atomic_set(&net->count, 1);
    net->user_ns = user_ns;

    /* Run each subsystem's init function for this new namespace */
    list_for_each_entry(ops, &pernet_list, list) {
        error = ops->init(net);  // e.g., ipv4_net_init, tcp_net_init
        if (error < 0)
            goto out_undo;
    }
    return 0;
}
```

---

## 4. `veth` — Virtual Ethernet Pairs

**Source:** `drivers/net/veth.c`

A `veth` pair is two virtual NICs wired together — what goes in one end comes out the other:

```
netns A                         netns B
────────────                    ────────────
veth0 ──────── kernel ──────── veth1
(192.168.10.1)    wire          (192.168.10.2)
```

### How `veth` transmit works
```c
/* drivers/net/veth.c */
static netdev_tx_t veth_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct veth_priv *rcv_priv, *priv = netdev_priv(dev);
    struct net_device *rcv;

    /* Get the peer device */
    rcv = rcu_dereference(priv->peer);
    if (!rcv || !pskb_may_pull(skb, ETH_HLEN))
        goto drop;

    /* Hand skb directly to the peer's receive path */
    /* No actual wire — just a function call! */
    veth_forward_skb(rcv, skb, false);
    return NETDEV_TX_OK;
drop:
    kfree_skb(skb);
    return NETDEV_TX_OK;
}

static void veth_forward_skb(struct net_device *dev, struct sk_buff *skb,
                              bool xdp)
{
    skb->dev = dev;
    if (dev->features & NETIF_F_GRO)
        napi_gro_receive(&priv->xdp_napi, skb);
    else
        netif_rx(skb);   // → netif_receive_skb() in peer's namespace
}
```

**Zero copy, zero hardware.** The `sk_buff` pointer simply moves from one namespace's device to another.

---

## 5. Container Networking (Docker/Kubernetes Pattern)

```
Host namespace                     Container namespace
──────────────────                 ─────────────────────
docker0 bridge                     eth0 (veth peer)
(172.17.0.1)                       (172.17.0.2)
    │
    ├── vethABCD (host end)  ←────→  eth0 (container end)
    ├── vethEFGH (host end)  ←────→  eth0 (container 2)
    └── ...

iptables MASQUERADE:
  -t nat -A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
```

### Setup sequence (what `docker run` does)
```bash
# 1. Create namespace
ip netns add container1

# 2. Create veth pair
ip link add veth0 type veth peer name eth0

# 3. Move one end into namespace
ip link set eth0 netns container1

# 4. Configure addresses
ip addr add 172.17.0.1/24 dev veth0
ip netns exec container1 ip addr add 172.17.0.2/24 dev eth0

# 5. Bring up
ip link set veth0 up
ip netns exec container1 ip link set eth0 up
ip netns exec container1 ip link set lo up

# 6. Add to bridge
ip link set veth0 master docker0
```

---

## 6. Namespace-Aware Kernel Code

The pattern throughout the kernel:
```c
/* Getting the current namespace */
struct net *net = sock_net(sk);           // from socket
struct net *net = dev_net(dev);           // from net_device
struct net *net = get_net_ns_by_pid(pid); // from process

/* Per-namespace sysctl access */
net->ipv4.sysctl_tcp_rmem[2]   // instead of global sysctl_tcp_rmem
net->ipv4.sysctl_ip_default_ttl
```

---

## 7. Hands-On

### 7a. Create and explore a namespace
```bash
# Create namespace
sudo ip netns add testns

# List namespaces
ip netns list

# Run command inside namespace
sudo ip netns exec testns ip link show
sudo ip netns exec testns ip addr show

# /proc/net inside namespace is isolated
sudo ip netns exec testns cat /proc/net/tcp
```

### 7b. Create veth pair and connect namespaces
```bash
# Create veth pair
sudo ip link add veth-host type veth peer name veth-ns

# Move one end into namespace
sudo ip link set veth-ns netns testns

# Configure
sudo ip addr add 10.99.0.1/24 dev veth-host
sudo ip link set veth-host up
sudo ip netns exec testns ip addr add 10.99.0.2/24 dev veth-ns
sudo ip netns exec testns ip link set veth-ns up
sudo ip netns exec testns ip link set lo up

# Test connectivity
ping -c3 10.99.0.2
sudo ip netns exec testns ping -c3 10.99.0.1

# Clean up
sudo ip netns del testns   # removes veth-host automatically
```

### 7c. See namespace isolation in action
```bash
# Start listener in namespace
sudo ip netns exec testns nc -l 8888 &

# Connect from host (works if route exists)
nc 10.99.0.2 8888

# From host: can't see the listener in ss (different namespace)
ss -tnlp | grep 8888           # empty
sudo ip netns exec testns ss -tnlp | grep 8888   # shows it
```

### 7d. Read veth source
```bash
grep -n "veth_xmit\|veth_forward_skb\|peer" \
    ~/linux/drivers/net/veth.c | head -30
```

---

## 8. Concept Check

1. What exactly is isolated between two network namespaces? List at least 5 things.
2. Why is `veth` transmit essentially zero-copy? What does the kernel skip compared to a real NIC driver?
3. How does a container process's `socket()` call end up associated with the container's network namespace rather than the host's?
4. When a packet leaves a container through its `eth0`, what path does it take to reach an external host? (Hint: veth → bridge → NAT)

---

## 📚 References
- `net/core/net_namespace.c` — namespace lifecycle
- `drivers/net/veth.c` — veth pair driver
- `include/net/net_namespace.h` — `struct net`
- `kernel/nsproxy.c` — namespace switching
- Kernel docs: `Documentation/networking/net_namespace.rst`
