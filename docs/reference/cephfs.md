# CephFS — Architect Reference for AI Storage

CephFS provides a shared POSIX namespace over RADOS. It is useful when training
frameworks, checkpoint libraries, and operators need normal paths and file
operations, but its metadata behavior must be designed as carefully as its
aggregate data bandwidth.

Related: [Ceph reference index](ceph.md),
[Ceph object storage](ceph-object-storage.md), and
[AI training data pipelines](../L3-ai-storage/training-data-reference.md).

---

## 0. Terminology

| Term | Meaning |
|------|---------|
| MDS | Metadata Server; owns namespace metadata, locks, capabilities, and journals |
| MDS rank | One active metadata partition of a CephFS file system |
| Capability (cap) | MDS-issued authority allowing a client to cache or operate on an inode |
| Metadata pool | Replicated RADOS pool containing filesystem metadata and MDS journals |
| Data pool | RADOS pool containing file contents as objects |
| File layout | Mapping from file offsets to RADOS pool, namespace, stripes, and object size |
| Directory fragment | A partition of a large or busy directory's entries |
| Subtree partition | A directory subtree assigned to an active MDS rank |
| Kernel client | In-kernel CephFS mount, normally the high-performance Linux client |
| ceph-fuse | User-space FUSE client, useful when kernel-client deployment is unsuitable |

---

## 1. Architecture and I/O Path

CephFS separates metadata control from file-data transfer:

```text
Application
    |
    v
CephFS client
    |
    +-- open/stat/readdir/rename ----------> MDS rank
    |                                        - namespace
    |                                        - inode metadata
    |                                        - locks and capabilities
    |
    `-- read/write file bytes ------------> primary OSD
                                             |
                                             +--> replica OSDs
                                             `--> BlueStore devices
```

The MDS is not a proxy in the steady-state data path. After a client obtains the
required inode capabilities and layout information, it maps file offsets to
RADOS objects and communicates directly with OSDs.

### Read flow

```text
1. Client resolves the path through an MDS.
2. MDS grants suitable read/cache capabilities.
3. Client maps the requested offset through the file layout.
4. Client calculates the target RADOS object and placement group.
5. Client reads data directly from the acting OSD set.
6. Client may satisfy later reads from its page cache while its caps permit.
```

### Write flow

```text
1. Client obtains write/buffer capabilities from the MDS.
2. Client buffers data or maps it directly to file-data objects.
3. OSD primary replicates or erasure-codes the write according to the data pool.
4. Client receives RADOS acknowledgements.
5. fsync()/fdatasync() flushes the required data and metadata for durability.
6. MDS journals namespace changes so failover can replay them consistently.
```

Capabilities make client caching fast, but they also create coordination work.
When another client needs conflicting access, the MDS recalls caps from the
current holder. Slow, disconnected, or overloaded clients can therefore delay
metadata progress.

---

## 2. Metadata Scaling

One active MDS rank is the default. Multiple active ranks can divide the
namespace into subtrees, and very large or busy directories can be fragmented.

```text
MDS rank 0: /datasets/public
MDS rank 1: /checkpoints/team-a
MDS rank 2: /checkpoints/team-b

Clients still see one POSIX namespace.
```

Multiple active MDS ranks help when many clients work in separable directories.
They do not guarantee that a single serial namespace workload becomes faster.
Directory pinning or carefully enabled balancing can provide more predictable
placement than assuming the balancer will immediately fix every hotspot.

### AI metadata pressure

| Pattern | Effect |
|---------|--------|
| Millions of individual samples | Large inode/dentry working set and frequent cap recalls |
| Every worker recursively lists the same tree | MDS and client-cache pressure |
| All ranks create files in one directory | Hot directory fragments and lock contention |
| Large immutable shard files | Few metadata operations and efficient sequential reads |
| Per-job or per-rank subdirectories | Easier subtree distribution and cleanup |

For training data, packing samples into tar, Parquet, MDS, or another shard
format usually improves both CephFS metadata efficiency and application
prefetching.

### Availability is different from scale

- **Active MDS ranks** divide live metadata work.
- **Standby MDS daemons** can replace a failed rank.
- **Standby-replay** follows one active rank's journal for faster takeover, but
  that daemon is dedicated to that rank.

Provision standbys even when only one active rank is needed. Adding active
ranks without standby capacity can improve scale while weakening failover
coverage.

---

## 3. File Layout and Pool Selection

A CephFS file is divided into RADOS objects. Its layout specifies:

- data pool and optional RADOS namespace;
- object size;
- stripe unit;
- stripe count.

Directory layout values are inherited by newly created descendants. This makes
top-level AI workload directories a natural policy boundary:

```text
/datasets/hot       -> replicated NVMe data pool
/datasets/archive   -> erasure-coded capacity pool
/checkpoints        -> high-throughput data pool
/users              -> general-purpose pool
```

Example inspection and assignment:

```bash
# Inspect the inherited directory layout.
getfattr -n ceph.dir.layout /mnt/cephfs/datasets

# Make an existing CephFS data pool available to the filesystem.
ceph fs add_data_pool cephfs cephfs_data_ec

# New files below this directory inherit the selected pool.
setfattr -n ceph.dir.layout.pool -v cephfs_data_ec \
    /mnt/cephfs/datasets/archive
```

Use a replicated pool for CephFS metadata. A data pool may be replicated or
erasure-coded when configured for the required overwrite behavior. Erasure
coding improves capacity efficiency but increases failure-domain width,
recovery work, and small-update cost.

Do not change stripe or object parameters merely because a workload uses large
files. Client concurrency, queue depth, pool PG layout, network capacity, and
OSD media often matter more; benchmark before deviating from supported
defaults.

---

## 4. Consistency, Durability, and Checkpoints

CephFS aims to provide POSIX filesystem semantics across clients. The MDS uses
capabilities and distributed locks to coordinate cached metadata and file data.
MDS metadata updates are journaled in RADOS and replayed during failover.

### Durable file publication

```c
fd = open("rank-7.tmp", O_CREAT | O_WRONLY | O_TRUNC, 0644);
write_all(fd, checkpoint, size);
fsync(fd);                              /* make file content durable */
close(fd);
rename("rank-7.tmp", "rank-7.ckpt");  /* atomically publish one name */
```

An atomic rename publishes one file name; it does not atomically commit a
directory containing hundreds of rank files. Use a generation directory plus a
manifest or completion marker:

```text
checkpoint-1042/
  rank-0000.ckpt
  rank-0001.ckpt
  ...
  manifest.json
  COMMITTED
```

Readers accept the generation only when `COMMITTED` exists and the manifest
contains every expected rank, size, and checksum.

### Snapshots and remote copies

CephFS directory snapshots are useful for rollback and backup workflows, but
applications should coordinate writers before treating a snapshot as a
logically complete distributed checkpoint. CephFS snapshot mirroring copies
snapshots asynchronously to another CephFS file system, so the remote site can
lag and should not be treated as zero-RPO synchronous replication.

---

## 5. AI Workload Patterns

### Training datasets

```text
Good:
  10,000 shard files x 1-10 GiB
  sequential or large range reads
  shard assignment distributed across workers
  node-local cache for reused epochs

Risky:
  1,000,000,000 files x 4-64 KiB
  every worker scans the same directories
  random open/stat/read/close for every sample
```

CephFS works best when the application issues enough parallel data I/O to use
many placement groups and OSDs without overwhelming the MDS with tiny namespace
operations.

### Checkpoint bursts

Distributed checkpoints create synchronized write bursts. Spread ranks across
subdirectories when directory contention is visible, maintain enough free
space for the new generation plus recovery, and isolate checkpoint traffic
from latency-sensitive metadata or dataset pools when necessary.

### Model startup fan-out

Thousands of workers reading the same model files can saturate the OSDs that
hold those objects even when cluster-wide capacity appears idle. Mitigations
include node-local caching, staggered startup, artifact sharding, and placement
that creates enough independently readable objects.

---

## 6. Access Control and Isolation

CephX capabilities can restrict a client to a filesystem path:

```bash
ceph fs authorize cephfs client.training-a \
    /datasets r \
    /checkpoints/team-a rw
```

Layout and quota changes require the `p` capability flag; snapshot operations
require `s`. Path restrictions alone are not a complete security boundary if
the client's OSD capabilities permit broader direct RADOS access. Use matching
MDS and OSD capabilities, and use pool namespaces where strong tenant
separation is required.

CephFS directory quotas limit bytes or files:

```bash
setfattr -n ceph.quota.max_bytes -v "100 Ti" \
    /mnt/cephfs/checkpoints/team-a
setfattr -n ceph.quota.max_files -v 1000000 \
    /mnt/cephfs/checkpoints/team-a
```

CephFS quotas are cooperative and can be imprecise during active writes. Do not
treat them as a hard protection boundary against an untrusted client.

---

## 7. Operations and Failure Diagnosis

```bash
# Overall filesystem and MDS state
ceph fs status
ceph mds stat
ceph fs dump

# Correlate MDS warnings with underlying RADOS health
ceph health detail
ceph pg stat

# Inspect client sessions and operations on a specific MDS
ceph tell mds.<name> client ls
ceph tell mds.<name> dump_ops_in_flight
```

| Symptom | Likely layer | First checks |
|---------|--------------|--------------|
| Slow open/stat/readdir, data reads normal | MDS or client caps | MDS CPU/cache, hot directories, laggy clients |
| Reads and writes slow across many paths | OSD/network | PG states, slow ops, near-full OSDs, recovery traffic |
| Failover pause is long | MDS journal/client reconnect | standby coverage, journal replay, client count |
| `clients failing to respond to cache pressure` | Cap recall | client health, cap count, MDS cache pressure |
| Writes suddenly become synchronous and slow | Fullness protection | data-pool near-full state and capacity |
| One training job affects all users | Pool/directory contention | workload isolation, subtree placement, QoS |

The MDS can look healthy while data I/O is blocked by RADOS, and RADOS can look
healthy while one MDS rank is metadata-bound. Always inspect both layers.

---

## 8. Production Checklist

- Use replicated low-latency storage for the metadata pool.
- Run standby MDS daemons and test rank failover.
- Add active ranks only after measuring metadata saturation and namespace shape.
- Prefer large immutable dataset shards over tiny-file trees.
- Validate checkpoint durability with flush, manifest, checksum, and final marker.
- Reserve capacity and bandwidth for recovery during checkpoint bursts.
- Match CephX path caps with OSD pool/namespace caps.
- Measure metadata ops/s, client caps, OSD latency, and GPU data-wait time.
- Test client eviction and remount behavior before production incidents.
- Treat snapshots and mirrors as part of a tested recovery workflow, not a backup
  claim by themselves.

## References

- [Ceph client and CephFS architecture](https://docs.ceph.com/en/latest/architecture/ceph-clients/)
- [CephFS I/O path](https://docs.ceph.com/en/latest/cephfs/cephfs-io-path/)
- [Multiple active MDS daemons](https://docs.ceph.com/en/latest/cephfs/multimds/)
- [CephFS file layouts](https://docs.ceph.com/en/latest/cephfs/file-layouts/)
- [CephFS client authorization](https://docs.ceph.com/en/latest/cephfs/client-auth/)
- [CephFS quotas](https://docs.ceph.com/en/latest/cephfs/quota/)
- [CephFS failover and standby replay](https://docs.ceph.com/en/latest/cephfs/standby/)
- [CephFS snapshot mirroring](https://docs.ceph.com/en/latest/cephfs/cephfs-mirroring/)
- [CephFS troubleshooting](https://docs.ceph.com/en/latest/cephfs/troubleshooting/)
