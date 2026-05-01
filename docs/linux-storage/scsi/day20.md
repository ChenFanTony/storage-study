# Day 20 — LIO Persistent Reservations

**Week 3**: LIO Target Core — Fabric to Backend
**Time**: 1–2 hours
**Reference**: `drivers/target/target_core_pr.c`

---

## Overview

This is the target-side counterpart to day 13 (initiator side). `target_core_pr.c` implements the
complete SCSI SPC-4 Persistent Reservation state machine. It owns the registration list, the
reservation holder, and the `core_scsi3_pr_seq_non_holder()` function that generates
`RESERVATION CONFLICT`. Understanding this file tells you exactly how PR-based fencing works on
the target, and what you would need to replace if implementing an alternative.

---

## PR state overview — two-level structure

SCSI PR has two levels:

```
Level 1: Registration
    Each initiator registers a 64-bit key with the target.
    Registration != reservation. It's just "I exist and here's my key."
    Stored in: se_device->t10_pr_reg_list (list of t10_pr_registration)

Level 2: Reservation
    One registered initiator then acquires the reservation.
    The reservation has a type that determines access rules.
    Stored in: se_device->dev_pr_res_holder (single t10_pr_registration)

PR OUT service actions:
    REGISTER (0x00)      → add/update/remove a registration
    RESERVE  (0x01)      → acquire the reservation (must be registered first)
    RELEASE  (0x02)      → release the reservation
    CLEAR    (0x03)      → clear all registrations AND reservation
    PREEMPT  (0x04)      → steal reservation from another holder
    PREEMPT AND ABORT (0x05) → steal + abort holder's commands
    REGISTER AND IGNORE EXISTING KEY (0x06)
    REGISTER AND MOVE (0x07)
```

---

## core_scsi3_emulate_pro — `drivers/target/target_core_pr.c`

Entry point for PERSISTENT RESERVE OUT. Called from `target_execute_cmd_work()` via
`cmd->execute_cmd`:

```c
sense_reason_t core_scsi3_emulate_pro(struct se_cmd *cmd)
{
    u32 sa;
    /*
     * Service action is in CDB byte 1 bits[4:0].
     * CDB: [0x5F][SA][TYPE<<4|SCOPE][0][0][0][0][PLLen_hi][PLLen_lo][CTL]
     */
    sa = (cmd->t_task_cdb[1] & 0x1f);

    /*
     * Parameter list is in the SGL (set up by transport_generic_new_cmd).
     * For RESERVE/RELEASE: 24 bytes.
     * Read it into a local buffer for parsing.
     */

    switch (sa) {
    case PRO_REGISTER:
    case PRO_REGISTER_AND_IGNORE_EXISTING_KEY:
        return core_scsi3_pro_register(cmd, sa);

    case PRO_RESERVE:
        return core_scsi3_pro_reserve(cmd, sa);

    case PRO_RELEASE:
        return core_scsi3_pro_release(cmd, sa);

    case PRO_CLEAR:
        return core_scsi3_pro_clear(cmd, sa);

    case PRO_PREEMPT:
    case PRO_PREEMPT_AND_ABORT:
        return core_scsi3_pro_preempt(cmd, sa,
            (sa == PRO_PREEMPT_AND_ABORT));

    case PRO_REGISTER_AND_MOVE:
        return core_scsi3_pro_register_and_move(cmd, sa);

    default:
        return TCM_INVALID_CDB_FIELD;
    }
}
```

All these functions run synchronously in the `target_submission_wq` worker. They operate on
in-memory lists with spinlocks — no disk I/O unless APTPL persistence is enabled.

---

## core_scsi3_pro_register — `drivers/target/target_core_pr.c`

```c
static sense_reason_t core_scsi3_pro_register(struct se_cmd *cmd, u32 sa)
{
    struct se_device *dev  = cmd->se_dev;
    struct se_session *sess = cmd->se_sess;
    struct se_node_acl *nacl = sess->se_node_acl;
    struct t10_pr_registration *pr_reg;
    unsigned char *buf;
    u64 res_key, sa_res_key;
    int aptpl;

    /*
     * Parse the 24-byte PR OUT parameter list from the SGL.
     * Bytes 0-7:  Reservation Key (the key already registered, 0 if new)
     * Bytes 8-15: Service Action Reservation Key (new key to register)
     * Byte 16[0]: APTPL (Activate Persist Through Power Loss)
     */
    buf = transport_kmap_data_sg(cmd);
    if (!buf)
        return TCM_LOGICAL_UNIT_COMMUNICATION_FAILURE;

    res_key    = get_unaligned_be64(&buf[0]);  /* current key (0 for new) */
    sa_res_key = get_unaligned_be64(&buf[8]);  /* new key */
    aptpl      = (buf[20] & 0x01);

    transport_kunmap_data_sg(cmd);

    spin_lock(&dev->dev_reservation_lock);

    /*
     * Find existing registration for this I_T nexus.
     * Key = (nacl, lun) pair — one registration per initiator per LUN.
     */
    pr_reg = core_scsi3_locate_pr_reg(dev, nacl,
                                       cmd->se_lun->unpacked_lun);

    if (!pr_reg) {
        /*
         * No existing registration.
         * If res_key != 0: error — can't modify non-existent registration.
         * If res_key == 0: create new registration with sa_res_key.
         */
        if (res_key != 0) {
            spin_unlock(&dev->dev_reservation_lock);
            return TCM_RESERVATION_CONFLICT;
        }

        if (sa_res_key == 0) {
            /* both keys 0: no-op (unregister of non-existent) */
            spin_unlock(&dev->dev_reservation_lock);
            goto out;
        }

        /* Create new t10_pr_registration */
        pr_reg = kzalloc(sizeof(*pr_reg), GFP_ATOMIC);
        if (!pr_reg) {
            spin_unlock(&dev->dev_reservation_lock);
            return TCM_LOGICAL_UNIT_COMMUNICATION_FAILURE;
        }

        pr_reg->pr_res_key   = sa_res_key;  /* the key being registered */
        pr_reg->pr_reg_nacl  = nacl;
        pr_reg->pr_reg_deve  = cmd->se_lun;
        pr_reg->pr_res_mapped_lun = cmd->se_lun->unpacked_lun;
        pr_reg->pr_reg_aptpl = aptpl;

        /*
         * Add to device's registration list.
         * Protected by dev_reservation_lock.
         */
        list_add_tail(&pr_reg->pr_reg_list, &dev->t10_pr_reg_list);

    } else {
        /*
         * Existing registration found.
         * Verify the presented res_key matches the registered key.
         */
        if (pr_reg->pr_res_key != res_key) {
            spin_unlock(&dev->dev_reservation_lock);
            return TCM_RESERVATION_CONFLICT;
        }

        if (sa_res_key == 0) {
            /*
             * Unregister: remove this registration.
             * If this initiator held the reservation, release it.
             */
            if (dev->dev_pr_res_holder == pr_reg) {
                dev->dev_pr_res_holder = NULL;
                dev->dev_t10_pr.pr_res_type = 0;
            }
            list_del(&pr_reg->pr_reg_list);
            kfree(pr_reg);
            pr_reg = NULL;
        } else {
            /* update key */
            pr_reg->pr_res_key = sa_res_key;
        }
    }

    spin_unlock(&dev->dev_reservation_lock);

out:
    target_complete_cmd(cmd, SAM_STAT_GOOD);
    return 0;
}
```

---

## core_scsi3_pro_reserve — `drivers/target/target_core_pr.c`

```c
static sense_reason_t core_scsi3_pro_reserve(struct se_cmd *cmd, u32 sa)
{
    struct se_device *dev  = cmd->se_dev;
    struct se_session *sess = cmd->se_sess;
    struct se_node_acl *nacl = sess->se_node_acl;
    struct t10_pr_registration *pr_reg;
    unsigned char *buf;
    u64 res_key;
    u8 type;

    buf     = transport_kmap_data_sg(cmd);
    res_key = get_unaligned_be64(&buf[0]);
    type    = (cmd->t_task_cdb[2] & 0x0f);  /* reservation type from CDB byte 2 */
    transport_kunmap_data_sg(cmd);

    spin_lock(&dev->dev_reservation_lock);

    /*
     * Find the registration for this initiator.
     * Must be registered before reserving.
     */
    pr_reg = core_scsi3_locate_pr_reg(dev, nacl,
                                       cmd->se_lun->unpacked_lun);
    if (!pr_reg) {
        spin_unlock(&dev->dev_reservation_lock);
        return TCM_RESERVATION_CONFLICT;  /* not registered */
    }

    /* verify key matches registration */
    if (pr_reg->pr_res_key != res_key) {
        spin_unlock(&dev->dev_reservation_lock);
        return TCM_RESERVATION_CONFLICT;
    }

    /*
     * Check if device already has a reservation.
     */
    if (dev->dev_pr_res_holder) {
        /*
         * Device already reserved.
         * If this initiator already holds the reservation: idempotent OK.
         * If another initiator holds it: RESERVATION CONFLICT.
         */
        if (dev->dev_pr_res_holder == pr_reg) {
            /* already our reservation — check type matches */
            if (dev->dev_pr_res_holder->pr_res_type == type) {
                spin_unlock(&dev->dev_reservation_lock);
                goto out_complete;
            }
            spin_unlock(&dev->dev_reservation_lock);
            return TCM_RESERVATION_CONFLICT; /* type mismatch */
        }

        /*
         * Another initiator holds the reservation.
         *
         * Some reservation types allow sharing:
         *   WRITE_EXCLUSIVE_ALL_REGS (0x07): all registered initiators can write
         *   EXCLUSIVE_ACCESS_ALL_REGS (0x08): only registered initiators
         *
         * Check core_scsi3_pr_check_type_conflict() for full rules.
         */
        if (core_scsi3_pr_check_type_conflict(dev, pr_reg, type)) {
            spin_unlock(&dev->dev_reservation_lock);
            return TCM_RESERVATION_CONFLICT;
        }
    }

    /*
     * Acquire the reservation.
     * Set dev_pr_res_holder to this initiator's registration.
     */
    dev->dev_pr_res_holder               = pr_reg;
    dev->dev_t10_pr.pr_res_type          = type;
    dev->dev_t10_pr.pr_res_scope         = (cmd->t_task_cdb[2] >> 4) & 0x0f;
    pr_reg->pr_res_type                  = type;

    spin_unlock(&dev->dev_reservation_lock);

out_complete:
    target_complete_cmd(cmd, SAM_STAT_GOOD);
    return 0;
}
```

---

## core_scsi3_pr_seq_non_holder — the access check — `drivers/target/target_core_pr.c`

Called from `target_submit_cmd()` for every incoming command when a reservation exists:

```c
sense_reason_t core_scsi3_pr_seq_non_holder(struct se_cmd *cmd,
                                              unsigned char *cdb,
                                              u32 pr_res_type)
{
    struct se_device *dev  = cmd->se_dev;
    struct se_session *sess = cmd->se_sess;
    struct se_node_acl *nacl = sess->se_node_acl;
    struct t10_pr_registration *pr_reg;
    bool registered = false;

    /*
     * Check if the command's initiator is registered with this device.
     * "Registered" means has an entry in dev->t10_pr_reg_list.
     */
    pr_reg = core_scsi3_locate_pr_reg(dev, nacl,
                                       cmd->se_lun->unpacked_lun);
    registered = (pr_reg != NULL);

    /*
     * Access rules depend on the reservation type:
     *
     * WRITE_EXCLUSIVE (0x01):
     *   Reads: ALL initiators allowed (registered or not)
     *   Writes: ONLY reservation holder allowed
     *
     * EXCLUSIVE_ACCESS (0x03):
     *   Reads: ALL registered initiators allowed
     *   Writes: ONLY reservation holder allowed
     *   Non-registered initiators: RESERVATION CONFLICT for all I/O
     *
     * WRITE_EXCLUSIVE_REG_ONLY (0x05):
     *   All I/O: ALL registered initiators allowed
     *   Non-registered: RESERVATION CONFLICT for writes, allowed for reads
     *
     * EXCLUSIVE_ACCESS_REG_ONLY (0x06):
     *   All I/O: ALL registered initiators allowed
     *   Non-registered: RESERVATION CONFLICT for ALL I/O
     *
     * WRITE_EXCLUSIVE_ALL_REGS (0x07):
     *   All I/O: ALL registered initiators allowed
     *   Non-registered: RESERVATION CONFLICT for writes
     *
     * EXCLUSIVE_ACCESS_ALL_REGS (0x08):
     *   All I/O: ALL registered initiators allowed
     *   Non-registered: RESERVATION CONFLICT for ALL I/O
     */

    switch (pr_res_type) {
    case PR_TYPE_WRITE_EXCLUSIVE:
        if (dev->dev_pr_res_holder->pr_reg_nacl == nacl)
            return 0;   /* we are the holder — all access allowed */

        /*
         * Check if this is a READ command.
         * WRITE_EXCLUSIVE allows reads from anyone.
         */
        if (cmd->data_direction == DMA_FROM_DEVICE)
            return 0;   /* read — allowed */

        /* write from non-holder: CONFLICT */
        return TCM_RESERVATION_CONFLICT;

    case PR_TYPE_EXCLUSIVE_ACCESS:
        if (dev->dev_pr_res_holder->pr_reg_nacl == nacl)
            return 0;   /* we are the holder */

        /*
         * Exclusive Access: even reads from non-holders are blocked
         * if they are not registered.
         */
        if (!registered)
            return TCM_RESERVATION_CONFLICT;

        /* registered non-holder with read: check command */
        if (cmd->data_direction == DMA_FROM_DEVICE && registered)
            return 0;

        return TCM_RESERVATION_CONFLICT;

    case PR_TYPE_WRITE_EXCLUSIVE_REGONLY:
        if (registered)
            return 0;   /* all registered initiators: full access */
        /* non-registered write: CONFLICT */
        if (cmd->data_direction == DMA_TO_DEVICE)
            return TCM_RESERVATION_CONFLICT;
        return 0;

    case PR_TYPE_EXCLUSIVE_ACCESS_REGONLY:
    case PR_TYPE_EXCLUSIVE_ACCESS_ALLREG:
        if (registered)
            return 0;
        return TCM_RESERVATION_CONFLICT;

    case PR_TYPE_WRITE_EXCLUSIVE_ALLREG:
        if (registered)
            return 0;
        if (cmd->data_direction == DMA_TO_DEVICE)
            return TCM_RESERVATION_CONFLICT;
        return 0;

    default:
        return TCM_RESERVATION_CONFLICT;
    }
}
```

---

## How RESERVATION CONFLICT flows from here to the initiator

```
core_scsi3_pr_seq_non_holder() returns TCM_RESERVATION_CONFLICT
    │
    ▼  (in target_submit_cmd):
transport_generic_request_failure(cmd, TCM_RESERVATION_CONFLICT)
    │  cmd->scsi_status = SAM_STAT_RESERVATION_CONFLICT (0x18)
    │  no sense buffer written
    ▼
target_complete_cmd(cmd, SAM_STAT_RESERVATION_CONFLICT)
    │  INIT_WORK(&cmd->work, target_complete_failure_work)
    │  queue_work(target_completion_wq, &cmd->work)
    ▼
[target_completion_wq worker]
target_complete_failure_work()
    │  → transport_complete_qf()
    ▼
cmd->se_tfo->queue_status(cmd)
    │  = iscsit_queue_status()
    │  cmd->i_state = ISTATE_SEND_STATUS
    │  wake TX thread
    ▼
[TX kthread]
iscsit_send_response()
    │  hdr->cmd_status = 0x18
    │  DataSegmentLength = 0 (no sense)
    │  kernel_sendmsg() → TCP socket
    ▼
Initiator receives SCSI Response PDU with status 0x18
    │  iscsi_scsi_cmd_rsp(): sc->result = DID_OK | 0x18
    │  sc->scsi_done(sc)
    ▼
scsi_done() → scsi_complete() [passthrough path for PR commands]
    │  blk_end_sync_rq() → wakes blk_execute_rq()
    ▼
scsi_execute_cmd() returns -EIO (or the conflict status)
    │  sd_pr_reserve() returns error
    ▼
ioctl(IOC_PR_RESERVE) returns -ENODEV to userspace
```

---

## core_scsi3_locate_pr_reg — O(n) list search

```c
struct t10_pr_registration *core_scsi3_locate_pr_reg(
    struct se_device *dev,
    struct se_node_acl *nacl,
    u64 mapped_lun)
{
    struct t10_pr_registration *pr_reg;

    /*
     * Linear search of dev->t10_pr_reg_list.
     * Key: (nacl pointer, mapped_lun).
     * In practice: small number of registrations per device.
     * Protected by caller holding dev_reservation_lock.
     */
    list_for_each_entry(pr_reg, &dev->t10_pr_reg_list, pr_reg_list) {
        if (pr_reg->pr_reg_nacl == nacl &&
            pr_reg->pr_res_mapped_lun == mapped_lun)
            return pr_reg;
    }
    return NULL;
}
```

For the PR check on EVERY command, this is called under `dev_reservation_lock`. With a small
number of registered initiators (typical: 2-8) this is fast. At scale (hundreds of initiators)
it could be a bottleneck — one reason why alternative fencing mechanisms (session drop + ACL)
are sometimes preferred.

---

## Key takeaways

- PR state is two-level: registrations (all initiators with a key) + reservation (one holder).
- `t10_pr_reg_list` = all registrations. `dev_pr_res_holder` = current reservation holder.
- `core_scsi3_emulate_pro()` dispatches by service action. All operations are synchronous
  (spinlock + list ops) — no disk I/O for in-memory PR state.
- `core_scsi3_pro_reserve()` sets `dev->dev_pr_res_holder`. Only one holder at a time (except
  ALL_REGS types where all registered initiators are considered holders).
- `core_scsi3_pr_seq_non_holder()` is called for EVERY command on a reserved device. Access rules
  depend on reservation type — EXCLUSIVE_ACCESS (0x03) is the strictest.
- `TCM_RESERVATION_CONFLICT` → `transport_generic_request_failure()` → `target_complete_cmd()`
  → `target_completion_wq` → `queue_status()` → `iscsit_send_response()` with `cmd_status=0x18`.
- PR is immune to `no_path_retry=queue` because the conflict is generated and returned before any
  workqueue involvement — it is processed entirely in the PR check inside `target_submit_cmd()`.

---

## Previous / Next

[Day 19 — iSCSI fabric TX thread and Data-Out](day19.md) | [Day 21 — LIO backends](day21.md)
