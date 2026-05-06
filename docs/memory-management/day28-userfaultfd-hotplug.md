# Day 28: userfaultfd & Memory Hot-plug

## Learning Objectives
- Understand userfaultfd: user-space page fault handling
- Know how QEMU uses userfaultfd for live VM migration
- Understand memory hot-plug: adding/removing DIMM online
- Connect userfaultfd to storage: lazy loading, tiered memory, SCM

---

## 1. userfaultfd: User-Space Page Fault Handler

Normally, page faults are handled entirely in the kernel. `userfaultfd` lets a user-space thread intercept page faults for a registered VA range and resolve them however it wants.

```c
// Basic flow:
// 1. Create userfaultfd:
int uffd = syscall(SYS_userfaultfd, O_CLOEXEC | O_NONBLOCK);

// 2. Enable it:
struct uffdio_api api = { .api = UFFD_API };
ioctl(uffd, UFFDIO_API, &api);

// 3. Register a VA range:
struct uffdio_register reg = {
    .range = { .start = (uint64_t)addr, .len = size },
    .mode  = UFFDIO_REGISTER_MODE_MISSING,  // intercept missing-page faults
};
ioctl(uffd, UFFDIO_REGISTER, &reg);

// 4. Fault handler thread: poll uffd for events:
struct uffd_msg msg;
read(uffd, &msg, sizeof(msg));
// msg.event == UFFD_EVENT_PAGEFAULT
// msg.arg.pagefault.address == faulting VA

// 5. Resolve fault (copy data into the faulting page):
struct uffdio_copy copy = {
    .dst  = msg.arg.pagefault.address & ~(PAGE_SIZE - 1),
    .src  = (uint64_t)source_data,
    .len  = PAGE_SIZE,
    .mode = 0,
};
ioctl(uffd, UFFDIO_COPY, &copy);
// → kernel maps source_data into the faulting page, wakes the faulting thread
```

---

## 2. Fault Modes

```c
// Registration modes:
UFFDIO_REGISTER_MODE_MISSING   // intercept missing page faults (most common)
UFFDIO_REGISTER_MODE_WP        // intercept write-protect faults (tracking writes)
UFFDIO_REGISTER_MODE_MINOR     // intercept minor faults (hugetlb, shmem)

// Resolution ioctls:
UFFDIO_COPY    // copy page data from user buffer → faulting page
UFFDIO_ZEROPAGE // zero-fill the faulting page (no data needed)
UFFDIO_CONTINUE // resume fault without data (for minor mode)
UFFDIO_WRITEPROTECT // change write-protect state
UFFDIO_POISON  // mark page as poisoned (testing error paths)
```

---

## 3. QEMU Live Migration via userfaultfd

This is the primary production use case today:

```
Source VM:                          Destination VM:
──────────────────                  ──────────────────
1. Start migration                  1. Pre-allocate guest RAM
2. Copy all pages to dest           2. Register all pages with userfaultfd
3. Track dirty pages (WP mode)      3. Start VM (pages missing → UFFD faults)
4. Iteratively copy dirty pages     4. UFFD handler waits for page from source
5. Stop VM                         5. UFFD handler gets page → UFFDIO_COPY
6. Copy final dirty pages          6. Guest thread resumes
7. Resume VM on dest               7. VM running with minimal downtime
```

Key insight: guest VM starts running on the destination before all pages are copied. Missing pages are fetched on-demand via userfaultfd. Downtime = only the final stop-copy phase.

---

## 4. Storage Applications of userfaultfd

### Lazy Loading (Storage-Class Memory Tiering)

```c
// Scenario: application has 100GB working set, 32GB DRAM, 100GB PMEM
// Strategy: map all data in DRAM VA space; fetch from PMEM on fault

// 1. Register 100GB anonymous region with userfaultfd:
mmap(NULL, 100GB, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
ioctl(uffd, UFFDIO_REGISTER, &reg);  // intercept all missing faults

// 2. Fault handler: on access to cold page:
//    - Read page from PMEM/NVMe
//    - UFFDIO_COPY to install it in the guest's page table
//    - Optionally evict least-recently-used page back to PMEM

// This is how software memory tiering works:
// Linux 5.15+ has kernel-level NUMA-based tiering (demotion/promotion)
// userfaultfd allows user-space policy control
```

### CRIU (Checkpoint/Restore in Userspace)

```
Checkpoint: serialize process memory to storage
Restore:    
  1. Create new process with same address space layout
  2. Register all pages with userfaultfd
  3. Resume process (starts running immediately)
  4. Fault handler pages in from checkpoint files on demand
  → Fast restore: process starts in milliseconds, not minutes
```

---

## 5. Hands-On: userfaultfd Demo

```c
// save as /tmp/uffd_demo.c
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <linux/userfaultfd.h>
#include <pthread.h>
#include <poll.h>

#define PAGE_SIZE 4096

static int uffd;
static char *region;

void *fault_handler(void *arg) {
    struct pollfd pfd = { .fd = uffd, .events = POLLIN };
    struct uffd_msg msg;

    while (poll(&pfd, 1, -1) > 0) {
        if (read(uffd, &msg, sizeof(msg)) < 0) break;
        if (msg.event != UFFD_EVENT_PAGEFAULT) continue;

        uint64_t fault_addr = msg.arg.pagefault.address & ~(PAGE_SIZE - 1);
        printf("[uffd handler] fault at %#lx — providing page\n", fault_addr);

        // Provide a page filled with 'X':
        char *page = aligned_alloc(PAGE_SIZE, PAGE_SIZE);
        memset(page, 'X', PAGE_SIZE);

        struct uffdio_copy copy = {
            .dst  = fault_addr,
            .src  = (uint64_t)page,
            .len  = PAGE_SIZE,
            .mode = 0,
        };
        ioctl(uffd, UFFDIO_COPY, &copy);
        free(page);
    }
    return NULL;
}

int main(void) {
    // 1. Create userfaultfd:
    uffd = syscall(SYS_userfaultfd, O_CLOEXEC | O_NONBLOCK);
    struct uffdio_api api = { .api = UFFD_API };
    ioctl(uffd, UFFDIO_API, &api);

    // 2. Map region:
    region = mmap(NULL, 4 * PAGE_SIZE, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

    // 3. Register with userfaultfd:
    struct uffdio_register reg = {
        .range = { .start = (uint64_t)region, .len = 4 * PAGE_SIZE },
        .mode  = UFFDIO_REGISTER_MODE_MISSING,
    };
    ioctl(uffd, UFFDIO_REGISTER, &reg);

    // 4. Start fault handler thread:
    pthread_t thr;
    pthread_create(&thr, NULL, fault_handler, NULL);

    // 5. Access pages — triggers userfaultfd:
    for (int i = 0; i < 4; i++) {
        printf("[main] accessing page %d...\n", i);
        char c = region[i * PAGE_SIZE];  // triggers fault
        printf("[main] page %d first byte: '%c'\n", i, c);
    }

    pthread_cancel(thr);
    munmap(region, 4 * PAGE_SIZE);
    return 0;
}
```

```bash
gcc -o /tmp/uffd_demo /tmp/uffd_demo.c -lpthread && /tmp/uffd_demo
# Output:
# [main] accessing page 0...
# [uffd handler] fault at 0x7f... — providing page
# [main] page 0 first byte: 'X'
# [main] accessing page 1...
# ...
```

---

## 6. Memory Hot-plug

Add or remove physical DIMM modules while the system is running:

```bash
# List memory sections:
ls /sys/devices/system/memory/
# memory0, memory1, ... each covers 128MB or 256MB (arch-dependent)

# Check state of each section:
cat /sys/devices/system/memory/memory*/state
# online       ← active
# offline      ← removed from active use
# going-offline ← transition in progress

# Bring a memory section online:
echo online > /sys/devices/system/memory/memory512/state

# Bring offline (for DIMM removal):
echo offline > /sys/devices/system/memory/memory512/state
# May fail if pages are in use (UNMOVABLE pages)

# Online to specific zone (MOVABLE means it can be offlined later):
echo online_movable > /sys/devices/system/memory/memory512/state

# Total hot-pluggable memory:
grep "^State: online" /sys/devices/system/memory/memory*/state | wc -l
```

### Memory Hot-plug and NUMA

```bash
# When new DIMM is added on socket 1:
# New NUMA node may appear (or expand existing node)
numactl --hardware   # before
# Add DIMM...
numactl --hardware   # after — node memory increases

# Kernel notification via udev:
# /sys/bus/memory/drivers/... triggers uevents on hot-add
udevadm monitor --kernel | grep memory
```

---

## 7. Key Source Files

```
mm/userfaultfd.c        — userfaultfd_register(), handle_userfault()
fs/userfaultfd.c        — userfaultfd syscall, ioctl handlers
mm/memory-failure.c     — memory error handling (adjacent to hot-plug)
drivers/base/memory.c   — memory hot-plug sysfs interface
mm/memory_hotplug.c     — add_memory(), remove_memory()
include/uapi/linux/userfaultfd.h — UFFD API constants
```

---

## 8. Self-Check Questions

1. A userfaultfd fault handler takes 50ms to fetch a page from remote storage. The faulting thread is blocked for all 50ms. What is the thread's state during this wait? Is it interruptible?

2. QEMU uses `UFFDIO_REGISTER_MODE_WP` (write-protect mode) during live migration dirty page tracking. When a guest writes to a page, what happens? How does QEMU use this to track which pages need re-copying?

3. A process registers a 10GB anonymous region with userfaultfd (MISSING mode). Another thread accesses 1000 random pages simultaneously. How many fault events does the uffd handler receive? Are they serialized or concurrent?

4. Memory hot-plug adds a new DIMM to NUMA node 1. Existing processes have their memory on node 0. Does any process memory automatically migrate to node 1? What would trigger migration?

5. `echo offline > /sys/devices/system/memory/memory512/state` returns `-EBUSY`. Why? What types of pages prevent a memory section from being taken offline?

---

## Tomorrow: Day 29 — MM Performance Tuning Reference Card
