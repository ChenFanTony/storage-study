# Day 3: VFS Operations (Read/Write Paths)

## Learning Objectives
- Understand how `read()` and `write()` enter the kernel and reach VFS
- Follow `vfs_read()` / `vfs_write()` through validation and dispatch
- Distinguish legacy `read`/`write` callbacks from modern `read_iter`/`write_iter`
- Understand `kiocb` + `iov_iter` in the synchronous path
- Implement and test a minimal kernel module that registers `file_operations`

---

## 1. End-to-End Read/Write Flow

At a high level, Linux file I/O follows this path:

```
userspace read()/write()
        |
        v
SYSCALL_DEFINE3(read/write)  (fs/read_write.c)
        |
        v
ksys_read()/ksys_write()
        |
        v
vfs_read()/vfs_write()
  - fd/file mode checks
  - rw_verify_area()
  - security hooks
  - accounting/notifications
        |
        v
file->f_op dispatch
  - read() / write()               (legacy)
  - read_iter() / write_iter()     (modern)
        |
        v
filesystem implementation
  - ext4/xfs/btrfs specific handlers
        |
        v
page cache and/or block layer
```

Core idea: **VFS is the stable interface**. Filesystems provide concrete behavior through function pointers in `file_operations`.

---

## 2. Syscall Entry: `read()` and `write()`

`read()` and `write()` enter in `fs/read_write.c` through syscall wrappers, then delegate to internal helpers.

Typical flow:

```
SYSCALL_DEFINE3(read, fd, buf, count)
  -> ksys_read(fd, buf, count)
     -> fdget_pos(fd)
     -> vfs_read(file, buf, count, &pos)

SYSCALL_DEFINE3(write, fd, buf, count)
  -> ksys_write(fd, buf, count)
     -> fdget_pos(fd)
     -> vfs_write(file, buf, count, &pos)
```

Important points:
- File descriptor lookup maps `fd` to `struct file`.
- Position-handling logic (`f_pos`) is coordinated in this layer.
- VFS handles generic checks before filesystem callbacks execute.

---

## 3. `vfs_read()` / `vfs_write()` Responsibilities

`vfs_read()` and `vfs_write()` are not the filesystem implementation—they are the **generic gatekeepers**.

### What happens in `vfs_read()`
- Verify file mode allows reading (`FMODE_READ`)
- Verify user buffer access constraints
- Call `rw_verify_area()` for range/permission checks
- Dispatch to:
  - `file->f_op->read()` (legacy path), or
  - `new_sync_read()` if `read_iter` exists
- Update task accounting and notifications

### What happens in `vfs_write()`
- Verify file mode allows writing (`FMODE_WRITE`)
- Verify user buffer access constraints
- Call `rw_verify_area()`
- Dispatch to:
  - `file->f_op->write()` (legacy path), or
  - `new_sync_write()` if `write_iter` exists
- Perform post-write notifications/accounting

Think of these functions as: **validate once, dispatch consistently**.

---

## 4. Why `read_iter` / `write_iter` Matters

Modern filesystems usually implement `read_iter` / `write_iter`.

Why?
- Better support for vectored I/O and async-oriented interfaces
- Shared iterator-based infrastructure
- Cleaner integration with modern paths (`io_uring`, direct I/O flows, etc.)

### Iterator-based sync helper flow

```
new_sync_read(file, buf, len, ppos)
  -> init_sync_kiocb(&kiocb, file)
  -> iov_iter_ubuf(&iter, ITER_DEST, buf, len)
  -> call_read_iter(file, &kiocb, &iter)

new_sync_write(file, buf, len, ppos)
  -> init_sync_kiocb(&kiocb, file)
  -> iov_iter_ubuf(&iter, ITER_SOURCE, buf, len)
  -> call_write_iter(file, &kiocb, &iter)
```

Two key objects:
- `struct kiocb`: request context (file, position, flags)
- `struct iov_iter`: abstract view over user buffers

---

## 5. Dispatch via `file_operations`

`struct file_operations` is the VFS dispatch table for open file instances.

Common read/write-related entries:
- `.read`
- `.write`
- `.read_iter`
- `.write_iter`
- `.llseek`
- `.fsync`
- `.mmap`
- `.open`
- `.release`

VFS dispatch logic (conceptual):

```c
if (file->f_op->read)
    ret = file->f_op->read(file, buf, count, pos);
else if (file->f_op->read_iter)
    ret = new_sync_read(file, buf, count, pos);
else
    ret = -EINVAL;
```

Equivalent pattern applies to write.

---

## 6. Validation and Security Checks in the VFS Path

Before filesystem code runs, VFS centralizes checks:

- Access mode checks (`FMODE_READ`, `FMODE_WRITE`)
- `rw_verify_area()`:
  - offset/length validity
  - overflow handling
  - permission constraints
- LSM/security hook integration (policy enforcement)
- Consistent accounting hooks

This design avoids duplicating fundamental checks in every filesystem.

---

## 7. Data Path Notes: Buffered vs Direct-ish Behavior

After VFS dispatch, filesystem handlers choose the data path:

### Buffered path (common)
- Read/write mostly interacts with page cache
- Write often marks dirty cache pages first
- Writeback pushes dirty pages later

### Direct path (when configured)
- May bypass page cache for data transfer
- Still uses VFS entry/validation layers
- Different performance and consistency trade-offs

For Day 3, focus is **dispatch mechanics**, not deep page-cache internals (covered in later days).

---

## 8. Minimal Kernel Module: Register `file_operations`

Below is a compact misc-device example that exposes `/dev/day3_vfs_demo` with read/write callbacks.

```c
// day3_vfs_demo.c
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/uaccess.h>

#define DEV_NAME "day3_vfs_demo"
#define BUF_SZ   256

static char demo_buf[BUF_SZ];
static size_t demo_len;

static ssize_t demo_read(struct file *file, char __user *ubuf, size_t count, loff_t *ppos)
{
    return simple_read_from_buffer(ubuf, count, ppos, demo_buf, demo_len);
}

static ssize_t demo_write(struct file *file, const char __user *ubuf, size_t count, loff_t *ppos)
{
    size_t n = min(count, (size_t)(BUF_SZ - 1));

    if (copy_from_user(demo_buf, ubuf, n))
        return -EFAULT;

    demo_buf[n] = '\0';
    demo_len = n;
    return n;
}

static const struct file_operations demo_fops = {
    .owner = THIS_MODULE,
    .read  = demo_read,
    .write = demo_write,
    .llseek = default_llseek,
};

static struct miscdevice demo_miscdev = {
    .minor = MISC_DYNAMIC_MINOR,
    .name  = DEV_NAME,
    .fops  = &demo_fops,
    .mode  = 0666,
};

static int __init demo_init(void)
{
    int ret = misc_register(&demo_miscdev);
    if (ret)
        pr_err("%s: misc_register failed: %d\n", DEV_NAME, ret);
    else
        pr_info("%s: loaded\n", DEV_NAME);
    return ret;
}

static void __exit demo_exit(void)
{
    misc_deregister(&demo_miscdev);
    pr_info("%s: unloaded\n", DEV_NAME);
}

module_init(demo_init);
module_exit(demo_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("study");
MODULE_DESCRIPTION("Day 3 VFS file_operations demo");
```

What this demonstrates:
- VFS calls your `demo_read`/`demo_write` through `file_operations`
- `loff_t *ppos` drives file position semantics
- User-kernel copying uses `copy_from_user` / helper APIs
- `demo_write` intentionally behaves like a simple overwrite buffer for learning, not a full file-like append/update implementation

---

## 9. Hands-On Exercises

### Exercise 1: Locate VFS entry functions
```bash
grep -n "vfs_read" fs/read_write.c
grep -n "vfs_write" fs/read_write.c
grep -n "new_sync_read" fs/read_write.c
grep -n "new_sync_write" fs/read_write.c
```

### Exercise 2: Trace userspace syscalls
```bash
strace -e trace=read,write cat /etc/hostname > /dev/null
strace -e trace=read,write sh -c 'echo hello > /tmp/day3.out; cat /tmp/day3.out > /dev/null'
```

### Exercise 3: Function trace for VFS operations
```bash
cd /sys/kernel/debug/tracing
echo 0 > tracing_on
echo function_graph > current_tracer
echo vfs_read > set_graph_function
echo vfs_write >> set_graph_function
echo 1 > tracing_on

# trigger workload
cat /etc/hostname > /dev/null
echo x > /tmp/day3.tmp

echo 0 > tracing_on
head -120 trace
```

### Exercise 4: Build and test the demo module
```bash
# 1) Build module (using your kernel build setup)
# 2) Load
sudo insmod day3_vfs_demo.ko

# 3) Interact
echo "vfs-day3" | sudo tee /dev/day3_vfs_demo
sudo cat /dev/day3_vfs_demo

# 4) Unload
sudo rmmod day3_vfs_demo
```

### Exercise 5: Observe dispatch behavior in real filesystems
```bash
# Inspect operation tables in sources (example: ext4)
grep -n "file_operations" fs/ext4/file.c
grep -n "read_iter" fs/ext4/file.c
grep -n "write_iter" fs/ext4/file.c
```

---

## 10. Key Source References

| Topic | Files |
|------|------|
| Syscall + VFS read/write entry | `fs/read_write.c` |
| Core file structures | `include/linux/fs.h` |
| Path/open internals | `fs/namei.c`, `fs/open.c` |
| Page cache read/write paths | `mm/filemap.c` |
| Writeback | `mm/page-writeback.c`, `fs/fs-writeback.c` |
| Example filesystem file ops | `fs/ext4/file.c`, `fs/xfs/` |

---

## 11. Common Pitfalls

1. Confusing `struct inode` with `struct file`
   - inode: file identity/metadata
   - file: one open instance (fd state)

2. Assuming `.read` is always used
   - modern kernels/filesystems often use `.read_iter`

3. Ignoring `*ppos`
   - position management is part of correct read/write behavior

4. Treating VFS as a filesystem
   - VFS is a dispatch and policy layer, not on-disk logic

---

## 12. Self-Check Questions

1. What is the role of `vfs_read()` before filesystem callback execution?
2. Why do modern filesystems prefer `read_iter` / `write_iter`?
3. What do `kiocb` and `iov_iter` represent in `new_sync_read()`?
4. Where does `file->f_op` come from during `open()` lifecycle?
5. In a custom device driver, which object exposes read/write callbacks to VFS?
6. Why is centralized VFS validation important for security and correctness?

## 13. Self-Check Answers

1. It performs generic checks (mode, range, access/security/accounting) and then dispatches.
2. They support iterator-based I/O and integrate better with modern kernel I/O mechanisms.
3. `kiocb` is operation context; `iov_iter` is abstract buffer iterator over user memory.
4. It is set from inode-provided operations during open path initialization.
5. `struct file_operations`.
6. It ensures uniform enforcement and avoids duplicated, inconsistent checks across filesystems.

---

## 14. Tomorrow’s Preview: Day 4 — Path Lookup & Dcache

Next we will follow pathname resolution in `fs/namei.c`, including:
- component walk (`link_path_walk`)
- dcache fast path
- RCU-walk vs ref-walk
- practical lookup tracing.
