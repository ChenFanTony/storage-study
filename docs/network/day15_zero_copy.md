# Day 15 — Zero-Copy Networking: `sendfile`, `splice`, `MSG_ZEROCOPY`
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 3)

---

## 🎯 Goal
Understand how the kernel avoids expensive data copies between userspace and kernel space, and how `sendfile`, `splice`, and `MSG_ZEROCOPY` each achieve this differently.

---

## 1. The Copy Problem

Normal `send()` path:
```
Disk → [read()] → kernel page cache → [copy_to_user()] → userspace buffer
                                                              │
                                                        [send()]
                                                              │
                                                     [copy_from_user()] → sk_buff
                                                                              │
                                                                           NIC DMA
```

**Two copies:** disk→userspace, userspace→sk_buff. For a file server sending static files, this is pure overhead.

---

## 2. `sendfile()` — File to Socket, No Userspace Copy

**Source:** `net/socket.c` → `mm/filemap.c` → `net/ipv4/tcp.c`

```c
ssize_t sendfile(int out_fd, int in_fd, off_t *offset, size_t count);
```

**Path:**
```
sendfile(sockfd, filefd, &offset, count)
  └── do_sendfile()
        └── in_file->f_op->splice_read()   // read file pages
              └── sock_sendpage()           // send page directly
                    └── tcp_sendpage()
                          └── tcp_sendpage_locked()
                                ├── skb = tcp_write_queue_tail(sk)
                                ├── skb_can_coalesce()?  // add page to existing skb
                                │     skb_fill_page_desc(skb, i, page, offset, size)
                                │     // no copy! sk_buff points to page cache page
                                └── ip_queue_xmit() → dev_queue_xmit()
                                      └── NIC DMA directly from page cache
```

```
Disk → page cache → [sk_buff page pointer] → NIC DMA
              ↑
         no copy here!
         sk_buff just references the page
```

### `skb_fill_page_desc` — nonlinear skb
```c
/* sk_buff can hold data in two forms: */
/* 1. Linear: data in skb->data..skb->tail (contiguous) */
/* 2. Nonlinear: extra pages in skb_shinfo(skb)->frags[] */

struct skb_shared_info {
    __u8        nr_frags;         // number of page fragments
    skb_frag_t  frags[MAX_SKB_FRAGS];  // up to 17 page refs
    struct sk_buff *frag_list;    // chain of skbs
};

typedef struct skb_frag {
    struct page *page;        // pointer to page cache page
    __u32        page_offset; // offset within the page
    __u32        size;        // bytes in this fragment
} skb_frag_t;
```

NIC drivers with scatter-gather DMA handle nonlinear skbs natively — no linearization needed.

---

## 3. `splice()` — Generic Kernel Pipe Transfer

**Source:** `fs/splice.c`

`splice` moves data between two file descriptors via an in-kernel pipe, without going through userspace:

```c
ssize_t splice(int fd_in,  off_t *off_in,
               int fd_out, off_t *off_out,
               size_t len, unsigned int flags);
```

```
fd_in (file/pipe) → [splice] → fd_out (socket/pipe)
                        │
                   kernel pipe
                   (page references,
                    no data copy)
```

**Two-step pattern (file → socket):**
```c
int pipefd[2];
pipe(pipefd);

// Step 1: file → pipe (no copy, moves page refs)
splice(filefd, &offset, pipefd[1], NULL, len, SPLICE_F_MOVE);

// Step 2: pipe → socket (no copy, NIC DMA from pages)
splice(pipefd[0], NULL, sockfd, NULL, len, SPLICE_F_MOVE);
```

### Kernel implementation
```c
/* fs/splice.c */
static long do_splice(struct file *in, loff_t *off_in,
                      struct file *out, loff_t *off_out,
                      size_t len, unsigned int flags)
{
    if (in->f_op->splice_read && out->f_op->splice_write) {
        /* pipe as intermediary */
        return splice_file_to_pipe(in, pipe, len, flags);
    }
    /* ... */
}
```

---

## 4. `MSG_ZEROCOPY` — Zero-Copy `send()`

**Source:** `net/core/zerocopy.c`, `net/ipv4/tcp.c`

`MSG_ZEROCOPY` allows `send()` to reference userspace memory directly — the NIC DMA's from user pages:

```c
/* Enable on socket */
setsockopt(fd, SOL_SOCKET, SO_ZEROCOPY, &one, sizeof(one));

/* Send with zero-copy flag */
send(fd, buf, len, MSG_ZEROCOPY);

/* MUST wait for completion notification before freeing buf! */
struct msghdr msg = {};
struct cmsghdr *cm;
char cbuf[sizeof(cm) + sizeof(struct sock_extended_err)];
msg.msg_control = cbuf;
msg.msg_controllen = sizeof(cbuf);
recvmsg(fd, &msg, MSG_ERRQUEUE);  // blocks until NIC is done with buf
```

### Kernel implementation
```c
/* net/ipv4/tcp.c - tcp_sendmsg_locked() */
if (msg->msg_flags & MSG_ZEROCOPY) {
    /* Pin userspace pages (get_user_pages) */
    /* Build skb pointing to pinned pages */
    skb_zerocopy_iter_stream(sk, skb, msg, copy, uarg);
    /* skb->destructor will notify via MSG_ERRQUEUE when NIC done */
}
```

### Why it's complex
```
Problem: userspace buffer must not be freed until NIC DMA completes!
Solution:
  1. get_user_pages() pins the pages (prevents free/reuse)
  2. skb destructor (when skb freed after TX): unpin pages, send notification
  3. App reads notification from MSG_ERRQUEUE
  4. Only then is it safe to reuse the buffer
```

### When `MSG_ZEROCOPY` helps vs hurts
```
Good for:  large sends (>10KB), high-throughput servers
Bad for:   small sends (<1KB) — notification overhead > copy overhead
           Loopback — copies are fast, completion path adds latency
```

---

## 5. `sendfile` vs `splice` vs `MSG_ZEROCOPY`

| | `sendfile` | `splice` | `MSG_ZEROCOPY` |
|---|---|---|---|
| Source | File/mmap | Any fd | Userspace buffer |
| Destination | Socket | Any fd | Socket |
| User involvement | None | Two calls + pipe | Must wait for completion |
| Page cache bypass | No (reads into cache) | No | Yes |
| Best for | Static file serving | Pipeline processing | App-generated data |
| Complexity | Low | Medium | High |

---

## 6. `copy_file_range()` — In-Kernel File Copy

For file-to-file copies without going through userspace:
```c
copy_file_range(fd_in, &off_in, fd_out, &off_out, len, 0);
```

On filesystems that support it (btrfs, NFS), this can be a **server-side copy** — not even reading the data locally.

---

## 7. GRO and GSO — Bulk Transfer Optimizations

### GSO (Generic Segmentation Offload) — TX path
```
tcp_sendmsg() builds one LARGE skb (up to 64KB)
  ↓
dev_queue_xmit()
  ↓
if NIC supports TSO: NIC hardware segments into MTU-sized frames
if not: gso_segment() in software splits the skb
        (still faster than building each segment individually)
```

```bash
ethtool -k eth0 | grep -i "segmentation\|offload"
# tcp-segmentation-offload: on
# generic-segmentation-offload: on
```

### GRO (Generic Receive Offload) — RX path
```
Opposite of GSO: merge multiple small skbs into one large skb
→ fewer calls through the stack
→ better CPU efficiency for bulk receive

NAPI poll → napi_gro_receive() → gro_list accumulates skbs
                               → napi_gro_flush() → delivers coalesced skb
```

```bash
ethtool -k eth0 | grep "generic-receive-offload"
```

---

## 8. Hands-On

### 8a. `sendfile` in action — measure the difference
```bash
# Create a test file
dd if=/dev/urandom of=/tmp/testfile bs=1M count=100 2>/dev/null

# Start a receiver
nc -l 9999 > /dev/null &

# Send with normal cp + nc (goes through userspace)
time cat /tmp/testfile | nc 127.0.0.1 9999

# Python sendfile (kernel sendfile syscall)
python3 -c "
import socket, os, time
s = socket.socket()
s.connect(('127.0.0.1', 9999))
f = open('/tmp/testfile', 'rb')
start = time.time()
os.sendfile(s.fileno(), f.fileno(), 0, 100*1024*1024)
print(f'sendfile: {time.time()-start:.3f}s')
f.close(); s.close()
" 2>/dev/null

kill %1 2>/dev/null
```

### 8b. Check GSO/GRO/TSO offloads
```bash
ethtool -k lo | grep -E "offload|segmentation|scatter"
ethtool -k eth0 2>/dev/null | grep -E "offload|segmentation"

# Check if large skbs are being sent (GSO)
cat /proc/net/netstat | tr '\t' '\n' | grep -i "gso\|gro"
```

### 8c. Find sendfile in kernel
```bash
grep -n "SYSCALL_DEFINE4(sendfile\|do_sendfile\|tcp_sendpage" \
    ~/linux/net/socket.c ~/linux/net/ipv4/tcp.c 2>/dev/null | head -15
```

### 8d. Observe skb frags
```bash
# skb nonlinear stats
cat /proc/net/netstat | tr '\t' '\n' | grep -i "frag\|nonlinear" | head -10

# TCP offload stats
nstat 2>/dev/null | grep -i "gso\|gro" || \
    cat /proc/net/netstat | tr '\t' '\n' | grep -i "gso" | head -5
```

---

## 9. Concept Check

1. In a normal `send()` call, how many times is data copied? Where? How does `sendfile` eliminate these copies?
2. What is a nonlinear `sk_buff`? How does `skb_shinfo(skb)->frags` enable zero-copy page transfer?
3. Why must an application wait for `MSG_ERRQUEUE` notification after `MSG_ZEROCOPY send()`? What happens if it doesn't?
4. What is the difference between TSO (TCP Segmentation Offload) and GSO? Which requires NIC hardware support?

---

## 📚 References
- `net/socket.c` — `sys_sendfile`
- `fs/splice.c` — `splice`, `do_splice`
- `net/core/zerocopy.c` — `MSG_ZEROCOPY` support
- `net/ipv4/tcp.c` — `tcp_sendpage`, `tcp_sendmsg`
- `include/linux/skbuff.h` — `skb_shared_info`, `skb_frag_t`
- Kernel docs: `Documentation/networking/msg_zerocopy.rst`
