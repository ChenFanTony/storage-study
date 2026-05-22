# Review Summary: Linux Storage Study Materials (Days 1–14)

I went through all 14 files. Below are the issues found, ranked by severity.
**Corrected versions of all 14 files are in this directory** alongside this summary.

The fixes range from material errors (broken lab commands, wrong kernel versions)
down to small wording cleanups. I kept the user's content and structure intact
and only changed what was actually wrong or unclear.

---

## Critical errors (would break things or teach wrong facts)

### Day 1 — Two factual errors

1. **Kyber kernel version is wrong.**
   - Document said: `kyber added for low-latency NVMe; none now default for NVMe | 5.x`
   - Reality: Kyber was merged in **4.12** (2017). Split into two table rows
     in the fix.

2. **`read_folio` replaces `readpage`, not `read_pages`.**
   - Document said: `read_folio replace read_pages in older kernels`
   - Reality: `->read_folio` replaced `->readpage` (single-page miss). The
     multi-page op was `->readpages`, and it was replaced by `->readahead`
     (different conversion, different release). Rewrote the prose paragraph
     and cleaned up the broken-English worksheet answers.

### Day 3 — The blktrace awk parser is wrong

Section 7 had:
```bash
awk '/D / {d[$6]=$1} / C / {if($6 in d) printf "lat=%.6f\n", $1-d[$6]}'
```

`blkparse` columns are: `device CPU seqno time PID action RWBS sector + nrsec`.
**Field 6 is the action character, not the sector**, and **field 4 is the
timestamp, not field 1**. The script silently produces garbage. Fixed to
key by sequence number (`$3`) and use `$4` as the time.

### Day 5 — Self-check answer #6 was contradictory

> Raise bcache sequential_cutoff below your scan I/O size — sequential reads
> above cutoff bypass the SSD entirely.

Sequential I/O **above** the cutoff bypasses. To make a scan bypass, the
cutoff must be **below** the scan I/O size. The verb should be "set" or
"lower", not "raise". Rewritten with concrete examples.

### Day 11 — Manual dm-cache `dmsetup` example was broken

Section 6 had:
```bash
echo "0 $CACHE_SIZE cache-pool $META $SSD $CACHE_BLOCK 0 smq 0" | dmsetup create cache_pool
```

Two issues:
1. **There is no `cache-pool` target in dm-cache.** `cache-pool` is dm-thin
   terminology. The dm-cache target is just called `cache`.
2. **Argument order is wrong.** The kernel docs specify:
   `cache <metadata dev> <cache dev> <origin dev> <block size>
    <#feature args> [<feature arg>]* <policy> <#policy args> [<policy arg>]*`

The lvconvert example also combined pool creation and attachment into one
invocation; that's not how LVM works. Rewrote with the standard two-step flow:
```bash
lvconvert --type cache-pool --poolmetadata vg_data/cache_meta vg_data/cache_data
lvconvert --type cache --cachepool vg_data/cache_data vg_data/data_lv
```

### Day 12 — Lab section wouldn't run

Section 8 had multiple issues that mean nobody following the lab would succeed:

1. **`thin_pool_format` does not exist.** Replaced with the canonical approach:
   zero the metadata superblock area with `dd`.
2. **Missing `dmsetup message ... create_thin <id>` calls.** Activating a
   thin LV is a two-step process: first send a message to allocate the
   dev-id, then load the `thin` target table that references it.
3. **The snapshot table line had an extra parameter.** The doc had
   `thin /dev/mapper/test_pool 2 1` — the trailing `1` would be interpreted
   as an external origin **device path**, not an origin dev-id. Internal
   snapshots use just `thin <pool> <dev_id>`; the `create_snap` message
   carries the origin dev-id.

### Day 13 — Same dm-thin lab errors as Day 12

Section 4 reused the broken setup. Applied the same fixes.

---

## Worth noting; fixed in passing

### Day 1 — Worksheet answers

The user's own answers had grammatical issues ("folio is lager page", "good
for fragile in page") but the underlying technical points were roughly
correct. I rewrote them to be cleaner and more accurate where the meaning
was ambiguous, while keeping the same intent. Treat the rewrite as a
reference answer; the raw notes are fine.

### Day 2 — `cat /sys/.../mq/*/nr_tags`

Wildcard expansion works (cat handles multiple files) but the parenthetical
"`*` is the hardware ctx mapping to CPU" was confusing. Replaced with an
explicit per-queue loop.

### Day 4 — Flusher tracepoint

The bpftrace example used `kprobe:wb_writeback` and dereferenced
`((struct bdi_writeback *)arg0)->bdi->dev_name`. That works if the field
name happens to match your kernel, but it's brittle across versions.
Replaced with the stable `tracepoint:writeback:writeback_start` instead,
which exposes `args->name` and `args->reason` directly.

### Day 6 — `io.weight` without bfq

Document said: `io.weight requires bfq OR is best-effort only`.

This was incomplete. Since kernel 5.4, `io.weight` works on any scheduler
via the **blk-iocost** cost-model controller. It does not require BFQ.
Updated the cgroup interaction section to make this explicit.

### Day 7 — Local NVMe latency

`local NVMe's ~50µs` was a bit high for modern hardware (10–30µs at low
queue depth is more typical). The math (concurrency = throughput × latency)
was already correct; just updated the example numbers and made the
Little's Law reference explicit. Bumped the recommended target up to
match the formula (32 minimum → 64–128 with headroom).

### Day 8 — sysfs path note

`cache/*/freelist_percent` exists on some kernels but is mainly a testing
knob. The more useful signal for "is GC keeping up" is
`cache_available_percent`. Clarified what each path tells you.

### Day 9

Marked the `umount -l` simulation as a "soft" crash, since a lazy unmount
isn't really a crash. The real test is sysrq-trigger; called this out
explicitly.

### Day 10

Added a hedge to the "~150–200K IOPS" contention threshold — there's no
hard cutoff; it depends on CPU, NUMA layout, and workload. Encouraged
measurement rather than treating the number as a fact.

### Day 14 — dm-thin metadata sizing

Document recommended a 32GB dm-thin metadata device. dm-thin has a **hard
16GB limit**; anything beyond is wasted (the kernel emits a warning at
creation). Updated the reference answer to use 16GB and noted what to do
if the math suggests you'd need more (reduce snapshot retention, increase
data block size).

---

## Files produced

All 14 days plus this summary are in this directory:

```
REVIEW_SUMMARY.md
day01-storage-stack-gap-fill.md
day02-blk-mq-internals.md
day03-blk-mq-scheduler-plug.md
day04-writeback-thresholds.md
day05-readahead-tiering.md
day06-io-schedulers-architect.md
day07-week1-review.md
day08-bcache-gc-ssd-wear.md
day09-bcache-failure-semantics.md
day10-bcache-limitations.md
day11-dm-cache-architecture.md
day12-dm-thin-metadata.md
day13-tiering-failure-semantics.md
day14-week2-review.md
```

Days 1, 3, 5, 11, 12, 13, 14 had the critical errors and are the ones to
re-read carefully. Days 2, 4, 6, 7, 8, 9, 10 only have small cleanups —
you can compare them against your originals with `diff` if you want to
see exactly what changed.
