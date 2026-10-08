# Day 9: AIO-Backed bdev

## What this day covers

Replace the malloc bdev with a real block device or file using the AIO bdev module.

This is the first time I/O actually reaches persistent storage. It is also the first
time you will see the bdev abstraction working: the NVMf layer does not change at all —
only the bdev backend changes.

---

## What changes from Day 8

The entire NVMf setup (transport, subsystem, listener, host config) is identical.
Only the bdev creation command changes:

```
Day 8: bdev_malloc_create  -> Malloc0 (in-memory)
Day 9: bdev_aio_create     -> Aio0    (kernel AIO on file or block device)
```

Everything above the bdev layer — ctrlr.c, subsystem.c, namespace state, PR — is
completely unchanged. This is what the bdev abstraction means in practice.

---

## Option A: AIO bdev from a block device

Use a spare block device. Do not use a device with data you care about.

```bash
sudo $SPDK_DIR/scripts/rpc.py bdev_aio_create \
    /dev/sdb \
    Aio0 \
    512
```

Parameters:

- `/dev/sdb`: the backing Linux block device
- `Aio0`: bdev name
- `512`: block size (must match the device's physical block size or be a valid override)

Verify:

```bash
sudo $SPDK_DIR/scripts/rpc.py bdev_get_bdevs -b Aio0
```

What to check:

- `num_blocks`: should match `blockdev --getsize64 /dev/sdb` / 512
- `block_size`: 512
- `driver_specific.aio.filename`: `/dev/sdb`

---

## Option B: AIO bdev from a file

If you do not have a spare block device, create a file:

```bash
# Create a 1GB sparse file
truncate -s 1G /tmp/spdk-test.img

sudo $SPDK_DIR/scripts/rpc.py bdev_aio_create \
    /tmp/spdk-test.img \
    Aio0 \
    512
```

This works for lab purposes. Performance will be lower than a real block device.

---

## Full setup sequence

```bash
# 1. Start target
sudo $SPDK_DIR/build/bin/nvmf_tgt -m 0x1 &
sudo $SPDK_DIR/scripts/rpc.py rpc_get_methods  # wait for RPC

# 2. Transport
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_transport \
    -t TCP -u 16384 -m 8 -c 8192

# 3. AIO bdev
sudo $SPDK_DIR/scripts/rpc.py bdev_aio_create /dev/sdb Aio0 512

# 4. Subsystem
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_subsystem \
    nqn.2024-01.io.spdk:testnqn \
    -a -s SPDK00000000000001 -d "SPDK AIO Target"

# 5. Listener
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_listener \
    nqn.2024-01.io.spdk:testnqn \
    -t TCP -a 192.168.1.10 -s 4420

# 6. Namespace
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.2024-01.io.spdk:testnqn \
    Aio0 -n 1
```

---

## Connect from initiator

```bash
# Load driver
sudo modprobe nvme-tcp

# Connect
nvme connect -t tcp -a 192.168.1.10 -s 4420 \
    -n nqn.2024-01.io.spdk:testnqn

# Verify geometry matches the backing device
nvme id-ns /dev/nvme0n1
# nsze should match /dev/sdb size in blocks

# Write test
sudo dd if=/dev/urandom of=/dev/nvme0n1 bs=4k count=256 oflag=direct

# Read back (verify I/O reaches device)
sudo dd if=/dev/nvme0n1 of=/dev/null bs=4k count=256 iflag=direct

# Disconnect
nvme disconnect -n nqn.2024-01.io.spdk:testnqn
```

After the write test, verify on the target that data actually reached the backing device:

```bash
# If using a file
xxd /tmp/spdk-test.img | head -20
# Should show non-zero bytes if write succeeded
```

---

## AIO bdev internals (brief)

The AIO bdev module uses Linux kernel AIO (`io_submit` / `io_getevents`) to submit
and complete I/O asynchronously.

It registers a poller on the SPDK thread that calls `io_getevents` to check for
completed operations on every reactor iteration. This is the same polling model as
everything else in SPDK — no blocking wait, no interrupt.

Key difference from the NVMe bdev:

- NVMe bdev: SPDK's own user-space NVMe driver, bypasses kernel entirely
- AIO bdev: goes through kernel AIO, involves kernel I/O path and scheduler

For a lab, AIO is sufficient. For production latency-sensitive work, the NVMe bdev
with direct device access is preferred.

---

## io_uring bdev (optional)

If your kernel supports io_uring (5.1+):

```bash
sudo $SPDK_DIR/scripts/rpc.py bdev_uring_create \
    /dev/sdb \
    Uring0 \
    512
```

io_uring bdev is similar to AIO but uses the newer Linux io_uring interface.
Generally lower latency than AIO for storage workloads.

Use exactly like Aio0 — just substitute Uring0 in the namespace add command.

---

## Teardown

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_delete_subsystem nqn.2024-01.io.spdk:testnqn
sudo $SPDK_DIR/scripts/rpc.py bdev_aio_delete Aio0
sudo kill $(pgrep nvmf_tgt)
```

---

## What to observe and record

1. Does `nvme id-ns` on the initiator show the same geometry as `blockdev --getsize64 /dev/sdb`?
2. Does a write from the initiator actually persist on the backing device after disconnect and reconnect?
3. What does `bdev_get_bdevs -b Aio0` show differently from `bdev_get_bdevs -b Malloc0`?
4. What error does SPDK return if you specify the wrong block size for the AIO bdev?

---

## What matters most after Day 9

1. The NVMf layer is completely unchanged between Day 8 and Day 9. Only the bdev name changes.
2. This is the bdev abstraction working exactly as designed.
3. AIO bdev uses kernel AIO with a poller — still fits the SPDK polling model.
4. Data now persists: write from initiator → survives disconnect → readable after reconnect.

---

## Suggested next step

Day 10: host ACLs. Right now the subsystem uses `-a` (allow_any_host). Day 10 tests
what happens without it and how per-host allow lists work.
