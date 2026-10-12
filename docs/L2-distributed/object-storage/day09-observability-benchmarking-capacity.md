# Day 9: Observability, Benchmarking, and Capacity

## Learning objectives

- Build an object-storage signal map from client to media.
- Design benchmarks that represent a workload rather than one headline number.
- Separate throughput saturation from metadata, gateway, or retry bottlenecks.
- Include protection, versions, repair reserve, and growth in capacity plans.

## 1. Observe every layer

```text
client -> DNS/LB -> gateway -> auth/policy -> metadata/index
                                      \-> data placement -> devices
                                      \-> replication/repair
```

| Layer | Useful signals |
|-------|----------------|
| Client | operation latency, retry count, timeout, bytes, concurrency |
| Load balancer | active connections, TLS time, resets, backend health |
| Gateway | requests by operation/status, queueing, CPU, memory, network |
| Metadata/index | lookup and LIST latency, shard load, resharding, cache misses |
| Storage | device latency, queue depth, utilization, checksum errors |
| Protection | degraded objects, missing shards, repair bytes and ETA |
| Multisite | oldest pending change, backlog, apply errors and throughput |

Aggregate success rate can hide a failed tenant or prefix. Conversely, labels
containing full object keys can make the monitoring system unusable. Preserve
bucket/tenant/operation visibility with controlled cardinality.

## 2. Benchmark matrix

At minimum vary:

- object size: tiny, representative median, large, and checkpoint-scale;
- operation mix: PUT, GET, range GET, HEAD, LIST, DELETE;
- concurrency and connection reuse;
- sequential, random, hot-key, and broad-key distributions;
- TLS, authentication, checksums, and encryption as deployed;
- replicated versus EC storage;
- healthy, degraded, repairing, and multisite-backlogged states;
- cold and warm caches.

Report p50, p95, p99, and maximum latency with throughput and error/retry rate.
An average hides pauses that starve GPUs or violate request deadlines.

## 3. Find the saturation point

Increase offered load gradually:

```text
useful throughput rises
        -> one resource saturates
        -> queueing and p99 rise
        -> timeouts trigger retries
        -> useful throughput may fall
```

The best operating point is usually before the cliff. Record gateway CPU,
network, metadata latency, storage-device latency, and client retry rate for
each step. More clients cannot fix a saturated backend.

## 4. Capacity model

Start with logical live data, then include:

```text
raw required =
  live logical bytes
  x replica/EC overhead
  x version and retention multiplier
  x metadata/allocation multiplier
  + incomplete multipart and garbage backlog
  + repair/rebalance reserve
  + forecast growth before the next expansion
```

Also model request capacity. Ten petabytes of large archives and ten
petabytes of 8 KiB objects demand radically different metadata, CPU, and
operations budgets.

Set a safe high-water mark that leaves room to rebuild after the largest
supported failure. Capacity available during healthy operation is not all
sellable capacity.

## 5. Lab: reproducible benchmark record

For a disposable endpoint, create a result sheet containing:

```text
software versions and configuration
node, CPU, memory, NIC, drive, and topology
bucket protection and encryption
object size and key distribution
operation mix and duration
client count, concurrency, and connection reuse
p50/p95/p99/max, throughput, errors, retries
gateway, metadata, network, drive, and repair signals
```

Run a baseline, then repeat with one storage component unavailable and healing
active. Keep the workload definition identical. The difference is more useful
than comparing your result with an unrelated public benchmark.

Tools may include MinIO Warp, COSBench, or a small SDK workload generator.
Read the tool's generated workload before trusting its label such as "mixed."

## 6. Diagnostic examples

- High gateway CPU, low device latency: authentication, TLS, checksums, or
  request parsing may be limiting.
- High LIST latency, normal GET: bucket-index fan-out or metadata hot shards.
- Healthy media, rising client p99: load balancer, connection churn, or retries.
- Good foreground latency, repair ETA increasing: recovery is starved.
- High bytes but GPU stalls: object layout, range-read pattern, or client
  preprocessing may be wrong despite storage throughput.

## Failure patterns

- Reporting only aggregate MiB/s.
- Benchmarking without TLS or encryption used in production.
- Comparing different object sizes as if they were the same workload.
- Running for seconds and missing compaction, scrub, or cache effects.
- Filling to nominal capacity with no repair reserve.
- Alerting on replica count but not oldest replication lag.

## Self-check

1. Which signals distinguish gateway saturation from drive saturation?
2. Why must error and retry rates accompany throughput?
3. What multipliers turn logical bytes into required raw capacity?
4. Which degraded-state benchmark is most relevant to your availability claim?

## References

- [Ceph RGW metrics](https://docs.ceph.com/en/latest/radosgw/metrics/)
- [Ceph health monitoring](https://docs.ceph.com/en/latest/rados/operations/monitoring/)
- [MinIO metrics and alerts](https://docs.min.io/aistor/operations/monitoring/metrics-and-alerts/)
- [MinIO Warp benchmark tool](https://github.com/minio/warp)
- [COSBench repository](https://github.com/intel-cloud/cosbench)

---

## Previous / Next

[← Previous: Day 8 — Multisite and disaster recovery: lag, RPO/RTO, failover, and conflicts](day08-multisite-replication-and-dr.md) | [Object-storage study index](README.md) | [Next: Day 10 — AI data and checkpoints: sharding, range reads, caches, and atomic publication →](day10-ai-data-and-checkpoint-patterns.md)
