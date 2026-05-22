# Day 11 — UDP and Raw Sockets
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 2)

---

## 🎯 Goal
Understand how UDP differs from TCP in the kernel, how `sendto`/`recvfrom` work, and how raw sockets give direct access to IP/Ethernet frames.

---

## 1. UDP vs TCP in the Kernel

| Aspect | TCP | UDP |
|---|---|---|
| Kernel struct | `struct tcp_sock` | `struct udp_sock` |
| State machine | Complex (11 states) | Almost none |
| Receive queue | `sk_receive_queue` (ordered) | `sk_receive_queue` (datagrams) |
| Transmit queue | `sk_write_queue` (retransmit) | None — send immediately |
| Flow control | Yes (rwnd/cwnd) | No |
| Fragmentation | TCP segmentation | IP fragmentation |
| Header | `struct tcphdr` (20+ bytes) | `struct udphdr` (8 bytes) |

UDP is essentially: **IP + port multiplexing + checksum. That's it.**

---

## 2. UDP Header and Socket

**Source:** `include/linux/udp.h`, `include/net/udp.h`

```c
struct udphdr {
    __be16  source;   // source port
    __be16  dest;     // destination port
    __be16  len;      // UDP header + data length
    __sum16 check;    // checksum (optional for IPv4)
};

struct udp_sock {
    struct inet_sock inet;     // embeds struct sock
    int       pending;         // cork: pending data
    unsigned int corkflag;     // UDP_CORK setsockopt
    __u8      encap_type;      // VXLAN/GRE encapsulation
    __u16     len;             // total length being corked
    /* ... */
};
```

---

## 3. UDP Receive Path

**Source:** `net/ipv4/udp.c`

```
ip_local_deliver_finish()
  └── udp_rcv(skb)                   ← registered as IPPROTO_UDP handler
        └── __udp4_lib_rcv(skb, &udp_table, AF_INET)
              ├── validate UDP header, checksum
              ├── lookup socket: __udp4_lib_lookup()
              │     hash table keyed on (dst_port, [dst_ip, src_ip, src_port])
              └── udp_unicast_rcv_skb()
                    └── udp_queue_rcv_skb(sk, skb)
                          ├── check sk->sk_rcvbuf not exceeded
                          ├── __skb_queue_tail(&sk->sk_receive_queue, skb)
                          └── sk->sk_data_ready(sk)  ← wake recvfrom()
```

**Key difference from TCP:** UDP enqueues the entire datagram as a single `sk_buff`. There's no reassembly of sequence numbers.

### UDP hash table lookup
```c
/* udp_table has two hash tables: */
/* 1. hslot:  hash on destination port only (for unconnected sockets) */
/* 2. hslot2: hash on (src_addr, src_port, dst_addr, dst_port) */

static struct sock *__udp4_lib_lookup(...)
{
    /* Try 4-tuple match first (connected socket), then 2-tuple */
    result = udp4_lib_lookup2(net, saddr, sport, daddr, hnum, dif, ...);
    if (!result)
        result = udp4_lib_lookup1(net, daddr, hnum, dif, ...);
    return result;
}
```

---

## 4. `recvfrom()` for UDP

```c
recvfrom(fd, buf, len, flags, src_addr, addrlen)
  └── udp_recvmsg(sk, msg, len, flags, addr_len)
        ├── skb = __skb_recv_udp(sk, flags, &err)
        │     └── __skb_try_recv_from_queue(&sk->sk_receive_queue, ...)
        │           or sk_wait_data(sk, &timeo, NULL)  // block if empty
        ├── copy datagram: skb_copy_datagram_msg(skb, 0, msg, copied)
        ├── if MSG_TRUNC: return actual datagram length (may be > len)
        └── fill src_addr (sender's IP:port from IP/UDP header)
```

**Critical UDP behavior:** If `len` is smaller than the datagram, the excess is **silently discarded** (unlike TCP which keeps it for the next read).

---

## 5. UDP Transmit Path

```c
sendto(fd, buf, len, 0, dst_addr, addrlen)
  └── udp_sendmsg(sk, msg, len)
        ├── routing: ip_route_output_flow()
        ├── build UDP header (pushed into skb headroom)
        │     th->source = inet->inet_sport
        │     th->dest   = usin->sin_port
        │     th->len    = htons(ulen)
        │     udp4_hwcsum() or udp_set_csum()
        └── ip_send_skb(net, skb)
              └── ip_local_out() → ip_output() → dev_queue_xmit()
```

### UDP Cork (`MSG_MORE` / `UDP_CORK`)
```c
/* Accumulate multiple sendmsg() calls into one UDP datagram */
setsockopt(fd, SOL_UDP, UDP_CORK, &on, sizeof(on));
sendmsg(fd, ...);   // data queued
sendmsg(fd, ...);   // more data queued
setsockopt(fd, SOL_UDP, UDP_CORK, &off, sizeof(off)); // flush → one datagram
```

---

## 6. UDP Buffer Overflow

Unlike TCP, UDP has **no flow control**. If the receive buffer is full:

```c
udp_queue_rcv_skb(sk, skb)
  └── if (sk_rcvqueues_full(sk, sk->sk_rcvbuf)):
        /* Drop the datagram! */
        UDP_INC_STATS(net, UDP_MIB_RCVBUFERRORS, ...);
        UDP_INC_STATS(net, UDP_MIB_INERRORS, ...);
        kfree_skb(skb);
        return -1;
```

```bash
# Check UDP receive buffer overflows
cat /proc/net/snmp | grep "^Udp"
# RcvbufErrors = datagrams dropped due to full receive buffer
```

---

## 7. Raw Sockets

**Source:** `net/ipv4/raw.c`

Raw sockets bypass TCP/UDP and give access to raw IP packets.

```c
/* Creating a raw socket */
int fd = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
// or IPPROTO_TCP, IPPROTO_RAW (build entire IP header yourself)
```

### Raw socket receive path
```c
/* ip_local_deliver_finish() delivers to raw sockets BEFORE protocol handlers */
raw_local_deliver(skb, protocol)
  └── for each raw socket matching protocol:
        raw_rcv(sk, skb)
          └── skb_queue_tail(&sk->sk_receive_queue, skb_clone)
                /* clone: original continues to TCP/UDP handler */
```

### Raw socket types

**`IPPROTO_ICMP` — ICMP raw socket**
```c
/* Used by ping(1) */
/* Kernel builds IP header, you build ICMP header */
struct icmphdr {
    __u8  type;   // ICMP_ECHO = 8, ICMP_ECHOREPLY = 0
    __u8  code;
    __sum16 checksum;
    __be16 id;
    __be16 sequence;
};
```

**`IPPROTO_RAW` — build entire IP header**
```c
/* IP_HDRINCL option: you provide full IP header */
setsockopt(fd, IPPROTO_IP, IP_HDRINCL, &one, sizeof(one));
/* Now sendto() sends exactly what you put in the buffer */
/* Useful for: custom protocols, network tools, packet crafting */
```

**Packet socket — Ethernet-level access**
```c
/* socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL)) */
/* Receives ALL frames including Ethernet header */
/* Used by: tcpdump, wireshark, arping */
```

---

## 8. Hands-On

### 8a. UDP stats
```bash
cat /proc/net/snmp | grep "^Udp"
# InDatagrams, NoPorts, InErrors, OutDatagrams, RcvbufErrors, SndbufErrors

cat /proc/net/udp    # active UDP sockets
```

### 8b. Observe UDP socket buffer
```bash
# UDP receive buffer drops
watch -n1 'cat /proc/net/snmp | grep Udp'

# Increase UDP receive buffer
sysctl net.core.rmem_max
sysctl net.core.rmem_default
```

### 8c. Simple UDP test
```bash
# Terminal 1: listen
nc -u -l 9999

# Terminal 2: send
echo "hello udp" | nc -u 127.0.0.1 9999

# Watch in ss
ss -unp
```

### 8d. Raw socket: ping implementation sketch
```python
# Conceptual ping (requires root)
import socket, struct, time

# Create ICMP raw socket
s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)

# Build ICMP echo request
def build_icmp_echo(seq):
    header = struct.pack('bbHHh', 8, 0, 0, os.getpid() & 0xFFFF, seq)
    data = b'ping-data-here'
    checksum = compute_checksum(header + data)
    return struct.pack('bbHHh', 8, 0, checksum, os.getpid() & 0xFFFF, seq) + data

# s.sendto(build_icmp_echo(1), ('8.8.8.8', 0))
print("Raw socket fd:", s.fileno())
s.close()
```

### 8e. Read raw socket receive path
```bash
grep -n "raw_local_deliver\|raw_rcv\b" ~/linux/net/ipv4/raw.c | head -15
```

---

## 9. Concept Check

1. What happens to a UDP datagram if `recvfrom()` provides a buffer smaller than the datagram? How does TCP differ?
2. Why is UDP's receive queue simpler than TCP's? What does it not need to track?
3. How does a raw socket with `IPPROTO_ICMP` interact with the normal ICMP handler? Do they conflict?
4. What is the `AF_PACKET` socket family used for, and how low in the stack does it operate?

---

## 📚 References
- `net/ipv4/udp.c` — `udp_rcv`, `udp_sendmsg`, `udp_recvmsg`
- `net/ipv4/raw.c` — raw socket implementation
- `include/linux/udp.h` — `struct udphdr`
- `include/net/udp.h` — `struct udp_sock`
- `net/packet/af_packet.c` — `AF_PACKET` implementation
