# Day 28 — Final Review: The Complete Mental Model
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 4 — Final Day)

---

## 🎯 Goal
Build a single coherent mental model of the entire Linux network stack, consolidate all 28 days of learning, and leave with a reference you can return to forever.

---

## 1. The Unified Stack Map

```
══════════════════════════════════════════════════════════════════
                         USER SPACE
══════════════════════════════════════════════════════════════════

Application
  ├── send() / recv()            (blocking or non-blocking)
  ├── sendfile() / splice()      (zero-copy file transfer)
  ├── epoll_wait()               (event notification)
  └── MSG_ZEROCOPY send()        (zero-copy user buffer TX)

══════════════════════════════════════════════════════════════════
                    SYSCALL BOUNDARY
══════════════════════════════════════════════════════════════════

Socket Layer                               [Day 02]
  struct socket  (VFS glue: proto_ops)
  struct sock    (network state: queues, buffers, state)
  struct tcp_sock / udp_sock / inet_sock   (protocol-specific)

  kTLS ULP  →  tls_sw_sendmsg()           [Day 18]
           →  kernel AES-GCM encrypt
           →  TLS record header prepend

══════════════════════════════════════════════════════════════════
                  TRANSPORT LAYER (L4)
══════════════════════════════════════════════════════════════════

TCP                                        [Days 05, 06, 09, 17, 24]
  TX: tcp_sendmsg → tcp_write_xmit → tcp_transmit_skb
      ├── Congestion control: cwnd (CUBIC/BBR)  [Day 06]
      ├── Flow control: snd_wnd (receiver)      [Day 09]
      ├── TSQ: limit bytes in lower layers      [Day 24]
      └── Pacing: sk_pacing_rate via fq qdisc   [Day 24]

  RX: tcp_v4_rcv → tcp_rcv_established (fast path)
      ├── Socket lookup: __inet_lookup_skb()
      ├── In-order: sk_receive_queue → sk_data_ready()
      └── Out-of-order: out_of_order_queue (rb_tree)

  TIME_WAIT: tcp_timewait_sock (lightweight)    [Day 17]
  Memory: sk_rcvbuf/sk_sndbuf, tcp_mem zones    [Day 08]

UDP                                        [Day 11]
  TX: udp_sendmsg → ip_send_skb
  RX: udp_rcv → sk_receive_queue (datagrams, no ordering)
  Drops silently when sk_rcvbuf full

══════════════════════════════════════════════════════════════════
                    NETWORK LAYER (L3)
══════════════════════════════════════════════════════════════════

IP Layer                                   [Day 04]
  RX: ip_rcv() → validate → NF_HOOK(PREROUTING)
      → fib_lookup() → ip_local_deliver() or ip_forward()

  TX: ip_queue_xmit() → build IP header → NF_HOOK(OUTPUT)
      → ip_finish_output() → fragment if needed

Routing / FIB                              [Day 20]
  LC-Trie: O(1) longest-prefix match
  fib_info + fib_nh[]: nexthop(s), interface, gateway
  Policy routing: ip rules → table selection
  ECMP: flow hash selects nexthop for connection coherence
  dst_entry: cached in skb→_skb_refdst, drives input/output

Netfilter                                  [Day 07]
  5 hooks: PREROUTING, INPUT, FORWARD, OUTPUT, POSTROUTING
  iptables tables: raw, mangle, nat, filter
  conntrack: per-connection state for NAT and stateful filter

══════════════════════════════════════════════════════════════════
                      LINK LAYER (L2)
══════════════════════════════════════════════════════════════════

ARP / Neighbor                             [Day 19]
  struct neighbour: IP→MAC, NUD state machine
  NUD: INCOMPLETE→REACHABLE→STALE→DELAY→PROBE
  arp_queue: skbs wait here during resolution

Ethernet Framing                           [Day 19]
  eth_header(): skb_push(ETH_HLEN) → fill ethhdr

Bridge                                     [Day 27]
  br_handle_frame(): learn src MAC → FDB, forward or flood
  FDB: MAC → port hash table, aged out after 300s

VXLAN                                      [Day 27]
  vxlan_xmit(): FDB lookup → encap UDP/IP → outer NIC
  VNI (24-bit): 16M virtual L2 segments

Traffic Control (qdisc)                    [Day 13]
  dev_queue_xmit → qdisc enqueue → dequeue → ndo_start_xmit
  pfifo_fast (default), TBF (rate), HTB (hierarchy)
  fq: pacing enforcement from sk_pacing_rate
  netem: artificial delay/loss for testing

══════════════════════════════════════════════════════════════════
                    DEVICE / DRIVER LAYER
══════════════════════════════════════════════════════════════════

net_device                                 [Day 03]
  struct net_device: NIC abstraction
  net_device_ops: ndo_open, ndo_start_xmit, ndo_set_rx_mode

Multi-queue / Scaling                      [Day 16]
  XPS: pick TX queue per CPU/socket
  RSS: NIC hardware hash → RX queue → IRQ → CPU
  RPS: software steering when NIC has one queue
  RFS: steer to CPU running recvmsg() (socket affinity)

NAPI / Softirq                             [Day 23]
  Hard IRQ → napi_schedule → NET_RX_SOFTIRQ
  net_rx_action(): poll_list, budget=300pkts/2ms
  napi_poll(): driver processes ring → netif_receive_skb()
  GRO: coalesce small skbs before delivering to stack

NIC Driver (e.g., e1000)                   [Day 03]
  Ring buffer: DMA descriptors pointing to pre-allocated pages
  NAPI poll: read descriptors, alloc sk_buff, call netif_receive_skb()
  ndo_start_xmit: write descriptor, DMA map skb, ring doorbell

══════════════════════════════════════════════════════════════════
                      NIC HARDWARE
══════════════════════════════════════════════════════════════════
  RX: DMA frame → ring[tail] → IRQ → NAPI
  TX: DMA from ring[head] → wire → completion IRQ
  Optional offloads: TSO, GRO, RSS, checksum, TLS_HW

══════════════════════════════════════════════════════════════════
                     CROSS-CUTTING CONCERNS
══════════════════════════════════════════════════════════════════

sk_buff lifecycle                          [Day 22]
  alloc_skb → skb_reserve (headroom) → skb_put (payload)
  → skb_push (header prepend) → skb_pull (header consume)
  clone: shared data, new descriptor (dataref++)
  free: kfree_skb → destructor → skb_release_data (dataref--)

Network Namespaces                         [Days 12, 27]
  struct net: isolated stack per container
  veth: zero-copy peer→peer
  Container = netns + veth + bridge + iptables NAT

Zero-Copy                                  [Day 15]
  sendfile: page cache refs in skb_shinfo frags
  MSG_ZEROCOPY: pinned user pages, MSG_ERRQUEUE notify
  GSO/TSO: one large skb, NIC or software segments

eBPF / XDP                                 [Days 14, 25]
  XDP: before sk_buff, in driver poll loop
  TC BPF: qdisc level, full sk_buff access
  AF_XDP: UMEM rings, zero-copy to userspace

Observability                              [Day 26]
  /proc/net/snmp, /proc/net/netstat, ss -tin
  ftrace events: tcp/, net/, sock/
  bpftrace one-liners: latency, histogram, state
```

---

## 2. The Central Data Structures

```
struct sk_buff              — THE packet carrier (skbuff.h)
struct sock                 — socket state machine (sock.h)
struct tcp_sock             — TCP state (tcp.h)
struct net_device           — NIC abstraction (netdevice.h)
struct napi_struct          — NAPI poll (netdevice.h)
struct neighbour            — ARP/NDP cache (neighbour.h)
struct rtable / dst_entry   — route cache (route.h)
struct Qdisc                — traffic scheduler (sch_generic.h)
struct net                  — network namespace (net_namespace.h)
struct eventpoll            — epoll instance (fs/eventpoll.c)
```

---

## 3. The 10 Most Important Kernel Functions

| Function | File | Significance |
|---|---|---|
| `tcp_v4_rcv()` | `net/ipv4/tcp_ipv4.c` | TCP entry point — all inbound segments start here |
| `tcp_rcv_established()` | `net/ipv4/tcp_input.c` | Fast path — handles 99% of TCP traffic |
| `tcp_write_xmit()` | `net/ipv4/tcp_output.c` | The TCP sending engine |
| `ip_rcv()` | `net/ipv4/ip_input.c` | IP entry point from L2 |
| `ip_queue_xmit()` | `net/ipv4/ip_output.c` | IP output: routing + header build |
| `netif_receive_skb()` | `net/core/dev.c` | Demux from driver to L3 protocols |
| `dev_queue_xmit()` | `net/core/dev.c` | Entry to qdisc + driver TX |
| `ep_poll_callback()` | `fs/eventpoll.c` | epoll: wakes epoll_wait on data |
| `napi_poll()` | `net/core/dev.c` | NAPI: calls driver poll, limits budget |
| `fib_lookup()` | `net/ipv4/fib_rules.c` | Routing: policy rules + FIB trie |

---

## 4. The 10 Most Useful `/proc` and `sysctl` Knobs

```bash
# Observability
cat /proc/net/snmp              # IP/TCP/UDP counters (RFC names)
cat /proc/net/netstat           # Extended TCP counters
cat /proc/net/softnet_stat      # Per-CPU softirq drops
cat /proc/net/tcp               # All TCP sockets (hex)
ss -tin state established       # Rich per-socket TCP state

# Tuning
sysctl net.ipv4.tcp_rmem        # [min default max] receive buffer
sysctl net.ipv4.tcp_wmem        # [min default max] write buffer
sysctl net.ipv4.tcp_congestion_control  # cubic/bbr/reno
sysctl net.ipv4.ip_local_port_range     # ephemeral port range
sysctl net.core.netdev_budget           # NAPI packets per softirq
```

---

## 5. Source Code Reading Order (Revisited)

If you were to re-read kernel source end-to-end:

```
1. include/linux/skbuff.h        — understand the packet carrier
2. include/net/sock.h            — understand the socket
3. net/core/skbuff.c             — allocation and lifecycle
4. net/socket.c                  — syscall entry points
5. net/ipv4/af_inet.c            — AF_INET socket creation
6. net/ipv4/tcp_ipv4.c           — TCP entry and socket lookup
7. net/ipv4/tcp_input.c          — TCP receive state machine
8. net/ipv4/tcp_output.c         — TCP transmit engine
9. net/ipv4/ip_input.c           — IP receive
10. net/ipv4/ip_output.c         — IP transmit + fragmentation
11. net/ipv4/route.c             — routing lookup
12. net/ipv4/arp.c               — ARP
13. net/core/neighbour.c         — neighbor subsystem
14. net/core/dev.c               — NAPI, netif_receive_skb, dev_queue_xmit
15. net/sched/sch_generic.c      — qdisc framework
16. drivers/net/ethernet/intel/e1000/e1000_main.c — real driver
17. fs/eventpoll.c               — epoll
18. net/netfilter/               — netfilter/iptables
19. net/tls/                     — kTLS
20. net/xdp/                     — AF_XDP
```

---

## 6. Final 28-Day Concept Check

1. A `send()` call returns. Has the data left the machine? Explain where it is.
2. An HTTP server sees latency spikes every 40ms even under light load. What's the most likely cause and fix?
3. A new container starts. List every kernel object created (struct types and counts).
4. `ethtool -S eth0` shows `rx_fifo_errors` growing. Trace the path from NIC to where packets are lost and propose two fixes.
5. You need 10M pps with <10μs latency on a 25G NIC. What technology do you use, and what does it bypass?
6. A TCP connection has `cwnd=100` but `snd_wnd=3000` (bytes). How many bytes can be in flight? What caps transmission now?
7. You see `TCPZeroWindowAdv` rising. Which end is advertising zero? What's happening on that machine?
8. A packet arrives at `ip_rcv()`. Name every function it might pass through before `tcp_recvmsg()` returns data to userspace.

---

## 7. What's Next

You've completed the 28-day Linux network stack curriculum. Natural next steps:

**Go deeper on one area:**
- Write a kernel module that hooks Netfilter → deploy a custom firewall
- Write an XDP program → build a software load balancer
- Contribute to Linux kernel networking → `net/ipv4/` or `net/core/`

**Expand to related areas:**
- **Linux Storage I/O**: `block/`, `mm/`, page cache, io_uring
- **Linux Scheduler**: `kernel/sched/`, CFS, real-time scheduling
- **Linux Memory Management**: `mm/`, page tables, NUMA, huge pages
- **Linux Security**: LSM, namespaces, cgroups, seccomp, eBPF LSM

**Books:**
- *Linux Kernel Networking* — Rami Rosen
- *Understanding Linux Network Internals* — Christian Benvenuti
- *Linux Kernel Development* — Robert Love
- *Systems Performance* — Brendan Gregg

**Kernel mailing list:**
- `netdev@vger.kernel.org` — Linux network development
- `lkml@vger.kernel.org` — Linux kernel mailing list

---

## 🎓 Congratulations

You've gone from "network stack overview" to understanding:
- Every byte a packet touches from NIC wire to userspace buffer
- Every data structure that owns the packet at each layer
- How the kernel makes performance/correctness tradeoffs at each step
- How to observe, measure, and tune every part of the path

The network stack is one of the most elegant pieces of engineering in the Linux kernel. You now have the mental model to read, understand, and eventually contribute to it.
