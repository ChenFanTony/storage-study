# Day 26: mlock, madvise & Memory Pinning

## Learning Objectives
- Understand mlock: locking pages against reclaim and swap
- Understand the full MADV_* vocabulary and when each applies
- Understand FOLL_PIN: kernel-internal pinning for io_uring
- Know the difference between mlock and FOLL_PIN and why both exist

---

## 1. mlock: Locking Pages in RAM

```c
// mlock prevents reclaim and swap:
int mlock(const void *addr, size_t len);   // lock range
int munlock(const void *addr, size_t len); // unlock range
int mlockall(int flags);                   // lock all current and future pages
int munlockall(void);

// Flags for mlockall:
MCL_CURRENT   // lock all current pages
MCL_FUTURE    // lock all future allocated pages
MCL_ONFAULT   // lock on fault (lazy: only lock pages as they're faulted in)
```

### What mlock Does

```c
// mm/mlock.c
int mlock_fixup(struct vm_area_struct *vma, ...)
{
    // Set VM_LOCKED flag on VMA
    vma->vm_flags |= VM_LOCKED;

    // Fault in all pages in range (make them resident):
    populate_vma_page_range(vma, start, end);

    // Mark pages on unevictable LRU (cannot be reclaimed):
    mlock_vma_pages_range(vma, start, end);
}
```

### Requirements and Limits

```bash
# Regular users have RLIMIT_MEMLOCK limit:
ulimit -l                          # current limit in KB (default: 64KB)
cat /proc/$$/limits | grep locked

# Storage daemons need higher limit:
# /etc/security/limits.conf:
# ceph    hard    memlock    unlimited
# spdk    hard    memlock    unlimited

# Or via systemd:
# [Service]
# LimitMEMLOCK=infinity

# Check mlocked pages:
cat /proc/meminfo | grep Mlocked
cat /proc/$pid/status | grep VmLck
```

---

## 2. MADV_* Hints: Telling the Kernel Your Access Pattern

```c
int madvise(void *addr, size_t length, int advice);
```

| Advice | Effect | Use case |
|--------|--------|---------|
| `MADV_SEQUENTIAL` | Aggressive read-ahead; evict behind | Sequential file scans |
| `MADV_RANDOM` | Disable read-ahead | Random access (databases, KV stores) |
| `MADV_WILLNEED` | Prefetch range now (async) | Pre-warm cache before processing |
| `MADV_DONTNEED` | Drop range from cache immediately | After processing, free cache |
| `MADV_FREE` | Mark as reclaimable (lazy free) | Freed memory: kernel may reuse |
| `MADV_HUGEPAGE` | Enable THP for this VMA | Large sequential buffers |
| `MADV_NOHUGEPAGE` | Disable THP for this VMA | Databases, random access |
| `MADV_DONTDUMP` | Exclude from core dump | Sensitive data, large buffers |
| `MADV_DONTFORK` | Don't copy to child after fork | Device memory, DMA buffers |
| `MADV_POPULATE_READ` | Fault in pages for reading (sync) | Pre-populate before I/O (6.0+) |
| `MADV_POPULATE_WRITE` | Fault in pages for writing (sync) | Pre-populate before write (6.0+) |

### Storage-Relevant Examples

```c
// Backup tool: process 1GB file, then release:
void *buf = mmap(NULL, 1<<30, PROT_READ, MAP_SHARED, fd, 0);
madvise(buf, 1<<30, MADV_SEQUENTIAL);  // aggressive read-ahead
process_data(buf);
madvise(buf, 1<<30, MADV_DONTNEED);   // don't pollute cache after done

// Database: random access, no read-ahead pollution:
madvise(db_mmap, db_size, MADV_RANDOM);    // disable read-ahead
madvise(db_mmap, db_size, MADV_NOHUGEPAGE); // disable THP

// io_uring pre-population (avoid faults during I/O):
madvise(io_buf, buf_size, MADV_POPULATE_WRITE);  // fault in all pages now
// Now io_uring can use buffer without any page faults
```

---

## 3. FOLL_PIN: The io_uring Pinning Mechanism

`mlock()` prevents reclaim but doesn't prevent the kernel from migrating pages (for NUMA balancing, compaction, etc.). For DMA and io_uring, pages must be **pinned** — guaranteed immovable.

The kernel introduced `FOLL_PIN` (pin_user_pages) for this purpose:

```c
// include/linux/mm.h
// FOLL_PIN: stronger than mlock
// - Pages cannot be reclaimed
// - Pages cannot be migrated (NUMA balancing, compaction won't touch them)
// - Device drivers can safely DMA to/from these pages
// - Tracked separately from get_page() refs for debugging

// io_uring uses this for registered buffers:
// io_uring_register(ring_fd, IORING_REGISTER_BUFFERS, ...)
//   → pin_user_pages_fast(addr, len, FOLL_PIN | FOLL_WRITE, pages)
//   → each page gets a "pin reference" counted separately from mapcount
```

### mlock vs FOLL_PIN

| Feature | mlock | FOLL_PIN |
|---------|-------|---------|
| Prevents reclaim | ✓ | ✓ |
| Prevents migration | ✗ | ✓ |
| User API | `mlock()` | `io_uring_register()` or kernel internal |
| Ref counting | VM_LOCKED VMA flag | `page_pincount` / mapcount |
| Safe for DMA | No (can migrate) | Yes (immovable) |
| Safe for io_uring zero-copy | No | Yes |

---

## 4. io_uring Fixed Buffers: The Full Picture

```c
// Application registers buffers with io_uring:
struct iovec iov = { .iov_base = buf, .iov_len = buf_size };
io_uring_register(ring_fd, IORING_REGISTER_BUFFERS, &iov, 1);
// → kernel calls pin_user_pages(buf, npages, FOLL_PIN | FOLL_WRITE, pages)
// → each page: page->_refcount += 1 (pin reference)
// → VMA: vm_mm->pinned_vm += npages

// Submit I/O using registered buffer (index 0):
struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
io_uring_prep_read_fixed(sqe, fd, buf, buf_size, 0, 0);  // buf_index=0
// → no DMA mapping per-I/O! Buffer is pre-registered.
// → no page faults! Pages are pinned.
// → no mmap/munmap overhead!
// → latency improvement: ~5-15μs reduction in I/O setup overhead
```

```bash
# Check pinned pages:
cat /proc/meminfo | grep -i pin     # no direct counter unfortunately
cat /proc/$pid/status | grep VmPin  # kernel 5.15+

# io_uring buffer registration (test):
# Requires liburing
cat > /tmp/test_fixed.c << 'EOF'
#include <liburing.h>
#include <stdio.h>
#include <stdlib.h>

int main() {
    struct io_uring ring;
    io_uring_queue_init(32, &ring, 0);

    char *buf = aligned_alloc(4096, 4096 * 256);  // 1MB buffer
    struct iovec iov = { buf, 4096 * 256 };

    int ret = io_uring_register_buffers(&ring, &iov, 1);
    printf("register_buffers: %d\n", ret);

    // Check /proc/self/status VmPin here...
    io_uring_unregister_buffers(&ring);
    io_uring_queue_exit(&ring);
    return 0;
}
EOF
gcc -o /tmp/test_fixed /tmp/test_fixed.c -luring 2>/dev/null && /tmp/test_fixed
```

---

## 5. Hands-On Exercises

```bash
# --- mlock behavior ---
python3 << 'EOF'
import ctypes, os, mmap

libc = ctypes.CDLL("libc.so.6")
MCL_CURRENT = 1
MCL_FUTURE  = 2

# Lock all current pages:
ret = libc.mlockall(MCL_CURRENT)
print(f"mlockall: {ret} (0=success)")

# Check mlocked memory:
with open(f"/proc/{os.getpid()}/status") as f:
    for line in f:
        if "VmLck" in line:
            print(line.strip())

libc.munlockall()
EOF

# --- MADV_DONTNEED to free cache after backup ---
# Create test file:
dd if=/dev/urandom of=/tmp/backup_test bs=1M count=100 2>/dev/null

# Read file, observe cache growth:
python3 << 'EOF'
import mmap, os, ctypes

f = open("/tmp/backup_test", "rb")
m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)

# MADV_SEQUENTIAL hint:
libc = ctypes.CDLL("libc.so.6")
MADV_SEQUENTIAL = 2
libc.madvise(m.fileno(), len(m), MADV_SEQUENTIAL)

# Read all data (simulating backup):
data = bytes(m)  # reads everything
print(f"Read {len(data)//1024//1024}MB")

# Now release the cache:
MADV_DONTNEED = 4
libc.madvise(m.fileno(), len(m), MADV_DONTNEED)
print("Cache released with MADV_DONTNEED")

m.close()
f.close()
EOF

# --- Check madvise effect on cache ---
vmtouch /tmp/backup_test   # should show 0% cached after MADV_DONTNEED
```

---

## 6. Key Source Files

```
mm/mlock.c              — mlock_fixup(), populate_vma_page_range()
mm/madvise.c            — madvise() implementation, per-advice handlers
mm/gup.c                — pin_user_pages(), FOLL_PIN implementation
io_uring/io_uring.c     — io_uring_register_buffers(), fixed buffer pinning
include/linux/mm.h      — FOLL_* flags, pin_user_pages()
```

---

## 7. Self-Check Questions

1. A process calls `mlock(buf, 1GB)`. The system has `RLIMIT_MEMLOCK=64KB` for this user. What happens? What capability allows bypassing this limit?

2. NUMA balancing tries to migrate a page to reduce remote memory accesses. The page has a FOLL_PIN reference from io_uring. Can migration proceed? Why not?

3. `madvise(addr, len, MADV_DONTNEED)` is called on a `MAP_PRIVATE` anonymous mapping. What happens to the pages? Does the virtual address range still exist? What happens on next access?

4. A database uses `madvise(data_region, size, MADV_RANDOM)`. Why is this important for I/O performance? What kernel behavior does it prevent?

5. io_uring registered buffers (FOLL_PIN) eliminate per-I/O DMA mapping overhead. Quantify: if `dma_map_sg()` takes 1μs per I/O and an NVMe drive does 1M IOPS, how much CPU time is saved by pre-registering buffers?

---

## Tomorrow: Day 27 — DAX & PMEM: Memory-Mapped Persistent Storage
