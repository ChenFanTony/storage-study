# Day 15: Multi-Host Shared Namespace

## What this day covers

Connect two hosts simultaneously to one subsystem sharing one namespace.

This is the foundational multi-host lab. Everything in Week 3 — PR, PTPL, namespace
visibility — builds on this configuration being solid.

---

## What you are building

```
Host A (initiator)          Host B (initiator)
    |                            |
    +----------TCP---------------+
                 |
           nvmf_tgt
               |
       subsystem: nqn.2024-01.io.spdk:shared
           |
           +-- listener: 192.168.1.10:4420
           +-- allow_any_host: true (or both hosts explicitly allowed)
           +-- namespace NSID 1 -> Aio0
               |
           /dev/sdb (or file)
```

Both hosts see NSID 1. Both operate on the same `spdk_nvmf_ns`. Both are in the
same PR domain.

---

## Step 1: Setup target

```bash
sudo $SPDK_DIR/build/bin/nvmf_tgt -m 0x1 &
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_transport -t TCP -u 16384 -m 8 -c 8192

# Use AIO bdev for persistence
sudo $SPDK_DIR/scripts/rpc.py bdev_aio_create /dev/sdb Aio0 512

sudo $SPDK_DIR/scripts/rpc.py nvmf_create_subsystem \
    nqn.2024-01.io.spdk:shared \
    -a \
    -s SPDK00000000000001 \
    -d "Shared Target"

sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_listener \
    nqn.2024-01.io.spdk:shared \
    -t TCP -a 192.168.1.10 -s 4420

sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.2024-01.io.spdk:shared \
    Aio0 -n 1
```

---

## Step 2: Connect both hosts

On Host A:

```bash
sudo modprobe nvme-tcp
nvme connect -t tcp -a 192.168.1.10 -s 4420 \
    -n nqn.2024-01.io.spdk:shared
nvme list
# Note the device name, e.g. /dev/nvme0n1
```

On Host B:

```bash
sudo modprobe nvme-tcp
nvme connect -t tcp -a 192.168.1.10 -s 4420 \
    -n nqn.2024-01.io.spdk:shared
nvme list
# Note the device name, e.g. /dev/nvme0n1
```

---

## Step 3: Verify both hosts see the same namespace

On both hosts, run:

```bash
nvme id-ns /dev/nvme0n1
```

Check:

- `nsze` (namespace size in blocks): must be identical on both hosts
- `lbaf` (LBA format): must be identical
- `nguid` or `eui64`: must be identical — this is the namespace identifier

The identical GUID/EUI confirms both hosts are connected to the same namespace object.

Also verify controller details:

```bash
nvme id-ctrl /dev/nvme0
```

Both should show the same model string and serial number.

On the target, inspect active controllers:

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_get_subsystems
```

Look for the `controllers` or connection count in the subsystem output. You should
see two controllers listed (one per connected host).

---

## Step 4: Verify shared storage

Write from Host A and read from Host B:

```bash
# On Host A — write a pattern
echo "HOST-A-WRITE-$(date)" | sudo dd of=/dev/nvme0n1 bs=512 count=1 oflag=direct conv=notrunc

# On Host B — read it back
sudo dd if=/dev/nvme0n1 of=/dev/stdout bs=512 count=1 iflag=direct 2>/dev/null | strings
# Should show the string written by Host A
```

This confirms both hosts are accessing the same underlying storage through the same
namespace object.

---

## Step 5: Confirm PR domain

Both hosts share the same `spdk_nvmf_ns`. This means any PR registration or
reservation set by Host A will be visible to and affect Host B.

You do not need to test PR today — that is Day 16. Just confirm:

```bash
# On Host A
nvme resv-report /dev/nvme0n1 --eds
# Should show: no reservations held, no registrants
# (since no PR commands have been issued)
```

---

## Step 6: Teardown

```bash
# On both hosts
nvme disconnect -n nqn.2024-01.io.spdk:shared

# On target
sudo $SPDK_DIR/scripts/rpc.py nvmf_delete_subsystem nqn.2024-01.io.spdk:shared
sudo $SPDK_DIR/scripts/rpc.py bdev_aio_delete Aio0
sudo kill $(pgrep nvmf_tgt)
```

---

## What to observe and record

1. How many controllers does `nvmf_get_subsystems` show after both hosts connect?
2. Do both hosts see the same `nguid` in `nvme id-ns`?
3. Does a write from Host A appear immediately on Host B? (no caching delay?)
4. What happens if you connect a third host? Does it also see NSID 1?

---

## What matters most after Day 15

1. One subsystem + one namespace + multiple hosts = shared `spdk_nvmf_ns` = one PR domain.
2. Both hosts operate on the same bdev through the same namespace object.
3. The shared write test proves the storage path is truly shared, not per-host copies.
4. This is the only topology where PR works across hosts in SPDK.

---

## Suggested next step

Day 16: PR lab. Keep both hosts connected from today's setup. Register from Host A,
reserve, then observe conflict behavior from Host B.
