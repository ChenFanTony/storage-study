# Day 25 — Kernel Bypass: DPDK Concepts and AF_XDP
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 4)

---

## 🎯 Goal
Understand why kernel bypass exists, how DPDK bypasses the kernel entirely, and how AF_XDP provides a kernel-assisted zero-copy path that bridges XDP and userspace.

---

## 1. Why Kernel Bypass?

At very high packet rates (10M+ pps on 10G/100G NICs), even a lean kernel network stack has overhead:

```
Per-packet kernel overhead:
  Hard IRQ handling:       ~1μs
  Softirq scheduling:      ~0.5μs
  sk_buff allocation:      ~0.2μs
  Routing/socket lookup:   ~0.5μs
  Context switch (syscall):~1μs
  Total: ~3-4μs per packet

At 10M pps: 30-40 CPU cores just for network I/O overhead!
```

**Solution:** Skip the kernel entirely and have userspace talk directly to NIC hardware.

---

## 2. DPDK — Data Plane Development Kit

DPDK is not a kernel feature — it's a **userspace framework** that uses kernel support primitives:

### Core mechanism: UIO / VFIO
```
Normal:  NIC → kernel driver → sk_buff → socket → userspace
DPDK:    NIC → UIO/VFIO driver (minimal) → userspace memory pool
                                           ↑
                               mmap'd DMA-capable memory
                               directly accessible by userspace
```

```c
/* DPDK pseudo-code: polling the NIC in userspace */
while (running) {
    /* Poll RX ring directly (no interrupt, no syscall) */
    nb_rx = rte_eth_rx_burst(port_id, queue_id,
                              pkts_burst, MAX_PKT_BURST);

    for (int i = 0; i < nb_rx; i++) {
        struct rte_mbuf *m = pkts_burst[i];
        /* Access packet: rte_pktmbuf_mtod(m, void *) */
        process_packet(m);
        rte_pktmbuf_free(m);
    }
}
```

### DPDK key concepts
```
rte_mbuf:      DPDK's equivalent of sk_buff
               pre-allocated from huge-page memory pool (rte_mempool)

Huge pages:    2MB/1GB pages mapped into userspace
               → no TLB pressure
               → NIC DMA directly into userspace pages

PMD:           Poll Mode Driver — userspace driver (igb, ixgbe, mlx5)
               replaces kernel driver entirely
               NIC registers mmap'd into userspace

No IRQ:        Pure polling loop — CPU spins on ring buffer
               → ~0 latency variance, max throughput
               → wastes CPU (dedicated core needed)
```

### What DPDK bypasses
```
Bypassed:       sk_buff allocation/free
                Kernel interrupt handling
                Softirq / NAPI
                Routing, netfilter
                Socket layer
                All syscall overhead

Not bypassed:   Physical hardware (NIC still does DMA)
                Kernel boot (UIO/VFIO drivers still loaded)
                Kernel memory allocator (huge pages setup)
```

---

## 3. AF_XDP — Zero-Copy with Kernel Assistance

**Source:** `net/xdp/`, `include/uapi/linux/if_xdp.h`

AF_XDP is a Linux socket type that provides near-DPDK performance while keeping the NIC driver in the kernel. It's the kernel's answer to DPDK.

```
NIC → kernel driver → XDP program → AF_XDP socket → userspace
                           ↑
                    Instead of: → netif_receive_skb → full stack
```

### The UMEM — Userspace Memory

AF_XDP requires the application to provide a **UMEM** (User Memory region):

```c
/* Userspace allocates a large buffer registered with the kernel */
void *umem_area = mmap(NULL, UMEM_SIZE,
                        PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);

/* Register UMEM with kernel */
struct xdp_umem_reg umem_reg = {
    .addr = (uint64_t)umem_area,
    .len  = UMEM_SIZE,
    .chunk_size = FRAME_SIZE,     // e.g., 4096 bytes per frame
    .headroom   = FRAME_HEADROOM, // e.g., 256 bytes
};
setsockopt(xsk_fd, SOL_XDP, XDP_UMEM_REG, &umem_reg, sizeof(umem_reg));
```

The UMEM is divided into **frames** of fixed size. Addresses are offsets into the UMEM, not pointers.

---

### Four Rings: The AF_XDP Interface

```c
/* Four rings connect userspace ↔ kernel for each AF_XDP socket: */

/* RX Ring: kernel writes received frame addresses here */
struct xsk_ring_cons rx_ring;   /* consumer: userspace reads */

/* TX Ring: userspace writes frame addresses to transmit */
struct xsk_ring_prod tx_ring;   /* producer: userspace writes */

/* FILL Ring: userspace gives frames to kernel for RX */
struct xsk_ring_prod fill_ring; /* producer: userspace refills */

/* COMPLETION Ring: kernel signals TX-complete frames */
struct xsk_ring_cons comp_ring; /* consumer: userspace reclaims */
```

### RX data flow
```
1. Userspace writes UMEM frame offsets into FILL ring
   (giving kernel free buffers to DMA into)

2. NIC DMA's received packet into a FILL ring frame
   (driver writes directly into UMEM — zero copy!)

3. XDP program on NIC port returns XDP_REDIRECT → AF_XDP socket
   Kernel writes frame offset + length into RX ring

4. Userspace reads RX ring:
   uint64_t addr = xsk_ring_cons__rx_desc(&rx, idx)->addr;
   uint32_t len  = xsk_ring_cons__rx_desc(&rx, idx)->len;
   void *pkt = xsk_umem__get_data(umem_area, addr);
   /* Process pkt[0..len] — zero copy! */

5. Return frame to FILL ring for reuse
```

### TX data flow
```
1. Userspace writes packet into a UMEM frame
2. Writes frame offset into TX ring
3. Kernel reads TX ring, DMA's frame to NIC
4. NIC signals completion → kernel writes offset to COMPLETION ring
5. Userspace reclaims frame from COMPLETION ring
```

---

## 4. AF_XDP Code Sketch

```c
/* Minimal AF_XDP receiver (conceptual) */
#include <linux/if_xdp.h>
#include <sys/socket.h>

int main(void)
{
    /* 1. Allocate UMEM */
    void *umem_area = mmap(NULL, UMEM_SIZE, PROT_READ|PROT_WRITE,
                            MAP_PRIVATE|MAP_ANONYMOUS|MAP_HUGETLB, -1, 0);

    /* 2. Create AF_XDP socket */
    int fd = socket(AF_XDP, SOCK_RAW, 0);

    /* 3. Register UMEM */
    setsockopt(fd, SOL_XDP, XDP_UMEM_REG, &umem_reg, sizeof(umem_reg));

    /* 4. Create rings (mmap them) */
    /* Fill, Completion, RX, TX rings via mmap with XDP_* offsets */

    /* 5. Bind to NIC queue */
    struct sockaddr_xdp addr = {
        .sxdp_family   = AF_XDP,
        .sxdp_ifindex  = if_nametoindex("eth0"),
        .sxdp_queue_id = 0,
        .sxdp_flags    = XDP_ZEROCOPY,  /* or XDP_COPY */
    };
    bind(fd, (struct sockaddr *)&addr, sizeof(addr));

    /* 6. Pre-fill the FILL ring with free frames */
    for (int i = 0; i < NUM_FRAMES; i++) {
        *xsk_ring_prod__fill_addr(&fill_ring, idx++) = i * FRAME_SIZE;
    }
    xsk_ring_prod__submit(&fill_ring, NUM_FRAMES);

    /* 7. Poll for received packets */
    while (1) {
        poll(&pfd, 1, -1);  /* or busy-poll with recvfrom() */

        uint32_t rcvd = xsk_ring_cons__peek(&rx_ring, BATCH_SIZE, &idx);
        for (uint32_t i = 0; i < rcvd; i++) {
            const struct xdp_desc *d = xsk_ring_cons__rx_desc(&rx_ring, idx+i);
            void *pkt = (void *)((uint64_t)umem_area + d->addr);
            uint32_t len = d->len;
            process(pkt, len);
            /* Return frame to fill ring */
            *xsk_ring_prod__fill_addr(&fill_ring, fill_idx++) = d->addr;
        }
        xsk_ring_cons__release(&rx_ring, rcvd);
    }
}
```

---

## 5. DPDK vs AF_XDP vs Standard Stack

| | Standard | AF_XDP | DPDK |
|---|---|---|---|
| NIC driver | Kernel | Kernel | Userspace PMD |
| Copy count | 2 (DMA→kernel, kernel→user) | 0 | 0 |
| Interrupt model | IRQ → softirq | Optional | Pure poll |
| Stack overhead | Full kernel stack | XDP + rings | None |
| Routing/FW support | Yes | No (raw frames) | App must implement |
| Ease of use | Easy | Medium | Hard |
| Peak throughput | ~2M pps/core | ~10M pps/core | ~20M+ pps/core |
| Use case | General | NFV/firewall/LB | Line-rate packet processing |

---

## 6. Hands-On

### 6a. Check AF_XDP support
```bash
# Kernel config
grep "AF_XDP\|XDP_SOCKET" /boot/config-$(uname -r) 2>/dev/null

# Check if NIC supports zero-copy XDP
ethtool -i eth0 2>/dev/null
# Drivers with XDP zero-copy: mlx5, i40e, ixgbe, ice, ena

# Check XDP support on interface
ip link show eth0 | grep xdp
```

### 6b. XDP redirect to AF_XDP (concept)
```bash
# Load XDP program that redirects to AF_XDP socket
# (requires bpftool and an XDP program)
ls ~/linux/samples/bpf/ | grep xsk 2>/dev/null

# xdpsock sample is the canonical AF_XDP example
ls ~/linux/tools/testing/selftests/bpf/ | grep xsk 2>/dev/null
```

### 6c. Inspect kernel AF_XDP structures
```bash
grep -rn "struct xdp_umem\|struct xsk_queue\|XDP_UMEM_REG" \
    ~/linux/include/net/xdp_sock.h \
    ~/linux/include/uapi/linux/if_xdp.h 2>/dev/null | head -20

ls ~/linux/net/xdp/
```

### 6d. perf: observe copy overhead in standard path
```bash
# How much time spent in copy_from_user / copy_to_user for network
perf top -e cache-misses 2>/dev/null &
# Generate network traffic (iperf, curl)
sleep 5
kill %1 2>/dev/null
```

---

## 7. Concept Check

1. DPDK uses "poll mode" instead of interrupts. What CPU cost does this impose, and why is it acceptable for line-rate packet processing?
2. In AF_XDP, what is the FILL ring used for? Why must userspace actively replenish it?
3. What is the difference between `XDP_ZEROCOPY` and `XDP_COPY` modes in AF_XDP? When would each be used?
4. An XDP program on a port needs to forward some packets to the kernel stack and redirect others to an AF_XDP socket. What return codes does it use for each case?

---

## 📚 References
- `net/xdp/` — AF_XDP socket implementation
- `include/uapi/linux/if_xdp.h` — AF_XDP userspace API
- `include/net/xdp_sock.h` — `xdp_umem`, `xsk_queue` structures
- `tools/lib/bpf/xsk.c` — libxdp helper library
- `samples/bpf/xdpsock_user.c` — reference AF_XDP application
- Kernel docs: `Documentation/networking/af_xdp.rst`
- DPDK: `https://www.dpdk.org/`
