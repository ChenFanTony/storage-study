# Day 17 — target_core_transport: completion path

**Week 3**: LIO Target Core — Fabric to Backend
**Time**: 1–2 hours
**Reference**: `drivers/target/target_core_transport.c`

---

## Overview

The completion path runs in `target_completion_wq`. It takes a completed `se_cmd` (from either
the backend or the PR/emulation inline path), stamps the final SCSI status and sense data, and
calls the fabric's `queue_status()` to send the response PDU back to the initiator. Understanding
every step here explains how `RESERVATION CONFLICT`, `CHECK CONDITION`, and `GOOD` statuses are
generated and how they get back to the initiator.

---

## target_complete_cmd — `drivers/target/target_core_transport.c`

The entry point for all completions. Called by:
- Backend I/O done: `iblock_bio_done()` → `target_complete_cmd()`
- PR emulation done: `core_scsi3_emulate_pro()` → `target_complete_cmd()`
- Request failure: `transport_generic_request_failure()` → `target_complete_cmd()`
- TMF completion: `core_tmr_abort_task()` → `target_complete_cmd()`

```c
void target_complete_cmd(struct se_cmd *cmd, u8 scsi_status)
{
    int success;

    spin_lock_irqsave(&cmd->t_state_lock, flags);

    /*
     * If CMD_T_ABORTED is set, this command was aborted by a TMF.
     * Don't send a normal SCSI response — the TMF handler deals with it.
     */
    if (cmd->transport_state & CMD_T_ABORTED) {
        /*
         * Complete the transport stop — unblock the TMF waiter.
         */
        if (cmd->transport_state & CMD_T_STOP) {
            spin_unlock_irqrestore(&cmd->t_state_lock, flags);
            complete_all(&cmd->t_transport_stop_comp);
            return;
        }
        spin_unlock_irqrestore(&cmd->t_state_lock, flags);
        target_handle_aborted_cmd(cmd);
        return;
    }

    /*
     * Stamp the SCSI status on the command.
     * scsi_status = SAM_STAT_GOOD (0x00) for success
     *             = SAM_STAT_CHECK_CONDITION (0x02) for errors with sense
     *             = SAM_STAT_RESERVATION_CONFLICT (0x18) for PR conflict
     *             = SAM_STAT_TASK_ABORTED (0x40) for TMF abort
     */
    cmd->scsi_status = scsi_status;

    success = (scsi_status == SAM_STAT_GOOD);
    cmd->transport_state &= ~CMD_T_ACTIVE;

    spin_unlock_irqrestore(&cmd->t_state_lock, flags);

    /*
     * Queue to the completion workqueue.
     * work.func is set to either:
     *   target_complete_ok_work  — command completed successfully or with sense
     */
    INIT_WORK(&cmd->work, success ? target_complete_ok_work :
                                     target_complete_failure_work);
    queue_work(target_completion_wq, &cmd->work);
}
EXPORT_SYMBOL(target_complete_cmd);
```

---

## target_complete_ok_work — the completion worker

```c
static void target_complete_ok_work(struct work_struct *work)
{
    struct se_cmd *cmd = container_of(work, struct se_cmd, work);
    int rc;

    /*
     * For reads: queue data to the initiator first via queue_data_in().
     * The fabric sends Data-In PDUs. When all data is sent, the fabric
     * calls se_tfo->queue_status() to send the final status PDU.
     *
     * For writes and no-data: go directly to queue_status().
     */
    if (cmd->data_direction == DMA_FROM_DEVICE) {
        /*
         * For iSCSI: iscsit_queue_data_in() sends Data-In PDUs.
         * If the S-bit optimisation is enabled, the last Data-In PDU
         * carries the SCSI status piggybacked — no separate Response PDU.
         */
        rc = cmd->se_tfo->queue_data_in(cmd);
        if (rc == -EAGAIN || rc == -ENOMEM) {
            /* fabric temporarily unable — requeue */
            goto queue_full;
        }
        return;
    }

    /*
     * For writes, no-data (INQUIRY, PR OUT, TUR), and errors:
     * call queue_status() to send the SCSI Response PDU.
     *
     * For iSCSI: queue_status = iscsit_queue_status()
     *   → iscsit_send_response()
     *   → TX kthread
     *   → SCSI Response PDU on wire
     *
     * The SCSI Response PDU carries:
     *   - Status field: cmd->scsi_status (0x00, 0x02, 0x18, etc.)
     *   - Sense data (if CHECK CONDITION): from cmd->sense_buffer
     *   - ResidualCount (if underrun/overrun)
     *   - StatSN, ExpCmdSN, MaxCmdSN (window management)
     */
    rc = cmd->se_tfo->queue_status(cmd);
    if (rc == -EAGAIN || rc == -ENOMEM)
        goto queue_full;

    return;

queue_full:
    /*
     * Fabric temporarily busy (TX buffer full).
     * Requeue to try again.
     */
    transport_handle_queue_full(cmd, cmd->se_dev, rc, false);
}
```

---

## transport_generic_request_failure — generating sense data

Called when a command fails anywhere in the path (PR conflict, ALUA denial, backend error, etc.):

```c
void transport_generic_request_failure(struct se_cmd *cmd,
                                        sense_reason_t reason)
{
    /*
     * Map the TCM_* sense reason to SCSI sense key / ASC / ASCQ.
     * The sense data is written into cmd->sense_buffer (96 bytes).
     */
    switch (reason) {
    case TCM_NON_EXISTENT_LUN:
        /* ILLEGAL REQUEST, ASC=0x25 (LU NOT SUPPORTED) */
        cmd->scsi_status = SAM_STAT_CHECK_CONDITION;
        scsi_build_sense(cmd->sense_buffer, 0,
                         ILLEGAL_REQUEST, 0x25, 0x00);
        break;

    case TCM_UNSUPPORTED_SCSI_OPCODE:
        /* ILLEGAL REQUEST, ASC=0x20 (INVALID COMMAND OPERATION CODE) */
        cmd->scsi_status = SAM_STAT_CHECK_CONDITION;
        scsi_build_sense(cmd->sense_buffer, 0,
                         ILLEGAL_REQUEST, 0x20, 0x00);
        break;

    case TCM_SECTOR_COUNT_TOO_MANY:
    case TCM_LOGICAL_BLOCK_ADDRESS_OUT_OF_RANGE:
        /* ILLEGAL REQUEST, ASC=0x21 (LBA OUT OF RANGE) */
        cmd->scsi_status = SAM_STAT_CHECK_CONDITION;
        scsi_build_sense(cmd->sense_buffer, 0,
                         ILLEGAL_REQUEST, 0x21, 0x00);
        break;

    case TCM_WRITE_PROTECTED:
        /* DATA PROTECT, ASC=0x27 (WRITE PROTECTED) */
        cmd->scsi_status = SAM_STAT_CHECK_CONDITION;
        scsi_build_sense(cmd->sense_buffer, 0,
                         DATA_PROTECT, 0x27, 0x00);
        break;

    case TCM_CHECK_CONDITION_UNIT_ATTENTION:
        /* UNIT ATTENTION — generated for power-on, mode change, etc. */
        cmd->scsi_status = SAM_STAT_CHECK_CONDITION;
        /* sense data already set by caller */
        break;

    case TCM_RESERVATION_CONFLICT:
        /*
         * RESERVATION CONFLICT is NOT a CHECK CONDITION.
         * It has its own SCSI status byte (0x18).
         * No sense data is attached.
         * The Response PDU status field = 0x18, data segment = empty.
         */
        cmd->scsi_status     = SAM_STAT_RESERVATION_CONFLICT;
        cmd->scsi_sense_reason = TCM_RESERVATION_CONFLICT;
        /* NO sense buffer written — RESERVATION CONFLICT needs none */
        goto queue_status;  /* skip sense building, go straight to complete */

    case TCM_LOGICAL_UNIT_COMMUNICATION_FAILURE:
        /*
         * NOT READY — hardware error or LUN offline.
         * HARDWARE ERROR, ASC=0x08 (LOGICAL UNIT COMMUNICATION FAILURE)
         */
        cmd->scsi_status = SAM_STAT_CHECK_CONDITION;
        scsi_build_sense(cmd->sense_buffer, 0,
                         HARDWARE_ERROR, 0x08, 0x00);
        break;

    case TCM_ALUA_TG_PT_STANDBY:
        /*
         * ALUA: target port is in Standby state.
         * NOT READY, ASC=0x04, ASCQ=0x0B (LOGICAL UNIT NOT ACCESSIBLE,
         * TARGET PORT IN STANDBY STATE)
         */
        cmd->scsi_status = SAM_STAT_CHECK_CONDITION;
        scsi_build_sense(cmd->sense_buffer, 0,
                         NOT_READY, 0x04, 0x0B);
        break;

    /* ... many more cases ... */
    }

    target_complete_cmd(cmd, cmd->scsi_status);
    return;

queue_status:
    target_complete_cmd(cmd, cmd->scsi_status);
}
EXPORT_SYMBOL(target_generic_request_failure);
```

---

## target_complete_failure_work — the failure completion worker

```c
static void target_complete_failure_work(struct work_struct *work)
{
    struct se_cmd *cmd = container_of(work, struct se_cmd, work);

    /*
     * For commands that completed with an error (CHECK CONDITION,
     * RESERVATION CONFLICT, etc.):
     * queue_status() sends the SCSI Response PDU with the error status
     * and sense data.
     *
     * The iSCSI Response PDU for CHECK CONDITION:
     *   - Status = 0x02 (CHECK CONDITION)
     *   - DataSegmentLength = 2 + sense_length (2-byte length prefix)
     *   - Data segment = [sense_length(2)] [sense_buffer]
     *
     * The iSCSI Response PDU for RESERVATION CONFLICT:
     *   - Status = 0x18
     *   - DataSegmentLength = 0 (no sense data)
     */
    transport_complete_qf(cmd);
}

static void transport_complete_qf(struct se_cmd *cmd)
{
    int rc = 0;

    if (cmd->se_cmd_flags & SCF_TRANSPORT_TASK_SENSE)
        rc = cmd->se_tfo->queue_status(cmd);

    if (!rc)
        rc = cmd->se_tfo->queue_status(cmd);

    if (rc)
        transport_handle_queue_full(cmd, cmd->se_dev, rc, false);
}
```

---

## target_put_sess_cmd — reference counting and cleanup

```c
void target_put_sess_cmd(struct se_cmd *se_cmd)
{
    /*
     * Drop the command reference. When it reaches 0, the command
     * memory is released.
     *
     * kref_put() calls target_release_cmd_kref() when count = 0:
     *   - removes se_cmd from se_sess->sess_cmd_list
     *   - releases LUN reference: percpu_ref_put(&se_cmd->se_lun->lun_ref)
     *   - calls se_cmd->se_tfo->check_stop_free() → iscsit_check_stop_free()
     *   - frees SGL pages
     *   - calls fabric's release function to free the se_cmd memory
     *     (for iSCSI: the iscsit_cmd contains the se_cmd inline)
     */
    kref_put(&se_cmd->cmd_kref, target_release_cmd_kref);
}

static void target_release_cmd_kref(struct kref *kref)
{
    struct se_cmd *se_cmd = container_of(kref, struct se_cmd, cmd_kref);
    struct se_session *se_sess = se_cmd->se_sess;
    struct completion *compl = NULL;
    unsigned long flags;

    spin_lock_irqsave(&se_sess->sess_cmd_lock, flags);
    list_del_init(&se_cmd->se_cmd_list);

    /*
     * If session teardown is waiting for commands to drain,
     * wake it when the list becomes empty.
     */
    if (se_sess->sess_tearing_down && list_empty(&se_sess->sess_cmd_list))
        compl = &se_sess->sess_wait_comp;
    spin_unlock_irqrestore(&se_sess->sess_cmd_lock, flags);

    /* release LUN reference */
    if (se_cmd->lun_ref_active)
        percpu_ref_put(&se_cmd->se_lun->lun_ref);

    /* free SGL */
    transport_free_pages(se_cmd);

    /* fabric cleanup */
    se_cmd->se_tfo->release_cmd(se_cmd);

    if (compl)
        complete(compl);  /* wake session teardown waiter */
}
```

`sess_tearing_down` + `sess_cmd_list` drain is the safe session teardown mechanism (day 25). When
`target_wait_for_sess_cmds()` is called during `iscsit_close_session()`, it waits for
`sess_cmd_list` to become empty. Each `target_release_cmd_kref()` call checks this and wakes
the waiter when the last command is released.

---

## Complete completion path for RESERVATION CONFLICT

```
core_scsi3_pr_seq_non_holder() returns TCM_RESERVATION_CONFLICT
    │  (called from target_submit_cmd → target_scsi3_pr_reservation_check)
    ▼
transport_generic_request_failure(cmd, TCM_RESERVATION_CONFLICT)
    │  cmd->scsi_status = SAM_STAT_RESERVATION_CONFLICT (0x18)
    │  no sense data written (RESERVATION CONFLICT needs none)
    ▼
target_complete_cmd(cmd, SAM_STAT_RESERVATION_CONFLICT)
    │  INIT_WORK(&cmd->work, target_complete_failure_work)
    │  queue_work(target_completion_wq, &cmd->work)
    ▼
[target_completion_wq worker fires]
target_complete_failure_work()
    │  → transport_complete_qf()
    ▼
cmd->se_tfo->queue_status(cmd)
    │  = iscsit_queue_status(cmd)  [for iSCSI]
    ▼
iscsit_send_response(conn, cmd)
    │  builds SCSI Response PDU:
    │    opcode = ISCSI_OP_SCSI_CMD_RSP (0x21)
    │    cmd_status = 0x18 (RESERVATION CONFLICT)
    │    DataSegmentLength = 0 (no sense)
    │    StatSN, ExpCmdSN, MaxCmdSN (window fields)
    │  TX kthread sends PDU over TCP socket
    ▼
Initiator receives SCSI Response PDU
    │  iscsi_scsi_cmd_rsp() (day 11):
    │    sc->result = DID_OK | SAM_STAT_RESERVATION_CONFLICT
    │    sc->scsi_done(sc)
    ▼
scsi_done() → scsi_complete() [passthrough]
    │  blk_end_sync_rq() → complete() → wakes blk_execute_rq()
    ▼
scsi_execute_cmd() returns
    │  sd_pr_reserve() returns error
    ▼
blk_pr_reserve() returns -ENODEV to ioctl caller
    │  ioctl() returns -ENODEV to userspace
    ▼
Cluster fencing agent sees: reservation failed → fencing complete
```

---

## Complete completion path for a successful READ

```
iblock_bio_done() called by block layer completion softirq
    │  target_complete_cmd(cmd, SAM_STAT_GOOD)
    ▼
target_complete_cmd()
    │  cmd->scsi_status = SAM_STAT_GOOD
    │  INIT_WORK(&cmd->work, target_complete_ok_work)
    │  queue_work(target_completion_wq, &cmd->work)
    ▼
[target_completion_wq worker]
target_complete_ok_work()
    │  data_direction == DMA_FROM_DEVICE
    ▼
cmd->se_tfo->queue_data_in(cmd)
    │  = iscsit_queue_data_in(cmd)
    │  → iscsit_send_datain() × N PDUs
    │    each Data-In PDU: BHS + data segment from SGL
    │    last PDU: F=1, S=1 (status piggybacked) → status = GOOD
    ▼
Initiator receives Data-In PDUs + final status
    │  iscsi_data_in_rsp() per PDU
    │  on S=1: sc->result = DID_OK | SAM_STAT_GOOD
    │           iscsi_complete_scsi_task() → sc->scsi_done(sc)
    ▼
scsi_done() → blk_complete_request() → softirq → scsi_io_completion()
    │  scsi_decide_disposition() → SUCCESS
    │  blk_mq_complete_request() → bio_endio()
    ▼
VFS / filesystem / application: read() returns data
```

---

## Key takeaways

- `target_complete_cmd()` stamps `scsi_status`, sets `cmd->work.func`, and calls
  `queue_work(target_completion_wq, &cmd->work)`.
- `target_complete_ok_work()` runs in completion_wq. For reads: `queue_data_in()` first, then
  `queue_status()`. For writes/no-data: `queue_status()` directly.
- `transport_generic_request_failure()` maps `TCM_*` reason codes to SCSI status + sense data.
  `TCM_RESERVATION_CONFLICT` maps to `SAM_STAT_RESERVATION_CONFLICT` (0x18) with no sense data.
- `queue_status()` = fabric callback = `iscsit_queue_status()` for iSCSI → builds and queues the
  SCSI Response PDU to the TX kthread.
- `target_put_sess_cmd()` drops the cmd reference. When 0: removes from `sess_cmd_list`, releases
  LUN ref, frees SGL, calls fabric release. Wakes session teardown waiter if list empty.
- `sess_tearing_down` + `sess_cmd_list` drain = the safe shutdown mechanism for fencing.
- `CMD_T_ABORTED` prevents double-completion when a TMF aborts a command that's also completing.

---

## Previous / Next

[Day 16 — target_core_transport submit path](day16.md) | [Day 18 — iSCSI fabric RX thread](day18.md)
