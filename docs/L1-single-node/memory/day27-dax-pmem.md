# Day 27: DAX & PMEM — Memory-Mapped Persistent Storage

## Learning Objectives
- Understand DAX: filesystem direct access bypassing page cache
- Trace the DAX fault path vs regular file fault path
- Understand FSDAX vs DEVDAX modes
- Know MAP_SYNC and crash consistency guarantees
- Benchmark DAX vs page cache for storage latency

---

## 1. Why DAX Exists

Standard storage path (NVMe, page cache):
```
CPU LOAD → page cache → [if miss] → block layer → NVMe → 4-10μs
```

DAX path (PMEM):
```
CPU LOAD → PMEM physical address → 200-400ns
```

DAX eliminates: page cache allocation, bio submission, block layer, interrupt handling. The CPU accesses persistent memory directly via LOAD/STORE, same as DRAM but persistent.

---

## 2. PMEM Modes

### FSDAX: Filesystem DAX
Filesystem (ext4/XFS) mounted with `dax=always` option:
- Regular file API (`open()`, `mmap()`, `read()`/`write()`)
- Internally bypasses page cache
- `mmap()` maps directly to PMEM physical addresses

### DEVDAX: Raw Device DAX
Raw `/dev/daxN.M` device:
- Only `open()` + `mmap()` — no read/write
- Application manages all addressing
- Used by databases (Oracle, SAP HANA) for direct PMEM management
- Used by PMDK (Persistent Memory Development Kit)

```bash
# Configure PMEM namespace:
ndctl create-namespace --mode=fsdax --size=32G --name=fsdax0
# → creates /dev/pmem0 (block device, DAX-capable)

ndctl create-namespace --mode=devdax --size=32G --name=devdax0
# → creates /dev/dax0.0 (char device, mmap-only)

# List namespaces:
ndctl list -N
```

---

## 3. The DAX Fault Path

```c
// fs/dax.c
vm_fault_t dax_iomap_fault(struct vm_fault *vmf, enum page_entry_size pe_size,
                             pfn_t *pfnp, int *iomap_errp,
                             const struct iomap_ops *ops)
{
    // Get the file offset:
    pgoff_t pgoff = vmf->pgoff;

    // Ask filesystem where this file offset maps to on PMEM:
    // (no block layer; filesystem gives direct PMEM physical address)
    error = ops->iomap_begin(inode, pos, length, 0, &iomap, &srcmap);
    // iomap.addr = physical address on PMEM

    // Map PMEM physical address directly into process page table:
    // Unlike regular fault: no struct page, no buddy allocator
    pfn = phys_to_pfn_t(iomap.addr + offset, PFN_DEV | PFN_MAP);
    ret = vmf_insert_pfn_prot(vmf->vma, vmf->address,
                               pfn_t_to_pfn(pfn), vmf->vma->vm_page_prot);
    // → PTE now maps directly to PMEM physical page
    // → CPU load/store goes directly to PMEM — no copy, no bounce buffer
}
```

Key difference from `filemap_fault()`:
- No `folio` allocated from buddy
- No bio submitted to block layer
- No interrupt on completion
- Fault completes in ~1μs instead of ~10μs (NVMe)

---

## 4. MAP_SYNC and Persistence

```c
// MAP_SYNC: writes are durably committed (reach PMEM) before write() returns
void *addr = mmap(NULL, size,
                   PROT_READ | PROT_WRITE,
                   MAP_SHARED | MAP_SYNC,  // ← key flag
                   fd, 0);

addr[0] = 'X';   // CPU writes to PMEM
// With MAP_SYNC: write is synchronous to persistent media
// Without MAP_SYNC: write may be in CPU cache (not yet in PMEM)
```

### Persistence Guarantees

| Method | Durable after |
|--------|--------------|
| `write()` on regular file | `fsync()` + `fdatasync()` |
| `mmap()` on regular file | `msync(MS_SYNC)` |
| DAX `mmap()` without MAP_SYNC | `clflushopt + sfence` or `msync()` |
| DAX `mmap()` with MAP_SYNC | After the store instruction (guaranteed on ADR-capable PMEM) |

```c
// Explicit cache flush for DAX (when not using MAP_SYNC):
// ADR (Asynchronous DRAM Refresh) ensures data in memory controller
// reaches PMEM on power loss.
// clflushopt + sfence: ensure data leaves CPU cache → memory controller:

#include <immintrin.h>
void persist_range(void *addr, size_t len) {
    for (size_t i = 0; i < len; i += 64) {
        _mm_clflushopt((char *)addr + i);  // flush cache line
    }
    _mm_sfence();  // store fence: all flushes complete
}
```

---

## 5. Setting Up DAX (Emulation in VM)

For development without real PMEM hardware:

```bash
# Method 1: kernel boot param for RAM-backed PMEM emulation
# Add to GRUB: memmap=4G!12G
# This reserves 4GB starting at 12GB as "persistent memory"
# After reboot:
ls /dev/pmem*          # shows /dev/pmem0 if successful
ndctl list             # shows the namespace

# Method 2: on VMs with qemu-nvdimm:
# qemu adds: -machine pc,nvdimm=on -m 8G,slots=2,maxmem=16G
#            -object memory-backend-file,id=mem1,share=on,mem-path=/tmp/nvdimm,size=4G
#            -device nvdimm,id=nvdimm1,memdev=mem1

# Create FSDAX filesystem:
ndctl create-namespace --mode=fsdax --size=4G 2>/dev/null || true
mkfs.ext4 /dev/pmem0 2>/dev/null
mount -o dax /dev/pmem0 /mnt/pmem 2>/dev/null

# Verify DAX mount:
mount | grep dax
# /dev/pmem0 on /mnt/pmem type ext4 (rw,dax)
```

---

## 6. Hands-On Exercises

```bash
# --- Latency comparison: page cache vs DAX ---
# (requires PMEM or emulation; otherwise compare O_DIRECT vs mmap)

# Benchmark page cache mmap:
fio --name=page_cache \
    --filename=/tmp/test.dat \
    --rw=randread --bs=4k \
    --direct=0 --ioengine=mmap \
    --size=1G --runtime=30 \
    --percentile_list=50,99,99.9

# Benchmark DAX mmap (if available):
fio --name=dax_test \
    --filename=/mnt/pmem/test.dat \
    --rw=randread --bs=4k \
    --direct=0 --ioengine=mmap \
    --size=1G --runtime=30 \
    --percentile_list=50,99,99.9
# Expected: 10-50× lower latency with real PMEM

# --- Trace DAX fault vs regular fault ---
bpftrace -e '
kprobe:dax_iomap_fault { @dax_faults = count(); }
kprobe:filemap_fault   { @cache_faults = count(); }
interval:s:5 {
    printf("DAX faults: %d, Cache faults: %d\n",
           @dax_faults, @cache_faults);
    clear(@dax_faults); clear(@cache_faults);
}
'

# --- Verify DAX is active for a file ---
# statx with STATX_ATTR_DAX:
python3 -c "
import os
try:
    result = os.stat('/mnt/pmem/test.dat')
    print('File stat OK')
    # Check DAX attribute via xfs_io or ndctl
except:
    print('PMEM not available on this system')
"

# Check via xfs_io (if xfsprogs installed):
xfs_io -c 'statx -r' /mnt/pmem/test.dat 2>/dev/null | grep -i dax
```

---

## 7. Storage Architecture Connections

| Scenario | DAX involvement |
|----------|----------------|
| PMEM as NVMe cache tier | DEVDAX gives app direct PMEM access; faster than block layer cache |
| Database WAL on PMEM | FSDAX + MAP_SYNC: durability without fsync overhead |
| In-memory database persistence | DEVDAX: PMDK's libpmemobj manages persistence transparently |
| Storage class memory tiering | DAX for hot data; NVMe for warm; HDD for cold |
| Ceph OSD journal on PMEM | FSDAX provides ~300ns write latency vs 50μs on NVMe |

---

## 8. Key Source Files

```
fs/dax.c                — dax_iomap_fault(), dax_direct_access()
drivers/nvdimm/         — NVDIMM/PMEM driver
fs/ext4/inode.c         — ext4_dax_fault() → calls dax_iomap_fault()
fs/xfs/xfs_file.c       — xfs_dax_fault()
include/linux/dax.h     — DAX API
include/linux/libnvdimm.h — PMEM device interface
```

---

## 9. Self-Check Questions

1. An application writes to a DAX-mmap'd file without MAP_SYNC. Power fails immediately after the write. Is the data in the file? What determines this? What instruction would guarantee durability?

2. DAX fault completes in ~1μs vs NVMe read in ~10μs. But the application doing sequential reads sees similar throughput. Why? (Hint: read-ahead)

3. A filesystem is mounted with `dax=inode` (per-inode DAX mode). File A has the DAX flag set; file B does not. What happens when both are mmap'd? Which fault handler is called for each?

4. DEVDAX provides a raw `/dev/dax0.0` device. A process `mmap()`s it and writes data. Is the data visible to another process that opens the same device? Is it persistent?

5. Ceph OSD wants to use PMEM for its BlueStore WAL. Should it use FSDAX or DEVDAX? What are the tradeoffs? What persistence guarantees does each provide?

---

## Tomorrow: Day 28 — userfaultfd & Memory Hot-plug
