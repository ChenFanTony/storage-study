# Day 7: Week 1 Review — Architect Decision Points

## Objective
Synthesize Days 1–6 into a defensible reference you can use in real design
reviews. This is not passive review — you produce a written output today.

---

## 1. What You Should Now Be Able to Explain

Before proceeding, verify you can explain each of these to a peer engineer
**without looking anything up**. Mark any gaps for re-review.

| Topic | Can Explain? |
|-------|-------------|
| How a bio becomes a tagged request in blk-mq | |
| What queue depth controls and how to find the right value | |
| What happens when all tags in a tag set are exhausted | |
| The plug/unplug mechanism and when it helps vs hurts | |
| The writeback cliff and what causes it | |
| The difference between `dirty_background_ratio` and `dirty_ratio` | |
| How read-ahead adaptive window growth works | |
| Why aggressive read-ahead can hurt bcache hit rate | |
| When to use `none` vs `mq-deadline` vs `bfq` | |
| What p99 latency tells you that average does not | |
| How `io.max`, `io.weight`, `io.latency` differ | |

---

## 2. The Decision Matrix (Fill This In)

Complete this table based on your understanding from the week.
If you can't fill in a cell, that's a gap to address.

### Queue Depth Selection

| Device | Workload | Recommended Depth | Rationale |
|--------|----------|-------------------|-----------|
| NVMe local | random 4K, latency-sensitive | | |
| NVMe local | sequential throughput | | |
| virtio-blk (VM) | mixed | | |
| HDD | random read | | |
| HDD via bcache | mixed | | |
| NVMe-oF (TCP) | any | | |

**Hint for NVMe-oF:** fabric RTT is ~100µs vs local NVMe's ~50µs.
To saturate a 10Gbps link with 4K I/O: bandwidth = 10Gbps / 8 / 4K = ~300K IOPS.
Queue depth needed: IOPS × RTT = 300K × 0.0001s = 30 in-flight minimum.

### Scheduler Selection

| Scenario | Scheduler | Key Reason |
|----------|-----------|-----------|
| NVMe, single tenant | | |
| NVMe, multi-tenant containers | | |
| HDD, database (latency matters) | | |
| HDD, multiple competing jobs | | |
| bcache composite device | | |
| NVMe-oF target | | |

### Writeback Tuning

| Workload | dirty_background_bytes | dirty_bytes | Rationale |
|----------|----------------------|-------------|-----------|
| Database (write-heavy, latency-sensitive) | | | |
| Bulk import / ETL | | | |
| Mixed (general purpose) | | | |

---

## 3. Scenario: Design Review Simulation

**You are asked to configure the storage layer for a new PostgreSQL primary node.**
- Hardware: 2× NVMe (local), 32 cores, 256GB RAM
- Workload: OLTP, ~80% random reads, ~20% random writes
- SLA: p99 read latency < 5ms, p99 write latency < 10ms
- Containers: no (single workload)

Answer each question with justification:

1. **Scheduler:** What and why?
2. **Queue depth (`nr_requests`):** What range and how would you determine the right value?
3. **`dirty_ratio` / `dirty_bytes`:** PostgreSQL uses `O_DIRECT` for data files and buffered I/O for WAL. How does this change your writeback tuning?
4. **Read-ahead:** Should you tune `read_ahead_kb` for this workload?
5. **NUMA:** Your NVMe devices are on NUMA node 0. PostgreSQL is bound to NUMA node 0. Anything to verify in blk-mq queue mapping?

**Reference answers at end of this document.**

---

## 4. Scenario 2: Multi-Tenant Object Store

**You are designing storage for a Ceph OSD node:**
- Hardware: 1× NVMe (journal/WAL), 4× HDD (data)
- Tenants: 50 clients, varied I/O patterns
- Concern: one tenant's sequential scan should not starve others' random reads

Answer:

1. **Scheduler for NVMe journal:** ?
2. **Scheduler for HDD data disks:** ?
3. **cgroup mechanism:** Ceph OSDs run as a single process. Is cgroup I/O useful here?
4. **read_ahead_kb for HDD:** Ceph does large object reads (4MB+). What would you set?
5. **writeback:** With 4× HDD, at 256GB RAM, what is 20% dirty_ratio in bytes? Is this reasonable?

---

## 5. Hands-On: Produce Your Architecture Reference

Write a one-page (or one-screen) reference document covering the three
primary decisions from this week. Format it however is most useful to you
(table, decision tree, prose). The requirement is that it is something you
would actually use in a real design review.

**Minimum content:**
- Queue depth decision logic (with example numbers)
- Scheduler selection guide (device type × workload × tenancy)
- Writeback threshold guidance (absolute bytes preferred, with example values)

**Suggested structure:**
```markdown
# Storage Layer Configuration Reference
## Queue Depth
[your decision logic]

## I/O Scheduler
[your decision matrix]

## Writeback Thresholds
[your guidance]

## Tooling: How to Validate
[blktrace / bpftrace / fio commands you'll actually use]
```

---

## 6. Tools Drill

Run through this without looking up syntax — if you need to look something
up, add it to your notes:

```bash
# 1. Show per-device queue topology
ls /sys/block/nvme0n1/mq/

# 2. Show current in-flight I/O
cat /sys/block/nvme0n1/inflight

# 3. Check scheduler and queue depth
cat /sys/block/nvme0n1/queue/scheduler
cat /sys/block/nvme0n1/queue/nr_requests

# 4. Trace block I/O latency (D→C) for 10 seconds
bpftrace -e '
tracepoint:block:block_rq_issue   { @s[args.sector] = nsecs; }
tracepoint:block:block_rq_complete {
    $lat = nsecs - @s[args.sector];
    if (@s[args.sector]) { @us = hist($lat/1000); delete(@s[args.sector]); }
}
interval:s:10 { print(@us); exit(); }'

# 5. Check writeback pressure
grep -E "^(Dirty|Writeback):" /proc/meminfo

# 6. Show current writeback settings
sysctl vm.dirty_bytes vm.dirty_background_bytes \
       vm.dirty_ratio vm.dirty_background_ratio

# 7. Measure p99 latency on NVMe random 4K
fio --name=p99 --filename=/dev/nvme0n1 --rw=randread --bs=4k \
    --ioengine=libaio --iodepth=32 --time_based --runtime=30 \
    --percentile_list=50,99,99.9
```

---

## 7. Week 1 → Week 2 Bridge

Week 2 enters your area of deep expertise: bcache internals. But the goal
shifts from "understand how it works" to "know every failure mode and
performance limit."

Coming in Week 2, you should be able to answer:
- What happens to in-flight dirty writes when the bcache SSD device dies suddenly?
- How does bcache's GC pressure manifest under sustained write load?
- At what point does bcache's btree lock contention become the bottleneck on high-queue-depth NVMe?
- What does dm-cache's SMQ policy do that bcache's LRU does not?

If you can answer these now, your Week 2 will go quickly.
If not, Week 2 will be highly productive.

---

## Reference Answers: PostgreSQL Scenario

1. **Scheduler:** `none` — single workload, NVMe, no need for fairness. Scheduler overhead adds tail latency without benefit.

2. **Queue depth:** Start at 32–64 per HW queue, benchmark with `fio --iodepth` sweep. Find the knee where p99 starts rising faster than IOPS grow. PostgreSQL random I/O pattern will likely saturate at 32–64.

3. **Writeback:** PostgreSQL data files use `O_DIRECT` — they bypass page cache entirely, so `dirty_ratio` doesn't apply to data I/O. WAL uses buffered I/O — tune `dirty_bytes` conservatively (e.g. 64–128MB) for WAL to prevent cliff events on commit latency. Use absolute bytes, not ratio, so tuning is stable regardless of RAM.

4. **Read-ahead:** For data files (`O_DIRECT`): irrelevant, bypasses page cache. For WAL: WAL is written sequentially, moderate read-ahead is fine (128KB). For shared_buffers hit files: PostgreSQL manages its own cache; kernel read-ahead may be redundant — consider `0` or `16` to avoid cache pollution.

5. **NUMA:** Verify `cat /sys/block/nvme0n1/device/numa_node` matches PostgreSQL's NUMA binding. If misaligned, cross-NUMA memory accesses occur for every I/O completion — adds ~100ns per I/O, significant at 100K+ IOPS. Bind PostgreSQL to NUMA node 0 and verify NVMe is on node 0.

---

## Tomorrow: Day 8 — bcache Internals: Bucket GC & SSD Wear

Week 2 begins. We go deep on bcache's allocation and GC subsystem —
the part that determines long-term SSD health and write amplification.
