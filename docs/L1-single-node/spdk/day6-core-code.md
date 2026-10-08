# Day 6: Read Core Code

## What this day covers

Reading selected files with architecture in mind. The goal is not line-by-line perfection.
The goal is to find where the abstractions you learned in Days 2–5 actually live in code,
and to build a map of the most important structs and functions.

By the end of today you should be able to open any file in `lib/nvmf/` and immediately
know what threading context the code is expected to run in.

Source files to read today:

- `lib/thread/thread.c`
- `lib/bdev/bdev.c`
- `lib/nvmf/nvmf_internal.h`

---

## Reading strategy

Do not read for completeness. Read for structure.

For each file, first scan:

1. what structs are defined or used heavily?
2. what assertions exist? (`SPDK_THREAD_*`, `assert`)
3. what callback patterns repeat?
4. where are message sends (`spdk_thread_send_msg`)?
5. where are pollers registered?

Then read the functions that matter for your NVMf focus.

---

## lib/thread/thread.c — what to look for

Key functions to find and read:

| Function | What it does |
|---|---|
| `spdk_thread_create` | allocates thread, initializes message queue and poller list |
| `spdk_thread_poll` | one reactor iteration: drains messages, runs pollers |
| `spdk_thread_send_msg` | enqueues a message to another thread |
| `spdk_poller_register` | registers a poller on the current thread |
| `spdk_get_io_channel` | returns or creates a per-thread channel for a device |
| `spdk_put_io_channel` | releases a channel, calls destroy_cb at refcount zero |
| `spdk_io_device_register` | registers a device with create/destroy callbacks and ctx size |

Things to notice:

- `spdk_thread_poll` is what the reactor calls in its spin loop
- message queue is lockless (ring buffer)
- `spdk_get_io_channel` checks a per-thread list before allocating a new channel

---

## lib/bdev/bdev.c — what to look for

Key functions to find and read:

| Function | What it does |
|---|---|
| `spdk_bdev_open_ext` | opens a bdev, returns a descriptor |
| `spdk_bdev_close` | releases a descriptor |
| `spdk_bdev_module_claim_bdev` | marks bdev as exclusively owned by one module |
| `spdk_bdev_module_release_bdev` | releases the claim |
| `spdk_bdev_get_io_channel` | gets per-thread I/O channel for this bdev/desc |
| `spdk_bdev_read` / `spdk_bdev_write` | async I/O submit |
| `spdk_bdev_io_complete` | module calls this to signal completion |
| `spdk_bdev_free_io` | caller returns bdev_io to channel pool after completion |

Things to notice:

- `spdk_bdev_module_claim_bdev` fails if already claimed: this is the NVMf exclusivity gate
- `spdk_bdev_io_complete` calls the user callback and can queue pending I/O
- bdev_io is allocated from a per-channel pool, not malloc

---

## lib/nvmf/nvmf_internal.h — what to look for

This header defines the most important NVMf structs. Read it in full.

Key structs:

### spdk_nvmf_tgt

The top-level target object. Holds:

- list of subsystems
- list of transports
- discovery log

### spdk_nvmf_subsystem

One NVMe subsystem (one NQN). Holds:

- array of namespaces (`ns[]`)
- list of allowed hosts
- list of listeners
- subsystem state (inactive, activating, active, pausing, paused, deactivating)
- the thread this subsystem is managed on

Note the state machine. Subsystem operations like add/remove namespace go through
state transitions to ensure no I/O races.

### spdk_nvmf_ns

One namespace. Holds:

- `struct spdk_bdev *bdev`
- `struct spdk_bdev_desc *desc`
- PR state: registrants, holder, reservation key, reservation type, PTPL
- per-host visibility list (when `no_auto_visible` is used)
- NSID

This is the struct you analyzed in your PR conclusion. Everything you concluded is visible
here.

### spdk_nvmf_ctrlr

One NVMe controller. One per host connection. Holds:

- hostnqn
- list of queue pairs
- the subsystem this controller is connected to
- ANA state

### spdk_nvmf_qpair

One queue pair. Holds:

- the transport-specific context (e.g., TCP connection state)
- the thread this QP runs on
- list of active requests

### spdk_nvmf_request

One in-flight NVMe command. Holds:

- the NVMe command (SQE)
- the NVMe response (CQE)
- data buffers
- the qpair it belongs to

---

## Thread ownership map

After reading `nvmf_internal.h`, fill in this ownership table for your notes:

| Struct | Owned by / runs on |
|---|---|
| `spdk_nvmf_tgt` | app thread (created there, referenced from multiple threads) |
| `spdk_nvmf_subsystem` | subsystem thread (one per subsystem) |
| `spdk_nvmf_ns` | subsystem thread (PR updates serialized here) |
| `spdk_nvmf_ctrlr` | QP thread (created on accept) |
| `spdk_nvmf_qpair` | one specific poll group thread |
| `spdk_nvmf_request` | QP thread (processed start to finish on same thread) |

This map is the key to understanding why code in `ctrlr.c` sends messages to the
subsystem thread for PR updates instead of modifying `spdk_nvmf_ns` directly.

---

## 10 most important things to record

After reading today, write down the 10 structs or functions that matter most to you
for NVMf work. Format:

```
1. spdk_nvmf_ns
   - lives in subsystem.c ownership
   - holds PR state: registrants[], holder, resv_key, resv_type, ptpl_activated
   - per-host visibility list when no_auto_visible=true
   - this is the center of everything from the PR conclusion doc
```

Fill in 9 more from what you found.

---

## What matters most after Day 6

1. `spdk_thread_poll` is the reactor loop body. Everything else flows from it.
2. `spdk_bdev_module_claim_bdev` is the gate that enforces bdev exclusivity.
3. `nvmf_internal.h` is the single best file to read for NVMf struct layout.
4. `spdk_nvmf_ns` is exactly what you analyzed in `spdk-pr-conclusion.md`.
5. Thread ownership is explicit and enforced by assertions, not by luck.

---

## Suggested next step

Day 7: connect the framework to NVMf. Read `lib/nvmf/ctrlr.c` and `lib/nvmf/subsystem.c`
lightly. The goal is to answer: how does an NVMf request move from transport receive to
bdev submit and back?
