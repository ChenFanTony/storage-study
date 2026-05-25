# RCU Lock Patterns in Linux Storage — Architect's Reference

**Audience:** Senior storage architect / kernel engineer
**Context:** When and why RCU is chosen over spinlock, rwlock, mutex, or RWsemaphore in the block layer, device drivers, and distributed storage analogs
**Related:** L1 kernel-io (blk-mq, NVMe driver), L1 storage-tiering (dm-cache, dm-thin), L2 distributed/systems (Ceph OSDMap)

---

## Why RCU Exists — The Core Problem

Every lock has a cost at the read side. Under a spinlock or rwlock, readers must atomically acquire/release the lock — that is a memory barrier, a cache line bounce across CPUs, and serialization. On a 96-core machine with thousands of I/Os per second, that lock becomes a bottleneck even when contention is rare.

RCU's insight: **if readers are vastly more frequent than writers, and readers can tolerate briefly seeing old data, the read side can be zero-cost.**

```
spinlock:   reader acquires lock → memory barrier → work → release → memory barrier
rwlock:     reader increments counter → memory barrier → work → decrement
RCU:        rcu_read_lock() [preempt_disable()] → work → rcu_read_unlock()
            ← no atomic op, no memory barrier, no cache line bounce →
```

The writer pays instead: it creates a new copy of the data, atomically swaps the pointer, then waits for all existing readers to finish (the "grace period") before freeing the old copy.

---

## The Three Conditions That Mandate RCU

Use RCU when all three are true:

1. **Read:write ratio is very high** — readers run millions of times per second; writers run rarely (config changes, hotplug, scheduler switch)
2. **Readers are in a hot path** — per-I/O, per-packet, per-interrupt paths where lock overhead compounds at scale
3. **Readers can tolerate momentarily stale data** — a reader that started before a writer finishes can see the old version without correctness problems

---

## Block Layer: Where RCU Is Used

### 1. blk-mq CPU-to-Hardware-Queue Mapping

Every I/O submission does: "which hardware queue does this CPU map to?"

```c
// block/blk-mq.c — called on every bio submission
struct blk_mq_ctx *ctx = blk_mq_get_ctx(q);
struct blk_mq_hw_ctx *hctx = blk_mq_map_queue(q, rqf, ctx);
```

The CPU→hwqueue map (`q->mq_map`) is RCU-protected. It changes only during CPU hotplug or device reconfiguration — but is read on every single I/O. An rwlock here would serialize all I/O submission across all CPUs for a cache line bounce. RCU makes it free.

### 2. I/O Scheduler Operations Pointer

When you `echo mq-deadline > /sys/block/nvme0n1/queue/scheduler`, the scheduler is switched atomically. The `q->elevator` pointer is RCU-protected:

```c
// block/blk-mq-sched.c
rcu_read_lock();
e = rcu_dereference(q->elevator);
if (e->type->ops.has_work(hctx))
    // dispatch
rcu_read_unlock();
```

Writer (scheduler switch) uses `rcu_assign_pointer()` + `synchronize_rcu()` to wait for all in-flight readers before freeing the old scheduler state.

**Why not a spinlock?** The scheduler's `has_work()` and `dispatch_request()` are called in the I/O dispatch loop — potentially millions of times per second. A spinlock on the scheduler pointer would serialize all I/O dispatch across the machine.

### 3. Block Device (gendisk) Lookup

`blkdev_get_by_dev()` traverses the registered disk list. New disks are added/removed rarely (hotplug, driver probe) but device open is called frequently (container startup, mounts, udev events).

```c
// block/genhd.c
rcu_read_lock();
disk = xa_load(&bdev_map, dev);   // RCU-safe xarray lookup
rcu_read_unlock();
```

---

## Device Driver: Where RCU Is Used

### 4. NVMe Namespace List (Most Important Storage RCU Case)

Every NVMe I/O must find the correct namespace struct from the namespace ID:

```c
// drivers/nvme/host/core.c
static struct nvme_ns *nvme_find_get_ns(struct nvme_ctrl *ctrl, unsigned nsid)
{
    struct nvme_ns *ns, *ret = NULL;

    rcu_read_lock();
    list_for_each_entry_rcu(ns, &ctrl->namespaces, list) {
        if (ns->head->ns_id == nsid) {
            if (!nvme_get_ns(ns))    // refcount + RCU pattern
                continue;
            ret = ns;
            break;
        }
    }
    rcu_read_unlock();
    return ret;
}
```

Namespaces are added/removed only by NVMe namespace management commands — rare. But this lookup happens on every I/O.

**RCU + refcount together**: RCU ensures pointer validity during the lookup; refcount ensures the object lives long enough to use after the RCU read-side critical section exits.

### 5. NVMe Multipath — ANA Path Selection

Every I/O on a multipath namespace needs: "which path is currently optimized?"

```c
// drivers/nvme/host/multipath.c — called per I/O
rcu_read_lock();
ns = srcu_dereference(head->current_path[node], &head->srcu);
if (ns && nvme_path_is_optimized(ns))
    found = ns;
rcu_read_unlock();
```

ANA state changes (optimized → inaccessible → optimized) happen on path failover events — rare. But path selection is per-I/O. The `current_path` pointer is RCU-assigned atomically on ANA state change.

**Why not a spinlock?** At 2M IOPS with NVMe-oF multipath, a spinlock on the path pointer serializes 2M path lookups per second across all CPUs — guaranteed contention.

### 6. Device Mapper — Table Pointer (SRCU Case)

Every bio submitted to `/dev/dm-X` goes through:

```c
// drivers/md/dm.c
static blk_qc_t dm_submit_bio(struct bio *bio)
{
    struct mapped_device *md = bio->bi_bdev->bd_disk->private_data;
    int srcu_idx;
    struct dm_table *map = dm_get_live_table(md, &srcu_idx);
    // dispatch bio to target (bcache, thin, cache, linear...)
    dm_put_live_table(md, srcu_idx);
}
```

DM uses **SRCU** (Sleepable RCU), not plain RCU. The DM target's `map()` function can sleep — it may allocate memory, wait for metadata, etc. Plain RCU read-side critical sections cannot sleep (they disable preemption). SRCU allows sleeping readers at the cost of per-subsystem SRCU state.

**Table reload** (`dmsetup reload`, `lvchange`, bcache reconfiguration): writer allocates new table, calls `rcu_assign_pointer()`, waits for all in-flight I/Os with `synchronize_srcu()`, then frees the old table. This is why `dmsetup suspend` can take time — it waits for all in-flight I/Os to drain.

### 7. SCSI Device List

The SCSI host maintains a list of attached devices (`shost->__devices`). Device lookup happens on every command dispatch; device add/remove happens during bus scan and hotplug.

```c
// drivers/scsi/hosts.c
struct scsi_device *scsi_device_lookup(struct Scsi_Host *shost,
                                        uint channel, uint id, u64 lun)
{
    struct scsi_device *sdev;
    rcu_read_lock();
    list_for_each_entry_rcu(sdev, &shost->__devices, siblings) {
        if (sdev->channel == channel && sdev->id == id && sdev->lun == lun)
            // found
    }
    rcu_read_unlock();
}
```

### 8. md/RAID — Per-Disk rdev Pointer

RAID-1 read path picks a disk from the member list; RAID-5 must find the stripe location. When a disk is hot-removed, the per-disk `rdev` pointer is set to NULL via `rcu_assign_pointer()`. The grace period ensures no in-flight I/O is still dereferencing the old `rdev` when it is freed.

```c
// drivers/md/raid1.c — read path picks a disk
rcu_read_lock();
rdev = rcu_dereference(conf->mirrors[rdisk].rdev);
if (rdev && test_bit(In_sync, &rdev->flags))
    // use this disk for the read
rcu_read_unlock();
```

---

## The Canonical RCU Pattern in Storage Drivers

```c
/* Writer — runs rarely (hotplug, config change) */
new_config = kzalloc(sizeof(*new_config), GFP_KERNEL);
memcpy(new_config, old_config, sizeof(*old_config));
new_config->changed_field = new_value;

rcu_assign_pointer(device->config, new_config);   // atomic pointer swap
synchronize_rcu();      // wait for all readers with old_config to finish
kfree(old_config);      // now safe: no reader holds a reference

/* Reader — runs millions of times per second (every I/O) */
rcu_read_lock();
config = rcu_dereference(device->config);   // safe pointer dereference
use_config_fields(config);                  // must not sleep (plain RCU)
rcu_read_unlock();
```

`rcu_dereference()` is not just a pointer dereference — it includes a read memory barrier on architectures that need it (Alpha), preventing speculative execution with a stale pointer value.

---

## RCU vs Other Locks: Decision Matrix

| Scenario | Lock choice | Reason |
|----------|------------|--------|
| Per-I/O lookup of rarely-changed config | **RCU** | Read:write ratio enormous; readers must not pay |
| Shared counter updated on every I/O | **atomic / per-cpu** | No pointer indirection; atomic ops cheaper than RCU |
| List modified and read at similar rates | **spinlock** | High write rate makes RCU grace period expensive |
| Mutual exclusion only, can sleep | **mutex** | No concurrent read performance requirement |
| Multiple readers, infrequent writers, readers may sleep | **RWsemaphore** | Sleeping readers need semaphore, not spinlock |
| Readers in DM target map() which may sleep | **SRCU** | Same as RCU but allows sleeping in read-side |
| In-flight I/O count (not a data pointer) | **percpu_ref** | Reference counting, not data structure protection |
| Per-CPU data modified only by owning CPU | **preempt_disable** | No cross-CPU coordination needed |

### RCU vs rwlock specifically

```
rwlock:
  Reader: atomic increment of reader count (cache miss on contention)
  Writer: spin until all readers exit, then proceed
  Can starve writers if readers are continuous
  N concurrent readers = N atomic ops at entry/exit

RCU:
  Reader: preempt_disable (no atomic, no cache miss)
  Writer: rcu_assign_pointer() + synchronize_rcu() (grace period)
  Writers are never blocked by readers; readers may briefly see old data
  N concurrent readers = zero per-reader overhead
```

Use **rwlock** when: readers must always see the latest data AND writes are frequent.
Use **RCU** when: reads dwarf writes AND readers can briefly see the previous version.

---

## Common RCU Mistakes in Storage Code

### Mistake 1 — Sleeping inside plain RCU read-side

```c
rcu_read_lock();
config = rcu_dereference(dev->config);
kmalloc(size, GFP_KERNEL);    // BUG: GFP_KERNEL may sleep → schedule
rcu_read_unlock();
```

Plain RCU disables preemption. Any sleep inside `rcu_read_lock()` deadlocks or corrupts RCU state. **Fix**: use SRCU, or move the allocation outside the critical section.

### Mistake 2 — Using the pointer after rcu_read_unlock() without a refcount

```c
rcu_read_lock();
ns = rcu_dereference(head->ns);
rcu_read_unlock();
ns->submit_bio(...);    // BUG: ns may be freed — grace period may have elapsed
```

**Fix**: always combine RCU with `kref_get()` / `refcount_inc()` before exiting the RCU read-side if you need to use the object after `rcu_read_unlock()`. This is exactly what `nvme_get_ns()` does in the namespace lookup pattern above.

### Mistake 3 — Long critical sections blocking grace periods

If a read-side critical section runs for a long time, `synchronize_rcu()` on the writer blocks for the duration. Never do blocking I/O inside `rcu_read_lock()` with plain RCU. Use SRCU for any read-side that may sleep.

---

## RCU Analogs in Distributed Systems

RCU does not exist as a kernel primitive in distributed systems, but the same problem — readers must not block, writers create new versions — appears at higher levels:

### MVCC (Multi-Version Concurrency Control)

- Databases (PostgreSQL, InnoDB): readers see a consistent snapshot at their transaction start time. Writers create new row versions. Old versions are cleaned up when no transaction references them.
- The "grace period" = time until all transactions older than the write have committed.
- Exact analog: RCU grace period = MVCC garbage collection epoch.

### Ceph OSDMap / PGMap Epochs

When cluster topology changes (OSD down/up), Ceph publishes a new OSDMap epoch.
- Clients continue using their current epoch map while reading → no blocking
- New writes use the new epoch
- Old epochs retained until all clients have acknowledged the new one — a distributed grace period
- Reads against a stale OSDMap that route to the wrong OSD → `ENOENT` redirect → client fetches new map

This is structurally identical to RCU: readers see old-but-consistent data; writer publishes new version; old version freed after all readers advance.

### Epoch-Based Reclamation (EBR)

User-space analog of RCU for lock-free data structures. Each thread registers its current epoch. Objects freed only when all threads have advanced past the epoch in which the object was removed. Used in user-space storage engines (RocksDB, WiredTiger) for internal data structures.

### Seqlock for Fast Metadata Consistency

Distributed pattern: readers check version, retry if writer was active.
- etcd uses Raft log index as a sequence number
- Read: note current revision → fetch data → check revision unchanged → valid
- Write: increment revision, apply change
- Same principle as Linux `seqlock_t`: reader detects mid-write by checking version before and after

---

## Decision Rule for Storage Architects

```
Is the data accessed on every I/O / per-packet / per-interrupt?
  └── YES: Does it change more than once per second?
            └── NO  (config, topology, namespace list):  → RCU
            └── YES (per-I/O counters, per-request state): → atomic / per-cpu
  └── NO: Can readers sleep?
            └── NO:  Is write frequency low?
                      └── YES: → RCU
                      └── NO:  → spinlock
            └── YES: Can the read-side sleep (DM target, complex lookup)?
                      └── YES: → SRCU
                      └── NO:  → mutex or RWsemaphore
```

**The storage-specific answer**: blk-mq hwqueue mapping, I/O scheduler ops pointer, NVMe namespace and path lookup, DM table dispatch, SCSI device list, RAID disk pointers — all use RCU or SRCU because they are read billions of times per day and change only on human-timescale events (hotplug, reconfiguration, failover).

---

## Quick Reference: Storage Subsystem RCU Usage

| Subsystem | Protected data | Lock type | Change trigger |
|-----------|---------------|-----------|----------------|
| blk-mq | CPU→hwqueue map | RCU | CPU hotplug |
| blk-mq | Scheduler ops pointer | RCU | `echo scheduler > sysfs` |
| block/genhd | Disk list (xarray) | RCU | Driver probe/remove |
| NVMe host | Namespace list | RCU + kref | NS management command |
| NVMe multipath | ANA current path | RCU | Path failover |
| Device Mapper | DM table pointer | **SRCU** | dmsetup reload |
| SCSI | Device list | RCU | Bus scan / hotplug |
| md/RAID | Per-disk rdev pointer | RCU | Hot-remove / add |
| Ceph client | OSDMap epoch | Distributed epoch | OSD up/down event |
