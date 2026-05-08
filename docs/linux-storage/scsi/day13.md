# Day 13 — PR slow path: initiator side

**Week 2**: iSCSI Initiator Kernel Code  
**Time**: 1–2 hours  
**Reference**: `drivers/scsi/sd.c`, `block/blk-ioc.c`, `include/uapi/linux/pr.h`, `block/ioctl.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

Persistent Reservations (PR) are SCSI-3's mechanism for fencing — claiming exclusive access to a
LUN such that other initiators get RESERVATION CONFLICT. On the initiator side, PR is exposed
through the kernel's `pr_ops` interface. The path from a `multipathd` userspace ioctl down to a
SCSI PERSISTENT RESERVE OUT PDU on the wire passes through several layers, each of which is
critical to understand for the fencing problem.

---

## struct pr_ops — `include/linux/blkdev.h`

```c
struct pr_ops {
    int (*pr_register)(struct block_device *bdev,
                       u64 old_key, u64 new_key,
                       u32 flags);
    int (*pr_reserve)(struct block_device *bdev,
                      u64 key,
                      enum pr_type type,
                      u32 flags);
    int (*pr_release)(struct block_device *bdev,
                      u64 key,
                      enum pr_type type);
    int (*pr_preempt)(struct block_device *bdev,
                      u64 old_key, u64 new_key,
                      enum pr_type type, bool abort);
    int (*pr_clear)(struct block_device *bdev,
                    u64 key);
    int (*pr_read_keys)(struct block_device *bdev,
                        struct pr_keys *keys_info);
    int (*pr_read_reservation)(struct block_device *bdev,
                                struct pr_held_reservation *rsv);
};
```

Block devices register a `pr_ops` table to expose PR. Two table sets exist:
- `sd_pr_ops` — for `/dev/sdX` (single SCSI path) — `drivers/scsi/sd.c`
- `dm_pr_ops` — for `/dev/mapper/mpathN` (dm-multipath) — `drivers/md/dm.c`

---

## include/uapi/linux/pr.h — userspace types

```c
/* PR reservation types — Linux abstraction */
enum pr_type {
    PR_WRITE_EXCLUSIVE              = 1,
    PR_EXCLUSIVE_ACCESS             = 2,
    PR_WRITE_EXCLUSIVE_REG_ONLY     = 3,
    PR_EXCLUSIVE_ACCESS_REG_ONLY    = 4,
    PR_WRITE_EXCLUSIVE_ALL_REGS     = 5,
    PR_EXCLUSIVE_ACCESS_ALL_REGS    = 6,
};

/* These are NOT the same as the SCSI PR type byte values — sd_pr_type()
 * translates between Linux PR_* and the on-the-wire SCSI Type field. */

struct pr_registration {
    __u64   old_key;
    __u64   new_key;
    __u32   flags;
    __u32   __pad;
};

struct pr_reservation {
    __u64   key;
    __u32   type;     /* one of enum pr_type */
    __u32   flags;
};

struct pr_preempt {
    __u64   old_key;
    __u64   new_key;
    __u32   type;
    __u32   flags;
};

#define IOC_PR_REGISTER             _IOW('p', 200, struct pr_registration)
#define IOC_PR_RESERVE              _IOW('p', 201, struct pr_reservation)
#define IOC_PR_RELEASE              _IOW('p', 202, struct pr_reservation)
#define IOC_PR_PREEMPT              _IOW('p', 203, struct pr_preempt)
#define IOC_PR_PREEMPT_ABORT        _IOW('p', 204, struct pr_preempt)
#define IOC_PR_CLEAR                _IOW('p', 205, struct pr_clear)
```

`multipathd` (or any userspace) opens `/dev/sdX` or `/dev/mapper/mpathN` and issues these ioctls
with the appropriate struct.

---

## blkdev_pr_ioctl — userspace entry — `block/ioctl.c`

```c
/* Simplified — see block/ioctl.c. */
static int blkdev_pr_register(struct block_device *bdev,
                               struct pr_registration __user *arg)
{
    const struct pr_ops *ops = bdev->bd_disk->fops->pr_ops;
    struct pr_registration reg;

    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;
    if (!ops || !ops->pr_register)
        return -EOPNOTSUPP;
    if (copy_from_user(&reg, arg, sizeof(reg)))
        return -EFAULT;
    if (reg.flags & ~PR_FL_IGNORE_KEY)
        return -EOPNOTSUPP;
    return ops->pr_register(bdev, reg.old_key, reg.new_key, reg.flags);
}
```

For `/dev/sdX`: `ops = &sd_pr_ops`.
For `/dev/mapper/mpathN`: `ops = &dm_pr_ops`.

---

## sd_pr_ops — direct SCSI path — `drivers/scsi/sd.c`

```c
const struct pr_ops sd_pr_ops = {
    .pr_register      = sd_pr_register,
    .pr_reserve       = sd_pr_reserve,
    .pr_release       = sd_pr_release,
    .pr_preempt       = sd_pr_preempt,
    .pr_clear         = sd_pr_clear,
    .pr_read_keys     = sd_pr_read_keys,
    .pr_read_reservation = sd_pr_read_reservation,
};
```

### sd_pr_register

```c
/* Simplified — see drivers/scsi/sd.c. */
static int sd_pr_register(struct block_device *bdev,
                           u64 old_key, u64 new_key,
                           u32 flags)
{
    struct scsi_disk *sdkp = scsi_disk(bdev->bd_disk);
    /*
     * Build PR OUT REGISTER parameter list (24 bytes per SPC-4 §6.13.3):
     *   0..7   reservation key (current)
     *   8..15  service action reservation key (new)
     *   16     scope/type (0 for register)
     *   17     flags (APTPL bit)
     *   18..23 reserved
     */
    struct {
        __be64  reservation_key;
        __be64  sa_reservation_key;
        u8      reserved1[4];
        u8      flags;
        u8      reserved2[3];
    } data;

    memset(&data, 0, sizeof(data));
    put_unaligned_be64(old_key, &data.reservation_key);
    put_unaligned_be64(new_key, &data.sa_reservation_key);

    /*
     * Service action 0x00 = REGISTER (with old_key check)
     * 0x06 = REGISTER_AND_IGNORE_EXISTING_KEY (when PR_FL_IGNORE_KEY set)
     */
    return sd_pr_out_command(sdkp,
                              flags & PR_FL_IGNORE_KEY ? 0x06 : 0x00,
                              old_key, new_key, 0, &data, sizeof(data));
}
```

### sd_pr_reserve

```c
static int sd_pr_reserve(struct block_device *bdev,
                          u64 key,
                          enum pr_type type,
                          u32 flags)
{
    struct scsi_disk *sdkp = scsi_disk(bdev->bd_disk);
    struct {
        __be64  reservation_key;
        __be64  sa_reservation_key;   /* must be 0 for RESERVE */
        u8      reserved1[4];
        u8      flags;
        u8      reserved2[3];
    } data = {0};

    if (flags)
        return -EOPNOTSUPP;

    put_unaligned_be64(key, &data.reservation_key);

    /*
     * service action = 0x01 (RESERVE)
     * sd_pr_type() translates Linux pr_type → SCSI PR type byte
     */
    return sd_pr_out_command(sdkp, 0x01, key, 0,
                              sd_pr_type(type), &data, sizeof(data));
}

static u8 sd_pr_type(enum pr_type type)
{
    switch (type) {
    case PR_WRITE_EXCLUSIVE:              return 0x01;
    case PR_EXCLUSIVE_ACCESS:             return 0x03;
    case PR_WRITE_EXCLUSIVE_REG_ONLY:     return 0x05;
    case PR_EXCLUSIVE_ACCESS_REG_ONLY:    return 0x06;
    case PR_WRITE_EXCLUSIVE_ALL_REGS:     return 0x07;
    case PR_EXCLUSIVE_ACCESS_ALL_REGS:    return 0x08;
    default:                              return 0;
    }
}
```

### sd_pr_out_command — building the CDB

```c
/* Simplified. */
static int sd_pr_out_command(struct scsi_disk *sdkp, u8 sa,
                              u64 key, u64 sa_key, u8 type,
                              void *data, int data_len)
{
    struct scsi_device *sdev = sdkp->device;
    u8 cmd[10] = {0};
    int result;
    struct scsi_sense_hdr sshdr;

    /*
     * PERSISTENT RESERVE OUT CDB (SPC-4 §6.13.1):
     *   byte 0: opcode = 0x5F
     *   byte 1: service action (5 bits)
     *   byte 2: scope (4 bits, always 0) | type (4 bits)
     *   bytes 3-6: reserved
     *   bytes 7-8: parameter list length (big-endian)
     *   byte 9: control
     */
    cmd[0] = PERSISTENT_RESERVE_OUT;  /* 0x5F */
    cmd[1] = sa;
    cmd[2] = type;
    cmd[7] = (data_len >> 8) & 0xff;
    cmd[8] = data_len & 0xff;

    result = scsi_execute_cmd(sdev, cmd, REQ_OP_DRV_OUT,
                               data, data_len,
                               SD_TIMEOUT, SD_MAX_RETRIES,
                               &(struct scsi_exec_args){
                                   .sshdr     = &sshdr,
                                   .req_flags = BLK_MQ_REQ_PM,
                               });

    if (driver_byte(result) != 0)
        sd_print_sense_hdr(sdkp, &sshdr);

    return result;
}
```

This is where the slow path begins. `scsi_execute_cmd()` (day 4) is called with:
- `cmd` = 10-byte CDB starting with 0x5F (PERSISTENT RESERVE OUT)
- `REQ_OP_DRV_OUT` — marks request as passthrough
- `data` = the 24-byte parameter list (PR keys)
- `SD_TIMEOUT` = 30 seconds, `SD_MAX_RETRIES` = 5

`scsi_execute_cmd()` calls `blk_execute_rq()` which:
1. Allocates request with `REQ_OP_DRV_OUT`
2. Maps the 24-byte buffer into SGL via `blk_rq_map_kern()`
3. Inserts at HEAD of `hctx->dispatch` via `BLK_MQ_INSERT_AT_HEAD`
4. Runs the queue (calls `iscsi_queuecommand()`)
5. `wait_for_completion_io()` — caller sleeps

Eventually the target responds (RESERVATION CONFLICT or GOOD), the RX path completes the task,
`scsi_done()` short-circuits via `scsi_complete()`, and the caller wakes.

---

## dm_pr_ops — multipath path — `drivers/md/dm.c`

When the application opens `/dev/mapper/mpathN` instead of a path device, PR ops go through
dm-multipath:

```c
static const struct pr_ops dm_pr_ops = {
    .pr_register      = dm_pr_register,
    .pr_reserve       = dm_pr_reserve,
    .pr_release       = dm_pr_release,
    .pr_preempt       = dm_pr_preempt,
    .pr_clear         = dm_pr_clear,
};
```

### dm_pr_register — fan-out across all paths

```c
/* Simplified — see drivers/md/dm.c. */
static int dm_pr_register(struct block_device *bdev,
                           u64 old_key, u64 new_key,
                           u32 flags)
{
    struct mapped_device *md = bdev->bd_disk->private_data;
    struct dm_pr pr = {
        .old_key  = old_key,
        .new_key  = new_key,
        .flags    = flags,
        .fail_early = true,
    };
    int ret;

    /*
     * Iterate over all paths in the dm device.
     * For each path: call __dm_pr_register() which dispatches
     * down to the underlying /dev/sdX → sd_pr_register().
     *
     * fail_early=true means stop on first error. Setting fail_early=false
     * allows the loop to continue and aggregate errors — useful for
     * "register on all paths even if some fail" semantics.
     */
    ret = dm_call_pr(bdev, __dm_pr_register, &pr);

    return ret;
}

static int __dm_pr_register(struct dm_target *ti,
                             struct dm_dev *dev,
                             sector_t start, sector_t len,
                             void *data)
{
    struct dm_pr *pr = data;
    const struct pr_ops *ops = dev->bdev->bd_disk->fops->pr_ops;

    if (!ops || !ops->pr_register)
        return -EOPNOTSUPP;

    /*
     * Recursive call to sd_pr_register() on the underlying /dev/sdX.
     * Each path is registered separately so each I_T nexus has the same key.
     */
    return ops->pr_register(dev->bdev,
                             pr->old_key, pr->new_key, pr->flags);
}
```

### dm_pr_reserve — only one path holds the reservation

```c
static int dm_pr_reserve(struct block_device *bdev,
                          u64 key,
                          enum pr_type type,
                          u32 flags)
{
    struct mapped_device *md = bdev->bd_disk->private_data;

    /*
     * Reserve only needs to be issued on ONE path — the reservation
     * is held by the I_T_L nexus (per SPC-4) but PR with type
     * PR_*_ALL_REGS allows any registered path to issue commands.
     *
     * dm uses the current_pgpath via dm_get_live_table().
     */
    return dm_blk_ioctl(bdev, ... /* dispatched via the active path */);
}
```

In practice, `multipathd` registers on every path (so each I_T nexus is registered) and reserves
only on one. The `*_ALL_REGS` types ensure all registered initiators can write.

---

## Why PR is the right primitive for fencing

When the cluster decides node A should not access shared storage anymore:

```
Cluster decision: fence node A
    │
    ▼
Surviving node B issues PR PREEMPT
    │  → SCSI: PERSISTENT RESERVE OUT, sa=0x04 (PREEMPT)
    │     parameter list contains node A's key
    ▼
Target processes PREEMPT
    │  → core_scsi3_pro_preempt()
    │  → invalidates node A's registration
    │  → node B becomes the sole holder
    ▼
Node A continues running, attempts I/O
    │  → all reads/writes return RESERVATION CONFLICT
    │  → BLK_STS_RESV_CONFLICT (modern kernels)
    │  → blk_path_error() = false → multipath does NOT fail path
    │  → application sees -EIO immediately on every I/O
    ▼
Node A is fenced — cannot corrupt shared storage
```

The crucial property: PR PREEMPT happens through `dm_pr_ops` → `sd_pr_ops` →
`scsi_execute_cmd()` → `blk_execute_rq()` — completely separate from `submit_bio()` and
`multipath_map_bio()`. PR commands can succeed even when normal I/O is hung in `m->queued_bios`,
because they take a different path entirely.

---

## Comparing the two paths

```
NORMAL READ/WRITE                          PR REGISTER/RESERVE/PREEMPT
─────────────────                          ───────────────────────────
application: write(fd, buf, len)           application: ioctl(fd, IOC_PR_RESERVE, ...)
    │                                          │
    ▼                                          ▼
VFS / page cache                           blkdev_pr_ioctl()
submit_bio()                                   │
    │                                          ▼
multipath_map_bio()                        bdev->bd_disk->fops->pr_ops->pr_reserve()
    │                                          │  (dm_pr_reserve or sd_pr_reserve)
    │  if no path: bio_list_add(queued_bios)   ▼
    │  → HANG until path returns           sd_pr_reserve()
    ▼                                          │
choose_pgpath()                                ▼
    │                                      sd_pr_out_command()
    ▼                                          │
bio remapped to /dev/sdX                       ▼
    │                                      scsi_execute_cmd()
    ▼                                          │  REQ_OP_DRV_OUT (passthrough)
iscsi_queuecommand()                           ▼
    │                                      blk_execute_rq(at_head=true)
    ▼                                          │  inserts at HEAD of hctx->dispatch
TX worker → TCP                                │  bypasses scheduler
    │                                          ▼
    │                                      iscsi_queuecommand()
                                               │
                                               ▼
                                           TX worker → TCP
                                               │
                                               ▼
                                           wait_for_completion_io()
                                               │
                                               │  (sleeps on stack-allocated completion)
                                               │
                                           target responds (PR success or conflict)
                                               │
                                               ▼
                                           caller wakes, returns -EIO or 0
```

The PR path NEVER touches `multipath_map_bio()`, NEVER queues in `m->queued_bios`, and is NEVER
subject to `no_path_retry=queue` queueing. It can complete on the very session that has all
normal I/O hung — provided a TCP connection still exists and the LUN is still mapped.

---

## Key takeaways

- `pr_ops` is the kernel's PR abstraction. `sd_pr_ops` for `/dev/sdX`, `dm_pr_ops` for
  `/dev/mapper/mpathN`.
- PR ioctls flow: userspace → `blkdev_pr_ioctl()` → `pr_ops->pr_*` → CDB construction →
  `scsi_execute_cmd()` → `blk_execute_rq()` (slow path).
- `REQ_OP_DRV_OUT` is the key flag — marks the request as passthrough at every layer.
- For dm-multipath, `dm_pr_register` fans out via `dm_call_pr()` to each path's `sd_pr_register`.
  `dm_pr_reserve` only reserves on the active path.
- The Linux `enum pr_type` values (1–6) are NOT the same as SCSI PR type byte values
  (`0x01`–`0x08`). `sd_pr_type()` translates between them.
- PR commands NEVER traverse `multipath_map_bio()` and are NEVER subject to
  `no_path_retry=queue`. This is how fencing succeeds even when normal I/O hangs.
- `multipathd` is the typical caller — registers keys on session start and preempts on fencing.

---

## Previous / Next

[Day 12 — session failure and EH interaction](day12.md) | [Day 14 — dm-multipath PR ops and path management](day14.md)
