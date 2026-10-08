# Day 5: bdev Framework

## What this day covers

The bdev layer is the central storage abstraction in SPDK. Almost every higher-level
service — NVMf, iSCSI, vhost — talks to storage through bdev, not directly to hardware.

Understanding bdev well means you can reason about any SPDK storage service.

Source references:

- `lib/bdev/bdev.c`
- `include/spdk/bdev.h`
- `include/spdk/bdev_module.h`
- `doc/bdev.md`

---

## What a bdev is

A bdev (block device) is SPDK's generic block storage object.

It has:

- a name (string, used in RPC and NVMf namespace config)
- block size and block count
- supported I/O types (read, write, unmap, flush, reset, etc.)
- a bdev module that implements the actual operations
- a list of open descriptors
- a claim (exclusive write owner, if any)

```c
struct spdk_bdev {
    const char                  *name;
    const struct spdk_bdev_fn_table *fn_table;   // module ops
    struct spdk_bdev_module     *module;
    uint32_t                     blocklen;
    uint64_t                     blockcnt;
    // ... many more fields
};
```

---

## bdev modules

Each backend type is a bdev module. Modules register with the bdev layer and provide
a function table of operations.

Common modules:

| Module | What it backs |
|---|---|
| `malloc` | in-memory buffer, testing/scratch |
| `aio` | Linux AIO on a file or block device |
| `uring` | io_uring on a file or block device |
| `nvme` | NVMe device via SPDK NVMe driver |
| `lvol` | logical volumes on top of another bdev |
| `raid` | RAID on top of multiple bdevs |
| `null` | discards all I/O, for benchmarking |

From NVMf's perspective, all backends look identical. NVMf only calls bdev API, never
module-specific code.

---

## Opening a bdev: descriptors

To use a bdev, a caller opens it and gets a descriptor.

```c
int spdk_bdev_open_ext(
    const char *bdev_name,
    bool write,
    spdk_bdev_event_cb_t event_cb,
    void *event_ctx,
    struct spdk_bdev_desc **desc
);

void spdk_bdev_close(struct spdk_bdev_desc *desc);
```

Multiple callers can hold read descriptors simultaneously.
Write descriptors are also allowed to coexist unless a claim is held.

The descriptor is the token. You pass it to every bdev I/O call along with an
`io_channel`.

---

## Claims

A claim gives one module exclusive write ownership of a bdev.

```c
int spdk_bdev_module_claim_bdev(
    struct spdk_bdev *bdev,
    struct spdk_bdev_desc *desc,
    struct spdk_bdev_module *module
);

void spdk_bdev_module_release_bdev(struct spdk_bdev *bdev);
```

NVMf claims a bdev when you add it as a namespace. That is why the same bdev cannot be
added to two NVMf subsystems simultaneously — the second add fails because the bdev is
already claimed.

This is the mechanical reason behind your PR conclusion: the bdev exclusivity is enforced
at the claim level before PR sharing even becomes relevant.

---

## I/O submission

All I/O goes through typed submit calls:

```c
int spdk_bdev_read(
    struct spdk_bdev_desc *desc,
    struct spdk_io_channel *ch,
    void *buf,
    uint64_t offset,
    uint64_t nbytes,
    spdk_bdev_io_completion_cb cb,
    void *cb_arg
);

int spdk_bdev_write(...);
int spdk_bdev_unmap(...);
int spdk_bdev_flush(...);
int spdk_bdev_reset(...);
```

All are asynchronous. They return immediately. `cb` is called when the operation
completes, on the same thread that submitted it.

The `ch` must have been obtained on the calling thread via `spdk_bdev_get_io_channel(desc)`.

---

## bdev_io

Each in-flight I/O is represented by `struct spdk_bdev_io`.

The bdev layer allocates one from a per-channel pool (avoiding malloc on the hot path).
It is passed to the module's submit function and returned in the completion callback.

```c
void my_completion_cb(struct spdk_bdev_io *bdev_io, bool success, void *cb_arg) {
    // inspect bdev_io->u.bdev.iovs etc.
    spdk_bdev_free_io(bdev_io);  // return to pool
}
```

Always call `spdk_bdev_free_io` in your completion callback. Forgetting this leaks
from the per-channel pool.

---

## Queueing

If a bdev has no resources available (queue full, out of bdev_io objects), the bdev layer
can queue the request internally. When resources free up, it retries automatically.

This is transparent to the caller. The completion callback fires eventually regardless.

---

## NVMf and bdev: the connection

NVMf namespace maps directly to a bdev:

```
struct spdk_nvmf_ns {
    struct spdk_bdev        *bdev;
    struct spdk_bdev_desc   *desc;
    struct spdk_io_channel  *ch;    // per-thread, set up per QP
    // ... PR state, visibility state ...
};
```

When NVMf receives a read command for NSID 1:

1. look up `ns = subsystem->ns[nsid - 1]`
2. check PR conflict
3. call `spdk_bdev_read(ns->desc, qpair->ch[nsid], buf, offset, len, cb, req)`
4. return to poller
5. bdev module completes I/O
6. `cb` fires on the same thread
7. NVMf builds and sends the NVMe completion

The bdev layer is the seam. NVMf does not know or care whether the bdev is malloc,
AIO, NVMe passthrough, or lvol.

---

## Block diagram

```
NVMf target
     |
     | spdk_bdev_read/write/unmap
     v
  bdev layer  <-- descriptor, claim, io_channel, queueing, bdev_io pool
     |
     | fn_table->submit_request
     v
  bdev module (aio / nvme / malloc / lvol / raid)
     |
     v
  actual hardware or file
```

---

## Comparison with kernel block layer

| Linux kernel | SPDK bdev |
|---|---|
| `struct block_device` | `struct spdk_bdev` |
| `blk_queue_make_request` | `fn_table->submit_request` |
| `struct bio` | `struct spdk_bdev_io` |
| `blk_get_request` | `spdk_bdev_free_io` pool |
| partition / holder exclusive open | claim (`spdk_bdev_module_claim_bdev`) |
| `submit_bio` | `spdk_bdev_read/write/...` |
| per-cpu queue | per-thread io_channel |

---

## What matters most after Day 5

1. Every SPDK storage service talks to storage through bdev. Learn bdev once, understand
   all services.
2. A descriptor is the open handle. An io_channel is the per-thread I/O context.
   Both are needed to submit I/O.
3. Claims enforce exclusive write ownership. This is why you cannot add the same bdev
   to two NVMf subsystems.
4. All I/O is asynchronous. The completion callback fires on the submitting thread.
5. `spdk_bdev_free_io` must always be called in the completion callback.
6. NVMf stores `bdev`, `desc`, and a per-QP channel in `spdk_nvmf_ns`. That is the
   entire NVMf-to-storage wiring.

---

## Suggested next step

Day 6: read `lib/bdev/bdev.c` and `lib/thread/thread.c` with architecture in mind.
Find the 10 most important structs and functions. Write them down with a one-line
explanation of each.
