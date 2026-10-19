# Day 8: Monitoring and Performance

## Learning objectives

- Build monitoring from dm status and LVM metrics.
- Correlate pool pressure with application latency.
- Understand chunk-size, fragmentation, metadata, and snapshot costs.
- Define alerts that lead to actionable runbooks.

## 1. Minimum observability

```bash
lvs -a -o \
name,attr,size,pool_lv,origin,data_percent,metadata_percent,seg_monitor,devices

dmsetup info -c
dmsetup status vg-pool-tpool
dmsetup table vg-pool-tpool
dmsetup ls --tree
```

Collect:

- pool Data% and Meta%;
- remaining bytes/blocks and recent consumption rate;
- target mode: `rw`, `ro`, `out_of_data_space`, or `Fail`;
- `needs_check`;
- discard and no-space policy;
- thin mapped sectors;
- dm event number and LVM monitoring state;
- metadata/data-device latency and errors;
- application p95/p99 I/O latency.

Do not scrape device names only. Preserve stable VG/LV/pool identity across dm
minor-number changes.

## 2. Alert progression

A useful policy has multiple stages:

```text
warning: investigate growth and confirm autoextend reserve
urgent: automatic extension must have completed
critical: stop new provisioning/writes before exhaustion
emergency: execute tested recovery/fencing procedure
```

Thresholds depend on allocation rate and extension latency. Meta% often needs a
separate, more conservative threshold because metadata failure can force
offline repair.

Alert on failed autoextension, disabled monitoring, lack of VG free extents,
and rising time-to-exhaustion risk—not only raw percentages.

## 3. Performance costs

First writes to unmapped chunks allocate and update metadata. Writes that
diverge shared snapshot blocks allocate new chunks and update sharing state.
A metadata device with high latency can therefore limit small random writes
even when the data device is fast.

Fragmentation grows when thin devices allocate interleaved chunks and diverge
through snapshots. Sequential logical I/O can become scattered physical I/O.

Large chunks reduce metadata but amplify small writes and snapshot divergence.
Small chunks reduce amplification but increase metadata operations. There is no
universal best size.

## 4. Snapshot workload effects

Snapshot creation is cheap, not free:

- metadata roots/device details must be committed;
- later writes retain old blocks and allocate new ones;
- deletes may not reclaim shared blocks;
- more active divergent devices increase working-set and metadata pressure;
- backup readers compete with production I/O.

Snapshot depth alone does not impose classic chain lookup cost, but snapshot
count, churn, retained data, and fragmentation remain operational costs.

## 5. Flush and latency

dm-thin metadata commits on FLUSH/FUA and periodically otherwise. Sync-heavy
workloads can expose metadata commit latency. Test with the same durability
flags as production; a benchmark omitting fsync/FUA measures a different
contract.

When Device Mapper is stacked, inspect latency at:

```text
application -> filesystem -> thin -> cache/crypt/multipath -> physical device
```

High top-level latency with low device latency suggests queueing or metadata
work above the media.

## 6. Lab: snapshot amplification

On a disposable pool:

1. measure 4 KiB random-write latency and pool growth without snapshots;
2. create one snapshot;
3. overwrite the same logical working set;
4. compare physical Data% growth and Meta% growth;
5. add several snapshots at controlled points;
6. repeat while monitoring `_tmeta` and `_tdata` device latency;
7. remove snapshots one at a time and observe reclaim.

Keep logical bytes written identical between runs.

## Failure patterns

- Alerting only at 100%, when recovery time is already gone.
- Ignoring allocation velocity.
- Monitoring data space but not metadata space.
- Benchmarking without sync semantics used by production.
- Calling snapshot creation "zero cost."
- Blaming the SSD while `_tmeta` or an upper dm queue is saturated.
- Using high-cardinality per-device labels without lifecycle cleanup.

## Self-check

1. Which fields indicate a pool is unsafe even below 100%?
2. Why can snapshot divergence amplify physical writes?
3. How does chunk size trade metadata for allocation amplification?
4. Which measurement distinguishes media latency from dm queueing?

## References

- [Kernel thin-pool status format](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/thin-provisioning.html#status)
- [Device Mapper statistics](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/statistics.html)
- [LVM thin-pool monitoring and autoextension](https://man7.org/linux/man-pages/man7/lvmthin.7.html)

---

## Previous / Next

[← Previous: Day 7 — Capacity and ENOSPC: Data%, Meta%, discard, autoextension, queueing, and errors](day07-capacity-discard-and-enospc.md) | [Device Mapper study index](README.md) | [Next: Day 9 — Metadata recovery: live metadata snapshots, checking, dumping, repair, and validation →](day09-metadata-check-repair-and-recovery.md)
