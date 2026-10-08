# Day 1: SPDK Overview

## What this day covers

What SPDK is, what problem it solves, and how it differs from the Linux kernel storage
path. This is the mental model foundation for everything that follows.

Source references:

- `doc/overview.md`
- `doc/event.md`
- `doc/bdev.md`

---

## What SPDK is

SPDK is a set of user-space storage libraries and applications. The code is organized as:

- `lib`: core SPDK libraries
- `include/spdk`: public headers
- `app`: full applications built from the libraries
- `examples`: smaller reference programs
- `doc`: architecture and feature documentation
- `test`: unit and functional tests

SPDK is not one binary. It is a framework of libraries that applications are built from.
`nvmf_tgt` and `spdk_tgt` are applications that sit on top of the framework.

---

## The core architectural idea

SPDK is designed around four principles:

1. **user-space execution** — storage code runs in a process, not the kernel
2. **asynchronous I/O** — no blocking, no waiting
3. **polling instead of interrupts** — reactors spin continuously checking for work
4. **message passing instead of locking** — threads communicate by sending work to each
   other, not by taking shared locks

The most important of these is message passing. Every design decision in SPDK — why
callbacks are everywhere, why state machines appear constantly, why there are no mutexes
in the hot path — flows from this choice.

---

## The first mental shift: polling vs interrupts

Linux storage path:

```
task submits I/O
  -> sleeps or polls
  -> interrupt fires on completion
  -> wakes up or completion detected
  -> continues
```

SPDK storage path:

```
request submitted
  -> returns immediately (async)
  -> reactor spins checking for completions
  -> completion detected by poller
  -> callback fires
  -> next step executes
```

There is no sleeping. There is no interrupt handler wakeup. The reactor runs
continuously. This trades CPU utilization on dedicated cores for dramatically lower
and more predictable latency.

---

## The second mental shift: message passing vs locking

Linux storage path (shared state):

```
thread A wants to modify shared struct
  -> take mutex
  -> modify struct
  -> release mutex
thread B blocks until mutex is available
```

SPDK (ownership + messages):

```
struct is owned by thread A
thread B wants to modify it
  -> thread B sends message to thread A
  -> thread A processes message on its next loop
  -> no mutex, no blocking
```

This is why SPDK code is full of callbacks and state machines. A multi-step operation
that in kernel code might be a sequence of locked writes becomes a chain of messages,
each one advancing a state machine one step.

---

## Threading model at a high level

SPDK provides a framework for asynchronous, polled-mode, shared-nothing server
applications.

Key concepts:

- **reactor**: one event loop thread pinned to one CPU core, spinning forever
- **spdk_thread**: a logical thread abstraction that runs on a reactor; multiple
  `spdk_thread` objects can exist but each runs on one reactor at a time
- **poller**: a callback registered on a thread and called on every reactor iteration
- **event/message**: a function enqueued to run on a specific thread's next iteration

The reactor loop in pseudocode:

```
while (running) {
    drain message queue
    run all pollers
    run timed pollers whose deadline has passed
}
```

---

## Environment abstraction

SPDK uses POSIX for many operations but abstracts system-specific functionality:

- PCI enumeration (via DPDK/VFIO)
- DMA-safe memory allocation (hugepages)

By default SPDK uses a DPDK-based environment. This is why `scripts/setup.sh` allocates
hugepages and binds devices to VFIO before the target starts.

---

## Application model

SPDK applications:

- start with `spdk_app_start`
- initialize subsystems in dependency order
- expose runtime configuration through JSON-RPC over a UNIX socket

This differs from Linux nvmet which uses configfs. In SPDK:

- start the application
- configure using RPC calls
- inspect and modify state dynamically at runtime
- state is in-memory; scripts recreate it on restart

---

## The bdev layer

The block device layer (`bdev`) is the central storage abstraction for most SPDK services.

The bdev layer provides:

- a common API for block devices (read, write, unmap, flush, reset)
- pluggable modules for different backends (malloc, AIO, NVMe, lvol, RAID)
- lockless queueing and asynchronous completion
- per-thread I/O channels to avoid contention
- JSON-RPC management

NVMf does not talk directly to hardware. It exports bdevs. The bdev module handles
the actual hardware interaction. This means NVMf works identically regardless of whether
the backend is a malloc buffer, an AIO file, or a bare-metal NVMe device.

---

## Big-picture stack

```
nvmf_tgt application
    |
    | JSON-RPC control plane
    |
SPDK application framework
    |
    +-- thread / reactor / poller model
    |
NVMf service (lib/nvmf/)
    |
    | spdk_bdev_read / write / unmap
    |
bdev framework (lib/bdev/)
    |
    +-- malloc bdev module
    +-- AIO bdev module
    +-- uring bdev module
    +-- NVMe bdev module
    +-- lvol bdev module
    +-- RAID bdev module
    |
actual hardware or Linux block device / file
```

---

## Comparison with Linux kernel storage

| Linux kernel | SPDK |
|---|---|
| kernel threads, scheduler | reactors, pollers |
| interrupt-driven completions | poller-driven completions |
| `bio` / block layer | `spdk_bdev_io` / bdev layer |
| mutex / spinlock for shared state | message passing, per-thread ownership |
| configfs / sysfs management | JSON-RPC over UNIX socket |
| module_init / module_exit | spdk_app_start / spdk_app_stop |
| per-cpu variables for hot paths | per-thread io_channel |

This does not mean SPDK has no synchronization. It means the architecture minimizes
contention by giving each thread ownership of its own state and communicating changes
via messages rather than locks.

---

## What matters most after Day 1

1. SPDK is a framework of libraries, not a single binary.
2. Message passing is the core design rule — everything else follows from it.
3. Polling replaces interrupt-driven completions.
4. The bdev layer is the central storage abstraction that NVMf and all other services
   depend on.
5. JSON-RPC is the runtime control plane — there is no configfs equivalent.
6. State is in-memory. Restart means re-running your configuration script.
7. To understand NVMf well, you must first understand thread/reactor/poller and bdev.

---

## Suggested next step

Day 2: application framework. Learn how `spdk_app_start` initializes subsystems in
order, how the RPC socket becomes available, and what the startup sequence of
`nvmf_tgt` looks like from process launch to RPC-ready state.
