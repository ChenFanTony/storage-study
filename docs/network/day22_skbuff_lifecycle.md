# Day 22 — `sk_buff` Lifecycle: Allocation, Cloning, Fragmentation, and Freeing
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 4)

---

## 🎯 Goal
Master the complete lifecycle of an `sk_buff` — from allocation through cloning, fragmentation, and reference-counted freeing. This is the deepest internals day of the entire course.

---

## 1. The Complete `sk_buff` Memory Layout

```
        kmalloc region
        ┌──────────────────────────────────────────────────────┐
        │  struct sk_buff  (descriptor, ~240 bytes)            │
        │    head ──────────────────────────────────────┐      │
        │    data ──────────────┐                       │      │
        │    tail ──────────┐   │                       │      │
        │    end ───────────┼───┼───────────────────────┘      │
        └───────────────────┼───┼───────────────────────────── ┘
                            │   │
        kmalloc region      │   │
        ┌───────────────────▼───▼───────────────────────────── ┐
        │[headroom][  L2  ][  L3  ][  L4  ][ payload ][tailrm]│
        │          ↑mac    ↑network ↑transport                  │
        └──────────────────────────────────────────────────────┘
                                                   │
                            skb_shared_info (at end of data buffer)
                            ┌──────────────────────▼────────────┐
                            │ nr_frags: 3                        │
                            │ frags[0]: page* offset size        │
                            │ frags[1]: page* offset size        │
                            │ frags[2]: page* offset size        │
                            │ frag_list: *skb → *skb → NULL      │
                            │ dataref: refcount                  │
                            └────────────────────────────────────┘
```

---

## 2. Allocation: `alloc_skb()` Family

**Source:** `net/core/skbuff.c`

```c
struct sk_buff *alloc_skb(unsigned int size, gfp_t priority)
{
    struct sk_buff *skb;
    u8 *data;

    /* 1. Allocate sk_buff descriptor from slab cache */
    skb = kmem_cache_alloc(skbuff_head_cache, priority & ~__GFP_DMA);
    if (!skb)
        return NULL;

    /* 2. Allocate data buffer (size + skb_shared_info) */
    size = SKB_DATA_ALIGN(size);       // align to cache line
    size += SKB_DATA_ALIGN(sizeof(struct skb_shared_info));
    data = kmalloc_reserve(size, priority, NUMA_NO_NODE, &pfmemalloc);
    if (!data)
        goto nodata;

    /* 3. Initialize */
    memset(skb, 0, offsetof(struct sk_buff, tail));
    skb->head      = data;
    skb->data      = data;
    skb->tail      = data;
    skb->end       = data + size - SKB_DATA_ALIGN(sizeof(struct skb_shared_info));
    skb->mac_header = (typeof(skb->mac_header))~0U;

    /* 4. Initialize shared info */
    shinfo = skb_shinfo(skb);         // pointer to skb_shared_info at skb->end
    memset(shinfo, 0, offsetof(struct skb_shared_info, frags));
    atomic_set(&shinfo->dataref, 1);  // one reference to the data buffer

    return skb;
nodata:
    kmem_cache_free(skbuff_head_cache, skb);
    return NULL;
}
```

### Key allocation variants
```c
/* With headroom pre-reserved (for headers) */
struct sk_buff *alloc_skb_with_frags(unsigned long header_len,
                                      unsigned long data_len, ...);

/* Aligned for IP headers (adds NET_IP_ALIGN = 2 bytes) */
struct sk_buff *netdev_alloc_skb_ip_align(struct net_device *dev,
                                           unsigned int length);

/* Clone-friendly (allocates fclone from paired slab) */
struct sk_buff *alloc_skb_fclone(unsigned int size, gfp_t priority);
```

---

## 3. Header Manipulation

```c
/* skb_reserve(skb, len): move data and tail forward — create headroom */
static inline void skb_reserve(struct sk_buff *skb, int len)
{
    skb->data += len;
    skb->tail += len;
}
/* Used after alloc_skb to make room for headers that will be prepended */

/* skb_push(skb, len): extend data backward — prepend header */
static inline void *skb_push(struct sk_buff *skb, unsigned int len)
{
    skb->data -= len;
    skb->len  += len;
    /* returns pointer to new start of data — fill your header here */
    return skb->data;
}

/* skb_put(skb, len): extend tail — append payload */
static inline void *skb_put(struct sk_buff *skb, unsigned int len)
{
    void *tmp = skb_tail_pointer(skb);
    skb->tail += len;
    skb->len  += len;
    return tmp;
}

/* skb_pull(skb, len): consume header — move data pointer forward */
static inline void *skb_pull(struct sk_buff *skb, unsigned int len)
{
    skb->len -= len;
    return skb->data += len;
}
```

### Typical TX build sequence
```c
skb = alloc_skb(MAX_HEADER + data_len, GFP_KERNEL);
skb_reserve(skb, MAX_HEADER);     // reserve space for all headers

/* App layer: copy payload */
memcpy(skb_put(skb, data_len), data, data_len);

/* TCP layer: prepend TCP header */
th = skb_push(skb, tcp_hdr_len);
/* fill th->... */

/* IP layer: prepend IP header */
iph = skb_push(skb, ip_hdr_len);
/* fill iph->... */

/* Ethernet layer: prepend ETH header */
eth = skb_push(skb, ETH_HLEN);
/* fill eth->... */
```

---

## 4. Cloning: `skb_clone()` vs `pskb_copy()` vs `skb_copy()`

**Source:** `net/core/skbuff.c`

These three operations serve very different purposes:

### `skb_clone()` — share data, new descriptor
```c
struct sk_buff *skb_clone(struct sk_buff *skb, gfp_t gfp_mask)
{
    struct sk_buff *n = skb_clone_sk(skb);  /* or kmem_cache_alloc */

    /* Copy the descriptor fields */
    C(head);      /* same data buffer pointer */
    C(data);
    C(tail);
    C(end);
    C(len);

    /* Share the data buffer — increment dataref */
    atomic_inc(&skb_shinfo(skb)->dataref);
    /* Also inc page refs for any frags */
    skb_clone_fraglist(n);

    return n;
}
```
```
Original:  [descriptor1] ──►  [data buffer]  ◄── [descriptor2] :Clone
                                    ↑
                              dataref = 2
```
**Use case:** retransmit path (TCP keeps original, sends clone).
**Constraint:** cannot modify data — both share it.

### `pskb_copy()` — new header, shared data
```c
/* Copies skb->data (header area) but shares page frags */
/* Allows modifying the linear header without affecting original */
struct sk_buff *pskb_copy(struct sk_buff *skb, gfp_t gfp_mask);
```
**Use case:** NAT (rewrite IP header, keep payload pages shared).

### `skb_copy()` — full deep copy
```c
/* Copies everything: linear data + all frags */
/* Expensive but completely independent */
struct sk_buff *skb_copy(const struct sk_buff *skb, gfp_t gfp_mask);
```
**Use case:** when you need to modify both headers and payload independently.

---

## 5. Fragmentation: `skb_split()` and `tcp_fragment()`

**Source:** `net/core/skbuff.c`, `net/ipv4/tcp_output.c`

### TCP segmentation
```c
/* Split an skb at position `len` bytes */
int tcp_fragment(struct sock *sk, enum tcp_queue tcp_queue,
                 struct sk_buff *skb, u32 len,
                 unsigned int mss_now, gfp_t gfp)
{
    struct sk_buff *buff;

    /* Allocate new skb for the second half */
    buff = sk_stream_alloc_skb(sk, 0, gfp, true);

    /* Split the data: skb keeps [0..len), buff gets [len..end) */
    skb_split(skb, buff, len);

    /* Update TCP sequence numbers */
    TCP_SKB_CB(buff)->seq  = TCP_SKB_CB(skb)->seq + len;
    TCP_SKB_CB(skb)->end_seq = TCP_SKB_CB(skb)->seq + len;

    /* Insert buff after skb in write queue */
    __skb_queue_after(&sk->sk_write_queue, skb, buff);

    return 0;
}
```

### IP fragmentation
```c
/* net/ipv4/ip_output.c */
int ip_fragment(struct net *net, struct sock *sk, struct sk_buff *skb,
                unsigned int mtu,
                int (*output)(struct net *, struct sock *, struct sk_buff *))
{
    unsigned int left = skb->len - hlen;  // payload to fragment
    unsigned int ptr  = 0;

    while (left > 0) {
        /* Allocate fragment skb */
        frag = alloc_skb(len + hlen + ll_rs, GFP_ATOMIC);

        /* Copy IP header + fragment payload */
        skb_copy_from_linear_data(skb, skb_network_header(frag), hlen);
        skb_copy_bits(skb, ptr, skb_transport_header(frag), len);

        /* Set fragment offset in IP header */
        iph = ip_hdr(frag);
        iph->frag_off = htons(offset >> 3);
        if (left > len)
            iph->frag_off |= htons(IP_MF);  // More Fragments bit

        output(net, sk, frag);
        ptr    += len;
        offset += len;
        left   -= len;
    }
    kfree_skb(skb);  // free the original oversized skb
    return err;
}
```

---

## 6. Reference Counting and Freeing

**Source:** `net/core/skbuff.c`

### `kfree_skb()` — the primary free path
```c
void kfree_skb(struct sk_buff *skb)
{
    if (!skb_unref(skb))   // atomic_dec_and_test(&skb->users)
        return;             // still referenced — don't free yet

    /* Call destructor if set (e.g., sock memory accounting) */
    if (skb->destructor)
        skb->destructor(skb);   /* e.g., sock_wfree() for TX accounting */

    /* Free the data buffer */
    skb_release_data(skb);

    /* Return descriptor to slab cache */
    kmem_cache_free(skbuff_head_cache, skb);
}

static void skb_release_data(struct sk_buff *skb)
{
    struct skb_shared_info *shinfo = skb_shinfo(skb);

    /* Decrement dataref — free only when it hits zero */
    if (atomic_sub_and_test(skb->cloned ? 1 : shinfo->nr_frags + 1,
                             &shinfo->dataref)) {
        /* Free all page fragments */
        for (i = 0; i < shinfo->nr_frags; i++)
            __skb_frag_unref(shinfo->frags + i);  // put_page()

        /* Free the linear data buffer */
        kfree(skb->head);
    }
}
```

### Destructor pattern for socket accounting
```c
/* Set when skb is added to write queue: */
skb->destructor = sock_wfree;
skb->sk = sk;
refcount_add(skb->truesize, &sk->sk_wmem_alloc);

/* When skb is freed (after TX completes): */
void sock_wfree(struct sk_buff *skb)
{
    struct sock *sk = skb->sk;
    /* Decrement socket write memory */
    atomic_sub(skb->truesize, &sk->sk_wmem_alloc);
    /* If space freed up, wake blocked send() */
    if (sk_stream_is_writeable(sk))
        sk->sk_write_space(sk);
    sock_put(sk);
}
```

---

## 7. `skb_shared_info` and `dataref`

```c
struct skb_shared_info {
    __u8        flags;
    __u8        meta_len;
    __u8        nr_frags;       // number of page frags
    __u8        tx_flags;

    unsigned short  gso_size;   // GSO segment size
    unsigned short  gso_segs;   // number of GSO segments
    unsigned short  gso_type;   // SKB_GSO_TCPV4, etc.

    struct sk_buff  *frag_list; // list of skbs (for sk_buff chain)

    skb_frag_t  frags[MAX_SKB_FRAGS];  // page fragment array

    atomic_t    dataref;        // reference count on the data buffer
                                // = 1 + number of clones sharing this data
};
```

**`dataref` invariant:**
```
dataref = 1 + (number of clones sharing this data buffer)
When dataref reaches 0: free head + all frags
```

---

## 8. Hands-On

### 8a. Read `alloc_skb` and `kfree_skb`
```bash
grep -n "^struct sk_buff \*alloc_skb\|^void kfree_skb\|^void skb_release_data" \
    ~/linux/net/core/skbuff.c | head -10

# Count lines in skbuff.c (it's large)
wc -l ~/linux/net/core/skbuff.c
```

### 8b. Find all clone/copy variants
```bash
grep -n "^struct sk_buff \*skb_clone\|^struct sk_buff \*skb_copy\|^struct sk_buff \*pskb_copy" \
    ~/linux/net/core/skbuff.c
```

### 8c. Trace skb allocation in live system
```bash
# Count skb alloc/free events (requires bpftrace)
bpftrace -e '
kprobe:alloc_skb { @allocs = count(); }
kprobe:kfree_skb { @frees  = count(); }
interval:s:1     { print(@allocs); print(@frees); clear(@allocs); clear(@frees); }
' 2>/dev/null &
sleep 5
kill %1 2>/dev/null
```

### 8d. Observe skb slab caches
```bash
# skbuff slab allocator stats
cat /proc/slabinfo | grep skb
# Look for: skbuff_head_cache, skbuff_fclone_cache

# Memory used by skbs
cat /proc/meminfo | grep Slab
```

### 8e. skb truesize vs len
```bash
# Observe truesize overhead
bpftrace -e '
kprobe:tcp_sendmsg_locked {
    $sk = (struct sock *)arg0;
    printf("sndbuf=%d wmem=%d\n",
        $sk->sk_sndbuf,
        $sk->sk_wmem_queued);
}' 2>/dev/null &
python3 -c "
import socket
s = socket.socket()
s.connect(('127.0.0.1', 22))
s.send(b'A' * 4096)
s.close()
" 2>/dev/null
kill %1 2>/dev/null
```

---

## 9. Concept Check

1. What is `dataref` in `skb_shared_info`? When does it reach 0, and what happens then?
2. What is the difference between `skb_clone()` and `skb_copy()`? Give a concrete kernel use case for each.
3. After `skb_clone()`, can either the original or the clone safely call `skb_push()` to add a header? Why or why not?
4. What does the `destructor` field of `sk_buff` do, and why is it important for socket send buffer accounting?

---

## 📚 References
- `net/core/skbuff.c` — all allocation, clone, copy, free operations
- `include/linux/skbuff.h` — `struct sk_buff`, `struct skb_shared_info`
- `net/ipv4/tcp_output.c` — `tcp_fragment`
- `net/ipv4/ip_output.c` — `ip_fragment`
- `net/core/sock.c` — `sock_wfree`, socket memory accounting
