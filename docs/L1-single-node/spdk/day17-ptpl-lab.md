# Day 17: PTPL Lab

## What this day covers

Persist Through Power Loss (PTPL) allows PR state to survive a target restart.

Today you will:

1. configure a namespace with a PTPL file
2. acquire a reservation
3. restart the target
4. re-add the namespace with the same PTPL file
5. verify the reservation survived

This directly validates the PTPL load-at-ns-add behavior from your PR conclusion.

---

## How PTPL works in SPDK

When PTPL is enabled on a namespace:

- every PR state change (register, acquire, release, preempt) writes the current state
  to a JSON file on the target's filesystem
- the file contains: all registrants, the holder, the reservation key, and the
  reservation type
- when the target restarts and the namespace is re-added with the same file path,
  SPDK reads the file and restores the PR state into the new `spdk_nvmf_ns` object

Key implication from your PR conclusion: PTPL is loaded at namespace-add time only.
The file is not watched or re-read at runtime. If you modify the file manually while
the target is running, nothing happens until the namespace is removed and re-added.

---

## Step 1: Setup with PTPL

Create the PTPL directory:

```bash
sudo mkdir -p /var/lib/nvmf-ptpl
```

Start the target and create the bdev:

```bash
sudo $SPDK_DIR/build/bin/nvmf_tgt -m 0x1 &
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_transport -t TCP -u 16384 -m 8 -c 8192
sudo $SPDK_DIR/scripts/rpc.py bdev_aio_create /dev/sdb Aio0 512
```

Create subsystem and add namespace **with PTPL file**:

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_subsystem \
    nqn.2024-01.io.spdk:shared \
    -a -s SPDK00000000000001

sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_listener \
    nqn.2024-01.io.spdk:shared \
    -t TCP -a 192.168.1.10 -s 4420

# Note: --ptpl-file sets the PTPL file path
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.2024-01.io.spdk:shared \
    Aio0 -n 1 \
    --ptpl-file /var/lib/nvmf-ptpl/aio0-ns1.json
```

At this point the PTPL file may not exist yet — it is created on the first PR state
change.

---

## Step 2: Connect hosts and acquire reservation

On Host A:

```bash
nvme connect -t tcp -a 192.168.1.10 -s 4420 \
    -n nqn.2024-01.io.spdk:shared

DEV=/dev/nvme0n1
RKEY_A=0xDEADBEEF

# Register
nvme resv-register $DEV --rkey=$RKEY_A --crkey=0 --racqa=0

# Enable PTPL in the SET FEATURES command
# Note: PTPL must be explicitly activated via SET FEATURES before it takes effect
nvme set-feature $DEV -f 0x83 -v 1
# Feature 0x83 = Reservation Persistence, value 1 = PTPL enabled

# Acquire WRITE_EXCLUSIVE
nvme resv-acquire $DEV --rkey=$RKEY_A --rtype=1 --racqa=0

# Verify state
nvme resv-report $DEV --eds
```

---

## Step 3: Verify PTPL file was written

```bash
ls -la /var/lib/nvmf-ptpl/aio0-ns1.json
cat /var/lib/nvmf-ptpl/aio0-ns1.json
```

The file should be JSON containing the registrants, holder, reservation key, and type.
Example structure:

```json
{
  "ptpl": true,
  "rtype": 1,
  "crkey": "0xdeadbeef",
  "bdev_uuid": "...",
  "registrants": [
    {
      "hostid": "...",
      "rkey": "0xdeadbeef",
      "holder": true
    }
  ]
}
```

The exact format may vary by SPDK version. The important thing is it contains the
reservation state.

---

## Step 4: Disconnect hosts and restart target

On Host A:

```bash
nvme disconnect -n nqn.2024-01.io.spdk:shared
```

On target, stop cleanly:

```bash
sudo $SPDK_DIR/scripts/rpc.py spdk_kill_instance SIGTERM
# or
sudo kill $(pgrep nvmf_tgt)
```

Verify the PTPL file still exists after target stops:

```bash
ls -la /var/lib/nvmf-ptpl/aio0-ns1.json
cat /var/lib/nvmf-ptpl/aio0-ns1.json
# File should be unchanged
```

---

## Step 5: Restart target and re-add namespace with same PTPL file

```bash
sudo $SPDK_DIR/build/bin/nvmf_tgt -m 0x1 &
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_transport -t TCP -u 16384 -m 8 -c 8192
sudo $SPDK_DIR/scripts/rpc.py bdev_aio_create /dev/sdb Aio0 512

sudo $SPDK_DIR/scripts/rpc.py nvmf_create_subsystem \
    nqn.2024-01.io.spdk:shared \
    -a -s SPDK00000000000001

sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_listener \
    nqn.2024-01.io.spdk:shared \
    -t TCP -a 192.168.1.10 -s 4420

# Critical: same --ptpl-file path
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.2024-01.io.spdk:shared \
    Aio0 -n 1 \
    --ptpl-file /var/lib/nvmf-ptpl/aio0-ns1.json
```

The PTPL file is read at `nvmf_subsystem_add_ns` time. After this call, the in-memory
`spdk_nvmf_ns` should have the restored reservation state.

---

## Step 6: Reconnect Host A and verify reservation survived

On Host A:

```bash
nvme connect -t tcp -a 192.168.1.10 -s 4420 \
    -n nqn.2024-01.io.spdk:shared

nvme resv-report /dev/nvme0n1 --eds
```

Expected:

- `rtype`: 1 (WRITE_EXCLUSIVE — survived restart)
- `regctl`: 1 (one registrant — survived restart)
- registrant with Host A's hostid and `rcsts=1` (holder)

If the reservation state is shown, PTPL worked correctly.

---

## Step 7: Test what happens WITHOUT the PTPL file on re-add

Repeat the experiment but omit `--ptpl-file` on restart:

```bash
# After stopping and restarting target:
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.2024-01.io.spdk:shared \
    Aio0 -n 1
# No --ptpl-file
```

Reconnect Host A and check:

```bash
nvme resv-report /dev/nvme0n1 --eds
# Expected: no reservation, no registrants
# State was NOT restored
```

This confirms: PTPL restoration requires explicitly re-specifying the file path at
namespace-add time. The target does not auto-discover PTPL files.

---

## What to record

| Test | Expected | Actual | Match? |
|---|---|---|---|
| PTPL file created after first PR state change | yes | | |
| File contains holder and rkey | yes | | |
| File survives target stop | yes | | |
| Reservation restored after restart with --ptpl-file | yes | | |
| Reservation NOT restored without --ptpl-file | yes (empty state) | | |

---

## What matters most after Day 17

1. PTPL requires `--ptpl-file` at both namespace-add calls (before and after restart).
2. PTPL is loaded at namespace-add time — not auto-discovered, not synced at runtime.
3. The PTPL file is written on every PR state change, not just at shutdown.
4. Without re-specifying the file path on restart, the namespace starts with clean PR state.
5. This confirms the exact behavior described in `spdk-pr-conclusion.md`.

---

## Suggested next step

Day 18: write the updated PR conclusion. Cross-reference your lab results from Days
15–17 against `spdk-pr-conclusion.md` and record any differences or surprises.
