# Day 10: Page Faults — Demand Paging & COW

## Learning Objectives
- Trace the page fault handler from CPU exception to resolved page
- Distinguish minor faults, major faults, and COW faults
- Understand anonymous page allocation vs file page fault paths
- Connect major faults to storage I/O in your benchmarks

---

## 1. The Fault Handler Call Chain

A page fault happens when the CPU tries to access a virtual address with no valid PTE (or a protection violation). The CPU raises a #PF exception.

```
CPU: page fault exception (#PF)
    │
    └─ do_page_fault()          [arch/x86/mm/fault.c]
         │
         ├─ [kernel fault]: oops or vmalloc fault → handle separately
         │
         └─ [user fault]:
              │
              └─ handle_mm_fault(vma, address, flags, regs)   [mm/memory.c]
                   │
                   ├─ hugetlb_fault()     ← if huge page VMA
                   │
                   └─ __handle_mm_fault(vma, address, flags)
                        │
                        ├─ [PGD/P4D/PUD/PMD not present]: allocate page table pages
                        │
                        └─ handle_pte_fault(vmf)
                             │
                             ├─ [PTE not present, anonymous VMA]:
                             │   do_anonymous_page(vmf)
                             │     → alloc_zeroed_user_highpage_movable()
                             │     → set PTE → return VM_FAULT_MINOR
                             │
                             ├─ [PTE not present, file VMA]:
                             │   do_fault(vmf)
                             │     → do_read_fault() or do_cow_fault() or do_shared_fault()
                             │     → vma->vm_ops->fault(vmf)   ← filesystem handler
                             │     → filemap_fault() → page cache lookup/read
                             │     → may return VM_FAULT_MAJOR (disk I/O needed)
                             │
                             └─ [PTE present but write-protected, MAP_PRIVATE]:
                                 do_wp_page(vmf)   ← COW
                                   → alloc new page
                                   → copy content
                                   → update PTE to new writable page
                                   → return VM_FAULT_MINOR
```

---

## 2. Fault Types

### Minor Fault (VM_FAULT_MINOR)
Page is already in memory; just need to fill in the PTE.
- Anonymous zero page on first access
- COW copy of an already-resident page
- Shared page already in page cache (another process already faulted it in)

**Cost:** microseconds. No I/O. Just PTE setup + TLB shootdown.

### Major Fault (VM_FAULT_MAJOR)  
Data must be read from disk.
- File-backed page not in page cache
- Swapped-out page

**Cost:** milliseconds (depends on storage latency). Calls into block layer. Process sleeps waiting for I/O.

```bash
# Count major faults — each one = storage I/O:
cat /proc/$pid/stat | awk '{print "minor:", $10, "major:", $12}'

# Rate of major faults per second:
bpftrace -e '
software:major-faults:1 { @[comm] = count(); }
interval:s:1 { print(@); clear(@); }
'
```

### COW Fault (Copy-on-Write)
Triggered when a process writes to a MAP_PRIVATE page that's shared (e.g., after fork, or a read-only file mapping with MAP_PRIVATE).

```c
// mm/memory.c
static vm_fault_t do_wp_page(struct vm_fault *vmf)
{
    // The PTE exists but is write-protected
    // Fault is because process tried to write

    if (reuse_swap_page(page)) {
        // Only reference: just make writable, no copy needed
        wp_page_reuse(vmf);
        return VM_FAULT_WRITE;
    }

    // Allocate new page:
    new_page = alloc_page_vma(GFP_HIGHUSER_MOVABLE, vma, address);
    // Copy content:
    copy_user_highpage(new_page, old_page, address, vma);
    // Update PTE to point to new writable page:
    entry = mk_pte(new_page, vma->vm_page_prot);
    set_pte_at(mm, address, vmf->pte, entry);
    // Optionally unmap old page from this PTE
}
```

---

## 3. do_anonymous_page: Zero Page Optimization

On the very first write to a fresh anonymous mapping:
```c
static vm_fault_t do_anonymous_page(struct vm_fault *vmf)
{
    // Read access? Map the shared zero page (no allocation):
    if (!(vmf->flags & FAULT_FLAG_WRITE)) {
        entry = pte_mkspecial(pfn_pte(my_zero_pfn(vmf->address), vma->vm_page_prot));
        set_pte_at(mm, vmf->address, vmf->pte, entry);
        return VM_FAULT_MINOR;
        // No page allocated! Zero page is shared kernel page.
    }

    // Write access: must allocate real page:
    page = alloc_zeroed_user_highpage_movable(vma, vmf->address);
    // GFP_HIGHUSER_MOVABLE: movable (can be migrated), user memory
    entry = mk_pte(page, vma->vm_page_prot);
    entry = pte_sw_mkyoung(entry);
    entry = maybe_mkwrite(pte_mkdirty(entry), vma);
    set_pte_at(mm, vmf->address, vmf->pte, entry);
    return VM_FAULT_MINOR;
}
```

**The zero page trick:** Reading a fresh anonymous page never allocates physical memory — all reads see the shared zero page. Only writes allocate. `malloc(1GB); memset(buf, 0, 1GB)` allocates pages. `malloc(1GB)` without writing = no pages allocated. RSS stays near zero.

---

## 4. filemap_fault: The File Page Path

```c
// mm/filemap.c
vm_fault_t filemap_fault(struct vm_fault *vmf)
{
    struct file *file = vma->vm_file;
    struct address_space *mapping = file->f_mapping;
    pgoff_t offset = vmf->pgoff;

    // Look up page in page cache:
    folio = filemap_get_folio(mapping, offset);

    if (!folio) {
        // Page not in cache: must read from disk
        // This is a MAJOR FAULT
        error = filemap_read_folio(file, mapping->a_ops->read_folio, folio);
        // → calls into filesystem → block layer → disk I/O
        vmf->flags |= FAULT_FLAG_TRIED;
        return VM_FAULT_MAJOR | VM_FAULT_LOCKED;
    }

    // Page in cache (minor fault):
    // Map page into process page table:
    vmf->page = folio_file_page(folio, offset);
    return VM_FAULT_LOCKED;
    // caller will set PTE
}
```

---

## 5. Hands-On Exercises

```bash
# --- Observe fault types during file access ---

# Create test file:
dd if=/dev/urandom of=/tmp/fault_test bs=1M count=100

# Drop caches (force major faults):
echo 3 > /proc/sys/vm/drop_caches

# Trace faults while reading the file:
bpftrace -e '
software:page-faults:1    { @minor[comm] = count(); }
software:major-faults:1   { @major[comm] = count(); }
interval:s:1 {
    printf("minor: "); print(@minor);
    printf("major: "); print(@major);
    clear(@minor); clear(@major);
}
' &
BPID=$!

# Access the file (triggers major faults first time, minor after cache warm):
cat /tmp/fault_test > /dev/null
sleep 2

# Access again (should be ALL minor faults now — page cache warm):
cat /tmp/fault_test > /dev/null
sleep 2
kill $BPID

# --- Observe COW after fork ---
python3 << 'EOF'
import os, mmap

# Allocate 100MB anonymous
data = bytearray(100 * 1024 * 1024)

pid = os.fork()
if pid == 0:
    # Child: check RSS before write
    with open(f'/proc/{os.getpid()}/status') as f:
        for line in f:
            if 'VmRSS' in line:
                print(f"Child before write: {line.strip()}")

    # Write triggers COW on every page:
    data[0] = 1
    data[4096] = 1  # another page

    with open(f'/proc/{os.getpid()}/status') as f:
        for line in f:
            if 'VmRSS' in line:
                print(f"Child after write: {line.strip()}")
    os._exit(0)
else:
    os.wait()
EOF

# --- Fault latency distribution ---
bpftrace -e '
kprobe:handle_mm_fault { @start[tid] = nsecs; }
kretprobe:handle_mm_fault {
    if (@start[tid]) {
        @lat_ns = hist(nsecs - @start[tid]);
        delete(@start[tid]);
    }
}
interval:s:10 { print(@lat_ns); exit(); }
'
```

---

## 6. Storage Architecture Connections

| Scenario | Fault type | What happens |
|----------|-----------|-------------|
| `mmap(db_file)` first access | Major | `filemap_fault()` → page cache miss → block I/O → sleep |
| `mmap(db_file)` second access | Minor | Page already in cache → just set PTE |
| `fork()` in storage daemon | Minor (COW) | Pages shared until written; write → COW copy |
| io_uring registered buffer first use | Minor | Buffer already mlock'd by registration → no fault |
| Swap-in during reclaim | Major | Read page from swap device → storage I/O |
| DAX mmap first access | Minor | `dax_iomap_fault()` → device physical page mapped → no I/O |

---

## 7. Key Source Files

```
arch/x86/mm/fault.c     — do_page_fault(): architecture fault entry
mm/memory.c             — handle_mm_fault(), do_fault(), do_wp_page(), do_anonymous_page()
mm/filemap.c            — filemap_fault(): page cache fault handler
mm/swap.c               — do_swap_page(): swap fault handler
include/linux/mm.h      — VM_FAULT_* return codes
```

---

## 8. Self-Check Questions

1. `malloc(1GB)` followed by reading every byte returns zeros but causes no major faults. Why? Draw the PTE entry that satisfies all reads before any write.

2. Process A `mmap(MAP_SHARED)` a file and reads page 0. Process B then `mmap(MAP_SHARED)` the same file and reads page 0. How many physical pages hold page 0's data? How many page faults occurred in total?

3. After `fork()`, the child immediately calls `execve()`. Does COW copy any pages? Explain with reference to `do_wp_page()`.

4. A database reads a 10GB file with `mmap`. The file is not in page cache. How many major faults occur? At 10ms per fault (HDD), how long does the initial scan take? How does using `madvise(MADV_SEQUENTIAL)` change this?

5. `handle_mm_fault()` returns `VM_FAULT_OOM`. What happens? What triggered the OOM condition inside the fault handler?

---

## Tomorrow: Day 11 — Page Tables & TLB Management
The hardware structures that translate virtual to physical addresses, and the software cost of managing them.
