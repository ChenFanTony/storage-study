# Day 16 — target_core_transport: submit path

**Week 3**: LIO Target Core — Fabric to Backend
**Time**: 1–2 hours
**Reference**: `drivers/target/target_core_transport.c`

---

## Overview

`target_core_transport.c` is the engine of LIO. It owns the three workqueues, the command
submission path (`target_submit_cmd` → `transport_generic_new_cmd` → `target_queue_submission`),
and the execution worker (`target_execute_cmd_work`). Understanding this file end-to-end is the
single highest-value thing you can do in week 3. Today covers the submit side; day 17 covers
completion.

---

## The three workqueues — defined in target_core_transport.c

```c
/*
 * Declared at file scope — module-wide, shared across all targets.
 */
struct workqueue_struct *target_completion_wq;
struct workqueue_struct *target_submission_wq;
struct workqueue_struct *target_tmr_wq;

/*
 * Initialised in target_core_init_configfs() at module load:
 */
static int __init target_core_init_configfs(void)
{
    /*
     * WQ_MEM_RECLAIM: guarantee a worker thread is always available,
     * even under severe memory pressure. Critical for a storage target —
     * memory reclaim itself may need I/O to complete.
     *
     * 0 (max_active=0): unlimited concurrency — as many workers as needed.
     */
    target_completion_wq = alloc_workqueue("target_completion",
                                            WQ_MEM_RECLAIM, 0);

    target_submission_wq = alloc_workqueue("target_submission",
                                            WQ_MEM_RECLAIM, 0);

    /*
     * TMF workqueue: ORDERED — max_active=1.
     * Task Management Functions must execute serially.
     * Reason: concurrent ABORT_TASK operations on the same command
     * could race on the PR registration list and command state flags,
     * causing use-after-free or double-completion.
     */
    target_tmr_wq = alloc_ordered_workqueue("target_tmr_wq",
                                             WQ_MEM_RECLAIM);
}
```

All three use `WQ_MEM_RECLAIM` — the kernel guarantees at least one worker thread is always
available regardless of memory pressure. This prevents a deadlock where the storage target needs
to complete I/O to free memory, but can't schedule a worker because memory is exhausted.

---

## target_submit_cmd — `drivers/target/target_core_transport.c`

The entry point called by the fabric layer for every incoming SCSI command. For iSCSI, called
from `iscsit_process_scsi_cmd()` once all write data is received.

```c
sense_reason_t target_submit_cmd(struct se_cmd *se_cmd,
                                  struct se_session *se_sess,
                                  unsigned char *cdb,
                                  unsigned char *sense,
                                  u64 unpacked_lun,
                                  u32 data_length,
                                  int task_attr,
                                  int data_dir,
                                  int flags)
{
    struct se_portal_group *se_tpg = se_sess->se_tpg;
    sense_reason_t rc;

    /*
     * Step 1: Initialise the se_cmd struct.
     * Sets: data_length, data_direction, t_task_cdb, se_sess, se_tfo.
     */
    rc = transport_init_se_cmd(se_cmd, se_tpg->se_tpg_tfo, se_sess,
                                data_length, data_dir, task_attr, sense,
                                unpacked_lun);
    if (rc)
        return rc;

    /*
     * Step 2: Resolve LUN → se_lun → se_device.
     *
     * core_get_se_deve_from_se_lun() looks up the LUN in the initiator's
     * ACL LUN mapping table. If the LUN is not mapped for this initiator,
     * returns TCM_NON_EXISTENT_LUN.
     */
    rc = transport_lookup_cmd_lun(se_cmd, unpacked_lun);
    if (rc) {
        transport_send_check_condition_and_sense(se_cmd, rc, 0);
        return 0;
    }

    /*
     * Step 3: PR check — is this initiator allowed to access this LUN?
     *
     * core_scsi3_pr_seq_non_holder() checks se_device->dev_pr_res_holder.
     * If the device has a reservation AND this initiator is not the holder
     * (and not registered as an all-registrants holder), returns
     * TCM_RESERVATION_CONFLICT.
     *
     * On conflict: transport_generic_request_failure() is called immediately,
     * which calls se_cmd->se_tfo->queue_status(se_cmd).
     * The SCSI Response PDU with status 0x18 is sent back to the initiator.
     * No workqueue involvement — this returns directly from here.
     */
    if (!(flags & TARGET_SCF_ACK_KREF)) {
        rc = target_scsi3_pr_reservation_check(se_cmd);
        if (rc) {
            transport_generic_request_failure(se_cmd, rc);
            return 0;
        }
    }

    /*
     * Step 4: ALUA check — is this target port in an accessible state?
     * Returns TCM_CHECK_CONDITION_UNIT_ATTENTION if ALUA state transition
     * is in progress, or TCM_ALUA_TG_PT_STANDBY if in Standby state.
     */
    rc = target_alua_state_check(se_cmd);
    if (rc) {
        transport_generic_request_failure(se_cmd, rc);
        return 0;
    }

    /*
     * Step 5: Proceed to execution.
     * Allocates SGL, sets up data transfer, queues to target_submission_wq.
     */
    transport_generic_new_cmd(se_cmd);
    return 0;
}
EXPORT_SYMBOL(target_submit_cmd);
```

The PR check at step 3 is what makes PR-based fencing work. `RESERVATION CONFLICT` is generated
here and sent back immediately via `queue_status()` — no workqueue, no backend I/O.

---

## transport_init_se_cmd — initialising the command

```c
sense_reason_t transport_init_se_cmd(struct se_cmd *cmd,
    const struct target_core_fabric_ops *tfo,
    struct se_session *se_sess,
    u32 data_length,
    int data_direction,
    int task_attr,
    unsigned char *sense_buffer,
    u64 unpacked_lun)
{
    init_completion(&cmd->t_transport_stop_comp);
    init_completion(&cmd->cmd_wait_comp);
    spin_lock_init(&cmd->t_state_lock);
    kref_init(&cmd->cmd_kref);
    INIT_LIST_HEAD(&cmd->se_cmd_list);
    INIT_WORK(&cmd->work, NULL);  /* work fn set later before queue_work() */

    cmd->se_tfo         = tfo;
    cmd->se_sess        = se_sess;
    cmd->data_length    = data_length;
    cmd->data_direction = data_direction;
    cmd->sam_task_attr  = task_attr;
    cmd->sense_buffer   = sense_buffer;
    cmd->orig_fe_lun    = unpacked_lun;

    cmd->state_active   = false;

    return 0;
}
```

`INIT_WORK(&cmd->work, NULL)` initialises the `work_struct` without a function. The function is
assigned just before `queue_work()`:
- For submission: `cmd->work.func = target_execute_cmd_work`
- For completion: `cmd->work.func = target_complete_ok_work`

---

## transport_lookup_cmd_lun — LUN resolution

```c
sense_reason_t transport_lookup_cmd_lun(struct se_cmd *se_cmd, u64 unpacked_lun)
{
    struct se_session *se_sess = se_cmd->se_sess;
    struct se_node_acl *nacl  = se_sess->se_node_acl;
    struct se_dev_entry *deve;
    struct se_lun *lun;
    sense_reason_t ret = TCM_NO_SENSE;

    rcu_read_lock();

    /*
     * Look up the LUN in the initiator's ACL LUN hash table.
     * Key: unpacked_lun (the LUN number from the PDU BHS).
     * Value: se_dev_entry which contains a pointer to se_lun.
     */
    deve = target_nacl_find_deve(nacl, unpacked_lun);
    if (!deve) {
        rcu_read_unlock();
        /*
         * LUN not mapped for this initiator.
         * Returns TCM_NON_EXISTENT_LUN → ILLEGAL REQUEST sense,
         * ASC=0x25, ASCQ=0x00 (LOGICAL UNIT NOT SUPPORTED).
         */
        return TCM_NON_EXISTENT_LUN;
    }

    lun = rcu_dereference(deve->se_lun);
    if (!lun) {
        rcu_read_unlock();
        return TCM_NON_EXISTENT_LUN;
    }

    /*
     * Take a percpu_ref on the LUN to keep it alive for the
     * duration of the command. This prevents the LUN from being
     * removed while the command is in flight.
     */
    if (!percpu_ref_tryget_live(&lun->lun_ref)) {
        rcu_read_unlock();
        return TCM_NON_EXISTENT_LUN;
    }

    se_cmd->se_lun   = lun;
    se_cmd->se_dev   = rcu_dereference(lun->lun_se_dev);
    se_cmd->lun_ref_active = true;

    rcu_read_unlock();
    return TCM_NO_SENSE;
}
```

The `percpu_ref_tryget_live()` call is the hot-unplug safety mechanism. If the LUN is being
removed (ref is dead), `tryget_live` returns false and the command gets `NON_EXISTENT_LUN`.

---

## transport_generic_new_cmd — SGL allocation and submission

```c
sense_reason_t transport_generic_new_cmd(struct se_cmd *cmd)
{
    int ret = 0;

    /*
     * Step 1: Allocate scatter-gather list for data transfer.
     *
     * For WRITE: SGL will be filled with incoming data from Data-Out PDUs.
     * For READ:  SGL will be filled by the backend, then sent as Data-In PDUs.
     * For NONE:  no SGL needed (e.g. INQUIRY, TUR, PR OUT parameter list).
     */
    if (cmd->data_direction != DMA_NONE) {
        ret = target_alloc_sgl(&cmd->t_data_sg, &cmd->t_data_nents,
                                cmd->data_length,
                                cmd->data_direction == DMA_FROM_DEVICE,
                                false);
        if (ret < 0)
            return TCM_LOGICAL_UNIT_COMMUNICATION_FAILURE;
    }

    /*
     * Step 2: Call backend's parse_cdb() to validate the CDB and
     * determine which backend handler will execute it.
     * For iblock: sets cmd->execute_cmd = iblock_execute_rw, etc.
     */
    ret = transport_parse_cdb(cmd);
    if (ret)
        return ret;

    /*
     * Step 3: For writes — notify fabric to receive incoming data.
     * For iSCSI: iscsit_alloc_buffs() maps the SGL for Data-Out receive.
     *
     * For reads and no-data: proceed directly to submission.
     */
    if (cmd->data_direction == DMA_TO_DEVICE) {
        /*
         * Fabric must call target_execute_cmd() when data is ready.
         * For iSCSI: called from iscsit_check_dataout_payload()
         * when ICF_GOT_LAST_DATAOUT is set.
         */
        if (!(cmd->se_cmd_flags & SCF_BIDI)) {
            if (cmd->data_direction == DMA_TO_DEVICE &&
                cmd->se_tfo->write_pending) {
                ret = cmd->se_tfo->write_pending(cmd);
                if (ret == -EAGAIN || ret == -ENOMEM)
                    return 0; /* will be called again */
                if (ret < 0)
                    return TCM_LOGICAL_UNIT_COMMUNICATION_FAILURE;
                return 0; /* write data path — wait for data */
            }
        }
    }

    /*
     * Step 4: Queue for execution.
     * For reads and no-data commands: go directly to submission workqueue.
     * For writes: target_execute_cmd() is called later from the fabric
     * when Data-Out is complete.
     */
    target_execute_cmd(cmd);
    return 0;
}
```

---

## target_execute_cmd and target_queue_submission

```c
/*
 * Called when a command is ready to execute:
 *   - For reads/no-data: called from transport_generic_new_cmd()
 *   - For writes: called from iscsit_check_dataout_payload() via
 *     iscsit_process_scsi_cmd() when ICF_GOT_LAST_DATAOUT is set
 */
void target_execute_cmd(struct se_cmd *cmd)
{
    /*
     * Check if a TMF abort has been issued for this command while
     * it was waiting for write data. If so, don't execute it.
     */
    spin_lock_irq(&cmd->t_state_lock);
    if (cmd->transport_state & CMD_T_ABORTED) {
        spin_unlock_irq(&cmd->t_state_lock);
        return;
    }
    cmd->transport_state |= CMD_T_ACTIVE;
    spin_unlock_irq(&cmd->t_state_lock);

    /*
     * OOO CmdSN: if this command arrived out of order, it may need
     * to wait until earlier commands complete (for ordered task sets).
     */
    if (target_cmd_interrupted(cmd))
        return;

    target_queue_submission(cmd);
}
EXPORT_SYMBOL(target_execute_cmd);

static void target_queue_submission(struct se_cmd *cmd)
{
    /*
     * Set the work function and queue to target_submission_wq.
     *
     * INIT_WORK assigns the handler: target_execute_cmd_work().
     * queue_work() schedules it on target_submission_wq.
     *
     * The worker runs on a kthread from the workqueue pool.
     * It calls: cmd->execute_cmd(cmd) = backend's execute_cmd.
     */
    INIT_WORK(&cmd->work, target_execute_cmd_work);
    queue_work(target_submission_wq, &cmd->work);
}
```

---

## target_execute_cmd_work — the submission worker

```c
static void target_execute_cmd_work(struct work_struct *work)
{
    struct se_cmd *cmd = container_of(work, struct se_cmd, work);
    sense_reason_t rc;

    /*
     * Check CDB emulation first.
     * Some commands are handled entirely in target_core without
     * going to the backend at all:
     *   - INQUIRY (returns VPD pages, device identification)
     *   - MODE SENSE / MODE SELECT
     *   - REPORT LUNS
     *   - TEST UNIT READY (always returns GOOD if LUN exists)
     *   - REQUEST SENSE
     *
     * Emulated commands complete here without touching the backend.
     */
    if (cmd->execute_cmd) {
        /*
         * execute_cmd is set by parse_cdb():
         *   For READ/WRITE: iblock_execute_rw, fd_execute_rw, pscsi_execute_cmd
         *   For PR OUT: core_scsi3_emulate_pro (handled in target_core_pr.c)
         *   For emulated: target_emulate_inquiry, target_emulate_modesense, etc.
         */
        rc = cmd->execute_cmd(cmd);

        if (rc) {
            spin_lock_irq(&cmd->t_state_lock);
            cmd->transport_state &= ~CMD_T_ACTIVE;
            spin_unlock_irq(&cmd->t_state_lock);
            transport_generic_request_failure(cmd, rc);
            return;
        }

        /*
         * For backend I/O (iblock, fileio):
         * execute_cmd() returns 0 immediately — I/O is async.
         * Completion comes later via target_complete_cmd() called
         * from the block layer completion callback (iblock_bio_done).
         *
         * For emulated commands (INQUIRY, etc.):
         * execute_cmd() completes synchronously and calls
         * target_complete_cmd() before returning.
         *
         * For PR OUT:
         * core_scsi3_emulate_pro() runs synchronously (spinlock + list ops)
         * and calls target_complete_cmd() before returning.
         */
    }
}
```

---

## target_scsi3_pr_reservation_check — the PR gate

```c
static sense_reason_t target_scsi3_pr_reservation_check(struct se_cmd *cmd)
{
    struct se_device *dev  = cmd->se_dev;
    struct se_session *sess = cmd->se_sess;

    /*
     * If the device has no reservation, all commands pass.
     */
    if (!dev->dev_pr_res_holder)
        return TCM_NO_SENSE;

    /*
     * Device has a reservation. Check if this command's initiator
     * is the holder or is allowed access under the reservation type.
     *
     * core_scsi3_pr_seq_non_holder() returns:
     *   0 = allowed (is the holder, or reservation type permits access)
     *   TCM_RESERVATION_CONFLICT = denied
     *
     * See target_core_pr.c for full logic per reservation type.
     */
    return core_scsi3_pr_seq_non_holder(cmd, (unsigned char *)cmd->t_task_cdb,
                                         dev->dev_pr_res_holder->pr_res_type);
}
```

When `TCM_RESERVATION_CONFLICT` is returned:

```c
/* in target_submit_cmd: */
rc = target_scsi3_pr_reservation_check(se_cmd);
if (rc) {
    transport_generic_request_failure(se_cmd, rc);
    return 0;
}

/* transport_generic_request_failure with TCM_RESERVATION_CONFLICT: */
void transport_generic_request_failure(struct se_cmd *cmd, sense_reason_t reason)
{
    switch (reason) {
    case TCM_RESERVATION_CONFLICT:
        cmd->scsi_status = SAM_STAT_RESERVATION_CONFLICT;
        /* no sense data for RESERVATION CONFLICT — it has its own status */
        cmd->scsi_sense_reason = TCM_RESERVATION_CONFLICT;
        /*
         * Queue completion immediately — no workqueue, no backend I/O.
         * This calls target_complete_ok_work() inline or via completion_wq.
         */
        target_complete_cmd(cmd, SAM_STAT_RESERVATION_CONFLICT);
        return;
    /* ... other sense reasons ... */
    }
}
```

---

## Full submit path timeline

```
iscsit_process_scsi_cmd()                [iSCSI fabric]
    │  all write data received (ICF_GOT_LAST_DATAOUT set, or read/no-data)
    ▼
target_submit_cmd(se_cmd, se_sess, cdb, …)
    │
    ├── transport_init_se_cmd()           initialise se_cmd fields + work_struct
    ├── transport_lookup_cmd_lun()        LUN → se_lun → se_device (RCU)
    ├── target_scsi3_pr_reservation_check()
    │       → if conflict: transport_generic_request_failure()
    │                       → target_complete_cmd(RESERVATION_CONFLICT)
    │                       → queue_status() → SCSI Response PDU → done
    ├── target_alua_state_check()
    └── transport_generic_new_cmd()
            │
            ├── target_alloc_sgl()        allocate scatter-gather list
            ├── transport_parse_cdb()     set cmd->execute_cmd function pointer
            └── target_execute_cmd()
                    │
                    ├── CMD_T_ACTIVE set
                    └── target_queue_submission()
                            │
                            ├── INIT_WORK(&cmd->work, target_execute_cmd_work)
                            └── queue_work(target_submission_wq, &cmd->work)
                                        │
                                        ▼  [target_submission_wq worker]
                                target_execute_cmd_work()
                                    │  cmd->execute_cmd(cmd)
                                    ▼
                                backend: iblock_execute_rw()  /  core_scsi3_emulate_pro()
```

---

## Key takeaways

- `target_submission_wq` and `target_completion_wq` use `WQ_MEM_RECLAIM` + unlimited concurrency.
- `target_tmr_wq` is ordered (`alloc_ordered_workqueue`) — TMF functions run serially.
- `target_submit_cmd()` is the fabric→core boundary. LUN resolution, PR check, and ALUA check
  all happen here before any workqueue involvement.
- `TCM_RESERVATION_CONFLICT` from the PR check → `transport_generic_request_failure()` →
  `target_complete_cmd()` immediately — no workqueue delay. This is why PR conflict responses
  are fast and deterministic.
- `transport_generic_new_cmd()` allocates the SGL and sets `cmd->execute_cmd` function pointer.
- `target_queue_submission()` sets `cmd->work.func = target_execute_cmd_work` and calls
  `queue_work(target_submission_wq, &cmd->work)`.
- In the worker: `cmd->execute_cmd(cmd)` dispatches to the backend. For I/O: async (returns 0
  immediately, completion comes later). For PR/emulated: synchronous (calls `target_complete_cmd`
  before returning).

---

## Previous / Next

[Day 15 — target core structs](day15.md) | [Day 17 — target_core_transport completion path](day17.md)
