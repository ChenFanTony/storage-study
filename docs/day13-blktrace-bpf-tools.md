# Day 13: blktrace & BPF Tools

## Learning Objectives
- Understand `blktrace`/`blkparse` output format and event classification
- Use BCC/bpftrace block-layer tools for live observability
- Correlate trace events with block-layer concepts from Days 8–12
- Build a practical tracing workflow for storage debugging

---

## 1. Why Block-Layer Tracing

Block-layer tracing sits between the filesystem and the device driver. It captures events at the request queue boundary — exactly where scheduling, merging, and dispatch decisions happen.

Key use cases:
- Latency attribution (where time is spent in the I/O path)
- Merge and plug behavior verification
- Queue depth and concurrency analysis
- Correlating application I/O patterns with device behavior

---

## 2. blktrace / blkparse

### Overview

`blktrace` captures per-CPU block-layer events via the kernel's `tracepoint` infrastructure. `blkparse` formats and filters the captured data.

```
blktrace (capture)  →  blkparse (format/filter)  →  btt (analyze)
```

### Event Flow in blktrace

blktrace traces a request through these stages:

```
 Q  — Queued (bio enters the request queue)
 G  — Get request (request struct allocated)
 M  — Merged (bio merged into existing request)
 I  — Inserted into scheduler/dispatch queue
 D  — Dispatched to driver
 C  — Completed (hardware completion)
 P  — Plug (plugging starts)
 U  — Unplug (plugging ends, requests flushed)
```

The time between these events reveals where latency accumulates:
- **Q→G**: request allocation overhead
- **G→I**: scheduler insertion time
- **I→D**: scheduler queue wait (scheduling latency)
- **D→C**: device service time (hardware + driver)
- **Q→C**: total I/O latency from block layer perspective

### Basic Usage

```bash
# Capture events on a device (run in one terminal)
sudo blktrace -d /dev/sda -o trace

# In another terminal, generate I/O
dd if=/dev/sda of=/dev/null bs=4k count=1000 iflag=direct

# Stop blktrace (Ctrl-C), then parse
blkparse -i trace -o trace.txt

# Or capture + parse in one pipeline
sudo blktrace -d /dev/sda -o - | blkparse -i -
```

### Reading blkparse Output

Example output line:
```
  8,0    1       12     0.000456789  1234  Q  WS 123456 + 8 [dd]
  │      │       │      │            │     │  │  │        │  │
  │      │       │      │            │     │  │  sector   │  process
  │      │       │      │            │     │  rw flags    nr_sectors
  │      │       │      │            │     event code
  │      │       │      │            PID
  │      │       │      timestamp (seconds)
  │      │       sequence number
  │      CPU
  major,minor
```

Fields:
- **major,minor**: device numbers (8,0 = /dev/sda)
- **CPU**: which CPU processed the event
- **event code**: Q/G/M/I/D/C/P/U etc.
- **rw flags**: R (read), W (write), S (sync), D (discard), etc.
- **sector + nr_sectors**: LBA range of the I/O
- **process**: originating process name

### btt — Block Trace Timing

`btt` post-processes blktrace data for statistical analysis:

```bash
# Generate timing statistics
blkparse -i trace -d trace.bin
btt -i trace.bin
```

`btt` output includes:
- Q2C (total latency), D2C (device time), Q2D (queueing time)
- Per-process I/O statistics
- Seek distance distributions
- Plug/unplug event counts

---

## 3. BCC Block Tools

BCC (BPF Compiler Collection) provides ready-made tools that attach to block-layer tracepoints and kprobes. They are simpler to use than raw blktrace for common tasks.

### biolatency — I/O Latency Histogram

Shows the distribution of block I/O latency:

```bash
sudo biolatency
# Output: histogram of I/O completion times
#   usecs           : count    distribution
#       0 -> 1      : 0       |                                    |
#       2 -> 3      : 0       |                                    |
#       4 -> 7      : 15      |***                                 |
#      64 -> 127    : 187     |****************************************|
#     128 -> 255    : 42      |*********                           |

# Per-disk breakdown
sudo biolatency -D

# Show timestamps
sudo biolatency -T
```

Key insight: bimodal distributions often indicate mixed workloads or cache hits vs misses at the device level.

### biosnoop — Per-I/O Event Tracing

Shows every block I/O with latency:

```bash
sudo biosnoop
# Output:
# TIME(s)     COMM           PID    DISK    T  SECTOR    BYTES   LAT(ms)
# 0.000000    dd             1234   sda     W  123456    4096    0.45
# 0.000512    dd             1234   sda     W  123464    4096    0.38

# Filter by disk
sudo biosnoop -d sda

# Filter by PID
sudo biosnoop -p 1234
```

Useful for identifying outlier I/Os and correlating latency with specific processes.

### bitesize — I/O Size Distribution

Shows block I/O size distribution per process:

```bash
sudo bitesize
# Output:
# Process          : count    distribution
#   dd
#       1 -> 1     : 0       |                                    |
#    4096 -> 8191  : 500     |****************************************|
```

Helps identify whether applications are issuing optimally-sized I/Os.

### biotop — Top-like I/O Monitor

```bash
sudo biotop
# Shows per-process I/O rates, updated periodically
# PID    COMM         D MAJ MIN  DISK   I/O  Kbytes  AVGms
# 1234   postgres     R 8   0    sda    150  1200    0.82
```

---

## 4. bpftrace One-Liners for Block Layer

bpftrace allows ad-hoc block-layer investigation with concise scripts:

### I/O latency histogram
```bash
sudo bpftrace -e '
tracepoint:block:block_rq_issue { @start[args.dev, args.sector] = nsecs; }
tracepoint:block:block_rq_complete /@start[args.dev, args.sector]/ {
    @usecs = hist((nsecs - @start[args.dev, args.sector]) / 1000);
    delete(@start[args.dev, args.sector]);
}
END { clear(@start); }'
```

### I/O size by process
```bash
sudo bpftrace -e '
tracepoint:block:block_rq_issue {
    @bytes[comm] = hist(args.bytes);
}'
```

### Count I/O by type (read/write)
```bash
sudo bpftrace -e '
tracepoint:block:block_rq_issue {
    @io_type[args.rwbs] = count();
}'
```

### Queue depth over time
```bash
sudo bpftrace -e '
tracepoint:block:block_rq_issue { @depth = count(); }
tracepoint:block:block_rq_complete { @depth = count(); }'
```

### Trace merges
```bash
sudo bpftrace -e '
tracepoint:block:block_bio_backmerge { @merges["back"] = count(); }
tracepoint:block:block_bio_frontmerge { @merges["front"] = count(); }'
```

---

## 5. Practical Tracing Workflow

A systematic approach to block-layer investigation:

```
1. Start broad        →  biolatency (is there a latency problem?)
2. Identify outliers  →  biosnoop (which I/Os are slow?)
3. Check patterns     →  bitesize (right I/O sizes?)
                         bpftrace merge script (merging as expected?)
4. Deep dive          →  blktrace + btt (full event timeline)
5. Correlate          →  Match block events to application behavior
```

Guidelines:
- Always note the I/O scheduler and queue settings before tracing
- Capture baseline traces under known-good conditions for comparison
- Use `biolatency -D` to separate per-disk when multiple devices are active
- Combine block-layer tracing with filesystem-level tools (ftrace on VFS) for full-stack analysis

---

## 6. Key Tracepoints

The block layer exposes tracepoints under `tracepoint:block:*`:

| Tracepoint | Fires When |
|-----------|------------|
| `block_bio_queue` | bio enters request queue |
| `block_bio_backmerge` | bio merged at back of existing request |
| `block_bio_frontmerge` | bio merged at front of existing request |
| `block_rq_insert` | request inserted into scheduler queue |
| `block_rq_issue` | request dispatched to driver |
| `block_rq_complete` | request completed by device |
| `block_rq_requeue` | request requeued |
| `block_plug` | plug started |
| `block_unplug` | plug released |

List all available:
```bash
sudo bpftrace -l 'tracepoint:block:*'
```

---

## 7. Hands-On Exercises

### Exercise 1: Basic blktrace capture
```bash
# Capture 5 seconds of activity on your primary disk
sudo blktrace -d /dev/sda -w 5 -o day13
blkparse -i day13 | head -50

# Count event types
blkparse -i day13 | awk '{print $6}' | sort | uniq -c | sort -rn
```

### Exercise 2: Compare sequential vs random I/O
```bash
# Terminal 1: capture
sudo blktrace -d /dev/sda -o - | blkparse -i - > /tmp/seq_trace.txt &
BLKTRACE_PID=$!

# Terminal 1: sequential workload
fio --name=seq --filename=/tmp/fio_test --size=64M --bs=128k \
    --rw=read --direct=1 --ioengine=libaio --iodepth=1 --runtime=5

kill $BLKTRACE_PID

# Look for M (merge) events — sequential should show many merges
grep ' M ' /tmp/seq_trace.txt | wc -l

# Repeat with random read (--rw=randread --bs=4k) — expect fewer merges
```

### Exercise 3: biolatency under load
```bash
# Start biolatency
sudo biolatency -D 5 &

# Generate mixed workload
fio --name=mixed --filename=/tmp/fio_test --size=64M --bs=4k \
    --rw=randrw --rwmixread=70 --direct=1 --ioengine=libaio \
    --iodepth=32 --runtime=10

# Observe the histogram output
```

### Exercise 4: biosnoop for outlier detection
```bash
# Capture per-I/O events, filter for slow ones (>1ms)
sudo biosnoop | awk '$NF > 1.0 {print}'

# Generate workload in another terminal
```

### Exercise 5: bpftrace merge counting
```bash
# Count merges during a sequential write
sudo bpftrace -e '
tracepoint:block:block_bio_backmerge { @merges["back"] = count(); }
tracepoint:block:block_bio_frontmerge { @merges["front"] = count(); }
tracepoint:block:block_bio_queue { @total = count(); }
interval:s:5 { exit(); }'

# In another terminal:
dd if=/dev/zero of=/tmp/day13_test bs=4k count=10000 oflag=direct
```

### Exercise 6: Full btt analysis
```bash
sudo blktrace -d /dev/sda -w 10 -o day13_full
blkparse -i day13_full -d day13_full.bin
btt -i day13_full.bin

# Review Q2C, D2C, Q2D columns
# Q2D large → scheduling/merge overhead
# D2C large → device is slow
```

---

## 8. Common Pitfalls

1. **Tracing overhead**: `blktrace` can generate large amounts of data on busy systems. Use `-w` (duration) or filter by event type to limit capture size.

2. **Confusing bio events with request events**: bio tracepoints fire per-bio, request tracepoints fire per-request (which may contain multiple merged bios).

3. **Missing context without scheduler info**: always check `cat /sys/block/<dev>/queue/scheduler` before interpreting trace data — scheduler choice affects merge, reorder, and dispatch behavior.

4. **Clock skew across CPUs**: blktrace timestamps are per-CPU. Large apparent latencies across CPUs may reflect clock synchronization, not real delays.

5. **biolatency vs application latency**: `biolatency` measures block-layer latency (D→C or Q→C depending on version). Application-visible latency includes VFS, page cache, and filesystem overhead above the block layer.

---

## 9. Tool Installation Reference

```bash
# blktrace
sudo apt install blktrace

# BCC tools (biolatency, biosnoop, bitesize, biotop)
sudo apt install bpfcc-tools
# Tools are typically at /usr/sbin/ with -bpfcc suffix:
#   biolatency-bpfcc, biosnoop-bpfcc, etc.

# bpftrace
sudo apt install bpftrace

# Verify tracepoints are available
sudo bpftrace -l 'tracepoint:block:*' | head
```

---

## 10. Self-Check Questions

1. What does the blktrace event code 'M' represent?
2. In btt output, what does Q2C measure vs D2C?
3. How does `biolatency` differ from `biosnoop` in terms of output?
4. Why might you see many merge events with sequential I/O but few with random I/O?
5. What tracepoint fires when a request is dispatched to the device driver?
6. How can you determine if latency is caused by the scheduler vs the device?

## 11. Self-Check Answers

1. **M** = merge: a bio was merged into an existing request (front or back merge).
2. **Q2C** = total block-layer latency (queue to complete). **D2C** = device service time (dispatch to complete). The difference (Q2D) is queueing/scheduling overhead.
3. `biolatency` shows a histogram (aggregate distribution). `biosnoop` shows per-I/O events with individual latencies.
4. Sequential I/O targets adjacent sectors, making back-merges possible. Random I/O targets scattered sectors with no merge opportunity.
5. `tracepoint:block:block_rq_issue`.
6. Compare Q2D (scheduling time) vs D2C (device time). If Q2D dominates, the scheduler or queue depth is the bottleneck. If D2C dominates, the device is slow.

---

## 12. Tomorrow's Preview: Day 14 — Week 2 Review

Day 14 is a review day. We will:
- Re-read the bio → request → dispatch path end-to-end
- Draw the full block I/O diagram from memory
- Consolidate Days 8–13 into a coherent mental model
- Trace any block I/O from `submit_bio()` to hardware completion
