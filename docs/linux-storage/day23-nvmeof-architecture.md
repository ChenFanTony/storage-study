# Day 23: NVMe-oF — Architecture & Transport Comparison

## Learning Objectives
- Understand NVMe-oF's architecture: how it extends the NVMe queue model over a fabric
- Set up NVMe-oF/TCP loopback (host + target on same machine)
- Measure latency overhead of TCP transport vs local NVMe
- Understand the discovery protocol and queue allocation over a fabric
- Know when NVMe-oF is and isn't the right architecture

---

## 1. NVMe-oF: Extending the Queue Model Over a Fabric

NVMe-oF extends the NVMe command set over a network transport while
preserving the queue pair model.

```
Local NVMe (Day 22):
  Host CPU → PCIe → NVMe SQ/CQ (MMIO doorbells) → NAND

NVMe-oF:
  Host CPU → Network → Target → NVMe SQ/CQ (fabric messages) → NAND

Key insight: the NVMe command set is UNCHANGED.
  Same opcodes (read=0x02, write=0x01, ...), same CID, same completion structure.
  Only the transport mechanism differs (PCIe MMIO ↔ fabric messages).
  A read command on a local NVMe device is byte-identical to one sent over the fabric.
```

```
Host-side stack:
  Application
    └── block layer (blk-mq)
        └── nvme host driver (drivers/nvme/host/)
            └── fabric core (drivers/nvme/host/fabrics.c)
                └── transport driver:
                      tcp.c    — NVMe-oF/TCP   (kernel 5.0+)
                      rdma.c   — NVMe-oF/RDMA  (RoCE, iWARP)
                      fc.c     — NVMe-oF/FC    (Fibre Channel)

Target-side stack (drivers/nvme/target/):
  configfs (admin interface)
    └── nvmet core
        └── transport driver (nvmet-tcp, nvmet-rdma, nvmet-fc)
        └── backing store: block device (/dev/nvmeXn1), file, or null
```

---

## 2. Transport Comparison

| Transport | Latency overhead | Throughput | HW required | Use case |
|-----------|-----------------|------------|-------------|----------|
| Local NVMe | (baseline ~50–100 µs) | Device max | None | Single-server |
| NVMe-oF/RDMA (RoCE) | +5–20 µs | Near wire speed | RDMA NIC + lossless network | Low-latency storage fabric |
| NVMe-oF/TCP | +100–300 µs | Near wire speed | Any Ethernet NIC | Disaggregated storage, SDN |
| NVMe-oF/FC | +10–50 µs | Near wire speed | FC HBA + FC fabric | Enterprise SAN replacement |

### TCP vs RDMA — the decision

```
RDMA (RoCE):
  + Near-local NVMe latency (kernel-bypass for the data path)
  + Zero-copy: data goes directly from NIC to application memory
  + Lower CPU overhead on host
  - Requires lossless Ethernet (PFC, ECN) — complex network configuration
  - Requires RDMA-capable NICs (more expensive per port)
  - Operationally complex (PFC storms, fabric tuning, debugging is hard)

TCP:
  + Works on any standard Ethernet (25/100 GbE commodity NICs)
  + Simple operations — no PFC, no special config
  + Widely supported, well-understood failure modes
  - Higher latency (~200 µs vs ~70 µs over the same physical distance)
  - More CPU overhead (TCP stack processing on both sides)
  - Use case: TCP latency is acceptable for the vast majority of workloads
```

The TCP transport is the default for greenfield deployments. RDMA is
worth the operational complexity when sub-100µs latency to remote storage
genuinely matters — typically: low-latency databases, HPC, GPU training
with disaggregated storage.

---

## 3. NVMe-oF/TCP Target Setup

The Linux target (`nvmet`) is configured via configfs.

```bash
# Load target modules
modprobe nvmet
modprobe nvmet-tcp

# Create a subsystem (the NVMe-oF "endpoint identity")
mkdir /sys/kernel/config/nvmet/subsystems/testnqn
cd /sys/kernel/config/nvmet/subsystems/testnqn

# Allow any host to connect (testing only; production: list allowed hosts)
echo 1 > attr_allow_any_host

# Add a namespace backed by a block device (or file)
mkdir namespaces/1
echo /dev/nvme0n1 > namespaces/1/device_path
# Or for testing: a file
# truncate -s 4G /tmp/nvmeof-test.img
# echo /tmp/nvmeof-test.img > namespaces/1/device_path
echo 1 > namespaces/1/enable

# Create a TCP port (listen on 127.0.0.1:4420 for testing)
mkdir /sys/kernel/config/nvmet/ports/1
cd /sys/kernel/config/nvmet/ports/1
echo "127.0.0.1" > addr_traddr
echo "tcp"       > addr_trtype
echo "4420"      > addr_trsvcid
echo "ipv4"      > addr_adrfam

# Link subsystem to port (makes it discoverable on this port)
ln -s /sys/kernel/config/nvmet/subsystems/testnqn \
      /sys/kernel/config/nvmet/ports/1/subsystems/testnqn

echo "Target configured. Listening on 127.0.0.1:4420"
```

---

## 4. Host: Discovery and Connect

```bash
# Load host transport module
modprobe nvme-tcp

# Discover subsystems on a target
nvme discover -t tcp -a 127.0.0.1 -s 4420
# Discovery Log Number of Records 1, Generation counter ...
# =====Discovery Log Entry 0======
# trtype:  tcp
# adrfam:  ipv4
# subtype: nvme subsystem
# treq:    not specified
# portid:  1
# trsvcid: 4420
# subnqn:  testnqn
# traddr:  127.0.0.1

# Connect to a specific subsystem
nvme connect -t tcp -a 127.0.0.1 -s 4420 -n testnqn

# A new NVMe device appears
nvme list
# /dev/nvme1n1   ... testnqn   ...

# Inspect the fabric connection
cat /sys/class/nvme/nvme1/transport     # "tcp"
cat /sys/class/nvme/nvme1/address       # "traddr=127.0.0.1,trsvcid=4420"
cat /sys/class/nvme/nvme1/state         # "live"

# Disconnect
nvme disconnect -n testnqn
```

---

## 5. NVMe-oF Identity Model: NQN, Subsystem, Namespace

```
Hierarchy of names:

NQN (NVMe Qualified Name)
  e.g., "nqn.2014-08.org.nvmexpress:uuid:9e02..." or "testnqn" (for testing)
  Used to identify: subsystems, hosts, discovery service
  Format like a reverse-DNS name; globally unique in principle

Subsystem
  A logical collection of namespaces and controllers
  Has one NQN
  Lives on one or more target ports (multipath = same subsystem, multiple ports)

Namespace
  An addressable LBA space (the actual block device)
  Belongs to exactly one subsystem
  Identified by namespace ID within the subsystem (1, 2, ...)

Controller
  An instance of an NVMe controller as seen by a host
  When host connects to subsystem: creates a controller on each side
  Identified by Controller ID (CNTLID)

ANA (Asymmetric Namespace Access) Group
  A set of namespaces with the same access state from a controller
  Used for multipathing (Day 24 topic)
```

```bash
# View NQN of host (auto-generated on first use)
cat /etc/nvme/hostnqn

# View NQN of a connected target's subsystem
nvme list-subsys
# nvme-subsys0 - NQN=testnqn
#  +- nvme1 tcp traddr=127.0.0.1 trsvcid=4420 live
```

---

## 6. Latency Measurement: Local vs NVMe-oF/TCP

```bash
# Setup test image as backing store on target
truncate -s 4G /tmp/nvmeof-test.img
# (re-configure target as above to use this file)

REMOTE_DEV=/dev/nvme1n1   # the NVMe-oF connected device (host view)

# Measure 4K random read latency at QD=1 (pure latency, no queue effects)
echo "=== NVMe-oF/TCP loopback latency, QD=1 ==="
fio --name=nvmeof-lat \
    --filename=$REMOTE_DEV \
    --rw=randread --bs=4k \
    --ioengine=libaio --iodepth=1 --direct=1 \
    --time_based --runtime=15 \
    --percentile_list=50,99,99.9 \
    --output-format=normal | grep -E "lat \(usec\)|percentiles"

# For comparison, run the same against a local NVMe (if available)
# Expected (loopback, same machine):
#   Local NVMe:    p50 ~50 µs, p99 ~120 µs
#   NVMe-oF/TCP:   p50 ~250 µs, p99 ~500 µs
# Overhead: ~200 µs for TCP loopback (real network adds RTT)

# Throughput at high QD (bandwidth, not latency)
echo "=== NVMe-oF/TCP throughput, QD=32 ==="
fio --name=nvmeof-tput \
    --filename=$REMOTE_DEV \
    --rw=randread --bs=128k \
    --ioengine=libaio --iodepth=32 --direct=1 \
    --time_based --runtime=15
# Should approach the network link's bandwidth (not necessarily NVMe maximum)
```

---

## 7. Queue Allocation Over the Fabric

```c
// drivers/nvme/host/fabrics.c

// When host connects to target:
nvmf_connect_io_queue():
    // 1. Send CONNECT command (fabric-specific) to target
    //    CONNECT specifies: subsystem NQN, host NQN, queue ID, queue size
    // 2. Target creates the corresponding queue on its side (nvmet)
    // 3. Both sides have matched queue pairs
    // 4. Subsequent NVMe commands flow over this queue

// Queue count negotiation at connect time:
//   Host requests: min(host_max_queues, target_max_queues, nr_cpus)
//   Each I/O queue pair = one blk_mq_hw_ctx on host
//   Target allocates corresponding worker threads / event handlers per queue
```

```bash
# Queue count for an NVMe-oF device
cat /sys/block/nvme1n1/queue/nr_hw_queues
# Typically: min(local_CPUs, target advertised max)

ls /sys/block/nvme1n1/mq/ | wc -l   # one directory per HW queue

# Each queue gets its own TCP connection (for nvme-tcp transport)
ss -t | grep 4420
# One ESTABLISHED connection per I/O queue
```

The "one TCP connection per queue" model is what gives nvme-tcp its
parallelism. Each queue maintains its own TCP stream, so commands and
completions on different queues are completely independent. Loss of one
connection doesn't affect others; one slow connection doesn't HoL-block
the rest.

---

## 8. The Discovery Service

NVMe-oF includes a lightweight Discovery Service, a special subsystem
with a well-known NQN that returns a list of available subsystems:

```
Well-known discovery NQN: nqn.2014-08.org.nvmexpress.discovery

Discovery flow:
  Host connects to discovery subsystem (port 4420 by default)
  Host sends Get Log Page command (Discovery Log)
  Target returns list of available subsystems with NQN + transport + address
  Host disconnects from discovery, connects to chosen subsystems
```

```bash
# Discover via the standard discovery NQN
nvme discover -t tcp -a 192.168.1.10 -s 4420
# Equivalent to manually connecting to the discovery NQN

# Configure persistent discovery for boot-time auto-connect
mkdir -p /etc/nvme
cat > /etc/nvme/discovery.conf <<EOF
--transport=tcp --traddr=192.168.1.10 --trsvcid=4420
EOF
systemctl enable nvmf-autoconnect.service
```

**Operational implication:** new namespaces become visible without host
reconfiguration. Provisioning systems can register new namespaces on the
target; hosts re-discover and connect automatically.

---

## 9. NVMe-oF: When It's the Right Architecture

**Use NVMe-oF when:**

```
Disaggregated storage:
  Compute nodes have no local persistent storage (or only boot disk)
  Central storage nodes export NVMe-oF namespaces
  Storage and compute scale independently
  Common in hyperscale: Google, Meta, Alibaba all use variants of this

Shared NVMe access:
  Multiple hosts access the same namespace (read-only or with
  application-level coordination)
  Database shared-disk for HA without a SAN

High-density storage pools:
  One storage node with 24× NVMe → exports to 100+ compute nodes
  Better utilization than per-server local storage
```

**Don't use NVMe-oF when:**

```
Sub-200 µs latency is required AND TCP isn't sufficient:
  TCP adds ~200 µs; even RDMA adds ~20 µs
  For very latency-critical paths, local NVMe at ~50 µs wins

Simple single-server deployment:
  Complexity of NVMe-oF (target config, multipathing, network tuning)
  is not justified for one server with a few disks

Storage is not shared:
  If each host always uses only its own data, local NVMe is simpler and faster
```

---

## 10. Target Teardown

```bash
# Reverse order of setup

# Disconnect host first
nvme disconnect -n testnqn

# Remove port → subsystem link
rm /sys/kernel/config/nvmet/ports/1/subsystems/testnqn

# Disable and remove namespace
echo 0 > /sys/kernel/config/nvmet/subsystems/testnqn/namespaces/1/enable
rmdir /sys/kernel/config/nvmet/subsystems/testnqn/namespaces/1

# Remove subsystem and port
rmdir /sys/kernel/config/nvmet/subsystems/testnqn
rmdir /sys/kernel/config/nvmet/ports/1

# Unload modules
modprobe -r nvmet-tcp nvmet nvme-tcp
```

---

## 11. Source Reading Checklist

```
drivers/nvme/host/fabrics.c   — fabric core: CONNECT, discovery, queue mgmt
drivers/nvme/host/tcp.c       — TCP transport (host)
drivers/nvme/host/rdma.c      — RDMA transport (host)
drivers/nvme/target/core.c    — target framework
drivers/nvme/target/configfs.c — target configfs interface
drivers/nvme/target/tcp.c     — TCP transport (target)
include/linux/nvme-tcp.h      — TCP PDU format
```

Reading order: `nvme-tcp.h` (the protocol PDU layout), then host `tcp.c`
(read/write paths over TCP), then target `tcp.c` (mirror of host side).
The protocol is symmetric; understanding one side gives you the other.

---

## 12. Self-Check Questions

1. What exactly travels over the NVMe-oF fabric — data, commands, or both?
2. Why does NVMe-oF/TCP have higher latency than NVMe-oF/RDMA even at the same physical network distance?
3. How many TCP connections does nvme-tcp establish for a host with 32 I/O queues, and why?
4. A 10 GbE NVMe-oF/TCP connection with 200 µs RTT. What queue depth is needed to saturate a target capable of 300K IOPS at 4 KB?
5. Eight storage nodes each with 12× NVMe serve 200 compute nodes. Local NVMe latency is 50 µs. Application requires p99 < 1 ms. Is NVMe-oF/TCP viable?
6. What is the NVMe-oF Discovery Service and why does it matter for operations?
7. The NVMe-oF protocol uses the same command opcodes (0x02 = read, etc.) as local NVMe. Why is this design choice significant?

## 13. Answers

1. Both. Commands travel from host to target over the fabric (replacing PCIe MMIO command submission). Data travels bidirectionally: write data goes host→target, read data goes target→host. The fabric replaces both the PCIe transport of commands and the DMA transfer of data.
2. RDMA bypasses the kernel TCP/IP stack and uses kernel-bypass: data goes directly from NIC to application/host memory via DMA without CPU involvement. TCP requires processing through the kernel networking stack on both sides — socket buffer management, TCP state machine, ACK-based flow control, often a userspace copy. Each layer adds latency. RDMA's protocol overhead is fundamentally lower because it offloads more to hardware.
3. 32 — one TCP connection per I/O queue (plus one for the admin queue, so 33 total). This design means each queue's commands and completions are independent: loss or head-of-line blocking on one TCP stream doesn't affect the others. It also means a single host occupies many sockets on the target.
4. Queue depth = IOPS × RTT = 300,000 × 0.0002 s = 60 in-flight requests minimum. Use `iodepth=64` or higher (per fio job; with multiple jobs total in-flight scales further). Note: 300K IOPS × 4 KB = 1.2 GB/s, which exceeds 10 GbE (~1.25 GB/s); you'd be bandwidth-bound before reaching the IOPS ceiling. Would need 25 GbE to actually saturate 300K IOPS at 4 KB.
5. Yes, viable. NVMe-oF/TCP adds ~200 µs overhead on top of the local 50 µs → target p50 ~250 µs, well under 1 ms. p99 depends on network congestion and target load distribution. With proper QoS (DSCP marking for storage traffic, dedicated storage VLAN, load balancing across the 8 storage nodes), p99 < 1 ms is achievable. RDMA would give more headroom (50–80 µs total) but TCP meets the requirement.
6. The Discovery Service is a special subsystem with NQN `nqn.2014-08.org.nvmexpress.discovery` that a host queries to find available subsystems on a target without prior knowledge. The host connects to the discovery port, sends a Get Log Page command, and receives a list of subsystems with their addresses and transport types. Operationally: discovery allows dynamic storage provisioning (new namespaces become visible without host configuration changes) and underpins NVMe-oF management automation.
7. It preserves the entire NVMe software stack and tooling. Drivers, monitoring (nvme-cli, SMART), userspace libraries, applications written for local NVMe — all work over NVMe-oF unchanged. From the application's perspective, a remote namespace is indistinguishable from a local one. This is a deliberate choice to keep storage software vendor-neutral and to make disaggregated storage adoption frictionless. It contrasts sharply with iSCSI, which is its own protocol layered on TCP.

---

## Tomorrow: Day 24 — NVMe-oF Failure Handling, Multipathing & O_DIRECT Gap-Fill

We simulate NVMe-oF path failure, observe ANA state transitions and
reconnect behavior, and do a targeted gap-fill on the O_DIRECT kernel
path — confirming source-level understanding of what BlueStore bypasses.
