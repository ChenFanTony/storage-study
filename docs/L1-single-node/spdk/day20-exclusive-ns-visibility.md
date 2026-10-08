# Day 20: Two Hosts, Two Namespaces, Exclusive Visibility

## What this day covers

Build the most common use case for per-namespace host visibility:

- one subsystem
- two namespaces (two backing devices)
- host A sees NSID 1 only
- host B sees NSID 2 only

Both hosts connect to the same subsystem NQN. Each gets exclusive access to its
own namespace. Neither can see the other's storage.

---

## What you are building

```
Host A                          Host B
  |  connects to shared NQN      |  connects to shared NQN
  |  sees only NSID 1            |  sees only NSID 2
  +----------TCP-----------------+
                  |
            nvmf_tgt
                  |
   subsystem: nqn.2024-01.io.spdk:exclusive
                  |
        +---------+---------+
        |                   |
   ns NSID 1           ns NSID 2
   Aio0                Aio1
   /dev/sdb            /dev/sdc
   visible: Host A     visible: Host B
```

---

## Step 1: Setup two bdevs

```bash
sudo $SPDK_DIR/build/bin/nvmf_tgt -m 0x1 &
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_transport -t TCP -u 16384 -m 8 -c 8192

# Two separate backing devices
sudo $SPDK_DIR/scripts/rpc.py bdev_aio_create /dev/sdb Aio0 512
sudo $SPDK_DIR/scripts/rpc.py bdev_aio_create /dev/sdc Aio1 512

# Verify both bdevs
sudo $SPDK_DIR/scripts/rpc.py bdev_get_bdevs
```

---

## Step 2: Create subsystem and add both namespaces as no-auto-visible

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_subsystem \
    nqn.2024-01.io.spdk:exclusive \
    -a -s SPDK00000000000001

sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_listener \
    nqn.2024-01.io.spdk:exclusive \
    -t TCP -a 192.168.1.10 -s 4420

# Both namespaces: no-auto-visible
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.2024-01.io.spdk:exclusive \
    Aio0 -n 1 --no-auto-visible

sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.2024-01.io.spdk:exclusive \
    Aio1 -n 2 --no-auto-visible
```

Verify subsystem state:

```bash
sudo $SPDK_DIR/scripts/rpc.py nvmf_get_subsystems
# Should show two namespaces, both with no_auto_visible
```

---

## Step 3: Grant exclusive visibility

Get NQNs from both initiators:

```bash
# On Host A
HOST_A_NQN=$(cat /etc/nvme/hostnqn)

# On Host B
HOST_B_NQN=$(cat /etc/nvme/hostnqn)
```

On the target:

```bash
# Host A sees NSID 1 only
sudo $SPDK_DIR/scripts/rpc.py nvmf_ns_add_host \
    nqn.2024-01.io.spdk:exclusive 1 "$HOST_A_NQN"

# Host B sees NSID 2 only
sudo $SPDK_DIR/scripts/rpc.py nvmf_ns_add_host \
    nqn.2024-01.io.spdk:exclusive 2 "$HOST_B_NQN"
```

---

## Step 4: Connect both hosts and verify

On Host A:

```bash
nvme connect -t tcp -a 192.168.1.10 -s 4420 \
    -n nqn.2024-01.io.spdk:exclusive

nvme list
# Expected: one namespace (/dev/nvme0n1), corresponding to NSID 1 (Aio0 = /dev/sdb)

nvme id-ns /dev/nvme0n1
# nsze should match /dev/sdb size

# Confirm NSID 1 is accessible
sudo dd if=/dev/nvme0n1 of=/dev/null bs=4k count=1 iflag=direct
echo "Host A NSID 1 read: $?"

# Confirm NSID 2 is NOT accessible from Host A
nvme id-ns /dev/nvme0 --namespace-id=2
# Expected: error — namespace 2 not visible to Host A
```

On Host B:

```bash
nvme connect -t tcp -a 192.168.1.10 -s 4420 \
    -n nqn.2024-01.io.spdk:exclusive

nvme list
# Expected: one namespace (/dev/nvme0n1), corresponding to NSID 2 (Aio1 = /dev/sdc)

nvme id-ns /dev/nvme0n1
# nsze should match /dev/sdc size

# Confirm NSID 2 is accessible
sudo dd if=/dev/nvme0n1 of=/dev/null bs=4k count=1 iflag=direct
echo "Host B NSID 2 read: $?"

# Confirm NSID 1 is NOT accessible from Host B
nvme id-ns /dev/nvme0 --namespace-id=1
# Expected: error — namespace 1 not visible to Host B
```

---

## Step 5: Verify storage isolation

Write a marker from each host to its namespace:

```bash
# On Host A
echo "HOST-A-DATA" | sudo dd of=/dev/nvme0n1 bs=512 count=1 oflag=direct conv=notrunc

# On Host B
echo "HOST-B-DATA" | sudo dd of=/dev/nvme0n1 bs=512 count=1 oflag=direct conv=notrunc
```

Verify storage is separate (on the target):

```bash
sudo dd if=/dev/sdb of=/dev/stdout bs=512 count=1 2>/dev/null | strings
# Should show: HOST-A-DATA

sudo dd if=/dev/sdc of=/dev/stdout bs=512 count=1 2>/dev/null | strings
# Should show: HOST-B-DATA
```

---

## Step 6: Verify PR isolation

Since Host A and Host B are on different namespace objects, they are in separate PR
domains:

```bash
# On Host A — register on NSID 1
nvme resv-register /dev/nvme0n1 --rkey=0xAAAA --crkey=0 --racqa=0

# On Host B — check NSID 2 (Host B's namespace)
nvme resv-report /dev/nvme0n1 --eds
# Expected: no registrants — Host A's registration on NSID 1 does not affect NSID 2
```

This directly demonstrates that per-namespace visibility creates per-namespace PR domains.

---

## Teardown

```bash
# Disconnect both hosts
nvme disconnect -n nqn.2024-01.io.spdk:exclusive

# On target
sudo $SPDK_DIR/scripts/rpc.py nvmf_delete_subsystem nqn.2024-01.io.spdk:exclusive
sudo $SPDK_DIR/scripts/rpc.py bdev_aio_delete Aio0
sudo $SPDK_DIR/scripts/rpc.py bdev_aio_delete Aio1
sudo kill $(pgrep nvmf_tgt)
```

---

## What to observe and record

| Check | Expected | Actual | Match? |
|---|---|---|---|
| Host A sees NSID 1 | yes | | |
| Host A sees NSID 2 | no | | |
| Host B sees NSID 2 | yes | | |
| Host B sees NSID 1 | no | | |
| Host A write visible on /dev/sdb | yes | | |
| Host B write visible on /dev/sdc | yes | | |
| Host A PR registration affects Host B namespace | no | | |

---

## What matters most after Day 20

1. One subsystem NQN can serve multiple hosts with exclusive private namespaces.
2. The host connects to the same NQN but only sees its granted namespaces.
3. Per-namespace visibility creates per-namespace PR domains automatically.
4. This is the topology Linux nvmet cannot reproduce inside one subsystem.

---

## Suggested next step

Day 21: Week 3 review. Write the lab-verified nvmet vs SPDK comparison document,
cross-referencing everything you built in Days 15–20.
