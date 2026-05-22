# Day 17 — TCP `TIME_WAIT`, Connection Reuse, and Port Exhaustion
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 3)

---

## 🎯 Goal
Understand why `TIME_WAIT` exists, how it's implemented in the kernel, the dangers of bypassing it, and the right tools for handling high connection rates.

---

## 1. Why `TIME_WAIT` Exists

After a TCP connection closes, the active closer enters `TIME_WAIT` for **2 × MSL** (Maximum Segment Lifetime, default 60s → 2MSL = 120s).

**Two reasons:**

**Reason 1: Ensure the final ACK is delivered**
```
Active closer (us)             Passive closer (peer)
      │                               │
  FIN_WAIT2                           │
      │←── FIN ───────────────────────│ LAST_ACK
      │─── ACK ──────────────────────►│
      │                               │ (closed)
  TIME_WAIT
      │
  (wait 2MSL in case ACK was lost and peer retransmits FIN)
      │
  CLOSED
```

If the ACK is lost, the peer retransmits FIN. We're still in `TIME_WAIT` → we re-send the ACK. Without `TIME_WAIT`, we'd RST the retransmitted FIN.

**Reason 2: Prevent old packets from contaminating new connections**
```
Old connection: (10.0.0.1:5000 → 10.0.0.2:80), seq 1000..2000
[connection closed]
New connection: same 4-tuple reused immediately
Old duplicate packet (seq 1500) arrives → looks like valid new data!
TIME_WAIT for 2MSL ensures all old packets expired before reuse.
```

---

## 2. `TIME_WAIT` in the Kernel

**Source:** `net/ipv4/tcp_minisocks.c`

`TIME_WAIT` uses a **lightweight** `tcp_timewait_sock` instead of a full `tcp_sock`:

```c
struct tcp_timewait_sock {
    struct inet_timewait_sock tw_sk;  // common TW fields
    u32    tw_rcv_nxt;     // next expected sequence
    u32    tw_snd_nxt;     // our next sequence number
    u32    tw_rcv_wnd;     // receive window
    u32    tw_ts_recent;   // last timestamp seen
    /* NO send/receive queues, no congestion state */
};

struct inet_timewait_sock {
    struct sock_common  __tw_common;
    int                 tw_timeout;   // 2MSL timer
    volatile unsigned char tw_substate; // TCP_TIME_WAIT or TCP_FIN_WAIT2
    unsigned char       tw_rcv_wscale;
    __be16              tw_sport;
    __u32               tw_bound_dev_if;
    struct inet_bind_bucket *tw_tb;
    struct timer_list   tw_timer;     // fires after 2MSL → TCP_CLOSE
};
```

**Memory savings:** `tcp_timewait_sock` ≈ 128 bytes vs `tcp_sock` ≈ 1.5KB.

### Creating a `TIME_WAIT` socket
```c
/* net/ipv4/tcp_minisocks.c */
void tcp_time_wait(struct sock *sk, int state, int timeo)
{
    struct tcp_timewait_sock *tcptw;
    struct inet_timewait_sock *tw;

    /* Allocate lightweight TIME_WAIT sock */
    tw = inet_twsk_alloc(sk, &tcp_death_row, state);
    tcptw = tcp_twsk((struct sock *)tw);

    /* Copy minimal state from full socket */
    tcptw->tw_rcv_nxt = tp->rcv_nxt;
    tcptw->tw_snd_nxt = tp->snd_nxt;

    /* Start 2MSL timer */
    inet_twsk_schedule(tw, timeo);

    /* Now close the full socket — TIME_WAIT sock takes over */
    inet_csk_destroy_sock(sk);
}
```

---

## 3. Handling Packets in `TIME_WAIT`

**Source:** `net/ipv4/tcp_minisocks.c` (`tcp_timewait_state_process`)

```c
enum tcp_tw_status
tcp_timewait_state_process(struct inet_timewait_sock *tw,
                            struct sk_buff *skb,
                            const struct tcphdr *th)
{
    /* RST received → kill TIME_WAIT immediately */
    if (th->rst)
        goto kill;

    /* SYN received with higher seq → allow new connection */
    if (th->syn && !th->rst && !th->ack && !th->fin &&
        after(TCP_SKB_CB(skb)->seq, tcptw->tw_rcv_nxt)) {
        /* New connection can reuse this 4-tuple */
        return TCP_TW_SYN;
    }

    /* Duplicate FIN → re-send ACK, restart 2MSL timer */
    if (th->fin)
        inet_twsk_reschedule(tw, TCP_TIMEWAIT_LEN);

    /* Any valid data packet → send ACK */
    return TCP_TW_ACK;

kill:
    inet_twsk_deschedule_put(tw);
    return TCP_TW_SUCCESS;
}
```

---

## 4. Port Exhaustion

On a client making many short-lived connections to the same server:

```
4-tuple: (client_ip, client_port, server_ip, server_port)
server_ip and server_port are fixed
client_ip is fixed (usually)
→ only client_port varies: 1024..65535 = ~64,000 ports

If TIME_WAIT lasts 120s and you do 1000 connections/sec:
120,000 TIME_WAIT sockets → exhausted in ~64 seconds!
```

Check with:
```bash
ss -tan state time-wait | wc -l
```

---

## 5. Solutions to `TIME_WAIT` / Port Exhaustion

### `SO_REUSEADDR` — Allow reuse of local address
```c
setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
/* Server: allows binding to a port still in TIME_WAIT */
/* Client: allows reusing local address after quick close */
```

Kernel check:
```c
/* net/ipv4/inet_connection_sock.c */
/* If SO_REUSEADDR set AND tw sock in TIME_WAIT:
   allow bind if not exact 4-tuple collision */
```

### `tcp_tw_reuse` — Reuse `TIME_WAIT` sockets for new connections
```bash
sysctl net.ipv4.tcp_tw_reuse   # default 2 (safe reuse with timestamps)
# 0 = disabled
# 1 = always reuse
# 2 = reuse only for loopback (default since 4.19)
```

Kernel logic:
```c
/* net/ipv4/tcp_ipv4.c - tcp_v4_connect() */
/* If tcp_tw_reuse=1 AND TCP timestamps enabled:
   can reuse a TIME_WAIT 4-tuple because timestamps
   prevent old packet confusion (PAWS: Protection Against Wrapped Sequences) */
```

**Why timestamps make reuse safe:**
```
Each segment carries timestamp. Old segments from previous connection
have lower timestamps. New connection's PAWS check drops them.
```

### Increase local port range
```bash
sysctl net.ipv4.ip_local_port_range
# default: 32768 60999 = ~28,000 ports

# Expand to full range
sysctl -w net.ipv4.ip_local_port_range="1024 65535"
```

### `tcp_fin_timeout` — Shorten `FIN_WAIT2`
```bash
# FIN_WAIT2 timeout (not the same as TIME_WAIT!)
sysctl net.ipv4.tcp_fin_timeout
# default 60s — reduce to 15s for busy servers
```

### Use persistent connections (best solution)
```
Instead of open-send-close per request:
→ HTTP/1.1 Keep-Alive, HTTP/2, connection pools
→ eliminates TIME_WAIT entirely for that workload
```

---

## 6. `tcp_death_row` — Managing TIME_WAIT at Scale

**Source:** `net/ipv4/tcp_minisocks.c`

```c
struct inet_timewait_death_row tcp_death_row = {
    .sysctl_max_tw_buckets = NR_FILE * 2,
    /* Default max: 262144 TIME_WAIT sockets */
};
```

```bash
# Current TIME_WAIT count
ss -s | grep "timewait"

# Max allowed
sysctl net.ipv4.tcp_max_tw_buckets
# If exceeded: TIME_WAIT sockets destroyed early (warning in dmesg)
```

---

## 7. Hands-On

### 7a. Observe TIME_WAIT in action
```bash
# Make a connection and close it
curl -s http://httpbin.org/get > /dev/null 2>&1

# See TIME_WAIT sockets
ss -tan state time-wait | head -10

# Count by state
ss -tan | awk '{print $1}' | sort | uniq -c | sort -rn
```

### 7b. Simulate port exhaustion (safe, local only)
```bash
# Show current ephemeral port range
cat /proc/sys/net/ipv4/ip_local_port_range

# Count current TIME_WAITs per remote port
ss -tan state time-wait | awk '{print $5}' | \
    awk -F: '{print $NF}' | sort | uniq -c | sort -rn | head -10
```

### 7c. Test SO_REUSEADDR
```python
# Test that SO_REUSEADDR allows quick server restart
import socket, time

s1 = socket.socket()
s1.bind(('127.0.0.1', 19999))
s1.listen(1)
print("First server bound")
s1.close()

# Without SO_REUSEADDR this might fail if connection was established
s2 = socket.socket()
s2.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s2.bind(('127.0.0.1', 19999))
s2.listen(1)
print("Second server bound with SO_REUSEADDR: OK")
s2.close()
```

### 7d. Read TIME_WAIT implementation
```bash
grep -n "tcp_time_wait\|TCP_TIMEWAIT_LEN\|tw_timer" \
    ~/linux/net/ipv4/tcp_minisocks.c | head -20

grep -n "tcp_tw_reuse\|TCP_TW_SYN" \
    ~/linux/net/ipv4/tcp_ipv4.c | head -15
```

---

## 8. Concept Check

1. Why is the `TIME_WAIT` duration 2×MSL and not just 1×MSL?
2. How does enabling TCP timestamps (`tcp_timestamps`) make `tcp_tw_reuse` safe? What mechanism prevents old packets from being accepted?
3. A server restarts and `bind()` fails with `EADDRINUSE` immediately. What option fixes this and why?
4. A client machine does 1000 short HTTP connections/second to one server. Calculate how many `TIME_WAIT` sockets exist at steady state with default 60s timeout.

---

## 📚 References
- `net/ipv4/tcp_minisocks.c` — `TIME_WAIT` management
- `net/ipv4/tcp.c` — close sequence
- `net/ipv4/tcp_ipv4.c` — `tcp_tw_reuse` logic
- `include/net/inet_timewait_sock.h` — `inet_timewait_sock`
- RFC 793 §3.5 — closing a connection
- RFC 1337 — TIME_WAIT assassination hazards
