# Day 2: VFS Core Structures

## Learning Objectives
- Understand the four core VFS objects and how they relate
- Read the actual struct definitions in kernel source
- Trace `open()` syscall to see how VFS objects are created/connected
- Understand the operations tables (dispatch mechanism)

---

## 1. The Four Core VFS Objects

The VFS uses four primary data structures to represent a filesystem in memory:

```
┌──────────────────────────────────────────────────────────────────┐
│                    VFS Object Relationships                      │
│                                                                  │
│  mount("ext4", "/mnt")                                          │
│       │                                                          │
│       ▼                                                          │
│  ┌─────────────┐                                                 │
│  │ super_block  │ ◄── one per mounted filesystem instance        │
│  │  s_op        │     (ext4 on /dev/sda1 mounted at /mnt)        │
│  └──────┬──────┘                                                 │
│         │ s_root                                                 │
│         ▼                                                        │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐        │
│  │   dentry     │────►│   dentry     │────►│   dentry     │       │
│  │  "/mnt"      │     │  "home"      │     │  "file.txt"  │       │
│  │  d_inode ────┼──┐  │  d_inode ────┼──┐  │  d_inode ────┼──┐   │
│  └─────────────┘  │  └─────────────┘  │  └─────────────┘  │   │
│                    ▼                   ▼                   ▼   │
│             ┌─────────┐        ┌─────────┐         ┌─────────┐│
│             │  inode   │        │  inode   │         │  inode   ││
│             │  (dir)   │        │  (dir)   │         │  (file)  ││
│             │  i_op    │        │  i_op    │         │  i_op    ││
│             │ i_mapping│        │ i_mapping│         │ i_mapping││
│             └─────────┘        └─────────┘         └────┬────┘│
│                                                          │     │
│  open("/mnt/home/file.txt", O_RDONLY)                    │     │
│       │                                                  │     │
│       ▼                                                  │     │
│  ┌─────────────┐                                         │     │
│  │    file      │ ◄── one per open() call (per-process)  │     │
│  │  f_inode  ───┼─────────────────────────────────────────┘     │
│  │  f_op        │ (points to file_operations from inode)        │
│  │  f_pos       │ (current read/write position)                 │
│  └─────────────┘                                                 │
└──────────────────────────────────────────────────────────────────┘
```

**Key relationships:**
- `super_block` → `dentry` (root) via `s_root`
- `dentry` → `inode` via `d_inode`
- `inode` → `address_space` (page cache) via `i_mapping`
- `file` → `dentry` via `f_path.dentry`
- `file` → `inode` via `f_inode`
- `file` → `file_operations` via `f_op` (copied from `inode->i_fop`)

---

## 2. struct super_block — The Mounted Filesystem

**Defined in:** `include/linux/fs/super.h`

One `super_block` exists for each mounted filesystem instance (e.g., ext4 on /dev/sda1 at /mnt).

```c
struct super_block {
    struct list_head    s_list;        /* list of all superblocks */
    dev_t               s_dev;         /* device identifier */
    unsigned char       s_blocksize_bits;
    unsigned long       s_blocksize;   /* block size in bytes */
    loff_t              s_maxbytes;    /* max file size */
    struct file_system_type *s_type;   /* filesystem type (ext4, xfs, ...) */
    const struct super_operations *s_op; /* superblock operations */

    unsigned long       s_flags;       /* mount flags */
    unsigned long       s_magic;       /* filesystem magic number */
    struct dentry       *s_root;       /* ROOT dentry of this mount */

    struct block_device *s_bdev;       /* associated block device */
    struct backing_dev_info *s_bdi;    /* backing device info */

    struct list_head    s_inodes;      /* all inodes */
    struct list_head    s_dirty;       /* dirty inodes */
    // ... many more fields
};
```

**Key operations (`struct super_operations`):**
```c
struct super_operations {
    struct inode *(*alloc_inode)(struct super_block *sb);  /* allocate inode */
    void (*destroy_inode)(struct inode *);                 /* free inode */
    void (*dirty_inode)(struct inode *, int flags);        /* mark dirty */
    int (*write_inode)(struct inode *, struct writeback_control *);
    void (*evict_inode)(struct inode *);                   /* remove from cache */
    void (*put_super)(struct super_block *);               /* release superblock */
    int (*sync_fs)(struct super_block *, int wait);        /* sync filesystem */
    int (*statfs)(struct dentry *, struct kstatfs *);      /* get fs stats */
    // ...
};
```

---

## 3. struct inode — The File Identity

**Defined in:** `include/linux/fs.h:766`

An `inode` represents a file object on the filesystem. It contains all metadata *except* the filename (that's in the dentry). Multiple dentries can point to the same inode (hard links).

```c
struct inode {
    umode_t             i_mode;        /* file type + permissions */
    unsigned short      i_opflags;
    kuid_t              i_uid;         /* owner UID */
    kgid_t              i_gid;         /* owner GID */
    unsigned int        i_flags;

    const struct inode_operations  *i_op;      /* inode operations */
    struct super_block             *i_sb;      /* owning superblock */
    struct address_space           *i_mapping; /* PAGE CACHE for this file */

    unsigned long       i_ino;         /* inode number */
    const unsigned int  i_nlink;       /* hard link count */

    loff_t              i_size;        /* file size in bytes */
    struct timespec64   __i_atime;     /* access time */
    struct timespec64   __i_mtime;     /* modification time */
    struct timespec64   __i_ctime;     /* change time */

    blkcnt_t            i_blocks;      /* blocks allocated */
    unsigned short      i_bytes;       /* bytes used in last block */

    const struct file_operations *i_fop; /* default file operations */
    struct address_space  i_data;       /* actual address_space (page cache) */
    // ...
};
```

**Important note:** `i_mapping` usually points to `&i_data`, the embedded `address_space`. For block devices, `i_mapping` can point to a shared `address_space`.

**Key operations (`struct inode_operations`):**
```c
struct inode_operations {
    struct dentry * (*lookup)(struct inode *, struct dentry *, unsigned int);
    int (*create)(struct mnt_idmap *, struct inode *, struct dentry *, umode_t, bool);
    int (*link)(struct dentry *, struct inode *, struct dentry *);
    int (*unlink)(struct inode *, struct dentry *);
    int (*symlink)(struct inode *, struct dentry *, const char *);
    int (*mkdir)(struct mnt_idmap *, struct inode *, struct dentry *, umode_t);
    int (*rmdir)(struct inode *, struct dentry *);
    int (*rename)(struct mnt_idmap *, struct inode *, struct dentry *,
                  struct inode *, struct dentry *, unsigned int);
    int (*permission)(struct mnt_idmap *, struct inode *, int);
    int (*setattr)(struct mnt_idmap *, struct dentry *, struct iattr *);
    int (*getattr)(struct mnt_idmap *, const struct path *, struct kstat *, u32, unsigned int);
    // ...
};
```

---

## 4. struct dentry — The Name-to-Inode Mapping

**Defined in:** `include/linux/dcache.h:81`

A dentry maps a filename component to an inode. Dentries exist only in memory (they're cached in the dcache for performance). They are NOT stored on disk — the on-disk directory entries are different.

```c
struct dentry {
    unsigned int d_flags;              /* dentry flags */
    seqcount_spinlock_t d_seq;         /* per-dentry seqlock */
    struct hlist_bl_node d_hash;       /* lookup hash list */
    struct dentry *d_parent;           /* parent directory dentry */
    struct qstr d_name;                /* filename component (e.g., "file.txt") */
    struct inode *d_inode;             /* associated inode (NULL = negative dentry) */
    unsigned char d_iname[DNAME_INLINE_LEN]; /* small name inline storage */

    const struct dentry_operations *d_op;
    struct super_block *d_sb;          /* owning superblock */

    struct list_head d_child;          /* child of parent list */
    struct list_head d_subdirs;        /* our children */
    // ...
};
```

**Dentry states:**
1. **Used** — `d_inode` is valid, dentry is in use (positive refcount)
2. **Unused** — `d_inode` is valid, but refcount = 0 (cached for future use)
3. **Negative** — `d_inode` is NULL (file doesn't exist, but cached to avoid repeated lookups)

**The dcache (dentry cache):**
- Hash table for O(1) lookup by (parent dentry, name)
- LRU list for reclaiming unused dentries under memory pressure
- Dramatically speeds up path lookup — avoids disk reads for directory entries

---

## 5. struct file — The Open File Instance

**Defined in:** `include/linux/fs.h`

A `file` represents an open file descriptor. It's per-process (actually per-fd-table entry). Multiple processes can have different `file` structs pointing to the same inode (different positions, flags).

```c
struct file {
    file_ref_t              f_ref;         /* reference count */
    struct path             f_path;        /* { vfsmount, dentry } */
    struct inode            *f_inode;      /* cached inode pointer */
    const struct file_operations *f_op;    /* file operations (from inode) */

    fmode_t                 f_mode;        /* FMODE_READ, FMODE_WRITE, ... */
    loff_t                  f_pos;         /* current read/write position */
    unsigned int            f_flags;       /* O_RDONLY, O_NONBLOCK, etc. */

    struct mutex            f_pos_lock;    /* protects f_pos updates */
    struct address_space    *f_mapping;    /* page cache mapping */
    void                    *private_data; /* filesystem private data */
    // ...
};
```

**Key operations (`struct file_operations`):**
```c
struct file_operations {
    struct module *owner;
    loff_t (*llseek)(struct file *, loff_t, int);
    ssize_t (*read)(struct file *, char __user *, size_t, loff_t *);
    ssize_t (*write)(struct file *, const char __user *, size_t, loff_t *);
    ssize_t (*read_iter)(struct kiocb *, struct iov_iter *);
    ssize_t (*write_iter)(struct kiocb *, struct iov_iter *);
    int (*iterate_shared)(struct file *, struct dir_context *);
    __poll_t (*poll)(struct file *, struct poll_table_struct *);
    long (*unlocked_ioctl)(struct file *, unsigned int, unsigned long);
    int (*mmap)(struct file *, struct vm_area_struct *);
    int (*open)(struct inode *, struct file *);
    int (*flush)(struct file *, fl_owner_t id);
    int (*release)(struct inode *, struct file *);
    int (*fsync)(struct file *, loff_t, loff_t, int datasync);
    int (*flock)(struct file *, int, struct file_lock *);
    ssize_t (*splice_read)(struct file *, loff_t *, struct pipe_inode_info *,
                           size_t, unsigned int);
    // ...
};
```

**Modern path:** Most filesystems now implement `read_iter`/`write_iter` instead of `read`/`write`. The VFS calls `new_sync_read()` which wraps the call with `struct kiocb` + `struct iov_iter`.

---

## 6. struct address_space — The Page Cache Interface

**Defined in:** `include/linux/fs.h`

The `address_space` is the page cache for a file. Every inode has one embedded (`inode->i_data`), and `inode->i_mapping` points to it.

```c
struct address_space {
    struct inode        *host;           /* owning inode */
    struct xarray       i_pages;         /* cached pages (xarray/radix tree) */
    struct rw_semaphore invalidate_lock;
    gfp_t               gfp_mask;        /* memory allocation flags */
    atomic_t            i_mmap_writable; /* count of VM_SHARED mappings */
    struct rb_root_cached i_mmap;        /* tree of private/shared mappings */
    unsigned long       nrpages;         /* number of cached pages */
    const struct address_space_operations *a_ops; /* page cache operations */
    unsigned long       flags;           /* AS_EIO, AS_ENOSPC, etc. */
    // ...
};
```

**Key operations (`struct address_space_operations`):**
```c
struct address_space_operations {
    int (*writepage)(struct page *page, struct writeback_control *wbc);
    int (*read_folio)(struct file *, struct folio *);
    int (*writepages)(struct address_space *, struct writeback_control *);
    bool (*dirty_folio)(struct address_space *, struct folio *);
    void (*readahead)(struct readahead_control *);
    int (*write_begin)(struct file *, struct address_space *, loff_t pos,
                       unsigned len, struct folio **foliop, void **fsdata);
    int (*write_end)(struct file *, struct address_space *, loff_t pos,
                     unsigned len, unsigned copied, struct folio *folio, void *fsdata);
    int (*direct_IO)(struct kiocb *, struct iov_iter *);
    // ...
};
```

---

## 7. Tracing open() — How VFS Objects Connect

### Step 1: System call entry
```
fs/open.c:  SYSCALL_DEFINE3(open, ...)
  → do_sys_openat2(AT_FDCWD, filename, &how)
```

### Step 2: Allocate file descriptor and struct file
```c
// fs/open.c: do_sys_openat2()
static long do_sys_openat2(int dfd, const char __user *filename,
                           struct open_how *how)
{
    // ... validate flags ...
    fd = get_unused_fd_flags(how->flags);  // allocate fd number
    struct filename *tmp = getname(filename);  // copy filename from user
    struct file *f = do_filp_open(dfd, tmp, &op);  // THE MAIN WORK
    fd_install(fd, f);  // install file into process fd table
    return fd;
}
```

### Step 3: Path lookup + open (fs/namei.c)
```c
// fs/namei.c: do_filp_open()
struct file *do_filp_open(int dfd, struct filename *pathname,
                          const struct open_flags *op)
{
    struct nameidata nd;
    // ... set up nameidata ...
    filp = path_openat(&nd, op, flags | LOOKUP_RCU);  // try RCU-walk first
    if (unlikely(filp == ERR_PTR(-ECHILD)))
        filp = path_openat(&nd, op, flags);            // fall back to ref-walk
    if (unlikely(filp == ERR_PTR(-ESTALE)))
        filp = path_openat(&nd, op, flags | LOOKUP_REVAL);  // revalidate
    return filp;
}
```

### Step 4: path_openat — walk the path and open
```c
// fs/namei.c: path_openat()
static struct file *path_openat(struct nameidata *nd,
                                const struct open_flags *op, unsigned flags)
{
    struct file *file = alloc_empty_file(op->open_flag, ...);  // allocate struct file

    // Walk each component of the path:
    //   "/mnt/home/file.txt" → walk "mnt" → walk "home" → walk "file.txt"
    const char *s = path_init(nd, flags);  // start from root or cwd
    while (!(error = link_path_walk(s, nd))) {
        // link_path_walk resolves each path component:
        //   For each component:
        //     1. Look up dentry in dcache (fast) or call inode->i_op->lookup() (slow)
        //     2. Follow mount points
        //     3. Advance to next component

        error = do_open(nd, file, op);  // open the final component
    }
    return file;
}
```

### Step 5: do_dentry_open — connect everything
```c
// fs/open.c: do_dentry_open()
static int do_dentry_open(struct file *f, struct inode *inode,
                          int (*open)(struct inode *, struct file *))
{
    f->f_inode = inode;                    // file → inode
    f->f_mapping = inode->i_mapping;       // file → page cache
    f->f_op = fops_get(inode->i_fop);      // file → operations (from inode!)

    // Set f_mode based on flags
    if (f->f_flags & O_RDONLY)
        f->f_mode |= FMODE_READ;

    // Call filesystem-specific open
    if (open)
        error = open(inode, f);             // e.g., ext4_file_open()
    else if (f->f_op->open)
        error = f->f_op->open(inode, f);

    // Now f is fully initialized and connected
    return 0;
}
```

### The complete picture after open():
```
Process fd table:
  fd[3] ──► struct file {
                f_path.dentry ──► dentry("file.txt") ──► inode {
                f_inode ─────────────────────────────────►  i_op  = ext4_file_inode_operations
                f_op = ext4_file_operations                 i_fop = ext4_file_operations
                f_mapping ─────────────────────────────►    i_mapping ──► address_space {
                f_pos = 0                                                  a_ops = ext4_aops
            }                                                              i_pages = (xarray)
                                                                         }
                                                           i_sb ──► super_block {
                                                                      s_op = ext4_sops
                                                                      s_bdev = /dev/sda1
                                                                    }
                                                         }
```

---

## 8. VFS Dispatch Mechanism — How Polymorphism Works

The VFS achieves filesystem independence through **function pointer tables** (similar to vtables in C++):

```c
// When userspace calls read(fd, buf, count):

// 1. Kernel gets struct file from fd table
struct file *f = fdget_pos(fd);

// 2. VFS dispatches through file_operations
if (f->f_op->read_iter)                    // modern path
    ret = f->f_op->read_iter(&kiocb, &iter);
    // → This calls ext4_file_read_iter() for ext4
    // → This calls xfs_file_read_iter() for XFS
    // → This calls btrfs_file_read_iter() for Btrfs

// 3. Filesystem calls into page cache or block layer as needed
```

Each filesystem registers its own implementations:
```c
// fs/ext4/file.c
const struct file_operations ext4_file_operations = {
    .llseek     = ext4_llseek,
    .read_iter  = ext4_file_read_iter,
    .write_iter = ext4_file_write_iter,
    .open       = ext4_file_open,
    .release    = ext4_release_file,
    .fsync      = ext4_sync_file,
    .mmap       = ext4_file_mmap,
    // ...
};

// fs/xfs/xfs_file.c
const struct file_operations xfs_file_operations = {
    .llseek     = xfs_file_llseek,
    .read_iter  = xfs_file_read_iter,
    .write_iter = xfs_file_write_iter,
    .fsync      = xfs_file_fsync,
    .mmap       = xfs_file_mmap,
    // ...
};
```

---

## 9. Hands-On Exercises

### Exercise 1: Trace open() with strace
```bash
# Watch the open syscall
strace -e trace=openat cat /etc/hostname
# Output: openat(AT_FDCWD, "/etc/hostname", O_RDONLY|O_CLOEXEC) = 3

# Trace the full lifecycle: open, read, close
strace -e trace=openat,read,close cat /etc/hostname
```

### Exercise 2: Examine inode via stat
```bash
# Show inode metadata
stat /etc/hostname
# Output shows: inode number, links, size, block count, timestamps

# Show just inode number
ls -i /etc/hostname

# Show hard link count
stat -c '%h' /etc/hostname
```

### Exercise 3: Explore the dentry cache
```bash
# Dentry cache stats
cat /proc/sys/fs/dentry-state
# Fields: nr_dentry, nr_unused, age_limit, want_pages, nr_negative, dummy

# Slab allocator for dentries
cat /proc/slabinfo | grep dentry
```

### Exercise 4: Examine superblock information
```bash
# List all mounted filesystems with superblock info
cat /proc/mounts

# Filesystem statistics (uses super_operations->statfs)
df -T /
stat -f /
```

### Exercise 5: Trace open() with ftrace
```bash
cd /sys/kernel/debug/tracing
echo 0 > tracing_on
echo function_graph > current_tracer
echo do_dentry_open > set_graph_function
echo 1 > tracing_on

# Trigger
cat /etc/hostname > /dev/null

echo 0 > tracing_on
cat trace | head -80
```

### Exercise 6: Trace inode->i_op->lookup with kprobe
```bash
# Using bpftrace to see dentry lookups
bpftrace -e 'kprobe:ext4_lookup { printf("ext4_lookup: %s\n",
    str(((struct dentry *)arg1)->d_name.name)); }'

# In another terminal:
ls /mnt/some_ext4_filesystem/
```

---

## 10. VFS Object Lifecycle Summary

| Object | Created When | Destroyed When | Cache |
|--------|-------------|----------------|-------|
| `super_block` | `mount()` syscall | `umount()` or last reference dropped | in-memory, one per mount |
| `inode` | First access to file (lookup or create) | Memory pressure / eviction | inode cache (slab) |
| `dentry` | Path lookup finds a component | Memory pressure (LRU reclaim) | dentry cache (dcache hash table) |
| `file` | `open()` syscall | `close()` or process exit | per-process, no global cache |

---

## 11. Self-Check Questions

1. How many `file` structs are created if two processes both `open()` the same file?
2. How many `inode` structs exist for a file with 3 hard links?
3. What is a negative dentry, and why is it useful?
4. Where does `struct file` get its `f_op` pointer from?
5. What's the difference between `inode_operations` and `file_operations`?
6. What happens in `do_dentry_open()` that connects all VFS objects?
7. Why does the VFS try RCU-walk first in `do_filp_open()`?
8. What structure holds the page cache for a file?

## 12. Answers to Self-Check

1. **Two** `file` structs — one per `open()` call. Each has its own `f_pos`.
2. **One** `inode` — hard links are multiple dentries pointing to the same inode.
3. A negative dentry has `d_inode = NULL` — it caches "this file doesn't exist" to avoid repeating the disk lookup.
4. From `inode->i_fop`, set during `do_dentry_open()`: `f->f_op = fops_get(inode->i_fop)`.
5. `inode_operations` handles namespace operations (create, lookup, mkdir, rename). `file_operations` handles data operations (read, write, mmap, ioctl).
6. It sets `f->f_inode`, `f->f_mapping`, `f->f_op`, and calls the filesystem's `open()` method.
7. RCU-walk avoids taking any locks or incrementing refcounts — it's much faster for the common case. Falls back to ref-walk if it encounters anything that needs sleeping.
8. `struct address_space`, accessed via `inode->i_mapping` (which points to `&inode->i_data`).

---

## 13. Tomorrow's Preview: Day 3 — VFS Operations (read/write paths)

We'll deep-dive into `vfs_read()` / `vfs_write()`, understand `new_sync_read()` with `kiocb` + `iov_iter`, and trace how the VFS dispatches to filesystem-specific read implementations.
