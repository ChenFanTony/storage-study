# Day 22 — Task Management Functions

**Week 4**: Advanced Topics  
**Time**: 1–2 hours  
**Reference**: `drivers/target/target_core_tmr.c`, `drivers/target/iscsi/iscsi_target.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

Task Management Functions (TMFs) are out-of-band SCSI requests that abort or reset state. The
SAM-defined TMFs are: ABORT TASK, ABORT TASK SET, CLEAR ACA, CLEAR TASK SET, LOGICAL UNIT
RESET, TARGET WARM RESET, TARGET COLD RESET, QUERY TASK. iSCSI carries TMFs via PDU opcode 0x02
(SCSI Task Management Function Request). On the LIO target side, TMFs run on the ordered TMR
workqueue (`target_tmr_wq`) to prevent races on `sess_cmd_list`.

---

## TMF flow on the target

```
iSCSI RX thread receives Task Mgmt Function Request PDU
    │
    ▼
iscsit_handle_task_mgt_cmd()              [iscsi_target.c]
    │  parse function code, ITT, RefTaskTag, LUN
    │  build se_cmd as TMR via transport_init_se_cmd()
    ▼
target_submit_tmr()                        [target_core_transport.c]
    │  attach se_tmr_req with function and reference
    │  queue work to target_tmr_wq (ordered)
    ▼
core_tmr_lun_reset() / core_tmr_abort_task() / core_tmr_clear_task_set()
    │  walk se_sess->sess_cmd_list (target_get_sess_cmd_kref per cmd)
    │  set CMD_T_ABORTED on selected commands
    │  wait for backend completion (or abort-in-flight)
    │  drop kref taken during walk
    ▼
target_complete_tmr_cmd()
    │  cmd->se_tfo->queue_tm_rsp(cmd)
    ▼
iscsit_queue_tm_rsp() → TX thread sends Task Mgmt Response PDU
```

---

## struct se_tmr_req — `include/target/target_core_base.h`

```c
struct se_tmr_req {
    u8                          function;          /* TMR_* code */
    u8                          response;          /* TMR_FUNCTION_* result */

    u64                         ref_task_tag;      /* ITT to abort, for ABORT TASK */
    void                        *fabric_tmr_ptr;   /* fabric-private state */

    struct se_cmd               *task_cmd;         /* the command being aborted */

    struct se_device            *tmr_dev;
    struct se_lun               *tmr_lun;

    struct list_head            tmr_list;
};

/* function codes — see RFC 7143 §11.6 / SAM-5 */
enum tcm_tmreq_table {
    TMR_ABORT_TASK              = 1,
    TMR_ABORT_TASK_SET          = 2,
    TMR_CLEAR_ACA               = 3,
    TMR_CLEAR_TASK_SET          = 4,
    TMR_LUN_RESET               = 5,
    TMR_TARGET_WARM_RESET       = 6,
    TMR_TARGET_COLD_RESET       = 7,
    TMR_LUN_RESET_PRO           = 8,    /* internal — used by PR PREEMPT_AND_ABORT */
};

/* response codes — what target sends back */
enum tcm_tmrsp_table {
    TMR_FUNCTION_FAILED         = 0,
    TMR_FUNCTION_COMPLETE       = 1,
    TMR_TASK_DOES_NOT_EXIST     = 2,
    TMR_LUN_DOES_NOT_EXIST      = 3,
    TMR_TASK_STILL_ALLEGIANT    = 4,
    TMR_TASK_FAILOVER_NOT_SUPPORTED = 5,
    TMR_TASK_MGMT_FUNCTION_NOT_SUPPORTED = 6,
    TMR_FUNCTION_AUTHORIZATION_FAILED = 7,
    TMR_FUNCTION_REJECTED       = 255,
};

/* These map to iSCSI TMF response codes per RFC 7143 §11.6;
 * iscsit_send_task_mgt_rsp() does the translation. */
```

---

## iscsit_handle_task_mgt_cmd — RX side

```c
/* Simplified — see drivers/target/iscsi/iscsi_target.c. */
int iscsit_handle_task_mgt_cmd(struct iscsit_conn *conn, struct iscsi_hdr *hdr)
{
    struct iscsi_tm *tm_hdr = (struct iscsi_tm *)hdr;
    struct iscsit_cmd *cmd;
    int ret;
    u8 function;

    cmd = iscsit_allocate_cmd(conn, TASK_INTERRUPTIBLE);
    if (!cmd)
        return -1;

    cmd->iscsi_opcode = ISCSI_OP_SCSI_TMFUNC;
    cmd->init_task_tag = tm_hdr->itt;
    cmd->cmd_sn = be32_to_cpu(tm_hdr->cmdsn);
    cmd->exp_stat_sn = be32_to_cpu(tm_hdr->exp_statsn);

    /* low 7 bits of flags = TMF function code */
    function = tm_hdr->flags & ISCSI_FLAG_TM_FUNC_MASK;

    /*
     * Sequence in CmdSN window — TMFs may be Immediate (skip ordering)
     * or non-immediate (queued).
     */
    ret = iscsit_sequence_cmd(conn, cmd, (unsigned char *)hdr, tm_hdr->cmdsn);
    if (ret < 0)
        goto err;

    /* set up se_tmr_req */
    cmd->se_cmd.se_tmr_req = transport_alloc_se_tmr_req(NULL);
    cmd->se_cmd.se_tmr_req->function = iscsi_tmf_to_tcm_tmr(function);
    cmd->se_cmd.se_tmr_req->ref_task_tag = tm_hdr->rtt;

    /*
     * Submit to target core. target_submit_tmr() queues the work item
     * to target_tmr_wq (ordered queue).
     */
    ret = target_submit_tmr(&cmd->se_cmd, conn->sess->se_sess,
                              cmd->sense_buffer + 2,
                              scsilun_to_int(&tm_hdr->lun),
                              cmd->se_cmd.se_tmr_req->ref_task_tag,
                              cmd->se_cmd.se_tmr_req->function,
                              GFP_KERNEL, 0, 0);
    return ret;

err:
    iscsit_release_cmd(&cmd->se_cmd);
    return -1;
}

static u8 iscsi_tmf_to_tcm_tmr(u8 iscsi_tmf)
{
    switch (iscsi_tmf) {
    case ISCSI_TM_FUNC_ABORT_TASK:                  return TMR_ABORT_TASK;
    case ISCSI_TM_FUNC_ABORT_TASK_SET:              return TMR_ABORT_TASK_SET;
    case ISCSI_TM_FUNC_CLEAR_ACA:                   return TMR_CLEAR_ACA;
    case ISCSI_TM_FUNC_CLEAR_TASK_SET:              return TMR_CLEAR_TASK_SET;
    case ISCSI_TM_FUNC_LOGICAL_UNIT_RESET:          return TMR_LUN_RESET;
    case ISCSI_TM_FUNC_TARGET_WARM_RESET:           return TMR_TARGET_WARM_RESET;
    case ISCSI_TM_FUNC_TARGET_COLD_RESET:           return TMR_TARGET_COLD_RESET;
    default:                                        return 0;
    }
}
```

---

## target_submit_tmr — `drivers/target/target_core_transport.c`

```c
/* Simplified. */
int target_submit_tmr(struct se_cmd *se_cmd, struct se_session *se_sess,
                       unsigned char *sense, u64 unpacked_lun,
                       u64 tag, u8 function, gfp_t gfp_mask, ...)
{
    transport_init_se_cmd(se_cmd, se_sess->se_tpg->se_tpg_tfo,
                          se_sess, 0, DMA_NONE, TCM_SIMPLE_TAG, sense,
                          unpacked_lun);

    se_cmd->se_tmr_req->function = function;
    se_cmd->se_tmr_req->ref_task_tag = tag;

    /*
     * Bind to the LUN (unless LUN_RESET — special case, doesn't need a
     * specific LUN). transport_lookup_tmr_lun() takes the lun_ref.
     */
    if (function != TMR_LUN_RESET) {
        ret = transport_lookup_tmr_lun(se_cmd);
        if (ret)
            goto out;
    }

    /*
     * Queue work to ordered TMR workqueue.
     * Strict FIFO — only one TMR runs at a time per device.
     */
    INIT_WORK(&se_cmd->work, target_tmr_work);
    queue_work(target_tmr_wq, &se_cmd->work);

    return 0;
}

static void target_tmr_work(struct work_struct *work)
{
    struct se_cmd *cmd = container_of(work, struct se_cmd, work);
    struct se_tmr_req *tmr = cmd->se_tmr_req;
    int ret;

    switch (tmr->function) {
    case TMR_ABORT_TASK:
        ret = core_tmr_abort_task(cmd->se_dev, tmr, cmd->se_sess);
        break;
    case TMR_ABORT_TASK_SET:
    case TMR_CLEAR_TASK_SET:
        ret = core_tmr_clear_task_set(cmd, cmd->se_dev, cmd->se_sess);
        break;
    case TMR_LUN_RESET:
    case TMR_LUN_RESET_PRO:
        ret = core_tmr_lun_reset(cmd->se_dev, tmr,
                                   /* preempt_and_abort_list = */ NULL,
                                   cmd);
        break;
    case TMR_TARGET_WARM_RESET:
    case TMR_TARGET_COLD_RESET:
        ret = TMR_FUNCTION_REJECTED;  /* most fabrics don't support */
        break;
    default:
        ret = TMR_FUNCTION_REJECTED;
    }

    tmr->response = ret;
    cmd->se_tfo->queue_tm_rsp(cmd);
}
```

---

## core_tmr_abort_task — single-task abort

```c
/* Simplified — see drivers/target/target_core_tmr.c. */
int core_tmr_abort_task(struct se_device *dev, struct se_tmr_req *tmr,
                          struct se_session *se_sess)
{
    struct se_cmd *se_cmd;
    unsigned long flags;
    bool found = false;

    spin_lock_irqsave(&se_sess->sess_cmd_lock, flags);

    list_for_each_entry(se_cmd, &se_sess->sess_cmd_list, se_cmd_list) {
        /*
         * Match by ITT (ref_task_tag).
         * The fabric stored the initiator's ITT in se_cmd→tag.
         */
        if (se_cmd->tag != tmr->ref_task_tag)
            continue;

        /* take a kref so cmd doesn't get released while we operate */
        if (!target_get_sess_cmd_kref(se_cmd))
            continue;

        spin_unlock_irqrestore(&se_sess->sess_cmd_lock, flags);

        /*
         * Mark for abort. target_handle_aborted_cmd takes care of
         * draining: if backend I/O is in progress, wait for it; if not,
         * complete with TASK_ABORTED.
         */
        target_handle_aborted_cmd(se_cmd);

        /*
         * Wait for the command to actually leave the in-flight state.
         * Backend may take a while if a bio is mid-flight.
         */
        wait_for_completion(&se_cmd->t_transport_stop_comp);

        target_put_sess_cmd(se_cmd);
        found = true;
        break;
    }

    if (!found)
        spin_unlock_irqrestore(&se_sess->sess_cmd_lock, flags);

    return found ? TMR_FUNCTION_COMPLETE : TMR_TASK_DOES_NOT_EXIST;
}
```

The kref-during-walk pattern (day 17) is what keeps `se_cmd` alive while we examine and operate
on it. Without the kref, a normal completion could free the cmd between the walk's `list_for_each`
finding it and our `target_handle_aborted_cmd()` touching it.

---

## core_tmr_lun_reset — LUN-wide abort

```c
/* Simplified. */
int core_tmr_lun_reset(struct se_device *dev, struct se_tmr_req *tmr,
                         struct list_head *preempt_and_abort_list,
                         struct se_cmd *prout_cmd)
{
    struct se_session *se_sess;
    struct se_cmd *se_cmd, *next_cmd;
    LIST_HEAD(drain_task_list);

    /*
     * Walk every session that touches this device.
     * For each session: walk sess_cmd_list, collect commands that
     * target this LUN and were not preempt_and_abort filtered.
     */
    spin_lock(&dev->se_port_lock);
    list_for_each_entry(se_sess, &dev->dev_sess_list, sess_list) {
        spin_lock(&se_sess->sess_cmd_lock);
        list_for_each_entry_safe(se_cmd, next_cmd,
                                   &se_sess->sess_cmd_list, se_cmd_list) {
            if (preempt_and_abort_list &&
                !cmd_in_preempt_list(preempt_and_abort_list, se_cmd))
                continue;

            if (!target_get_sess_cmd_kref(se_cmd))
                continue;

            list_move_tail(&se_cmd->state_list, &drain_task_list);
        }
        spin_unlock(&se_sess->sess_cmd_lock);
    }
    spin_unlock(&dev->se_port_lock);

    /*
     * Abort each collected command. Wait for completion individually
     * so partial backend I/O can drain cleanly.
     */
    list_for_each_entry_safe(se_cmd, next_cmd, &drain_task_list, state_list) {
        list_del_init(&se_cmd->state_list);
        target_handle_aborted_cmd(se_cmd);
        wait_for_completion_timeout(&se_cmd->t_transport_stop_comp,
                                      ABORT_TIMEOUT);
        target_put_sess_cmd(se_cmd);
    }

    /*
     * For non-PR LUN_RESET: clear the SCSI-2 reservation (legacy
     * RESERVE/RELEASE) but DO NOT touch SPC-3 PR registrations.
     * SPC-4 says PR is preserved across LUN reset (when APTPL is
     * meaningful and on the same nexus). LIO follows this — the
     * core_tmr_drain_pr_reg() helper exists for explicit PR clears
     * via PREEMPT_AND_ABORT, not normal LUN reset.
     */
    spin_lock(&dev->dev_reservation_lock);
    if (dev->dev_reserved_node_acl) {
        dev->dev_reserved_node_acl = NULL;
        dev->dev_reservation_flags = 0;
    }
    spin_unlock(&dev->dev_reservation_lock);

    /* queue UNIT ATTENTION on every initiator: 0x29/0x00 POWER ON, RESET */
    core_scsi3_ua_allocate_for_lun_reset(dev);

    return TMR_FUNCTION_COMPLETE;
}
```

The interaction between LUN_RESET and PR is subtle and worth being precise about: SPC-4
preserves SPC-3 PR registrations across LUN reset by default. SCSI-2 reserve/release state is
cleared. PR PREEMPT_AND_ABORT is the explicit operation for tearing down PR registrations and
aborting their commands together.

---

## target_handle_aborted_cmd — the abort body

```c
/* Simplified. */
void target_handle_aborted_cmd(struct se_cmd *cmd)
{
    unsigned long flags;
    bool send_response;

    spin_lock_irqsave(&cmd->t_state_lock, flags);
    cmd->transport_state |= CMD_T_ABORTED;
    send_response = !(cmd->transport_state & CMD_T_TAS);
    spin_unlock_irqrestore(&cmd->t_state_lock, flags);

    /*
     * If TAS bit set: send TASK ABORTED status (0x40) to other
     * initiators with the same I_T_L (per SAM-5 §7.5.7).
     */
    if (cmd->transport_state & CMD_T_TAS)
        target_send_task_aborted_status(cmd);

    /*
     * If backend I/O is mid-flight: bio completion will see
     * CMD_T_ABORTED and call complete(&t_transport_stop_comp)
     * instead of normal completion. We wait for that.
     */
}
```

The TAS (Task Aborted Status) flag is set when the device or LUN has multiple initiators and a
command from one is aborted by a TMF from another. The other initiators must be informed via
status `0x40` so they don't see "successful" completion of an aborted task.

---

## TMF response

```c
/* Simplified. */
static void iscsit_queue_tm_rsp(struct se_cmd *se_cmd)
{
    struct iscsit_cmd *cmd = container_of(se_cmd, struct iscsit_cmd, se_cmd);

    cmd->i_state = ISTATE_SEND_TASKMGTRSP;
    iscsit_add_cmd_to_response_queue(cmd, cmd->conn, cmd->i_state);
}

/* TX thread eventually calls iscsit_send_task_mgt_rsp() */
static int iscsit_send_task_mgt_rsp(struct iscsit_cmd *cmd,
                                      struct iscsit_conn *conn)
{
    struct iscsi_tm_rsp *hdr = ...;
    struct se_tmr_req *tmr = cmd->se_cmd.se_tmr_req;

    hdr->opcode = ISCSI_OP_SCSI_TMFUNC_RSP;
    hdr->flags  = ISCSI_FLAG_CMD_FINAL;
    hdr->itt    = cmd->init_task_tag;

    /*
     * Map TCM tmr response → iSCSI TMF response code (RFC 7143 §11.6).
     */
    switch (tmr->response) {
    case TMR_FUNCTION_COMPLETE:
        hdr->response = ISCSI_TMF_RSP_COMPLETE;        /* 0x00 */
        break;
    case TMR_TASK_DOES_NOT_EXIST:
        hdr->response = ISCSI_TMF_RSP_NO_TASK;          /* 0x01 */
        break;
    case TMR_LUN_DOES_NOT_EXIST:
        hdr->response = ISCSI_TMF_RSP_NO_LUN;           /* 0x02 */
        break;
    /* ... */
    default:
        hdr->response = ISCSI_TMF_RSP_REJECTED;         /* 0xFF */
    }

    hdr->statsn   = cpu_to_be32(conn->stat_sn++);
    hdr->exp_cmdsn = cpu_to_be32(conn->sess->exp_cmd_sn);
    hdr->max_cmdsn = cpu_to_be32(conn->sess->max_cmd_sn);

    return iscsit_fe_sendpage_sg(...);
}
```

---

## Why target_tmr_wq is ordered

The `__WQ_ORDERED` flag is critical. Three race scenarios it prevents:

**1. Two ABORT TASK racing on the same sess_cmd_list walk:**
Without ordering, both walks could find different commands but mis-account krefs if the same
command is matched twice. Strict serialization avoids this.

**2. ABORT TASK SET interleaving with ABORT TASK:**
If LUN_RESET (which aborts everything) runs concurrently with ABORT TASK (which aborts one),
the per-cmd `wait_for_completion(t_transport_stop_comp)` calls could deadlock or report stale
results. Ordering means LUN_RESET fully completes before any new ABORT TASK begins.

**3. PR PREEMPT_AND_ABORT generating internal LUN_RESET_PRO:**
When PREEMPT_AND_ABORT (day 20) fires, it internally invokes the same machinery as LUN reset
for the preempted nexus. Concurrent fabric-driven TMFs would race here.

The cost — only one TMF per device at a time — is acceptable because TMFs are rare (orders of
magnitude rarer than data commands).

---

## Key takeaways

- TMFs travel via iSCSI opcode 0x02 (Task Management Function Request). The function code is
  in the flags byte.
- `iscsit_handle_task_mgt_cmd()` builds an `se_cmd` with `se_tmr_req` and calls
  `target_submit_tmr()`.
- TMR work runs on `target_tmr_wq` (ordered, one at a time per device) — prevents races on
  `sess_cmd_list` walks.
- `core_tmr_abort_task()` walks the session's command list, takes a kref on the matched
  command, marks `CMD_T_ABORTED`, and waits for `t_transport_stop_comp`.
- `core_tmr_lun_reset()` walks every session attached to the LUN, aborts everything, clears
  SCSI-2 reservation but preserves SPC-3 PR registrations (per SPC-4).
- `CMD_T_TAS` (Task Aborted Status) tells target to send 0x40 status to other initiators with
  the same I_T_L when a command is aborted.
- TMF response codes map between SAM (`TMR_FUNCTION_COMPLETE` etc.) and iSCSI (`ISCSI_TMF_RSP_*`)
  in `iscsit_send_task_mgt_rsp()`. The kernel-internal SAM enums and the iSCSI wire codes are
  different value spaces.

---

## Previous / Next

[Day 21 — LIO backends](day21.md) | [Day 23 — ALUA](day23.md)
