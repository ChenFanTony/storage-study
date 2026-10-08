# Day 27: Performance Baseline

## What this day covers

Measure baseline IOPS and latency for one exported namespace using `bdevperf` (target-side)
and `fio` with the Linux NVMe initiator (end-to-end). Record numbers you can compare
against after making changes.

---

## Why measure now

You have been focused on correctness. Before making any performance-affecting changes in
Week 4 or beyond, establish a baseline. This gives you:

- a reference to detect regressions
- context for interpreting profiling results
- realistic numbers to compare against published SPDK benchmarks

---

## Tool 1: bdevperf (target-side, no network)

`bdevperf` exercises the bdev layer directly without going through NVMf. It measures
pure bdev throughput and latency.

```bash
# Run bdevperf on an AIO bdev
sudo $SPDK_DIR/build/examples/bdevperf \
    -m 0x1 \
    -q 128 \
    -o 4096 \
    -t 10 \
    -r /var/tmp/bdevperf.sock \
    --wait-for-rpc &

# Wait for RPC, then create bdev and run
sleep 2
sudo $SPDK_DIR/scripts/rpc.py -s /var/tmp/bdevperf.sock \
    bdev_aio_create /dev/sdb Aio0 512

sudo $SPDK_DIR/scripts/rpc.py -s /var/tmp/bdevperf.sock \
    bdev_set_qos_limit --rw-ios-per-sec 0 Aio0  # no limit

sudo $SPDK_DIR/scripts/rpc.py -s /var/tmp/bdevperf.sock \
    bdevperf_run

# Wait for completion
wait
```

Parameters:

- `-q 128`: queue depth
- `-o 4096`: I/O size in bytes (4KB)
- `-t 10`: runtime in seconds
- `-m 0x1`: use CPU core 0

Output includes:

- IOPS
- MB/s
- average latency in microseconds

Run for multiple workload types:

```bash
# Random read
bdevperf ... -w randread

# Random write
bdevperf ... -w randwrite

# Sequential read
bdevperf ... -w read

# Mixed 70/30 read/write
bdevperf ... -w randrw -M 70
```

---

## Tool 2: fio via NVMf (end-to-end)

This measures performance through the full NVMf stack: TCP → ctrlr.c → bdev → AIO.

### Setup target

```bash
sudo $SPDK_DIR/build/bin/nvmf_tgt -m 0x3 &  # use cores 0 and 1
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_transport \
    -t TCP -u 131072 -m 128 -c 8192
sudo $SPDK_DIR/scripts/rpc.py bdev_aio_create /dev/sdb Aio0 512
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_subsystem \
    nqn.2024-01.io.spdk:perf -a -s SPDK00000000000001
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_listener \
    nqn.2024-01.io.spdk:perf -t TCP -a 192.168.1.10 -s 4420
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.2024-01.io.spdk:perf Aio0 -n 1
```

### Connect from initiator

```bash
sudo modprobe nvme-tcp
nvme connect -t tcp -a 192.168.1.10 -s 4420 \
    -n nqn.2024-01.io.spdk:perf
```

### Run fio

```bash
# Random 4K read, queue depth 32
sudo fio \
    --filename=/dev/nvme0n1 \
    --rw=randread \
    --bs=4k \
    --numjobs=1 \
    --iodepth=32 \
    --runtime=30 \
    --time_based \
    --ioengine=io_uring \
    --direct=1 \
    --name=randread-4k-qd32 \
    --output-format=json \
    --output=/tmp/fio-randread-4k-qd32.json

# Random 4K write
sudo fio \
    --filename=/dev/nvme0n1 \
    --rw=randwrite \
    --bs=4k \
    --numjobs=1 \
    --iodepth=32 \
    --runtime=30 \
    --time_based \
    --ioengine=io_uring \
    --direct=1 \
    --name=randwrite-4k-qd32

# Sequential 128K read
sudo fio \
    --filename=/dev/nvme0n1 \
    --rw=read \
    --bs=128k \
    --numjobs=1 \
    --iodepth=8 \
    --runtime=30 \
    --time_based \
    --ioengine=io_uring \
    --direct=1 \
    --name=seqread-128k-qd8
```

Parse JSON output for key metrics:

```bash
python3 -c "
import json
with open('/tmp/fio-randread-4k-qd32.json') as f:
    d = json.load(f)
job = d['jobs'][0]
read = job['read']
print(f'IOPS: {read[\"iops\"]:.0f}')
print(f'BW: {read[\"bw_bytes\"] / 1e6:.1f} MB/s')
print(f'avg lat: {read[\"lat_ns\"][\"mean\"] / 1000:.1f} us')
print(f'p99 lat: {read[\"clat_ns\"][\"percentile\"][\"99.000000\"] / 1000:.1f} us')
"
```

---

## Baseline results table

Record your results here:

| Workload | Queue depth | Block size | IOPS | BW (MB/s) | avg lat (μs) | p99 lat (μs) |
|---|---|---|---|---|---|---|
| randread | 1 | 4K | | | | |
| randread | 32 | 4K | | | | |
| randwrite | 1 | 4K | | | | |
| randwrite | 32 | 4K | | | | |
| seqread | 8 | 128K | | | | |
| seqwrite | 8 | 128K | | | | |

---

## What the numbers tell you

For AIO-backed bdev over TCP:

- **IOPS** will be limited by the kernel AIO path and network round trips, not SPDK
  overhead. Typical range: 50K–200K IOPS for 4K random depending on storage and NIC.
- **Latency** at QD=1 is the most revealing: it shows raw single-request round trip
  time through the stack. Typical range: 100–500μs for AIO over loopback TCP.
- **The NVMf overhead** (SPDK side) is typically a few microseconds. Most latency
  comes from AIO, TCP, and the backing device.

For NVMe passthrough bdev over TCP, numbers are dramatically better. If you have
NVMe hardware, try:

```bash
sudo $SPDK_DIR/scripts/rpc.py bdev_nvme_attach_controller \
    -b NVMe0 -t PCIe -a 0000:01:00.0
```

---

## bdev iostat

While fio is running, inspect live stats on the target:

```bash
sudo $SPDK_DIR/scripts/rpc.py bdev_get_iostat -b Aio0
```

This shows:

- bytes read/written
- I/O count
- current queue depth estimate

---

## What matters most after Day 27

1. AIO-backed NVMf is not a latency benchmark — the kernel AIO path dominates.
2. Use bdevperf first to isolate bdev-layer performance from transport overhead.
3. p99 latency matters more than average for storage systems under mixed load.
4. Your baseline numbers are a regression guard for any future code changes.

---

## Suggested next step

Day 28: failure path lab. Intentionally break things and observe how SPDK handles
them: live namespace removal, host disconnect mid-I/O, target restart under load,
PTPL behavior under failure.
