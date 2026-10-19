# Day 7: Thin-Pool Capacity, Discard, and ENOSPC

## Learning objectives

- Distinguish filesystem free space, thin-LV mappings, pool Data%, and Meta%.
- Understand when deletion returns physical blocks.
- Configure autoextension with enough reaction time and VG reserve.
- Explain queue-versus-error behavior and metadata exhaustion.

## 1. Four different capacity views

```text
df free space          filesystem allocation view inside one thin LV
thin mapped blocks     physical chunks mapped to that thin device
pool Data%             shared _tdata consumption by all thin devices
pool Meta%             mapping/space-map metadata consumption
```

A 100 GiB thin LV can report 80 GiB free while its 10 GiB pool is nearly full.
Conversely, deleting a file changes `df` immediately but pool Data% falls only
after the filesystem issues discard for whole releasable chunks.

Snapshots retain shared chunks even after the origin discards them.

## 2. Discard modes

The pool can:

- process discards and pass them to underlying data storage;
- process discards in pool metadata but not pass them down
  (`no_discard_passdown`);
- ignore discards (`ignore_discard`).

Removing the thin mapping is what returns a chunk to the pool. Passing discard
down may additionally inform SSD or sparse lower storage. These are different
effects.

`fstrim` can release unused filesystem ranges, but sub-chunk free regions,
still-referenced snapshot blocks, and ignored discards cannot be reclaimed.

## 3. Autoextension

Monitor both metrics:

```bash
lvs -o name,data_percent,metadata_percent,seg_monitor vg/pool
```

LVM can use `dmeventd` and these settings:

```text
activation/thin_pool_autoextend_threshold
activation/thin_pool_autoextend_percent
```

The threshold must provide time to detect the event, allocate VG extents,
reload the pool, and absorb peak writes. Autoextension cannot work without
free extents in the VG.

A percentage-only alert is insufficient. Also calculate time to exhaustion:

```text
remaining bytes / recent allocation rate
```

A pool consuming 1% per minute and one consuming 1% per day need different
responses.

## 4. Data exhaustion

The thin-pool target can queue writes while waiting for extension or return
errors with `error_if_no_space`. Kernel documentation describes a
`no_space_timeout` for queued I/O.

Queueing may give automation time to extend, but blocked storage can freeze
applications and propagate timeouts through an entire stack. Returning errors
fails faster but filesystems and applications must handle ENOSPC/EIO safely.
Choose and test the policy deliberately.

Read status for `out_of_data_space`, then extend the data LV/pool and verify
I/O recovery. Do not assume adding virtual size to a thin LV adds physical pool
capacity.

## 5. Metadata exhaustion

Metadata full or a metadata operation failure is more severe. The target can
set `needs_check`, error I/O, and require the pool to be taken offline and
checked/repaired. Because upper layers may have seen completions around an
aborted metadata transaction, check filesystems or applications after pool
repair as the kernel documentation recommends.

Extend metadata before 100%:

```bash
lvextend --poolmetadatasize +1G vg/pool
```

Exact support and syntax depend on the installed LVM version and available VG
space.

## 6. Lab: observe reclaim

On the Day 6 disposable pool:

1. record Data% and Meta%;
2. create a file larger than several pool chunks;
3. snapshot the thin LV;
4. delete the file from the origin and run `fstrim`;
5. observe that snapshot references keep old chunks allocated;
6. remove the snapshot;
7. run `fstrim` again and observe reclaim;
8. record chunk-size effects.

Do not intentionally reach 100% until Day 10's isolated failure lab.

## Failure patterns

- Alerting on `df` but not pool Data% and Meta%.
- Enabling autoextend with no free VG extents.
- Setting a threshold too high for peak allocation rate.
- Assuming file deletion immediately returns chunks.
- Forgetting snapshot-pinned blocks.
- Treating metadata exhaustion as ordinary filesystem ENOSPC.
- Queueing indefinitely and causing fleet-wide application hangs.

## Self-check

1. Why can `df` show free space while the pool is full?
2. What is the difference between reclaiming a pool mapping and passing discard down?
3. Why does autoextension require VG reserve?
4. Why must upper layers be checked after metadata repair?

## References

- [Kernel dm-thin space-exhaustion behavior](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/thin-provisioning.html#updating-on-disk-metadata)
- [Kernel thin-pool target reference](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/thin-provisioning.html#thin-pool-target)
- [LVM thin-pool data, metadata, and autoextension](https://man7.org/linux/man-pages/man7/lvmthin.7.html)

---

## Previous / Next

[← Previous: Day 6 — LVM thin-snapshot lab: create, diverge, inspect, and remove thin volumes](day06-lvm-thin-snapshot-lab.md) | [Device Mapper study index](README.md) | [Next: Day 8 — Monitoring and performance: status, events, fragmentation, and snapshot workload cost →](day08-monitoring-and-performance.md)
