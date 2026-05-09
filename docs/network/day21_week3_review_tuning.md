# Day 21 — Week 3 Review + Network Performance Tuning Cheatsheet
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 3)

---

## 🎯 Goal
Consolidate Week 3's advanced topics and build a practical reference for diagnosing and tuning Linux network performance.

---

## 1. 🗺️ Week 3 Full Review

```
Day 15: Zero-Copy
  sendfile → nonlinear sk_buff (page refs, no copy)
  splice → kernel pipe as intermediary
  MSG_ZEROCOPY → pin user pages, notify via MSG_ERRQUEUE
  GSO/TSO → large skb, NIC segments; GRO → merge inbound skbs

Day 16: Multi-Queue / Scaling
  RSS → NIC hardware hash → multiple RX queues → one IRQ per CPU
  RPS → software flow steering when NIC has one queue
  RFS → steer to CPU running recvmsg() for cache locality
  XPS → pick TX queue based on CPU / socket
  SO_REUSEPORT → multiple accept() sockets, kernel distributes SYNs

Day 17: TIME_WAIT
  2×MSL to: (1) ensure final ACK delivered, (2) let old pkts expire
  tcp_timewait_sock: lightweight, ~128 bytes
  tcp_tw_reuse + timestamps: safe reuse of TIME_WAIT 4-tuples
  Port exhaustion: ephemeral range + TIME_WAIT × rate

Day 18: kTLS
  ULP: intercepts sendmsg/recvmsg at TCP socket level
  tls_sw: kernel AES-GCM + prepend TLS record header
  sendfile with TLS: file → encrypt in kernel → NIC DMA (zero copy)
  TLS_HW: NIC encrypts in hardware

Day 19: ARP / Neighbor
  struct neighbour: IP→MAC mapping + NUD state machine
  ARP request = broadcast; ARP reply = unicast
  NUD states: INCOMPLETE → REACHABLE → STALE → DELAY → PROBE
  neigh->arp_queue: packets wait here during resolution

Day 20: Routing / FIB
  LC-Trie: O(1) longest-prefix match
  fib_info: route metadata + fib_nh array (nexthops)
  Policy routing: ip rule → pick table → fib_table_lookup()
  ECMP: flow hash selects nexthop; same flow = same path
  dst_entry: embedded in rtable, drives input/output function pointers
```

---

## 2. Full Stack with Week 3 Additions

```
USER SPACE
  Application: send() / recv() / sendfile()
        │
  [kTLS ULP]     tls_sw_sendmsg: encrypt → TLS record header
        │
  [TCP layer]    congestion control, flow control, retransmit
        │
  [IP layer]     ip_route_output() → FIB lookup → rtable
        │
  [Neighbor]     ARP lookup → neigh→ha (MAC address)
  [Link layer]   eth_header() → Ethernet frame
        │
  [qdisc layer]  pfifo_fast / HTB / TBF → schedule TX
        │
  [Driver TX]    XPS → pick queue → ndo_start_xmit
  [NIC HW]       DMA from sk_buff frags (GSO/TSO if supported)
                 Optional: TLS_HW encrypt in NIC
        │
────────── WIRE ──────────────────────────────────────────────
        │
  [NIC HW RX]    DMA into ring buffer → RSS → queue N → IRQ N
  [NAPI poll]    napi_poll() → netif_receive_skb()
                 GRO: merge small skbs
                 XDP: drop/redirect before sk_buff
        │
  [Netfilter]    PREROUTING → routing → INPUT/FORWARD
  [IP RX]        ip_rcv() → ip_local_deliver() or ip_forward()
        │
  [TCP/UDP RX]   tcp_v4_rcv(): socket lookup → fast path / state machine
  [Socket buf]   sk_receive_queue → sk_data_ready() → wake epoll
        │
USER SPACE
  Application: recv() / epoll_wait()
```

---

## 3. 🛠️ Performance Tuning Cheatsheet

### 3a. Socket Buffer Sizes
```bash
# Show current limits
sysctl net.ipv4.tcp_rmem    # [min default max] receive buffer
sysctl net.ipv4.tcp_wmem    # [min default max] write buffer
sysctl net.core.rmem_max    # absolute max for SO_RCVBUF
sysctl net.core.wmem_max    # absolute max for SO_SNDBUF

# High-throughput tuning (10G+ links, high-latency paths)
sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728"
sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728"
sysctl -w net.core.rmem_max=134217728
sysctl -w net.core.wmem_max=134217728

# Enable auto-tuning (should be on by default)
sysctl -w net.ipv4.tcp_moderate_rcvbuf=1
```

### 3b. Connection Handling
```bash
# SYN backlog (half-open connections during 3-way handshake)
sysctl -w net.ipv4.tcp_max_syn_backlog=65536

# Accept queue per socket (listen() backlog max)
sysctl -w net.core.somaxconn=65535

# TIME_WAIT limit
sysctl -w net.ipv4.tcp_max_tw_buckets=262144

# Ephemeral port range for clients
sysctl -w net.ipv4.ip_local_port_range="1024 65535"

# Reuse TIME_WAIT sockets (with timestamps)
sysctl -w net.ipv4.tcp_tw_reuse=1

# SYN cookies for SYN flood protection
sysctl -w net.ipv4.tcp_syncookies=1
```

### 3c. Multi-Queue / Interrupt Tuning
```bash
# Set number of RX/TX queues (requires driver support)
ethtool -L eth0 rx 8 tx 8

# Enable RPS (all CPUs)
CPUMASK=$(python3 -c "print(hex((1 << $(nproc)) - 1))")
for q in /sys/class/net/eth0/queues/rx-*/rps_cpus; do
    echo $CPUMASK > $q
done

# Enable RFS
echo 65536 > /proc/sys/net/core/rps_sock_flow_entries
for q in /sys/class/net/eth0/queues/rx-*/rps_flow_cnt; do
    echo 4096 > $q
done

# IRQ affinity (distribute IRQs across CPUs)
# Check: cat /proc/interrupts | grep eth0
# Set: echo <cpumask> > /proc/irq/<N>/sma_affinity
```

### 3d. TCP Algorithm Tuning
```bash
# Congestion control
sysctl net.ipv4.tcp_congestion_control   # cubic by default
sysctl -w net.ipv4.tcp_congestion_control=bbr  # BBR for long-fat pipes

# Enable ECN (Explicit Congestion Notification)
sysctl -w net.ipv4.tcp_ecn=1

# SACK (Selective Acknowledgment) - should be on
sysctl net.ipv4.tcp_sack   # 1 = enabled

# Fast Open (skip handshake for repeat connections)
sysctl -w net.ipv4.tcp_fastopen=3  # client+server
```

### 3e. Offload and Zero-Copy
```bash
# Check current offloads
ethtool -k eth0

# Enable TSO/GSO/GRO (usually on by default)
ethtool -K eth0 tso on gso on gro on

# For sendfile performance: check page cache health
cat /proc/meminfo | grep -E "Cached|Dirty|Writeback"
```

### 3f. Network Queue Tuning
```bash
# TX queue length per interface
ip link set eth0 txqueuelen 10000
# or: ifconfig eth0 txqueuelen 10000

# Softirq budget (packets processed per NAPI poll)
sysctl -w net.core.netdev_budget=600
sysctl -w net.core.netdev_budget_usecs=8000

# Backlog queue (per-CPU softirq receive queue)
sysctl -w net.core.netdev_max_backlog=5000
```

---

## 4. 🔍 Diagnostics Reference

### Finding packet drops
```bash
# Per-interface drops
ip -s link show eth0

# TCP-level drops and errors
cat /proc/net/snmp | grep "^Tcp"
nstat -az | grep -i "drop\|error\|fail" | head -20

# Socket receive buffer drops (UDP)
cat /proc/net/snmp | grep "^Udp" | tr '\t' '\n' | grep -i "error\|buf"

# Softirq drop (backlog overflow)
cat /proc/net/softnet_stat
# column 2 = dropped due to netdev_max_backlog

# NIC ring buffer drops
ethtool -S eth0 | grep -i "drop\|miss"
```

### Latency diagnosis
```bash
# RTT to target
ping -c100 <host> | tail -1

# TCP connection latency histogram (requires bpftrace)
bpftrace -e 'kretprobe:tcp_v4_connect /retval == 0/ { @[comm] = hist(nsecs - @start[tid]); } kprobe:tcp_v4_connect { @start[tid] = nsecs; }' 2>/dev/null

# Detect retransmits
ss -tin | grep "retrans"
cat /proc/net/snmp | grep "^Tcp" | tr '\t' '\n' | grep Retrans
```

### Connection state overview
```bash
# Summary of all TCP states
ss -tan | awk 'NR>1 {print $1}' | sort | uniq -c | sort -rn

# Established connections by remote host
ss -tn state established | awk '{print $5}' | \
    sed 's/:[0-9]*$//' | sort | uniq -c | sort -rn | head -20

# Listening sockets
ss -tlnp
```

---

## 5. Key Files: Week 3 Summary

| Day | Source Files |
|---|---|
| 15 | `net/socket.c`, `fs/splice.c`, `net/core/zerocopy.c`, `net/ipv4/tcp.c` |
| 16 | `net/core/dev.c` (RPS/RFS/XPS), `net/ipv4/inet_hashtables.c` |
| 17 | `net/ipv4/tcp_minisocks.c`, `net/ipv4/tcp_ipv4.c` |
| 18 | `net/tls/tls_sw.c`, `net/tls/tls_main.c`, `net/tls/tls_device.c` |
| 19 | `net/ipv4/arp.c`, `net/core/neighbour.c`, `net/ethernet/eth.c` |
| 20 | `net/ipv4/fib_trie.c`, `net/ipv4/fib_semantics.c`, `net/ipv4/route.c` |

---

## 6. Week 3 Final Concept Check

1. You're building an HTTP file server. List three techniques from this week that reduce data copies between disk and NIC, and explain which kernel path each uses.
2. A server has 16 CPUs and one NIC queue. What sequence of features should you enable to scale receive processing? What is the ordering dependency between them?
3. A client does 2,000 short HTTP/1.0 requests per second (no keep-alive) to one server. The client machine runs out of ephemeral ports. List three solutions, ordered from "quick fix" to "proper fix".
4. You set up ECMP with two paths to `10.0.0.0/8`. A TCP connection from `192.168.1.5:54321` to `10.1.2.3:80` starts on path 1. A few packets later, does it switch to path 2? Why or why not?
5. Describe what happens in the kernel between `send()` returning and the actual bits leaving the NIC wire. Include: kTLS (if active), TCP, IP, ARP/neigh, qdisc, and driver.

---

## Week 4 Preview

Final week — **Expert-Level Internals**:
- Day 22: `sk_buff` lifecycle: allocation, cloning, fragmentation, and freeing
- Day 23: Softirq and NAPI in depth — the Linux packet I/O engine
- Day 24: TCP small queues (TSQ) and pacing
- Day 25: Kernel bypass — DPDK concepts and AF_XDP
- Day 26: Network namespaces in depth — bridges, VXLAN, overlays
- Day 27: Kernel networking observability — perf, ftrace, bpftrace recipes
- Day 28: Final review — build a mental model of the entire stack
