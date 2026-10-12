# Day 8: Multisite Replication and Disaster Recovery

## Learning objectives

- Distinguish local durability from geographic disaster recovery.
- Translate replication behavior into RPO and RTO.
- Design failover, write fencing, conflict handling, and failback.
- Prove recovery with data validation rather than endpoint health.

## 1. Local protection is not geographic recovery

Replicas or EC shards in one cluster protect against selected local failures.
They do not protect against credentials deleting every copy, a bad lifecycle
rule, software corruption, or loss of the site.

```text
zone A accepts PUT
   |
   +-> local durable acknowledgement
   |
   `-> replication log -> network -> zone B apply
                              ^
                         lag and backlog
```

Many multisite systems replicate asynchronously. A successful write in zone A
can be durable locally but absent from zone B for a measurable interval.

## 2. RPO and RTO

- **RPO** is the acceptable amount of recently acknowledged data that recovery
  can lose.
- **RTO** is the acceptable time to restore useful service.

Do not set both to zero by aspiration. Derive them from the replication and
failover mechanism.

Useful evidence includes oldest unsynchronized change, bytes/operations
backlogged, apply rate, object validation results, DNS or routing convergence,
and the time required to restore identity and KMS dependencies.

## 3. Failover needs write fencing

Failing traffic to zone B while zone A might still accept writes can create two
independent histories:

```text
zone A: key K -> version A2
zone B: key K -> version B2
```

Before promotion:

1. determine whether the old writer is truly unavailable;
2. fence or revoke its write path;
3. measure replication lag and choose the recovery point;
4. promote the destination according to the product workflow;
5. restore identity, policy, encryption keys, and application dependencies;
6. validate known objects and manifests;
7. route clients.

Define conflict policy before a split occurs. Last-writer-wins is dangerous
when clocks differ and does not preserve business intent.

## 4. Failback is a separate migration

After the original site returns, do not simply flip DNS back. First reconcile
changes created at the recovery site, re-establish replication direction,
wait for convergence, validate data, fence the temporary writer, and only then
move clients.

Version identifiers, ETags, replication markers, and retention state may not
be portable between independent implementations. Test the exact topology.

## 5. Backup remains necessary

Replication rapidly copies valid writes—and can rapidly copy valid but
destructive requests. Versioning can help with accidental overwrite, but it
shares administrative and capacity failure domains with the service.

An independent recovery copy should have:

- separate credentials and preferably separate administration;
- retention that the primary writer cannot shorten;
- a known restore procedure and catalog;
- periodic checksum and manifest validation;
- tested bandwidth and time to restore.

## 6. Lab: disaster-recovery tabletop

Prepare ten immutable objects and a manifest, then walk through:

1. pause or block replication;
2. write three more objects in the primary zone;
3. measure which generation exists remotely;
4. declare the primary unavailable;
5. record the chosen RPO and why;
6. fence the old primary;
7. promote and validate the remote manifest;
8. write a new recovery-site generation;
9. restore the old site and practice failback.

Capture timestamps for detection, decision, promotion, identity/KMS recovery,
validation, routing, and resumed application writes. Those intervals explain
the real RTO.

## Failure patterns

- Advertising zero RPO with asynchronous replication.
- Promoting a destination without fencing the old writer.
- Monitoring current lag but not the age of the oldest pending change.
- Restoring data but forgetting identities, policies, DNS, or encryption keys.
- Treating replication or versioning as an independent backup.
- Never testing failback.

## Self-check

1. Which acknowledged writes are inside the RPO window?
2. Why can two active writers create irreconcilable state?
3. What must be restored besides payload data?
4. Why is failback not merely another DNS change?

## References

- [Ceph RGW multisite](https://docs.ceph.com/en/latest/radosgw/multisite/)
- [Ceph RGW multisite sync policy](https://docs.ceph.com/en/latest/radosgw/multisite-sync-policy/)
- [Amazon S3 replication](https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication.html)
- [Amazon S3 disaster-recovery guidance](https://docs.aws.amazon.com/prescriptive-guidance/latest/backup-recovery/s3.html)

---

## Previous / Next

[← Previous: Day 7 — Ceph RGW, MinIO, and SeaweedFS architecture comparison](day07-ceph-minio-seaweedfs.md) | [Object-storage study index](README.md) | [Next: Day 9 — Observability and performance: metrics, benchmarking, capacity, and diagnosis →](day09-observability-benchmarking-capacity.md)
