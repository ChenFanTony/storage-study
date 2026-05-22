# Day 14 — dm-multipath PR ops and path management

**Week 2**: iSCSI Initiator Kernel Code  
**Time**: 1–2 hours  
**Reference**: `drivers/md/dm-mpath.c`, `drivers/md/dm.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

Day 13 covered the initiator-side PR slow path. Today: how dm-multipath manages the *interaction*
between PR operations, path failures, and the `queued_bios` list. This is where many subtle
fencing bugs live — wrong assumptions about which thread holds which lock, when paths get
reinstated, or how PR ops coexist with hung normal I/O.

---

## The two layers of dm

dm-core (`drivers/md/dm.c`) implements:
- `pr_ops` table (`dm_pr_ops`)
- `dm_call_pr()` iterator that walks paths
- `dm_blk_ioctl()` general ioctl pass-through

dm-mpath (`drivers/md/dm-mpath.c`) implements:
- `multipath_map_bio()` — bio interception
- `m->queued_bios` and `process_queued_bios` — the queue and its drain
- `fail_path()` / `reinstate_path()` — path state changes
- Admin messages (`fail_if_no_path`, `queue_if_no_path`)

PR ops go through dm-core; bio I/O goes through dm-mpath. They share `struct multipath` state but
operate on different code paths.

---

## dm_call_pr — the PR fan-out — `drivers/md/dm.c`

```c
/* Simplified — see drivers/md/dm.c. */
struct dm_pr {
    u64     old_key;
    u64     new_key;
    u32     flags;
    bool    fail_early;
    int     ret;
    enum pr_type type;
};

static int dm_call_pr(struct block_device *bdev, iterate_devices_callout_fn fn,
                       void *data)
{
    struct mapped_device *md = bdev->bd_disk->private_data;
    struct dm_table *table;
    struct dm_target *ti;
    int ret = -ENOTTY;
    int srcu_idx;

    table = dm_get_live_table(md, &srcu_idx);
    if (!table || !table->num_targets)
        goto out;

    /* Multipath devices have one target spanning the whole LUN */
    ti = dm_table_get_target(table, 0);
    if (!ti->type->iterate_devices) {
        ret = -EINVAL;
        goto out;
    }

    /*
     * iterate_devices walks every pgpath in every priority group.
     * For each: calls our `fn` with the pgpath's underlying bdev.
     */
    ret = ti->type->iterate_devices(ti, fn, data);

out:
    dm_put_live_table(md, srcu_idx);
    return ret;
}
```

For dm-multipath, `iterate_devices` is `multipath_iterate_devices()`:

```c
static int multipath_iterate_devices(struct dm_target *ti,
                                       iterate_devices_callout_fn fn,
                                       void *data)
{
    struct multipath *m = ti->private;
    struct priority_group *pg;
    struct pgpath *p;
    int ret = 0;

    list_for_each_entry(pg, &m->priority_groups, list) {
        list_for_each_entry(p, &pg->pgpaths, list) {
            ret = fn(ti, p->path.dev,
                     ti->begin, ti->len, data);
            if (ret)
                break;
        }
        if (ret)
            break;
    }

    return ret;
}
```

So `dm_pr_register()` ends up calling `__dm_pr_register()` once per path, once per priority
group. Each call:
1. Looks up the path's `sd_pr_ops`.
2. Calls `sd_pr_register()` with the same `(old_key, new_key, flags)`.
3. The session for that path sends a `PERSISTENT RESERVE OUT REGISTER` PDU.
4. Target's `core_scsi3_pro_register()` records the key for that I_T nexus.

After registration completes on all paths, every path has the same registered key from this
initiator's perspective. Each I_T nexus on the target has an entry with that key.

`fail_early=true` (the default for register) means stop on first failure — useful when one path
has a stale ACL or other auth issue. `fail_early=false` lets the loop attempt every path even if
some fail.

---

## dm_pr_reserve — only the active path

Unlike register, reserve only needs to fire once. The dm layer uses the active path:

```c
/* Simplified. */
static int dm_pr_reserve(struct block_device *bdev,
                          u64 key,
                          enum pr_type type,
                          u32 flags)
{
    struct mapped_device *md = bdev->bd_disk->private_data;
    struct block_device *path_bdev;
    int ret;

    /*
     * Get the currently active path's bdev.
     * dm_get_active_pgpath_bdev() walks the path selectors to find
     * a usable path. If no path is active, returns -ENOTTY.
     */
    ret = dm_prepare_ioctl(md, &path_bdev);
    if (ret < 0)
        return ret;

    /*
     * Issue PR RESERVE on this path's bdev.
     * sd_pr_reserve() builds the CDB and calls scsi_execute_cmd().
     */
    ret = path_bdev->bd_disk->fops->pr_ops->pr_reserve(path_bdev, key,
                                                        type, flags);

    dm_unprepare_ioctl(md);
    return ret;
}
```

The reservation is held by the I_T_L nexus on the target. With `PR_*_ALL_REGS` types, ALL
registered nexuses share write access — exactly the "all paths active, one key, can write"
semantics multipath wants.

---

## What happens when a path fails during PR

Scenario: PR REGISTER is fanning out across 4 paths. Path 2 has just lost its TCP session.

```
__dm_pr_register on path 0      → success
__dm_pr_register on path 1      → success
__dm_pr_register on path 2      → ?
    │
    ▼
sd_pr_register(path 2's bdev)
    │
    ▼
sd_pr_out_command()
    │
    ▼
scsi_execute_cmd()
    │  REQ_OP_DRV_OUT (passthrough)
    ▼
blk_execute_rq(at_head=true)
    │  inserted at hctx->dispatch HEAD
    ▼
blk_mq_run_hw_queue() → iscsi_queuecommand()
    │  Gate 1: iscsi_session_chkready()
    │  session->state == ISCSI_STATE_FAILED
    │  → return DID_TRANSPORT_DISRUPTED << 16
    ▼
sc->result set, scsi_done(sc)
    │  blk_rq_is_passthrough → scsi_complete()
    │  → wakes blk_execute_rq()
    ▼
sd_pr_out_command() returns -EIO
    │
    ▼
__dm_pr_register returns -EIO
    │
    ▼  (with fail_early=true: stop and return)
dm_pr_register returns -EIO to userspace
```

If `fail_early=false`, the loop continues to paths 3 and 4. `multipathd` sees per-path errors and
typically retries the failed path later (often via its path checker triggering a reinstate).

---

## Path failure during normal I/O — the fencing scenario

Now the same path failure but during normal `submit_bio()` (not PR):

```
application: write(fd, buf, len)
    │
    ▼
submit_bio() / blk_mq_submit_bio()
    │
    ▼
multipath_map_bio()
    │  choose_pgpath() — picks current_pgpath (say path 2)
    ▼
bio_set_dev(bio, path2 bdev)
DM_MAPIO_REMAPPED
    │
    ▼  (re-submit on path 2)
iscsi_queuecommand() on path 2
    │  session->state == ISCSI_STATE_FAILED
    ▼
... bio eventually completes with BLK_STS_TRANSPORT
    │
    ▼
multipath_end_io_bio()
    │  blk_path_error(BLK_STS_TRANSPORT) = true
    │  fail_path(path 2)
    │  atomic_dec(&m->nr_valid_paths)
    ▼
return DM_ENDIO_REQUEUE
    │  bio resubmitted via blk_mq_requeue_request
    ▼
multipath_map_bio() — try again
    │  choose_pgpath() picks path 3
    ▼
... bio remapped to path 3, eventually succeeds
```

If all paths are failed (`nr_valid_paths == 0`):
```
multipath_map_bio()
    │  choose_pgpath() returns NULL
    │  if m->queue_if_no_path:
    │      bio_list_add(&m->queued_bios, bio)  ← HANG
    │      return DM_MAPIO_SUBMITTED
```

But PR ops in flight at the same time:
```
dm_pr_reserve()
    │  takes a different code path entirely
    │  calls underlying bdev's pr_ops directly
    │  blk_execute_rq() injects at hctx->dispatch HEAD
    ▼
If at least one path's session is still alive:
    PR command succeeds → caller wakes → returns 0
```

---

## queue_if_no_path messages

Userspace controls `queue_if_no_path` via dmsetup messages:

```bash
# Pause queueing — bios will fail with -EIO when no path
dmsetup message dm-0 0 fail_if_no_path

# Resume queueing — new bios will queue when no path
dmsetup message dm-0 0 queue_if_no_path
```

```c
/* Simplified — drivers/md/dm-mpath.c. */
static int multipath_message(struct dm_target *ti, unsigned argc, char **argv,
                              char *result, unsigned maxlen)
{
    struct multipath *m = ti->private;

    if (!strcasecmp(argv[0], "queue_if_no_path"))
        return queue_if_no_path(m, true, false);

    if (!strcasecmp(argv[0], "fail_if_no_path"))
        return queue_if_no_path(m, false, false);

    /* ... other messages ... */
}

static int queue_if_no_path(struct multipath *m, bool queue_if_no_path,
                              bool save_old_value)
{
    unsigned long flags;
    bool queue_if_no_path_bit, saved_queue_if_no_path_bit;

    spin_lock_irqsave(&m->lock, flags);

    saved_queue_if_no_path_bit = m->saved_queue_if_no_path;
    queue_if_no_path_bit       = m->queue_if_no_path;

    if (save_old_value) {
        if (unlikely(!queue_if_no_path_bit && saved_queue_if_no_path_bit)) {
            DMERR("saved_queue_if_no_path_bit out of sync");
        } else {
            m->saved_queue_if_no_path = queue_if_no_path_bit;
        }
    } else if (!queue_if_no_path && saved_queue_if_no_path_bit) {
        m->saved_queue_if_no_path = false;
    }

    m->queue_if_no_path = queue_if_no_path;

    spin_unlock_irqrestore(&m->lock, flags);

    /*
     * If we cleared queue_if_no_path while bios were queued, drain them.
     * They will be failed with -EIO since there's no path.
     */
    if (!queue_if_no_path) {
        dm_table_run_md_queue_async(m->ti->table);
        process_queued_io_list(m);
    }

    return 0;
}
```

`fail_if_no_path` is the standard "stop the hang" lever. After issuing:
- `m->queue_if_no_path = 0`
- Next `multipath_map_bio()` call with no paths returns `DM_MAPIO_KILL` instead of queuing
- `process_queued_bios` drains the queue, but with `queue_if_no_path=0` and no paths, those bios
  fail with `-EIO`

This is the manual recovery path. `multipathd` can also be configured to do it automatically
after `no_path_retry` retries.

---

## fail_path side effects

Beyond decrementing `nr_valid_paths`, `fail_path()` triggers:

```c
static void fail_path(struct pgpath *pgpath)
{
    /* ... lock, mark inactive, atomic_dec ... */

    /*
     * Send a uevent — multipathd is listening.
     */
    dm_path_uevent(DM_UEVENT_PATH_FAILED, m->ti,
                   pgpath->path.dev->name,
                   atomic_read(&m->nr_valid_paths));

    /*
     * trigger_event work item — runs in process context to send
     * userspace notification.
     */
    schedule_work(&m->trigger_event);

    /*
     * If a path-group ALUA initialization is in progress, signal it
     * (the path is gone, no point waiting).
     */
    if (pgpath->is_active)
        pgpath->pg->ps.type->fail_path(&pgpath->pg->ps, &pgpath->path);
}
```

`multipathd` receives the uevent and:
- Updates its internal path map.
- May schedule a path-checker re-test.
- Logs the failure.
- May trigger a reinstate attempt later.

---

## reinstate_path — recovery

```c
static int reinstate_path(struct pgpath *pgpath)
{
    struct multipath *m = pgpath->pg->m;
    int run_queue = 0;
    unsigned long flags;

    spin_lock_irqsave(&m->lock, flags);

    if (pgpath->is_active) {
        /* already active — idempotent */
        spin_unlock_irqrestore(&m->lock, flags);
        return 0;
    }

    pgpath->is_active = 1;
    atomic_inc(&m->nr_valid_paths);

    if (atomic_read(&m->nr_valid_paths) == 1) {
        /* this was the first path back — drain queued_bios */
        run_queue = 1;
        m->current_pgpath = pgpath;
    }

    dm_path_uevent(DM_UEVENT_PATH_REINSTATED, m->ti,
                   pgpath->path.dev->name,
                   atomic_read(&m->nr_valid_paths));

    schedule_work(&m->trigger_event);

    spin_unlock_irqrestore(&m->lock, flags);

    if (run_queue) {
        dm_table_run_md_queue_async(m->ti->table);
        process_queued_io_list(m);   /* runs process_queued_bios */
    }

    return 0;
}
```

After `reinstate_path()` runs and returns, `process_queued_bios` (the `m->process_queued_bios`
work item) drains `m->queued_bios`. Each bio re-enters `multipath_map_bio()`, where
`choose_pgpath()` now finds the newly-reinstated path and returns it. The bio gets remapped to
the path's bdev and submitted.

The application's `write()` call — which has been blocked since the bio went into
`m->queued_bios` — now returns success.

---

## The key invariant

The PR slow path and the multipath bio path share `struct multipath` state but never share code:

| Aspect | Bio I/O | PR ioctl |
|---|---|---|
| Entry | `submit_bio()` / `multipath_map_bio()` | `blkdev_pr_ioctl()` / `dm_pr_*` |
| Path selection | `choose_pgpath()` | `iterate_devices()` (register) or current_pgpath (reserve) |
| Failure handling | `m->queued_bios` if no_path_retry=queue | returns -EIO immediately |
| Tag | regular blk-mq tag | reserved tag (`BLK_MQ_REQ_RESERVED`) |
| Insert position | scheduler / normal queue | `BLK_MQ_INSERT_AT_HEAD` |
| Underlying call | `iscsi_queuecommand()` for I/O | `iscsi_queuecommand()` for passthrough — but on a passthrough request |

PR commands do hit `iscsi_queuecommand()` like any other command. But the request they're
attached to has `REQ_OP_DRV_OUT`, was inserted via `BLK_MQ_INSERT_AT_HEAD`, will skip
`scsi_decide_disposition()` retry/EH on failure (passthrough short-circuit), and is waited on
synchronously by `blk_execute_rq()`. None of `multipath_map_bio`'s queueing logic is involved.

---

## Key takeaways

- `dm_pr_ops` provides PR for `/dev/mapper/mpathN`. PR REGISTER fans out via `dm_call_pr()` →
  `iterate_devices()` → `__dm_pr_register()` → `sd_pr_register()` per path.
- `dm_pr_reserve` only reserves on the active path. With `PR_*_ALL_REGS` types, all registered
  initiators retain write access.
- `multipath_map_bio()` is for normal bio I/O only. PR ops never touch it.
- `m->queued_bios` is the bio hold queue. PR ops never see it.
- `fail_path()` decrements `nr_valid_paths` and sends a udev event; `multipathd` listens.
- `reinstate_path()` triggers `process_queued_bios` to drain queued I/O when a path returns.
- `dmsetup message dm-0 0 fail_if_no_path` is the manual lever to stop the hang — clears
  `queue_if_no_path` and drains queued bios with -EIO.
- The two layers (dm-core for PR, dm-mpath for bio) share state but never share code paths —
  this is what makes PR-based fencing work even when normal I/O is hung.

---

## Previous / Next

[Day 13 — PR slow path: initiator side](day13.md) | [Day 15 — target core structs](day15.md)
