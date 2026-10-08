#!/usr/bin/env bash
# =============================================================================
# SPDK NVMf Target — Week 2 Lab Scripts
# Days 8, 9, 10: TCP target, AIO backend, host ACLs
#
# Usage:
#   Edit the variables in each section to match your environment.
#   Run each section independently or source this file and call functions.
#
# Requirements:
#   - SPDK built and hugepages/devices set up via scripts/setup.sh
#   - nvmf_tgt running before calling any rpc_* functions
#   - Linux initiator with nvme-cli installed
# =============================================================================

# --- Environment ---------------------------------------------------------------

SPDK_DIR="${SPDK_DIR:-$HOME/spdk}"
RPC="$SPDK_DIR/scripts/rpc.py"
NVMF_TGT="$SPDK_DIR/build/bin/nvmf_tgt"
SPDK_SOCK="/var/tmp/spdk.sock"

# Change these to match your system
AIO_DEV="/dev/sdb"                          # block device for Day 9 AIO bdev
TARGET_IP="192.168.1.10"                    # IP the target listens on
HOST_A_NQN="nqn.2024-01.io.spdk:host-a"   # initiator NQN for host A
HOST_B_NQN="nqn.2024-01.io.spdk:host-b"   # initiator NQN for host B
SUBSYS_NQN="nqn.2024-01.io.spdk:testnqn"  # subsystem NQN

# --- Helper --------------------------------------------------------------------

rpc() {
    python3 "$RPC" -s "$SPDK_SOCK" "$@"
}

wait_for_rpc() {
    echo "Waiting for nvmf_tgt RPC socket..."
    for i in $(seq 1 30); do
        if python3 "$RPC" -s "$SPDK_SOCK" rpc_get_methods &>/dev/null; then
            echo "RPC ready."
            return 0
        fi
        sleep 1
    done
    echo "ERROR: RPC socket not available after 30s" >&2
    return 1
}

# =============================================================================
# DAY 8: Basic TCP target with malloc bdev
# Goal: export one malloc bdev, connect Linux initiator, verify
# =============================================================================

day8_start_target() {
    echo "=== Day 8: Starting nvmf_tgt ==="
    # -m: CPU mask (core 0 only for lab)
    # Adjust -m for your CPU layout
    sudo "$NVMF_TGT" -m 0x1 &
    NVMF_PID=$!
    echo "nvmf_tgt PID: $NVMF_PID"
    wait_for_rpc
}

day8_setup() {
    echo "=== Day 8: Creating TCP transport ==="
    rpc nvmf_create_transport \
        -t TCP \
        -u 16384 \
        -m 8 \
        -c 8192

    echo "=== Day 8: Creating malloc bdev ==="
    # 64MB, 512-byte blocks
    rpc bdev_malloc_create \
        -b Malloc0 \
        67108864 \
        512

    echo "=== Day 8: Verifying bdev ==="
    rpc bdev_get_bdevs -b Malloc0

    echo "=== Day 8: Creating subsystem ==="
    rpc nvmf_create_subsystem \
        "$SUBSYS_NQN" \
        -a \
        -s SPDK00000000000001 \
        -d "SPDK NVMf Target"

    echo "=== Day 8: Adding listener ==="
    rpc nvmf_subsystem_add_listener \
        "$SUBSYS_NQN" \
        -t TCP \
        -a "$TARGET_IP" \
        -s 4420

    echo "=== Day 8: Adding namespace ==="
    rpc nvmf_subsystem_add_ns \
        "$SUBSYS_NQN" \
        Malloc0 \
        -n 1

    echo "=== Day 8: Subsystem state ==="
    rpc nvmf_get_subsystems
}

day8_initiator_connect() {
    echo "=== Day 8: Connect from initiator (run on initiator host) ==="
    cat <<'EOF'
# Run these on the Linux initiator:

# Discover
nvme discover -t tcp -a 192.168.1.10 -s 4420

# Connect
nvme connect -t tcp -a 192.168.1.10 -s 4420 -n nqn.2024-01.io.spdk:testnqn

# List connected namespaces
nvme list

# Check namespace details
nvme id-ns /dev/nvme0n1

# Basic I/O test (read)
dd if=/dev/nvme0n1 of=/dev/null bs=4k count=1024 iflag=direct

# Disconnect
nvme disconnect -n nqn.2024-01.io.spdk:testnqn
EOF
}

day8_teardown() {
    echo "=== Day 8: Teardown ==="
    rpc nvmf_delete_subsystem "$SUBSYS_NQN"
    rpc bdev_malloc_delete Malloc0
    echo "Done. Kill nvmf_tgt manually or:"
    echo "  sudo kill $NVMF_PID"
}

# =============================================================================
# DAY 9: AIO-backed bdev
# Goal: replace malloc with a real block device via AIO bdev
# =============================================================================

day9_setup() {
    echo "=== Day 9: Starting nvmf_tgt ==="
    day8_start_target

    echo "=== Day 9: Creating TCP transport ==="
    rpc nvmf_create_transport -t TCP -u 16384 -m 8 -c 8192

    echo "=== Day 9: Creating AIO bdev from $AIO_DEV ==="
    # Name: Aio0, device: $AIO_DEV, block size: 512
    rpc bdev_aio_create "$AIO_DEV" Aio0 512

    echo "=== Day 9: Verifying AIO bdev ==="
    rpc bdev_get_bdevs -b Aio0

    echo "=== Day 9: Creating subsystem ==="
    rpc nvmf_create_subsystem \
        "$SUBSYS_NQN" \
        -a \
        -s SPDK00000000000001 \
        -d "SPDK AIO Target"

    echo "=== Day 9: Adding listener ==="
    rpc nvmf_subsystem_add_listener \
        "$SUBSYS_NQN" \
        -t TCP \
        -a "$TARGET_IP" \
        -s 4420

    echo "=== Day 9: Adding AIO namespace ==="
    rpc nvmf_subsystem_add_ns \
        "$SUBSYS_NQN" \
        Aio0 \
        -n 1

    echo "=== Day 9: Full subsystem state ==="
    rpc nvmf_get_subsystems

    echo ""
    echo "Verify on initiator:"
    echo "  nvme connect -t tcp -a $TARGET_IP -s 4420 -n $SUBSYS_NQN"
    echo "  nvme id-ns /dev/nvme0n1   # should show real device geometry"
    echo "  nvme id-ctrl /dev/nvme0   # check model string"
}

day9_teardown() {
    echo "=== Day 9: Teardown ==="
    rpc nvmf_delete_subsystem "$SUBSYS_NQN"
    rpc bdev_aio_delete Aio0
}

# =============================================================================
# DAY 10: Host ACLs
# Goal: understand default-deny, allow_any_host, and per-host allow
# =============================================================================

day10_setup_base() {
    echo "=== Day 10: Starting target and transport ==="
    day8_start_target
    rpc nvmf_create_transport -t TCP -u 16384 -m 8 -c 8192
    rpc bdev_malloc_create -b Malloc0 67108864 512
}

day10_test_default_deny() {
    echo "=== Day 10: Test 1 — default deny (no allow_any_host, no allowed hosts) ==="
    rpc nvmf_create_subsystem \
        "$SUBSYS_NQN" \
        -s SPDK00000000000001

    rpc nvmf_subsystem_add_listener \
        "$SUBSYS_NQN" \
        -t TCP \
        -a "$TARGET_IP" \
        -s 4420

    rpc nvmf_subsystem_add_ns "$SUBSYS_NQN" Malloc0 -n 1

    rpc nvmf_get_subsystems

    echo ""
    echo "Expected: connection from any host is REJECTED"
    echo "Initiator test (should fail):"
    echo "  nvme connect -t tcp -a $TARGET_IP -s 4420 -n $SUBSYS_NQN"
    echo "  (expect: Failed to connect)"
    echo ""
    read -p "Press enter after testing default deny..."

    rpc nvmf_delete_subsystem "$SUBSYS_NQN"
}

day10_test_allow_any() {
    echo "=== Day 10: Test 2 — allow_any_host ==="
    rpc nvmf_create_subsystem \
        "$SUBSYS_NQN" \
        -a \
        -s SPDK00000000000001

    rpc nvmf_subsystem_add_listener \
        "$SUBSYS_NQN" \
        -t TCP \
        -a "$TARGET_IP" \
        -s 4420

    rpc nvmf_subsystem_add_ns "$SUBSYS_NQN" Malloc0 -n 1

    echo ""
    echo "Expected: any host can connect"
    echo "Initiator test (should succeed):"
    echo "  nvme connect -t tcp -a $TARGET_IP -s 4420 -n $SUBSYS_NQN"
    echo "  nvme list"
    echo ""
    read -p "Press enter after testing allow_any_host..."

    rpc nvmf_delete_subsystem "$SUBSYS_NQN"
}

day10_test_per_host_allow() {
    echo "=== Day 10: Test 3 — per-host allow list ==="

    echo "Your initiator NQN (run on initiator): cat /etc/nvme/hostnqn"
    echo "Set HOST_A_NQN and HOST_B_NQN in this script to match."
    echo ""

    rpc nvmf_create_subsystem \
        "$SUBSYS_NQN" \
        -s SPDK00000000000001
    # Note: no -a flag — default deny

    rpc nvmf_subsystem_add_listener \
        "$SUBSYS_NQN" \
        -t TCP \
        -a "$TARGET_IP" \
        -s 4420

    rpc nvmf_subsystem_add_ns "$SUBSYS_NQN" Malloc0 -n 1

    echo "=== Adding host A to allowed list ==="
    rpc nvmf_subsystem_add_host "$SUBSYS_NQN" "$HOST_A_NQN"

    echo "=== Current allowed hosts ==="
    rpc nvmf_get_subsystems | python3 -c "
import sys, json
data = json.load(sys.stdin)
for s in data:
    if 'hosts' in s:
        print('Subsystem:', s['nqn'])
        print('Allowed hosts:', s['hosts'])
"

    echo ""
    echo "Expected: host A connects OK, host B is rejected"
    echo "Host A initiator:"
    echo "  nvme connect -t tcp -a $TARGET_IP -s 4420 -n $SUBSYS_NQN --hostnqn $HOST_A_NQN"
    echo "Host B initiator (should fail):"
    echo "  nvme connect -t tcp -a $TARGET_IP -s 4420 -n $SUBSYS_NQN --hostnqn $HOST_B_NQN"
    echo ""
    echo "Now add host B dynamically (no restart needed):"
    echo "  rpc nvmf_subsystem_add_host $SUBSYS_NQN $HOST_B_NQN"
    echo "Then retry host B — should now connect."
    echo ""
    read -p "Press enter after testing per-host allow..."

    rpc nvmf_delete_subsystem "$SUBSYS_NQN"
}

day10_run_all() {
    day10_setup_base
    day10_test_default_deny
    day10_test_allow_any
    day10_test_per_host_allow
    echo "=== Day 10 complete ==="
    echo "Key observations to record:"
    echo "  1. Default is deny — subsystem without -a and no hosts rejects all"
    echo "  2. -a flag (allow_any_host) opens to all initiators"
    echo "  3. Per-host allow list is additive and takes effect immediately"
    echo "  4. Host removal: rpc nvmf_subsystem_remove_host <nqn> <hostnqn>"
}

# =============================================================================
# UTILITY: inspect running state
# =============================================================================

inspect_all() {
    echo "=== Bdevs ==="
    rpc bdev_get_bdevs

    echo ""
    echo "=== Subsystems ==="
    rpc nvmf_get_subsystems

    echo ""
    echo "=== Transports ==="
    rpc nvmf_get_transports

    echo ""
    echo "=== Stats ==="
    rpc bdev_get_iostat
}

# =============================================================================
# UTILITY: full teardown
# =============================================================================

teardown_all() {
    echo "=== Full teardown ==="
    # Remove subsystems first (releases bdev claims)
    for nqn in $(rpc nvmf_get_subsystems | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    if 'discovery' not in s['nqn']:
        print(s['nqn'])
"); do
        echo "Deleting subsystem: $nqn"
        rpc nvmf_delete_subsystem "$nqn"
    done

    # Delete bdevs
    for bdev in Malloc0 Aio0; do
        rpc bdev_get_bdevs -b "$bdev" &>/dev/null && \
            rpc bdev_malloc_delete "$bdev" 2>/dev/null || \
            rpc bdev_aio_delete "$bdev" 2>/dev/null || true
    done

    echo "Done. Kill nvmf_tgt when ready."
}

# =============================================================================
# Main
# =============================================================================

case "${1:-help}" in
    day8-setup)    day8_setup ;;
    day8-connect)  day8_initiator_connect ;;
    day8-teardown) day8_teardown ;;
    day9-setup)    day9_setup ;;
    day9-teardown) day9_teardown ;;
    day10)         day10_run_all ;;
    inspect)       inspect_all ;;
    teardown)      teardown_all ;;
    *)
        echo "Usage: $0 {day8-setup|day8-connect|day8-teardown|day9-setup|day9-teardown|day10|inspect|teardown}"
        echo ""
        echo "Workflow:"
        echo "  1. Edit AIO_DEV, TARGET_IP, HOST_A_NQN, HOST_B_NQN at top of script"
        echo "  2. Run nvmf_tgt manually or via day8_start_target()"
        echo "  3. $0 day8-setup    # malloc bdev, TCP target"
        echo "  4. $0 day8-connect  # print initiator commands"
        echo "  5. $0 day9-setup    # AIO bdev, TCP target"
        echo "  6. $0 day10         # host ACL walkthrough"
        ;;
esac
