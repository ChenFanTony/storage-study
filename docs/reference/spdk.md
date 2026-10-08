# SPDK

SPDK (Storage Performance Development Kit) moves storage data paths into user
space and normally uses polling instead of hardware interrupts. This trades
dedicated CPU time for low and predictable I/O latency.

## NVMe Polling versus IRQ Completion

An NVMe controller places completion queue entries into DMA-accessible host
memory. With interrupt-driven I/O, it then raises an MSI-X interrupt so the
kernel can process those entries. With SPDK polling, a user-space thread checks
the completion queue directly, so no interrupt is required for each completion.

```text
SPDK polling                             Traditional IRQ path

application submits I/O                  application submits I/O
          |                                        |
          v                                        v
NVMe processes command                   NVMe processes command
          |                                        |
          | DMA completion to memory               | DMA completion to memory
          v                                        v
CPU polls completion queue               device raises MSI-X interrupt
          |                                        |
          v                                        v
callback runs on polling thread           kernel interrupt handler runs
                                                   |
                                                   v
                                          application is notified/woken
```

Polling does **not** repeatedly send a command across PCIe. The CPU normally
reads the next expected completion queue entry from memory and checks whether
its phase bit has changed.

| Property | SPDK polling | IRQ-driven I/O |
|----------|--------------|----------------|
| Completion detection | CPU checks the completion queue | Device interrupts the CPU |
| Idle CPU consumption | High; often one dedicated core | Low |
| Completion latency | Low and predictable | Includes interrupt and wake-up delay |
| Context switches | Usually none in the fast path | Often involves kernel and scheduler work |
| High sustained IOPS | Avoids interrupt storms and batches efficiently | Interrupt overhead can become expensive |
| Light or idle workload | May waste CPU and power | Usually more efficient |

## `spdk_nvme_qpair_process_completions()`

The public NVMe polling API is:

```c
int32_t spdk_nvme_qpair_process_completions(
    struct spdk_nvme_qpair *qpair,
    uint32_t max_completions);
```

One call performs **one non-blocking poll**. It processes completions that are
ready at that moment and then returns; it does not wait for an outstanding
command to finish. The caller creates continuous polling by calling it
repeatedly:

```c
while (!done) {
    int32_t rc;

    rc = spdk_nvme_qpair_process_completions(qpair, 0);
    if (rc < 0) {
        /* The qpair or transport failed. */
        break;
    }
}
```

This distinction is important:

```text
one function call       = inspect and drain ready completions once
function called in loop = polling
```

### Arguments and return value

| Item | Meaning |
|------|---------|
| `qpair` | The NVMe submission/completion queue pair to inspect |
| `max_completions == 0` | Process all completions currently available |
| `max_completions > 0` | Process at most this many completions in this call |
| return `> 0` | Number of completions processed |
| return `0` | No completion was ready; this is not an error |
| return `< 0` | An error occurred |
| return `-ENXIO` | The qpair failed at the transport layer |

A positive limit provides a fairness budget. For example, a reactor can drain
at most 32 entries from one busy qpair before servicing other work:

```c
int32_t completed;

completed = spdk_nvme_qpair_process_completions(qpair, 32);
```

### What the function does

For a PCIe NVMe qpair, the flow is conceptually:

```text
1. Examine the completion entry at the current CQ head.
2. Check its phase bit to determine whether it is new.
3. Read the command identifier (CID).
4. Use the CID to find the original SPDK request.
5. Advance the completion queue head.
6. Invoke the request's completion callback.
7. Repeat until the queue has no ready entry or the budget is reached.
8. Ring the CQ-head doorbell so the controller can reuse consumed slots.
9. Return the number of completions processed.
```

SPDK supports transports other than PCIe, so transport-specific internals can
differ. The public API behavior remains non-blocking completion processing.

## Submission and Callback Flow

SPDK NVMe command functions submit work asynchronously. For example:

```c
rc = spdk_nvme_ns_cmd_read(ns, qpair, buffer,
                            lba, lba_count,
                            read_complete, context, 0);
```

A successful return means the request was accepted for submission, not that
the read has completed. Later polling discovers its completion and invokes:

```c
read_complete(context, completion);
```

The callback runs synchronously inside the call that processes completions:

```text
spdk_nvme_qpair_process_completions()
    |
    +-- complete request A -> callback_A()
    +-- complete request B -> callback_B()
    `-- return 2
```

Consequently, callbacks should avoid blocking or doing long-running work. A
slow callback delays the return to the poll loop and therefore delays other
I/O completions on that thread.

## Thread Ownership

The caller must ensure that only one thread uses a qpair at a time. A common
layout assigns one qpair to an SPDK thread pinned to one CPU core:

```text
CPU core 2
  `-- SPDK thread/reactor
        +-- submit commands through qpair 1
        `-- process completions from qpair 1
```

Single-thread ownership removes locks from the qpair's fast path and keeps its
queue metadata cache-local. It is unsafe for two threads to submit or process
completions on the same qpair concurrently without external serialization.

## Related Completion APIs

- `spdk_nvme_ctrlr_process_admin_completions()` processes an NVMe controller's
  admin-queue completions.
- `spdk_nvme_poll_group_process_completions()` processes the qpairs collected
  in an NVMe poll group and is useful when one thread owns several qpairs.
- Direct NVMe-library applications may call the qpair function themselves;
  SPDK framework applications commonly let reactor pollers drive completion
  processing.

## References

- [SPDK NVMe API reference](https://spdk.io/doc/nvme_8h.html)
- [SPDK NVMe driver documentation](https://spdk.io/doc/nvme.html)
- [SPDK NVMe design notes](https://github.com/spdk/spdk/blob/master/doc/nvme_spec.md)
- [SPDK NVMe hello-world polling example](https://github.com/spdk/spdk/blob/master/examples/nvme/hello_world/hello_world.c)
