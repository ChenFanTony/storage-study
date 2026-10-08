# Day 8: Running a Basic TCP Target

## What this day covers

First end-to-end NVMf lab. Export one malloc bdev through one subsystem over TCP and
connect from a Linux initiator.

The goal is not performance. The goal is to make every component you read about in
Days 1–7 visible in a running system.

---

## What you are building

```
Linux initiator
    | TCP port 4420
    v
nvmf_tgt (SPDK)
    ├── transport: TCP
    ├── subsystem: nqn.2024-01.io.spdk:testnqn
    │     ├── listener: 192.168.1.10:4420
    │     ├── allow_any_host: true
    │     └── namespace NSID 1 -> Malloc0
    └── bdev: Malloc0 (64MB, 512B blocks)
```

---

## Step 1: Prerequisites

Hugepages and device binding must be set up before starting nvmf_tgt:

```bash
sudo $SPDK_DIR/scripts/setup.sh
```

Verify hugepages:

```bash
grep HugePages /proc/meminfo
# HugePages_Total should be non-zero
```

Verify DPDK environment:

```bash
ls /dev/hugepages/
```

---

## Step 2: Start nvmf_tgt

```bash
sudo $SPDK_DIR/build/bin/nvmf_tgt -m 0x1 &
```

`-m 0x1` assigns CPU core 0 to SPDK. For a lab, one core is enough.

Wait for RPC to be ready:

```bash
sudo $SPDK_DIR/scripts/rpc.py rpc_get_methods
# Should print a long list of available RPC methods
```

---

## Step 3: Create TCP transport

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_transport \
    -t TCP \
    -u 16384 \
    -m 8 \
    -c 8192
```

Parameters:

- `-t TCP`: transport type
- `-u 16384`: max I/O size in bytes (16KB)
- `-m 8`: max queue depth
- `-c 8192`: in-capsule data size

Verify:

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_get_transports
```

---

## Step 4: Create malloc bdev

```bash
sudo $SPDK_DIR/scripts/rpc.py bdev_malloc_create \
    -b Malloc0 \
    67108864 \
    512
```

Parameters:

- `-b Malloc0`: bdev name
- `67108864`: size in bytes (64MB)
- `512`: block size in bytes

Verify:

```bash
sudo $SPDK_DIR/scripts/rpc.py bdev_get_bdevs -b Malloc0
```

What to look for in output:

- `block_size`: 512
- `num_blocks`: 131072 (64MB / 512)
- `claimed`: false (not yet claimed by NVMf)
- `driver_specific.malloc`: present

---

## Step 5: Create subsystem

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_subsystem \
    nqn.2024-01.io.spdk:testnqn \
    -a \
    -s SPDK00000000000001 \
    -d "SPDK NVMf Target"
```

Parameters:

- `nqn.2024-01.io.spdk:testnqn`: subsystem NQN (must be globally unique)
- `-a`: allow_any_host (any initiator can connect)
- `-s`: serial number
- `-d`: model string shown in identify controller

---

## Step 6: Add listener

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_listener \
    nqn.2024-01.io.spdk:testnqn \
    -t TCP \
    -a 192.168.1.10 \
    -s 4420
```

Replace `192.168.1.10` with the IP of your target system.

---

## Step 7: Add namespace

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.2024-01.io.spdk:testnqn \
    Malloc0 \
    -n 1
```

After this call, Malloc0 is **claimed** by NVMf. Verify:

```bash
sudo $SPDK_DIR/scripts/rpc.py bdev_get_bdevs -b Malloc0
# claimed: true
```

This is the bdev claim from your PR conclusion. Attempting to add Malloc0 to a second
subsystem now will fail.

---

## Step 8: Verify full subsystem state

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_get_subsystems
```

Confirm:

- subsystem NQN present
- listener with correct IP and port
- namespace with NSID 1 and bdev_name Malloc0
- `allow_any_host: true`

---

## Step 9: Connect from Linux initiator

On the initiator host:

```bash
# Load NVMf TCP driver
sudo modprobe nvme-tcp

# Discover
nvme discover -t tcp -a 192.168.1.10 -s 4420

# Connect
nvme connect -t tcp -a 192.168.1.10 -s 4420 \
    -n nqn.2024-01.io.spdk:testnqn

# List connected devices
nvme list
# Should show /dev/nvme0 or similar

# Check namespace details
nvme id-ns /dev/nvme0n1
# block_size: 512, nsze: 131072

# Check controller details
nvme id-ctrl /dev/nvme0
# model: SPDK NVMf Target
# serial: SPDK00000000000001

# Simple read test
dd if=/dev/nvme0n1 of=/dev/null bs=4k count=1024 iflag=direct
```

---

## Step 10: Teardown

```bash
# On initiator
nvme disconnect -n nqn.2024-01.io.spdk:testnqn

# On target
sudo $SPDK_DIR/scripts/rpc.py nvmf_delete_subsystem nqn.2024-01.io.spdk:testnqn
sudo $SPDK_DIR/scripts/rpc.py bdev_malloc_delete Malloc0
# Kill nvmf_tgt
sudo kill $(pgrep nvmf_tgt)
```

---

## What to observe and record

After completing the lab, write down:

1. What does `bdev_get_bdevs` show before and after `nvmf_subsystem_add_ns`? What field changes?
2. What does `nvme id-ctrl` show? Where do the model and serial values come from in the RPC call?
3. What does `nvme id-ns` show for block size and namespace size?
4. What happens if you try to add Malloc0 to a second subsystem while it is already claimed?

---

## What matters most after Day 8

1. The RPC sequence maps directly to the code path: transport → bdev → subsystem → listener → namespace.
2. `nvmf_subsystem_add_ns` triggers the bdev claim.
3. `nvmf_get_subsystems` is your primary inspection tool while the target is running.
4. The malloc bdev is volatile: all data is lost when the bdev is deleted or the target restarts.

---

## Suggested next step

Day 9: replace Malloc0 with a real block device using the AIO bdev. Same RPC flow,
real storage behind it.
