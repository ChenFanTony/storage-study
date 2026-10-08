# Day 3: Thread / Reactor / Poller Model

## What this day covers

The SPDK threading model is the most important architecture concept in the entire codebase.
Every performance decision, every ownership rule, and every cross-module interaction flows
from it.

If you understand this well, `lib/nvmf/ctrlr.c` callbacks and thread assertions will make
immediate sense. If you skip this, those files will feel arbitrary.

Source references:

- `lib/thread/thread.c`
- `lib/event/reactor.c`
- `include/spdk/thread.h`
- `doc/event.md`

---

## The core mental shift

Linux storage path often looks like:

```
task context → sleep/wait → wake on completion → continue
```

SPDK looks like:

```
submit request → return immediately → poller fires → completion callback called
```

There is no blocking. There is no sleeping. There is no condition variable wait.
Work moves through callbacks and pollers.

---

## spdk_thread

`spdk_thread` is SPDK's logical thread abstraction. It is NOT a POSIX thread.

One `spdk_thread` runs on one POSIX thread (reactor) at a time, but the abstraction is
separate.

What a `spdk_thread` provides:

- a message queue (for cross-thread `spdk_thread_send_msg`)
- a list of pollers (functions called repeatedly on this thread)
- a list of io_channels (covered in Day 4)
- a name, for debugging

Key API:

```c
struct spdk_thread *spdk_thread_create(const char *name, const struct spdk_cpuset *cpumask);
void spdk_thread_destroy(struct spdk_thread *thread);
struct spdk_thread *spdk_get_thread(void);  // get current thread
```

---

## Reactors

A reactor is one event-loop POSIX thread pinned to one CPU core.

What a reactor does in its loop:

1. drain the message queue for its `spdk_thread`
2. run all registered pollers
3. run any timed pollers whose deadline has passed
4. repeat forever

There is one reactor per CPU core assigned to SPDK. The reactor never sleeps (in
performance mode). It spins, polling for work.

This is the polling model: instead of sleeping until an interrupt wakes the thread,
the reactor actively checks for completions on every loop iteration.

Why this matters:

- latency is determined by poller frequency, not interrupt latency
- no context switch overhead on the completion path
- the tradeoff is 100% CPU utilization on assigned cores

---

## Pollers

A poller is a function registered on a `spdk_thread` that is called repeatedly by the
reactor loop.

```c
struct spdk_poller *spdk_poller_register(
    spdk_poller_fn fn,
    void *arg,
    uint64_t period_microseconds   // 0 = run every reactor iteration
);

void spdk_poller_unregister(struct spdk_poller **ppoller);
```

Period of 0 means: call this every single reactor iteration. This is used for hot paths
like NVMe queue pair polling.

Non-zero period is used for lower-frequency work: keepalives, stats collection,
timeout checks.

Example from NVMf:

- the TCP transport registers a poller to check for new incoming data on each queue pair
- the NVMe bdev registers a poller to call `spdk_nvme_qpair_process_completions`

---

## Message passing

Cross-thread communication uses `spdk_thread_send_msg`:

```c
int spdk_thread_send_msg(
    const struct spdk_thread *thread,
    spdk_msg_fn fn,
    void *ctx
);
```

This enqueues `fn(ctx)` to run on the target thread's message queue.
The calling thread does not wait. It returns immediately.
The target thread will call `fn(ctx)` on its next reactor loop iteration.

This is the SPDK equivalent of a kernel `queue_work` or `schedule_work`, but without
the scheduler involvement and with a known execution thread.

Important rule: you must not access another thread's data directly. You send a message
and let that thread act on its own data.

---

## Thread ownership model

Each piece of state in SPDK is owned by one thread.

Examples:

- an NVMf controller is owned by the thread that created it
- a bdev channel is owned by the thread that opened it
- PR state in `spdk_nvmf_ns` is updated only on the subsystem thread

When code needs to operate on state owned by another thread, it sends a message.
This is why you see patterns like:

```c
spdk_thread_send_msg(ns->subsystem->thread, nvmf_ns_reservation_update, ctx);
```

instead of a mutex lock.

---

## Diagram

```
Physical CPU core 0          Physical CPU core 1
       |                            |
   Reactor 0                    Reactor 1
       |                            |
  spdk_thread A               spdk_thread B
       |                            |
  [message queue]             [message queue]
  [poller list]               [poller list]
       |                            |
  poller: nvme completions    poller: tcp recv
  poller: nvmf keepalive
       |
  msg: nvmf_ns_reservation_update
```

Messages cross from B to A via lockless queue.
Both threads run their own pollers without touching each other's state.

---

## Comparison with kernel model

| Linux kernel | SPDK |
|---|---|
| kernel thread / workqueue | `spdk_thread` / reactor |
| `schedule_work` | `spdk_thread_send_msg` |
| interrupt handler | poller (period 0) |
| `mutex_lock` for shared state | message passing + per-thread ownership |
| `wait_event` / `complete` | callback / poller drives completion |
| `kthread_run` | `spdk_thread_create` + pin to reactor |

---

## Event functions must be short

Because a reactor runs one thing at a time, any long-running operation blocks all other
pollers and messages on that thread.

Rules:

- poller callbacks should be short and non-blocking
- message handlers should be short and non-blocking
- if work takes multiple steps, split it into a state machine with multiple messages

This is why SPDK code is full of state machines: `enum spdk_nvmf_subsystem_state`,
controller state in `ctrlr.c`, bdev reset sequences. Each state transition is one message
or one poller call.

---

## What matters most after Day 3

1. `spdk_thread` is a logical construct, not a POSIX thread.
2. One reactor per CPU core, spinning forever.
3. Pollers replace interrupt-driven completions.
4. `spdk_thread_send_msg` replaces mutexes for cross-thread coordination.
5. State is owned by a thread. You do not lock it. You message it.
6. Event and poller functions must be short and non-blocking.
7. This model explains every callback pattern you will see in `ctrlr.c` and `subsystem.c`.

---

## Suggested next step

Day 4: `io_channel`. This is the per-thread resource model that sits between SPDK threads
and bdev backends. It is how each thread gets its own private I/O context without locking.
