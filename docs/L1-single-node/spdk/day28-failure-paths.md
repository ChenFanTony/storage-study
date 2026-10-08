# Day 28: Failure Path Lab

## What this day covers

Intentionally break things and observe how SPDK handles them. Failure paths are where
bugs hide, and understanding them is essential before modifying production code.

---

## Why test failure paths

- failure handling is rarely tested in normal operation
- bugs in teardown paths cause memory leaks and resource exhaustion
- PTPL correctness depends on clean failure behavior
- understanding what breaks helps you write better code

---

## Lab 1: Remove namespace while host is connected and doing I/O

### Setup

```bash
sudo $SPDK_DIR/build/bin/nvmf_tgt -m 0x1 &
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_transport -t TCP -u 16384 -m 8 -c 8192
sudo $SPDK_DIR/scripts/rpc.py bdev_aio_create /dev/sdb Aio0 512
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_subsystem \
    nqn.2024-01.io.spdk:fail -a -s SPDK00000000000001
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_listener \
    nqn.2024-01.io.spdk:fail -t TCP -a 192.168.1.10 -s 4420
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.2024-01.io.spdk:fail Aio0 -n 1
```

Connect initiator and start background I/O:

```bash
nvme connect -t tcp -a 192.168.1.10 -s 4420 -n nqn.2024-01.io.spdk:fail

# Start continuous I/O in background
sudo fio --filename=/dev/nvme0n1 --rw=randread --bs=4k \
    --iodepth=32 --time_based --runtime=60 --ioengine=io_uring \
    --direct=1 --name=bg-io &
FIO_PID=$!
```

Now remove the namespace while I/O is running:

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_remove_ns \
    nqn.2024-01.io.spdk:fail 1
```

Observe:

1. Does the RPC return immediately or block until I/O drains?
2. What does fio report? (errors? completion? hang?)
3. Check dmesg on the initiator
4. Check SPDK logs on the target

```bash
# After removal
sudo $SPDK_DIR/scripts/rpc.py nvmf_get_subsystems
# Namespace should be gone

# Kill fio if it is hung
kill $FIO_PID
```

---

## Lab 2: Disconnect host mid-session

Start a host with active I/O, then forcibly disconnect at the TCP level:

```bash
# On initiator: start I/O
sudo fio --filename=/dev/nvme0n1 --rw=randwrite --bs=4k \
    --iodepth=16 --time_based --runtime=60 --ioengine=io_uring \
    --direct=1 --name=mid-io &

# Find the TCP connection from the target side
ss -tnp | grep 4420

# Kill the connection by resetting the socket (on target)
# Option 1: use tc to drop packets (simulate network failure)
sudo tc qdisc add dev eth0 root netem loss 100%

sleep 3

sudo tc qdisc del dev eth0 root
```

Or more simply, just disconnect the initiator abruptly:

```bash
# Abrupt disconnect (no graceful NVMf disconnect)
sudo ip link set eth0 down
sleep 2
sudo ip link set eth0 up
```

Observe on the target:

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_get_subsystems
# Controller should eventually disappear (keep-alive timeout)

sudo $SPDK_DIR/scripts/rpc.py bdev_get_bdevs -b Aio0
# claimed: should still be true (bdev still in subsystem)
```

How long until the target detects the dead connection? Check SPDK logs for keepalive
timeout messages.

---

## Lab 3: Kill and restart target, then reapply config

This exercises the stateless restart model.

While a host is connected with I/O running, kill the target:

```bash
# Kill target abruptly (not graceful)
sudo kill -9 $(pgrep nvmf_tgt)
```

Observe on initiator:

```bash
# I/O should fail
dmesg | tail -10
# NVMe device should report errors or disconnect

nvme list
# Device may remain listed until kernel times out
```

Now restart and reapply the full config:

```bash
sudo $SPDK_DIR/build/bin/nvmf_tgt -m 0x1 &
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_transport -t TCP -u 16384 -m 8 -c 8192
sudo $SPDK_DIR/scripts/rpc.py bdev_aio_create /dev/sdb Aio0 512
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_subsystem \
    nqn.2024-01.io.spdk:fail -a -s SPDK00000000000001
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_listener \
    nqn.2024-01.io.spdk:fail -t TCP -a 192.168.1.10 -s 4420
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.2024-01.io.spdk:fail Aio0 -n 1
```

On initiator, attempt reconnect:

```bash
nvme connect -t tcp -a 192.168.1.10 -s 4420 -n nqn.2024-01.io.spdk:fail
nvme list
# Should reconnect and show the namespace
```

---

## Lab 4: PTPL behavior under abrupt restart

Configure PTPL, set a reservation, kill the target without graceful shutdown:

```bash
# With PTPL configured (from Day 17 setup)
# Acquire reservation from Host A
nvme resv-register /dev/nvme0n1 --rkey=0xABCD --crkey=0 --racqa=0
nvme resv-acquire /dev/nvme0n1 --rkey=0xABCD --rtype=1 --racqa=0
nvme set-feature /dev/nvme0n1 -f 0x83 -v 1  # enable PTPL

# Kill target abruptly
sudo kill -9 $(pgrep nvmf_tgt)

# Check: was the PTPL file written before the kill?
cat /var/lib/nvmf-ptpl/aio0-ns1.json
```

Key question: is the PTPL file written synchronously on every state change, or only
at shutdown? An abrupt kill reveals this.

If the file shows the reservation: PTPL writes are synchronous (written on each state
change, which is the correct SPDK behavior).

If the file is missing or stale: PTPL writes may be batched or asynchronous, which
would be a bug.

Restart and re-add with PTPL file, then verify:

```bash
# Restart target and re-add namespace with ptpl-file
# Then reconnect Host A and check reservation state
nvme resv-report /dev/nvme0n1 --eds
```

---

## Lab 5: Add namespace with invalid parameters

Test error handling:

```bash
# Non-existent bdev
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.2024-01.io.spdk:fail NoSuchBdev -n 1
# Expected: error

# Invalid NSID (0 is invalid in NVMe)
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.2024-01.io.spdk:fail Aio0 -n 0
# Expected: error or auto-assignment

# NSID already in use
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.2024-01.io.spdk:fail Aio0 -n 1
# add once...
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.2024-01.io.spdk:fail Aio1 -n 1
# Expected: error — NSID 1 already in use
```

For each error case, record the exact error message and return code. These are what
you improve in Day 26 type contributions.

---

## What to record

| Failure scenario | Target behavior | Initiator behavior | Data integrity? |
|---|---|---|---|
| Namespace removed mid-I/O | | | |
| Host TCP killed | | | |
| Target killed -9 | | | |
| Target restarted, reconnect | | | |
| PTPL after kill -9 | | | |

---

## What matters most after Day 28

1. SPDK's stateless model means restart + reapply config is the recovery procedure.
2. PTPL writes should be synchronous — verify this empirically.
3. Namespace removal while I/O is active goes through subsystem pause — observe the delay.
4. Keepalive timeout is the mechanism for detecting dead hosts — find its default value.
5. Understanding failure paths is what separates a debugger from a reader.

---

## Suggested next step

Day 29: build a reusable lab guide that documents everything you have learned in
reproducible script form. This is your personal reference for future SPDK work.
