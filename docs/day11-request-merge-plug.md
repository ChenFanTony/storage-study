# Day 11: Request Merge & Plug (Block-Layer Efficiency)

## Learning Objectives
- Understand why request merging improves block I/O efficiency
- Distinguish front-merge and back-merge behavior
- Learn plugging/unplugging concepts in modern block paths
- Observe merge-related effects with tracing tools
- Evaluate merge behavior under different workload patterns

---

## 1. Why Merging Matters

Storage devices generally perform better with larger, contiguous I/O than many tiny fragmented requests.

Request merging helps by combining adjacent I/O operations, which can:
- reduce per-request overhead
- improve throughput
- reduce device command pressure
- improve locality (especially on HDD, also useful on SSD/NVMe in some patterns)

---

## 2. Merge Concepts

When incoming I/O is adjacent in LBA/sector space, block layer may merge it.

### Back merge
New request starts where existing request ends.

```text
existing: [100..199]
new:      [200..299]
result:   [100..299]
```

### Front merge
New request ends where existing request starts.

```text
existing: [200..299]
new:      [100..199]
result:   [100..299]
```

Back merges are often more common in naturally increasing sequential workloads.

---

## 3. Where Merging Happens

Merging decisions are made in block-layer request handling paths (blk-mq core/scheduler interactions), influenced by:
- adjacency of sectors
- operation compatibility (read vs write, flags)
- queue constraints
- scheduler policy and timing
- device limits (max segments, max sectors, alignment)

Not all adjacent bios can be merged due to these constraints.

---

## 4. Plugging and Unplugging

Plugging is a short-term batching strategy:
- delay immediate dispatch briefly
- accumulate requests
- increase chance of merge/reordering benefits

Unplugging is when queued requests are dispatched.

Why useful:
- more requests visible together improves optimization opportunities
- can increase throughput

Trade-off:
- excessive delay can increase latency

Modern blk-mq uses evolved dispatch logic, but the batching concept remains important for understanding behavior.

---

## 5. Workload Impact

### Sequential workloads
- usually high merge opportunities
- larger effective request sizes
- often better throughput

### Random workloads
- low adjacency, fewer merges
- more small independent requests
- merging contributes less

### Mixed workloads
- behavior depends on access interleaving and queue depth

---

## 6. Observability Signals

Useful indicators:
- block trace merge events (e.g., `M` in `blkparse` output)
- queue stats and throughput patterns during tests
- latency/IOPS changes when workload becomes more/less merge-friendly

You can infer merge efficiency by comparing similar workloads with different block sizes and access patterns.

---

## 7. Hands-On Exercises

### Exercise 1: Sequential vs random baseline
```bash
fio --name=seq-merge --filename=/tmp/day11-merge.img --size=2G --rw=read --bs=128k --iodepth=16 --ioengine=libaio --direct=1 --group_reporting
fio --name=rand-nomerge --filename=/tmp/day11-merge.img --size=2G --rw=randread --bs=4k --iodepth=16 --ioengine=libaio --direct=1 --group_reporting
```

Compare throughput and request behavior.

### Exercise 2: Trace merge events with blktrace
```bash
sudo blktrace -d /dev/sda -o - | blkparse -i - | grep " M " | head -50
```

(Use your actual device, e.g., `/dev/nvme0n1`.)

### Exercise 3: Full event sample for manual inspection
```bash
sudo blktrace -d /dev/sda -o - | blkparse -i - | head -120
```

Look for merge-related markers and sequence patterns.

### Exercise 4: Block-size sensitivity
```bash
fio --name=bs4k --filename=/tmp/day11-merge.img --size=2G --rw=read --bs=4k --iodepth=32 --ioengine=libaio --direct=1 --group_reporting
fio --name=bs128k --filename=/tmp/day11-merge.img --size=2G --rw=read --bs=128k --iodepth=32 --ioengine=libaio --direct=1 --group_reporting
```

Larger block sizes may reduce reliance on runtime merge opportunities.

### Exercise 5: Scheduler influence check
```bash
cat /sys/block/sda/queue/scheduler
# switch scheduler carefully, rerun one workload, compare merge/latency behavior
```

---

## 8. Source Navigation Checklist

Primary:
- `block/blk-merge.c` (merge logic)
- `block/blk-mq.c` (request path and dispatch interactions)

Supporting:
- scheduler implementation files in `block/`
- request limit definitions in block headers

---

## 9. Common Pitfalls

1. Assuming merges always happen for sequential reads
   - queue timing, alignment, and constraints can prevent merges

2. Attributing all throughput changes to scheduler only
   - merge opportunities and plug timing also matter

3. Ignoring tail latency
   - batching/plugging can improve throughput but hurt latency in some cases

4. Using only one test pattern
   - merge behavior is highly workload-dependent

---

## 10. Self-Check Questions

1. What is the difference between front merge and back merge?
2. Why does plugging increase merge opportunities?
3. Why are random workloads typically merge-poor?
4. Which source file is most directly associated with merge logic?
5. What is a practical trade-off of aggressive batching?

## 11. Self-Check Answers

1. Front merge prepends adjacent request before existing range; back merge appends after existing range.
2. It briefly accumulates more requests, making adjacency/reordering opportunities visible.
3. Their LBA pattern is non-adjacent, so contiguous ranges are rare.
4. `block/blk-merge.c`.
5. Throughput can improve, but latency may increase if dispatch is delayed too long.

---

## 12. Tomorrow’s Preview: Day 12 — Block Device Registration

Next we study how block devices become visible to userspace:
- `gendisk` and queue setup
- registration flow (`add_disk`/related paths)
- simple driver model via `null_blk`
- sysfs exposure and lifecycle basics.
