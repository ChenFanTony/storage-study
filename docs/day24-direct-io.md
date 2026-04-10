# Day 24: Direct I/O (`O_DIRECT`)

## Learning Objectives
- Understand what Direct I/O is and when Linux bypasses page cache
- Learn alignment and I/O-size constraints of `O_DIRECT`
- Compare buffered I/O vs Direct I/O behavior and trade-offs
- Benchmark `O_DIRECT` vs buffered paths with `fio`

---

## 1. What Direct I/O Means

With buffered I/O, data usually flows through page cache.

With Direct I/O (`O_DIRECT`), the kernel attempts to transfer data directly between user buffers and storage path, minimizing page-cache involvement for file data.

Conceptually:

```text
Buffered I/O:
app buffer <-> page cache <-> block layer/device

Direct I/O:
app buffer -------------> block layer/device
```

(Exact internals vary by filesystem and kernel path, but this is the operational model.)

---

## 2. Why Use Direct I/O

Common motivations:
- avoid page-cache pollution for large streaming workloads
- reduce double-buffering when app already has its own cache
- achieve more predictable cache behavior in database/log systems

Typical use cases:
- databases
- large backup/restore tools
- custom storage engines with user-space caching policies

---

## 3. Trade-offs vs Buffered I/O

### Buffered I/O strengths
- simple API usage
- benefits from readahead and cache hits
- often better for small/repeated reads

### Direct I/O strengths
- bypasses page cache for data path
- avoids evicting useful cached pages
- can improve consistency of memory usage under heavy scan workloads

### Direct I/O caveats
- alignment constraints can cause `EINVAL`
- may perform worse for small/random patterns depending on stack
- application must handle its own caching/read-ahead strategy if needed

---

## 4. Alignment Constraints (Critical)

`O_DIRECT` typically requires alignment for:
- user buffer address
- file offset
- I/O length

Alignment often relates to logical block size (commonly 512 or 4096), and filesystem/device specifics can impose stricter constraints.

If constraints are violated, operations can fail (often `EINVAL`).

Practical rule:
- use block-size-aligned offsets and I/O sizes (e.g., 4K multiples)
- use aligned buffers (e.g., `posix_memalign` in custom code)

---

## 5. Kernel Path Notes

From study-plan perspective:
- historical direct-I/O code: `fs/direct-io.c`
- modern filesystems increasingly use `iomap`-based direct-I/O paths

So behavior depends on filesystem implementation details, but user-level semantics still revolve around `O_DIRECT` bypass intent and alignment requirements.

---

## 6. Buffered vs Direct Benchmark Design

For meaningful comparison:
1. same file size and workload shape
2. same block size and queue depth where applicable
3. multiple runs per case
4. collect throughput + latency
5. separate cold/warm cache scenarios for buffered mode

Do not compare one-off runs only.

---

## 7. Hands-On Exercises

### Exercise 1: Prepare test file
```bash
fio --name=prep --filename=/tmp/day24-directio.img --size=2G --rw=write --bs=1M --ioengine=psync --direct=0
```

### Exercise 2: Buffered sequential read baseline
```bash
fio --name=buf-seqread --filename=/tmp/day24-directio.img --size=2G \
    --rw=read --bs=128k --iodepth=16 --ioengine=libaio --direct=0 --group_reporting
```

### Exercise 3: Direct sequential read
```bash
fio --name=dio-seqread --filename=/tmp/day24-directio.img --size=2G \
    --rw=read --bs=128k --iodepth=16 --ioengine=libaio --direct=1 --group_reporting
```

### Exercise 4: Buffered random read vs direct random read
```bash
fio --name=buf-randread --filename=/tmp/day24-directio.img --size=2G \
    --rw=randread --bs=4k --iodepth=64 --ioengine=libaio --direct=0 --group_reporting

fio --name=dio-randread --filename=/tmp/day24-directio.img --size=2G \
    --rw=randread --bs=4k --iodepth=64 --ioengine=libaio --direct=1 --group_reporting
```

### Exercise 5: Observe cache effect for buffered mode
```bash
# run buffered test twice and compare
fio --name=buf-pass1 --filename=/tmp/day24-directio.img --size=2G --rw=read --bs=128k --ioengine=psync --direct=0
fio --name=buf-pass2 --filename=/tmp/day24-directio.img --size=2G --rw=read --bs=128k --ioengine=psync --direct=0
```

### Exercise 6: Source navigation
```bash
grep -rn "direct" fs/direct-io.c fs/ | head -40
grep -rn "iomap.*direct" fs/ | head -40
```

---

## 8. Source Navigation Checklist

Primary:
- `fs/direct-io.c`
- `fs/*` iomap-based direct-I/O integration paths (filesystem-dependent)

Supporting:
- `fs/read_write.c`
- `mm/filemap.c` (for buffered path contrast)

---

## 9. Common Pitfalls

1. Assuming `O_DIRECT` always improves performance
   - depends heavily on workload and storage characteristics

2. Ignoring alignment requirements
   - misaligned I/O often fails with `EINVAL`

3. Comparing buffered warm-cache with direct-cold-device unfairly
   - ensure comparable test conditions

4. Forgetting application-level caching implications
   - bypassing page cache shifts caching responsibility toward the app/workload design

---

## 10. Self-Check Questions

1. What is the main semantic difference between buffered I/O and Direct I/O?
2. Why can `O_DIRECT` return `EINVAL`?
3. Name one workload where Direct I/O is commonly used.
4. Why should buffered benchmarks consider warm vs cold cache behavior?
5. Which kernel file is traditionally associated with direct I/O logic?

## 11. Self-Check Answers

1. Buffered I/O uses page cache; Direct I/O tries to bypass page cache for file data transfers.
2. Buffer address, size, or offset may violate alignment constraints required by filesystem/device path.
3. Databases and large backup/restore pipelines are common examples.
4. Page cache can drastically change buffered performance between runs.
5. `fs/direct-io.c` (plus filesystem-specific modern iomap paths).

---

## 12. Tomorrow’s Preview: Day 25 — bcache

Next we study Linux block caching with bcache:
- cache set registration
- SSD cache + HDD backing flow
- writeback policy behavior and observability.
