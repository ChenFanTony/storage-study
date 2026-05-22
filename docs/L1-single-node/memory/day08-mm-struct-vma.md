# Day 8: Process Address Space — mm_struct & VMAs

## Learning Objectives
- Understand `struct mm_struct` as the complete virtual address space descriptor
- Understand `struct vm_area_struct` (VMA) as the unit of virtual memory management
- Read `/proc/PID/maps` and `/proc/PID/smaps` fluently
- Understand VMA flags, merging, and the maple tree (kernel 6.1+)
- Connect address spaces to storage: mmap'd files, device memory, stack growth

---

## 1. struct mm_struct: The Address Space

Every user process has one `mm_struct`. Kernel threads share a single `init_mm`. Thread groups share `mm_struct` (all threads of one process have the same `->mm`).

```c
// include/linux/mm_types.h (simplified, 6.6)
struct mm_struct {
    struct {
        // VMA tree (kernel 6.1+: maple tree; older: rbtree)
        struct maple_tree mm_mt;

        unsigned long mmap_base;       // base of mmap region
        unsigned long mmap_legacy_base;// base in legacy layout

        // Segment boundaries:
        unsigned long start_code, end_code;   // text segment
        unsigned long start_data, end_data;   // data segment
        unsigned long start_brk, brk;         // heap (brk grows up)
        unsigned long start_stack;             // stack base (grows down)
        unsigned long arg_start, arg_end;      // argv region
        unsigned long env_start, env_end;      // envp region

        // Page table root:
        pgd_t         *pgd;            // top-level page table

        // Stats:
        atomic_t mm_users;             // user processes sharing this mm
        atomic_t mm_count;             // references (including lazy mmput)
        unsigned long total_vm;        // total virtual pages
        unsigned long locked_vm;       // mlock'd pages
        unsigned long pinned_vm;       // FOLL_PIN'd pages (io_uring)
        unsigned long data_vm;         // data+stack pages
        unsigned long exec_vm;         // executable pages
        unsigned long stack_vm;        // stack pages

        // RSS counters (atomics, per-type):
        // MM_FILEPAGES, MM_ANONPAGES, MM_SWAPENTS, MM_SHMEMPAGES
    };
    // ...
};
```

### Sharing and Reference Counting
- `mm_users`: number of tasks using this mm (threads + one for the mm itself)
- `mm_count`: number of references (users + lazy references like `/proc/PID/maps` readers)
- `mmget()` / `mmput()`: get/release user reference
- `mmdrop()`: release mm_count reference; last drop frees the struct

---

## 2. struct vm_area_struct: The VMA

Each contiguous region of virtual address space with uniform permissions is one VMA.

```c
// include/linux/mm_types.h (simplified)
struct vm_area_struct {
    unsigned long vm_start;     // start VA (inclusive, page-aligned)
    unsigned long vm_end;       // end VA (exclusive, page-aligned)

    struct mm_struct *vm_mm;    // back pointer to mm

    pgprot_t vm_page_prot;      // page protection bits (CPU flags)
    unsigned long vm_flags;     // VMA behavior flags (see below)

    // For file-backed VMAs:
    struct file *vm_file;       // the mapped file (NULL for anonymous)
    unsigned long vm_pgoff;     // offset in file (in pages)
    const struct vm_operations_struct *vm_ops;  // fault handler etc.

    // For anonymous VMAs:
    struct anon_vma *anon_vma;  // reverse mapping for anonymous pages

    // VMA name (for debugging):
    const char __user *vm_name; // set by prctl(PR_SET_VMA_ANON_NAME)
};
```

### vm_flags: VMA Behavior
```c
// include/linux/mm.h
VM_READ         0x00000001  // readable
VM_WRITE        0x00000002  // writable
VM_EXEC         0x00000004  // executable
VM_SHARED       0x00000008  // shared (MAP_SHARED; changes visible to others)
VM_MAYREAD      0x00000010  // mprotect() may add READ
VM_MAYWRITE     0x00000020  // mprotect() may add WRITE
VM_GROWSDOWN    0x00000100  // stack (grows toward lower addresses)
VM_UFFD_MISSING 0x00000200  // userfaultfd: handle missing page fault in userspace
VM_LOCKED       0x00002000  // mlock'd: pages pinned in RAM
VM_IO           0x00004000  // MMIO region (mapped with ioremap equiv from userspace)
VM_DONTEXPAND   0x00000040  // cannot be extended with mremap()
VM_PFNMAP       0x00000400  // no struct page backing (raw PFN mapping, device mem)
VM_MIXEDMAP     0x10000000  // mixture of struct page and PFN mappings (DAX)
VM_HUGEPAGE     0x00800000  // THP enabled for this VMA
VM_NOHUGEPAGE   0x01000000  // THP disabled for this VMA
VM_DONTDUMP     0x04000000  // exclude from core dump
VM_SYNC         0x00080000  // MAP_SYNC: DAX writes are synchronous
```

---

## 3. Reading /proc/PID/maps

```bash
cat /proc/$$/maps
# Output format:
# start-end perms offset dev inode pathname
#
# 55a3b0000000-55a3b0001000 r--p 00000000 fd:01 1234567 /usr/bin/bash
# 55a3b0001000-55a3b0005000 r-xp 00001000 fd:01 1234567 /usr/bin/bash
# ...
# 7f8c40000000-7f8c40021000 rw-p 00000000 00:00 0       [heap] (or [anon])
# 7ffcb0000000-7ffcb0021000 rw-p 00000000 00:00 0       [stack]
# ...
```

Decode the flags column:
- `r` = VM_READ, `w` = VM_WRITE, `x` = VM_EXEC
- `p` = private (COW); `s` = shared (MAP_SHARED)

```bash
# Detailed per-VMA stats:
cat /proc/$$/smaps | head -80

# For each VMA:
# 7f8c40000000-7f8c40021000 rw-p ...
# Size:            135168 kB   ← virtual size
# KernelPageSize:    4096 B
# MMUPageSize:       4096 B
# RSS:               4096 kB   ← resident pages (in RAM)
# PSS:               1024 kB   ← proportional (RSS / sharing count)
# Shared_Clean:         0 kB   ← shared pages, not modified
# Shared_Dirty:         0 kB   ← shared pages, modified
# Private_Clean:        0 kB   ← private, not modified (can be dropped)
# Private_Dirty:     4096 kB   ← private, modified (needs swap if evicted)
# Referenced:        4096 kB   ← accessed recently
# Anonymous:         4096 kB   ← anonymous pages (no file backing)
# LazyFree:             0 kB   ← MADV_FREE pages (reclaimable)
# AnonHugePages:        0 kB   ← THP anonymous pages
# ShmemPmdMapped:       0 kB
# Swap:                 0 kB   ← pages currently swapped out
# SwapPss:              0 kB
# Locked:               0 kB   ← mlock'd pages
# THPeligible:          1       ← eligible for THP
# VmFlags: rd wr mr mw me     ← human-readable vm_flags
```

---

## 4. VMA Merging

The kernel aggressively merges adjacent VMAs with identical flags and backing:

```c
// mm/mmap.c
vma_merge()     // called after mmap(), mprotect(), etc.
    // Conditions for merge:
    // - adjacent (end of one == start of other)
    // - same vm_flags
    // - same file + contiguous offset (or both anonymous)
    // - same anon_vma (for anonymous)
```

This matters for performance: fewer VMAs = faster VMA lookup, less memory for VMA structs. The maple tree (replacing the old rbtree in 6.1) makes VMA lookup O(log n).

```bash
# Count VMAs for a process:
wc -l /proc/$pid/maps

# Heavy mmap users have many VMAs:
wc -l /proc/$(pidof java)/maps    # Java processes often have 1000+ VMAs
wc -l /proc/$(pidof mysqld)/maps  # databases: usually < 100
```

---

## 5. Address Space Layout

```bash
# Canonical x86-64 layout (with ASLR):
cat /proc/$$/maps | awk '{print $1, $6}' | head -30

# Typical layout (low to high VA):
# 0x000000000000 - 0x7fffffffffff  : user space (128TB)
#   text segment      : ~0x55xxxxxxxx (with ASLR randomization)
#   heap (brk)        : above text, grows up
#   mmap region       : grows down from ~0x7f0000000000
#   stack             : ~0x7ffcxxxxxxxx, grows down
#
# 0xffff800000000000 - 0xffffffffffffffff : kernel space (128TB)
#   direct map        : 0xffff888000000000 (all physical RAM)
#   vmalloc           : 0xffffc90000000000
#   module text       : 0xffffffffa0000000

# Check ASLR state:
cat /proc/sys/kernel/randomize_va_space
# 0 = disabled, 1 = randomize mmap/stack, 2 = also randomize heap
```

---

## 6. Hands-On Exercises

```bash
# --- Explore your shell's address space ---
cat /proc/$$/maps

# Count VMA types:
awk '{print $6}' /proc/$$/maps | sort | uniq -c | sort -rn

# --- Watch VMA creation ---
bpftrace -e '
kprobe:mmap_region {
    printf("pid=%d vm_start=%lx vm_end=%lx vm_flags=%lx\n",
           pid, arg0, arg0+arg2, arg3);
}
' &
BPID=$!
# Trigger some mmaps:
cat /dev/urandom | head -c 1M > /dev/null
kill $BPID

# --- Inspect a storage daemon's address space ---
# Pick multipathd, iscsid, or ceph-osd
PID=$(pidof multipathd)
cat /proc/$PID/maps
cat /proc/$PID/smaps_rollup

# --- VMA flags for a mmap'd file ---
python3 -c "
import mmap, os
f = open('/etc/passwd', 'rb')
m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
print('mapped:', hex(id(m)))
input('press enter to continue')
m.close()
f.close()
" &
PYPID=$!
sleep 1
grep -E "passwd|anon" /proc/$PYPID/maps
wait $PYPID

# --- Observe stack growth ---
# Stack VMAs have VM_GROWSDOWN:
grep '\[stack\]' /proc/$$/maps
# The VMA will be small but grows as the stack deepens
```

---

## 7. Storage Architecture Connections

| Storage scenario | VMA involvement |
|-----------------|----------------|
| `mmap(file, MAP_SHARED)` | Creates file-backed VMA with `vm_file` set; `vm_ops->fault = filemap_fault` |
| `mmap(file, MAP_PRIVATE)` | File-backed VMA; writes trigger COW → new anonymous page |
| io_uring fixed buffers | VMA range registered; pages get `VM_PINNED` via `FOLL_PIN` |
| DAX mmap | VMA with `VM_MIXEDMAP`; fault handler bypasses page cache |
| SPDK huge page mmap | VMA with `VM_HUGETLB`; backed by hugetlbfs |
| NVMe BAR mmap to userspace | VMA with `VM_IO | VM_PFNMAP`; maps device registers |

---

## 8. Key Source Files

```
include/linux/mm_types.h    — struct mm_struct, struct vm_area_struct
include/linux/mm.h          — VM_* flag definitions
mm/mmap.c                   — do_mmap(), mmap_region(), vma_merge()
mm/util.c                   — vm_mmap_pgoff()
fs/proc/task_mmu.c          — /proc/PID/maps and /proc/PID/smaps generation
lib/maple_tree.c            — maple tree (VMA index structure, 6.1+)
```

---

## 9. Self-Check Questions

1. A process has 10 threads. How many `mm_struct` objects exist? How many `task_struct` objects? What is `mm_users` for that `mm_struct`?

2. You `mmap()` a 1GB file with `MAP_SHARED`. `/proc/PID/maps` shows one VMA covering the full 1GB. But `RSS` for that VMA is 0KB. Explain why RSS is 0 and when it will grow.

3. `/proc/PID/smaps` shows a VMA with `Private_Dirty: 100MB`. The process forks. What happens to these 100MB pages? What happens to `Private_Dirty` in the child immediately after fork?

4. `wc -l /proc/$(pidof java)/maps` returns 3500. Why does Java have so many VMAs? What are most of them? Is this a problem?

5. A storage driver needs to expose its DMA buffer directly to userspace (zero-copy). What VMA flags would the resulting mmap have? Which `vm_ops` function must the driver implement?

---

## Tomorrow: Day 9 — mmap() Internals: From Syscall to VMA
Trace `mmap()` through `do_mmap()` → VMA creation → return. Understand why `mmap()` creates no pages — demand paging means pages come only on first access.
