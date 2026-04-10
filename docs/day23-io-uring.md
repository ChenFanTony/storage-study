# Day 23: io_uring

## Learning Objectives
- Understand io_uring’s submission/completion ring model
- Follow request flow from userspace SQE to CQE completion
- Learn key internals in `io_uring/io_uring.c`
- Build and run a minimal `liburing` read example

---

## 1. Why io_uring

Traditional syscall-per-I/O patterns can add overhead and limit async efficiency. `io_uring` provides shared ring buffers between userspace and kernel for high-performance async I/O submission/completion.

Core design goals:
- reduce syscall overhead
- support batched submission/completion
- provide flexible async operations beyond file I/O

---

## 2. SQ/CQ Ring Model

Two primary rings:
- **SQ (Submission Queue):** userspace posts SQEs (submission queue entries)
- **CQ (Completion Queue):** kernel posts CQEs (completion queue entries)

```text
userspace prepares SQE(s)
   -> submit to kernel
   -> kernel executes operation(s)
   -> kernel writes CQE(s)
   -> userspace consumes completion(s)
```

Each request can carry `user_data` to match completion back to request context.

---

## 3. Basic Request Lifecycle

High-level sequence:
1. `io_uring_queue_init()` to set up rings
2. `io_uring_get_sqe()` to acquire SQE slot
3. fill SQE (opcode, fd, buf, len, offset)
4. `io_uring_submit()` to notify kernel
5. `io_uring_wait_cqe()` (or poll/peek variants)
6. read CQE result (`cqe->res`)
7. `io_uring_cqe_seen()` and cleanup

---

## 4. Key Concepts

### `SQE` opcodes
Common ones:
- `IORING_OP_READV`
- `IORING_OP_WRITEV`
- `IORING_OP_READ`
- `IORING_OP_WRITE`
- `IORING_OP_FSYNC`

### Completion semantics
- `cqe->res >= 0`: success (bytes or op-specific result)
- `cqe->res < 0`: `-errno` style failure

### Batching
Multiple SQEs can be prepared and submitted together for throughput gains.

---

## 5. Relationship to Kernel Storage Path

`io_uring` is userspace-facing async submission infrastructure. After operations enter kernel I/O paths, they still interact with VFS/filesystem/page cache/block layer similarly to other read/write mechanisms.

So io_uring changes **submission/completion mechanics**, not fundamental filesystem/block semantics.

---

## 6. Minimal `liburing` Read Example

```c
#include <liburing.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    struct io_uring ring;
    struct io_uring_sqe *sqe;
    struct io_uring_cqe *cqe;
    char buf[4096];
    int fd, ret;

    memset(buf, 0, sizeof(buf));
    fd = open("/etc/hostname", O_RDONLY);
    if (fd < 0) return 1;

    if (io_uring_queue_init(8, &ring, 0) < 0) return 1;

    sqe = io_uring_get_sqe(&ring);
    io_uring_prep_read(sqe, fd, buf, sizeof(buf), 0);
    sqe->user_data = 1;

    ret = io_uring_submit(&ring);
    if (ret < 0) return 1;

    ret = io_uring_wait_cqe(&ring, &cqe);
    if (ret < 0) return 1;

    if (cqe->res >= 0) {
        write(STDOUT_FILENO, buf, cqe->res);
    }

    io_uring_cqe_seen(&ring, cqe);
    io_uring_queue_exit(&ring);
    close(fd);
    return 0;
}
```

Build/run:
```bash
gcc -O2 day23_io_uring_read.c -luring -o day23_io_uring_read
./day23_io_uring_read
```

---

## 7. Hands-On Exercises

### Exercise 1: Verify environment
```bash
uname -r
pkg-config --modversion liburing
```

### Exercise 2: Run minimal read example
```bash
./day23_io_uring_read
```

### Exercise 3: Compare sync read vs io_uring (simple)
```bash
# sync baseline
time cat /etc/hostname > /dev/null

# io_uring sample repeatedly
for i in $(seq 1 1000); do ./day23_io_uring_read > /dev/null; done
```

### Exercise 4: Batch submission experiment
```bash
# extend sample to queue multiple read SQEs before submit
# compare total runtime with single-SQE loop
```

### Exercise 5: Source navigation
```bash
grep -rn "io_submit_sqes\|io_uring_enter\|io_req_complete_post" io_uring/io_uring.c | head -40
```

---

## 8. Source Navigation Checklist

Primary:
- `io_uring/io_uring.c`

Supporting:
- `include/uapi/linux/io_uring.h`
- `fs/read_write.c` (for path comparison)

---

## 9. Common Pitfalls

1. Assuming io_uring always outperforms simpler APIs
   - gains depend on batching/concurrency and workload shape

2. Ignoring completion handling
   - forgetting `io_uring_cqe_seen()` can stall ring progress

3. Misinterpreting negative `cqe->res`
   - it is `-errno`, not bytes

4. Comparing tiny microbenchmarks only
   - real wins often appear under concurrent/batched workloads

---

## 10. Self-Check Questions

1. What are SQ and CQ in io_uring?
2. How do you correlate a completion to a request?
3. What does negative `cqe->res` mean?
4. Which kernel file is central for io_uring internals?
5. Why can batching SQEs improve performance?

## 11. Self-Check Answers

1. SQ holds submissions from userspace; CQ holds kernel completions.
2. Use `sqe->user_data` and read it back from corresponding CQE.
3. Operation failed; value is `-errno`.
4. `io_uring/io_uring.c`.
5. It amortizes submission overhead and improves pipeline utilization.

---

## 12. Tomorrow’s Preview: Day 24 — Direct I/O

Next we compare buffered I/O and `O_DIRECT`:
- when page cache is bypassed
- alignment constraints and caveats
- benchmark `O_DIRECT` vs buffered with `fio`.
