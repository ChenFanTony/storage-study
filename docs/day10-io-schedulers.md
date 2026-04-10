# Day 10: I/O Schedulers (mq-deadline, BFQ, Kyber, none)

## Learning Objectives
- Understand why I/O schedulers exist in modern Linux block stack
- Compare key mq schedulers: `mq-deadline`, `bfq`, `kyber`, and `none`
- Learn workload-specific scheduler trade-offs
- Practice safe scheduler switching and benchmarking
- Build a repeatable scheduler evaluation workflow

---

## 1. Why Scheduling Still Matters with blk-mq

blk-mq improves submission scalability, but policy decisions are still needed:
- how to order requests
- how to balance reads vs writes
- how to control latency under contention
- how to enforce fairness across workloads

Schedulers provide those policy choices.

---

## 2. Available Scheduler Models

### `none`
Minimal policy path.

Typical characteristics:
- lowest scheduler-layer overhead
- useful when device firmware/hardware does excellent internal scheduling (common on NVMe)
- can reduce software queuing complexity

### `mq-deadline`
Deadline-style scheduler for multi-queue.

Typical characteristics:
- prioritizes read latency predictability
- controls starvation by deadline logic
- often a balanced default for mixed workloads

### `bfq`
Budget Fair Queueing.

Typical characteristics:
- stronger fairness across processes/cgroups
- often good for desktop/interactivity and mixed-user systems
- can trade some peak throughput for fairness/latency consistency in shared environments

### `kyber`
Token/latency-oriented control model.

Typical characteristics:
- designed to manage latency targets under load
- can perform well with controlled queue-depth behavior
- behavior is workload/device dependent; measure rather than assume

---

## 3. Selecting a Scheduler by Workload

General guidance (validate on your hardware):

- **Single-tenant, high-performance NVMe throughput focus:** start with `none`
- **Mixed read/write service with latency sensitivity:** try `mq-deadline`
- **Multi-tenant fairness and interactive responsiveness:** try `bfq`
- **Latency-control experimentation under heavy load:** test `kyber`

No scheduler is universally best. Always benchmark using your real access pattern.

---

## 4. Inspecting Current Scheduler

Check active and available schedulers:

```bash
cat /sys/block/nvme0n1/queue/scheduler
```

Output example:

```text
[none] mq-deadline kyber bfq
```

Bracketed entry is active.

---

## 5. Switching Scheduler Safely

Example (replace device as needed):

```bash
# set mq-deadline
echo mq-deadline | sudo tee /sys/block/nvme0n1/queue/scheduler

# verify
cat /sys/block/nvme0n1/queue/scheduler
```

Important notes:
- this is a runtime setting (not persistent across reboot unless configured)
- change one variable at a time during testing
- avoid production changes without validation

---

## 6. Benchmark Design for Scheduler Comparison

To compare schedulers fairly:
1. Keep test file/device and size identical
2. Keep fio job parameters identical
3. Run multiple iterations per scheduler
4. Capture both throughput and latency percentiles
5. Separate buffered and direct-I/O experiments

Metrics to compare:
- IOPS / MB/s
- average latency
- tail latency (`p95`, `p99`, `p99.9`)
- latency consistency across runs

---

## 7. Hands-On Exercises

### Exercise 1: Baseline random read test
```bash
fio --name=rr-baseline --filename=/tmp/day10-sched.img --size=2G --rw=randread --bs=4k --iodepth=64 --numjobs=4 --ioengine=libaio --direct=1 --group_reporting
```

### Exercise 2: Test `none`
```bash
echo none | sudo tee /sys/block/nvme0n1/queue/scheduler
fio --name=rr-none --filename=/tmp/day10-sched.img --size=2G --rw=randread --bs=4k --iodepth=64 --numjobs=4 --ioengine=libaio --direct=1 --group_reporting
```

### Exercise 3: Test `mq-deadline`
```bash
echo mq-deadline | sudo tee /sys/block/nvme0n1/queue/scheduler
fio --name=rr-deadline --filename=/tmp/day10-sched.img --size=2G --rw=randread --bs=4k --iodepth=64 --numjobs=4 --ioengine=libaio --direct=1 --group_reporting
```

### Exercise 4: Test `bfq` (if available)
```bash
echo bfq | sudo tee /sys/block/nvme0n1/queue/scheduler
fio --name=rr-bfq --filename=/tmp/day10-sched.img --size=2G --rw=randread --bs=4k --iodepth=64 --numjobs=4 --ioengine=libaio --direct=1 --group_reporting
```

### Exercise 5: Mixed workload comparison
```bash
fio --name=mix70r30w --filename=/tmp/day10-sched.img --size=2G --rw=randrw --rwmixread=70 --bs=4k --iodepth=64 --numjobs=4 --ioengine=libaio --direct=1 --group_reporting
```

Run this mixed workload under each scheduler and compare tail latency.

---

## 8. Source Navigation Checklist

Primary scheduler sources:
- `block/mq-deadline.c`
- `block/bfq-iosched.c`
- `block/kyber-iosched.c`

Related core paths:
- `block/blk-mq.c`
- `include/linux/blk-mq.h`

---

## 9. Common Pitfalls

1. Picking scheduler based on generic advice only
   - hardware and workload details dominate outcome

2. Comparing single runs
   - scheduler effects can vary run-to-run; use repeated measurements

3. Looking only at average latency
   - tail latency often drives user-visible performance

4. Mixing buffered/direct tests unintentionally
   - page cache can hide scheduler effects in buffered mode

---

## 10. Self-Check Questions

1. Why can `none` be a good choice on some NVMe setups?
2. What trade-off does BFQ often optimize for?
3. Why is `p99` latency important in scheduler evaluation?
4. Which sysfs path is used to view/set scheduler?
5. Why should you benchmark with both random and mixed read/write patterns?

## 11. Self-Check Answers

1. It minimizes software scheduling overhead when hardware/device-side scheduling is already strong.
2. Fairness and responsiveness across competing workloads.
3. Tail latency captures worst-case behavior that average latency can hide.
4. `/sys/block/<dev>/queue/scheduler`.
5. Different schedulers may behave very differently across workload shapes.

---

## 12. Tomorrow’s Preview: Day 11 — Request Merge & Plug

Next we study:
- front-merge/back-merge concepts
- plugging/unplugging mechanics
- how merging affects throughput and device efficiency
- observing merge events in traces.
