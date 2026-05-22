# Day 10 — `epoll` and the Kernel Event Notification System
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 2)

---

## 🎯 Goal
Understand how `epoll` works inside the kernel: how it registers interest in sockets, how events are delivered when data arrives, and why it scales better than `select`/`poll`.

---

## 1. The Problem `epoll` Solves

### `select` / `poll` scaling problem
```
select(maxfd, &readfds, ...) — O(maxfd) scan every call
poll(fds, nfds, timeout)    — O(nfds) scan every call

With 10,000 connections:
→ kernel scans all 10k fds on each call
→ even if only 1 fd is ready
→ O(n) per event = disaster for high-concurrency servers
```

### `epoll` solution: O(1) per event
```
epoll_create()  → create epoll instance (one-time)
epoll_ctl()     → register interest (one-time per fd)
epoll_wait()    → block until events, get only ready fds
                  returns only the fds that fired
```

---

## 2. Kernel Data Structures

**Source:** `fs/eventpoll.c`

### `eventpoll` — the epoll instance
```c
struct eventpoll {
    /* Protects the ready list */
    spinlock_t lock;
    struct mutex mtx;

    /* Wait queue for epoll_wait() callers */
    wait_queue_head_t wq;

    /* Wait queue for poll() on the epoll fd itself */
    wait_queue_head_t poll_wait;

    /* Ready list: fds with pending events */
    struct list_head rdllist;

    /* Red-black tree of all monitored fds */
    struct rb_root_cached rbr;

    /* Overflow list (used during event delivery) */
    struct epitem *ovflist;

    /* owning file */
    struct file *file;
};
```

### `epitem` — one monitored file descriptor
```c
struct epitem {
    /* Node in the red-black tree (keyed on fd number) */
    struct rb_node rbn;

    /* Node in ready list (when event fires) */
    struct list_head rdllink;

    /* Pointer back to the epoll instance */
    struct eventpoll *ep;

    /* The monitored file + fd */
    struct epoll_filefd ffd;    // { file, fd }

    /* User-supplied event: EPOLLIN, EPOLLOUT, EPOLLET, ... */
    struct epoll_event event;

    /* Wait queue entry registered on the target file */
    struct eppoll_entry *pwqlist;
};
```

---

## 3. `epoll_ctl(EPOLL_CTL_ADD)` — Registering a Socket

**Source:** `fs/eventpoll.c` (`epoll_ctl`)

```c
epoll_ctl(epfd, EPOLL_CTL_ADD, sockfd, &ev)
  └── ep_insert(ep, &event, tfile, fd, full_check)
        ├── alloc epitem
        ├── insert into ep->rbr (red-black tree)
        └── ep_item_poll(epi, &pt, 1)
              └── file->f_op->poll(file, &pt)
                    └── sock_poll()    ← net/socket.c
                          └── tcp_poll()
                                └── poll_wait(file, &sk->sk_wq, wait)
                                      └── add_wait_queue(wq, &epi->wait)
```

**Key insight:** `epoll_ctl` adds a **wait queue entry** directly onto the socket's wait queue (`sk->sk_wq`). When the socket becomes ready, it wakes up that entry — which adds the `epitem` to `ep->rdllist`.

---

## 4. Event Delivery: When Data Arrives

```c
/* In tcp_rcv_established(), when data is enqueued: */
sk->sk_data_ready(sk)
  └── sock_def_readable()
        └── wake_up_interruptible_all(&sk->sk_wq->wait)
              └── for each wait entry in sk->sk_wq:
                    ep_poll_callback(wait, mode, sync, key)
                      ├── /* Is this event we care about? */
                      │   if (!(epi->event.events & pollflags))
                      │       return;
                      ├── /* Add epitem to ready list */
                      │   list_add_tail(&epi->rdllink, &ep->rdllist)
                      └── /* Wake up epoll_wait() callers */
                          wake_up(&ep->wq)
```

This is the hot path — it happens for **every** incoming packet.

---

## 5. `epoll_wait()` — Collecting Ready Events

```c
epoll_wait(epfd, events, maxevents, timeout)
  └── ep_poll(ep, events, maxevents, timeout)
        ├── if rdllist empty:
        │     add_wait_queue(&ep->wq, &wait)
        │     schedule() ← sleep until ep_poll_callback wakes us
        │     remove_wait_queue(&ep->wq, &wait)
        └── ep_send_events(ep, events, maxevents)
              └── for each epitem in rdllist:
                    ├── call file->f_op->poll() to get current events
                    ├── if (revents & epi->event.events):
                    │     copy epoll_event to userspace
                    └── ET mode: remove from rdllist
                        LT mode: re-add to rdllist if still ready
```

### Return path to userspace
```c
// epoll_wait returns the number of ready fds
// events[] array contains {events, data} for each ready fd
// O(ready_fds) work — not O(total_fds)
```

---

## 6. Edge-Triggered vs Level-Triggered

| Mode | Flag | Behavior |
|---|---|---|
| Level-Triggered | (default) | Notify as long as fd is readable |
| Edge-Triggered | `EPOLLET` | Notify only on state change (new data) |

### Level-triggered (LT) — simpler
```
Data arrives (1000 bytes in buffer)
→ epoll_wait returns EPOLLIN
You read 500 bytes
→ epoll_wait returns EPOLLIN again (500 bytes still available)
→ safe: can't miss data
```

### Edge-triggered (ET) — higher performance, harder to use correctly
```
Data arrives (1000 bytes)
→ epoll_wait returns EPOLLIN (one notification)
You MUST read until EAGAIN — if you read only 500 bytes:
→ epoll_wait will NOT notify again until new data arrives
→ remaining 500 bytes sit unread!

Correct ET pattern:
  while (true) {
      n = recv(fd, buf, sizeof(buf), 0);
      if (n == -1 && errno == EAGAIN) break; // done
      if (n <= 0) { close(fd); break; }
      process(buf, n);
  }
```

### Kernel implementation of ET
```c
/* In ep_send_events_proc(): */
if (epi->event.events & EPOLLET) {
    /* Edge-triggered: remove from ready list */
    /* Only re-added by ep_poll_callback when new event fires */
    list_del_init(&epi->rdllink);
} else {
    /* Level-triggered: keep in ready list if still readable */
    if (revents & epi->event.events)
        list_add_tail(&epi->rdllink, &ep->rdllist);
}
```

---

## 7. `EPOLLONESHOT` and `EPOLLEXCLUSIVE`

```c
/* EPOLLONESHOT: disable fd after one event (re-arm with EPOLL_CTL_MOD) */
ev.events = EPOLLIN | EPOLLONESHOT;

/* EPOLLEXCLUSIVE: for multi-threaded servers, only wake ONE thread */
/* prevents thundering herd when multiple threads wait on same epfd */
ev.events = EPOLLIN | EPOLLEXCLUSIVE;
```

---

## 8. Hands-On

### 8a. Read `ep_poll_callback`
```bash
grep -n "ep_poll_callback\|ep_insert\|ep_send_events" \
    ~/linux/fs/eventpoll.c | head -30
```

### 8b. Check epoll fd limits
```bash
# Max number of fds epoll can watch system-wide
cat /proc/sys/fs/epoll/max_user_watches

# Max open file descriptors per process
ulimit -n
cat /proc/sys/fs/file-max
```

### 8c. Write a minimal epoll server (observe behavior)
```python
# Save as epoll_test.py and run
import socket, select

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('127.0.0.1', 9999))
server.listen(5)
server.setblocking(False)

ep = select.epoll()
ep.register(server.fileno(), select.EPOLLIN)
conns = {}

print("Listening on :9999 (connect with: nc 127.0.0.1 9999)")
try:
    while True:
        events = ep.poll(timeout=1)
        for fd, event in events:
            if fd == server.fileno():
                conn, addr = server.accept()
                conn.setblocking(False)
                ep.register(conn.fileno(), select.EPOLLIN | select.EPOLLET)
                conns[conn.fileno()] = conn
                print(f"  New connection from {addr}, fd={conn.fileno()}")
            elif event & select.EPOLLIN:
                data = conns[fd].recv(1024)
                if data:
                    print(f"  fd={fd} got: {data.decode().strip()}")
                    conns[fd].send(b"echo: " + data)
                else:
                    ep.unregister(fd)
                    conns[fd].close()
                    del conns[fd]
finally:
    ep.close()
    server.close()
```

### 8d. Observe epoll internals via /proc
```bash
# Count open epoll fds
ls /proc/self/fd | xargs -I{} readlink /proc/self/fd/{} 2>/dev/null | grep anon_inode

# fd count for a server process
ls /proc/$(pgrep nginx | head -1)/fd 2>/dev/null | wc -l
```

---

## 9. Concept Check

1. Why is `epoll` O(1) per ready event while `select`/`poll` is O(n) in the number of monitored fds?
2. What data structure does `epoll` use to store monitored fds, and why?
3. Explain exactly what happens in the kernel when `tcp_rcv_established()` receives data for a socket being watched by epoll.
4. What bug occurs if you use edge-triggered mode but don't read until `EAGAIN`? Why doesn't this bug occur with level-triggered mode?

---

## 📚 References
- `fs/eventpoll.c` — entire epoll implementation
- `net/socket.c` — `sock_poll`
- `net/ipv4/tcp.c` — `tcp_poll`
- `include/uapi/linux/eventpoll.h` — userspace-visible constants
- `man 7 epoll` — excellent conceptual overview
