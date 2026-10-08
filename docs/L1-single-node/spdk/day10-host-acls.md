# Day 10: Host ACLs

## What this day covers

How SPDK controls which hosts can connect to a subsystem.

The three modes:

1. default deny — no hosts can connect
2. allow_any_host — all hosts can connect
3. per-host allow list — specific hosts only

---

## Why this matters for NVMf

NVMe-oF has no inherent authentication at the transport level in basic deployments.
The only gate between an initiator and your storage is the host NQN check in the target.

Understanding this model is necessary before moving to multi-host setups in Week 3.

---

## Host NQN

Every NVMe-oF initiator has a Host NQN — a unique identifier string.

On a Linux initiator:

```bash
cat /etc/nvme/hostnqn
# nqn.2014-08.org.nvmexpress:uuid:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

You can override it at connect time:

```bash
nvme connect ... --hostnqn nqn.2024-01.io.spdk:my-custom-hostnqn
```

The target checks the connecting host's NQN against its allowed list.

---

## Mode 1: Default deny

Create a subsystem without `-a` and without adding any hosts:

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_subsystem \
    nqn.2024-01.io.spdk:testnqn \
    -s SPDK00000000000001
# Note: no -a flag
```

Add listener and namespace as usual, then try to connect from an initiator:

```bash
nvme connect -t tcp -a 192.168.1.10 -s 4420 \
    -n nqn.2024-01.io.spdk:testnqn
# Expected: Failed to connect to controller
```

Check SPDK logs — you should see the connection attempt rejected with
`host is not allowed`.

---

## Mode 2: allow_any_host

Two ways to enable:

**At subsystem creation:**

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_subsystem \
    nqn.2024-01.io.spdk:testnqn \
    -a \
    -s SPDK00000000000001
```

**Dynamically on a running subsystem:**

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_allow_any_host \
    nqn.2024-01.io.spdk:testnqn \
    -e   # enable
```

To disable again:

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_allow_any_host \
    nqn.2024-01.io.spdk:testnqn \
    -d   # disable
```

When `allow_any_host` is true, the per-host allow list is ignored. Any initiator
NQN is accepted.

---

## Mode 3: Per-host allow list

Get the initiator NQN from the initiator host:

```bash
# On initiator
cat /etc/nvme/hostnqn
```

Add to the subsystem allow list:

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_host \
    nqn.2024-01.io.spdk:testnqn \
    nqn.2014-08.org.nvmexpress:uuid:host-a-uuid
```

Verify:

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_get_subsystems
# Look for "hosts" array in the subsystem entry
```

Remove a host:

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_remove_host \
    nqn.2024-01.io.spdk:testnqn \
    nqn.2014-08.org.nvmexpress:uuid:host-a-uuid
```

Changes take effect immediately. A currently connected host is not disconnected
when its NQN is removed — the check only applies at connection time.

---

## Lab: test all three modes

### Setup (run once)

```bash
sudo $SPDK_DIR/build/bin/nvmf_tgt -m 0x1 &
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_transport -t TCP -u 16384 -m 8 -c 8192
sudo $SPDK_DIR/scripts/rpc.py bdev_malloc_create -b Malloc0 67108864 512
```

### Test 1: default deny

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_subsystem \
    nqn.2024-01.io.spdk:testnqn -s SPDK00000000000001

sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_listener \
    nqn.2024-01.io.spdk:testnqn -t TCP -a 192.168.1.10 -s 4420

sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.2024-01.io.spdk:testnqn Malloc0 -n 1

# On initiator — expect failure
nvme connect -t tcp -a 192.168.1.10 -s 4420 -n nqn.2024-01.io.spdk:testnqn

# Clean up
sudo $SPDK_DIR/scripts/rpc.py nvmf_delete_subsystem nqn.2024-01.io.spdk:testnqn
```

### Test 2: allow_any_host

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_subsystem \
    nqn.2024-01.io.spdk:testnqn -a -s SPDK00000000000001

sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_listener \
    nqn.2024-01.io.spdk:testnqn -t TCP -a 192.168.1.10 -s 4420

sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.2024-01.io.spdk:testnqn Malloc0 -n 1

# On initiator — expect success
nvme connect -t tcp -a 192.168.1.10 -s 4420 -n nqn.2024-01.io.spdk:testnqn
nvme list
nvme disconnect -n nqn.2024-01.io.spdk:testnqn

# Clean up
sudo $SPDK_DIR/scripts/rpc.py nvmf_delete_subsystem nqn.2024-01.io.spdk:testnqn
```

### Test 3: per-host allow list

```bash
# Get your initiator NQN first
HOST_NQN=$(ssh initiator-host cat /etc/nvme/hostnqn)
echo "Host NQN: $HOST_NQN"

sudo $SPDK_DIR/scripts/rpc.py nvmf_create_subsystem \
    nqn.2024-01.io.spdk:testnqn -s SPDK00000000000001
# No -a flag

sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_listener \
    nqn.2024-01.io.spdk:testnqn -t TCP -a 192.168.1.10 -s 4420

sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.2024-01.io.spdk:testnqn Malloc0 -n 1

# Try connect before adding host — expect failure
nvme connect -t tcp -a 192.168.1.10 -s 4420 -n nqn.2024-01.io.spdk:testnqn

# Add host
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_host \
    nqn.2024-01.io.spdk:testnqn "$HOST_NQN"

# Try connect after adding host — expect success
nvme connect -t tcp -a 192.168.1.10 -s 4420 -n nqn.2024-01.io.spdk:testnqn
nvme list

# Remove host while connected (should not disconnect existing session)
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_remove_host \
    nqn.2024-01.io.spdk:testnqn "$HOST_NQN"

# Disconnect and try reconnect — expect failure now
nvme disconnect -n nqn.2024-01.io.spdk:testnqn
nvme connect -t tcp -a 192.168.1.10 -s 4420 -n nqn.2024-01.io.spdk:testnqn
# Expected: failure

# Clean up
sudo $SPDK_DIR/scripts/rpc.py nvmf_delete_subsystem nqn.2024-01.io.spdk:testnqn
sudo $SPDK_DIR/scripts/rpc.py bdev_malloc_delete Malloc0
sudo kill $(pgrep nvmf_tgt)
```

---

## Where this is enforced in code

In `lib/nvmf/ctrlr.c`, during controller creation (host connect):

```c
// nvmf_ctrlr_cmd_connect()
if (!spdk_nvmf_subsystem_host_allowed(subsystem, hostnqn)) {
    // reject with CONNECT_INVALID_PARAMETERS
}
```

`spdk_nvmf_subsystem_host_allowed` is in `lib/nvmf/subsystem.c`:

```c
bool spdk_nvmf_subsystem_host_allowed(
    struct spdk_nvmf_subsystem *subsystem,
    const char *hostnqn)
{
    if (subsystem->flags.allow_any_host) {
        return true;
    }
    // walk subsystem->hosts list, check for matching hostnqn
}
```

The check happens once at connection time. Per-command checking is not done for the
host ACL — that is what PR is for.

---

## Comparison with Linux nvmet

| Operation | SPDK RPC | Linux nvmet configfs |
|---|---|---|
| Default deny | omit `-a`, add no hosts | `attr_allow_any_host=0`, no symlinks |
| Allow any | `-a` flag | `echo 1 > attr_allow_any_host` |
| Add host | `nvmf_subsystem_add_host` | `ln -s .../hosts/hostnqn .../allowed_hosts/` |
| Remove host | `nvmf_subsystem_remove_host` | `rm .../allowed_hosts/hostnqn` |
| Check host | `nvmf_get_subsystems` | `ls .../allowed_hosts/` |

---

## What matters most after Day 10

1. Default is deny. Forgetting `-a` or an explicit host add means no connections.
2. `allow_any_host` and the per-host list are mutually exclusive in effect: if `allow_any_host` is true, the list is not checked.
3. Host allow/deny is checked at connection time only, not per-command.
4. Changes to the allow list take effect immediately without restarting the target.
5. The code gate is `spdk_nvmf_subsystem_host_allowed` in `subsystem.c`.

---

## Suggested next step

Day 11: deep read of `lib/nvmf/ctrlr.c`. You have now used the target from the outside.
Day 11 opens the box and traces exactly what happens inside when a host connects and
when a command arrives.
