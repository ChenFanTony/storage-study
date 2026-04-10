# Day 29: Performance Tuning Lab (Full-Stack)

## Learning Objectives
- Build a repeatable storage performance tuning workflow
- Integrate scheduler, queue depth, readahead, mount options, and cgroup I/O controls
- Use measurement-driven iteration instead of guesswork
- Demonstrate measurable improvement with baseline vs tuned evidence

---

## 1. Lab Goal

Today is an integration day: combine everything learned into one practical tuning exercise.

Target outcome:
- pick a representative workload
- collect baseline metrics
- apply controlled tuning changes (one variable at a time)
- report measurable improvement (throughput and/or latency)

---

## 2. Tuning Dimensions (What You Can Adjust)

1. **I/O scheduler**
   - `none`, `mq-deadline`, `bfq`, `kyber` (device-dependent)

2. **Queue depth / request pressure**
   - fio `iodepth`, `numjobs`
   - device queue settings where appropriate

3. **Read-ahead**
   - `/sys/block/<dev>/queue/read_ahead_kb`

4. **Filesystem mount options**
   - filesystem-specific options (e.g., ext4 commit/atime-related choices)

5. **cgroup I/O control**
   - `io.max`, `io.weight`, (and `io.latency` if available)

6. **Workload shape**
   - sequential vs random
   - read-heavy vs write-heavy
   - block size

---

## 3. Measurement Principles

- Benchmark the workload you actually care about
- Keep environment stable (minimal background noise)
- Change one major knob at a time
- Run multiple trials and compare medians/tails
- Track both throughput and latency (`avg`, `p95`, `p99`)

Without disciplined measurement, tuning results are often misleading.

---

## 4. Suggested Lab Workflow

```text
Step 1: Define workload profile(s)
Step 2: Capture baseline
Step 3: Tune scheduler
Step 4: Tune queue depth/concurrency
Step 5: Tune readahead (for read-heavy sequential)
Step 6: Tune cgroup controls (if multi-tenant)
Step 7: Re-test and compare
Step 8: Document final recommendation + rollback plan
```

---

## 5. Baseline Setup

### 5.1 Capture current system state
```bash
uname -r
lsblk -o NAME,MAJ:MIN,SIZE,ROTA,TYPE,MOUNTPOINT
cat /sys/block/<dev>/queue/scheduler
cat /sys/block/<dev>/queue/read_ahead_kb
cat /sys/block/<dev>/queue/nr_requests
```

### 5.2 Define benchmark profiles
Use at least two profiles:
- Profile A: random 4K mixed (service-like)
- Profile B: sequential read/write (streaming-like)

Example fio templates:
```bash
# Profile A: mixed random
fio --name=mix-baseline --filename=/tmp/day29-test.img --size=4G \
    --rw=randrw --rwmixread=70 --bs=4k --iodepth=64 --numjobs=4 \
    --ioengine=libaio --direct=1 --runtime=60 --time_based --group_reporting

# Profile B: sequential read
fio --name=seq-baseline --filename=/tmp/day29-test.img --size=4G \
    --rw=read --bs=128k --iodepth=16 --numjobs=1 \
    --ioengine=libaio --direct=1 --runtime=60 --time_based --group_reporting
```

---

## 6. Iterative Tuning Experiments

## 6.1 Scheduler tuning
```bash
cat /sys/block/<dev>/queue/scheduler
# set candidate
echo mq-deadline | sudo tee /sys/block/<dev>/queue/scheduler
# rerun profile(s)
```

Test each available scheduler and record results.

## 6.2 Queue depth/concurrency
Try combinations:
- `iodepth`: 8, 16, 32, 64
- `numjobs`: 1, 2, 4, 8

Keep one axis fixed while varying the other.

## 6.3 Readahead (sequential focus)
```bash
cat /sys/block/<dev>/queue/read_ahead_kb
echo 128  | sudo tee /sys/block/<dev>/queue/read_ahead_kb
echo 1024 | sudo tee /sys/block/<dev>/queue/read_ahead_kb
```

Rerun sequential profiles after each change.

## 6.4 cgroup isolation test (optional but recommended)
- create `critical` and `batch` cgroups
- cap batch with `io.max`
- verify critical latency improvement under contention

---

## 7. Observability During Tuning

Use these tools while workload runs:

- `iostat -x 1`
- `pidstat -d 1`
- `biolatency` / `biosnoop` (if available)
- `blktrace` for deep issue/dispatch/complete timing

Questions to answer from traces:
- Is latency dominated by queueing (Q2D) or device time (D2C)?
- Are merges effective?
- Is scheduler adding helpful or harmful delay?

---

## 8. Reporting Template

Document results in a simple table:

| Profile | Config | Throughput | Avg Lat | P95 | P99 | Notes |
|--------|--------|------------|--------:|----:|----:|------|
| mix | baseline | ... | ... | ... | ... | ... |
| mix | tuned#1 | ... | ... | ... | ... | scheduler=... |
| seq | baseline | ... | ... | ... | ... | ... |
| seq | tuned#2 | ... | ... | ... | ... | read_ahead_kb=... |

Final section should include:
- Recommended config
- Workload scope where recommendation applies
- Risks/trade-offs
- Rollback instructions

---

## 9. Hands-On Exercises

### Exercise 1: Run baseline suite (3 runs each)
```bash
# run Profile A and B three times, save outputs to files
fio ... > baseline_a_run1.txt
```

### Exercise 2: Scheduler sweep
```bash
# for each scheduler available:
cat /sys/block/<dev>/queue/scheduler
echo <sched> | sudo tee /sys/block/<dev>/queue/scheduler
# rerun baseline profiles
```

### Exercise 3: Queue-depth sweep
```bash
# keep scheduler fixed to best candidate, vary iodepth
```

### Exercise 4: Readahead sweep (sequential)
```bash
# vary read_ahead_kb and compare seq profile
```

### Exercise 5: Contention scenario with cgroups
```bash
# critical + batch concurrent workloads, compare critical latency
```

### Exercise 6: Summarize and choose final profile
```text
Pick configuration that best matches your production objective
(throughput, tail latency, fairness, or balanced outcome).
```

---

## 10. Common Pitfalls

1. Overfitting to synthetic microbenchmarks
2. Optimizing only average latency, ignoring tail
3. Changing many knobs simultaneously
4. Forgetting rollback/default capture
5. Declaring success without repeated runs

---

## 11. Self-Check Questions

1. Why must tuning be workload-specific?
2. What does changing one variable at a time help with?
3. Which metric is crucial for user-facing latency stability beyond averages?
4. Why might a throughput-optimal config be unacceptable in production?
5. What should every tuning recommendation include besides “best numbers”?

## 12. Self-Check Answers

1. Different workloads stress different parts of the stack; optimal settings differ.
2. It isolates causal impact and avoids confounded conclusions.
3. Tail latency (e.g., p95/p99).
4. It may cause poor fairness or high tail latency.
5. Scope, trade-offs, and rollback plan.

---

## 13. Tomorrow’s Preview: Day 30 — Final Review & Roadmap

Next is consolidation day:
- draw full syscall→hardware storage path from memory
- identify weak areas and next-study priorities
- build a concrete next-30-day roadmap.
