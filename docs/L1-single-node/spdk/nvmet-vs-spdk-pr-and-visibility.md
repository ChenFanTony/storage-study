# nvmet vs SPDK NVMf — PR and Namespace Visibility Comparison

## Purpose

This document compares Linux `nvmet` and SPDK `nvmf_tgt` across four areas:

- host ACL model
- namespace visibility
- PR scope and behavior
- operational workflow

It is written from the SPDK side based on code analysis and lab verification.
Sections marked **[verify in lab]** should be confirmed during Week 3 lab work.

---

## 1. Host ACL Model

### SPDK

Host access control is **subsystem-scoped**.

A host is allowed or denied at the subsystem level:

```
nvmf_create_subsystem nqn.xxx -s SERIAL          # default deny
nvmf_subsystem_add_host nqn.xxx nqn.host-a       # allow host A
nvmf_subsystem_add_host nqn.xxx nqn.host-b       # allow host B
nvmf_subsystem_remove_host nqn.xxx nqn.host-a    # revoke host A
```

Or open to all:

```
nvmf_create_subsystem nqn.xxx -a -s SERIAL       # allow_any_host
```

Key behaviors:

- default is **deny** (no `-a` and no hosts = no connections accepted)
- changes take effect immediately without restart
- the same host NQN can be in multiple subsystems independently
- host ACL is checked at connection time (controller create), not per-command

### Linux nvmet

Host access control is also **subsystem-scoped**, implemented via configfs symlinks:

```bash
# Allow host A
ln -s /sys/kernel/config/nvmet/hosts/host-a \
      /sys/kernel/config/nvmet/subsystems/testnqn/allowed_hosts/host-a

# Open to all
echo 1 > /sys/kernel/config/nvmet/subsystems/testnqn/attr_allow_any_host
```

Key behaviors:

- default is **deny** (no symlinks and `attr_allow_any_host=0`)
- changes take effect immediately
- same model as SPDK at the subsystem level

### Comparison

| Feature | SPDK | Linux nvmet |
|---|---|---|
| ACL scope | subsystem | subsystem |
| Default | deny | deny |
| Open to all | `-a` flag / RPC | `attr_allow_any_host=1` |
| Per-host allow | `nvmf_subsystem_add_host` | symlink in `allowed_hosts/` |
| Per-host revoke | `nvmf_subsystem_remove_host` | remove symlink |
| Live changes | yes | yes |
| Per-namespace ACL | yes (SPDK-specific, see section 2) | no |

**Key difference:** SPDK adds per-namespace host visibility on top of the subsystem ACL.
Linux nvmet has no equivalent upstream.

---

## 2. Namespace Visibility

### SPDK: default (auto-visible)

When a namespace is added without `--no-auto-visible`, it is visible to all hosts that
can connect to the subsystem:

```
nvmf_subsystem_add_ns nqn.xxx Aio0 -n 1
# NSID 1 visible to all allowed hosts
```

### SPDK: per-host visibility

When a namespace is added with `--no-auto-visible`, it starts invisible to all hosts.
Visibility is then granted per host:

```
nvmf_subsystem_add_ns nqn.xxx Aio0 -n 1 --no-auto-visible
nvmf_ns_add_host nqn.xxx 1 nqn.host-a     # host A sees NSID 1
nvmf_ns_add_host nqn.xxx 1 nqn.host-b     # host B sees NSID 1 (optional)
```

Or to give two hosts exclusive visibility to different namespaces:

```
nvmf_subsystem_add_ns nqn.xxx Aio0 -n 1 --no-auto-visible
nvmf_subsystem_add_ns nqn.xxx Aio1 -n 2 --no-auto-visible

nvmf_ns_add_host nqn.xxx 1 nqn.host-a    # host A sees NSID 1 only
nvmf_ns_add_host nqn.xxx 2 nqn.host-b    # host B sees NSID 2 only
```

Both hosts connect to the same subsystem NQN. NSID visibility is filtered per host.

**[verify in lab: Day 19–20]**

### Linux nvmet

Linux nvmet has **no per-namespace host visibility** upstream.

All enabled namespaces in a subsystem are visible to all connected hosts.

To achieve exclusive namespace exposure, the only option is to use separate subsystems
(separate NQNs):

```bash
# subsys-a: host A only
mkdir /sys/kernel/config/nvmet/subsystems/nqn.xxx.a
ln -s /sys/kernel/config/nvmet/hosts/host-a \
      /sys/kernel/config/nvmet/subsystems/nqn.xxx.a/allowed_hosts/host-a

# subsys-b: host B only
mkdir /sys/kernel/config/nvmet/subsystems/nqn.xxx.b
ln -s /sys/kernel/config/nvmet/hosts/host-b \
      /sys/kernel/config/nvmet/subsystems/nqn.xxx.b/allowed_hosts/host-b
```

This works but results in two NQNs, two discovery entries, and two controller instances
per host — more overhead and a different management model.

### Comparison

| Feature | SPDK | Linux nvmet |
|---|---|---|
| Default visibility | all hosts in subsystem | all hosts in subsystem |
| Per-namespace host masking | yes (`--no-auto-visible`) | no |
| Exclusive ns per host in one subsystem | yes | no (requires separate subsystems) |
| Live visibility change | yes (RPC) | N/A |

---

## 3. Persistent Reservations (PR)

### Scope

Both SPDK and Linux nvmet scope PR state to the **namespace**, not the backing block
device.

In SPDK, PR state lives in `struct spdk_nvmf_ns`:

```c
struct spdk_nvmf_registrant *registrants;   // list of registered hosts
struct spdk_nvmf_registrant *holder;        // current reservation holder
uint64_t                     crkey;         // current reservation key
enum spdk_nvme_reservation_type rtype;      // reservation type
bool                         ptpl_activated;
```

In Linux nvmet, PR state lives in `struct nvmet_ns` (added in kernel 6.x PR support work).

### PR domain

PR only applies among hosts that share the **same namespace object**.

In SPDK:

- one subsystem, one NSID → all connected hosts share the same `spdk_nvmf_ns` → PR works across all those hosts
- two hosts with different NSIDs → separate `spdk_nvmf_ns` objects → separate PR domains
- same bdev in two subsystems → not possible (bdev claim is exclusive) → moot

In Linux nvmet:

- one subsystem, one enabled namespace → all connected hosts share the same `nvmet_ns` → PR works
- no per-namespace visibility → no way to have hosts A and B use different NS objects inside one subsystem

### Reservation types supported

Both support all standard NVMe reservation types:

- `WRITE_EXCLUSIVE` (1)
- `EXCLUSIVE_ACCESS` (2)
- `WRITE_EXCLUSIVE_REGISTRANTS_ONLY` (3)
- `EXCLUSIVE_ACCESS_REGISTRANTS_ONLY` (4)
- `WRITE_EXCLUSIVE_ALL_REGISTRANTS` (5)
- `EXCLUSIVE_ACCESS_ALL_REGISTRANTS` (6)

**[verify in lab: Day 16]**

### PTPL (Persist Through Power Loss)

**SPDK:**

- PTPL state is written to a file when reservation state changes
- the file path is set at namespace-add time via the `ptpl_file` parameter:
  ```
  nvmf_subsystem_add_ns nqn.xxx Aio0 -n 1 --ptpl-file /path/to/ptpl.json
  ```
- PTPL state is loaded from the file at namespace-add time (not at runtime sync)
- if the target restarts, you must re-add the namespace with the same `ptpl_file` path
  to restore reservation state

**[verify in lab: Day 17]**

**Linux nvmet:**

- PTPL support was added as part of the broader PR support work (kernel 6.x)
- implementation details differ from SPDK (kernel-managed persistence)

### Comparison

| Feature | SPDK | Linux nvmet |
|---|---|---|
| PR support | yes | yes (kernel 6.x+) |
| PR scope | per `spdk_nvmf_ns` | per `nvmet_ns` |
| PR state location | in-memory in ns struct | in-memory in ns struct |
| PR shared across hosts | yes, if same NSID in same subsystem | yes, if same namespace in same subsystem |
| PTPL | yes, file-based | yes (kernel-managed) |
| PTPL load timing | at namespace-add time | at namespace enable time |
| Cross-subsystem PR sharing | not possible (bdev claim exclusive) | not applicable (no per-ns host acl) |
| PR state persists across target restart | only if ptpl_file re-specified | depends on implementation |

---

## 4. Operational Workflow

### SPDK

Everything is done via JSON-RPC over a UNIX socket. State is in-memory.

Typical setup script:

```bash
# Start target
nvmf_tgt -m 0x1 &

# Create transport
rpc nvmf_create_transport -t TCP -u 16384 -m 8 -c 8192

# Create bdev
rpc bdev_aio_create /dev/sdb Aio0 512

# Create subsystem
rpc nvmf_create_subsystem nqn.xxx -s SERIAL001

# Add listener
rpc nvmf_subsystem_add_listener nqn.xxx -t TCP -a 192.168.1.10 -s 4420

# Add namespace
rpc nvmf_subsystem_add_ns nqn.xxx Aio0 -n 1

# Add host
rpc nvmf_subsystem_add_host nqn.xxx nqn.host-a
```

All steps must be re-run after restart (or use `bdev_nvmf_tgt save-config` to save
and reload).

### Linux nvmet

Everything is done via configfs. State can persist across reboots if the configfs
directories are recreated (e.g., via a systemd service or `nvmetcli`).

Typical setup:

```bash
modprobe nvmet
modprobe nvmet-tcp

# Create subsystem
mkdir /sys/kernel/config/nvmet/subsystems/nqn.xxx
echo 1 > /sys/kernel/config/nvmet/subsystems/nqn.xxx/attr_allow_any_host

# Create namespace
mkdir /sys/kernel/config/nvmet/subsystems/nqn.xxx/namespaces/1
echo /dev/sdb > /sys/kernel/config/nvmet/subsystems/nqn.xxx/namespaces/1/device_path
echo 1 > /sys/kernel/config/nvmet/subsystems/nqn.xxx/namespaces/1/enable

# Create port (listener)
mkdir /sys/kernel/config/nvmet/ports/1
echo tcp  > /sys/kernel/config/nvmet/ports/1/addr_trtype
echo ipv4 > /sys/kernel/config/nvmet/ports/1/addr_adrfam
echo 192.168.1.10 > /sys/kernel/config/nvmet/ports/1/addr_traddr
echo 4420 > /sys/kernel/config/nvmet/ports/1/addr_trsvcid

# Link subsystem to port
ln -s /sys/kernel/config/nvmet/subsystems/nqn.xxx \
      /sys/kernel/config/nvmet/ports/1/subsystems/nqn.xxx
```

### Comparison

| Feature | SPDK | Linux nvmet |
|---|---|---|
| Config interface | JSON-RPC | configfs |
| Config tooling | `scripts/rpc.py` | `echo`, `mkdir`, `ln`, or `nvmetcli` |
| State persistence | manual (re-run script or save config) | configfs survives reboot if module loaded |
| Live changes | yes (add/remove ns, hosts, listeners) | yes (most changes) |
| Discovery service | built-in to target | built-in to nvmet |
| Multiple transports | yes (TCP, RDMA, FC) | yes (TCP, RDMA, FC) |
| User-space vs kernel | user-space | kernel |

---

## 5. Decision Guide

When to use SPDK:

- you need per-namespace host visibility within one subsystem
- you need maximum throughput and minimum latency (polling model)
- you are building a dedicated storage appliance that owns CPU cores
- you want fine-grained runtime control without reboots or module reloads

When to use Linux nvmet:

- you want kernel-integrated storage with minimal setup
- you need a simple single-host-per-namespace model
- you want state that survives restarts without a setup script
- you are exporting kernel block devices without a dedicated storage process

When either works:

- PR across multiple hosts on one namespace: both support it
- TCP or RDMA transport: both support it
- Selective host access at subsystem level: both support it

---

## Lab Verification Checklist

Complete these during Week 3 (Days 15–20) and update this document with results.

- [ ] Day 15: Two hosts connect to one subsystem, one namespace — both see same NSID
- [ ] Day 16: Host A registers and reserves; Host B sees RESERVATION_CONFLICT
- [ ] Day 17: PTPL survives target restart with same ptpl_file on namespace re-add
- [ ] Day 19: `--no-auto-visible` + `nvmf_ns_add_host` — host A sees NSID, host B does not
- [ ] Day 20: Two namespaces, two hosts, one subsystem — exclusive visibility confirmed
