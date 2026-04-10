# Day 22: NVMe Driver

## Learning Objectives
- Understand NVMe queue-pair architecture in Linux
- Follow host driver command lifecycle at a high level
- Learn key structures in `drivers/nvme/host/core.c` and `pci.c`
- Practice inspecting NVMe devices with `nvme-cli` and sysfs

---

## 1. Why NVMe Looks Different

NVMe is designed for parallel, low-latency flash access using multiple submission/completion queue pairs, unlike legacy single-queue storage interfaces.

In Linux, NVMe host support lives mainly in:
- `drivers/nvme/host/core.c`
- `drivers/nvme/host/pci.c`

---

## 2. Queue-Pair Model

Conceptually, each queue pair has:
- **Submission Queue (SQ):** host posts commands
- **Completion Queue (CQ):** controller posts completions

```text
CPU / blk-mq hctx
   -> NVMe SQ (submit command)
   -> device executes
   -> NVMe CQ (completion entry)
   -> interrupt/poll completion handler
```

Multiple queue pairs allow high concurrency and CPU locality.

---

## 3. Linux NVMe Host Architecture

Key conceptual objects:
- **Controller object**: represents NVMe controller state/lifecycle
- **Namespace objects**: logical block devices exposed as `/dev/nvmeXnY`
- **Queue resources**: admin queue + I/O queues

High-level init flow:
1. PCI probe discovers device
2. Controller reset/init sequence
3. Admin queue setup
4. Identify controller/namespaces
5. I/O queue creation and blk-mq integration
6. Namespace block devices become visible

---

## 4. Command Lifecycle (Simplified)

```text
block request arrives
  -> nvme_map_data() / command build
  -> post command to SQ tail
  -> ring doorbell (notify controller)
  -> controller executes command
  -> completion entry in CQ
  -> completion handler consumes CQE
  -> request completes to block layer
```

Important performance points:
- queue depth sizing
- interrupt affinity / CPU mapping
- polling vs interrupt mode in some scenarios

---

## 5. Admin Queue vs I/O Queues

- **Admin queue**: controller management commands (identify, features, etc.)
- **I/O queues**: data read/write commands for namespaces

Admin queue is required early in init before normal data I/O paths are ready.

---

## 6. Namespace Exposure

After successful identify/init, namespaces are exposed as block devices:
- `/dev/nvme0n1`, `/dev/nvme0n2`, ...

Controller device paths typically appear under:
- `/sys/class/nvme/nvme0/`
- `/sys/block/nvme0n1/`

---

## 7. Hands-On Exercises

### Exercise 1: Inspect NVMe devices
```bash
nvme list
lsblk -o NAME,MODEL,SIZE,TYPE,MOUNTPOINT | grep nvme
```

### Exercise 2: Inspect controller info
```bash
sudo nvme id-ctrl /dev/nvme0
```

### Exercise 3: Inspect namespace info
```bash
sudo nvme id-ns /dev/nvme0n1
```

### Exercise 4: Explore sysfs layout
```bash
ls /sys/class/nvme/
ls /sys/class/nvme/nvme0/
ls /sys/block/nvme0n1/queue/
cat /sys/block/nvme0n1/queue/nr_requests
cat /sys/block/nvme0n1/queue/scheduler
```

### Exercise 5: Basic workload and observation
```bash
fio --name=nvme-randread --filename=/tmp/day22-nvme.img --size=1G \
    --rw=randread --bs=4k --iodepth=64 --numjobs=4 \
    --ioengine=libaio --direct=1 --group_reporting
```

### Exercise 6: Source navigation
```bash
grep -rn "nvme_probe\|nvme_reset_work\|nvme_alloc_admin_tags" drivers/nvme/host/ | head -30
grep -rn "nvme_queue_rq\|nvme_submit_cmd\|nvme_complete_rq" drivers/nvme/host/ | head -40
```

---

## 8. Source Navigation Checklist

Primary:
- `drivers/nvme/host/core.c`
- `drivers/nvme/host/pci.c`

Supporting:
- `drivers/nvme/host/nvme.h`
- `include/linux/nvme.h`

---

## 9. Common Pitfalls

1. Treating all NVMe devices as identical
   - controller firmware, queue limits, and latency characteristics vary

2. Ignoring queue depth/affinity when benchmarking
   - poor settings can hide real device capability

3. Confusing controller resets with namespace errors
   - diagnose at controller and namespace levels separately

4. Running heavy tests on mounted production namespaces
   - always use safe test files/devices

---

## 10. Self-Check Questions

1. What is the difference between NVMe admin queue and I/O queues?
2. Why are multiple queue pairs important for performance?
3. Where in the kernel source are core NVMe host paths implemented?
4. Which userspace tool shows controller and namespace details?
5. What happens conceptually after ringing an NVMe submission doorbell?

## 11. Self-Check Answers

1. Admin queue handles controller-management commands; I/O queues carry normal read/write commands.
2. They enable high concurrency, reduced contention, and better CPU locality.
3. Mainly `drivers/nvme/host/core.c` and `drivers/nvme/host/pci.c`.
4. `nvme-cli` (e.g., `nvme list`, `nvme id-ctrl`, `nvme id-ns`).
5. Controller processes submitted command(s), posts completion to CQ, and host completion path finishes requests.

---

## 12. Tomorrow’s Preview: Day 23 — io_uring

Next we study asynchronous userspace I/O interface internals:
- SQ/CQ ring model
- submission/completion flow
- key file: `io_uring/io_uring.c`
- minimal `liburing` read example.
