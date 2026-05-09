# Day 14 — eBPF/XDP Introduction and Week 2 Review
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 2)

---

## 🎯 Goal
Get a solid introduction to eBPF and XDP — the modern programmable layer in the Linux network stack — and consolidate all of Week 2's concepts.

---

## 1. What Is eBPF?

eBPF (extended Berkeley Packet Filter) lets you run **sandboxed programs inside the kernel** without writing a kernel module. The kernel verifies the program before running it.

```
User Space                         Kernel Space
──────────────                     ──────────────────────────────
Write eBPF program                 eBPF verifier checks safety
  (C → clang → BPF bytecode)  →   JIT compiles to native code
Load with bpf() syscall       →   Attach to hook point
Read results via maps         ←   Program runs on each event
```

**Use cases in networking:**
- XDP: drop/redirect packets at driver level (before sk_buff allocation)
- TC filter: classify and modify packets in the qdisc layer
- Socket filter: filter packets on a socket (original BPF use)
- kprobe/tracepoint: trace any kernel function

---

## 2. eBPF Architecture

**Source:** `kernel/bpf/`, `net/core/filter.c`

### BPF program types for networking
```c
enum bpf_prog_type {
    BPF_PROG_TYPE_SOCKET_FILTER,  // attached to socket (oldest)
    BPF_PROG_TYPE_XDP,            // at driver/NIC level
    BPF_PROG_TYPE_SCHED_CLS,      // tc classifier
    BPF_PROG_TYPE_SCHED_ACT,      // tc action
    BPF_PROG_TYPE_SK_SKB,         // sockmap/stream parser
    BPF_PROG_TYPE_CGROUP_SOCK,    // cgroup socket hooks
    /* ... many more */
};
```

### BPF Maps — sharing data between program and userspace
```c
/* Maps are key-value stores accessible from both kernel BPF programs
   and userspace via the bpf() syscall */
enum bpf_map_type {
    BPF_MAP_TYPE_HASH,          // generic hash map
    BPF_MAP_TYPE_ARRAY,         // array (faster for fixed keys)
    BPF_MAP_TYPE_PERCPU_HASH,   // per-CPU hash (lock-free)
    BPF_MAP_TYPE_LPM_TRIE,      // longest-prefix match (routing)
    BPF_MAP_TYPE_RINGBUF,       // ring buffer for events
    /* ... */
};
```

---

## 3. XDP — eXpress Data Path

**Source:** `net/core/dev.c`, `include/linux/netdevice.h`

XDP runs a BPF program at the **earliest possible point** — in the NIC driver, before `sk_buff` allocation:

```
NIC HW → DMA → rx_ring
                  │
              XDP program ← runs here, on raw frame
                  │
              ┌───┴────────────────────────┐
              │                            │
           XDP_PASS                    XDP_DROP
           XDP_TX                      XDP_REDIRECT
              │
        netif_receive_skb()  (normal stack)
```

### XDP return codes
```c
enum xdp_action {
    XDP_ABORTED  = 0,  // error, drop + count error
    XDP_DROP     = 1,  // drop silently (fastest)
    XDP_PASS     = 2,  // pass up to normal stack
    XDP_TX       = 3,  // transmit back out same NIC
    XDP_REDIRECT = 4,  // redirect to different NIC / CPU / socket
};
```

### XDP program context
```c
/* The XDP program receives this struct (not an sk_buff!) */
struct xdp_md {
    __u32 data;         // pointer to start of packet data
    __u32 data_end;     // pointer to end of packet data
    __u32 data_meta;    // metadata area before data
    __u32 ingress_ifindex;
    __u32 rx_queue_index;
};
```

### Minimal XDP program (in C, compiled with clang -target bpf)
```c
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

/* Drop all ICMP packets, pass everything else */
SEC("xdp")
int xdp_icmp_drop(struct xdp_md *ctx)
{
    void *data_end = (void *)(long)ctx->data_end;
    void *data     = (void *)(long)ctx->data;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    if (eth->h_proto != htons(ETH_P_IP))
        return XDP_PASS;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return XDP_PASS;

    if (ip->protocol == IPPROTO_ICMP)
        return XDP_DROP;

    return XDP_PASS;
}

char LICENSE[] SEC("license") = "GPL";
```

### Loading XDP
```bash
# Load XDP program on eth0 (requires ip tool with XDP support or bpftool)
ip link set dev eth0 xdp obj icmp_drop.o sec xdp

# Remove
ip link set dev eth0 xdp off

# Using bpftool
bpftool prog load icmp_drop.o /sys/fs/bpf/icmp_drop
bpftool net attach xdp pinned /sys/fs/bpf/icmp_drop dev eth0
```

---

## 4. TC BPF — qdisc-Level Programs

TC BPF runs at the `cls_bpf` classifier in the qdisc layer:

```bash
# Attach BPF program as tc classifier
tc qdisc add dev eth0 clsact
tc filter add dev eth0 ingress bpf da obj myfilter.o sec classifier
tc filter add dev eth0 egress  bpf da obj myfilter.o sec classifier
```

TC BPF sees full `sk_buff` (unlike XDP which sees raw frame). It can:
- Modify packet headers
- Set marks (`skb->mark`) for routing decisions
- Return `TC_ACT_SHOT` (drop) or `TC_ACT_OK` (pass)

---

## 5. BPF Verifier — Safety Guarantees

**Source:** `kernel/bpf/verifier.c`

Before running, every BPF program passes through the verifier:

```
Checks performed:
1. DAG check: no loops (ensures termination)
2. Instruction limit: max 1M instructions (prevents infinite loops)
3. Memory safety: all pointer accesses within valid bounds
   → must check (ptr + 1 <= data_end) before dereferencing
4. Stack depth limit: 512 bytes
5. Helper function calls: only allowed helpers for this program type
6. Return values: must return valid action code
```

This is why XDP programs always do:
```c
if ((void *)(eth + 1) > data_end)
    return XDP_PASS;   // verifier requires this bounds check
```

---

## 6. Observability with BPF

```bash
# bpftrace: one-liners for tracing (uses BPF internally)

# Trace all TCP connects with PID and destination
bpftrace -e 'kprobe:tcp_v4_connect { printf("%d -> %s\n", pid, comm); }'

# Count packets per TCP state transition
bpftrace -e 'kprobe:tcp_set_state { @[arg1] = count(); }'

# Histogram of TCP receive sizes
bpftrace -e 'kprobe:tcp_recvmsg { @size = hist(arg2); }'
```

---

## 7. 🗺️ Week 2 Full Review

```
Week 2 Topics:

Day 08: Socket Buffers & Memory
  sk_rcvbuf / sk_sndbuf → auto-tuning → memory pressure zones
  sk_stream_wait_memory() → blocked send → freed by reclaim

Day 09: Flow Control
  snd_wnd (receiver) vs snd_cwnd (congestion)
  Zero window → persist timer → window probe
  Delayed ACKs, SWS avoidance

Day 10: epoll
  eventpoll (rbtree + rdllist) → ep_poll_callback()
  Hooked into sk->sk_wq at epoll_ctl() time
  LT vs ET: ready list management

Day 11: UDP & Raw Sockets
  No state machine, no flow control, datagram-at-a-time
  sk_receive_queue overflow → silent drop
  Raw: IPPROTO_*, AF_PACKET bypass protocol handlers

Day 12: Network Namespaces & veth
  struct net: isolated stack per container
  veth: zero-copy peer→peer via netif_rx()
  Container networking = veth + bridge + iptables NAT

Day 13: Traffic Control (qdisc)
  dev_queue_xmit → qdisc enqueue/dequeue → ndo_start_xmit
  pfifo_fast (default), TBF (rate limit), HTB (hierarchy), netem (testing)

Day 14: eBPF / XDP
  Kernel-verifiable programs at hook points
  XDP: before sk_buff, at driver level
  TC BPF: qdisc level with full sk_buff access
```

---

## 8. Hands-On

### 8a. Explore BPF programs loaded on your system
```bash
# List all loaded BPF programs
bpftool prog list 2>/dev/null || sudo bpftool prog list

# List BPF maps
bpftool map list 2>/dev/null

# Show programs attached to network interfaces
bpftool net list 2>/dev/null
```

### 8b. Install BPF tracing tools
```bash
# Install bpftrace (if not present)
which bpftrace || apt-get install -y bpftrace 2>/dev/null

# Simple trace: count syscalls by name
bpftrace -e 'tracepoint:syscalls:sys_enter_* { @[probe] = count(); }' \
    -c "sleep 2" 2>/dev/null | head -20
```

### 8c. Check XDP support
```bash
# Does your NIC driver support XDP?
ethtool -i eth0 2>/dev/null | grep driver
# Check kernel config
zcat /proc/config.gz 2>/dev/null | grep BPF || \
    grep BPF /boot/config-$(uname -r) 2>/dev/null | grep "=y" | head -10
```

### 8d. Read XDP hook in kernel
```bash
grep -n "xdp_do_generic_rx\|bpf_prog_run_xdp\|do_xdp_generic" \
    ~/linux/net/core/dev.c | head -15
```

---

## 9. Week 2 Final Concept Check

1. When `send()` blocks because the write buffer is full, what event unblocks it? Trace the function chain.
2. Draw the `epoll` data structures: what lives in `eventpoll`, what is `epitem`, and how does `ep_poll_callback` link them when data arrives?
3. What is the difference between XDP and TC BPF in terms of where they run and what context they receive?
4. A container process calls `socket()`. How does the kernel ensure the new socket is in the container's network namespace, not the host's?
5. You add `netem delay 100ms` to `lo`. A subsequent `ping 127.0.0.1` shows ~200ms RTT. Why 200ms and not 100ms?

---

## Week 3 Preview

Next week: **Advanced Topics**
- Day 15: Zero-copy networking (`sendfile`, `splice`, `MSG_ZEROCOPY`)
- Day 16: Multi-queue NICs and RSS/RPS/RFS
- Day 17: TCP TIME_WAIT, connection reuse, `SO_REUSEPORT`
- Day 18: TLS in the kernel (`kTLS`)
- Day 19: ARP, neighbor subsystem, and the link layer
- Day 20: Routing internals: FIB, policy routing, ECMP
- Day 21: Week 3 review + performance tuning cheatsheet

## 📚 References
- `kernel/bpf/verifier.c` — BPF safety verification
- `net/core/dev.c` — XDP integration
- `net/core/filter.c` — BPF for sockets
- `include/linux/bpf.h` — BPF types and constants
- `include/uapi/linux/if_xdp.h` — XDP user API
- Kernel docs: `Documentation/bpf/`
