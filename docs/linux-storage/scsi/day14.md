# Day 14 — dm-multipath PR ops and path management

**Week 2**: iSCSI Initiator Kernel Code
**Time**: 1–2 hours
**Reference**: `drivers/md/dm-mpath.c`, `drivers/md/dm.c`

---

## Overview

This day ties together the multipath path management code with the PR ops picture from day 13.
The focus is: why PR goes through `dm_pr_ops` and NOT through the normal multipath dispatch;
how `fail_path()` and `reinstate_path()` manage the path set; and how `queue_if_no_path` interacts
with path failure to produce the indefinite hang — and what the clean alternatives are.

---

## dm_pr_ops — registered on the dm device — `drivers/md/dm.c`

```c
/*
 * dm_pr_ops is set as disk->fops->pr_ops when a dm device is created.
 * It is the ONLY way PR commands reach the underlying paths from a dm device.
 * multipath_map_bio() is NEVER called for PR commands.
 */
static const struct pr_ops dm_pr_ops = {
    .pr_register  = dm_pr_register,
    .pr_reserve   = dm_pr_reserve,
    .pr_release   = dm_pr_release,
    .pr_preempt   = dm_pr_preempt,
    .pr_clear     = dm_pr_clear,
};

/*
 * dm_pr_register — registers a key on all paths.
 * Must be called before dm_pr_reserve.
 *
 * PERSISTENT RESERVE workflow:
 *   1. dm_pr_register(key)   — each path: PERSISTENT RESERVE OUT / REGISTER
 *   2. dm_pr_reserve(key)    — each path: PERSISTENT RESERVE OUT / RESERVE
 *   3. I/O proceeds normally
 *   4. dm_pr_release(key)    — each path: PERSISTENT RESERVE OUT / RELEASE
 */
static int dm_pr_register(struct block_device *bdev,
                            u64 old_key, u64 new_key, u32 flags)
{
    struct mapped_device *md = bdev->bd_disk->private_data;
    struct dm_pr pr = {
        .old_key   = old_key,
        .new_key   = new_key,
        .flags     = flags,
        .fail_early = false,
    };
    int r;

    r = dm_pr_call_all(md, dm_pr_register_fn, &pr);
    return r;
}

/* helper that calls a PR function on each path via iterate_devices */
static int dm_pr_call_all(struct mapped_device *md,
                            iterate_devices_callout_fn fn,
                            struct dm_pr *pr)
{
    struct dm_table *table;
    struct dm_target *ti;
    int r, srcu_idx;

    table = dm_get_live_table(md, &srcu_idx);
    if (!table)
        return -ENOTTY;

    /*
     * Iterate all targets (usually just one for multipath).
     * For each target, iterate all devices (paths).
     */
    for (int i = 0; i < dm_table_get_num_targets(table); i++) {
        ti = dm_table_get_target(table, i);
        if (ti->type->iterate_devices) {
            r = ti->type->iterate_devices(ti, fn, pr);
            if (r && pr->fail_early) {
                dm_put_live_table(md, srcu_idx);
                return r;
            }
        }
    }

    dm_put_live_table(md, srcu_idx);
    return pr->fail_early ? -EINVAL : 0;
}
```

---

## multipath_iterate_devices — `drivers/md/dm-mpath.c`

The `iterate_devices` function registered by the multipath target. Called by `dm_pr_call_all()`:

```c
static int multipath_iterate_devices(struct dm_target *ti,
                                      iterate_devices_callout_fn fn,
                                      void *data)
{
    struct multipath *m = ti->private;
    struct priority_group *pg;
    struct pgpath *p;
    int ret = 0;

    /*
     * Walk every priority group, every path within each group.
     * Call fn(ti, path_dev, start, len, data) for each.
     *
     * For PR: fn = dm_pr_reserve_fn (or register_fn, release_fn, etc.)
     * This calls blk_pr_reserve(path->path.dev->bdev) for each /dev/sdX.
     *
     * Important: this iterates ALL paths, not just active ones.
     * PR must be registered on every path — even currently-failed ones —
     * so that when they come back, they already have the reservation.
     */
    list_for_each_entry(pg, &m->priority_groups, list) {
        list_for_each_entry(p, &pg->pgpaths, list) {
            ret = fn(ti, p->path.dev, ti->begin, ti->len, data);
            if (ret && data && ((struct dm_pr *)data)->fail_early)
                return ret;
        }
    }

    return ret;
}
```

This is why PR is issued per-path — the `iterate_devices` callback visits every `pgpath`. Each
call to `blk_pr_reserve(path_dev->bdev)` blocks synchronously (day 13). PR is registered/reserved
on all paths before `dm_pr_reserve()` returns.

---

## fail_path — `drivers/md/dm-mpath.c` (full detail)

```c
static void fail_path(struct pgpath *pgpath)
{
    struct multipath *m = pgpath->pg->m;

    spin_lock_irq(&m->lock);

    if (!pgpath->is_active)
        goto out;   /* already marked failed — idempotent */

    DMWARN("Failing path %s.", pgpath->path.dev->name);

    pgpath->path.is_active = 0;
    pgpath->is_active      = 0;
    pgpath->fail_count++;

    /*
     * Decrement valid path counter.
     *
     * When nr_valid_paths hits 0:
     *   - choose_pgpath() returns NULL
     *   - multipath_map_bio() queues bios (if queue_if_no_path=1)
     *     or fails them immediately (if queue_if_no_path=0)
     */
    atomic_dec(&m->nr_valid_paths);

    if (pgpath == m->current_pgpath)
        m->current_pgpath = NULL;

    /*
     * If pg_init (e.g. ALUA state query) was running for this path,
     * cancel it — path is gone.
     */
    if (pgpath->pg->nr_pgpaths == 1 && pgpath->pg == m->current_pg)
        m->current_pg = NULL;

    /* udev event → multipathd sees path failure */
    dm_path_uevent(DM_UEVENT_PATH_FAILED, m->ti,
                   pgpath->path.dev->name,
                   atomic_read(&m->nr_valid_paths));

    /* schedule_work: let multipathd poll and potentially re-enable */
    schedule_work(&m->trigger_event);

out:
    spin_unlock_irq(&m->lock);
}
```

---

## reinstate_path — `drivers/md/dm-mpath.c`

Called by multipathd (via sysfs) or `pg_init_done()` when a path comes back:

```c
static int reinstate_path(struct pgpath *pgpath)
{
    int r = 0, run_queue = 0;
    struct multipath *m = pgpath->pg->m;
    unsigned int nr_valid_paths;

    spin_lock_irq(&m->lock);

    if (pgpath->is_active) {
        DMWARN("Attempting to reinstate active path %s",
               pgpath->path.dev->name);
        r = -EINVAL;
        goto out;
    }

    nr_valid_paths = atomic_inc_return(&m->nr_valid_paths);

    pgpath->is_active     = 1;
    pgpath->path.is_active = 1;

    if (!m->current_pgpath)
        m->current_pgpath = pgpath;

    /*
     * If bios were queued while no path was available,
     * set run_queue=1 to drain them after releasing the lock.
     */
    if (!bio_list_empty(&m->queued_ios))
        run_queue = 1;

    dm_path_uevent(DM_UEVENT_PATH_REINSTATED, m->ti,
                   pgpath->path.dev->name, nr_valid_paths);

    schedule_work(&m->trigger_event);

out:
    spin_unlock_irq(&m->lock);

    if (run_queue) {
        /*
         * Drain queued_ios — resubmit each bio through multipath_map_bio().
         * Now that a path is available, choose_pgpath() will succeed.
         */
        dm_table_run_md_queue_async(m->ti->table);
        process_queued_io_list(m);
    }

    return r;
}
```

`process_queued_io_list()` drains `m->queued_ios`:

```c
static void process_queued_io_list(struct multipath *m)
{
    if (m->queue_mode == DM_TYPE_REQUEST_BASED)
        dm_mq_kick_requeue_list(m->md);
    else
        dm_table_run_md_queue_async(m->ti->table);
}
```

---

## queue_if_no_path control — the no_path_retry knob

`queue_if_no_path` is set by multipath during device table loading based on `no_path_retry`:

```c
/*
 * Parsing of no_path_retry= from /etc/multipath.conf:
 *
 * no_path_retry = queue  → queue_if_no_path = 1, pg_init_retries = INT_MAX
 * no_path_retry = fail   → queue_if_no_path = 0
 * no_path_retry = N      → queue_if_no_path = 1, pg_init_retries = N
 *                           after N retries: queue_if_no_path = 0 (fail)
 */
static int multipath_ctr(struct dm_target *ti, unsigned argc, char **argv)
{
    /* ... parsing ... */
    if (!strcasecmp(arg, "queue"))
        m->queue_if_no_path = 1;
    else if (!strcasecmp(arg, "fail"))
        m->queue_if_no_path = 0;
    else {
        m->nr_priority_groups = simple_strtoul(arg, NULL, 10);
        m->queue_if_no_path = 1; /* queue initially, fail after N */
    }
}
```

You can change it at runtime via:

```bash
# switch from queue to fail immediately (clears queued_ios with -EIO)
dmsetup message dm-0 0 "fail_if_no_path"
# or via multipathd:
multipathd -k "fail_path dm-0 8:16"
```

The message handler:

```c
static int multipath_message(struct dm_target *ti, unsigned argc, char **argv)
{
    struct multipath *m = ti->private;

    if (!strcasecmp(argv[0], "fail_if_no_path")) {
        /*
         * Immediately switch from queue mode to fail mode.
         * All bios queued in m->queued_ios are failed with -EIO.
         * Application sees write() return -EIO immediately.
         */
        m->queue_if_no_path = 0;
        if (!atomic_read(&m->nr_valid_paths))
            dm_table_run_md_queue_async(m->ti->table);
        return 0;
    }
    /* ... reinstate_path, fail_path messages ... */
}
```

---

## Path management summary: the states a pgpath goes through

```
pgpath.is_active states:
    1 (active) → fail_path() → 0 (failed)
    0 (failed) → reinstate_path() → 1 (active)

nr_valid_paths:
    start: N (number of configured paths)
    fail_path(): atomic_dec → N-1, N-2, ... 0
    reinstate_path(): atomic_inc → 1, 2, ... N

queue_if_no_path interaction with nr_valid_paths:
    nr_valid_paths > 0: choose_pgpath() returns a path → I/O proceeds
    nr_valid_paths == 0 AND queue_if_no_path=1: bio_list_add(queued_ios) → HANG
    nr_valid_paths == 0 AND queue_if_no_path=0: DM_MAPIO_KILL → -EIO

Recovery:
    reinstate_path() → nr_valid_paths++ → process_queued_io_list() → drain queued_ios
```

---

## Why session-drop fencing avoids the queue hang

```
Scenario: no_path_retry=queue, fencing via session drop + ACL removal

Path A dropped by target (TCP RST or FIN):
    │  iscsi_conn_failure() → ISCSI_STATE_FAILED
    │  replacement_timeout = 120s starts
    │  iscsid tries to reconnect: Login → REJECT (ACL removed)
    │  reconnect fails → replacement_timeout counts down
    │  120s → RECOVERY_FAILED → DID_TRANSPORT_FAILFAST
    ▼
fail_path(path_A) → nr_valid_paths--

Path B dropped by target (same fencing action):
    │  same sequence as A
    ▼
fail_path(path_B) → nr_valid_paths = 0

Now: queue_if_no_path = 1, nr_valid_paths = 0
    New I/O → queued_ios (HANG until replacement_timeout * num_paths passes)

To avoid the hang:
    Option 1: no_path_retry = fail      → DM_MAPIO_KILL → -EIO immediately
    Option 2: no_path_retry = 2         → after 2 retries, switch to fail
    Option 3: reduce replacement_timeout (e.g. 10s)
              → fail_path() fires in 10s per path → faster -EIO
    Option 4: use dmsetup message "fail_if_no_path" explicitly after fencing
```

---

## Key takeaways

- `dm_pr_ops.pr_reserve()` = `dm_pr_reserve()` uses `iterate_devices()` to call
  `blk_pr_reserve()` on EACH path. PR is issued per I_T nexus — every path gets it.
- `multipath_iterate_devices()` walks ALL paths (active and inactive). PR must be on all paths.
- `fail_path()` decrements `nr_valid_paths`. When 0: `choose_pgpath()` returns NULL.
- `reinstate_path()` increments `nr_valid_paths` and drains `queued_ios` via
  `process_queued_io_list()`.
- `queue_if_no_path=1` (no_path_retry=queue) + `nr_valid_paths=0` = indefinite bio queue.
- `queue_if_no_path=0` (no_path_retry=fail) = immediate `-EIO` when all paths gone.
- The queue hang with session-drop fencing is caused by `replacement_timeout=120s` delay before
  `fail_path()` fires. Reduce timeout or use `no_path_retry=fail` to avoid this.
- `dmsetup message dm-X 0 "fail_if_no_path"` switches to fail mode at runtime, draining the
  queue immediately.

---

## Week 2 complete

You now have the full initiator stack: session/connection structs (day 8) → queuecommand and BHS
building (day 9) → TCP TX path (day 10) → TCP RX path and PDU dispatch (day 11) → session failure
and EH (day 12) → PR slow path (day 13) → multipath PR and path management (day 14).

Ready to continue with **Week 3: LIO target core internals**.

---

## Previous / Next

[Day 13 — PR slow path initiator side](day13.md) | [Day 15 — target core structs](day15.md)
