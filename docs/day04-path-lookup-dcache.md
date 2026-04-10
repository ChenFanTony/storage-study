# Day 4: Path Lookup & Dcache

## Learning Objectives
- Understand how Linux resolves pathnames component by component
- Learn how dcache accelerates path lookup
- Distinguish RCU-walk and ref-walk modes
- Follow key `fs/namei.c` lookup flow and fallback behavior
- Practice tracing lookup hotspots such as `d_lookup()`

---

## 1. Why Path Lookup Matters

Before any file operation can proceed, the kernel must resolve a pathname like:

```text
/home/user/data/file.txt
```

into concrete VFS objects (mainly `dentry` + `inode`).

Path lookup is performance-critical because it happens for `open()`, `stat()`, `unlink()`, `rename()`, and many other syscalls.

---

## 2. High-Level Lookup Flow

Conceptual flow for `openat()`/`open()`:

```text
sys_openat2()
  -> do_sys_openat2()
    -> do_filp_open()
      -> path_openat()
         -> path_init()           // choose starting point (cwd or root)
         -> link_path_walk()      // walk intermediate components
             -> walk_component()  // lookup each path element
                -> lookup_fast()  // dcache fast path
                -> lookup_slow()  // filesystem lookup fallback
         -> open_last_lookups() / do_open()
```

Notes:
- Exact helper names can vary across kernel versions.
- The core model stays the same: **initialize context → walk components → final component open/operation**.

---

## 3. Key Data Structures in Lookup

### `struct nameidata`
Lookup state machine context used while walking a path:
- current path (`struct path`)
- root path constraints
- lookup flags (e.g. follow symlink policy, RCU mode)
- last component metadata

### `struct path`
Pair of:
- `vfsmount` (mount context)
- `dentry` (current node)

### `struct qstr`
Filename component descriptor (`name`, `len`, hash).

### `struct dentry`
In-memory directory entry cache object:
- `d_name`: this component name
- `d_parent`: parent linkage
- `d_inode`: target inode (or NULL for negative dentry)

---

## 4. Component Walk Mechanics

For `/a/b/c` the kernel resolves in sequence:
1. Start from root or current working directory
2. Resolve `a`
3. Resolve `b`
4. Resolve final component `c`

At each component:
- Check dcache hash for `(parent, name)`
- If hit and valid, move forward quickly
- If miss or invalid, ask filesystem via inode ops (`lookup`)
- Handle mountpoints, symlinks, and permission checks

This repeated loop is what makes dcache effectiveness so important.

---

## 5. Dcache Fast Path

`lookup_fast()`-style logic tries to satisfy path lookup without slow filesystem operations.

Benefits:
- Avoids repeated on-disk directory reads
- Reduces lock and refcount overhead in the common case
- Greatly improves metadata-heavy workloads (`git status`, builds, package installs)

Dcache works like a name-to-object memoization layer for directory traversal.

---

## 6. Slow Path and Filesystem Lookup

When fast path cannot resolve a component, kernel falls back to slow lookup:
- invoke filesystem-specific `inode_operations->lookup`
- instantiate/update dentries and inodes
- return to VFS walk loop

Common causes of slow path:
- cold cache
- dentry invalidation
- revalidation requirements (network/distributed filesystems)
- negative lookup miss that now became present (or vice versa)

---

## 7. Negative Dentries

A **negative dentry** is a cached “name not found” result (`d_inode == NULL`).

Why useful:
- avoids repeated expensive misses for non-existent paths
- common in workloads probing optional files

Example:
- process repeatedly checks `/run/some-service.sock`
- if absent, negative dentry prevents repeated full slow lookups

---

## 8. RCU-Walk vs Ref-Walk

Linux path walk usually starts in a lightweight mode and falls back when needed.

### RCU-walk (fast optimistic mode)
- avoids taking heavy references/locks in common cases
- high throughput for stable dcache states
- cannot handle operations that may sleep/block

### Ref-walk (fallback precise mode)
- takes references/locks as needed
- handles complex cases safely
- slower but robust

Typical pattern:
1. Attempt lookup in RCU mode
2. If kernel encounters conditions requiring stronger guarantees, restart/fallback to ref-walk

This hybrid strategy gives both speed and correctness.

---

## 9. Symlink and Mount Traversal Considerations

Path lookup also handles:
- symlink following policy (`LOOKUP_FOLLOW`, no-follow semantics)
- mount crossing (`/mnt/...` transitions to another superblock)
- `.` and `..` semantics with mount/root constraints

Security-relevant behavior (e.g. `openat2` resolve flags) is enforced during lookup, not after.

---

## 10. Practical Tracing Focus

If you want to observe lookup behavior, focus on:
- `link_path_walk`
- `walk_component`
- `d_lookup`
- filesystem lookup callbacks (`ext4_lookup`, etc.)

These points reveal whether your workload is mostly dcache-hit or frequently dropping into slow path.

---

## 11. Hands-On Exercises

### Exercise 1: Observe syscall-level path activity
```bash
strace -e trace=openat,newfstatat,statx ls -l /usr/bin > /dev/null
```

### Exercise 2: Compare warm vs cold path lookup effect
```bash
# First run (colder metadata state)
time find /usr/include -maxdepth 2 -type f > /dev/null

# Second run (typically warmer dcache)
time find /usr/include -maxdepth 2 -type f > /dev/null
```

### Exercise 3: Function graph trace for lookup walk
```bash
cd /sys/kernel/debug/tracing
echo 0 > tracing_on
echo function_graph > current_tracer
echo link_path_walk > set_graph_function
echo walk_component >> set_graph_function
echo 1 > tracing_on

# trigger
ls -R /etc > /dev/null

echo 0 > tracing_on
head -120 trace
```

### Exercise 4: Probe dentry lookup calls
```bash
# requires bpftrace and debug symbols availability
sudo bpftrace -e 'kprobe:d_lookup { @[comm] = count(); } interval:s:5 { print(@); clear(@); }'
```

### Exercise 5: Inspect dcache pressure indicators
```bash
cat /proc/sys/fs/dentry-state
cat /proc/slabinfo | grep -E "dentry|inode_cache"
```

---

## 12. Source Navigation Checklist

Primary files to study:
- `fs/namei.c` (core pathname resolution)
- `fs/dcache.c` (dentry cache behavior)
- `include/linux/dcache.h` (`struct dentry`)
- `include/linux/namei.h` (lookup flags/types)

Related syscall/open path context:
- `fs/open.c`
- `include/linux/fs.h`

---

## 13. Common Pitfalls

1. Assuming path lookup is only string parsing
   - it is stateful VFS traversal with cache, security, mount, and symlink semantics

2. Ignoring negative dentries
   - misses are cached and can heavily affect behavior/perf

3. Forgetting RCU fallback behavior
   - traces may show restarts/fallback paths that are expected

4. Treating dcache hit rate as always stable
   - workload shape, memory pressure, and invalidation patterns matter

---

## 14. Self-Check Questions

1. What are the two main lookup walk modes and why does Linux use both?
2. What does a negative dentry represent?
3. When does lookup use filesystem `inode_operations->lookup`?
4. Why can repeated metadata-heavy commands speed up after the first run?
5. Which file primarily contains the path walk implementation logic?

## 15. Self-Check Answers

1. RCU-walk (fast optimistic) and ref-walk (safe fallback); this balances performance and correctness.
2. A cached “name does not exist” entry (`d_inode == NULL`).
3. On dcache miss, invalidation/revalidation need, or other fast-path failure conditions.
4. Dcache and inode cache become warm, reducing slow-path lookups.
5. `fs/namei.c`.

---

## 16. Tomorrow’s Preview: Day 5 — Page Cache

Next we move from pathname resolution to data caching:
- `mm/filemap.c` read path
- cache hit/miss behavior
- folios/pages in file cache
- how misses trigger readahead and I/O.
