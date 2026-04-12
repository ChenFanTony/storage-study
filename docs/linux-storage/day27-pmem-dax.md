# Day 27: Persistent Memory / DAX Path

## Learning Objectives
- Understand how DAX bypasses both page cache and block layer
- Follow the DAX fault path in `fs/dax.c`
- Emulate pmem using kernel `memmap` parameter
- Know the tiering implications when pmem is in the stack
- Know DAX's limitations and what software must change to use it correctly

---

## 1. What DAX Bypasses (and Why It Matters)

Normal file I/O path:
```
read() → VFS → page cache (copy) → block layer → device → DMA → page cache → copy to user
```

DAX (Direct Access) path for pmem-backed filesystems:
```
read() → VFS → DAX fault → mmap pmem directly into user address space
      OR: read() → VFS → DAX → copy directly from pmem to user buffer
          (no page cache, no block layer, no DMA)
```

```
What DAX eliminates:
  ✓ Page cache allocation and management
  ✓ Block layer (blk-mq, I/O schedulers)
  ✓ DMA (pmem is CPU-addressable memory — load/store, not DMA)
  ✓ Interrupt handling for completion (no interrupt — synchronous load/store)
  ✓ Extra data copy (pmem is in CPU address space)

What DAX does NOT eliminate:
  ✗ VFS overhead (inode lookup, permission checks)
  ✗ Filesystem metadata operations (extent lookup, etc.)
  ✗ CPU cache line flushes (for durability — clflush/clwb instructions)
  ✗ Memory barriers (for ordering — sfence/mfence)
```

---

## 2. The DAX Fault Path

```c
// fs/dax.c

// When a process mmap()s a file on a DAX filesystem and accesses a page:
// Page fault → dax_fault_actor()

dax_fault_actor(vmf, pfnp):
    // 1. Get the file extent mapping (iomap)
    ops->iomap_begin(inode, pos, length, flags, &iomap, NULL)
    // Returns: iomap.addr = physical address of pmem extent

    // 2. Convert physical address to pfn (page frame number)
    *pfnp = phys_to_pfn_t(iomap.addr + offset)

    // 3. Insert pfn directly into process page table
    vmf_insert_mixed(vmf->vma, vmf->address, *pfnp)
    // Process page table now maps virtual address → pmem physical address
    // Subsequent access: no fault, direct load/store to pmem

// No page cache involvement at any point
// No block I/O at any point
// The process directly accesses pmem via CPU load/store instructions
```

---

## 3. Durability with DAX: CPU Instructions Matter

This is the critical difference from block I/O:

```
Block I/O durability:
  write() → block layer → NVMe FLUSH command → device confirms persistence
  fsync() → flush page cache + NVMe FLUSH → guaranteed durable

DAX durability:
  store instruction → CPU cache (NOT yet in pmem)
  clflushopt/clwb → flush CPU cache line to pmem memory controller
  sfence          → ensure ordering (all prior stores visible)
  
  Without explicit flush: data is in CPU cache, NOT in pmem
  CPU crash / power loss: unflushed cache lines are LOST
```

```c
// Filesystem must explicitly flush pmem after writes:

// Write path in ext4 DAX:
ext4_dax_write_iter():
    // Copy data to pmem (via store instructions)
    dax_copy_from_iter(daxdev, pgoff, iter, bytes)
    // Flush CPU cache to pmem
    dax_flush(daxdev, addr, size)
        → arch_wb_cache_pmem(addr, size)
        → clwb instructions for each cache line
        → sfence to order
```

```bash
# Check if CPU supports pmem-friendly flush instructions
grep -E "clflushopt|clwb|pcommit" /proc/cpuinfo
# clwb (cache line writeback) = optimal for pmem (keeps line in cache)
# clflushopt = flush and invalidate (less optimal but widely supported)
# Both faster than clflush (serializing)
```

---

## 4. Emulating pmem with `memmap` Kernel Parameter

```bash
# Reserve physical RAM to emulate persistent memory
# Add to kernel cmdline (GRUB):
# memmap=4G!12G
# Meaning: reserve 4GB starting at physical address 12GB as "pmem"

# Edit /etc/default/grub:
# GRUB_CMDLINE_LINUX="... memmap=4G!12G"
# update-grub && reboot

# After reboot: pmem device appears
ls /dev/pmem*           # /dev/pmem0
cat /proc/iomem | grep -i "persistent"

# Create DAX filesystem on emulated pmem
mkfs.ext4 -b 4096 -E nodiscard /dev/pmem0
mount -o dax /dev/pmem0 /mnt/pmem   # mount with DAX mode

# Verify DAX is active
mount | grep dax
dmesg | grep -i "dax"
```

---

## 5. Testing DAX vs Block I/O Performance

```bash
# Test 1: DAX read (no page cache, no block layer)
echo "=== DAX read ==="
fio --name=dax-read \
    --filename=/mnt/pmem/testfile \
    --rw=randread --bs=4k \
    --ioengine=psync \
    --size=1G \
    --time_based --runtime=10

# Test 2: Same filesystem without DAX
umount /mnt/pmem
mount /dev/pmem0 /mnt/pmem   # no -o dax

echo "=== Non-DAX read (page cache) ==="
fio --name=nodax-read \
    --filename=/mnt/pmem/testfile \
    --rw=randread --bs=4k \
    --ioengine=psync \
    --size=1G \
    --time_based --runtime=10

# Expected: DAX read is significantly faster for cold access
# (no page cache fill needed — direct access to pmem)
# Warm cache: non-DAX may be comparable (page cache = DRAM = similar speed)

# Test 3: mmap with DAX (true zero-copy)
# Application mmaps file → directly accesses pmem
# No syscall overhead per access after initial fault
```

---

## 6. DAX and Tiering Architecture Implications

This is the key architect concern when pmem is in the stack:

```
Traditional tiering (without pmem):
  CPU → DRAM (page cache) → NVMe SSD → HDD
  I/O path: block layer, DMA, interrupts

Tiering with pmem:
  CPU → pmem (via load/store, DAX) → NVMe SSD → HDD
  pmem is NOT a block device from application's perspective
  pmem IS in the CPU address space

Implications:

1. bcache/dm-cache cannot cache pmem
   bcache/dm-cache sit in the block layer — DAX bypasses the block layer
   A file on a DAX-mounted pmem filesystem never goes through bcache

2. Page cache is bypassed for DAX reads
   Normal page cache tiering (kernel manages hot data in DRAM) does NOT apply
   to DAX files. The application accesses pmem directly.

3. pmem IS the fast tier
   pmem's role in a tiered architecture: fastest persistent tier
   Data on pmem: accessed at memory speeds (100-300ns latency)
   Data on NVMe: accessed at NVMe speeds (50-100µs latency)
   1000× latency difference — pmem is a fundamentally different tier

4. Moving data between tiers is the application's job
   No automatic block-level tiering works for pmem
   Application (or filesystem) must explicitly move hot data to pmem
   and cold data to NVMe
```

---

## 7. Software That Uses DAX Correctly

```
Direct database use (most common):
  Database opens pmem file with mmap() + MAP_SYNC flag
  Stores hot index structures, transaction logs in pmem
  Uses clwb+sfence for durability (not fsync — too slow)
  Examples: Intel PMDK libraries, pmemkv, Redis with pmem backend

Filesystem tiering (less common, future direction):
  XFS/ext4 with -o dax for pmem-resident hot data
  Separate filesystem on NVMe for cold data
  Application or tiering daemon moves data between tiers

NVDIMM as journal/WAL:
  Database stores WAL on pmem (DAX mode)
  WAL writes: clwb+sfence (µs latency vs NVMe's ~50µs)
  Dramatically reduces transaction commit latency
  Main data stays on NVMe (capacity)
```

---

## 8. DAX Limitations Architects Must Know

```
No page cache for DAX files:
  - Cannot use madvise(MADV_DONTNEED) to free pages (no pages to free)
  - Memory pressure cannot reclaim DAX-mapped pages
  - Process holds pmem mapped until explicitly unmapped

Write ordering complexity:
  - Compiler may reorder stores to pmem
  - Must use PMDK or careful use of barriers and flush instructions
  - Easy to introduce correctness bugs (unflushed dirty data on crash)

Capacity limits:
  - pmem is expensive ($10-30/GB vs $0.10/GB for HDD)
  - Use for hot data only; not a replacement for NVMe storage

No transparent compression:
  - Block-layer compression (dm-compress) bypassed by DAX
  - What you store is what's on the device, byte for byte
```

---

## 9. Self-Check Questions

1. What two layers does DAX bypass that normal block I/O goes through?
2. Why must applications explicitly flush CPU cache lines when writing to pmem via DAX?
3. Can bcache or dm-cache cache data from a DAX-mounted pmem filesystem? Why not?
4. What is the `memmap` kernel parameter used for in the context of DAX testing?
5. An application wants sub-microsecond write durability for a transaction log. How does pmem + DAX achieve this vs NVMe + fsync?
6. What flag must be passed to `mmap()` to ensure DAX writes are persistent without explicit clwb instructions?

## 10. Answers

1. DAX bypasses the page cache (no kernel buffer allocation, no writeback) and the block layer (no blk-mq, no I/O scheduler, no DMA). Data is accessed via CPU load/store instructions directly to/from the persistent memory's physical address.
2. CPU store instructions go to the CPU cache, not directly to pmem. The CPU cache is volatile — power loss loses unflushed cache lines. To make writes durable, the application must explicitly execute `clwb` (cache line writeback) or `clflushopt` followed by `sfence` to flush data from CPU cache to the memory controller, which writes to persistent NVDIMM media.
3. No. bcache and dm-cache are block layer constructs — they intercept bio requests in blk-mq. DAX completely bypasses the block layer; accesses go directly from CPU to pmem via load/store. There are no bio requests for block-level caching to intercept.
4. `memmap=NGB!startGB` reserves a contiguous region of physical RAM and marks it as "persistent memory" — the kernel creates a `/dev/pmem` device backed by that RAM region. This allows testing DAX-capable filesystems and pmem-aware applications without actual NVDIMM hardware.
5. NVMe + fsync path: write to page cache → writeback → NVMe SSD → FLUSH command → device confirms persist (~50-100µs minimum). pmem + DAX path: store to pmem-mapped address → clwb instruction → sfence → done. The clwb+sfence path takes ~300-500ns — 100-200× faster than NVMe fsync. The key is that pmem is byte-addressable persistent memory in the CPU address space.
6. `MAP_SYNC | MAP_SHARED` — with `MAP_SYNC`, the kernel ensures that writes to the mapping are immediately durable (synchronous to pmem). Under the hood, the filesystem uses this flag to issue clwb+sfence automatically on each page fault and dirty page. Without `MAP_SYNC`, the application must explicitly call `msync()` or use PMDK's persistence functions.

---

## Tomorrow: Day 28 — cgroup I/O: Weight, Throttle & Latency Target

We go deep on blk-cgroup, blk-throttle, and blk-iolatency — the three
mechanisms for multi-tenant I/O isolation and how they interact with blk-mq
under saturation.
