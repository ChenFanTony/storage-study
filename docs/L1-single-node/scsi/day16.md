# Day 16 — target_core_transport submit path

**Week 3**: LIO Target Kernel Code  
**Time**: 1–2 hours  
**Reference**: `drivers/target/target_core_transport.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

When a fabric (iSCSI, FC, etc.) receives a SCSI command, it builds an `se_cmd` and calls into the
target core to dispatch it. The submit path is `target_submit_cmd()` →
`transport_lookup_cmd_lun()` → reservation/ALUA/state checks → `target_setup_cmd_from_cdb()` →
backend `execute_cmd()`. This is where RESERVATION CONFLICT is generated, where ALUA delays are
imposed, and where the backend's actual I/O begins.

---

## Workqueue topology

LIO uses three workqueues for command dispatch:

```c
/* drivers/target/target_core_transport.c */
struct workqueue_struct *target_completion_wq;   /* response generation */
struct workqueue_struct *target_submission_wq;   /* backend execution */
struct workqueue_struct *target_tmr_wq;          /* TMF processing — ordered */
```

Initialization (in `target_core_init_configfs()`):
```c
target_completion_wq = alloc_workqueue("target_completion",
                                        WQ_UNBOUND | WQ_MEM_RECLAIM, 0);
target_submission_wq = alloc_workqueue("target_submission",
                                        WQ_UNBOUND | WQ_MEM_RECLAIM, 0);
target_tmr_wq = alloc_workqueue("tmr-%s",
                                  WQ_MEM_RECLAIM | WQ_UNBOUND |
                                  __WQ_ORDERED, 1, dev_alias);
```

Key flags:
- `WQ_UNBOUND` — work can run on any CPU (don't pin to submitting CPU).
- `WQ_MEM_RECLAIM` — reserves a rescuer thread so I/O can make progress under memory pressure.
- `__WQ_ORDERED` (TMR queue only) — strict FIFO, one work item runs at a time. Prevents TMF
  reordering / concurrency hazards on the per-session command list.

---

## target_submit_cmd / target_submit_cmd_map_sgls — `drivers/target/target_core_transport.c`

The fabric's main entry point. Several variants exist; the common one is
`target_submit_cmd_map_sgls()` (which the simpler `target_submit_cmd()` wraps):

```c
/* Simplified — see target_core_transport.c for the actual signatures. */
int target_submit_cmd_map_sgls(struct se_cmd *se_cmd,
                                struct se_session *se_sess,
                                unsigned char *cdb,
                                unsigned char *sense,
                                u64 unpacked_lun,
                                u32 data_length,
                                int task_attr,
                                int data_dir,
                                int flags,
                                struct scatterlist *sgl,
                                u32 sgl_count, ...)
{
    int ret;

    /*
     * Initialize se_cmd: copy CDB, set direction, attach SGL.
     */
    transport_init_se_cmd(se_cmd, se_sess->se_tpg->se_tpg_tfo,
                          se_sess, data_length, data_dir,
                          task_attr, sense, unpacked_lun);

    if (sgl)
        ret = transport_generic_map_mem_to_cmd(se_cmd, sgl, sgl_count, ...);

    /*
     * Look up LUN — checks ACL and gets a percpu_ref on lun_ref.
     * If LUN was just removed (percpu_ref_kill), this fails.
     */
    ret = transport_lookup_cmd_lun(se_cmd);
    if (ret) {
        target_complete_cmd(se_cmd, SAM_STAT_CHECK_CONDITION);
        return 0;
    }

    /*
     * Decode the CDB — set up backend ops, length checks, etc.
     */
    ret = target_setup_cmd_from_cdb(se_cmd, cdb);
    if (ret) {
        transport_send_check_condition_and_sense(se_cmd, ret, 0);
        target_put_sess_cmd(se_cmd);
        return 0;
    }

    /*
     * Reservation, ALUA, ACA checks happen via the cdb_emulate or
     * generic_cmd_sequencer paths invoked here.
     */

    /* Dispatch — for non-data commands, execute immediately;
     * for writes with data not yet received, return and wait for fabric
     * to call write_pending → backend execute. */
    target_execute_cmd(se_cmd);
    return 0;
}
```

For iSCSI, `iscsit_setup_scsi_cmd()` builds the `se_cmd` and `iscsit_process_scsi_cmd()` calls
`target_submit_cmd()` (day 18).

---

## transport_lookup_cmd_lun — LUN binding — `drivers/target/target_core_device.c`

```c
/* Simplified — see drivers/target/target_core_device.c. */
sense_reason_t transport_lookup_cmd_lun(struct se_cmd *se_cmd)
{
    struct se_dev_entry *deve;
    struct se_session *se_sess = se_cmd->se_sess;
    struct se_node_acl *nacl = se_sess->se_node_acl;
    struct se_portal_group *se_tpg = se_sess->se_tpg;
    sense_reason_t ret = TCM_NO_SENSE;

    rcu_read_lock();

    /*
     * Walk the ACL's lun_entry_hlist looking for the requested LUN.
     */
    deve = target_nacl_find_deve(nacl, se_cmd->orig_fe_lun);
    if (!deve) {
        rcu_read_unlock();
        /*
         * LUN not in ACL → ILLEGAL REQUEST / LOGICAL UNIT NOT SUPPORTED
         */
        return TCM_NON_EXISTENT_LUN;
    }

    /*
     * percpu_ref_tryget_live: if LUN is being torn down (percpu_ref_kill
     * was called), this returns false. Bail with NOT READY.
     */
    if (!percpu_ref_tryget_live(&deve->se_lun->lun_ref)) {
        rcu_read_unlock();
        return TCM_NON_EXISTENT_LUN;
    }

    /* Read-only LUN check */
    if (deve->lun_access_ro &&
        ((se_cmd->data_direction == DMA_TO_DEVICE) ||
         (target_cmd_is_writable(se_cmd))) ) {
        percpu_ref_put(&deve->se_lun->lun_ref);
        rcu_read_unlock();
        return TCM_WRITE_PROTECTED;
    }

    se_cmd->se_lun  = deve->se_lun;
    se_cmd->se_dev  = deve->se_lun->lun_se_dev;

    rcu_read_unlock();

    return TCM_NO_SENSE;
}
```

The `percpu_ref_tryget_live()` check is the per-command hot-unplug safety mechanism. The matching
`percpu_ref_put()` happens during command release (in `transport_put_lun()`). When configfs
removes the LUN via `core_tpg_remove_lun()`, the `percpu_ref_kill()` causes all subsequent
`tryget_live` calls to fail, and the kill waits for outstanding refs (i.e. in-flight commands)
to drop to zero before completing — guaranteeing a quiescent LUN before tearing down further.

---

## target_setup_cmd_from_cdb — CDB decoding

```c
/* Simplified. */
sense_reason_t target_setup_cmd_from_cdb(struct se_cmd *se_cmd,
                                            unsigned char *cdb)
{
    struct se_device *dev = se_cmd->se_dev;
    sense_reason_t ret;

    if (!cdb)
        return TCM_INVALID_CDB_FIELD;

    /*
     * Copy CDB into the embedded buffer (or alloc a larger one for >32B).
     */
    if (scsi_command_size(cdb) > TCM_MAX_COMMAND_SIZE) {
        se_cmd->t_task_cdb = kzalloc(scsi_command_size(cdb), GFP_ATOMIC);
        if (!se_cmd->t_task_cdb)
            return TCM_OUT_OF_RESOURCES;
    } else {
        se_cmd->t_task_cdb = &se_cmd->__t_task_cdb[0];
    }
    memcpy(se_cmd->t_task_cdb, cdb, scsi_command_size(cdb));
    se_cmd->t_task_cdb_size = scsi_command_size(cdb);

    /*
     * Set up backend execute callback based on opcode.
     * For READ/WRITE: dev->transport->execute_cmd points to
     *   iblock_execute_rw, fd_execute_rw, etc. (day 21)
     * For PR: PR-emulation handler in target_core_pr.c (day 20)
     * For TUR / INQUIRY: emulation handlers in target_core_spc.c
     */
    ret = dev->transport->parse_cdb(se_cmd);
    if (ret == TCM_UNSUPPORTED_SCSI_OPCODE) {
        return ret;
    } else if (ret) {
        return ret;
    }

    /*
     * SAM task attribute setup.
     */
    target_get_sess_cmd_kref(se_cmd);

    return TCM_NO_SENSE;
}
```

The CDB is decoded by the backend's `parse_cdb()` (e.g. `iblock_parse_cdb`, `fd_parse_cdb`).
Common helpers in `target_core_sbc.c` (block commands) and `target_core_spc.c` (SPC commands)
do the actual decoding for READ/WRITE/INQUIRY/etc. PR commands are handled by `target_core_pr.c`
(day 20).

---

## Reservation check — where RESERVATION CONFLICT is generated

```c
/* Simplified — actual function is target_check_reservation in target_core_pr.c.
 * The old name core_scsi3_pr_reservation_check still appears in the same
 * source file as the underlying check. */
static sense_reason_t target_check_reservation(struct se_cmd *cmd)
{
    struct se_device *dev = cmd->se_dev;
    sense_reason_t ret = TCM_NO_SENSE;

    if (!dev->dev_pr_res_holder)
        return 0;  /* no reservation held — anyone can do anything */

    /*
     * Always-allowed CDBs (SPC-4 §6.13.4) — bypass reservation check:
     *   INQUIRY, REPORT LUNS, REQUEST SENSE, PERSISTENT RESERVE IN/OUT,
     *   RELEASE, READ KEYS, READ RESERVATION (and a few others).
     * This list is essential to fencing semantics: even a non-holder
     * must be able to discover topology and read/clear PR state.
     */
    if (target_cdb_is_pr_passthrough(cmd))
        return 0;

    spin_lock(&dev->dev_reservation_lock);

    if (dev->dev_pr_res_holder) {
        struct t10_pr_registration *pr_reg_holder = dev->dev_pr_res_holder;

        /*
         * Check if THIS initiator's I_T nexus is the holder.
         * Compares cmd->se_sess to pr_reg_holder->pr_reg_nacl session.
         */
        if (target_check_reservation_holder(cmd, pr_reg_holder)) {
            spin_unlock(&dev->dev_reservation_lock);
            return 0;  /* we are the holder — allow */
        }

        /*
         * For *_REG_ONLY and *_ALL_REGS types: registered initiators
         * are also allowed (read or read+write depending on type).
         */
        if (target_check_reservation_registered(cmd, pr_reg_holder)) {
            spin_unlock(&dev->dev_reservation_lock);
            return 0;
        }

        /*
         * For READ-only types: WRITE-class commands fail; reads pass.
         */
        if (target_pr_type_allows_read(pr_reg_holder->pr_res_type, cmd)) {
            spin_unlock(&dev->dev_reservation_lock);
            return 0;
        }

        spin_unlock(&dev->dev_reservation_lock);

        /*
         * Conflict — return TCM_RESERVATION_CONFLICT.
         * This becomes SAM_STAT_RESERVATION_CONFLICT (0x18) in the
         * SCSI Response PDU.
         */
        return TCM_RESERVATION_CONFLICT;
    }

    spin_unlock(&dev->dev_reservation_lock);
    return 0;
}
```

This is the gate. When a fenced initiator's READ or WRITE arrives, this returns
`TCM_RESERVATION_CONFLICT`, and `transport_send_check_condition_and_sense()` builds the SCSI
Response PDU with status 0x18. No backend I/O is performed. The response goes out via
`target_completion_wq`.

---

## ALUA check

```c
/* Simplified — see drivers/target/target_core_alua.c. */
static sense_reason_t core_alua_state_check(struct se_cmd *cmd,
                                              char *cdb, u8 *alua_ascq)
{
    struct se_lun *lun = cmd->se_lun;
    struct t10_alua_tg_pt_gp *tg_pt_gp;
    int alua_access_state;

    /*
     * Some commands are always allowed regardless of ALUA state:
     *   INQUIRY, REPORT LUNS, REPORT TARGET PORT GROUPS, etc.
     */
    if (target_cdb_is_alua_passthrough(cdb))
        return 0;

    spin_lock(&lun->lun_tg_pt_gp_lock);
    tg_pt_gp = lun->lun_tg_pt_gp;
    if (!tg_pt_gp) {
        spin_unlock(&lun->lun_tg_pt_gp_lock);
        return 0;  /* no ALUA configured */
    }

    alua_access_state = tg_pt_gp->tg_pt_gp_alua_access_state;

    spin_unlock(&lun->lun_tg_pt_gp_lock);

    switch (alua_access_state) {
    case ALUA_ACCESS_STATE_ACTIVE_OPTIMIZED:
        return 0;  /* fast path — no delay */

    case ALUA_ACCESS_STATE_ACTIVE_NON_OPTIMIZED:
        /*
         * Optionally apply nonop_delay_msec — slows commands on
         * non-optimized paths to encourage use of optimized ones.
         */
        if (tg_pt_gp->tg_pt_gp_alua_nonop_delay_msecs)
            msleep_interruptible(tg_pt_gp->tg_pt_gp_alua_nonop_delay_msecs);
        return 0;

    case ALUA_ACCESS_STATE_STANDBY:
        *alua_ascq = ASCQ_04H_ALUA_TGT_PORT_STANDBY;
        return TCM_CHECK_CONDITION_NOT_READY;  /* sense 02/04/0B */

    case ALUA_ACCESS_STATE_UNAVAILABLE:
        *alua_ascq = ASCQ_04H_ALUA_TGT_PORT_UNAVAILABLE;
        return TCM_CHECK_CONDITION_NOT_READY;

    case ALUA_ACCESS_STATE_TRANSITION:    /* 0xF */
        *alua_ascq = ASCQ_04H_ALUA_STATE_TRANSITION;
        return TCM_CHECK_CONDITION_NOT_READY;

    case ALUA_ACCESS_STATE_OFFLINE:       /* 0xE */
        *alua_ascq = ASCQ_04H_ALUA_OFFLINE;
        return TCM_CHECK_CONDITION_NOT_READY;
    }

    return 0;
}
```

ALUA states return NOT READY — initiator's `scsi_decide_disposition()` will retry. dm-multipath's
path checker eventually moves the failing path to a different priority group. Day 23 covers
ALUA in detail.

---

## target_execute_cmd — entry to backend

```c
/* Simplified — see target_core_transport.c. */
void target_execute_cmd(struct se_cmd *cmd)
{
    /*
     * If the command was aborted before reaching here, complete it
     * directly without backend execution.
     */
    if (test_bit(CMD_T_ABORTED, &cmd->transport_state)) {
        transport_complete_task_attr(cmd);
        target_complete_cmd(cmd, SAM_STAT_TASK_ABORTED);
        return;
    }

    /*
     * Some emulated commands (TUR, READ CAPACITY, INQUIRY) execute
     * synchronously here. No workqueue.
     */
    if (cmd->execute_cmd) {
        sense_reason_t ret = cmd->execute_cmd(cmd);
        if (ret) {
            transport_generic_request_failure(cmd, ret);
        }
        return;
    }

    /*
     * For backend I/O (READ, WRITE), queue to submission_wq.
     * The backend (iblock, fileio) will pick it up and submit bios.
     */
    INIT_WORK(&cmd->work, target_execute_cmd_work);
    queue_work(target_submission_wq, &cmd->work);
}

static void target_execute_cmd_work(struct work_struct *work)
{
    struct se_cmd *cmd = container_of(work, struct se_cmd, work);
    sense_reason_t ret;

    ret = cmd->se_dev->transport->execute_cmd(cmd);
    if (ret)
        transport_generic_request_failure(cmd, ret);
}
```

For RESERVATION CONFLICT, `target_check_reservation()` returns
`TCM_RESERVATION_CONFLICT` early in `target_setup_cmd_from_cdb()` — `cmd->execute_cmd` is never
called, no backend I/O is performed, and `transport_send_check_condition_and_sense()` builds the
response. The response is queued through `target_completion_wq` like any other completion (it
doesn't bypass the workqueue), but no backend I/O work is done.

---

## Full submit path for a write under PR conflict

```
iscsit RX thread receives Command PDU
    │
    ▼
iscsit_handle_scsi_cmd()                  [drivers/target/iscsi/iscsi_target.c]
    │  iscsit_setup_scsi_cmd()
    │  iscsit_process_scsi_cmd()
    ▼
target_submit_cmd_map_sgls(...)
    │  transport_init_se_cmd()
    │  transport_lookup_cmd_lun()         (ACL OK, percpu_ref_tryget_live OK)
    │  target_setup_cmd_from_cdb()        (CDB = WRITE 16)
    │       → backend->parse_cdb()
    │           → reservation check       (TCM_RESERVATION_CONFLICT!)
    │
    ▼  early return with conflict
transport_send_check_condition_and_sense()
    │  cmd->scsi_status = SAM_STAT_RESERVATION_CONFLICT
    │  target_complete_cmd()
    ▼
queue_work(target_completion_wq, ...)
    ▼
target_complete_ok_work()
    │  cmd->se_tfo->queue_status(cmd)
    ▼
iscsit_queue_status()
    │  build SCSI Response PDU
    │  status_byte = 0x18
    │  send via TX worker
    ▼
TCP wire → initiator
    ▼
Initiator's iscsi_scsi_cmd_rsp() sets sc->result, completes the bio
```

Total time for this path on a healthy network: typically < 1ms. No backend I/O. No bios. No
backend SGL setup. The PR check short-circuits before the backend is even consulted.

---

## Key takeaways

- LIO uses three workqueues: completion, submission, and an ordered TMR queue.
- `target_submit_cmd_map_sgls()` is the fabric's main entry point. It initializes `se_cmd`,
  binds to LUN (with `percpu_ref_tryget_live` gate), decodes CDB, runs reservation/ALUA checks,
  and dispatches to the backend (or generates a response directly for short commands or
  conflicts).
- `transport_lookup_cmd_lun()` is the LUN-removal gate via `percpu_ref_tryget_live()`. When
  `percpu_ref_kill()` runs, in-flight commands must drop their refs before the kill completes —
  guaranteeing a quiescent LUN.
- `target_check_reservation()` is where SAM_STAT_RESERVATION_CONFLICT is generated. SPC-4
  always-allowed commands (INQUIRY, REPORT LUNS, REQUEST SENSE, PERSISTENT RESERVE IN/OUT, etc.)
  bypass this check.
- ALUA state check (`core_alua_state_check`) returns NOT READY (sense 02/04/0B etc.) for
  STANDBY/UNAVAILABLE/TRANSITION/OFFLINE — initiator retries via `scsi_decide_disposition`.
- Successful commands flow to `target_execute_cmd()` which dispatches to the backend's
  `execute_cmd` either synchronously (emulated short commands) or via `target_submission_wq`
  (backend I/O).
- Conflicts/errors generate a response synchronously in the submit path (no backend I/O), but
  the response itself is sent via `target_completion_wq` like any other completion.

---

## Previous / Next

[Day 15 — target core structs](day15.md) | [Day 17 — target_core_transport completion path](day17.md)
