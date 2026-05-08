# Day 17 — target_core_transport completion path

**Week 3**: LIO Target Kernel Code  
**Time**: 1–2 hours  
**Reference**: `drivers/target/target_core_transport.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

When a backend (iblock, fileio) finishes executing a command — or when an error short-circuits
the dispatch — control returns to the target core for response generation. The completion path
is `target_complete_cmd()` → workqueue → `target_complete_ok_work` (or
`target_complete_failure_work`) → fabric callbacks (`queue_data_in`, `queue_status`) → command
release. This is also where sense data gets built and where the abort/release race is resolved.

---

## target_complete_cmd — `drivers/target/target_core_transport.c`

The single entry point used by every backend and every error path.

```c
/* Simplified — see drivers/target/target_core_transport.c. */
void target_complete_cmd(struct se_cmd *cmd, u8 scsi_status)
{
    struct se_device *dev = cmd->se_dev;
    int success = scsi_status == SAM_STAT_GOOD;
    unsigned long flags;

    cmd->scsi_status = scsi_status;

    spin_lock_irqsave(&cmd->t_state_lock, flags);
    cmd->t_state = TRANSPORT_COMPLETE;
    cmd->transport_state |= (CMD_T_COMPLETE | CMD_T_ACTIVE);

    /*
     * If the command was aborted while we were in the backend,
     * t_transport_stop_comp wakes the abort handler instead.
     */
    if (cmd->transport_state & CMD_T_ABORTED) {
        spin_unlock_irqrestore(&cmd->t_state_lock, flags);
        complete_all(&cmd->t_transport_stop_comp);
        return;
    }
    spin_unlock_irqrestore(&cmd->t_state_lock, flags);

    /*
     * Pick the work handler based on success.
     * Both run on target_completion_wq.
     */
    INIT_WORK(&cmd->work, success ? target_complete_ok_work
                                  : target_complete_failure_work);

    /*
     * For UNORDERED commands or fast paths, run inline on the calling
     * CPU rather than queueing to the workqueue. This is a per-device
     * optimization controlled by dev_attrib.
     */
    if (cmd->se_cmd_flags & SCF_TASK_ATTR_SET) {
        queue_work_on(cmd->cpuid, target_completion_wq, &cmd->work);
    } else {
        queue_work(target_completion_wq, &cmd->work);
    }
}
EXPORT_SYMBOL(target_complete_cmd);
```

`CMD_T_ABORTED` set during execution means a TMF (ABORT TASK or LUN RESET) handler is waiting on
`t_transport_stop_comp`. We must signal it instead of going down the normal completion path —
the abort handler is responsible for completing the command (with TASK_ABORTED status or
freeing).

---

## target_complete_ok_work — successful completion

```c
/* Simplified. */
static void target_complete_ok_work(struct work_struct *work)
{
    struct se_cmd *cmd = container_of(work, struct se_cmd, work);
    int ret;

    /*
     * Update LUN counters (read_bytes / write_bytes) for stats.
     */
    transport_complete_task_attr(cmd);

    /*
     * For commands that returned data (READ): hand to fabric to
     * deliver Data-In + Status.
     */
    switch (cmd->data_direction) {
    case DMA_FROM_DEVICE:
        if (cmd->data_length) {
            /*
             * Fabric callback to send Data-In PDU(s).
             * For iSCSI: iscsit_queue_data_in() — builds Data-In PDUs
             * with possibly piggybacked status (S-bit on last PDU).
             */
            ret = cmd->se_tfo->queue_data_in(cmd);
            if (ret) {
                transport_handle_queue_full(cmd, cmd->se_dev, ret, false);
                return;
            }
        }
        /* fall through */

    case DMA_NONE:
queue_status:
        /*
         * Send SCSI Response PDU (status only, no data).
         * For iSCSI: iscsit_queue_status() — builds the Response PDU
         * with status, sense (if any), and sequence numbers.
         */
        ret = cmd->se_tfo->queue_status(cmd);
        if (ret == -EAGAIN || ret == -ENOMEM)
            transport_handle_queue_full(cmd, cmd->se_dev, ret, false);
        break;

    case DMA_TO_DEVICE:
        /*
         * For WRITE: data was already received via write_pending →
         * fabric data-receive → backend I/O. Now just status remains.
         */
        goto queue_status;

    default:
        break;
    }
}
```

`cmd->se_tfo->queue_data_in` and `queue_status` are the fabric's hooks. For iSCSI:

```c
/* drivers/target/iscsi/iscsi_target_configfs.c */
static const struct target_core_fabric_ops iscsi_ops = {
    .queue_data_in    = iscsit_queue_data_in,
    .queue_status     = iscsit_queue_status,
    .queue_tm_rsp     = iscsit_queue_tm_rsp,
    .release_cmd      = iscsit_release_cmd,
    .write_pending    = iscsit_write_pending,
    /* ... */
};
```

`iscsit_queue_data_in()` and `iscsit_queue_status()` add the command to the appropriate iSCSI
output queue and signal the iSCSI TX thread (day 19).

---

## target_complete_failure_work — error completion

```c
static void target_complete_failure_work(struct work_struct *work)
{
    struct se_cmd *cmd = container_of(work, struct se_cmd, work);

    transport_generic_request_failure(cmd, cmd->scsi_sense_reason);
}

void transport_generic_request_failure(struct se_cmd *cmd,
                                         sense_reason_t sense_reason)
{
    /*
     * Build sense data appropriate for sense_reason.
     */
    transport_send_check_condition_and_sense(cmd, sense_reason, 0);

    /*
     * Drop the kref that was held during execution.
     */
    target_put_sess_cmd(cmd);
}
```

In current kernels these two helpers may be merged or further refactored, but the responsibility
split is the same: success path delivers data + status, failure path builds sense and sends
status.

---

## transport_send_check_condition_and_sense

```c
/* Simplified — see target_core_transport.c. */
int transport_send_check_condition_and_sense(struct se_cmd *cmd,
                                                sense_reason_t reason,
                                                int from_transport)
{
    struct se_device *dev = cmd->se_dev;
    int ret;

    if (!from_transport) {
        cmd->se_cmd_flags |= SCF_EMULATED_TASK_SENSE;
        cmd->scsi_status = SAM_STAT_CHECK_CONDITION;
    }

    /*
     * Map TCM_* sense reason → SCSI sense key / ASC / ASCQ.
     * Table-driven via sense_info_table in target_core_transport.c.
     *
     * Examples:
     *   TCM_NON_EXISTENT_LUN          -> ILLEGAL_REQUEST 25/00
     *   TCM_LBA_OUT_OF_RANGE          -> ILLEGAL_REQUEST 21/00
     *   TCM_RESERVATION_CONFLICT      -> (no sense — status 0x18)
     *   TCM_CHECK_CONDITION_NOT_READY -> NOT_READY 04/<ascq>
     *   TCM_LOGICAL_UNIT_COMMUNICATION_FAILURE -> HARDWARE_ERROR 08/00
     */

    if (reason != TCM_RESERVATION_CONFLICT) {
        scsi_build_sense(cmd, dev->dev_attrib.emulate_ua_intlck_ctrl,
                         sense_key, asc, ascq);
    } else {
        /*
         * RESERVATION CONFLICT is a status, not a sense. Set status
         * byte to 0x18 directly. Some targets attach sense; LIO does not.
         */
        cmd->scsi_status = SAM_STAT_RESERVATION_CONFLICT;
    }

    /*
     * Dispatch the response via fabric.
     */
    ret = cmd->se_tfo->queue_status(cmd);
    return ret;
}
```

`scsi_build_sense()` is shared with the initiator side — both build sense in the same fixed
(0x70) or descriptor (0x72) format. Lives in `drivers/scsi/scsi_common.c`. Day 29 covers the
sense format in detail.

---

## target_release_cmd_kref — command teardown

After the response is on the wire, the fabric drops its kref via `target_put_sess_cmd()`. When
the count hits zero:

```c
static void target_release_cmd_kref(struct kref *kref)
{
    struct se_cmd *cmd = container_of(kref, struct se_cmd, cmd_kref);
    struct se_session *se_sess = cmd->se_sess;

    spin_lock(&se_sess->sess_cmd_lock);
    if (!list_empty(&cmd->se_cmd_list))
        list_del_init(&cmd->se_cmd_list);
    spin_unlock(&se_sess->sess_cmd_lock);

    /*
     * Free any backend resources (SGL pages, etc.).
     * Must happen BEFORE release_cmd() because release_cmd() may free
     * the containing struct (iscsit_cmd) which the SGL might reference.
     */
    transport_free_pages(cmd);

    /*
     * Drop the LUN reference taken in transport_lookup_cmd_lun().
     * If this is the last command holding the LUN's percpu_ref, and
     * percpu_ref_kill has been called, the LUN can now be torn down.
     */
    if (cmd->se_lun)
        percpu_ref_put(&cmd->se_lun->lun_ref);

    /*
     * Fabric-specific cleanup. For iSCSI: iscsit_release_cmd() frees
     * the iscsit_cmd and returns its tag to the session pool.
     */
    cmd->se_tfo->release_cmd(cmd);

    /*
     * Drop the per-session command counter. When this percpu_ref is
     * killed (during session shutdown), its release waits for all
     * commands to drop their refs.
     */
    percpu_ref_put(&se_sess->cmd_count);

    /*
     * Wake the abort waiter, if any.
     */
    if (cmd->free_compl_on_release)
        complete(&cmd->free_compl);
}
```

The ordering — `transport_free_pages` BEFORE `release_cmd` — is critical. `release_cmd` may free
the `iscsit_cmd` that owns the SGL pages, so we need to release the pages first.

---

## Abort race — why CMD_T_FABRIC_STOP exists

Consider this race scenario:

```
Thread A (RX): receives ABORT TASK TMF for ITT=0x42
Thread B (TX): just finished sending Status PDU for ITT=0x42

Time   Thread A                            Thread B
─────  ──────────────────────              ──────────────────────
T0     iscsit_handle_task_mgt()
T1     core_tmr_abort_task() walks
       sess_cmd_list, finds cmd
T2                                         iscsit_send_response() done
T3                                         target_release_cmd_kref()
T4                                         transport_free_pages()
T5     spin_lock(t_state_lock)
T6                                         release_cmd() → kfree(iscsit_cmd)
T7     test cmd->transport_state           ← USE-AFTER-FREE
```

The fix: TMR processing takes a kref on every command it intends to abort, before walking the
list. The kref guarantees the cmd cannot be freed while TMR is examining it:

```c
/* Simplified — see drivers/target/target_core_tmr.c. */
static void core_tmr_drain_state_list(...)
{
    struct se_cmd *cmd, *next;

    spin_lock_irqsave(&dev->execute_task_lock, flags);
    list_for_each_entry_safe(cmd, next, &drain_task_list, state_list) {
        /*
         * Take a kref on this cmd. If kref is already 0, this returns
         * false and we skip the cmd — it's already being released.
         */
        if (!target_get_sess_cmd_kref(cmd))
            continue;

        list_del_init(&cmd->state_list);

        /* mark for abort */
        spin_lock(&cmd->t_state_lock);
        cmd->transport_state |= (CMD_T_ABORTED | CMD_T_FABRIC_STOP);
        spin_unlock(&cmd->t_state_lock);

        /* ... wait for completion ... */

        target_put_sess_cmd(cmd);   /* drop our kref */
    }
    spin_unlock_irqrestore(&dev->execute_task_lock, flags);
}
```

`CMD_T_FABRIC_STOP` (added around 2017) distinguishes "fabric is going away — wait for in-flight
I/O to complete cleanly" from `CMD_T_ABORTED` ("abort this specific command"). During session
shutdown, every command gets `CMD_T_FABRIC_STOP` set, the fabric stops accepting new work, and
existing work drains naturally. The exact rationale beyond ordering preservation is upstream
inference — the commit log emphasizes coordinated teardown rather than spelling out a specific
memory hazard.

---

## target_tmr_wq — why ordered

```c
target_tmr_wq = alloc_workqueue("tmr-%s",
                                  WQ_MEM_RECLAIM | WQ_UNBOUND |
                                  __WQ_ORDERED, 1, dev_alias);
```

`__WQ_ORDERED` means: only one work item runs at a time. TMF processing must be serialized
because:

1. Two ABORT TASK TMFs can race on the same `sess_cmd_list` walk. Concurrent walks would each
   try to take krefs and could double-account.
2. ABORT TASK SET (kills all tasks for an I_T_L) and ABORT TASK (kills one) must not
   interleave — order matters for which commands get TASK_ABORTED status (`CMD_T_TAS`).
3. LOGICAL UNIT RESET vs in-flight ABORT TASK: the LUN reset must process all current aborts
   first, then quiesce.

Strict FIFO ordering avoids these hazards. The cost — only one TMF processed at a time per
device — is acceptable because TMFs are rare (orders of magnitude rarer than data commands).

---

## Full completion flow for a successful WRITE

```
backend (iblock_bio_done) calls target_complete_cmd(cmd, SAM_STAT_GOOD)
    │
    ▼
target_complete_cmd()
    │  cmd->scsi_status = GOOD
    │  cmd->t_state = TRANSPORT_COMPLETE
    │  CMD_T_ABORTED check: not aborted
    │  INIT_WORK(work, target_complete_ok_work)
    │  queue_work(target_completion_wq, work)
    │
    ▼  (work item runs — possibly on different CPU)
target_complete_ok_work()
    │  cmd->data_direction = DMA_TO_DEVICE
    │  → goto queue_status
    │  cmd->se_tfo->queue_status(cmd)
    ▼
iscsit_queue_status(cmd)                  [drivers/target/iscsi/iscsi_target.c]
    │  set ICF flag for status pending
    │  iscsit_add_cmd_to_response_queue()
    │  signal iSCSI TX thread
    ▼
iSCSI TX thread (day 19)
    │  build SCSI Response PDU BHS
    │    opcode = 0x21
    │    response = 0x00 (CMD_COMPLETED)
    │    cmd_status = 0x00 (GOOD)
    │  send via TCP
    ▼
target_release_cmd_kref()
    │  remove from sess_cmd_list
    │  transport_free_pages()
    │  percpu_ref_put(lun_ref)
    │  cmd->se_tfo->release_cmd()
    │      iscsit_release_cmd() — return tag to session pool
    │  percpu_ref_put(cmd_count)
```

For a RESERVATION CONFLICT path, the diagram is similar but `target_complete_failure_work` is
queued instead of `target_complete_ok_work`, and `transport_send_check_condition_and_sense()`
sets `cmd->scsi_status = SAM_STAT_RESERVATION_CONFLICT` before the response is sent.

---

## Key takeaways

- `target_complete_cmd()` is the single entry from backends. It chooses success vs failure work
  and queues to `target_completion_wq`.
- `target_complete_ok_work()` calls fabric `queue_data_in` (for reads) then `queue_status`.
- `target_complete_failure_work()` calls `transport_generic_request_failure` →
  `transport_send_check_condition_and_sense` → fabric `queue_status`.
- Abort race: TMR takes a kref on every command before examining it. `CMD_T_FABRIC_STOP`
  distinguishes session shutdown from per-command abort, allowing in-flight I/O to drain
  cleanly during teardown.
- `target_tmr_wq` is `__WQ_ORDERED` so TMFs run strictly serially — avoids races on
  `sess_cmd_list` walks and preserves the SAM-required ordering between ABORT TASK / TASK SET
  / LUN RESET.
- `target_release_cmd_kref()` ordering: `transport_free_pages()` → `percpu_ref_put(lun_ref)` →
  `release_cmd()` → `percpu_ref_put(cmd_count)`. SGL freed before release_cmd so dangling
  pointers don't form.
- `scsi_build_sense()` is shared between initiator and target — both produce the same wire-format
  sense data.

---

## Previous / Next

[Day 16 — target_core_transport submit path](day16.md) | [Day 18 — iSCSI fabric RX thread](day18.md)
