# Day 23: NVMe-oF — Architecture & Transport Comparison

## Learning Objectives
- Understand NVMe-oF's architecture: how it extends the NVMe queue model over a fabric
- Set up NVMe-oF/TCP loopback (host + target on same machine)
- Measure latency overhead of TCP transport vs local NVMe
- Understand the discovery protocol and queue allocation
- Know when NVMe-oF is and isn't the right architecture

---

## 1. NVMe-oF: Extending the Queue Model Over a Fabric

NVMe-oF (NVMe over Fabrics) extends the NVMe command set over a network
transport while preserving the queue pair model.

```
Local NVMe:
  Host CPU → PCIe → NVMe SQ/CQ (MMIO doorbells) → NAND

NVMe-oF:
  Host CPU → Network → Target → NVMe SQ/CQ (fabric messages) → NAND

Key insight: the NVMe command set is UNCHANGED
  Same opcodes, same CID, same completion structure
  Only the transport mechanism differs (PCIe MMIO → fabric messages)
```

```
NVMe-oF stack (host side):
  Application
    → block layer (blk-mq)
      → nvme host driver (drivers/nvme/host/)
        → fabric transport layer (fabrics.c)
          → transport driver:
              tcp.c    — NVMe-oF/TCP (kernel 5.0+)
              rdma.c   — NVMe-oF/RDMA (RoCE, iWARP)
              fc.c     — NVMe-oF/FC (Fibre Channel)
            → network / RDMA / FC fabric
              → NVMe-oF target (drivers/nvme/target/)
                → local NVMe device
```

---

## 2. Transport Comparison

| Transport | Latency | Throughput | HW Required | Use Case |
|-----------|---------|------------|-------------|----------|
| Local NVMe | ~50–100µs | Device max | None | Single-server |
| NVMe-oF/RDMA (RoCE) | +5–20µs overhead | Near wire speed | RDMA NIC + lossless network | Low-latency storage fabric |
| NVMe-oF/TCP | +100–300µs overhead | Near wire speed | Any NIC | Disaggregated storage, software-defined |
| NVMe-oF/FC | +10–50µs overhead | Near wire speed | FC HBA | Enterprise SAN replacement |

**TCP vs RDMA tradeoff:**
```
RDMA (RoCE):
  Pro: near-local NVMe latency (kernel-bypass for data path)
  Pro: zero-copy — data goes directly to application memory
  Con: requires lossless Ethernet (PFC, ECN) — complex network config
  Con: requires RDMA-capable NICs (~$500-2000/port)
  Con: operationally complex (fabric management, PFC storms)

TCP:
  Pro: works on any network (standard 25/100GbE NICs)
  Pro: simple operations — no special network config
  Pro: widely supported, well-understood failure modes
  Con: higher latency (~200µs vs ~70µs for RDMA on same distance)
  Con: more CPU overhead (TCP stack processing)
  Use: when TCP latency is acceptable (most cloud/hyperscale deployments)
```

---

## 3. NVMe-oF Target Setup (TCP)

```bash
# Load target modules
modprobe nvmet
modprobe nvmet-tcp

# Create a subsystem (the NVMe-oF "endpoint")
mkdir /sys/kernel/config/nvmet/subsystems/testnqn
echo 1 > /sys/kernel/config/nvmet/subsystems/testnqn/attr_allow_any_host

# Add a namespace to the subsystem (backed by local NVMe or file)
mkdir /sys/kernel/config/nvmet/subsystems/testnqn/namespaces/1
echo /dev/nvme0n1 > /sys/kernel/config/nvmet/subsystems/testnqn/namespaces/1/device_path
# OR use a file as backing store (for testing):
echo /tmp/nvmeof-test.img > /sys/kernel/config/nvmet/subsystems/testnqn/namespaces/1/device_path
echo 1 > /sys/kernel/config/nvmet/subsystems/testnqn/namespaces/1/enable

# Create a port (TCP on port 4420)
mkdir /sys/kernel/config/nvmet/ports/1
echo "127.0.0.1" > /sys/kernel/config/nvmet/ports/1/addr_traddr
echo "tcp"       > /sys/kernel/config/nvmet/ports/1/addr_trtype
echo "4420"      > /sys/kernel/config/nvmet/ports/1/addr_trsvcid
echo "ipv4"      > /sys/kernel/config/nvmet/ports/1/addr_adrfam

# Link subsystem to port
ln -s /sys/kernel/config/nvmet/subsystems/testnqn \
      /sys/kernel/config/nvmet/ports/1/subsystems/testnqn

echo "Target configured. Listening on 127.0.0.1:4420"
```

---

## 4. NVMe-oF Host Discovery and Connect (TCP)

```bash
# Load host modules
modprobe nvme-tcp

# Discover available subsystems on target
nvme discover -t tcp -a 127.0.0.1 -s 4420
# Output shows: NQN, transport, address, port, subsystem type

# Connect to subsystem
nvme connect -t tcp -a 127.0.0.1 -s 4420 -n testnqn

# Verify connected
nvme list
# Shows new nvme device (e.g., nvme1n1)

# Check the fabric connection
cat /sys/class/nvme/nvme1/transport     # "tcp"
cat /sys/class/nvme/nvme1/address       # "traddr=127.0.0.1,trsvcid=4420"
cat /sys/class/nvme/nvme1/state         # "live"

# Disconnect
nvme disconnect -n testnqn
```

---

## 5. Latency Measurement: Local vs NVMe-oF/TCP

```bash
# Setup test image for target backing store
dd if=/dev/zero of=/tmp/nvmeof-test.img bs=1M count=4096

# (After target and host setup from above)
REMOTE_DEV=/dev/nvme1n1   # the NVMe-oF connected device
LOCAL_DEV=/dev/nvme0n1    # local NVMe for comparison

# Measure 4K random read latency at depth 1 (pure latency, no queue effects)
echo "=== Local NVMe latency ==="
fio --name=local-lat \
    --filename=$LOCAL_DEV \
    --rw=randread --bs=4k \
    --ioengine=libaio --iodepth=1 \
    --time_based --runtime=15 \
    --percentile_list=50,99,99.9

echo "=== NVMe-oF/TCP loopback latency ==="
fio --name=nvmeof-lat \
    --filename=$REMOTE_DEV \
    --rw=randread --bs=4k \
    --ioengine=libaio --iodepth=1 \
    --time_based --runtime=15 \
    --percentile_list=50,99,99.9

# Expected results (loopback, same machine):
# Local NVMe:     p50=50µs   p99=120µs
# NVMe-oF/TCP:   p50=250µs  p99=500µs
# Overhead: ~200µs for TCP loopback (real network adds more)

# Throughput at depth 32 (bandwidth, not latency)
echo "=== NVMe-oF/TCP throughput ==="
fio --name=nvmeof-tput \
    --filename=$REMOTE_DEV \
    --rw=randread --bs=128k \
    --ioengine=libaio --iodepth=32 \
    --time_based --runtime=15
# Should approach network bandwidth limit (not NVMe limit)
```

---

## 6. Queue Allocation Over Fabric

```c
// drivers/nvme/host/fabrics.c

// When host connects to target:
nvmf_connect_io_queue():
    // 1. Send CONNECT command to target (fabric-specific)
    //    CONNECT specifies: subsystem NQN, host NQN, queue ID, queue size
    // 2. Target creates a corresponding queue on its side
    // 3. Both sides have matched queue pairs

// Queue count negotiation:
// Host requests: min(host_max_queues, target_max_queues, nr_cpus)
// Each I/O queue pair = one blk_mq_hw_ctx on host
// Target allocates corresponding resources per queue
```

```bash
# Check queue count for NVMe-oF device
cat /sys/block/nvme1n1/queue/nr_hw_queues
# Typically: min(local_CPUs, target_max_queues)
# For loopback: likely == nproc

ls /sys/block/nvme1n1/mq/ | wc -l   # one dir per HW queue
```

---

## 7. ANA: Asymmetric Namespace Access

ANA (Asymmetric Namespace Access) is NVMe-oF's multipathing mechanism.
Each namespace can be accessed through multiple paths (controllers), with
different access states:

```
ANA states:
  ANA_OPTIMIZED    — preferred path (direct access to local storage)
  ANA_NON_OPTIMIZED — works but not preferred (cross-controller access)
  ANA_INACCESSIBLE — path is down, don't use
  ANA_PERSISTENT_LOSS — path permanently gone
  ANA_CHANGE       — transitioning to new state

Example: Active/Passive HA storage array
  Controller A → nvme0 (ANA_OPTIMIZED for namespaces 1-4)
  Controller B → nvme1 (ANA_OPTIMIZED for namespaces 5-8)
               → nvme0 (ANA_NON_OPTIMIZED for namespaces 1-4, if A fails)
```

```bash
# Check ANA state for each path
nvme ana-log /dev/nvme0
# Shows ANA group states for each namespace

# The kernel's nvme multipath automatically:
# - Routes I/O to OPTIMIZED paths first
# - Fails over to NON_OPTIMIZED if OPTIMIZED fails
# - Balances I/O across multiple OPTIMIZED paths

# Enable/verify multipath
cat /sys/module/nvme_core/parameters/multipath
# "Y" = multipath enabled (default in most distros)

# List all paths to a namespace
ls /sys/block/nvme0n1/holders/   # if multipath: shows nvmeXnY devices
nvme list-subsys                  # shows all paths per subsystem
```

---

## 8. NVMe-oF: When It's the Right Architecture

**Use NVMe-oF when:**
```
Disaggregated storage:
  Compute nodes have no local NVMe
  Central storage nodes export NVMe-oF namespaces
  Scales storage and compute independently
  Common in hyperscale: Google, Meta, Alibaba all use variants of this

Shared NVMe access:
  Multiple hosts access same namespace (read-only or with coordination)
  Database shared disk for HA without SAN

High-density storage:
  One storage node with 24× NVMe exports to 100+ compute nodes
  Better utilization than local storage (pool vs per-server)
```

**Don't use NVMe-oF when:**
```
Latency < 200µs required:
  TCP adds ~200µs; even RDMA adds ~20µs
  Local NVMe at ~50µs for latency-critical paths

Simple single-server:
  Complexity of NVMe-oF not justified for one server, few disks

Storage not shared:
  If each host always uses its own data, local NVMe is simpler and faster
```

---

## 9. Target Teardown

```bash
# Clean up NVMe-oF target (reverse order of setup)

# Disconnect host first
nvme disconnect -n testnqn

# Remove port-subsystem link
rm /sys/kernel/config/nvmet/ports/1/subsystems/testnqn

# Disable namespace
echo 0 > /sys/kernel/config/nvmet/subsystems/testnqn/namespaces/1/enable

# Remove namespace, subsystem, port
rmdir /sys/kernel/config/nvmet/subsystems/testnqn/namespaces/1
rmdir /sys/kernel/config/nvmet/subsystems/testnqn
rmdir /sys/kernel/config/nvmet/ports/1

# Unload modules
modprobe -r nvmet-tcp nvmet
```

---

## 10. Self-Check Questions

1. What exactly travels over the NVMe-oF fabric — data, commands, or both?
2. Why does NVMe-oF/TCP have higher latency than NVMe-oF/RDMA even at the same network distance?
3. What is the ANA_NON_OPTIMIZED state and when would the kernel route I/O through it?
4. A 10GbE NVMe-oF/TCP connection with 200µs RTT. What queue depth is needed to saturate a device capable of 300K IOPS at 4K?
5. You have 8 storage nodes each with 12× NVMe, serving 200 compute nodes. Local NVMe latency is 50µs. Your application requires p99 < 1ms. Is NVMe-oF/TCP viable?
6. What is the NVMe discovery protocol and why does it matter for operations?

## 11. Answers

1. Both. Commands travel from host to target over the fabric (replacing PCIe MMIO). Data travels bidirectionally: write data goes host→target, read data goes target→host. The fabric replaces both the PCIe transport of commands and the DMA transfer of data.
2. RDMA bypasses the TCP/IP stack and kernel networking: data goes directly from NIC to memory via DMA without CPU involvement. TCP requires: userspace→kernel copy (for non-zero-copy paths), TCP stack processing, socket buffer management, ACK-based flow control. Each adds latency. Even with kernel-bypass TCP (DPDK), the protocol overhead remains.
3. ANA_NON_OPTIMIZED means the path works but is not the preferred path — typically because I/O crosses a storage controller (e.g., Controller B accessing namespaces primarily served by Controller A). The kernel routes I/O through NON_OPTIMIZED paths only when all OPTIMIZED paths are unavailable — i.e., failover scenario.
4. Queue depth = IOPS × RTT = 300,000 × 0.0002s = 60 in-flight requests minimum to saturate device. Use iodepth=64 or higher. At 10GbE bandwidth: 300K × 4K = 1.2GB/s — exceeds 10GbE (~1.25GB/s). So bandwidth-limited before IOPS limit; would need 25GbE to saturate 300K IOPS at 4K.
5. Yes, viable. NVMe-oF/TCP adds ~200µs overhead → total p50 ~250µs, well under 1ms. p99 depends on network congestion and target load distribution. With proper QoS (DSCP marking for storage traffic, dedicated storage VLAN) and load balancing across 8 storage nodes, p99 <1ms is achievable. RDMA would give more headroom but TCP is viable.
6. NVMe-oF discovery is a lightweight subsystem (NQN: `nqn.2014-08.org.nvmexpress.discovery`) that a host queries to find available storage subsystems without prior knowledge. The host connects to a discovery controller (port 4420 default), sends a Get Log Page command, and receives a list of target subsystems with their addresses and transport types. Operationally: discovery allows dynamic storage provisioning (new namespaces become visible without host reconfiguration) and is the foundation for NVMe-oF management automation.

---

## Tomorrow: Day 24 — NVMe-oF: Failure Handling & Multipathing

We simulate path failure, observe ANA state transitions and reconnect
behavior, and design a resilient NVMe-oF multipath architecture.
