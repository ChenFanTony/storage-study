# Day 9: blk-mq Architecture (Multi-Queue Block Layer)

## Learning Objectives
- Understand why blk-mq replaced legacy single-queue block paths
- Distinguish software queues and hardware dispatch queues
- Learn the role of tag sets and request lifecycles
- Understand CPU locality and queue mapping
- Practice inspecting blk-mq topology and behavior from `/sys/block`

---

## 1. Why blk-mq Exists

Modern storage devices (especially NVMe) support high parallelism. A single global lock/queue becomes a bottleneck.

blk-mq (block multi-queue) was introduced to:
- reduce lock contention
- improve CPU locality
- scale submission/completion with core count
- better match hardware that has multiple submission/completion queues

---

## 2. High-Level Flow: bio to hardware queue

Conceptual path:

```text
filesystem/page cache
  -> submit_bio()
    -> blk-mq entry
      -> map to per-CPU software context (blk_mq_ctx)
      -> merge/allocate request + tag
      -> scheduler (optional)
      -> dispatch to hardware context (blk_mq_hw_ctx)
      -> driver queue_rq()
      -> device processes command
      -> completion path -> request end
```

Key point: blk-mq separates **software submission staging** from **hardware dispatch context**.

---

## 3. Core blk-mq Objects

### `struct request`
Represents a dispatchable block request (possibly derived from one or more bios).

### `struct blk_mq_ctx` (software queue context)
- typically per-CPU submission-side context
- helps avoid global contention

### `struct blk_mq_hw_ctx` (hardware queue context)
- represents dispatch context mapped to device queue(s)
- used for driver-facing queue_rq dispatch

### `struct blk_mq_tag_set`
- shared request/tag allocation framework for one or more queues/devices
- controls queue depth and tag management

---

## 4. Software vs Hardware Queues

### Software queues (`ctx`)
- close to submitting CPU
- batch and prepare requests
- improve cache locality and reduce cross-CPU locking

### Hardware queues (`hctx`)
- map to actual driver/device submission paths
- dispatch point for queue_rq callbacks

A common mapping model is many software queues feeding fewer or equal hardware queues, depending on device capability and configuration.

---

## 5. Tag-Based Request Management

blk-mq uses tags as request identifiers/slots:
- request allocation grabs a free tag
- active tag count reflects in-flight requests
- completion frees tag for reuse

Why tags matter:
- bounded queue depth enforcement
- efficient in-flight tracking
- direct indexing for completion handling

---

## 6. Scheduling in blk-mq

With mq schedulers enabled (e.g., `mq-deadline`, `bfq`, `kyber`):
- requests can be reordered/controlled before hardware dispatch
- policy goals include fairness, latency control, and throughput consistency

With `none` scheduler (common for high-performance NVMe in some setups):
- less policy overhead
- device/driver behavior dominates ordering characteristics

---

## 7. CPU Locality and Queue Mapping

blk-mq tries to keep submission/completion local where possible:
- submitting CPU generally uses local software context
- mapping from CPU to hardware queue is topology-aware
- reducing remote cacheline bouncing improves scalability

Observing queue topology is essential for tuning and understanding performance anomalies.

---

## 8. Request Lifecycle (Conceptual)

```text
allocate request (tag)
  -> attach/convert from bio context
  -> enqueue/schedule
  -> dispatch to driver queue_rq
  -> in-flight on hardware
  -> completion callback path
  -> end request + accounting
  -> release tag
```

Stalls can appear at allocation, scheduling, dispatch, device service, or completion processing stages.

---

## 9. Practical Inspection Exercises

### Exercise 1: Inspect queue scheduler and depth
```bash
cat /sys/block/nvme0n1/queue/scheduler
cat /sys/block/nvme0n1/queue/nr_requests
```

(Replace device as needed, e.g. `sda`.)

### Exercise 2: Inspect mq topology
```bash
ls /sys/block/nvme0n1/mq/
```

Each directory under `mq/` corresponds to a hardware queue context index.

### Exercise 3: Correlate CPU and queue behavior under load
```bash
fio --name=randread-mq --filename=/tmp/day9-mq.img --size=1G --rw=randread --bs=4k --iodepth=64 --numjobs=4 --ioengine=libaio --direct=1
```

Then inspect:
```bash
cat /sys/block/nvme0n1/stat
```

### Exercise 4: Compare schedulers
```bash
# inspect available + active scheduler
cat /sys/block/nvme0n1/queue/scheduler

# switch carefully for testing (example)
# echo mq-deadline | sudo tee /sys/block/nvme0n1/queue/scheduler
# run fio workload
# echo none | sudo tee /sys/block/nvme0n1/queue/scheduler
```

### Exercise 5: Source navigation quick grep
```bash
grep -n "blk_mq_submit_bio" block/blk-mq.c
grep -n "queue_rq" include/linux/blk-mq.h
grep -n "blk_mq_alloc_request" block/blk-mq.c
```

---

## 10. Source Navigation Checklist

Primary:
- `block/blk-mq.c`
- `include/linux/blk-mq.h`

Supporting:
- `block/blk-core.c`
- scheduler files in `block/` (`mq-deadline.c`, `bfq-iosched.c`, `kyber-iosched.c`)
- relevant driver dispatch path (e.g., `drivers/nvme/host/`)

---

## 11. Common Pitfalls

1. Assuming higher queue depth always improves latency
   - can increase tail latency or queueing delay

2. Ignoring scheduler impact
   - scheduler choice can materially change fairness/latency profiles

3. Overlooking CPU/NUMA locality
   - poor locality can reduce blk-mq scaling benefits

4. Treating all devices the same
   - SATA HDD/SSD and NVMe behave very differently under mq tuning

---

## 12. Self-Check Questions

1. What problem was blk-mq designed to solve compared to legacy block queues?
2. What is the difference between `blk_mq_ctx` and `blk_mq_hw_ctx`?
3. Why are tags central to blk-mq request handling?
4. Where can you inspect hardware queue indices for a block device?
5. How can scheduler choice affect workload behavior?

## 13. Self-Check Answers

1. It reduces contention and improves scalability/locality on modern parallel storage hardware.
2. `blk_mq_ctx` is software submission context (often per-CPU); `blk_mq_hw_ctx` is hardware dispatch context.
3. Tags provide bounded in-flight slot tracking and efficient request identification/completion.
4. Under `/sys/block/<dev>/mq/`.
5. It can shift latency/throughput/fairness trade-offs via request ordering and control policy.

---

## 14. Tomorrow’s Preview: Day 10 — I/O Schedulers

Next we focus on policy layers above dispatch:
- `mq-deadline`, `bfq`, `kyber`, `none`
- workload-specific trade-offs
- tuning and measurement methodology for scheduler comparison.
