# Day 27: Persistent Memory / DAX Path

## Learning Objectives
- Understand the persistent memory programming model and how it differs from block storage
- Understand how DAX bypasses BOTH the page cache AND the block layer
- Know the durability model: clwb/sfence instead of fsync
- Emulate pmem from RAM for hands-on testing
- Understand the tiering implications: why bcache and dm-cache cannot cache pmem
- Know when pmem is and isn't the right architectural choice

---

## 1. The pmem Programming Model

Persistent memory (Intel Optane DC PMM, NVDIMM-N, CXL.mem persistent
regions) is byte-addressable nonvolatile memory that sits on the memory
bus, not the PCIe/storage bus.

```
Storage hierarchy (latencies, approximate):
  CPU register/L1 cache    ~1 ns
  L2/L3 cache              ~10 ns
  DRAM                     ~80 ns
  Persistent memory        ~300 ns  (Optane DCPMM, app direct mode)
  NVMe SSD (read)          ~50 µs   ← 100-200× slower than pmem
  NVMe SSD (fsync)         ~100 µs+ ← durability requires full I/O round-trip
  HDD                      ~5 ms
```

```
Two pmem access modes:

  Memory mode (cache-augmented DRAM):
    pmem appears as DRAM (volatile from OS perspective)
    OS sees more "RAM"; pmem is invisible as storage
    DRAM acts as cache for the pmem
    Not interesting from a storage architecture perspective

  App Direct mode (what we care about):
    pmem appears as a namespace (e.g., /dev/pmem0)
    OS sees it as persistent storage that can be byte-addressed
    Applications can mmap it and access bytes directly
    THIS is the interesting mode for storage architects
```

---

## 2. DAX: Direct Access — Bypassing Both Page Cache AND Block Layer

```
Normal mmap'd file on disk:
  mmap() → kernel sets up page cache pages backing the file
  Page fault on access → kernel reads block from disk into page cache
  Subsequent access → fast (hits page cache)
  msync() → kernel writes back dirty page cache pages to disk via block layer

DAX-mounted pmem file:
  mmap() → kernel inserts pmem physical pages directly into process page tables
  No page cache page allocated. No copy from pmem to page cache.
  Read/write directly touches the pmem hardware via CPU load/store.
  msync()/fsync() are NEARLY no-ops (no dirty page cache to flush)
  Durability: handled by user via clwb/sfence (Section 4)
```

```c
// fs/dax.c — the DAX page fault path

dax_iomap_fault(vmf, pe_size, ...):
    // Look up the file extent for this fault address
    iomap_iter() →  get iomap describing where the file's data lives on disk
                   For DAX: iomap.type = IOMAP_MAPPED + iomap.dax_dev != NULL

    // Translate file offset to PFN of underlying pmem
    dax_iomap_pfn(&iomap, pos, size, &pfn);

    // Insert the pmem PFN directly into the process page table
    vmf_insert_mixed(vma, vaddr, pfn);
    // ← key point: the page table entry now points DIRECTLY at pmem hardware
    // ← no page cache page allocated, no copy on read or write
    //
    // From now on, CPU loads/stores at this address bypass the kernel entirely
```

**The architectural consequence:**
```
Page cache:           bypassed
Block layer (blk-mq): bypassed
NVMe/SCSI driver:     bypassed
DMA:                  not used (CPU does load/store)
Device firmware:      not in the path

The CPU's load/store instructions are the only thing between
application and persistent storage.
```

---

## 3. Mounting Pmem with DAX

```bash
# Detect pmem namespaces
ndctl list -N
# Or: ls /dev/pmem*
# Or: dmesg | grep -i 'persistent memory'

# Format with DAX-aware filesystem
mkfs.ext4 -b 4096 -E nodiscard /dev/pmem0
# Or:
mkfs.xfs -f -m reflink=0 -b size=4096 /dev/pmem0
# (reflink=0 because DAX and reflink are mutually exclusive on XFS)

# Mount with DAX
mount -o dax /dev/pmem0 /mnt/pmem

# Verify DAX is active
mount | grep pmem
# /dev/pmem0 on /mnt/pmem type ext4 (rw,relatime,dax)

# Per-file DAX (XFS supports `-o dax=inode` granular DAX)
mount -o dax=inode /dev/pmem0 /mnt/pmem
xfs_io -c 'chattr +x' /mnt/pmem/dax_file   # enable DAX for this file
# Other files on the same mount stay non-DAX
```

---

## 4. The Durability Model: clwb and sfence

The page cache bypass is great for performance, but creates a problem:
**CPU stores may sit in CPU cache lines (L1/L2/L3) before reaching pmem.**

```
The pmem durability question:
  store r0, [pmem_addr]   ← does this reach pmem persistence?

  Without flush: NO. The store sits in CPU cache.
  Power loss between store and cache eviction → data lost.

  Pmem durability requires explicit cache line flush:
    clwb [pmem_addr]   ← flush cache line, but keep it in cache (clean state)
    sfence              ← ensure flush completes before subsequent stores
```

```c
// Application-side durability pattern (PMDK / libpmem):

void *pmem_addr;   // mapped via mmap() of DAX file

// Write data
memcpy(pmem_addr, source_data, len);

// Flush all touched cache lines
for (uintptr_t a = ((uintptr_t)pmem_addr & ~63);
     a < (uintptr_t)pmem_addr + len; a += 64) {
    asm volatile("clwb (%0)" :: "r"(a) : "memory");
}

// Memory fence ensures flushes complete before continuing
asm volatile("sfence" ::: "memory");

// Data is now durable on pmem (survives power loss)
```

**Comparison to fsync:**
```
NVMe fsync:
  Issue FLUSH command to device
  Wait for device ACK (~50-100 µs round-trip)
  All pending writes durable after this

Pmem clwb + sfence:
  Hundreds of nanoseconds for typical update
  No round-trip — CPU handles it locally
  Result: pmem durability is 100-1000× faster than NVMe fsync
```

```
ADR (Asynchronous DRAM Refresh):
  Server-platform feature: on power loss, the system has enough hold-up
  capacitance to flush memory-controller WPQ (write pending queue) to pmem.
  → stores that reached the memory controller (regardless of CPU cache state)
    are guaranteed durable.
  → clwb is still needed to push from CPU cache to memory controller.

eADR (extended ADR, newer platforms):
  Power hold-up also covers CPU cache.
  → stores reach pmem regardless of cache state.
  → clwb becomes unnecessary; only sfence for ordering.
  → check: cat /sys/bus/nd/devices/region0/persistence_domain
           "cpu_cache" = eADR; "memory_controller" = ADR only
```

---

## 5. MAP_SYNC: Synchronous Page Faults for Pmem

There's a subtle interaction: a new file extent on a DAX filesystem must
be persisted (metadata: the file size, the extent allocation) before
writes to it are visible to the application after a crash.

```c
// Pmem mmap with metadata durability guarantee:
fd = open("/mnt/pmem/datafile", O_RDWR);
addr = mmap(NULL, len, PROT_READ|PROT_WRITE,
            MAP_SHARED | MAP_SYNC,    // ← MAP_SYNC requires DAX
            fd, 0);

// With MAP_SYNC:
//   On page fault that allocates new file extent or grows the file,
//   the kernel SYNCHRONOUSLY persists the metadata change before
//   the fault returns. This ensures: if the application then writes
//   to that address (+ clwb + sfence), the metadata pointing at that
//   data is also durable.
//
// Without MAP_SYNC:
//   Metadata is durable only after fsync()/msync().
//   For pure mmap'd workloads (no fsync), data might be durable but
//   metadata pointing to it might not be → application sees data lost.
```

---

## 6. Filesystem Support for DAX

```
ext4:
  - mount -o dax (whole filesystem)
  - All files use DAX
  - Mature, stable

XFS:
  - mount -o dax    (whole filesystem)
  - mount -o dax=inode (per-file via chattr +x)
  - reflink is incompatible with DAX (mkfs.xfs -m reflink=0 for DAX FS)
  - Most flexible for mixed workloads

Btrfs:
  - No DAX support (CoW conflicts with byte-addressable update model)

Other:
  - tmpfs: not really DAX, but doesn't go through block layer
  - virtio-pmem: pmem semantics in VMs, uses host-side DAX
```

---

## 7. Emulating Pmem from RAM for Testing

Most environments don't have real Optane hardware. The Linux kernel can
emulate pmem from RAM using the `memmap` kernel boot parameter:

```bash
# Add to GRUB_CMDLINE_LINUX in /etc/default/grub:
GRUB_CMDLINE_LINUX="... memmap=4G!12G"
# Means: reserve 4 GB of RAM starting at physical address 12 GB,
#        mark as type-12 (persistent memory). Will appear as /dev/pmem0.

# Update GRUB and reboot
update-grub                    # Debian/Ubuntu
grub2-mkconfig -o /boot/grub2/grub.cfg   # RHEL/Fedora
reboot

# After reboot, verify
dmesg | grep -i "persistent"
ls /dev/pmem*
# /dev/pmem0    (4 GB)

# Use exactly like real pmem
mkfs.ext4 -b 4096 -E nodiscard /dev/pmem0
mkdir /mnt/pmem
mount -o dax /dev/pmem0 /mnt/pmem

# Verify DAX-mapped pages
df /mnt/pmem
# Filesystem     Size  Used Avail Use% Mounted on
# /dev/pmem0     3.9G   24K  3.7G   1% /mnt/pmem
```

```
What the emulation provides:
  ✓ Same kernel code paths (DAX, fs/dax.c, mount -o dax)
  ✓ Same userspace API (mmap, MAP_SYNC, etc.)
  ✓ Test that your application code works correctly
  ✓ Test the durability model semantics

What the emulation does NOT provide:
  ✗ Real pmem performance characteristics (RAM is ~3× faster than real Optane)
  ✗ Real durability — it's just RAM; data is lost on power off
  ✗ Real wear behavior — pmem has limited write endurance; RAM doesn't

Use case: development, semantic testing, integration tests.
NOT use case: performance benchmarking pmem-based architectures.
```

---

## 8. Performance Comparison: pmem vs NVMe

```bash
# Setup: comparable test files on pmem (DAX) and NVMe (O_DIRECT)
dd if=/dev/zero of=/mnt/pmem/test.bin  bs=1M count=1024
dd if=/dev/zero of=/mnt/nvme/test.bin  bs=1M count=1024 oflag=direct

# 1. Random 4K READ latency
fio --name=pmem-r --filename=/mnt/pmem/test.bin --rw=randread --bs=4k \
    --ioengine=mmap --iodepth=1 --time_based --runtime=10
# Pmem latency: typically <1 µs (CPU load — no I/O syscall)

fio --name=nvme-r --filename=/mnt/nvme/test.bin --rw=randread --bs=4k \
    --ioengine=libaio --iodepth=1 --direct=1 --time_based --runtime=10
# NVMe latency: typically 50-100 µs

# 2. Durability: 4K WRITE + flush
# Pmem: store + clwb + sfence — ~300-500 ns total
# NVMe: write + fsync — ~50-100 µs total (FLUSH command + ACK)
# Ratio: pmem is ~100-200× faster for synchronous durable writes

# 3. Sustained throughput
# Pmem: limited by memory controller bandwidth (~6-8 GB/s per channel)
# NVMe: 3.5-7 GB/s for top-tier drives
# Note: pmem throughput is similar but latency is the architectural win
```

**The architectural takeaway:** pmem is not "faster NVMe." It's a
different tier with different access patterns. Its value is in the
sub-microsecond synchronous durability — for workloads that need fast
small synchronous writes (database WAL, distributed system commit
logs), it's transformative. For bulk throughput, NVMe is competitive.

---

## 9. Tiering Implications: bcache and dm-cache Cannot Cache Pmem

This is a critical architectural constraint:

```
bcache and dm-cache sit in the block layer.
They intercept bio submissions: cache hits return from the cache device,
misses go to the backing device.

DAX bypasses the block layer entirely.
mmap'd reads/writes on pmem do not generate bios.
They are CPU load/store instructions through the page table.

Therefore: bcache/dm-cache CANNOT cache pmem.
  - Even if you put a bcache device on top of a pmem namespace,
    DAX-mounted access skips bcache entirely.
  - bcache would only see non-DAX (page-cached) access patterns,
    which defeats the point of using pmem.

Architect implication:
  Pmem tiering must be done at the application layer.
  PMDK (libpmem, libpmemobj) provides primitives for this:
    - Manual placement: small/hot data on pmem, bulk on NVMe
    - Application controls migration between tiers
  
  Or: filesystem-level tiering with explicit copy operations.
  But NOT: transparent block-layer caching like bcache/dm-cache.
```

---

## 10. When pmem Is the Right Architectural Choice

**Use pmem when:**

```
Synchronous durability latency matters:
  Database WAL: every commit must be durable; pmem fsync ~500 ns vs
                NVMe fsync ~50 µs → 100× transaction commit rate at QD=1
  
  Distributed consensus (Raft, Paxos): every log append synchronous;
                                       same latency win
  
  In-memory database snapshots: occasional checkpoints to durable storage
                                without flushing to disk

Memory-mapped data structures persist across process restart:
  Index structures (B-trees, hash tables) built in pmem,
  rebuilt across crashes without serialize/deserialize
  
  Use PMDK's libpmemobj for transactional updates with crash consistency

Very low latency, modest size:
  Pmem capacities are typically smaller than NVMe (per dollar)
  Best for hot, small, latency-critical datasets
```

**Don't use pmem when:**

```
Bulk storage with high throughput:
  NVMe matches or exceeds pmem on sequential bandwidth
  Pmem capacity per dollar is much worse

Random read-heavy with no synchronous writes:
  Page cache + NVMe is plenty fast for this pattern

Workload is fundamentally throughput-bound:
  Pmem's latency advantage doesn't help

Application can't be modified to use pmem APIs:
  Transparent use (without modifying app) gets you DAX-mounted file I/O
  which is faster than NVMe but doesn't realize the full pmem advantage
```

---

## 11. Source Reading Checklist

```
fs/dax.c                — DAX page fault path, dax_iomap_fault()
include/linux/dax.h     — DAX interface
fs/ext4/inode.c         — ext4_dax_aops, DAX address-space operations
fs/xfs/xfs_aops.c       — XFS DAX integration
drivers/nvdimm/*        — pmem device driver
drivers/dax/*           — DAX subsystem core
arch/x86/include/asm/special_insns.h  — clwb, clflushopt, sfence definitions
```

Reading order: `dax.h` (interfaces), then `dax.c` `dax_iomap_fault()`
(the page fault path that inserts pmem PFNs into page tables — this is
where the "bypass everything" magic happens). After that, look at how
ext4 or XFS wires up DAX in their `address_space_operations`.

---

## 12. Self-Check Questions

1. What two kernel layers does DAX bypass, and what is the practical consequence for I/O performance?
2. After a `memcpy()` to a DAX-mapped pmem region, is the data durable? What additional steps are required and why?
3. What is `MAP_SYNC` and what failure mode does it prevent?
4. A customer has Optane DCPMM and wants to "just put bcache on it" to cache an NVMe device. Why is this wrong?
5. You have no real pmem hardware. How would you set up a development environment to write and test pmem-aware code? What are the limits of this approach?
6. A database transactional workload commits 10,000 small transactions per second, each calling fsync. The bottleneck is fsync latency. The team is debating: faster NVMe or add pmem? Recommend, with reasoning.
7. Why is `cat /sys/bus/nd/devices/region0/persistence_domain` worth checking before deploying pmem?

## 13. Answers

1. DAX bypasses both the page cache AND the block layer (blk-mq). On a DAX-mounted file, `mmap()` inserts pmem hardware PFNs directly into the process page tables; subsequent loads and stores reach pmem via the CPU's memory subsystem with no kernel involvement. Consequences: zero copy between pmem and process memory; no DMA; sub-microsecond access times; no bio submissions visible to dm-* or other block-layer features.
2. No, not yet. `memcpy()` writes pass through the CPU cache hierarchy. The data may sit in L1/L2/L3 caches and not have reached pmem. Without explicit flush, a power loss before cache eviction loses the data. Required steps: `clwb` for each touched cache line (flushes the line to memory while keeping it in cache as clean) followed by `sfence` to order the flushes against subsequent operations. On eADR-capable platforms (CPU caches covered by power hold-up), `clwb` is unnecessary — only `sfence` for ordering — but this depends on hardware capability, not OS.
3. `MAP_SYNC` (used with `MAP_SHARED` on DAX-mounted files) makes filesystem metadata updates synchronous during page faults. When a fault allocates a new extent or grows the file, the kernel persists the metadata change before returning from the fault. Without `MAP_SYNC`, the application could write durable data to a location whose metadata pointer is not yet persisted — after a crash, the data survives but the file's view of it might not. `MAP_SYNC` closes this window for pure mmap-based pmem workloads that never call `fsync()`.
4. bcache (and dm-cache) sit in the block layer. They intercept bios. DAX bypasses the block layer — pmem access goes directly through page tables via CPU load/store, generating no bios at all. So a DAX-mounted pmem device sees zero traffic through bcache. The bcache device would only see non-DAX accesses (which defeats the purpose of having pmem). Pmem tiering must be done at the application layer (PMDK) or via explicit filesystem-level data movement, not via transparent block-layer caching.
5. Use `memmap=NG!OG` kernel cmdline parameter (e.g., `memmap=4G!12G`) to reserve 4 GB of RAM starting at offset 12 GB and expose it as `/dev/pmem0`. Format and DAX-mount as if it were real pmem (`mkfs.ext4 -b 4096 -E nodiscard /dev/pmem0; mount -o dax /dev/pmem0 /mnt/pmem`). Limits: it's just RAM, so data is lost on power off — not actually persistent; performance characteristics differ (RAM is ~3× faster than Optane); no real wear behavior. Good for code correctness and semantic testing, NOT for performance benchmarking.
6. **Add pmem.** The bottleneck is synchronous durability latency (each fsync). NVMe fsync is hardware-bound at ~50-100 µs minimum (FLUSH command round-trip). Even a faster NVMe still has this ~50 µs floor; you can't beat the protocol. Pmem with proper durability (clwb + sfence) commits in ~500 ns — about 100× faster. At 10,000 TPS the database is doing 10,000 fsyncs/sec; if each is ~50 µs that's 50% of a CPU and a low ceiling on TPS scaling. Move the WAL to pmem with PMDK and the workload can scale much further. NVMe upgrades give incremental improvement; pmem gives architectural step-change.
7. It tells you whether the platform has full ADR or eADR. `memory_controller` (ADR) means cache lines are NOT covered by power hold-up — software must explicitly `clwb` to push from CPU cache to memory controller for durability. `cpu_cache` (eADR) means cache lines ARE covered — software needs only `sfence` for ordering, no `clwb` required. Software written assuming the wrong domain either does unnecessary work (slower) or fails to persist data (data loss on crash). PMDK auto-detects this, but understanding which is which lets you reason about performance and verify configuration.

---

## Tomorrow: Day 28 — cgroup I/O: io.max, io.weight & io.latency

We close Week 4 with the three cgroup v2 I/O enforcement mechanisms,
their distinct kernel paths (`blk-throttle`, BFQ, `blk-iolatency`), and
when to use each. This bridges to Day 29 — Full-Stack Performance Tuning Lab.
