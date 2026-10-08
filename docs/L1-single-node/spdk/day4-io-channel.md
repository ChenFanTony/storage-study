# Day 4: I/O Channel Model

## What this day covers

`io_channel` is how SPDK gives each thread its own private context for a device or module,
without locks.

Once you understand this, you will understand why bdev I/O submission looks the way it
does, why NVMf creates channels per queue pair, and why SPDK scales to many cores without
contention.

Source references:

- `lib/thread/thread.c` (io_channel implementation lives here)
- `include/spdk/thread.h`
- `lib/bdev/bdev.c` (bdev channel usage)

---

## The problem io_channel solves

Imagine a bdev module that manages an NVMe device. That device has multiple hardware
queue pairs (NVMe SQs and CQs).

Naive approach: one global queue pair, protected by a mutex.

Problems:

- every I/O submission takes the mutex
- cores serialize on a single queue
- performance collapses at high queue depth or many cores

SPDK approach: each thread that submits I/O gets its own queue pair, allocated once and
stored in a per-thread channel.

No mutex needed. No contention. Each thread works its own queue pair independently.

---

## What an io_channel is

An `io_channel` is a per-thread, per-device context object.

```c
struct spdk_io_channel {
    struct spdk_thread          *thread;     // thread that owns this channel
    struct io_device            *dev;        // the device this channel is for
    uint32_t                     ref;        // reference count
    void                        *ctx;        // module-private data (the actual per-thread state)
    TAILQ_ENTRY(spdk_io_channel) tailq;
};
```

The `ctx` pointer is what each module cares about. For an NVMe bdev, `ctx` holds a
pointer to a dedicated NVMe queue pair for this thread. For a malloc bdev, it might be
minimal or empty.

---

## How a module registers an io_device

Any module that needs per-thread context registers an "io_device":

```c
void spdk_io_device_register(
    void *io_device,          // unique pointer key (usually the device struct)
    spdk_io_channel_create_cb create_cb,
    spdk_io_channel_destroy_cb destroy_cb,
    uint32_t ctx_size,        // how many bytes of per-thread ctx to allocate
    const char *name
);
```

When a thread first calls `spdk_get_io_channel(io_device)`, SPDK:

1. allocates a channel struct plus `ctx_size` bytes
2. calls `create_cb(io_device, channel)` on the calling thread
3. caches the channel for this thread

Subsequent calls from the same thread return the cached channel. No allocation, no
callback.

---

## How a caller gets and uses a channel

```c
// get (or create) a channel for this thread
struct spdk_io_channel *ch = spdk_get_io_channel(my_device);

// submit I/O using the channel
my_module_submit_request(ch, request);

// release when done (refcounted)
spdk_put_io_channel(ch);
```

The channel is per-thread. You must not pass a channel obtained on thread A to thread B.

---

## bdev uses io_channel

The bdev layer wraps io_channel into `spdk_bdev_desc` and the channel obtained through it.

```c
// open a bdev
spdk_bdev_open_ext(bdev_name, true, event_cb, NULL, &desc);

// get a channel for I/O on the current thread
struct spdk_io_channel *ch = spdk_bdev_get_io_channel(desc);

// submit I/O
spdk_bdev_read(desc, ch, buf, offset, len, completion_cb, cb_arg);
```

Each thread that submits bdev I/O has its own channel, which maps to its own queue pair
(for NVMe), its own aio file descriptor context (for AIO bdev), etc.

---

## NVMf and io_channel

In NVMf, each queue pair (QP) runs on one thread. That thread holds the io_channel for
each namespace's backing bdev.

When a read or write command arrives:

```
NVMf QP poller (thread X)
  -> nvmf_ctrlr_process_io_cmd()
     -> spdk_nvmf_request_exec()
        -> nvmf_bdev_ctrlr_read_cmd()
           -> spdk_bdev_read(desc, ch, ...)    // ch is owned by thread X
```

The channel was created when the QP was established. It stays alive as long as the QP
is alive. No channel lookup on the hot path.

---

## Channel teardown

When a thread is done with a device:

```c
spdk_put_io_channel(ch);
```

When the refcount reaches zero, `destroy_cb` is called on the current thread.
For NVMe, this deletes the queue pair.

For NVMf, this happens when a host disconnects and the queue pair is torn down.

---

## Comparison with kernel model

| Linux kernel | SPDK io_channel |
|---|---|
| per-cpu variables (`__percpu`) | per-thread channel ctx |
| per-cpu queue or lock-free ring per cpu | per-thread NVMe queue pair |
| driver's `private_data` in request_queue | channel `ctx` for per-thread module state |
| `get_cpu()` / `put_cpu()` | `spdk_get_io_channel()` / `spdk_put_io_channel()` |

The mental model is the same: avoid sharing by giving each execution context its own
private resources. SPDK does it at the `spdk_thread` level instead of the CPU level.

---

## What matters most after Day 4

1. `io_channel` = per-thread private context for a device.
2. Registered once per device via `spdk_io_device_register`.
3. Created lazily per thread on first `spdk_get_io_channel` call.
4. The `ctx` field is what modules actually care about (queue pairs, fds, etc.).
5. You must not share a channel across threads.
6. bdev uses this for per-thread queue pairs to avoid lock contention.
7. NVMf creates one channel per QP thread and holds it for the connection lifetime.

---

## Suggested next step

Day 5: the bdev framework. Now that you understand threads and channels, the bdev open /
descriptor / claim / I/O submit model will all fit together cleanly.
