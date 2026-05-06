# Day 9: mmap() Internals — From Syscall to VMA

## Learning Objectives
- Trace the full `mmap()` call path from userspace to kernel VMA creation
- Understand why `mmap()` creates no pages (demand paging)
- Understand anonymous vs file-backed mmap differences
- Know MAP_SHARED vs MAP_PRIVATE semantics at the VMA level

---

## 1. The Call Chain

```
userspace: mmap(addr, length, prot, flags, fd, offset)
    │
    └─ syscall: sys_mmap_pgoff()           [arch/x86/kernel/sys_x86_64.c]
         │
         └─ vm_mmap_pgoff(file, addr, len, prot, flags, pgoff)   [mm/util.c]
              │
              ├─ security_mmap_file()      ← LSM/SELinux checks
              │
              └─ do_mmap(file, addr, len, prot, flags, 0, pgoff, &populate, NULL)
                   │                       [mm/mmap.c]
                   ├─ get_unmapped_area()  ← find free VA range
                   │   (honors addr hint, ASLR, alignment requirements)
                   │
                   ├─ mmap_region(file, addr, len, vm_flags, pgoff, uchunks)
                   │   │
                   │   ├─ vma_merge()      ← try to merge with adjacent VMA
                   │   │
                   │   ├─ vm_area_alloc()  ← allocate struct vm_area_struct (slab)
                   │   │
                   │   ├─ vma->vm_start = addr
                   │   │   vma->vm_end   = addr + len
                   │   │   vma->vm_flags = vm_flags
                   │   │   vma->vm_pgoff = pgoff
                   │   │
                   │   ├─ [file-backed]: call_mmap(file, vma)
                   │   │   → file->f_op->mmap(file, vma)
                   │   │   → e.g., ext4_file_mmap() sets vma->vm_ops = &ext4_file_vm_ops
                   │   │   → for DAX: sets VM_MIXEDMAP flag
                   │   │
                   │   ├─ vma_link(mm, vma)  ← insert into mm->mm_mt (maple tree)
                   │   │
                   │   └─ return addr
                   │
                   └─ [if MAP_POPULATE]: mm_populate() ← fault in pages now (optional)
                       otherwise: return immediately, pages come on demand
```

**Key insight:** `mmap()` returns immediately after VMA creation. No pages are allocated. No I/O happens. The mapping is purely virtual until the process actually reads or writes the mapped range. This is demand paging.

---

## 2. Anonymous vs File-Backed mmap

### Anonymous mmap (fd = -1, MAP_ANONYMOUS)
```c
mmap(NULL, 1<<20, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)
```
- VMA has `vm_file = NULL`, `vm_ops = &anon_vma_ops`
- On first write: page fault → `do_anonymous_page()` → zero-filled page from buddy
- Pages are not backed by any file; they live only in RAM (or swap)
- Used for: heap (`brk`/`mmap` from malloc), stack, thread stacks

### File-backed mmap
```c
fd = open("/var/lib/data/db.bin", O_RDWR);
mmap(NULL, file_size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0)
```
- VMA has `vm_file = file`, `vm_ops` set by filesystem
- On first access: page fault → `filemap_fault()` → look up page cache → if miss, read from disk
- Pages are shared with the page cache — same physical page, no copy
- Used for: database files, shared memory, executable text segments

### MAP_PRIVATE vs MAP_SHARED

| | MAP_PRIVATE | MAP_SHARED |
|--|------------|-----------|
| Writes | COW: new private page | Visible to all mappers |
| File sync | No (private copy) | Yes (via writeback) |
| vm_flags | — | VM_SHARED |
| Use case | Executable loading, private data | IPC, database files |

---

## 3. get_unmapped_area: Finding VA Space

```c
// mm/mmap.c
unsigned long get_unmapped_area(struct file *file, unsigned long addr,
                                unsigned long len, unsigned long pgoff,
                                unsigned long flags)
```

For huge page mappings (e.g., MAP_HUGETLB), the VMA must be aligned to huge page size (2MB on x86). `get_unmapped_area()` handles this alignment automatically.

For DAX files, alignment to huge page boundaries is critical for huge page faults to work.

---

## 4. Hands-On Exercises

```bash
# --- Trace mmap syscalls with strace ---
strace -e trace=mmap,munmap,mprotect -p $(pidof fio) 2>&1 | head -50
# Observe: what gets mmap'd, with what flags, what sizes

# --- Watch VMA creation/deletion ---
bpftrace -e '
tracepoint:syscalls:sys_enter_mmap {
    printf("pid=%-6d len=%-10lu prot=0x%x flags=0x%x\n",
           pid, args->len, args->prot, args->flags);
}
'

# --- Observe demand paging: mmap then access ---
python3 << 'EOF'
import mmap, time, os

# Create a 1GB sparse file
with open('/tmp/sparse_test', 'wb') as f:
    f.seek(1024*1024*1024 - 1)
    f.write(b'\0')

f = open('/tmp/sparse_test', 'r+b')
m = mmap.mmap(f.fileno(), 0)

print("mmap done — check RSS (should be ~0)")
input("Press enter to access first page...")
# Access first byte: triggers page fault → page read from disk
data = m[0]
print(f"Read byte: {data}")
input("Press enter to check RSS (should be ~4KB now)...")
# Check in another terminal: cat /proc/$PID/smaps | grep RSS

m.close()
f.close()
os.unlink('/tmp/sparse_test')
EOF

# --- Count major vs minor faults ---
# Major = required disk I/O; minor = page already in memory
cat /proc/$$/stat | awk '{print "minor faults:", $10, "major faults:", $12}'

# BPF: trace major faults (real I/O caused by page fault):
bpftrace -e '
software:major-faults:1 {
    @major[comm] = count();
}
interval:s:5 { print(@major); clear(@major); }
'
```

---

## 5. Key Source Files

```
mm/mmap.c           — do_mmap(), mmap_region(), get_unmapped_area(), vma_merge()
mm/util.c           — vm_mmap_pgoff()
mm/memory.c         — handle_mm_fault() (next day)
fs/ext4/file.c      — ext4_file_mmap() — sets vm_ops
fs/xfs/xfs_file.c   — xfs_file_mmap()
fs/dax.c            — dax_file_mmap() for PMEM
```

---

## 6. Self-Check Questions

1. `mmap(NULL, 1GB, PROT_READ, MAP_SHARED, fd, 0)` returns in microseconds even though the file is 1GB on a slow HDD. Why? When does disk I/O actually occur?

2. A process maps the same file twice: once with `MAP_SHARED` and once with `MAP_PRIVATE`. Both write to offset 0. How many physical pages hold the data at offset 0? Which process's write persists to disk?

3. `get_unmapped_area()` returns a different address than the `addr` hint passed to `mmap()`. Under what conditions does the kernel ignore the hint?

4. Trace `mmap(NULL, 4096, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)`. At what point is the first 4KB page actually allocated from the buddy allocator?

5. A 2MB DAX mmap requires `get_unmapped_area()` to return a 2MB-aligned address. Why? What happens if the address is only 4KB-aligned?

---

## Tomorrow: Day 10 — Page Faults: Demand Paging & COW
The fault handler that bridges the gap between VMA (virtual description) and physical pages.
