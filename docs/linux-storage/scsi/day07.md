# Day 7 — dm-multipath core

**Week 1**: Block Layer — blk-mq and SCSI Mid Layer  
**Time**: 1–2 hours  
**Reference**: `drivers/md/dm-mpath.c`, `drivers/md/dm-path-selector.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

dm-multipath presents multiple physical paths (each a separate `scsi_device` / iSCSI session)
as a single logical block device. When a path fails it retries on another. `no_path_retry=queue`
is the mode that causes indefinite I/O hangs when all paths fail simultaneously. Understanding
the exact code that implements this is the foundation of the fencing problem.

---

## Key structs — `drivers/md/dm-mpath.c`

```c
struct multipath {
    struct list_head        list;
    struct dm_target        *ti;            /* dm target descriptor */

    const char              *hw_handler_name;
    struct mutex            work_mutex;
    struct work_struct      trigger_event;  /* udev event on path change */

    struct pgpath           *current_pgpath;/* currently active path */
    struct priority_group   *current_pg;    /* current priority group */
    struct priority_group   *next_pg;       /* group to switch to next */

    atomic_t                nr_valid_paths; /* count of usable paths */
                                            /* *** KEY: 0 = no path → queue/fail */

    unsigned                queue_if_no_path;      /* no_path_retry=queue */
    unsigned                saved_queue_if_no_path;/* saved during pg_init */

    unsigned                pg_init_retries;
    atomic_t                pg_init_in_progress;   /* pg_init running */

    struct list_head        priority_groups;
    unsigned                nr_priority_groups;

    spinlock_t              lock;

    /*
     * When queue_if_no_path=1 and nr_valid_paths=0,
     * bios are held in this list indefinitely.
     * (Field renamed from queued_ios to queued_bios in modern code.)
     */
    struct bio_list         queued_bios;
    struct work_struct      process_queued_bios;
};

struct priority_group {
    struct list_head        list;
    struct multipath        *m;

    struct path_selector    ps;             /* round-robin, queue-length, etc. */

    unsigned                pg_num;         /* priority group number (1-based) */
    unsigned                bypassed;       /* admin-disabled group */

    unsigned                nr_pgpaths;
    struct list_head        pgpaths;        /* list of pgpath */
};

struct pgpath {
    struct list_head        list;
    struct priority_group   *pg;            /* parent group */
    unsigned                is_active;      /* 0 = failed, 1 = active */
    unsigned                fail_count;     /* times failed */
    struct dm_path          path;           /* contains .dev (dm_dev with bdev) */
    struct work_struct      deactivate_path;
    struct work_struct      activate_path;
};
```

`atomic_t nr_valid_paths` is the critical counter. Every call to `fail_path()` decrements it.
When it reaches 0, `choose_pgpath()` returns NULL and `multipath_map_bio()` queues the bio.

---

## multipath_map_bio — `drivers/md/dm-mpath.c`

The entry point for every bio submitted to the dm-multipath device. This is the function that
implements `no_path_retry=queue`.

```c
/* Simplified — see drivers/md/dm-mpath.c for the full implementation. */
static int multipath_map_bio(struct dm_target *ti, struct bio *bio)
{
    struct multipath *m = ti->private;
    struct pgpath *pgpath;
    unsigned long flags;

    spin_lock_irqsave(&m->lock, flags);

    /* select the best available path */
    pgpath = choose_pgpath(m, bio->bi_iter.bi_size);

    if (!pgpath) {
        /*
         * No path available.
         */
        if (m->queue_if_no_path) {
            /*
             * *** THIS IS THE EXACT LINE THAT IMPLEMENTS no_path_retry=queue ***
             *
             * Add the bio to m->queued_bios — it will stay here until:
             *   a) a path recovers (pg_init_done / reinstate_path), OR
             *   b) queue_if_no_path is set to 0 (admin changes no_path_retry)
             *
             * Return DM_MAPIO_SUBMITTED — tells dm-core the bio was handled.
             * The bio will NOT complete until drained from queued_bios.
             * The application's write() or read() call hangs here.
             */
            bio_list_add(&m->queued_bios, bio);
            spin_unlock_irqrestore(&m->lock, flags);
            return DM_MAPIO_SUBMITTED;
        }

        spin_unlock_irqrestore(&m->lock, flags);
        /*
         * no_path_retry=fail (queue_if_no_path=0):
         * Return DM_MAPIO_KILL → bio completed with -EIO immediately.
         * Application sees write() return -EIO.
         */
        return DM_MAPIO_KILL;
    }

    /* attach mpio (dm_mpath_io) to the bio for tracking */
    /* ... */

    /*
     * Redirect bio to the path's block device (e.g. /dev/sdb).
     * REQ_FAILFAST_TRANSPORT: if this path fails during I/O,
     * don't retry on this path — report failure immediately so
     * multipath_end_io() can try a different path.
     */
    bio_set_dev(bio, pgpath->path.dev->bdev);
    bio->bi_opf |= REQ_FAILFAST_TRANSPORT;

    spin_unlock_irqrestore(&m->lock, flags);

    return DM_MAPIO_REMAPPED;
}
```

`DM_MAPIO_SUBMITTED` = bio handled, don't touch it.
`DM_MAPIO_KILL` = fail the bio with -EIO.
`DM_MAPIO_REMAPPED` = bio redirected to new dev, submit it.

---

## choose_pgpath — path selection

```c
static struct pgpath *choose_pgpath(struct multipath *m, size_t nr_bytes)
{
    struct priority_group *pg;
    struct pgpath *pgpath;
    bool bypassed = true;

    if (!atomic_read(&m->nr_valid_paths)) {
        /* fast path: no valid paths, no point trying */
        return NULL;
    }

    /*
     * Try the currently active priority group first.
     * The path selector (round-robin, queue-length, service-time)
     * picks the best path within the group.
     */
    if (m->current_pg) {
        pgpath = m->current_pg->ps.type->select_path(
            &m->current_pg->ps, nr_bytes);
        if (pgpath)
            return pgpath;
    }

    /*
     * Current group exhausted — try other non-bypassed groups.
     * Trigger pg_init to re-initialize the path group (ALUA query, etc.)
     */
    list_for_each_entry(pg, &m->priority_groups, list) {
        if (pg->bypassed == bypassed) {
            pgpath = pg->ps.type->select_path(&pg->ps, nr_bytes);
            if (pgpath) {
                if (pg != m->current_pg)
                    m->next_pg = pg;  /* switch to this pg */
                return pgpath;
            }
        }
        if (!bypassed)
            break;
        bypassed = false; /* next iteration: try bypassed groups too */
    }

    return NULL; /* no path available in any group */
}
```

---

## multipath_end_io — completion handler

```c
static int multipath_end_io_bio(struct dm_target *ti, struct bio *clone,
                                blk_status_t *error)
{
    struct multipath *m = ti->private;
    struct dm_mpath_io *mpio = get_mpio(...);
    struct pgpath *pgpath = mpio->pgpath;
    int r = DM_ENDIO_DONE;

    if (*error) {
        /*
         * blk_path_error() returns true for errors that indicate
         * the PATH is broken (BLK_STS_TRANSPORT, BLK_STS_NEXUS, etc.).
         * It returns false for:
         *   BLK_STS_NOTSUPP, BLK_STS_NOSPC, BLK_STS_TARGET,
         *   BLK_STS_RESV_CONFLICT
         *
         * RESERVATION CONFLICT → BLK_STS_RESV_CONFLICT
         *   → blk_path_error() = false
         *   → path NOT marked failed (correct behavior)
         *
         * Transport failure / DID_NO_CONNECT → BLK_STS_TRANSPORT or IOERR
         *   → blk_path_error() = true
         *   → path is marked failed
         */
        if (pgpath && blk_path_error(*error))
            fail_path(pgpath);

        if (!atomic_read(&m->nr_valid_paths)) {
            if (m->queue_if_no_path) {
                /*
                 * Requeue this bio to be retried when path recovers.
                 * The bio goes back through multipath_map_bio() next time.
                 */
                r = DM_ENDIO_REQUEUE;
                goto done;
            }
        }
    }

done:
    return r;
}
```

```c
/* include/linux/blk_types.h — current upstream */
static inline bool blk_path_error(blk_status_t error)
{
    switch (error) {
    case BLK_STS_NOTSUPP:
    case BLK_STS_NOSPC:
    case BLK_STS_TARGET:
    case BLK_STS_RESV_CONFLICT:    /* added in v6.0 timeframe */
        /* these indicate target/data errors, not path errors */
        return false;
    }
    return true; /* everything else is a path error */
}
```

A meaningful change from older kernels: `BLK_STS_RESV_CONFLICT` is in the false-list. So a stray
RESERVATION CONFLICT on normal I/O does NOT cause `fail_path()` and does not propagate as a path
failure. NOT_READY (which gets retried via EH and may eventually result in `DID_NO_CONNECT` →
`BLK_STS_IOERR`) still does — but that's after EH exhaustion, not directly from the sense.

For PR commands themselves none of this applies — they go through `dm_pr_ops`, not
`multipath_map_bio` (day 13/14).

---

## fail_path — `drivers/md/dm-mpath.c`

```c
static void fail_path(struct pgpath *pgpath)
{
    struct multipath *m = pgpath->pg->m;
    unsigned long flags;

    spin_lock_irqsave(&m->lock, flags);

    if (!pgpath->is_active) {
        spin_unlock_irqrestore(&m->lock, flags);
        return;  /* already failed — idempotent */
    }

    DMWARN("Failing path %s.", pgpath->path.dev->name);

    pgpath->is_active = 0;
    pgpath->fail_count++;

    /*
     * *** Decrement the valid path counter ***
     * When this reaches 0, choose_pgpath() returns NULL.
     * From this point on, new bios go into queued_bios (if queue_if_no_path=1).
     */
    atomic_dec(&m->nr_valid_paths);

    if (pgpath == m->current_pgpath)
        m->current_pgpath = NULL;

    /* send udev event so userspace (multipathd) knows */
    dm_path_uevent(DM_UEVENT_PATH_FAILED, m->ti,
                   pgpath->path.dev->name,
                   atomic_read(&m->nr_valid_paths));

    /* trigger multipathd to run path checkers and possibly pg_init */
    schedule_work(&m->trigger_event);

    spin_unlock_irqrestore(&m->lock, flags);
}
```

---

## reinstate_path — recovery

```c
static int reinstate_path(struct pgpath *pgpath)
{
    int r = 0, run_queue = 0;
    struct multipath *m = pgpath->pg->m;
    unsigned int nr_valid_paths;
    unsigned long flags;

    spin_lock_irqsave(&m->lock, flags);

    if (pgpath->is_active) {
        spin_unlock_irqrestore(&m->lock, flags);
        return 0;  /* already active */
    }

    pgpath->is_active = 1;
    nr_valid_paths = atomic_inc_return(&m->nr_valid_paths); /* path is back */

    if (!m->current_pgpath)
        m->current_pgpath = pgpath;

    /*
     * If bios were queued while no path was available,
     * set run_queue=1 to drain them after releasing the lock.
     */
    if (!bio_list_empty(&m->queued_bios))
        run_queue = 1;

    dm_path_uevent(DM_UEVENT_PATH_REINSTATED, m->ti,
                   pgpath->path.dev->name, nr_valid_paths);

    schedule_work(&m->trigger_event);

    spin_unlock_irqrestore(&m->lock, flags);

    if (run_queue) {
        dm_table_run_md_queue_async(m->ti->table);
        process_queued_io_list(m);   /* drain queued_bios via the work item */
    }

    return r;
}
```

`process_queued_bios` work item:

```c
static void process_queued_bios(struct work_struct *work)
{
    int r;
    unsigned long flags;
    struct bio *bio;
    struct bio_list bios;
    struct multipath *m =
        container_of(work, struct multipath, process_queued_bios);

    bio_list_init(&bios);

    spin_lock_irqsave(&m->lock, flags);
    if (!m->current_pgpath)
        choose_pgpath(m, 0);

    if (!m->current_pgpath || !m->queue_if_no_path) {
        spin_unlock_irqrestore(&m->lock, flags);
        return;
    }

    /* drain queued_bios into local list */
    bio_list_merge(&bios, &m->queued_bios);
    bio_list_init(&m->queued_bios);

    spin_unlock_irqrestore(&m->lock, flags);

    /* resubmit each bio — now choose_pgpath() will find a path */
    while ((bio = bio_list_pop(&bios))) {
        r = dm_map_bio(m->ti, bio);
        if (r < 0 || r == DM_MAPIO_REQUEUE)
            bio->bi_status = BLK_STS_IOERR;
        switch (r) {
        case DM_MAPIO_SUBMITTED:
            break;
        case DM_MAPIO_REMAPPED:
            submit_bio_noacct(bio);
            break;
        default:
            bio_io_error(bio);
        }
    }
}
```

This is why the hang resolves when a path comes back — the queued bios are drained here. If the
LUN is permanently offline (admin action) and no path ever recovers, this work item never runs and
the bios queue forever.

---

## The full no_path_retry=queue hang scenario

```
target LUN offlined (admin: echo offline > /sys/kernel/config/target/iscsi/.../enable)
    │
    ▼  Target returns CHECK CONDITION / NOT READY on all paths
    │
    ▼  scsi_decide_disposition() → NEEDS_RETRY  (or FAILED → EH → DID_NO_CONNECT)
    │
    ▼  EH eventually exhausts, commands complete with BLK_STS_IOERR
    │
    ▼  multipath_end_io(): blk_path_error(BLK_STS_IOERR) = true
    │                      fail_path(pgpath) for each path
    │                      atomic_dec(&m->nr_valid_paths)
    │
    ▼  nr_valid_paths == 0
    │
    ▼  New bios: multipath_map_bio()
    │               choose_pgpath() → NULL
    │               m->queue_if_no_path = 1
    │               bio_list_add(&m->queued_bios, bio)  ← HELD HERE
    │               return DM_MAPIO_SUBMITTED
    │
    ▼  process_queued_bios never runs (no path recovery triggered)
    │
    ▼  Application: write() / read() call never returns
       Any new I/O also queues
       System appears hung from application perspective
```

---

## Key takeaways

- `multipath_map_bio()` is the interception point. `bio_list_add(&m->queued_bios, bio)` when
  `queue_if_no_path=1` and `nr_valid_paths=0` is the exact cause of indefinite hangs.
- `fail_path()` decrements `nr_valid_paths`. When it hits 0, all new bios queue.
- `reinstate_path()` increments `nr_valid_paths` and triggers `process_queued_bios` to drain
  the queue. This never fires if no path recovers.
- `blk_path_error()` returns true for transport errors (`BLK_STS_TRANSPORT`, `BLK_STS_IOERR`,
  etc.) and false for `BLK_STS_NOTSUPP`, `BLK_STS_NOSPC`, `BLK_STS_TARGET`, and
  `BLK_STS_RESV_CONFLICT`. Reservation conflict on normal I/O therefore does NOT fail the path.
- `no_path_retry=N` configures the path-checker retry count. After N retries without a path
  reinstating, `queue_if_no_path` is cleared and queued bios are flushed with -EIO.
- Session drop + login rejection → `DID_TRANSPORT_FAILFAST` → `BLK_STS_TRANSPORT` →
  `fail_path()` is the cleanest path failure signal.
- `schedule_work(&m->trigger_event)` notifies `multipathd` via udev. `multipathd` runs path
  checkers and may call `reinstate_path()` if a path recovers.

---

## Previous / Next

[Day 6 — SCSI error handler](day06.md) | [Day 8 — libiscsi session and connection structs](day08.md)
