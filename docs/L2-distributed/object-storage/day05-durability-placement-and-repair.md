# Day 5: Durability, Placement, and Repair

## Learning objectives

- Compare replication with erasure coding.
- Distinguish acknowledged durability, availability, and eventual repair.
- Place shards across real failure domains.
- Reason about degraded reads, scrub, healing, and rebuild traffic.

## 1. Protection models

Replication stores complete copies:

```text
three replicas -> raw overhead approximately 3x
```

Erasure coding splits data into `k` data shards and computes `m` parity shards:

```text
logical data = k shards
stored data  = k + m shards
overhead     = (k + m) / k
```

Under the code's assumptions, any `k` available shards reconstruct the object,
so up to `m` missing shards can be tolerated. Real availability also depends on
where shards are placed, which nodes are reachable, and what quorum the
implementation requires for metadata and writes.

Replication is usually simpler for small updates and degraded reads. Erasure
coding reduces capacity overhead for large immutable data but uses more CPU,
network, and failure-domain width.

## 2. Acknowledgement is a contract

Ask exactly what a successful PUT means:

- how many data/parity fragments reached stable storage;
- whether metadata was committed;
- whether protection is full or temporarily degraded;
- whether remote replication is included;
- what happens after a power loss or process crash.

"Replicated" is insufficient. A system that acknowledges after a local write
and copies later has a different loss window from one that waits for a durable
quorum.

## 3. Failure-domain-aware placement

```text
bad:  D1 D2 P1 all on drives in one chassis
good: D1 D2 P1 separated across hosts or racks required by the policy
```

Device tolerance is not rack tolerance. Define the failure domain—drive, host,
rack, availability zone, or region—before selecting replica count or EC
geometry. Ensure the cluster has enough distinct domains to satisfy the rule
during both normal operation and maintenance.

## 4. Detection and repair

A complete durability loop is:

```text
checksum on write
    -> verify on read or scrub
    -> identify authoritative good shards/copies
    -> reconstruct or copy
    -> verify repaired data
    -> update health state
```

Checksums detect corruption; they do not repair it. Scrub finds cold corruption
that ordinary reads never touch. Repair needs spare capacity, network, disk
bandwidth, and a correct source of truth.

## 5. The rebuild danger window

After a failure, protection is reduced while the system:

1. detects and declares the component failed;
2. selects replacement placement;
3. reads surviving fragments;
4. transfers and reconstructs data;
5. verifies and commits the replacement.

A second correlated failure, operator mistake, or latent checksum error in this
window can turn an available object into data loss. Faster rebuild is useful
until it saturates foreground I/O and causes timeouts or retry storms.

Maintain capacity and performance headroom. A cluster at 95% utilization often
cannot recover safely even if its normal workload still fits.

## 6. Lab: controlled degraded operation

On a disposable cluster:

1. upload objects with stored checksums;
2. record placement and healthy-state metrics;
3. stop one storage process or remove one test drive;
4. measure PUT, GET, range GET, and LIST latency while degraded;
5. restore or replace the component;
6. observe healing bytes, queue depth, time to full protection, and client
   errors;
7. verify every object's checksum.

Repeat with foreground load. A repair benchmark with no client traffic hides
the scheduling tradeoff that matters in production.

## Failure patterns

- Counting disks rather than independent failure domains.
- Assuming `m` parity shards means any `m` failures anywhere are safe.
- Running without scrub and discovering latent corruption during rebuild.
- Filling the cluster so repair has no target space.
- Allowing unbounded client retries to compete with recovery traffic.
- Declaring recovery complete from process health rather than object health.

## Self-check

1. What does `(k+m)/k` measure?
2. Why does checksum coverage not guarantee durability?
3. When can `m` failures still cause an EC object to be unavailable?
4. Which metrics define the rebuild danger window?

## References

- [Ceph erasure coding](https://docs.ceph.com/en/latest/rados/operations/erasure-code/)
- [Ceph placement groups](https://docs.ceph.com/en/latest/rados/operations/placement-groups/)
- [Ceph scrub](https://docs.ceph.com/en/latest/rados/configuration/osd-config-ref/#scrubbing)
- [MinIO erasure coding](https://docs.min.io/aistor/operations/core-concepts/erasure-coding/)

---

## Previous / Next

[← Previous: Day 4 — Metadata indexes and small objects: sharding, LIST fan-out, and hotspots](day04-metadata-indexes-and-small-objects.md) | [Object-storage study index](README.md) | [Next: Day 6 — Security and tenancy: IAM, policies, encryption, quotas, and audit →](day06-security-tenancy-and-encryption.md)
