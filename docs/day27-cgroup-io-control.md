# Day 27: cgroup I/O Control (cgroup v2)

## Learning Objectives
- Understand cgroup v2 I/O control concepts and use cases
- Learn key interfaces: `io.max`, `io.weight`, `io.latency`
- Practice isolating workloads with per-cgroup I/O policies
- Observe effects on throughput and latency under contention

---

## 1. Why cgroup I/O Control Matters

When multiple workloads share storage, one noisy job can degrade others.

cgroup I/O controls allow you to:
- limit bandwidth/IOPS for specific workloads
- prioritize important services
- protect latency-sensitive tasks
- enforce multi-tenant fairness

This is essential for production systems running mixed workloads.

---

## 2. cgroup v2 I/O Controller Basics

In cgroup v2, I/O control files are exposed under each cgroup directory (with io controller enabled).

Common files:
- `io.max` — absolute limits (bps/iops)
- `io.weight` — proportional share
- `io.latency` — latency-target-oriented control (kernel/config dependent)
- `io.stat` — usage and accounting stats

Base hierarchy:
- `/sys/fs/cgroup/`

---

## 3. `io.max` (Hard Limits)

`io.max` enforces device-specific throughput/IOPS caps.

Example format:
```text
<major>:<minor> rbps=<bytes/s> wbps=<bytes/s> riops=<iops> wiops=<iops>
```

Use when you need strict ceilings.

Example:
```bash
# limit writes to 20MB/s for device 8:0
echo "8:0 wbps=20971520" | sudo tee /sys/fs/cgroup/mygroup/io.max
```

---

## 4. `io.weight` (Proportional Sharing)

`io.weight` gives relative priority rather than absolute caps.

Typical range in cgroup v2:
- 1 to 10000 (default usually 100)

Example:
```bash
# higher priority for latency-sensitive group
echo 1000 | sudo tee /sys/fs/cgroup/critical/io.weight
# lower priority for batch
echo 100 | sudo tee /sys/fs/cgroup/batch/io.weight
```

Use when you want fair sharing with priority bias, not hard throttles.

---

## 5. `io.latency` (Latency Protection)

`io.latency` aims to help one cgroup meet latency goals under contention by controlling pressure from peers (availability depends on kernel/config/stack).

Conceptually:
- define latency target for a group/device
- kernel may throttle other groups when target is threatened

This is useful for service QoS protection but requires careful real-workload validation.

---

## 6. Workflow: Isolate and Control Workloads

Typical approach:
1. Create cgroups per workload class (e.g., `db`, `batch`)
2. Move workload processes into target cgroups
3. Apply `io.max` and/or `io.weight` policies
4. Monitor with `io.stat` and latency tools
5. Iterate carefully

---

## 7. Hands-On Exercises

### Exercise 1: Verify cgroup v2 and io controller
```bash
mount | grep cgroup2
cat /sys/fs/cgroup/cgroup.controllers
```

Ensure `io` appears in controllers list.

### Exercise 2: Create test cgroups
```bash
sudo mkdir -p /sys/fs/cgroup/critical
sudo mkdir -p /sys/fs/cgroup/batch
```

### Exercise 3: Enable io controller for children (if needed)
```bash
echo "+io" | sudo tee /sys/fs/cgroup/cgroup.subtree_control
```

### Exercise 4: Apply weights
```bash
echo 1000 | sudo tee /sys/fs/cgroup/critical/io.weight
echo 100  | sudo tee /sys/fs/cgroup/batch/io.weight
```

### Exercise 5: Apply hard cap to batch group
```bash
# example major:minor from lsblk -o MAJ:MIN,NAME
# replace 8:0 as needed
echo "8:0 rbps=10485760 wbps=10485760" | sudo tee /sys/fs/cgroup/batch/io.max
```

### Exercise 6: Run two competing fio jobs in separate cgroups
```bash
# batch workload
sudo bash -c 'echo $$ > /sys/fs/cgroup/batch/cgroup.procs; fio --name=batch --filename=/tmp/day27-batch.img --size=1G --rw=randwrite --bs=4k --iodepth=64 --ioengine=libaio --direct=1 --runtime=30 --time_based --group_reporting'

# critical workload (run in another terminal)
sudo bash -c 'echo $$ > /sys/fs/cgroup/critical/cgroup.procs; fio --name=critical --filename=/tmp/day27-critical.img --size=1G --rw=randread --bs=4k --iodepth=32 --ioengine=libaio --direct=1 --runtime=30 --time_based --group_reporting'
```

### Exercise 7: Inspect stats
```bash
cat /sys/fs/cgroup/critical/io.stat
cat /sys/fs/cgroup/batch/io.stat
```

### Exercise 8: Source navigation
```bash
grep -rn "blkcg\|throttle\|iolatency" block/ | head -50
```

---

## 8. Source Navigation Checklist

Primary:
- `block/blk-cgroup.c`
- `block/blk-throttle.c`
- `block/blk-iolatency.c`

Supporting:
- cgroup v2 docs in kernel `Documentation/admin-guide/cgroup-v2.rst`

---

## 9. Common Pitfalls

1. Mixing cgroup v1/v2 assumptions
   - interfaces differ significantly

2. Using only `io.max` everywhere
   - hard caps can underutilize resources; sometimes `io.weight` is better

3. Forgetting to move processes into target cgroup
   - policy files set but no effect if workload remains in parent cgroup

4. Ignoring device major:minor mapping
   - wrong device key means limits do not apply as intended

---

## 10. Self-Check Questions

1. What is the difference between `io.max` and `io.weight`?
2. Why is cgroup I/O control useful in multi-tenant systems?
3. Where do you read per-cgroup I/O accounting stats?
4. What must be done after creating a cgroup for a workload?
5. Which source file contains cgroup block-I/O core integration?

## 11. Self-Check Answers

1. `io.max` sets absolute per-device caps; `io.weight` sets proportional share priority.
2. It prevents noisy neighbors and enables fairness/QoS for critical workloads.
3. `io.stat` in the target cgroup directory.
4. Move workload process(es) into `cgroup.procs` of that cgroup.
5. `block/blk-cgroup.c`.

---

## 12. Tomorrow’s Preview: Day 28 — Inline Encryption

Next we study block-layer crypto integration:
- `blk-crypto` model
- hardware offload vs software fallback
- relation to fscrypt and storage capabilities.
