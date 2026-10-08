# Day 23: Logging and Debugging

## What this day covers

Make SPDK talk. Enable debug logs, attach gdb to a running target, set targeted
breakpoints, and trace a live request through the functions you have been reading.

---

## SPDK logging system

SPDK uses a flag-based logging system. Each subsystem has a named log flag.

Flags relevant to NVMf work:

| Flag | What it logs |
|---|---|
| `nvmf` | NVMf general: subsystem state, namespace ops, host connect/disconnect |
| `nvmf_tcp` | TCP transport: PDU send/recv, connection events |
| `bdev` | bdev layer: open, close, claim, I/O submit/complete |
| `nvme` | NVMe driver: queue pair ops, completion processing |
| `thread` | SPDK thread: message send/recv, poller registration |

---

## Enabling logs at startup

```bash
sudo $SPDK_DIR/build/bin/nvmf_tgt -m 0x1 \
    --logflag nvmf \
    --logflag nvmf_tcp \
    --logflag bdev \
    2>&1 | tee /tmp/spdk-debug.log &
```

Multiple `--logflag` options are allowed. Logs go to stderr by default.

Warning: `--logflag nvmf_tcp` is very verbose under load. Use it for connection
debugging, then disable for I/O tracing.

---

## Enabling logs at runtime via RPC

```bash
# Enable a log flag on a running target
sudo $SPDK_DIR/scripts/rpc.py log_set_flag nvmf

# Disable a log flag
sudo $SPDK_DIR/scripts/rpc.py log_clear_flag nvmf

# List all available flags
sudo $SPDK_DIR/scripts/rpc.py log_get_flags

# Set overall log level (ERROR, WARNING, NOTICE, INFO, DEBUG)
sudo $SPDK_DIR/scripts/rpc.py log_set_level DEBUG
```

Runtime log flag changes take effect immediately without restarting the target.

---

## What to look for in logs

### Host connect

```
grep "connect\|ctrlr\|hostnqn" /tmp/spdk-debug.log
```

You should see:

- incoming connection from host IP
- hostnqn of the connecting host
- cntlid assigned to the new controller
- subsystem and namespace the controller is attached to

### I/O request

```
grep "read\|write\|NSID\|bdev" /tmp/spdk-debug.log | head -20
```

Look for:

- opcode and NSID for each command
- bdev I/O submit and completion log lines
- thread ID on each log line (shows which thread processed each step)

### PR command

```
grep "reservation\|resv\|PTPL" /tmp/spdk-debug.log
```

Look for:

- reservation command received
- thread switch to subsystem thread
- state update
- PTPL write (if enabled)
- completion sent back

---

## Attaching gdb to a running target

```bash
# Find the PID
pgrep nvmf_tgt

# Attach
sudo gdb -p $(pgrep nvmf_tgt)
```

GDB will stop all threads. To resume:

```gdb
continue
```

To see all threads:

```gdb
info threads
thread apply all bt
```

---

## Useful breakpoints for NVMf debugging

### Breakpoint 1: PR conflict check

```gdb
b nvmf_ns_reservation_request_check
commands
  silent
  printf "PR check: ns=%p holder=%p rtype=%d opc=0x%x\n", ns, ns->holder, ns->rtype, req->cmd->nvme_cmd.opc
  continue
end
```

This prints a line for every I/O command that goes through the PR check without stopping.

### Breakpoint 2: PR state update (subsystem thread)

```gdb
b nvmf_ns_reservation_update
commands
  silent
  printf "PR update on subsystem thread: ns=%p\n", ((struct nvmf_ns_reservation_update_ctx *)ctx)->ns
  bt 3
  continue
end
```

### Breakpoint 3: bdev claim

```gdb
b spdk_bdev_module_claim_bdev
commands
  silent
  printf "bdev claim: bdev=%s module=%s\n", bdev->name, module->name
  continue
end
```

Fire this and watch what happens when you call `nvmf_subsystem_add_ns`. Then try to
add the same bdev to a second subsystem and watch it fail.

### Breakpoint 4: host connect

```gdb
b nvmf_ctrlr_cmd_connect
commands
  silent
  printf "host connect attempt: hostnqn=%s\n", \
    ((struct spdk_nvmf_fabric_connect_cmd *)req->cmd)->hostnqn
  continue
end
```

### Breakpoint 5: namespace lookup

```gdb
b nvmf_ctrlr_process_io_cmd
commands
  silent
  printf "io cmd: nsid=%d opc=0x%x\n", \
    req->cmd->nvme_cmd.nsid, req->cmd->nvme_cmd.opc
  continue
end
```

---

## Trace a PR command live

Setup: one host connected, namespace with no reservation.

In gdb, set:

```gdb
b nvmf_ns_reservation_request_check
b nvmf_ns_reservation_update
```

From the initiator, run:

```bash
nvme resv-register /dev/nvme0n1 --rkey=0xABCD --crkey=0 --racqa=0
```

In gdb you should see:

1. `nvmf_ns_reservation_request_check` hit for the REGISTER admin command
   (REGISTER does not go through the conflict check the same way — find what does)
2. `nvmf_ns_reservation_update` hit on the subsystem thread (different thread ID
   from the QP thread)

Compare the thread IDs to confirm the cross-thread message happened.

---

## Logging thread IDs

SPDK log lines include the thread name. You can also use gdb:

```gdb
# At any breakpoint, see current thread info
thread
p spdk_get_thread()->name
```

This confirms which SPDK thread you are on at each breakpoint.

---

## Useful gdb commands for SPDK

```gdb
# Print bdev list
p spdk_bdev_first()

# Print subsystem list (if you have the tgt pointer)
# Find it from the global or from a request
p req->qpair->ctrlr->subsystem->nqn

# Print ns PR state
p ns->holder
p ns->rtype
p ns->crkey
p ns->registrants   # TAILQ — need to walk it

# Print io_channel state
p ch->thread->name
```

---

## What to record

After the debugging session, write down:

1. what log flags were most useful for your work?
2. which gdb breakpoint gave you the most insight?
3. did you see the cross-thread message for a PR command? What were the thread names?
4. what was surprising about the log output?

---

## What matters most after Day 23

1. `--logflag nvmf` is your first debugging tool — always enable it when something
   is not working.
2. Runtime log flag changes via RPC avoid restarting the target.
3. GDB breakpoints with `commands` blocks let you trace without stopping the reactor.
4. The cross-thread message for PR commands is visible in both logs and gdb thread IDs.

---

## Suggested next step

Day 24: run the SPDK test suite relevant to NVMf. Read `test/nvmf/target/ns_masking.sh`
and understand how SPDK's own tests verify the behaviors you exercised manually.
