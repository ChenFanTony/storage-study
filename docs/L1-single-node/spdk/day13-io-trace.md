# Day 13: Trace One I/O Request End to End

## What this day covers

Connect the code you read in Days 11–12 to a live running target.

Pick one read command, trace it from transport receive through bdev submission and back
to completion. Write the full path with actual function names and the thread each step
runs on.

---

## Goal

By the end of today you should be able to produce this for a read command:

```
[QP thread — poll group thread N]
transport recv poller fires
  -> request object built
  -> spdk_nvmf_request_exec(req)
     -> nvmf_ctrlr_process_io_cmd(req)
        -> ns = _nvmf_subsystem_get_ns(subsystem, nsid=1)
        -> nvmf_ns_reservation_request_check(ns, ctrlr, req)  // no reservation, pass
        -> nvmf_bdev_ctrlr_read_cmd(ns->bdev, ns->desc, ch, req)
           -> spdk_bdev_readv_blocks(desc, ch, iov, iovcnt, lba, nblocks, cb, req)
              [bdev layer dispatches to AIO module]
              [AIO submits io_submit()]
              return (async)
           return ASYNC
        return ASYNC
     return ASYNC
   return (reactor continues)

... later, same thread ...

AIO completion poller fires (io_getevents)
  -> bdev layer calls nvmf_bdev_ctrlr_complete_cmd(bdev_io, true, req)
     -> spdk_bdev_free_io(bdev_io)
     -> spdk_nvmf_request_complete(req)
        -> transport sends CQE to host
```

Fill in actual function names from your Days 11–12 reading and verify them in source.

---

## Method 1: Code trace (no running target needed)

Use `cscope` or `ctags` to navigate the call chain:

```bash
cd $SPDK_DIR
cscope -Rb   # build cscope database
# then use cscope in your editor to follow calls
```

Or use `grep`:

```bash
# Find where spdk_nvmf_request_exec calls into process_io_cmd
grep -n "nvmf_ctrlr_process_io_cmd" lib/nvmf/ctrlr.c

# Find where nvmf_bdev_ctrlr_read_cmd is called
grep -rn "nvmf_bdev_ctrlr_read_cmd" lib/nvmf/

# Find where spdk_bdev_readv_blocks is called in nvmf_bdev.c
grep -n "spdk_bdev_readv_blocks\|spdk_bdev_read" lib/nvmf/nvmf_bdev.c
```

---

## Method 2: Log tracing on a running target

Enable NVMf debug logs:

```bash
sudo $SPDK_DIR/build/bin/nvmf_tgt -m 0x1 \
    --logflag nvmf \
    --logflag bdev \
    2>&1 | tee /tmp/spdk.log &
```

Connect an initiator and run a single read:

```bash
# On initiator
nvme connect -t tcp -a 192.168.1.10 -s 4420 -n nqn.2024-01.io.spdk:testnqn
dd if=/dev/nvme0n1 of=/dev/null bs=4k count=1 iflag=direct
```

Search the log:

```bash
grep -E "read|NSID|bdev|request" /tmp/spdk.log | head -50
```

You will see log lines from `ctrlr.c` and `bdev.c` showing the request moving through
the stack.

---

## Method 3: gdb breakpoints

Start nvmf_tgt under gdb (or attach to running process):

```bash
sudo gdb -p $(pgrep nvmf_tgt)
```

Set breakpoints at key points in the I/O path:

```gdb
# Dispatch gate
b spdk_nvmf_request_exec

# I/O command processing
b nvmf_ctrlr_process_io_cmd

# PR conflict check
b nvmf_ns_reservation_request_check

# bdev read submit
b nvmf_bdev_ctrlr_read_cmd

# completion callback
b nvmf_bdev_ctrlr_complete_cmd

continue
```

Then trigger a read from the initiator:

```bash
dd if=/dev/nvme0n1 of=/dev/null bs=4k count=1 iflag=direct
```

gdb will stop at each breakpoint. Inspect the request struct:

```gdb
# At spdk_nvmf_request_exec
p req->cmd->nvme_cmd.opc       # should be 0x02 (READ)
p req->cmd->nvme_cmd.nsid      # should be 1
p req->qpair->qid              # should be non-zero (I/O queue)

# At nvmf_ns_reservation_request_check
p ns->holder                   # should be NULL (no reservation)
p ns->rtype                    # should be 0

# At nvmf_bdev_ctrlr_read_cmd
p bdev->name                   # should be "Aio0" or "Malloc0"
p offset_blocks                # LBA from the command
p num_blocks                   # block count from the command
```

---

## Deliverable: your I/O trace document

Write `day13-io-trace.md` with:

### Setup used

- bdev type (malloc / AIO)
- one or two hosts
- subsystem NQN

### Read command trace

Fill in the actual function names and thread annotations:

```
[Thread: _________________]

1. Transport receive
   Function: ________________________
   File: lib/nvmf/tcp.c

2. Request exec (dispatch gate)
   Function: ________________________
   File: lib/nvmf/ctrlr.c

3. I/O command handler
   Function: ________________________
   File: lib/nvmf/ctrlr.c

4. PR conflict check
   Function: ________________________
   ns->holder value: ________________
   Result: __________________________

5. bdev read submission
   Function: ________________________
   File: lib/nvmf/nvmf_bdev.c
   Calls into bdev layer: ___________

6. bdev module (AIO/malloc)
   What happens: ___________________

7. Completion callback
   Function: ________________________
   File: lib/nvmf/nvmf_bdev.c

8. Request complete
   Function: ________________________
   File: lib/nvmf/ctrlr.c or transport

Thread switches during normal read: _____ (should be 0)
```

### PR RESERVE command trace (if attempted)

```
[Thread: QP thread]
1. Command dispatch: _________________
2. Reservation handler: ______________
3. Message sent to: __________________
   Function sent: ____________________

[Thread: Subsystem thread]
4. PR state update: __________________
5. Fields written: ___________________
6. Completion sent back to: __________

[Thread: QP thread]
7. Completion handler: _______________
8. CQE sent to host
```

---

## Observations to record

After the trace exercise, write down:

1. How many reactor iterations does a typical AIO read span? (submit in iteration N,
   complete in iteration N+1 or later?)
2. Does the completion always fire on the same thread as submission?
3. What is the `req->qpair->thread` value — is it the same thread you see in gdb?
4. What opcode does a read command have? (check `req->cmd->nvme_cmd.opc`)

---

## What matters most after Day 13

1. You have now seen the full I/O path in running code, not just on paper.
2. Zero thread switches for normal I/O — confirmed empirically.
3. The PR conflict check is a fast path with no side effects when `ns->holder == NULL`.
4. bdev submit and completion happen in separate reactor iterations (AIO) or potentially
   the same iteration (malloc, since malloc completes synchronously in some cases).

---

## Suggested next step

Day 14: review week. Write your own comparison of SPDK `ctrlr.c` dispatch vs Linux
`nvmet` dispatch. Explain in plain language why message passing is used at the subsystem
boundary instead of a mutex.
