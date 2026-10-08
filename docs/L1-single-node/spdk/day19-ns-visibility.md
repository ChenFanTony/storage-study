# Day 19: Namespace Visibility Masking

## What this day covers

Use `--no-auto-visible` and `nvmf_ns_add_host` / `nvmf_ns_remove_host` to control
which hosts can see which namespaces within a single subsystem.

---

## Why this is important

The default behavior (auto-visible) is: every host that can connect to the subsystem
sees all namespaces. This is fine for a shared volume model.

But if you want:

- host A sees NSID 1, host B sees NSID 2 (exclusive per-host volumes)
- host A sees NSID 1 and NSID 2, host B sees only NSID 2 (partial overlap)

...you need per-namespace host visibility, which SPDK provides and Linux nvmet does not.

---

## Concepts

### no_auto_visible

When a namespace is added with `--no-auto-visible`, it starts invisible to all hosts.
No host will see it in their namespace list until explicitly granted visibility.

### nvmf_ns_add_host

Grants one specific host the ability to see a specific namespace:

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_ns_add_host \
    <subsystem_nqn> <nsid> <hostnqn>
```

### nvmf_ns_remove_host

Revokes visibility for a specific host on a specific namespace:

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_ns_remove_host \
    <subsystem_nqn> <nsid> <hostnqn>
```

---

## Lab 1: One namespace, one host sees it, one does not

### Setup

```bash
sudo $SPDK_DIR/build/bin/nvmf_tgt -m 0x1 &
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_transport -t TCP -u 16384 -m 8 -c 8192

sudo $SPDK_DIR/scripts/rpc.py bdev_malloc_create -b Malloc0 67108864 512

sudo $SPDK_DIR/scripts/rpc.py nvmf_create_subsystem \
    nqn.2024-01.io.spdk:masked \
    -a -s SPDK00000000000001

sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_listener \
    nqn.2024-01.io.spdk:masked \
    -t TCP -a 192.168.1.10 -s 4420

# Add namespace with no-auto-visible
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.2024-01.io.spdk:masked \
    Malloc0 -n 1 \
    --no-auto-visible
```

### Connect both hosts — before granting visibility

On both Host A and Host B:

```bash
nvme connect -t tcp -a 192.168.1.10 -s 4420 \
    -n nqn.2024-01.io.spdk:masked

nvme list
# Expected: no namespaces listed for this controller

nvme id-ctrl /dev/nvme0
# Controller exists but namespace list is empty

nvme id-ns /dev/nvme0 --namespace-id=1
# Expected: error or empty — namespace not visible
```

### Grant visibility to Host A only

Get Host A's NQN:

```bash
# On Host A
cat /etc/nvme/hostnqn
```

On the target:

```bash
HOST_A_NQN="nqn.2014-08.org.nvmexpress:uuid:host-a-uuid"

sudo $SPDK_DIR/scripts/rpc.py nvmf_ns_add_host \
    nqn.2024-01.io.spdk:masked 1 "$HOST_A_NQN"
```

### Verify Host A sees the namespace, Host B does not

On Host A:

```bash
nvme list
# Expected: /dev/nvme0n1 now appears

nvme id-ns /dev/nvme0n1
# Expected: namespace details visible
```

On Host B:

```bash
nvme list
# Expected: still no namespace

nvme id-ns /dev/nvme0 --namespace-id=1
# Expected: still not visible
```

---

## Lab 2: Dynamic visibility change

Revoke visibility from Host A and grant to Host B — without restarting anything.

On the target:

```bash
HOST_B_NQN="nqn.2014-08.org.nvmexpress:uuid:host-b-uuid"

# Revoke from Host A
sudo $SPDK_DIR/scripts/rpc.py nvmf_ns_remove_host \
    nqn.2024-01.io.spdk:masked 1 "$HOST_A_NQN"

# Grant to Host B
sudo $SPDK_DIR/scripts/rpc.py nvmf_ns_add_host \
    nqn.2024-01.io.spdk:masked 1 "$HOST_B_NQN"
```

On Host A:

```bash
nvme list
# Expected: namespace disappears

# If Host A has the namespace open, it may still be accessible until it closes and rescans
# Rescan to force update
nvme ns-rescan /dev/nvme0
nvme list
```

On Host B:

```bash
nvme ns-rescan /dev/nvme0
nvme list
# Expected: namespace now appears on Host B
```

---

## Lab 3: Grant visibility to both hosts simultaneously

```bash
# Grant to both
sudo $SPDK_DIR/scripts/rpc.py nvmf_ns_add_host \
    nqn.2024-01.io.spdk:masked 1 "$HOST_A_NQN"

sudo $SPDK_DIR/scripts/rpc.py nvmf_ns_add_host \
    nqn.2024-01.io.spdk:masked 1 "$HOST_B_NQN"
```

Both hosts rescan and should now see NSID 1. This is equivalent to the auto-visible
behavior but explicitly controlled.

---

## What to observe and record

| Test | Host A sees ns? | Host B sees ns? |
|---|---|---|
| no-auto-visible, no hosts granted | no | no |
| Host A granted visibility | yes | no |
| Host A revoked, Host B granted | no | yes |
| Both hosts granted | yes | yes |

Also record: does `nvme ns-rescan` always work to update visibility immediately,
or is there a delay? What happens to I/O in flight when visibility is revoked?

---

## What matters most after Day 19

1. `--no-auto-visible` starts a namespace invisible to all hosts.
2. `nvmf_ns_add_host` grants visibility to one host on one namespace.
3. Visibility changes take effect immediately and can be changed without restart.
4. This is the SPDK feature that has no upstream Linux nvmet equivalent.

---

## Suggested next step

Day 20: build the two-host exclusive namespace lab. Host A sees only NSID 1,
Host B sees only NSID 2, both from the same subsystem.
