# Day 22 — Task Management Functions

**Week 4**: Deep Cuts — TMF, ALUA, configfs, NVMe-oF, Sense Data
**Time**: 1–2 hours
**Reference**: `drivers/target/target_core_tmr.c`, `drivers/target/iscsi/iscsi_target_tmr.c`, `drivers/target/target_core_transport.c`

---

## Overview

Task Management Functions (TMF) are out-of-band SCSI commands that control other in-flight
commands. The most important for our context are ABORT TASK (abort a single command) and LOGICAL
UNIT RESET (abort all commands for a LUN). TMF runs in `target_tmr_wq` — the ordered workqueue
(max_active=1). Understanding why it must be serialized, and how it interacts with PR state and
in-flight I/O, is critical for building any fencing or HA mechanism.

---

## iSCSI TMF PDU handling — `drivers/target/iscsi/iscsi_target_tmr.c`

When the RX thread receives opcode `0x02` (SCSI_TMFUNC):

```c
static int iscsit_handle_task_mgt_cmd(struct iscsi_conn *conn,
                                       struct iscsi_tm *hdr)
{
    struct se_tmr_req *tmr_req;
    struct iscsit_cmd *cmd;
    int out_of_order_cmdsn = 0;
    u8 function;

    /*
     * TMF function from BHS byte 1 bits[6:0]:
     *   1 = ABORT TASK
     *   2 = ABORT TASK SET
     *   3 = CLEAR ACA
     *   4 = CLEAR TASK SET
     *   5 = LOGICAL UNIT RESET
     *   6 = TARGET WARM RESET
     *   7 = TARGET COLD RESET
     *   8 = TASK REASSIGN (ERL=2)
     */
    function = hdr->flags & ISCSI_FLAG_TM_FUNC_MASK;

    /*
     * Allocate an iscsit_cmd to carry this TMF through the system.
     * Even TMFs use the same iscsit_cmd / se_cmd infrastructure.
     */
    cmd = iscsit_allocate_cmd(conn, TASK_INTERRUPTIBLE);
    if (!cmd)
        return iscsit_add_reject(conn, ISCSI_REASON_BOOKMARK_NO_RESOURCES,
                                  (unsigned char *)hdr);

    cmd->init_task_tag = hdr->itt;       /* ITT of this TMF */
    cmd->ref_task_tag  = hdr->rtt;       /* Referenced Task Tag (for ABORT TASK) */
    cmd->exp_stat_sn   = be32_to_cpu(hdr->exp_statsn);
    cmd->data_direction = DMA_NONE;
    cmd->tmr_req       = iscsit_allocate_tmr(cmd);
    cmd->tmr_req->function = function;

    /*
     * Convert iSCSI TMF function code to SCSI TMF type
     * (defined in include/target/target_core_base.h TMR_* constants).
     */
    switch (function) {
    case ISCSI_TM_FUNC_ABORT_TASK:
        cmd->tmr_req->se_tmr_type = TMR_ABORT_TASK;
        /*
         * rtt = Referenced Task Tag: the ITT of the command to abort.
         * We need to find the corresponding iscsit_cmd.
         */
        cmd->tmr_req->ref_task_tag = hdr->rtt;
        break;

    case ISCSI_TM_FUNC_LOGICAL_UNIT_RESET:
        cmd->tmr_req->se_tmr_type = TMR_LUN_RESET;
        break;

    case ISCSI_TM_FUNC_TARGET_WARM_RESET:
        cmd->tmr_req->se_tmr_type = TMR_TARGET_WARM_RESET;
        break;

    case ISCSI_TM_FUNC_TARGET_COLD_RESET:
        cmd->tmr_req->se_tmr_type = TMR_TARGET_COLD_RESET;
        break;

    default:
        cmd->tmr_req->se_tmr_type = TMR_UNKNOWN;
        break;
    }

    /*
     * CmdSN ordering: TMF uses CmdSN just like data commands.
     * Out-of-order TMFs are held on ooo_cmdsn_list.
     */
    out_of_order_cmdsn = iscsit_check_cmdsn_order(conn, cmd, hdr->cmdsn);

    if (!out_of_order_cmdsn)
        return iscsit_execute_tmr_cmd(conn, cmd);

    return 0;
}
```

---

## iscsit_execute_tmr_cmd → target_submit_tmr

```c
static int iscsit_execute_tmr_cmd(struct iscsi_conn *conn,
                                   struct iscsit_cmd *cmd)
{
    struct se_session *se_sess = conn->sess->se_sess;

    /*
     * target_submit_tmr() queues the TMF to target_tmr_wq.
     * It does NOT go through target_submission_wq.
     *
     * target_tmr_wq is ORDERED (alloc_ordered_workqueue, max_active=1).
     * This guarantees TMFs execute one at a time, in order.
     *
     * Why ordered?
     *   1. Abort races: two concurrent ABORT_TASK calls on the same
     *      command would both find it, both try to abort it, leading
     *      to use-after-free when the second abort runs after the
     *      command was freed by the first.
     *   2. PR state consistency: LUN RESET clears PR registrations.
     *      A concurrent RESERVE could race with RESET, leaving PR
     *      in an inconsistent state.
     *   3. Session ordering: ABORT_TASK_SET must complete before
     *      any commands it aborted can be re-issued.
     */
    return target_submit_tmr(&cmd->se_cmd, se_sess,
                              cmd->se_cmd.sense_buffer,
                              cmd->se_cmd.orig_fe_lun,
                              cmd->tmr_req,
                              cmd->tmr_req->se_tmr_type,
                              GFP_ATOMIC,
                              cmd->init_task_tag,
                              TARGET_SCF_ACK_KREF);
}
```

```c
/* target_core_transport.c */
int target_submit_tmr(struct se_cmd *se_cmd,
                       struct se_session *se_sess,
                       unsigned char *sense,
                       u64 unpacked_lun,
                       void *fabric_tmr_ptr,
                       unsigned char tm_type,
                       gfp_t gfp,
                       u64 tag,
                       int flags)
{
    struct se_portal_group *se_tpg = se_sess->se_tpg;
    int ret;

    /* initialise the se_cmd */
    transport_init_se_cmd(se_cmd, se_tpg->se_tpg_tfo, se_sess,
                          0, DMA_NONE, TCM_SIMPLE_TAG, sense, unpacked_lun);

    /* LUN lookup — needed so TMF knows which device to operate on */
    ret = transport_lookup_tmr_lun(se_cmd, unpacked_lun);
    if (ret)
        goto failure;

    se_cmd->se_tmr_req = target_alloc_se_tmr(se_cmd, tm_type);
    if (!se_cmd->se_tmr_req)
        goto failure;

    se_cmd->se_tmr_req->fabric_tmr_ptr = fabric_tmr_ptr;

    /*
     * Queue to target_tmr_wq — the ordered TMF workqueue.
     * Worker: target_tmr_work()
     */
    INIT_WORK(&se_cmd->work, target_tmr_work);
    queue_work(target_tmr_wq, &se_cmd->work);

    return 0;
failure:
    transport_generic_request_failure(se_cmd, TCM_LOGICAL_UNIT_COMMUNICATION_FAILURE);
    return ret;
}
EXPORT_SYMBOL(target_submit_tmr);
```

---

## target_tmr_work — `drivers/target/target_core_transport.c`

```c
static void target_tmr_work(struct work_struct *work)
{
    struct se_cmd *cmd = container_of(work, struct se_cmd, work);
    struct se_device *dev = cmd->se_dev;
    struct se_tmr_req *tmr = cmd->se_tmr_req;
    int ret;

    if (cmd->transport_state & CMD_T_ABORTED)
        goto check_stop;

    switch (tmr->function) {
    case TMR_ABORT_TASK:
        /*
         * Find the target command by tag (Referenced Task Tag).
         * core_tmr_abort_task() sets CMD_T_ABORTED on the target command
         * and waits for it to complete via t_transport_stop_comp.
         */
        core_tmr_abort_task(dev, tmr, cmd->se_sess);
        break;

    case TMR_ABORT_TASK_SET:
    case TMR_CLEAR_TASK_SET:
        /*
         * Abort all tasks in the task set for this session.
         * Iterates all se_cmds in se_sess->sess_cmd_list.
         */
        core_tmr_lun_reset(dev, tmr, NULL, cmd);
        break;

    case TMR_LUN_RESET:
        /*
         * Reset the LUN:
         *   1. Abort all in-flight commands for this LUN (all sessions)
         *   2. Clear any UA (Unit Attention) conditions
         *   3. Reset device state (queues, error recovery)
         *   4. Issue UNIT ATTENTION to all other sessions
         *
         * Note: LUN RESET does NOT clear PR registrations in LIO.
         * (Some targets clear PR on reset — LIO follows SPC-4 behavior
         * which says PR is preserved across LUN resets unless APTPL=0.)
         */
        core_tmr_lun_reset(dev, tmr, NULL, cmd);
        break;

    case TMR_TARGET_WARM_RESET:
        /*
         * Reset all LUNs on this target.
         * Clears all in-flight commands on all LUNs.
         */
        core_tmr_lun_reset(dev, tmr, NULL, cmd);
        break;

    case TMR_TARGET_COLD_RESET:
        /* Same as warm reset + power cycle semantics */
        core_tmr_lun_reset(dev, tmr, NULL, cmd);
        break;

    default:
        pr_err("Unhandled TMR function: %d\n", tmr->function);
        tmr->response = TMR_FUNCTION_REJECTED;
        goto check_stop;
    }

check_stop:
    /* Send TMF response PDU back to initiator */
    cmd->se_tfo->queue_tm_rsp(cmd);
    /*
     * For iSCSI: iscsit_queue_tm_rsp() sets i_state = ISTATE_SEND_TASKMGTRSP
     * and wakes the TX thread.
     */
}
```

---

## core_tmr_abort_task — `drivers/target/target_core_tmr.c`

```c
static void core_tmr_abort_task(struct se_device *dev,
                                 struct se_tmr_req *tmr,
                                 struct se_session *se_sess)
{
    struct se_cmd *se_cmd;
    unsigned long flags;
    u64 ref_tag;

    /*
     * ref_tag: the tag (ITT) of the command to abort.
     * Set from hdr->rtt in the ABORT TASK PDU.
     */
    ref_tag = tmr->ref_task_tag;

    spin_lock_irqsave(&se_sess->sess_cmd_lock, flags);

    /*
     * Search sess_cmd_list for the command with matching tag.
     * This is a linear scan — acceptable since sess_cmd_list is bounded
     * by queue_depth (typically 64-256 entries).
     */
    list_for_each_entry(se_cmd, &se_sess->sess_cmd_list, se_cmd_list) {
        if (se_cmd->tag != ref_tag)
            continue;

        /*
         * Found the command. Set CMD_T_ABORTED atomically.
         *
         * This flag is checked at three key points:
         *   1. target_execute_cmd(): if set, don't dispatch to backend
         *   2. iblock_bio_done(): if set, call target_complete_cmd with ABORTED status
         *   3. target_complete_cmd(): if set, route to aborted path instead of normal
         */
        spin_lock(&se_cmd->t_state_lock);

        if (se_cmd->transport_state & CMD_T_COMPLETE) {
            /* command already completed — can't abort */
            spin_unlock(&se_cmd->t_state_lock);
            spin_unlock_irqrestore(&se_sess->sess_cmd_lock, flags);
            tmr->response = TMR_FUNCTION_COMPLETE;
            return;
        }

        se_cmd->transport_state |= CMD_T_ABORTED | CMD_T_STOP;
        spin_unlock(&se_cmd->t_state_lock);

        spin_unlock_irqrestore(&se_sess->sess_cmd_lock, flags);

        /*
         * Wait for the command to reach a stable state.
         * t_transport_stop_comp is completed in target_complete_cmd()
         * when CMD_T_STOP is set.
         *
         * This wait ensures we don't return from ABORT_TASK until the
         * backend I/O is actually done and the command is no longer
         * being processed. Critical for memory safety.
         */
        wait_for_completion_timeout(&se_cmd->t_transport_stop_comp,
                                     msecs_to_jiffies(
                                         se_cmd->se_dev->dev_attrib.emulate_rest_reord ?
                                         30000 : 3000));

        tmr->response = TMR_FUNCTION_COMPLETE;
        return;
    }

    spin_unlock_irqrestore(&se_sess->sess_cmd_lock, flags);

    /* tag not found — command already completed normally */
    tmr->response = TMR_TASK_DOES_NOT_EXIST;
}
```

The `wait_for_completion_timeout()` call is the key safety mechanism. The TMF worker blocks
until the command being aborted has reached `t_transport_stop_comp`. This completion is signalled
in `target_complete_cmd()`:

```c
/* in target_complete_cmd() */
if (cmd->transport_state & CMD_T_ABORTED) {
    if (cmd->transport_state & CMD_T_STOP) {
        spin_unlock_irqrestore(&cmd->t_state_lock, flags);
        complete_all(&cmd->t_transport_stop_comp);  /* wake TMF waiter */
        return;
    }
}
```

---

## core_tmr_lun_reset — `drivers/target/target_core_tmr.c`

```c
int core_tmr_lun_reset(struct se_device *dev,
                        struct se_tmr_req *tmr,
                        struct list_head *preempt_and_abort_list,
                        struct se_cmd *prout_cmd)
{
    struct se_node_acl *acl;
    struct se_session *sess;
    struct se_cmd *cmd;
    unsigned long flags;

    /*
     * Phase 1: Abort all in-flight commands on this device.
     * Walk all sessions, find all se_cmds targeting this device,
     * set CMD_T_ABORTED, wait for each to complete.
     */
    spin_lock_irqsave(&dev->se_port_lock, flags);

    list_for_each_entry(acl, &dev->se_nacl_list, acl_list) {
        spin_lock(&acl->acl_sess_lock);
        list_for_each_entry(sess, &acl->acl_sess_list, sess_list) {
            spin_lock(&sess->sess_cmd_lock);
            list_for_each_entry(cmd, &sess->sess_cmd_list, se_cmd_list) {
                if (cmd->se_dev != dev)
                    continue;
                if (cmd == prout_cmd)
                    continue; /* don't abort the PR OUT that triggered this */

                spin_lock(&cmd->t_state_lock);
                if (!(cmd->transport_state & CMD_T_COMPLETE)) {
                    cmd->transport_state |= CMD_T_ABORTED | CMD_T_STOP;
                }
                spin_unlock(&cmd->t_state_lock);
            }
            spin_unlock(&sess->sess_cmd_lock);
        }
        spin_unlock(&acl->acl_sess_lock);
    }

    spin_unlock_irqrestore(&dev->se_port_lock, flags);

    /*
     * Phase 2: Wait for all aborted commands to drain.
     * Re-scan and wait for each CMD_T_STOP command.
     */
    /* [simplified — actual code does a similar wait loop] */

    /*
     * Phase 3: Issue UNIT ATTENTION to all sessions except the one
     * that issued the LUN RESET.
     * UA sense: POWER ON, RESET, OR BUS DEVICE RESET OCCURRED
     *           sense key=UNIT_ATTENTION, ASC=0x29, ASCQ=0x02
     *
     * Every subsequent command from other initiators will get
     * CHECK CONDITION / UNIT ATTENTION until they clear it.
     */
    core_scsi3_ua_allocate(dev, tmr->task_cmd->se_sess,
                            0x29, 0x02);

    tmr->response = TMR_FUNCTION_COMPLETE;
    return 0;
}
```

---

## PR interaction with LUN RESET

LIO's behavior on LUN RESET with regard to PR (per SPC-4):

```c
/*
 * SPC-4 section 5.9.7: "Persistent reservations and resets"
 *
 * When a LUN is reset:
 *   - If APTPL=0 (Activate Persist Through Power Loss = 0):
 *     All registrations and reservations are cleared.
 *   - If APTPL=1:
 *     Registrations and reservations persist across reset.
 *
 * In LIO: APTPL defaults to 0. On LUN RESET:
 */
static void core_tmr_drain_pr_reg(struct se_device *dev,
                                    struct se_tmr_req *tmr)
{
    if (!dev->dev_t10_pr.pr_aptpl_active) {
        /*
         * Clear all registrations.
         * This means after a LUN RESET, all initiators must re-register
         * before they can reserve the LUN again.
         *
         * Implication for fencing:
         * LUN RESET alone can be used as a fencing mechanism IF
         * the fenced initiator is blocked from re-registering
         * (e.g., ACL manipulation or session drop).
         */
        core_scsi3_free_all_registrations(dev);
        dev->dev_pr_res_holder = NULL;
    }
}
```

---

## TMF Response PDU — iSCSI

When `target_tmr_work()` calls `cmd->se_tfo->queue_tm_rsp(cmd)`:

```c
/* iscsit_queue_tm_rsp() → TX thread → iscsit_send_task_mgt_rsp() */
static int iscsit_send_task_mgt_rsp(struct iscsit_cmd *cmd,
                                     struct iscsi_conn *conn)
{
    struct iscsi_tm_rsp *hdr = (struct iscsi_tm_rsp *)cmd->pdu;

    hdr->opcode   = ISCSI_OP_SCSI_TMFUNC_RSP;  /* 0x22 */
    hdr->flags    = ISCSI_FLAG_CMD_FINAL;
    hdr->itt      = cmd->init_task_tag;
    hdr->statsn   = cpu_to_be32(conn->stat_sn++);
    hdr->exp_cmdsn = cpu_to_be32(conn->sess->exp_cmd_sn);
    hdr->max_cmdsn = cpu_to_be32(
        (u32) atomic_read(&conn->sess->max_cmd_sn));

    /*
     * response byte: TMR function result code.
     * From se_tmr_req->response:
     *   0x00 = TMR_FUNCTION_COMPLETE
     *   0x01 = TMR_TASK_DOES_NOT_EXIST
     *   0x02 = TMR_LUN_DOES_NOT_EXIST
     *   0x03 = TMR_TASK_STILL_ALLEGIANT
     *   0x04 = TMR_TASK_FAILOVER_NOT_SUPPORTED
     *   0x05 = TMR_TASK_MGMT_FUNCTION_NOT_SUPPORTED
     *   0xff = TMR_FUNCTION_REJECTED
     */
    hdr->response = cmd->se_tmr_req->response;

    iscsit_send_tx_data(cmd, conn, 1);
    return 0;
}
```

---

## Why target_tmr_wq must be ordered — race scenario

```
Without ordered TMF queue (hypothetical concurrent execution):

Thread A: ABORT_TASK for cmd X
    → finds cmd X in sess_cmd_list
    → sets CMD_T_ABORTED
    → waits on t_transport_stop_comp

Thread B (concurrent): ABORT_TASK for cmd X (duplicate from reconnect)
    → finds cmd X in sess_cmd_list (still there, waiting)
    → sets CMD_T_ABORTED (already set — no-op but proceeds)
    → waits on t_transport_stop_comp

cmd X backend completes:
    → target_complete_cmd() → complete_all(t_transport_stop_comp)
    → Thread A wakes → TMR response sent → se_cmd freed
    → Thread B wakes → accesses freed se_cmd → USE-AFTER-FREE CRASH

With ordered TMF queue (max_active=1):
Thread A runs to completion first (including se_cmd free).
Thread B then runs, finds tag not in sess_cmd_list → TMR_TASK_DOES_NOT_EXIST.
No crash.
```

---

## Key takeaways

- TMF is received as opcode `0x02` by the iSCSI RX thread → `iscsit_handle_task_mgt_cmd()` →
  `target_submit_tmr()` → `queue_work(target_tmr_wq, ...)`.
- `target_tmr_wq` is ordered (`alloc_ordered_workqueue`, `max_active=1`) — TMFs run serially.
  This prevents use-after-free races between concurrent aborts.
- `core_tmr_abort_task()` sets `CMD_T_ABORTED | CMD_T_STOP` on the target command and waits on
  `t_transport_stop_comp`. The command being aborted signals this when it reaches `target_complete_cmd()`.
- `core_tmr_lun_reset()` aborts ALL in-flight commands for a device, then issues UNIT ATTENTION
  to all other sessions.
- `CMD_T_ABORTED` is checked at three points: before dispatch, during backend completion, and in
  `target_complete_cmd()` — ensuring clean abort at any stage.
- LUN RESET clears PR registrations if `APTPL=0` (default). This makes LUN RESET + ACL denial a
  potential alternative fencing mechanism.
- TMF response PDU uses opcode `0x22` with a `response` byte indicating the TMF result code.

---

## Previous / Next

[Day 21 — LIO backends](day21.md) | [Day 23 — ALUA](day23.md)
