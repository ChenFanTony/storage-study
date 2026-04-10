# 30-Day Linux Kernel Storage Study Plan

**Created:** 2026-04-08
**Revised:** 2026-04-10
**Status:** Active
**Audience:** Experienced engineer targeting Storage Architect role (familiar with bcache, block layer, virtio-blk, extX)
**Goal:** Deepen expertise across the full storage stack; master modern I/O paths, tiering failure semantics, NVMe-oF, and production-grade design decisions

---

## Curriculum Modules

| Module | Topic | Key Source | Level |
|--------|-------|-----------|-------|
| 1 | Storage Stack Gap-Fill | `Documentation/block/` | Fast-pass |
| 2 | blk-mq Internals & Queue Depth | `block/blk-mq.c` | Deep |
| 3 | Page Cache & Writeback Semantics | `mm/filemap.c`, `mm/page-writeback.c` | Deep |
| 4 | Tiering: bcache Internals (Expert) | `drivers/md/bcache/` | Expert |
| 5 | Tiering: dm-cache & dm-thin | `drivers/md/dm-cache*`, `dm-thin.c` | Deep |
| 6 | Tiering Failure Semantics | crash analysis, writeback vs writethrough | Expert |
| 7 | Device Mapper Core + dm-crypt/verity | `drivers/md/dm.c`, `dm-crypt.c` | Deep |
| 8 | md/RAID & Failure Recovery | `drivers/md/md.c`, `raid1.c`, `raid5.c` | Deep |
| 9 | XFS In Depth | `fs/xfs/` — AG model, log, allocator | Deep |
| 10 | JBD2 Crash Recovery (ext4) | `fs/jbd2/`, `fs/ext4/` | Targeted |
| 11 | Btrfs: CoW, Snapshots, Send/Receive | `fs/btrfs/ctree.c` | Deep |
| 12 | NVMe Driver & Multi-Namespace | `drivers/nvme/host/` | Deep |
| 13 | NVMe-oF (TCP + RDMA) | `drivers/nvme/host/fabrics.c`, `tcp.c` | Expert |
| 14 | io_uring Deep Dive | `io_uring/` — fixed bufs, passthrough | Expert |
| 15 | ZNS & Zoned Devices | `block/blk-zoned.c`, `zonefs` | Deep |
| 16 | Persistent Memory / DAX | `fs/dax.c`, `drivers/dax/` | Deep |
| 17 | cgroup I/O & Latency Control | `block/blk-cgroup.c`, `blk-iolatency.c` | Deep |
| 18 | blk-crypto & fscrypt | `block/blk-crypto.c` | Deep |
| 19 | Full-Stack Performance Tuning | fio, bpftrace, perf, scheduler tuning | Expert |
| 20 | Architect Decision Lab | Design review: tiering, encryption, NVMe-oF | Expert |

---

## Week 1: Fast-Pass Foundation + blk-mq & Writeback Depth

> You know this layer. The goal is to **plug gaps and reach expert depth** on blk-mq and writeback — the two areas most architects underestimate.

### Day 1 — Storage Stack Gap-Fill (Half Day)
- **Read:** `Documentation/block/` — skim for anything unfamiliar
- **Hands-on:** `cat /proc/diskstats`, explore `/sys/block/<dev>/mq/`, verify your mental model
- **Goal:** Confirm your I/O path diagram is complete; note any gaps for later days
- **Skip if comfortable:** VFS core structures, path lookup, basic bio lifecycle

### Day 2 — blk-mq: Hardware Queues, Tag Sets, Dispatch
- **Read:** `block/blk-mq.c` — focus on `blk_mq_init_queue()`, tag set allocation, `__blk_mq_run_hw_queue()`
- **Read:** `block/blk-mq-tag.c` — how tags map to in-flight requests
- **Hands-on:** Compare `/sys/block/<dev>/mq/` on NVMe (many HW queues) vs virtio-blk (fewer); measure queue depth impact with `fio --iodepth`
- **Goal:** Explain exactly how a bio becomes a tagged request and gets dispatched to a HW queue

### Day 3 — blk-mq: Scheduler Interaction & Plug/Unplug
- **Read:** `block/blk-mq-sched.c`, `block/blk-merge.c`, plug/unplug in `blk-mq.c`
- **Hands-on:** `blktrace` — identify P (plug), U (unplug), M (merge) events on a real workload; correlate with latency
- **Goal:** Understand when plugging helps vs hurts; know when to set `none` scheduler on NVMe

### Day 4 — Page Cache: Writeback Thresholds & Flusher Behavior
- **Read:** `mm/page-writeback.c` — `balance_dirty_pages()`, flusher thread wakeup conditions
- **Read:** `fs/fs-writeback.c` — `wb_writeback()`, inode dirty list
- **Hands-on:** Tune `dirty_ratio` / `dirty_bytes` / `dirty_expire_centisecs`; use `bpftrace` to trace `balance_dirty_pages` call rate under heavy write load
- **Goal:** Predict writeback cliff behavior; know why large dirty ratios cause latency spikes

### Day 5 — Read-ahead: Adaptive Algorithm & Tiering Implications
- **Read:** `mm/readahead.c` — `ondemand_readahead()`, async prefetch window growth
- **Hands-on:** Tune `read_ahead_kb` for HDD-backed bcache vs pure SSD; measure with `fio` sequential
- **Goal:** Understand how read-ahead interacts with a cache tier — when it helps (cold HDD reads) and when it wastes cache (random workloads)

### Day 6 — I/O Schedulers: Architect's View
- **Read:** `block/mq-deadline.c` (latency guarantees), `block/bfq-iosched.c` (fairness model)
- **Hands-on:** Benchmark `none` vs `mq-deadline` vs `bfq` with `fio` mixed read/write; measure p99 latency not just throughput
- **Goal:** Know which scheduler to choose for: NVMe, HDD-backed cache, multi-tenant storage, real-time workloads

### Day 7 — Week 1 Review: Architect Decision Points
- **Review:** blk-mq queue depth tuning, writeback cliff, scheduler selection
- **Write:** A one-page decision matrix: "Given workload X, I choose scheduler Y and queue depth Z because..."
- **Goal:** Be able to defend storage configuration choices under cross-examination

---

## Week 2: Tiering Deep Dive — bcache, dm-cache, Failure Semantics

> This is your existing strength. The goal is to reach **expert + architect level**: failure modes, GC behavior, policy tradeoffs, and where both solutions fall short.

### Day 8 — bcache Internals: Bucket GC & SSD Wear
- **Read:** `drivers/md/bcache/alloc.c` — bucket allocation, GC (`bch_allocator_thread`)
- **Read:** `drivers/md/bcache/writeback.c` — writeback rate control, dirty data tracking
- **Hands-on:** Instrument bcache GC with `bpftrace`; observe bucket reclaim under heavy write load
- **Goal:** Explain how bcache GC interacts with SSD write amplification; know the conditions that cause GC pressure

### Day 9 — bcache: Cache Coherency Under Failure
- **Read:** `drivers/md/bcache/journal.c`, `super.c` — journal replay, cache set recovery
- **Hands-on:** Simulate cache device failure (detach mid-write); verify backing device consistency
- **Goal:** Answer precisely: what data is lost in writeback mode under (a) cache device failure, (b) system crash, (c) dirty shutdown

### Day 10 — bcache: Limitations & Where It Breaks Down
- **Study:** bcache behavior under high-queue-depth NVMe (contention on btree locks); sequential scan thrashing; ZNS incompatibility
- **Hands-on:** Reproduce cache thrashing with `fio` mixed sequential + random; observe hit rate collapse
- **Goal:** Know when NOT to use bcache; be able to propose alternatives (dm-cache, application-level tiering)

### Day 11 — dm-cache: Architecture & Policy Plugins
- **Read:** `drivers/md/dm-cache-target.c` — cache map, migration engine
- **Read:** `drivers/md/dm-cache-policy-smq.c` — SMQ policy (default)
- **Hands-on:** Set up dm-cache with `smq` vs `cleaner` policy; benchmark promotion/demotion latency
- **Goal:** Compare dm-cache vs bcache: metadata overhead, policy flexibility, failure behavior differences

### Day 12 — dm-thin: Thin Provisioning & Metadata
- **Read:** `drivers/md/dm-thin.c`, `drivers/md/dm-thin-metadata.c`
- **Hands-on:** Create thin pool, provision thin volumes, inspect metadata with `thin_dump`; simulate metadata device failure
- **Goal:** Understand mapping tree, snapshot COW, and what happens to all thin volumes when metadata device fails

### Day 13 — Tiering Failure Semantics: Full Analysis
- **Study:** Construct a failure matrix across: bcache writeback, bcache writethrough, dm-cache writeback, dm-cache writethrough, dm-thin with/without metadata redundancy
- **Hands-on:** For each mode: inject failure, verify actual data state, compare to expected
- **Goal:** Produce a failure semantics reference table you could present to a customer or use in an architecture document

### Day 14 — Week 2 Review: Tiering Architecture Decisions
- **Write:** Architect's guide: "Choosing and configuring a tiering solution" — covering workload fit, failure tolerance, GC tuning, operational complexity
- **Goal:** Be able to design a tiering solution and justify every parameter choice

---

## Week 3: Filesystems (Production Focus) + Device Mapper

### Day 15 — Device Mapper Core + dm-crypt
- **Read:** `drivers/md/dm.c` — `dm_submit_bio()`, target dispatch, map_info
- **Read:** `drivers/md/dm-crypt.c` — per-bio encryption, async crypto, IV modes
- **Hands-on:** Create LUKS2 volume; measure encryption overhead at different queue depths; test with `cryptsetup benchmark`
- **Goal:** Understand dm-crypt's per-bio crypto model; know the performance cost at architect level

### Day 16 — md/RAID: Resync, Bitmap Journal, Failure Recovery
- **Read:** `drivers/md/md.c`, `drivers/md/raid1.c`, `drivers/md/raid5.c`
- **Hands-on:** Create RAID-1 and RAID-5; force member failure; observe resync; test write-intent bitmap impact on resync time
- **Goal:** Understand RAID personalities, resync checkpointing, and partial-stripe write problem in RAID-5

### Day 17 — XFS: AG Model, Log Design, Allocator
- **Read:** `fs/xfs/xfs_alloc.c` — AG-based allocation, B+tree allocators
- **Read:** `fs/xfs/xfs_log.c` — log architecture, checkpoint, log recovery
- **Hands-on:** `xfs_info`, `xfs_db`, `xfs_logprint`; analyze log behavior under heavy metadata workload
- **Goal:** Understand why XFS is preferred for large files and parallel I/O; know its failure recovery model

### Day 18 — XFS: Delayed Allocation, Speculative Preallocation & Reflink
- **Read:** `fs/xfs/xfs_iomap.c` — delalloc, speculative preallocation
- **Read:** `fs/xfs/xfs_refcount*.c` — reflink/CoW fork
- **Hands-on:** Benchmark XFS delalloc behavior; test reflink (`cp --reflink`); measure CoW overhead
- **Goal:** Understand XFS's modern features relevant to storage architecture (dedupe, reflink, large-file performance)

### Day 19 — ext4: JBD2 Crash Recovery (Targeted)
- **Read:** `fs/jbd2/recovery.c`, `fs/jbd2/journal.c` — commit, checkpoint, recovery phases
- **Hands-on:** Force unclean shutdown on ext4; observe journal recovery; use `debugfs` to inspect journal
- **Goal:** Since you know extX layout, focus on: what exactly JBD2 guarantees, ordered vs writeback vs journal mode tradeoffs for a storage architect

### Day 20 — Btrfs: CoW B-tree, Snapshots, Send/Receive
- **Read:** `fs/btrfs/ctree.c` — CoW B-tree mechanics
- **Read:** `fs/btrfs/send.c` — send/receive stream format
- **Hands-on:** Create subvolumes; test snapshot + send/receive for incremental backup; measure CoW fragmentation over time
- **Goal:** Understand when Btrfs snapshots + send/receive is the right backup/replication architecture choice

### Day 21 — Week 3 Review: Filesystem Architecture Decisions
- **Write:** Decision matrix: XFS vs ext4 vs Btrfs — for object storage, database, backup, container image store workloads
- **Goal:** Defend filesystem choice for any given production workload

---

## Week 4: Modern I/O Path — NVMe, NVMe-oF, io_uring, ZNS, pmem

> This is the frontier. An architect who doesn't know NVMe-oF and io_uring is behind the industry.

### Day 22 — NVMe Driver: Queue Pairs, Multi-Namespace, Passthrough
- **Read:** `drivers/nvme/host/core.c`, `pci.c` — queue setup, namespace management
- **Read:** `drivers/nvme/host/ioctl.c` — NVMe passthrough (`NVME_IOCTL_IO_CMD`)
- **Hands-on:** `nvme list`, `nvme id-ctrl`, `nvme smart-log`; send raw NVMe commands via passthrough; explore multi-namespace with `nvme list-ns`
- **Goal:** Understand NVMe queue pair architecture; know when and why to use passthrough (SPDK-style bypass)

### Day 23 — NVMe-oF: Architecture & Transport Comparison
- **Read:** `drivers/nvme/host/fabrics.c`, `tcp.c`, `rdma.c`
- **Read:** `drivers/nvme/target/` — target-side implementation
- **Hands-on:** Set up NVMe-oF/TCP loopback (host + target on same machine); measure latency vs local NVMe; test with `fio`
- **Goal:** Understand discovery, queue allocation, and the latency/throughput tradeoff of TCP vs RDMA transports; know when NVMe-oF is and isn't the right architecture

### Day 24 — NVMe-oF: Failure Handling & Multipathing
- **Read:** `drivers/nvme/host/multipath.c` — ANA (Asymmetric Namespace Access)
- **Hands-on:** Simulate target path failure; observe reconnect behavior; test ANA path failover
- **Goal:** Design a resilient NVMe-oF architecture: understand ANA states, path selection, and reconnect semantics

### Day 25 — io_uring: Deep Dive — Fixed Buffers, Registered Files, Passthrough
- **Read:** `io_uring/io_uring.c` — SQ/CQ rings, `io_submit_sqes()`
- **Read:** `io_uring/rsrc.c` — fixed buffers and registered files
- **Read:** `io_uring/uring_cmd.c` — NVMe passthrough via io_uring
- **Hands-on:** Write programs using: (1) basic io_uring read, (2) fixed buffers, (3) io_uring + NVMe passthrough; benchmark vs O_DIRECT
- **Goal:** Understand io_uring's kernel-bypass potential; know when it outperforms O_DIRECT and when it doesn't

### Day 26 — ZNS: Zone Types, Write Pointer, Zone Append
- **Read:** `Documentation/block/zoned-blockdevices.rst`, `block/blk-zoned.c`
- **Read:** `fs/zonefs/` — zonefs design
- **Hands-on:** Use `null_blk` zoned mode; write zone-aware `fio` jobs; test `zonefs`; explore `f2fs` on zoned device
- **Goal:** Understand ZNS constraints for architects: why it exists, what filesystems/applications are zone-aware, how it changes tiering design

### Day 27 — Persistent Memory / DAX Path
- **Read:** `fs/dax.c` — DAX fault path, `dax_direct_access()`
- **Read:** `drivers/dax/super.c`, `drivers/nvdimm/`
- **Hands-on:** Use `memmap` kernel param to emulate pmem; mount ext4/XFS with `-o dax`; benchmark DAX vs non-DAX
- **Goal:** Understand how DAX bypasses page cache AND block layer; know the implications for tiering architecture when pmem is in the stack

### Day 28 — cgroup I/O: Weight, Throttle, Latency Target
- **Read:** `block/blk-cgroup.c`, `block/blk-throttle.c`, `block/blk-iolatency.c`
- **Hands-on:** Configure `io.max`, `io.weight`, `io.latency` in cgroup v2; observe how `io.latency` throttles competing cgroups; test under contention
- **Goal:** Design multi-tenant I/O isolation: know the difference between throttle (hard limit) and latency target (adaptive); understand interaction with blk-mq under saturation

### Day 29 — Full-Stack Performance Tuning Lab
- **Workload:** Choose a real workload: PostgreSQL, RocksDB, or container image store
- **Tune:** Scheduler, queue depth, readahead, mount options, cgroup I/O, NVMe queue count
- **Instrument:** `biolatency`, `bpftrace`, `perf stat`, `fio` for validation
- **Goal:** Demonstrate measurable p99 latency improvement; document every tuning decision with justification

### Day 30 — Architect Review & Forward Roadmap
- **Produce:** Full storage stack architecture diagram (syscall → hardware, annotated with design decisions)
- **Write:** "Storage Architecture Decision Guide" — a reference document covering: tiering choice, filesystem choice, NVMe-oF vs local, encryption, cgroup isolation
- **Identify:** 3 areas for next 30-day deep dive (e.g., SPDK/DPDK bypass, Ceph RADOS, io_uring + eBPF storage offload)
- **Goal:** Have a defensible, written architecture reference you can use in real design reviews

---

## Daily Study Structure

```
Each Day (~2.5-3 hours)

[20 min]  Skim LWN article or kernel commit history for today's topic
[40 min]  Read kernel source (focused — know what you're looking for)
[70 min]  Hands-on lab with real instrumentation (bpftrace / blktrace / fio)
[20 min]  Write architect-level notes: tradeoffs, failure modes, decision criteria
[10 min]  Review yesterday's notes
```

## Weekly Milestones

| Week | Architect Capability Unlocked |
|------|-------------------------------|
| 1 | Defend blk-mq queue depth and scheduler choices under cross-examination |
| 2 | Design a tiering solution; specify failure behavior for any cache configuration |
| 3 | Choose and justify a filesystem for any production workload; explain JBD2/XFS log recovery |
| 4 | Design a disaggregated NVMe-oF storage system; specify io_uring usage for high-performance I/O |

## Tools to Install

```bash
# tracing & profiling
apt install linux-tools-common bpfcc-tools bpftrace blktrace

# filesystem tools
apt install e2fsprogs xfsprogs btrfs-progs f2fs-tools

# NVMe-oF
apt install nvme-cli   # includes nvme-cli fabrics support
modprobe nvmet nvmet-tcp nvme-tcp

# development
apt install liburing-dev libspdk-dev   # io_uring + optional SPDK exploration

# emulate pmem
# add 'memmap=4G!12G' to kernel cmdline for 4GB pmem region at 12GB offset
```

## Key References

- **"Understanding the Linux Kernel"** — Bovet & Cesati
- **"Linux Kernel Development"** — Robert Love
- **"BPF Performance Tools"** — Brendan Gregg
- **LWN.net** — lwn.net — *read the bcache, io_uring, ZNS, NVMe-oF, and dm-cache LWN articles specifically*
- **kernel.org docs** — `Documentation/filesystems/`, `Documentation/block/`, `Documentation/admin-guide/device-mapper/`, `Documentation/nvme/`
- **NVMe Spec** — nvmexpress.org — NVMe base spec + NVMe-oF spec + ZNS spec
- **SPDK docs** — spdk.io — for understanding the user-space storage stack (context for kernel decisions)
- **Brendan Gregg's site** — brendangregg.com — storage performance methodology
