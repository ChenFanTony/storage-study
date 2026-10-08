# Day 29: Reusable Lab Guide

## What this day covers

Consolidate everything into a set of reusable, well-documented scripts that you can
run from scratch to reproduce any topology from the 30-day plan.

---

## Why build this now

- you will come back to this environment months from now with no memory of the setup
- reproducible scripts are how SPDK developers share and validate configurations
- this guide is the deliverable that proves you own the material

---

## Script 1: Environment setup (run once per boot)

```bash
#!/usr/bin/env bash
# spdk-env-setup.sh
# Run once after each system boot before starting nvmf_tgt

set -e

SPDK_DIR="${SPDK_DIR:-$HOME/spdk}"

echo "=== Setting up SPDK environment ==="

# Bind NVMe devices to vfio-pci (if using NVMe passthrough)
# Skip this section if using AIO only
# sudo $SPDK_DIR/scripts/setup.sh

# Setup hugepages only
echo "Setting up hugepages..."
echo 1024 | sudo tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# Verify
HUGE=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages)
echo "Hugepages allocated: $HUGE"

if [ "$HUGE" -lt 512 ]; then
    echo "ERROR: Not enough hugepages. Need at least 512."
    exit 1
fi

# Load nvme-tcp on initiator hosts
# sudo modprobe nvme-tcp

echo "Environment ready."
```

---

## Script 2: Recipe A — single host, AIO bdev

```bash
#!/usr/bin/env bash
# recipe-a-single-host.sh
# One host, one AIO-backed namespace over TCP

set -e

SPDK_DIR="${SPDK_DIR:-$HOME/spdk}"
RPC="sudo python3 $SPDK_DIR/scripts/rpc.py"
AIO_DEV="${AIO_DEV:-/dev/sdb}"
TARGET_IP="${TARGET_IP:-192.168.1.10}"
NQN="nqn.2024-01.io.spdk:single"

cleanup() {
    echo "=== Cleanup ==="
    $RPC nvmf_delete_subsystem "$NQN" 2>/dev/null || true
    $RPC bdev_aio_delete Aio0 2>/dev/null || true
    sudo pkill nvmf_tgt 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Starting nvmf_tgt ==="
sudo "$SPDK_DIR/build/bin/nvmf_tgt" -m 0x1 &
sleep 3
$RPC rpc_get_methods > /dev/null
echo "RPC ready."

echo "=== Creating transport ==="
$RPC nvmf_create_transport -t TCP -u 16384 -m 8 -c 8192

echo "=== Creating AIO bdev from $AIO_DEV ==="
$RPC bdev_aio_create "$AIO_DEV" Aio0 512
$RPC bdev_get_bdevs -b Aio0

echo "=== Creating subsystem ==="
$RPC nvmf_create_subsystem "$NQN" -a -s SPDK00000000000001 -d "Single Host"
$RPC nvmf_subsystem_add_listener "$NQN" -t TCP -a "$TARGET_IP" -s 4420
$RPC nvmf_subsystem_add_ns "$NQN" Aio0 -n 1

echo ""
echo "=== Target ready ==="
echo "Connect from initiator:"
echo "  nvme connect -t tcp -a $TARGET_IP -s 4420 -n $NQN"
echo ""
echo "Press Ctrl+C to teardown."
wait
```

---

## Script 3: Recipe B — two hosts, shared namespace

```bash
#!/usr/bin/env bash
# recipe-b-shared-ns.sh
# Two hosts, one shared namespace, same PR domain

set -e

SPDK_DIR="${SPDK_DIR:-$HOME/spdk}"
RPC="sudo python3 $SPDK_DIR/scripts/rpc.py"
AIO_DEV="${AIO_DEV:-/dev/sdb}"
TARGET_IP="${TARGET_IP:-192.168.1.10}"
NQN="nqn.2024-01.io.spdk:shared"

cleanup() {
    $RPC nvmf_delete_subsystem "$NQN" 2>/dev/null || true
    $RPC bdev_aio_delete Aio0 2>/dev/null || true
    sudo pkill nvmf_tgt 2>/dev/null || true
}
trap cleanup EXIT

sudo "$SPDK_DIR/build/bin/nvmf_tgt" -m 0x1 &
sleep 3
$RPC rpc_get_methods > /dev/null

$RPC nvmf_create_transport -t TCP -u 16384 -m 8 -c 8192
$RPC bdev_aio_create "$AIO_DEV" Aio0 512
$RPC nvmf_create_subsystem "$NQN" -a -s SPDK00000000000001 -d "Shared NS"
$RPC nvmf_subsystem_add_listener "$NQN" -t TCP -a "$TARGET_IP" -s 4420
$RPC nvmf_subsystem_add_ns "$NQN" Aio0 -n 1

echo "=== Shared namespace target ready ==="
echo "Both hosts connect to same NQN — same NSID, same PR domain:"
echo "  nvme connect -t tcp -a $TARGET_IP -s 4420 -n $NQN"
echo ""
echo "Press Ctrl+C to teardown."
wait
```

---

## Script 4: Recipe C — two hosts, exclusive namespaces

```bash
#!/usr/bin/env bash
# recipe-c-exclusive-ns.sh
# Two hosts, separate namespaces, per-host visibility

set -e

SPDK_DIR="${SPDK_DIR:-$HOME/spdk}"
RPC="sudo python3 $SPDK_DIR/scripts/rpc.py"
AIO_DEV_A="${AIO_DEV_A:-/dev/sdb}"
AIO_DEV_B="${AIO_DEV_B:-/dev/sdc}"
TARGET_IP="${TARGET_IP:-192.168.1.10}"
NQN="nqn.2024-01.io.spdk:exclusive"
HOST_A_NQN="${HOST_A_NQN:?Set HOST_A_NQN}"
HOST_B_NQN="${HOST_B_NQN:?Set HOST_B_NQN}"

cleanup() {
    $RPC nvmf_delete_subsystem "$NQN" 2>/dev/null || true
    $RPC bdev_aio_delete Aio0 2>/dev/null || true
    $RPC bdev_aio_delete Aio1 2>/dev/null || true
    sudo pkill nvmf_tgt 2>/dev/null || true
}
trap cleanup EXIT

sudo "$SPDK_DIR/build/bin/nvmf_tgt" -m 0x1 &
sleep 3
$RPC rpc_get_methods > /dev/null

$RPC nvmf_create_transport -t TCP -u 16384 -m 8 -c 8192
$RPC bdev_aio_create "$AIO_DEV_A" Aio0 512
$RPC bdev_aio_create "$AIO_DEV_B" Aio1 512

$RPC nvmf_create_subsystem "$NQN" -a -s SPDK00000000000001 -d "Exclusive NS"
$RPC nvmf_subsystem_add_listener "$NQN" -t TCP -a "$TARGET_IP" -s 4420

# Both namespaces: no-auto-visible
$RPC nvmf_subsystem_add_ns "$NQN" Aio0 -n 1 --no-auto-visible
$RPC nvmf_subsystem_add_ns "$NQN" Aio1 -n 2 --no-auto-visible

# Grant exclusive visibility
$RPC nvmf_ns_add_host "$NQN" 1 "$HOST_A_NQN"
$RPC nvmf_ns_add_host "$NQN" 2 "$HOST_B_NQN"

echo "=== Exclusive namespace target ready ==="
echo "Host A ($HOST_A_NQN): sees NSID 1 ($AIO_DEV_A)"
echo "Host B ($HOST_B_NQN): sees NSID 2 ($AIO_DEV_B)"
echo ""
echo "Both connect to: nvme connect -t tcp -a $TARGET_IP -s 4420 -n $NQN"
echo ""
echo "Press Ctrl+C to teardown."
wait
```

Usage:

```bash
HOST_A_NQN="nqn.2014-08.org.nvmexpress:uuid:aaa" \
HOST_B_NQN="nqn.2014-08.org.nvmexpress:uuid:bbb" \
AIO_DEV_A=/dev/sdb \
AIO_DEV_B=/dev/sdc \
TARGET_IP=192.168.1.10 \
./recipe-c-exclusive-ns.sh
```

---

## Script 5: Recipe D — shared namespace with PTPL

```bash
#!/usr/bin/env bash
# recipe-d-ptpl.sh
# One namespace with PTPL enabled

set -e

SPDK_DIR="${SPDK_DIR:-$HOME/spdk}"
RPC="sudo python3 $SPDK_DIR/scripts/rpc.py"
AIO_DEV="${AIO_DEV:-/dev/sdb}"
TARGET_IP="${TARGET_IP:-192.168.1.10}"
NQN="nqn.2024-01.io.spdk:ptpl"
PTPL_DIR="/var/lib/nvmf-ptpl"
PTPL_FILE="$PTPL_DIR/aio0-ns1.json"

sudo mkdir -p "$PTPL_DIR"

cleanup() {
    $RPC nvmf_delete_subsystem "$NQN" 2>/dev/null || true
    $RPC bdev_aio_delete Aio0 2>/dev/null || true
    sudo pkill nvmf_tgt 2>/dev/null || true
}
trap cleanup EXIT

sudo "$SPDK_DIR/build/bin/nvmf_tgt" -m 0x1 &
sleep 3
$RPC rpc_get_methods > /dev/null

$RPC nvmf_create_transport -t TCP -u 16384 -m 8 -c 8192
$RPC bdev_aio_create "$AIO_DEV" Aio0 512
$RPC nvmf_create_subsystem "$NQN" -a -s SPDK00000000000001 -d "PTPL Target"
$RPC nvmf_subsystem_add_listener "$NQN" -t TCP -a "$TARGET_IP" -s 4420
$RPC nvmf_subsystem_add_ns "$NQN" Aio0 -n 1 --ptpl-file "$PTPL_FILE"

echo "=== PTPL target ready ==="
echo "Namespace: NSID 1, PTPL file: $PTPL_FILE"
echo "Connect: nvme connect -t tcp -a $TARGET_IP -s 4420 -n $NQN"
echo ""
echo "After acquiring a reservation, check: cat $PTPL_FILE"
echo ""
echo "Press Ctrl+C to teardown."
wait
```

---

## Quick reference card

Save this as `spdk-quick-ref.md`:

```markdown
# SPDK NVMf Quick Reference

## Start target
nvmf_tgt -m 0x1 &

## Transport
rpc nvmf_create_transport -t TCP -u 16384 -m 8 -c 8192

## bdev
rpc bdev_malloc_create -b Malloc0 67108864 512
rpc bdev_aio_create /dev/sdb Aio0 512
rpc bdev_aio_delete Aio0
rpc bdev_get_bdevs [-b <name>]

## Subsystem
rpc nvmf_create_subsystem <nqn> -a -s <serial>
rpc nvmf_delete_subsystem <nqn>
rpc nvmf_get_subsystems

## Listener
rpc nvmf_subsystem_add_listener <nqn> -t TCP -a <ip> -s 4420

## Namespace
rpc nvmf_subsystem_add_ns <nqn> <bdev> -n <nsid>
rpc nvmf_subsystem_add_ns <nqn> <bdev> -n <nsid> --no-auto-visible
rpc nvmf_subsystem_add_ns <nqn> <bdev> -n <nsid> --ptpl-file <path>
rpc nvmf_subsystem_remove_ns <nqn> <nsid>

## Host ACL
rpc nvmf_subsystem_add_host <nqn> <hostnqn>
rpc nvmf_subsystem_remove_host <nqn> <hostnqn>
rpc nvmf_subsystem_allow_any_host <nqn> [-e|-d]

## Namespace visibility
rpc nvmf_ns_add_host <nqn> <nsid> <hostnqn>
rpc nvmf_ns_remove_host <nqn> <nsid> <hostnqn>

## Initiator
nvme discover -t tcp -a <ip> -s 4420
nvme connect -t tcp -a <ip> -s 4420 -n <nqn>
nvme disconnect -n <nqn>
nvme list
nvme id-ns /dev/nvme0n1
nvme resv-report /dev/nvme0n1 --eds
nvme resv-register /dev/nvme0n1 --rkey=0xABCD --crkey=0 --racqa=0
nvme resv-acquire /dev/nvme0n1 --rkey=0xABCD --rtype=1 --racqa=0

## Debug
rpc log_set_flag nvmf
rpc log_set_flag nvmf_tcp
rpc log_clear_flag nvmf
sudo gdb -p $(pgrep nvmf_tgt)
```

---

## What matters most after Day 29

1. Reproducible scripts mean you can rebuild any lab environment in minutes.
2. The recipes cover every topology from the 30-day plan.
3. The quick reference card is your daily driver for the next 12 months.
4. Environment variables (`AIO_DEV`, `TARGET_IP`, `HOST_A_NQN`) make scripts portable.

---

## Suggested next step

Day 30: final lab. From scratch, no notes, reproduce all topologies and explain PR
behavior clearly. This is the test of whether the 30 days worked.
