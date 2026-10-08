# Day 7: NVMf on SPDK — Integrating The Model

## What this day covers

This is the capstone of the 7-day architecture mini plan. The goal is not feature mastery.
The goal is to answer one question clearly:

**How does an NVMf request move through SPDK from transport receive to completion?**

By the end of today you should be able to draw the full path from a host sending a read
command to the host receiving the completion, naming every major boundary crossed.

Source files to read today:

- `doc/nvmf.md` (light read, feature overview)
- `lib/nvmf/ctrlr.c` (focus on dispatch and PR conflict check)
- `lib/nvmf/subsystem.c` (focus on namespace management and PR update path)

---

## How NVMf uses SPDK threads

NVMf runs on multiple threads, with clear ownership boundaries.

### App thread

- creates the target: `spdk_nvmf_tgt_create`
- creates transports: `spdk_nvmf_transport_create`
- creates subsystems: `spdk_nvmf_subsystem_create`
- adds namespaces, hosts, listeners via RPC handlers
- does NOT process I/O

### Poll group thread (one per CPU assigned to NVMf)

- runs transport pollers (TCP receive, RDMA completions)
- owns queue pairs assigned to it
- processes NVMe commands for those queue pairs
- submits bdev I/O on behalf of each request
- receives bdev completions and sends NVMe completions

### Subsystem thread

- serializes state changes to a subsystem
- owns PR state updates for all namespaces in the subsystem
- does NOT process I/O directly

When a PR command arrives on a QP thread, the QP thread sends a message to the subsystem
thread to update reservation state. This is the cross-thread message you will see in
`ctrlr.c`.

---

## Request flow: one read command

```
1. Host sends NVMe READ over TCP

2. TCP poller fires on poll group thread
   lib/nvmf/tcp.c: spdk_nvmf_tcp_qpair_process_pending()
   -> receives data, builds spdk_nvmf_request

3. Request dispatch
   lib/nvmf/ctrlr.c: nvmf_ctrlr_process_io_cmd()
   -> looks up NSID -> spdk_nvmf_ns
   -> checks PR conflict: nvmf_ns_reservation_request_check()
      (if PR conflict: complete with RESERVATION CONFLICT status, done)
   -> if no conflict: proceed

4. bdev I/O submission
   lib/nvmf/nvmf_bdev.c: nvmf_bdev_ctrlr_read_cmd()
   -> spdk_bdev_read(ns->desc, ch, buf, offset, len, nvmf_bdev_ctrlr_complete_cmd, req)
   -> returns immediately (async)

5. bdev module processes I/O
   (AIO, NVMe, malloc, etc. — depends on backend)
   completion fires when done

6. Completion callback
   nvmf_bdev_ctrlr_complete_cmd()
   -> builds NVMe CQE
   -> spdk_nvmf_request_complete(req)

7. Transport sends completion
   lib/nvmf/tcp.c: sends CQE back to host over TCP connection

All of steps 2–7 run on the SAME poll group thread.
No thread switches for a normal read. Only PR update commands cross to the subsystem thread.
```

---

## Request flow: a PR RESERVE command

```
1–3. Same as above through ctrlr dispatch

4. PR command recognized
   lib/nvmf/ctrlr.c: nvmf_ctrlr_process_fabrics_cmd() or reservation handler
   -> builds reservation context
   -> spdk_thread_send_msg(subsystem->thread, nvmf_ns_reservation_update, ctx)
   -> QP thread returns to polling (does not block)

5. Subsystem thread processes the message
   nvmf_ns_reservation_update()
   -> validates registrant
   -> updates spdk_nvmf_ns PR state
   -> if PTPL: writes PTPL file
   -> sends completion message back to QP thread

6. QP thread receives completion message
   -> builds NVMe CQE
   -> sends to host
```

This cross-thread round trip is why PR commands have slightly higher latency than
regular I/O. It is also what guarantees serialized, race-free PR state updates.

---

## How NVMf uses bdev

Each namespace holds:

```c
struct spdk_nvmf_ns {
    struct spdk_bdev        *bdev;    // the bdev object (shared, read-only reference)
    struct spdk_bdev_desc   *desc;    // open handle (holds claim)
    // io_channel is per-QP, stored in qpair or looked up per request
    ...
};
```

The claim on `desc` is what prevents the same bdev being added to two subsystems.

The io_channel is obtained per QP thread. When a QP is assigned to a poll group thread,
the thread opens channels to all namespaces it will serve. I/O then uses those channels
with zero lookup overhead.

---

## How NVMf uses pollers

Key pollers in `lib/nvmf/tcp.c`:

- `nvmf_tcp_accept_poll`: accepts new TCP connections
- `nvmf_tcp_qpair_poll`: polls one QP for new requests and completions

Key pollers added dynamically:

- each new QP registers its own poller on the poll group thread
- poller fires every reactor iteration (period 0) for active QPs

This means: for a QP receiving heavy I/O, the poller runs thousands of times per second
on its dedicated thread. No interrupt, no sleep, no wakeup latency.

---

## Where subsystem state lives

```
spdk_nvmf_tgt
  └── spdk_nvmf_subsystem[]
        ├── thread (subsystem management thread)
        ├── ns[]
        │     ├── bdev / desc
        │     ├── PR state (registrants, holder, resv_key, resv_type, ptpl)
        │     └── host visibility list
        ├── allowed_hosts[]
        └── listeners[]
```

Everything about what hosts can connect, what namespaces they can see, and what
reservations are active lives in this tree.

The subsystem thread serializes all writes to this tree.
QP threads read namespace state (with care) and send messages for writes.

---

## Summary diagram

```
Host (initiator)
    |  TCP/RDMA
    v
Transport layer (tcp.c)
    |  spdk_nvmf_request
    v
ctrlr.c dispatch
    |
    +--[PR command]---> subsystem thread (msg) --> PR state update --> msg back
    |
    +--[I/O command]--> nvmf_bdev.c
                            |  spdk_bdev_read/write
                            v
                        bdev layer
                            |
                            v
                        bdev module (aio/nvme/malloc)
                            |  completion cb
                            v
                        nvmf_bdev_ctrlr_complete_cmd
                            |
                            v
                        Transport sends CQE to host
```

All non-PR work stays on the QP thread. PR state changes cross to the subsystem thread.

---

## Completing the 7-day mini plan

You can now answer all seven questions from the mini plan:

1. **Why is SPDK user-space and polling-based?**
   Polling eliminates interrupt latency and context switch overhead. User-space gives
   direct hardware access via DPDK/VFIO.

2. **What do reactors, SPDK threads, and pollers do?**
   Reactors spin on CPU cores. SPDK threads are logical execution contexts on reactors.
   Pollers are callbacks called every reactor iteration to check for and process work.

3. **What is io_channel for?**
   Per-thread private context for a device. Gives each thread its own queue pair or
   resource handle, eliminating lock contention.

4. **Why is bdev the central abstraction?**
   Every storage service uses bdev API. Backend differences (NVMe, AIO, lvol, raid)
   are hidden behind one interface.

5. **How do services like NVMf sit on top of bdev?**
   NVMf stores a bdev descriptor per namespace and calls `spdk_bdev_read/write` directly.
   bdev modules handle the actual I/O.

6. **Why is code organized around async callbacks and message passing?**
   To avoid blocking the reactor. A blocked reactor stalls all pollers and messages on
   that thread. Callbacks and messages keep every thread moving.

---

## What matters most after Day 7

1. Normal I/O (read/write) stays on the QP thread start to finish.
2. PR state updates cross to the subsystem thread via message.
3. The subsystem thread is the serialization point for all namespace state changes.
4. `spdk_nvmf_ns` is the struct that holds everything: bdev reference, PR state,
   visibility state.
5. The architecture you now understand explains every design decision in the PR conclusion
   doc you already wrote.

---

## Suggested next step

You have completed the 7-day architecture mini plan. Move to the revised 30-day plan.

Next: Week 2 of the 30-day plan — NVMf target mechanics. Start by running a TCP target,
exporting a real bdev, and connecting a Linux initiator. The architecture is in your head.
Now make it work in the lab.
