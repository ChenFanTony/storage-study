# Day 20: ext4 — Extents & Delayed Allocation

## Learning Objectives
- Understand ext4 extent-based block mapping
- Learn how delayed allocation (`delalloc`) works in ext4
- Understand why delayed allocation helps reduce fragmentation
- Inspect extent layout with `filefrag`

---

## 1. Why Extents

Older block mapping schemes tracked many individual block pointers. ext4 uses **extents** to represent contiguous block ranges compactly.

An extent represents:
- starting logical file block
- starting physical disk block
- length (number of contiguous blocks)

Benefits:
- lower metadata overhead for large contiguous files
- faster mapping operations in many common cases
- better scalability for large files

---

## 2. Extent Tree Model

ext4 stores extents in an inode-rooted tree.

Conceptual structure:

```text
inode
 └─ extent header
     ├─ leaf extents (small/simple files)
     └─ internal index nodes -> leaf nodes (larger/more fragmented files)
```

Leaf entries map logical file ranges to physical ranges.

When files grow or fragmentation increases, ext4 may split/add extent nodes.

---

## 3. Delayed Allocation (`delalloc`)

With delayed allocation, ext4 can defer physical block assignment for buffered writes.

High-level behavior:
1. Application writes data
2. Data lands in page cache and is marked dirty
3. Physical block choice is deferred
4. During writeback, ext4 allocates blocks with better global view

Why this helps:
- allocator sees larger write patterns
- more chance to allocate contiguous extents
- reduced fragmentation compared to immediate small allocations

---

## 4. Write Path (Simplified)

```text
write()
  -> page cache dirtying
  -> ext4 marks delayed allocation state

later writeback:
  -> choose physical blocks
  -> convert delayed extents to real extents
  -> submit I/O
```

So “logical write now, physical placement later” is the core idea.

---

## 5. Trade-offs of Delayed Allocation

Pros:
- better extent contiguity
- potentially improved sequential performance
- reduced metadata churn from tiny immediate allocations

Trade-offs:
- exact on-disk placement happens later, not at write() time
- behavior depends on writeback timing and available free space
- under heavy pressure or fragmentation, outcomes can vary

---

## 6. Extents and Fragmentation

Fragmentation means file blocks are spread across many non-contiguous extents.

You can often estimate fragmentation by counting extent entries:
- fewer, larger extents → generally more contiguous
- many small extents → fragmented layout

Delayed allocation tends to improve this when workload patterns are friendly (e.g., larger sequential buffered writes).

---

## 7. Hands-On Exercises

### Exercise 1: Create a test ext4 volume
```bash
# Use loop/test device only
sudo mkfs.ext4 /dev/loop2
sudo mkdir -p /mnt/ext4test
sudo mount /dev/loop2 /mnt/ext4test
```

### Exercise 2: Create a large file with buffered write
```bash
dd if=/dev/zero of=/mnt/ext4test/buf-file.bin bs=1M count=512 status=progress
sync
```

### Exercise 3: Inspect extents with filefrag
```bash
filefrag -v /mnt/ext4test/buf-file.bin
```

Look at extent count and logical/physical mapping ranges.

### Exercise 4: Compare with fragmented write pattern
```bash
# Example: random-write workload
fio --name=frag --filename=/mnt/ext4test/rand-file.bin --size=512M \
    --rw=randwrite --bs=4k --iodepth=32 --ioengine=libaio --direct=0
sync
filefrag -v /mnt/ext4test/rand-file.bin
```

Compare extent count with sequential case.

### Exercise 5: Observe delayed allocation influence
```bash
# Write many small buffered appends before sync
for i in $(seq 1 10000); do echo "x" >> /mnt/ext4test/log.txt; done
sync
filefrag -v /mnt/ext4test/log.txt
```

### Exercise 6: Source navigation
```bash
grep -rn "ext4_ext_map_blocks\|ext4_ext_insert_extent" fs/ext4/extents.c | head -30
grep -rn "delalloc\|delayed" fs/ext4/ | head -40
```

---

## 8. Source Navigation Checklist

Primary:
- `fs/ext4/extents.c`
- `fs/ext4/inode.c`

Supporting:
- `fs/ext4/ialloc.c`
- `fs/ext4/mballoc.c` (multiblock allocator behavior)

---

## 9. Common Pitfalls

1. Assuming write() immediately finalizes disk block layout
   - with delayed allocation, physical mapping can be deferred

2. Interpreting one `filefrag` output as universal truth
   - extent layout depends on free space state and workload timing

3. Ignoring `sync` before measuring on-disk extents
   - dirty data may not have been fully materialized yet

4. Testing on busy production mounts
   - competing allocation activity can distort results

---

## 10. Self-Check Questions

1. What does an ext4 extent represent?
2. Why does delayed allocation often reduce fragmentation?
3. At what stage are physical blocks typically chosen with `delalloc`?
4. Which tool is commonly used to inspect extent layout?
5. Which source file is central to ext4 extent operations?

## 11. Self-Check Answers

1. A contiguous mapping from logical file blocks to physical disk blocks with a length.
2. Allocation is deferred so ext4 can choose larger contiguous ranges with more context.
3. During writeback (not necessarily at write() call time).
4. `filefrag`.
5. `fs/ext4/extents.c`.

---

## 12. Tomorrow’s Preview: Day 21 — XFS or Btrfs Deep Dive

Next: choose one advanced filesystem track:
- XFS path: AG model, allocator B+trees, log design
- Btrfs path: CoW B-trees, snapshots, checksums, send/receive.
