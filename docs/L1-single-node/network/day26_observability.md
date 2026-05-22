# Day 26 — Kernel Networking Observability: perf, ftrace, bpftrace
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 4)

---

## 🎯 Goal
Build a practical toolkit for observing the Linux network stack at runtime — from high-level counters to function-level tracing and latency histograms.

---

## 1. Observability Layers

```
Layer                  Tool                    Resolution
─────────────────────────────────────────────────────────
Application            strace, ltrace          syscall level
Socket counters        ss, /proc/net/snmp      per-socket / global
Interface stats        ip -s, ethtool -S       per-NIC queue
Kernel functions       ftrace, kprobes         per-function call
CPU + cache            perf stat, perf record  hardware counters
Custom tracing         bpftrace, BCC           arbitrary kernel state
```

---

## 2. `/proc/net` — The Fastest Counters

```bash
# TCP global counters (RFC-named)
cat /proc/net/snmp | grep "^Tcp"

# Extended TCP counters (Linux-specific)
cat /proc/net/netstat | tr '\t' '\n' | paste - - | column -t | head -40

# UDP counters
cat /proc/net/snmp | grep "^Udp"

# IP counters
cat /proc/net/snmp | grep "^Ip"

# Per-socket TCP state
cat /proc/net/tcp    # hex format: local/remote addr:port, state, uid

# Active sockets (human-readable)
ss -tin state established
ss -s   # summary
```

### Key counters to watch
```bash
# Parse and watch critical TCP metrics
watch -n1 'cat /proc/net/snmp | grep "^Tcp" | tr "\t" "\n" | \
    grep -E "RetransSegs|InErrs|OutRsts|AttemptFails|CurrEstab"'

# Extended: drops, ofo queue, zero windows
cat /proc/net/netstat | tr '\t' '\n' | paste - - | \
    grep -E "TCPLoss|TCPRetrans|TCPOFOQueue|TCPZeroWindow|TCPBacklog"
```

---

## 3. `ss` Deep Dive

```bash
# Full TCP internal state per socket
ss -tin state established

# Key fields explained:
# cubic cwnd:10        → congestion window = 10 MSS
# ssthresh:7           → slow start threshold
# bytes_sent:1234      → bytes sent total
# bytes_retrans:0      → bytes retransmitted
# bytes_acked:1234     → bytes ACKed by peer
# bytes_received:5678  → bytes received from peer
# segs_out:12          → segments sent
# segs_in:11           → segments received
# data_segs_out:8      → data segments sent
# send 1.0Mbps         → estimated send rate
# lastsnd:100          → ms since last send
# lastrcv:100          → ms since last receive
# lastack:50           → ms since last ACK received
# pacing_rate 1.2Mbps  → pacing rate (if set)
# delivery_rate 0.9Mbps → delivered data rate
# delivered:7          → segments delivered to receiver
# busy:100ms           → time socket was busy
# unacked:2            → unACKed segments
# retrans:0/0          → retransmits (current/total)
# rcv_space:43690      → receive window offered
# rcv_ssthresh:43690
# minrtt:0.8           → minimum observed RTT (ms)

# Filter by state
ss -tn state time-wait | wc -l
ss -tn state syn-sent
ss -tn state close-wait

# Filter by port
ss -tin '( sport = :80 or dport = :80 )'

# Watch connections to a host
watch -n1 "ss -tin 'dst 8.8.8.8'"
```

---

## 4. `nstat` — Structured Counter Diffs

```bash
# Install
apt-get install -y iproute2 2>/dev/null

# Show all non-zero kernel net counters
nstat -az

# Show diff since last call (like netstat -s but cleaner)
nstat

# Watch specific counter
watch -n1 'nstat | grep -E "TcpRetrans|IpInDiscards|TcpLoss"'

# Reset baseline
nstat -n
```

---

## 5. `ftrace` — Function-Level Tracing

**Source:** `kernel/trace/`

```bash
# Enable ftrace (tracefs usually at /sys/kernel/tracing)
mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null
cd /sys/kernel/tracing

# Trace specific function calls
echo 'tcp_v4_rcv' > set_ftrace_filter
echo 'function' > current_tracer
echo 1 > tracing_on
sleep 1
echo 0 > tracing_on
cat trace | head -30

# Function graph: show call tree with timing
echo 'ip_rcv' > set_graph_function
echo 'function_graph' > current_tracer
echo 1 > tracing_on
sleep 0.1
echo 0 > tracing_on
cat trace | head -50

# Reset
echo '' > set_ftrace_filter
echo 'nop' > current_tracer
echo > trace
```

### Trace events (structured tracing)
```bash
# List available network trace events
ls /sys/kernel/tracing/events/net/
ls /sys/kernel/tracing/events/tcp/
ls /sys/kernel/tracing/events/sock/

# Enable TCP state change event
echo 1 > /sys/kernel/tracing/events/tcp/tcp_set_state/enable
echo 1 > /sys/kernel/tracing/events/net/net_dev_xmit/enable
echo 1 > /sys/kernel/tracing/events/net/netif_receive_skb/enable

echo 1 > /sys/kernel/tracing/tracing_on
sleep 1
echo 0 > /sys/kernel/tracing/tracing_on
cat /sys/kernel/tracing/trace | head -40

# Disable all
echo 0 > /sys/kernel/tracing/events/enable
```

---

## 6. `perf` — CPU and Cache Analysis

```bash
# Flamegraph for network receive path
# 1. Record while running network workload
perf record -g -a -e cycles sleep 5

# 2. Generate report
perf report --stdio | head -50

# Per-function CPU time in kernel net path
perf top -e cycles:k --sort=dso,symbol | head -30

# Count specific events during iperf
perf stat -e \
    cache-misses,cache-references,\
    context-switches,cpu-migrations,\
    net:net_dev_xmit,net:netif_receive_skb \
    sleep 5 2>&1

# Trace retransmits with timestamps
perf trace -e tcp:tcp_retransmit_skb 2>/dev/null &
# Generate some packet loss with netem
sudo tc qdisc add dev lo root netem loss 5%
ping -c20 127.0.0.1 > /dev/null
sudo tc qdisc del dev lo root
kill %1 2>/dev/null
```

---

## 7. `bpftrace` — The Swiss Army Knife

```bash
# ONE-LINERS — copy and run these

# 1. Count new TCP connections per destination port
bpftrace -e '
kprobe:tcp_v4_connect {
    @connects[((struct sock *)arg0)->__sk_common.skc_dport] = count();
}
interval:s:5 { print(@connects); clear(@connects); }
' 2>/dev/null

# 2. Histogram of TCP receive sizes
bpftrace -e '
kprobe:tcp_recvmsg {
    @recv_size = hist(arg2);
}
interval:s:5 { print(@recv_size); exit(); }
' 2>/dev/null

# 3. Trace TCP state transitions
bpftrace -e '
tracepoint:tcp:tcp_set_state {
    printf("%s: %d -> %d\n", comm, args->oldstate, args->newstate);
}
' 2>/dev/null

# 4. Latency from send() to leaving the NIC (TX path)
bpftrace -e '
kprobe:tcp_sendmsg { @start[tid] = nsecs; }
kprobe:dev_queue_xmit /tid in @start/ {
    @latency = hist(nsecs - @start[tid]);
    delete(@start[tid]);
}
interval:s:5 { print(@latency); exit(); }
' 2>/dev/null

# 5. Find which processes are sending the most data
bpftrace -e '
kprobe:tcp_sendmsg {
    @bytes_sent[comm] = sum(arg2);
}
interval:s:5 { print(@bytes_sent); clear(@bytes_sent); }
' 2>/dev/null

# 6. Trace NAPI poll budget usage
bpftrace -e '
kretprobe:napi_poll {
    @work_done = hist(retval);
}
interval:s:5 { print(@work_done); exit(); }
' 2>/dev/null

# 7. Socket receive queue depth
bpftrace -e '
kprobe:tcp_recvmsg {
    $sk = (struct sock *)arg0;
    @queue_depth = hist($sk->sk_receive_queue.qlen);
}
interval:s:5 { print(@queue_depth); exit(); }
' 2>/dev/null

# 8. Retransmit events with PID and comm
bpftrace -e '
tracepoint:tcp:tcp_retransmit_skb {
    printf("PID=%d COMM=%s sport=%d dport=%d\n",
           pid, comm,
           args->sport, args->dport);
}
' 2>/dev/null
```

---

## 8. `ethtool` — NIC Hardware Diagnostics

```bash
# Driver and firmware info
ethtool -i eth0

# Link speed and negotiation
ethtool eth0

# NIC statistics (driver-specific)
ethtool -S eth0 | head -40

# Check offload features
ethtool -k eth0

# Ring buffer sizes (RX/TX descriptor count)
ethtool -g eth0

# Pause frames (flow control at L2)
ethtool -a eth0

# Interrupt coalescing (how many pkts/μs before IRQ fires)
ethtool -c eth0

# Set coalescing (trade latency for throughput)
# ethtool -C eth0 rx-usecs 50 tx-usecs 50
```

---

## 9. End-to-End Diagnosis Workflow

```bash
# Step 1: High-level symptom
ss -s
# → Too many TIME_WAIT? → Day 17
# → High retransmits? → check congestion control
# → Drops? → go to step 2

# Step 2: Where are drops happening?
cat /proc/net/softnet_stat    # → NIC ring or softirq backlog?
ethtool -S eth0 | grep drop   # → NIC hardware drops?
cat /proc/net/snmp | grep Udp # → UDP buffer drops?
nstat | grep Drop              # → general drops

# Step 3: CPU analysis
cat /proc/softirqs | grep NET  # → softirq imbalance?
cat /proc/interrupts | grep eth # → IRQ imbalance?
top → ksoftirqd CPU %           # → softirq overload?

# Step 4: Per-connection analysis
ss -tin state established       # → retransmits? low cwnd? zero window?

# Step 5: Function-level with bpftrace
# Use recipes from section 7 above
```

---

## 10. Concept Check

1. What does `time_squeeze` in `/proc/net/softnet_stat` indicate? How do you fix it?
2. You see `TCPRetransSegs` rising in `nstat`. How would you identify which connections are retransmitting and why?
3. A bpftrace one-liner shows TCP receive latency histogram has a long tail at 40ms for all connections. What's the most likely cause?
4. `ethtool -S eth0` shows `rx_missed_errors` growing. What layer is dropping packets and how do you fix it?

---

## 📚 References
- `kernel/trace/` — ftrace implementation
- `/sys/kernel/tracing/` — ftrace interface
- `tools/bpf/` — BPF tools
- `bpftrace` — https://github.com/iovisor/bpftrace
- BCC tools: `tcplife`, `tcpretrans`, `tcpconnect`, `netstat` (BCC version)
- Brendan Gregg's networking performance pages: http://www.brendangregg.com/linuxperf.html
- Kernel docs: `Documentation/trace/ftrace.rst`
