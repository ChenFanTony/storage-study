# Day 13 — PR slow path: initiator side

**Week 2**: iSCSI Initiator Kernel Code
**Time**: 1–2 hours
**Reference**: `block/pr.c`, `drivers/scsi/sd.c`, `drivers/md/dm.c`

---

## Overview

This day traces the complete PR (Persistent Reservation) slow path from a userspace `ioctl()` call
all the way down to a SCSI Command PDU on the wire. Three layers are involved: the block layer PR
abstraction (`block/pr.c`), the SCSI disk driver (`drivers/scsi/sd.c`), and the dm-multipath
PR ops (`drivers/md/dm.c`). Understanding this chain explains why PR commands are immune to
`no_path_retry=queue` hangs.

---

## Userspace entry: IOC_PR_RESERVE

Userspace tools (`sg_persist`, `blkpr`, cluster fencing agents) use the `IOC_PR_RESERVE` ioctl:

```c
/* in userspace (simplified) */
struct pr_reservation res = {
    .generation = 0,
    .type       = PR_TYPE_EXCLUSIVE_ACCESS,  /* 0x06 */
    .flags      = 0,
};
ioctl(fd, IOC_PR_RESERVE, &res);
```

This is a standard Linux block device ioctl defined in `include/uapi/linux/pr.h`:

```c
/* PR reservation types */
#define PR_TYPE_WRITE_EXCLUSIVE          1
#define PR_TYPE_EXCLUSIVE_ACCESS         3
#define PR_TYPE_WRITE_EXCLUSIVE_REG_ONLY 5
#define PR_TYPE_EXCLUSIVE_ACCESS_REG_ONLY 6
#define PR_TYPE_WRITE_EXCLUSIVE_ALL_REGS  7
#define PR_TYPE_EXCLUSIVE_ACCESS_ALL_REGS 8

/* IOC_PR_REGISTER:  register a key */
/* IOC_PR_RESERVE:   reserve with registered key */
/* IOC_PR_RELEASE:   release reservation */
/* IOC_PR_PREEMPT:   preempt another holder's reservation */
/* IOC_PR_CLEAR:     clear all registrations */
#define IOC_PR_REGISTER  _IOWR('p', 200, struct pr_registration)
#define IOC_PR_RESERVE   _IOWR('p', 201, struct pr_reservation)
#define IOC_PR_RELEASE   _IOWR('p', 202, struct pr_reservation)
#define IOC_PR_PREEMPT   _IOWR('p', 203, struct pr_preempt)
#define IOC_PR_CLEAR     _IOWR('p', 204, struct pr_clear)
```

---

## blkdev_ioctl dispatch — `block/ioctl.c`

```c
int blkdev_ioctl(struct block_device *bdev, fmode_t mode,
                 unsigned cmd, unsigned long arg)
{
    void __user *argp = (void __user *)arg;

    switch (cmd) {
    /* ... disk geometry, partition, etc ... */

    case IOC_PR_REGISTER:
        return blkdev_pr_register(bdev, argp);

    case IOC_PR_RESERVE:
        /*
         * Calls blk_pr_reserve() in block/pr.c.
         * This is the entry to the block-layer PR abstraction.
         */
        return blkdev_pr_reserve(bdev, argp);

    case IOC_PR_RELEASE:
        return blkdev_pr_release(bdev, argp);

    case IOC_PR_PREEMPT:
        return blkdev_pr_preempt(bdev, argp, false);

    case IOC_PR_CLEAR:
        return blkdev_pr_clear(bdev, argp);
    /* ... */
    }
}
```

```c
static int blkdev_pr_reserve(struct block_device *bdev, struct pr_reservation __user *arg)
{
    struct pr_reservation v;
    if (copy_from_user(&v, arg, sizeof(v)))
        return -EFAULT;
    return blk_pr_reserve(bdev, v.generation, v.type, v.flags);
}
```

---

## blk_pr_reserve — `block/pr.c`

The block-layer PR abstraction. Routes to the appropriate `pr_ops` implementation.

```c
int blk_pr_reserve(struct block_device *bdev, u64 key, enum pr_type type,
                   u32 flags)
{
    const struct pr_ops *ops = bdev->bd_disk->fops->pr_ops;

    /*
     * pr_ops is registered by the disk driver.
     * For /dev/sdX (SCSI disk): ops = &sd_pr_ops (drivers/scsi/sd.c)
     * For /dev/dmX (dm-multipath): ops = &dm_pr_ops (drivers/md/dm.c)
     *
     * This call goes through the ops table — not through blk-mq,
     * not through dm's map_bio(). This is why PR bypasses multipath
     * bio interception entirely.
     */
    if (!ops || !ops->pr_reserve)
        return -EOPNOTSUPP;

    return ops->pr_reserve(bdev, key, type, flags);
}
EXPORT_SYMBOL_GPL(blk_pr_reserve);
```

---

## sd_pr_ops registration — `drivers/scsi/sd.c`

```c
static const struct pr_ops sd_pr_ops = {
    .pr_register  = sd_pr_register,
    .pr_reserve   = sd_pr_reserve,
    .pr_release   = sd_pr_release,
    .pr_preempt   = sd_pr_preempt,
    .pr_clear     = sd_pr_clear,
};

/*
 * Registered during disk allocation:
 * disk->fops = &sd_fops where sd_fops.pr_ops = &sd_pr_ops
 */
static const struct block_device_operations sd_fops = {
    .owner          = THIS_MODULE,
    .open           = sd_open,
    .release        = sd_release,
    .ioctl          = sd_ioctl,
    .getgeo         = sd_getgeo,
    .compat_ioctl   = sd_compat_ioctl,
    .check_events   = sd_check_events,
    .revalidate_disk = sd_revalidate_disk,
    .unlock_native_capacity = sd_unlock_native_capacity,
    .pr_ops         = &sd_pr_ops,    /* ← registered here */
};
```

---

## sd_pr_reserve — `drivers/scsi/sd.c`

Builds the PERSISTENT RESERVE OUT CDB and calls `scsi_execute_cmd()`:

```c
static int sd_pr_reserve(struct block_device *bdev, u64 key,
                          enum pr_type type, u32 flags)
{
    struct scsi_disk *sdkp = scsi_disk(bdev->bd_disk);
    u8 sa;

    /*
     * Map the Linux PR type enum to the SCSI service action code.
     * SCSI SPC-4 Table 22 — PERSISTENT RESERVE OUT service actions:
     *   0x00 = REGISTER
     *   0x01 = RESERVE
     *   0x02 = RELEASE
     *   0x04 = PREEMPT
     *   0x05 = PREEMPT AND ABORT
     *   0x03 = CLEAR
     */
    sa = 0x01; /* RESERVE */

    return sd_pr_out_command(sdkp, sa, key, 0, sd_pr_type(type), 0);
}

static int sd_pr_out_command(struct scsi_disk *sdkp,
                              u8 sa,       /* service action */
                              u64 key,     /* reservation key */
                              u64 sa_key,  /* service action reservation key */
                              u8 type,     /* reservation type */
                              u8 aptpl)    /* Activate Persist Through Power Loss */
{
    struct scsi_device *sdev  = sdkp->device;
    int result;
    u8 cmd[10];          /* 10-byte CDB for PERSISTENT RESERVE OUT */
    u8 data[24];         /* 24-byte parameter list */

    /*
     * Build PERSISTENT RESERVE OUT CDB (SPC-4 section 6.16):
     *
     * Byte 0: 0x5F = PERSISTENT RESERVE OUT opcode
     * Byte 1: bits[4:0] = service action (0x01 = RESERVE)
     * Byte 2: bits[7:4] = scope (0x0 = LU_SCOPE), bits[3:0] = type
     * Bytes 3-6: reserved (0x00)
     * Bytes 7-8: parameter list length (0x0018 = 24 bytes, big-endian)
     * Byte 9: control byte (0x00)
     */
    memset(cmd, 0, sizeof(cmd));
    cmd[0] = PERSISTENT_RESERVE_OUT;   /* 0x5F */
    cmd[1] = sa;                        /* 0x01 (RESERVE) */
    cmd[2] = (0 << 4) | sd_pr_type(type); /* LU_SCOPE | type */
    put_unaligned_be16(sizeof(data), &cmd[7]); /* parameter list length = 24 */

    /*
     * Build 24-byte parameter list (SPC-4 Table 196):
     *
     * Bytes 0-7:   Reservation Key (8 bytes, big-endian)
     *              The key registered via PR REGISTER previously.
     * Bytes 8-15:  Service Action Reservation Key (8 bytes, big-endian)
     *              Used for PREEMPT — 0 for RESERVE.
     * Byte 16:     bits[0] = APTPL (Activate Persist Through Power Loss)
     * Bytes 17-23: reserved (0x00)
     */
    memset(data, 0, sizeof(data));
    put_unaligned_be64(key, &data[0]);    /* reservation key */
    put_unaligned_be64(sa_key, &data[8]); /* service action key */
    data[20] = aptpl & 1;

    /*
     * Submit via scsi_execute_cmd() — the synchronous slow path.
     * REQ_OP_DRV_OUT: passthrough write command.
     * at_head=true: injected at HEAD of dispatch queue (via blk_execute_rq).
     * timeout=SD_TIMEOUT: 30 seconds (HZ * 30).
     * retries=SD_MAX_RETRIES: 5.
     *
     * This call BLOCKS until the SCSI Response PDU arrives from target
     * or timeout fires.
     */
    result = scsi_execute_cmd(sdev, cmd, REQ_OP_DRV_OUT, data, sizeof(data),
                              SD_TIMEOUT, SD_MAX_RETRIES, NULL);

    return result;
}

/* Map Linux pr_type enum to SCSI reservation type byte */
static u8 sd_pr_type(enum pr_type type)
{
    switch (type) {
    case PR_TYPE_WRITE_EXCLUSIVE:          return 0x01;
    case PR_TYPE_EXCLUSIVE_ACCESS:         return 0x03;
    case PR_TYPE_WRITE_EXCLUSIVE_REG_ONLY: return 0x05;
    case PR_TYPE_EXCLUSIVE_ACCESS_REG_ONLY:return 0x06;
    case PR_TYPE_WRITE_EXCLUSIVE_ALL_REGS: return 0x07;
    case PR_TYPE_EXCLUSIVE_ACCESS_ALL_REGS:return 0x08;
    default:                               return 0;
    }
}
```

---

## dm_pr_ops — `drivers/md/dm.c`

When the block device is a dm-multipath device (`/dev/dm-X`), `blk_pr_reserve()` calls
`dm_pr_ops.pr_reserve()` instead of `sd_pr_ops.pr_reserve()`:

```c
static const struct pr_ops dm_pr_ops = {
    .pr_register  = dm_pr_register,
    .pr_reserve   = dm_pr_reserve,
    .pr_release   = dm_pr_release,
    .pr_preempt   = dm_pr_preempt,
    .pr_clear     = dm_pr_clear,
};

static int dm_pr_reserve(struct block_device *bdev, u64 key,
                          enum pr_type type, u32 flags)
{
    struct mapped_device *md = bdev->bd_disk->private_data;
    const struct pr_ops *ops;
    struct dm_target *ti;
    int r, srcu_idx;

    r = dm_get_live_table_use_srcu(md, &srcu_idx);
    if (r)
        return r;

    /*
     * dm_pr_reserve iterates ALL active paths and calls blk_pr_reserve()
     * on each underlying block device (each /dev/sdX path).
     *
     * WHY: SCSI PR state is per I_T (Initiator-Target) nexus. Each path
     * is a different I_T nexus. To have a valid reservation accessible
     * from any path, the reservation key must be registered on each path.
     *
     * If a path is not registered, the target would return
     * RESERVATION CONFLICT for I/O arriving on that path.
     */
    ti = dm_table_find_target(dm_get_live_table(md, &srcu_idx), 0);
    if (ti->type->iterate_devices) {
        r = ti->type->iterate_devices(ti, dm_pr_reserve_fn,
                                       &(struct dm_pr){
                                           .key   = key,
                                           .type  = type,
                                           .flags = flags,
                                       });
    }

    dm_put_live_table(md, srcu_idx);
    return r;
}

/* called once per path by iterate_devices */
static int dm_pr_reserve_fn(struct dm_target *ti,
                             struct dm_dev *dev,
                             sector_t start, sector_t len,
                             void *data)
{
    struct dm_pr *pr = data;
    int r;

    /*
     * Call blk_pr_reserve() on this specific path's block device.
     * dev->bdev is /dev/sdb, /dev/sdc, etc.
     * blk_pr_reserve() → sd_pr_ops.pr_reserve() → sd_pr_reserve()
     * → scsi_execute_cmd() → blk_execute_rq() [synchronous, blocks]
     *
     * This happens for EACH PATH sequentially.
     * PR is registered on every path before returning to userspace.
     */
    r = blk_pr_reserve(dev->bdev, pr->key, pr->type, pr->flags);
    if (r != 0)
        pr->fail_early = true;

    return r; /* 0 = continue to next path, non-0 = stop iteration */
}
```

---

## Why PR is immune to no_path_retry=queue

```
IOC_PR_RESERVE ioctl
    │
    ▼  VFS → blkdev_ioctl()
    │
    ▼  blk_pr_reserve(bdev)
    │  calls disk->fops->pr_ops->reserve()
    │  NOT map_bio(), NOT multipath_map_bio()
    │  → bypasses dm-multipath bio interception entirely
    │
    ▼  [if dm device]: dm_pr_reserve()
    │  iterate_devices() → dm_pr_reserve_fn() per path
    │  calls blk_pr_reserve(path_bdev) for each /dev/sdX
    │
    ▼  [per path]: sd_pr_reserve()
    │  builds CDB: PERSISTENT RESERVE OUT
    │  calls scsi_execute_cmd() with REQ_OP_DRV_OUT
    │
    ▼  scsi_execute_cmd()
    │  allocates request with REQ_OP_DRV_OUT
    │  blk_rq_is_passthrough() = true
    │  blk_execute_rq(at_head=true)
    │    → injects at HEAD of hctx->dispatch
    │    → blk_mq_run_hw_queues() — dispatches immediately
    │    → wait_for_completion_io() — CALLER BLOCKS HERE
    │
    ▼  SCSI Response PDU arrives from target
    │  iscsi_scsi_cmd_rsp() → sc->scsi_done()
    │  blk_end_sync_rq() → complete() → wakes caller
    │
    ▼  scsi_execute_cmd() returns
    │  result: 0 (success), -EIO (RESERVATION CONFLICT or error)
    │
    ▼  sd_pr_reserve() returns to blk_pr_reserve()
    │
    ▼  blkdev_pr_reserve() returns to userspace
    │  ioctl() returns 0 or -ENODEV to the cluster agent
```

At no point does this path touch `m->queued_ios`, `multipath_map_bio()`, or `hctx->dispatch` in
the multipath queue. The PR command goes directly through `dm_pr_ops` → `sd_pr_ops` → `scsi_execute_cmd()`.

---

## Key takeaways

- `blk_pr_reserve()` in `block/pr.c` calls `disk->fops->pr_ops->reserve()` — not `map_bio()`.
  This is why PR bypasses multipath bio interception.
- For plain `/dev/sdX`: `sd_pr_ops.pr_reserve` = `sd_pr_reserve()`.
- For `/dev/dm-X` (multipath): `dm_pr_ops.pr_reserve` = `dm_pr_reserve()` which calls
  `sd_pr_reserve()` once per active path via `iterate_devices()`.
- `sd_pr_reserve()` builds a 10-byte CDB (`0x5F`) + 24-byte parameter list and calls
  `scsi_execute_cmd()` with `REQ_OP_DRV_OUT`.
- `scsi_execute_cmd()` → `blk_execute_rq(at_head=true)` → caller blocks synchronously.
- No blk-mq scheduler, no `hctx->dispatch` queueing, no multipath bio queue — PR is immune to
  `no_path_retry=queue`.
- PR must be issued per-path because SCSI PR state is per I_T nexus.
- `RESERVATION CONFLICT` returns immediately from `scsi_execute_cmd()` as `-EIO` — no retry,
  no EH — and propagates directly to the ioctl caller.

---

## Previous / Next

[Day 12 — session failure and EH interaction](day12.md) | [Day 14 — dm-multipath PR ops and path management](day14.md)
