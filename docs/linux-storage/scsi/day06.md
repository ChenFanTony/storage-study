# Day 6 — SCSI error handler

**Week 1**: Block Layer — blk-mq and SCSI Mid Layer  
**Time**: 1–2 hours  
**Reference**: `drivers/scsi/scsi_error.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

When `scsi_decide_disposition()` returns `FAILED` (day 5), the command enters the SCSI Error
Handler (EH). EH runs in a dedicated kthread per Scsi_Host — `scsi_error_handler`. It attempts
recovery through an escalating sequence: abort → LUN reset → target reset → bus reset. If all fail,
commands complete with `DID_NO_CONNECT`. Understanding EH is critical because it is the bridge
between a TCP session drop and a path failure visible to dm-multipath.

---

## The EH kthread — `drivers/scsi/scsi_error.c`

```c
/* Simplified — see drivers/scsi/scsi_error.c for the actual implementation. */
int scsi_error_handler(void *data)
{
    struct Scsi_Host *shost = data;

    set_user_nice(current, -2);    /* slightly elevated priority */

    for (;;) {
        /*
         * Sleep until woken by scsi_eh_wakeup().
         * Wakeup sources:
         *   1. scsi_times_out()     — command timer expired
         *   2. iscsi_conn_failure() — session/connection dropped (via scsi_target_block)
         *   3. scsi_abort_command() — explicit EH request
         */
        wait_event_freezable(shost->host_wait,
            scsi_eh_should_run(shost) || kthread_should_stop());

        if (kthread_should_stop())
            break;

        /*
         * Drain failed commands and try recovery.
         * The actual entry function in upstream is scsi_unjam_host()
         * which orchestrates the abort/reset escalation ladder below.
         */
        scsi_unjam_host(shost);
    }

    return 0;
}
```

`shost->host_failed` counts commands added to EH via `scsi_eh_scmd_add()`.
`shost->host_busy` counts commands currently dispatched. EH wakes when failed commands exist and
the host is not processing new ones (the exact condition is checked by helpers like
`scsi_eh_should_run()` / `scsi_host_eh_past_deadline()` in current source).

---

## scsi_eh_wakeup — `drivers/scsi/scsi_error.c`

```c
void scsi_eh_wakeup(struct Scsi_Host *shost, unsigned int busy)
{
    lockdep_assert_held(shost->host_lock);

    if (busy == shost->host_failed) {
        wake_up(&shost->host_wait); /* wake the EH kthread */
        SCSI_LOG_ERROR_RECOVERY(5,
            shost_printk(KERN_INFO, shost, "Waking error handler thread\n"));
    }
}
```

For iSCSI, `iscsi_conn_failure()` calls `iscsi_suspend_tx()` which calls `scsi_target_block()`
which transitions devices toward `SDEV_TRANSPORT_OFFLINE` and indirectly wakes EH for any
in-flight commands that need to be unblocked or aborted.

---

## scsi_unjam_host — the recovery sequence

```c
/* Simplified — see scsi_error.c. */
void scsi_unjam_host(struct Scsi_Host *shost)
{
    LIST_HEAD(eh_work_q);
    LIST_HEAD(eh_done_q);

    scsi_eh_get_sense(&eh_work_q, &eh_done_q);

    if (!scsi_eh_abort_cmds(&eh_work_q, &eh_done_q))
        goto cleanup;       /* all recovered by abort */

    scsi_eh_ready_devs(shost, &eh_work_q, &eh_done_q);

cleanup:
    scsi_eh_flush_done_q(&eh_done_q);
}
```

`scsi_eh_ready_devs()` is where the escalation ladder lives:

```c
static void scsi_eh_ready_devs(struct Scsi_Host *shost,
                                struct list_head *work_q,
                                struct list_head *done_q)
{
    /* Level 2: LUN reset */
    if (!scsi_eh_bus_device_reset(shost, work_q, done_q))
        return;

    /* Level 3: target reset */
    if (!scsi_eh_target_reset(shost, work_q, done_q))
        return;

    /* Level 4: bus reset */
    if (!scsi_eh_bus_reset(shost, work_q, done_q))
        return;

    /* Level 5: host reset */
    if (!scsi_eh_host_reset(shost, work_q, done_q))
        return;

    /* Level 6: offline the devices — nothing else works */
    scsi_eh_offline_sdevs(work_q, done_q);
}
```

---

## Level 1: abort — scsi_try_to_abort_cmd

```c
static enum scsi_disposition scsi_try_to_abort_cmd(
    struct scsi_host_template *hostt,
    struct scsi_cmnd *scmd)
{
    if (!hostt->eh_abort_handler)
        return FAILED;

    return hostt->eh_abort_handler(scmd);
}
```

For iSCSI, `eh_abort_handler = iscsi_eh_abort()` in `drivers/scsi/libiscsi.c`:

```c
/* Simplified — illustrative of the structure. The actual function uses
 * scsi_cmd_priv(sc) (or per-LLD helpers) to recover the iscsi_task,
 * not the legacy sc->SCp pointer that was removed in v6.2. */
int iscsi_eh_abort(struct scsi_cmnd *sc)
{
    struct iscsi_cls_session *cls_session =
        starget_to_session(scsi_target(sc->device));
    struct iscsi_session *session = cls_session->dd_data;
    struct iscsi_conn *conn;
    struct iscsi_task *task;
    int rc;

    mutex_lock(&session->eh_mutex);
    spin_lock_bh(&session->frwd_lock);

    /*
     * If session is not logged in, we can't send an ABORT TASK TMF.
     * The task is already considered gone from the target's perspective.
     */
    if (session->state != ISCSI_STATE_LOGGED_IN) {
        spin_unlock_bh(&session->frwd_lock);
        mutex_unlock(&session->eh_mutex);
        return FAILED;
    }

    conn = session->leadconn;

    /*
     * Find the iscsi_task for this scsi_cmnd.
     * Modern libiscsi stores the task pointer in the per-command
     * private area (scsi_cmd_priv()), set up via Scsi_Host_Template.cmd_size.
     */
    task = iscsi_cmd(sc)->task;
    if (!task || !task->sc) {
        /* task already completed normally — race with completion */
        spin_unlock_bh(&session->frwd_lock);
        mutex_unlock(&session->eh_mutex);
        return SUCCESS;
    }

    /*
     * Send ABORT TASK TMF PDU to target.
     * Reference ITT of the task to abort.
     */
    rc = iscsi_exec_task_mgmt_fn(conn, ISCSI_TM_FUNC_ABORT_TASK,
                                  session->age, task->itt);

    spin_unlock_bh(&session->frwd_lock);
    mutex_unlock(&session->eh_mutex);
    return rc;
}
```

---

## Level 2: LUN reset — iscsi_eh_device_reset

```c
/* Scsi_Host_Template.eh_device_reset_handler = iscsi_eh_device_reset */
int iscsi_eh_device_reset(struct scsi_cmnd *sc)
{
    return iscsi_eh_reset_helper(sc, ISCSI_TM_FUNC_LOGICAL_UNIT_RESET);
}

static int iscsi_eh_reset_helper(struct scsi_cmnd *sc, uint8_t func)
{
    struct iscsi_cls_session *cls_session =
        starget_to_session(scsi_target(sc->device));
    struct iscsi_session *session = cls_session->dd_data;
    struct iscsi_conn *conn;
    int rc;

    mutex_lock(&session->eh_mutex);

    if (session->state != ISCSI_STATE_LOGGED_IN) {
        mutex_unlock(&session->eh_mutex);
        return FAILED;
    }

    conn = session->leadconn;

    /*
     * Send LOGICAL UNIT RESET TMF.
     * Target aborts all tasks for this LUN, returns TMF response.
     * On LIO target side: core_tmr_lun_reset() handles this.
     */
    rc = iscsi_exec_task_mgmt_fn(conn, func, session->age, 0);

    mutex_unlock(&session->eh_mutex);
    return rc;
}
```

---

## Level 3: target reset — iscsi_eh_recover_target

```c
int iscsi_eh_recover_target(struct scsi_cmnd *sc)
{
    struct iscsi_cls_session *cls_session =
        starget_to_session(scsi_target(sc->device));
    struct iscsi_session *session = cls_session->dd_data;
    struct iscsi_conn *conn;
    int rc;

    mutex_lock(&session->eh_mutex);

    /*
     * Try WARM TARGET RESET TMF first.
     * If session is not logged in, drop and reconnect the session.
     * This effectively performs a target reset from the iSCSI perspective.
     */
    if (session->state == ISCSI_STATE_LOGGED_IN) {
        conn = session->leadconn;
        rc = iscsi_exec_task_mgmt_fn(conn,
                                      ISCSI_TM_FUNC_TARGET_WARM_RESET,
                                      session->age, 0);
    } else {
        rc = FAILED;
    }

    if (rc == FAILED) {
        /*
         * Session is broken — drop and reconnect.
         * This triggers iscsi_conn_failure() → session reconnect.
         * replacement_timeout starts counting from the userspace-pushed value.
         */
        iscsi_conn_failure(session->leadconn, ISCSI_ERR_CONN_FAILED);
        rc = SUCCESS; /* signal EH that we handled it */
    }

    mutex_unlock(&session->eh_mutex);
    return rc;
}
```

---

## eh_deadline — bounding EH time

```c
/*
 * shost->eh_deadline: maximum seconds to attempt EH before giving up.
 * Default: -1 (unlimited — EH may run as long as the iSCSI session
 * recovery code lets it).
 *
 * Set via sysfs: echo 30 > /sys/class/scsi_host/hostN/eh_deadline
 */

static bool scsi_host_eh_past_deadline(struct Scsi_Host *shost)
{
    if (!shost->last_reset || shost->eh_deadline == -1)
        return false;

    return time_after(jiffies,
                      shost->last_reset + shost->eh_deadline * HZ);
}
```

With `eh_deadline = -1` (default), the practical bound on EH time for iSCSI is
`replacement_timeout` (typically 120s, pushed from open-iscsi userspace via sysfs at session
creation — it is not a kernel-side default constant). The interaction:

1. Session drops at T=0.
2. `iscsi_conn_failure()` blocks the SCSI target devices, wakes EH for in-flight commands.
3. EH tries abort → LUN reset → target reset — all fail because the session is gone.
4. Commands sit in the "blocked" state while iscsid attempts to reconnect.
5. At T = `replacement_timeout`, `iscsi_session_recovery_timedout()` fires →
   `ISCSI_STATE_RECOVERY_FAILED` → all held commands get `DID_TRANSPORT_FAILFAST`.
6. dm-multipath sees `BLK_STS_TRANSPORT` → `fail_path()` → path marked failed.

---

## scsi_noretry_cmd — bypassing EH for specific status codes

```c
static bool scsi_noretry_cmd(struct scsi_cmnd *scmd)
{
    struct request *req = scsi_cmd_to_rq(scmd);

    /* commands from callers that set FAILFAST flags skip retry */
    if (req->cmd_flags & REQ_FAILFAST_MASK)
        return true;

    /* RESERVATION CONFLICT — explicitly listed as non-retryable */
    if (status_byte(scmd->result) == SAM_STAT_RESERVATION_CONFLICT)
        return true;

    return false;
}
```

Note that this is checked for normal I/O paths too. If a READ or WRITE lands on a PR-protected
LUN, it gets `RESERVATION CONFLICT`, `scsi_noretry_cmd()` returns true, and the command completes
with the error immediately — no EH, no LUN reset triggered. (And in modern kernels the result
flows up as `BLK_STS_RESV_CONFLICT`, which `blk_path_error()` does not treat as a path failure.)

---

## scsi_eh_flush_done_q — final disposition of unrecoverable commands

```c
static void scsi_eh_flush_done_q(struct list_head *done_q)
{
    struct scsi_cmnd *scmd, *next;

    list_for_each_entry_safe(scmd, next, done_q, eh_entry) {
        list_del_init(&scmd->eh_entry);

        if (scsi_device_online(scmd->device) &&
            !scsi_noretry_cmd(scmd) &&
            scmd->retries < scmd->allowed) {
            scmd->retries++;
            scsi_queue_insert(scmd, SCSI_MLQUEUE_EH_RETRY);
        } else {
            /*
             * Cannot recover. Complete with DID_NO_CONNECT (or whatever
             * host_byte was already set by the transport).
             * blk-mq sees BLK_STS_IOERR (or BLK_STS_TRANSPORT for FAILFAST).
             * dm-multipath sees path failure via multipath_end_io().
             */
            if (!scmd->result)
                scmd->result = DID_NO_CONNECT << 16;
            scsi_finish_command(scmd);  /* complete to application */
        }
    }
}
```

`scsi_finish_command(scmd)` calls `scsi_io_completion()` →
`blk_mq_complete_request()` → dm-multipath's `multipath_end_io()` → `fail_path()`.

---

## Key takeaways

- EH runs in `scsi_error_handler` kthread per Scsi_Host. Woken by session drop or command timeout.
- Escalation: abort → LUN reset → target reset → bus reset → offline device.
- For iSCSI: abort sends ABORT TASK TMF; LUN reset sends LOGICAL_UNIT_RESET TMF; target reset
  drops and reconnects the session.
- `eh_deadline = -1` (default) means EH itself has no timeout; the practical bound is
  `replacement_timeout`, which is pushed to the kernel from open-iscsi userspace (typically 120s).
- `RESERVATION CONFLICT` is in `scsi_noretry_cmd()` — it NEVER enters EH, even for normal I/O.
- EH unrecoverable commands get `DID_NO_CONNECT` → `BLK_STS_IOERR` → dm-multipath `fail_path()`.
- Modern libiscsi stores the per-command iscsi_task in the SCSI command's private area
  (`scsi_cmd_priv(sc)`), not in the legacy `sc->SCp.ptr` field which was removed in v6.2.
- Chain: session drop → `iscsi_conn_failure()` → EH wakes → recovery timeout → DID_TRANSPORT_FAILFAST
  → `fail_path()` → `nr_valid_paths=0` → `no_path_retry=queue` takes effect.

---

## Previous / Next

[Day 5 — SCSI completion and disposition](day05.md) | [Day 7 — dm-multipath core](day07.md)
