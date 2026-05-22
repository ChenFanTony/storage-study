# Day 14: Week 2 Review — Virtual Memory Connective Tissue

## Learning Objectives
- Synthesize Days 8–13 into a single end-to-end mental model
- Trace a file `mmap()` access from userspace instruction to physical page
- Trace an NVMe I/O from DMA buffer setup to completion
- Build your virtual memory reference card
- Identify gaps before Week 3 (page cache + reclaim)

---

## 1. The Complete mmap File Access Trace

Trace: Process does `mmap(file)`, then reads byte 0. Follow every step:

```
Step 1: mmap() syscall
──────────────────────
mmap(NULL, file_size, PROT_READ, MAP_SHARED, fd, 0)
  → sys_mmap_pgoff()
  → do_mmap()
    → get_unmapped_area()  →  picks VA = 0x7f8000000000
    → mmap_region()
      → vm_area_alloc()   →  slab allocates struct vm_area_struct
      → vma->vm_start     =  0x7f8000000000
      → vma->vm_end       =  0x7f8000000000 + file_size
      → vma->vm_file      =  file
      → vma->vm_flags     =  VM_READ | VM_SHARED
      → file->f_op->mmap(file, vma)
          (ext4): vma->vm_ops = &ext4_file_vm_ops
      → vma_link(mm, vma) →  insert into mm->mm_mt (maple tree)
  → return 0x7f8000000000
  ── RETURNS IMMEDIATELY. No pages. No I/O. ──

Step 2: Process reads address 0x7f8000000000
─────────────────────────────────────────────
CPU: loads from 0x7f8000000000
  → TLB lookup: MISS (no PTE yet)
  → CPU walks page tables: PGD → PUD → PMD → PTE
  → PTE not present (_PAGE_PRESENT = 0)
  → CPU raises #PF exception

Step 3: Page fault handler
───────────────────────────
do_page_fault() [arch/x86/mm/fault.c]
  → handle_mm_fault(vma, 0x7f8000000000, FAULT_FLAG_USER)
  → __handle_mm_fault()
    → [check PMD: not present] → alloc PMD page (kmalloc GFP_PGTABLE_USER)
    → handle_pte_fault(vmf)
      → do_fault(vmf)  ← file-backed fault
        → do_read_fault(vmf)
          → vma->vm_ops->fault(vmf)
              ↓
          filemap_fault(vmf)  [mm/filemap.c]
            → filemap_get_folio(mapping, pgoff=0)
              → [page not in cache] → MAJOR FAULT
            → folio = filemap_alloc_folio(GFP_HIGHUSER_MOVABLE, 0)
              ← allocates physical page from buddy
            → filemap_add_folio(mapping, folio, 0)
              ← adds to address_space xarray at index 0
            → mapping->a_ops->read_folio(file, folio)
              ← ext4 submits bio → block layer → NVMe → disk
              ← process sleeps (TASK_UNINTERRUPTIBLE)
              ← wakes when I/O completes
        → vmf->page = folio_file_page(folio, 0)
      → [set PTE]: entry = mk_pte(page, vma->vm_page_prot)
                   set_pte_at(mm, addr, pte, entry)
      → [TLB]:    update_mmu_cache() → flush/fill TLB entry

Step 4: Return from fault
──────────────────────────
  → CPU retries the load instruction
  → TLB hit (or page walk hits valid PTE)
  → Physical page data returned to register
  → Process continues

Total time: ~10ms (NVMe random read) for major fault
            ~1μs  for minor fault (page already in cache)
```

---

## 2. The Complete NVMe I/O DMA Trace

Trace: NVMe driver submits a 4KB read I/O and receives completion.

```
Setup (once at driver probe):
──────────────────────────────
ioremap(pci_bar_phys, bar_len)  →  dev->bar (kernel VA for NVMe registers)
dma_alloc_coherent(sq_size)     →  nvmeq->sq_cmds (CPU VA + DMA addr for SQ)
dma_alloc_coherent(cq_size)     →  nvmeq->cqes   (CPU VA + DMA addr for CQ)
writel(sq_dma_addr, dev->bar + NVME_REG_ASQ)  →  tell NVMe where SQ is
writel(cq_dma_addr, dev->bar + NVME_REG_ACQ)  →  tell NVMe where CQ is

I/O Submission:
───────────────
bio_alloc_bioset(GFP_NOIO, ...)   →  struct bio (from mempool — cannot fail)
  → bio->bi_io_vec                →  page pointers for data
dma_map_sg(dev, sg, nents, DMA_FROM_DEVICE)
  → returns DMA addresses for each scatter-gather entry
  → IOMMU: maps IOVA → physical pages in IOMMU page table
nvme_setup_cmd()                   →  fill NVMe command in sq_cmds[]
  → cmd.prp1 = sg_dma_address(sg) →  data buffer DMA address
writel(new_tail, dev->bar + NVME_REG_DBS + doorbell_offset)
  ← CPU writes to NVMe doorbell register via ioremap'd BAR
  ← NVMe controller sees new SQ tail, fetches command via DMA from sq_cmds[]

I/O Completion:
───────────────
  ← NVMe DMA's data into the registered sg pages
  ← NVMe writes completion entry to cqes[] via DMA
  ← NVMe raises MSI-X interrupt
nvme_irq() [hardirq]:
  → read cqes[cq_head] (via DMA coherent memory — always CPU-visible)
  → parse status
  → complete request
dma_unmap_sg(dev, sg, nents, DMA_FROM_DEVICE)
  → IOMMU: unmaps IOVA entries
  → CPU cache: ensures CPU sees device-written data
bio_endio(bio)
  → page cache: mark folio uptodate
  → wake up sleeping process (from filemap_fault step above)
```

---

## 3. Virtual Memory Reference Card

### VMA Flag Quick Reference
| Flag | Meaning | Set by |
|------|---------|--------|
| VM_READ/WRITE/EXEC | Permissions | mmap prot |
| VM_SHARED | MAP_SHARED | mmap flags |
| VM_LOCKED | mlock'd pages | mlock() |
| VM_HUGETLB | Backed by HugeTLB | MAP_HUGETLB |
| VM_HUGEPAGE | THP eligible | default or madvise |
| VM_NOHUGEPAGE | THP disabled | madvise MADV_NOHUGEPAGE |
| VM_MIXEDMAP | DAX mapping | DAX filesystem |
| VM_PFNMAP | Raw device memory | driver mmap |
| VM_IO | MMIO region | driver mmap |
| VM_GROWSDOWN | Stack | exec setup |

### Fault Type Decision Tree
```
Page fault at address X
  │
  ├─ PTE present but protection fault?
  │   └─ Write to MAP_PRIVATE: do_wp_page() → COW → minor fault
  │
  └─ PTE not present:
      ├─ VMA is anonymous (vm_file == NULL)?
      │   └─ do_anonymous_page() → zero page or alloc → minor fault
      │
      ├─ VMA is file-backed?
      │   ├─ Page in page cache? → minor fault (set PTE, done)
      │   └─ Not in cache?       → major fault (read from disk, sleep)
      │
      └─ VMA is DAX?
          └─ dax_iomap_fault() → map device physical page → minor fault
```

---

## 4. Integration Exercises

### Exercise A: Trace mmap with strace and smaps
```bash
# Run a database that uses mmap (sqlite):
strace -e mmap,mprotect,munmap sqlite3 /tmp/test.db \
    "CREATE TABLE t(x); INSERT INTO t VALUES(1);" 2>&1 | grep mmap

# Inspect sqlite's address space:
PID=$(pidof sqlite3 2>/dev/null || echo $$)
cat /proc/$PID/smaps_rollup
```

### Exercise B: Measure Virtual vs Physical Memory
```bash
python3 << 'EOF'
import mmap, os

# Map 1GB anonymously
buf = bytearray(1024 * 1024 * 1024)  # 1GB — allocated physically
pid = os.getpid()

with open(f'/proc/{pid}/status') as f:
    for line in f:
        if line.startswith(('VmRSS', 'VmSize', 'RssAnon')):
            print(line.strip())

# Now allocate with mmap (lazy):
m = mmap.mmap(-1, 1024*1024*1024)  # 1GB anonymous mmap
print("\nAfter mmap (before access):")
with open(f'/proc/{pid}/status') as f:
    for line in f:
        if line.startswith(('VmRSS', 'VmSize', 'RssAnon')):
            print(line.strip())
# RSS should be unchanged — no pages allocated yet!
EOF
```

### Exercise C: Page Cache Sharing Proof
```bash
# Prove two processes share page cache:
python3 -c "
import mmap, os, time
f = open('/etc/passwd', 'rb')
m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
data = bytes(m)
print('Mapped /etc/passwd, PID:', os.getpid())
time.sleep(30)
" &
PID1=$!

python3 -c "
import mmap, os, time
f = open('/etc/passwd', 'rb')
m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
data = bytes(m)
print('Mapped /etc/passwd, PID:', os.getpid())
time.sleep(30)
" &
PID2=$!

sleep 2
# Inspect smaps: both should show Shared_Clean > 0 for the passwd pages
grep -A10 "passwd" /proc/$PID1/smaps | grep -E "Shared|Private"
grep -A10 "passwd" /proc/$PID2/smaps | grep -E "Shared|Private"
# Shared_Clean should be non-zero: same physical pages

kill $PID1 $PID2 2>/dev/null
```

---

## 5. Self-Check: Week 2 Mastery

Answer without notes:

1. `mmap(file, MAP_SHARED)` returns instantly. The file is 10GB on NVMe. Where is the data? When does it arrive in RAM?

2. Two threads in the same process access the same mmap'd file page simultaneously (first access). How many page faults occur? How does the kernel ensure only one physical page is allocated?

3. After `fork()`, the parent writes to a page that was previously mapped `MAP_PRIVATE`. Draw the PTE state before write, during COW fault, and after COW completes, for both parent and child.

4. Trace `dma_map_sg()` with IOMMU enabled. What kernel data structure is modified? What hardware table is updated? What is the returned `dma_addr_t` relative to?

5. `munmap(addr, 1GB)` on a 64-core server triggers TLB shootdowns on all 64 cores. Calculate the minimum time this takes given: IPI delivery = 1μs, TLB flush = 500ns. Is this visible in p99 latency?

---

## 6. Checklist Before Week 3

- [ ] Can read `/proc/PID/maps` and explain every VMA
- [ ] Can trace `mmap(file)` to first page access step by step
- [ ] Can explain COW with a concrete fork scenario
- [ ] Understand why ioremap is uncached and why that's necessary
- [ ] Understand the DMA mapping lifecycle in NVMe driver
- [ ] Can explain the difference between major and minor faults and their storage impact
- [ ] Understand that `mmap` and `read()` share the page cache

---

## Week 3 Preview: Page Cache, Writeback & Reclaim

Starting Day 15:
- `struct address_space` internals — how pages are indexed and tracked
- Dirty page lifecycle — from `write()` to disk
- `kswapd` and the LRU reclaim algorithm — why memory pressure causes I/O
- OOM killer — when reclaim fails completely

This is the week that explains the storage behavior you've observed for years: the writeback storms, the I/O spikes under memory pressure, the "warm-up" period needed for good benchmark results.
