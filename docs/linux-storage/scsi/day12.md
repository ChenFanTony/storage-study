# Day 12 — session failure and EH interaction

**Week 2**: iSCSI Initiator Kernel Code
**Time**: 1–2 hours
**Reference**: `drivers/scsi/libiscsi.c`

---

## Overview

When a TCP session drops (RST, FIN, or timeout), `iscsi_conn_failure()` is called. This starts
a chain of state transitions, device blocking, and EH interactions that ultimately either recovers
the session or — after `replacement_timeout` — permanently fails all commands. This is the exact
chain that connects a target-side fence action (session drop + ACL removal) to a dm-multipath
path failure visible to the application.

---

## iscsi_conn_failure — `drivers/scsi/libiscsi.c`

The entry point for any connection-level error. Called from:
- TCP socket error callback (`iscsi_sw_tcp_error_report`)
- NOP-Out timeout (`iscsi_check_transport_timeouts`)
- RX parse error (`iscsi_tcp_recv_pdu` on bad opcode/digest)
- Async PDU requesting logout

```c
void iscsi_conn_failure(struct iscsi_conn *conn, enum iscsi_err err)
{
    struct iscsi_session *session = conn->session;
    unsigned long flags;

    spin_lock_irqsave(&session->frwd_lock, flags);

    if (session->state == ISCSI_STATE_FAILED) {
        /* already failing — don't process again */
        spin_unlock_irqrestore(&session->frwd_lock, flags);
        return;
    }

    if (conn->stop_stage == 0)
        session->state = ISCSI_STATE_FAILED;

    spin_unlock_irqrestore(&session->frwd_lock, flags);

    /*
     * Record the error for userspace (iscsid) to see.
     * ISCSI_ERR_CONN_FAILED, ISCSI_ERR_XMIT_FAILED, etc.
     */
    set_bit(err, &conn->err_flags);

    /*
     * Stop accepting new commands on this connection.
     * suspend_tx=1 → iscsi_queuecommand() returns MLQUEUE_HOST_BUSY.
     * suspend_rx=1 → RX path stops processing.
     */
    iscsi_suspend_tx(conn);

    /*
     * Notify the iSCSI transport class → userspace iscsid daemon.
     * iscsid will attempt to reconnect.
     */
    iscsi_conn_error_event(conn->cls_conn, err);
}
EXPORT_SYMBOL_GPL(iscsi_conn_failure);
```

After `session->state = ISCSI_STATE_FAILED`:
- `iscsi_session_chkready()` returns `DID_TRANSPORT_DISRUPTED` for new commands
- New commands are requeued by blk-mq (not failed permanently)
- `replacement_timeout` countdown begins (via the delayed work registered in `iscsi_session_setup`)

---

## iscsi_suspend_tx — stopping command flow

```c
void iscsi_suspend_tx(struct iscsi_conn *conn)
{
    struct Scsi_Host *shost = conn->session->host;

    /*
     * Set the suspend bit — TX kthread checks this before sending.
     * In-progress sends may complete, but no new ones will start.
     */
    set_bit(ISCSI_SUSPEND_BIT, &conn->suspend_tx);

    /*
     * scsi_target_block() sets all scsi_devices on this target
     * to SDEV_TRANSPORT_OFFLINE state.
     *
     * Effect on blk-mq:
     *   - scsi_prep_state_check() returns SCSI_MLQUEUE_TERMINATE
     *     for new commands → DID_TRANSPORT_DISRUPTED
     *   - Commands already in the SCSI mid layer are held
     *   - EH is woken for in-flight commands that timed out
     */
    scsi_target_block(&conn->session->cls_session->dev);
}
```

`scsi_target_block()` walks all `scsi_device` structs under the target and calls
`scsi_device_set_state(sdev, SDEV_TRANSPORT_OFFLINE)` + `scsi_device_blocked(sdev)`. This causes
`scsi_queue_rq()` to return `SCSI_MLQUEUE_DEVICE_BUSY` for any new requests — blk-mq queues them
and retries until the device unblocks or the host's EH gives up.

---

## iscsi_session_recovery_timedout — `drivers/scsi/libiscsi.c`

Fires when `replacement_timeout` expires without reconnection:

```c
static void iscsi_session_recovery_timedout(struct work_struct *work)
{
    struct iscsi_session *session =
        container_of(work, struct iscsi_session, recovery_work.work);

    spin_lock_bh(&session->frwd_lock);
    if (session->state != ISCSI_STATE_LOGGED_IN) {
        /*
         * Still not logged in after replacement_timeout seconds.
         * Transition to RECOVERY_FAILED.
         * iscsi_session_chkready() will now return DID_TRANSPORT_FAILFAST.
         * DID_TRANSPORT_FAILFAST → scsi_decide_disposition() → SUCCESS (with error)
         * → BLK_STS_TRANSPORT → multipath_end_io() → blk_path_error()=true
         * → fail_path() → nr_valid_paths-- → queued_ios accumulates.
         */
        session->state = ISCSI_STATE_RECOVERY_FAILED;
    }
    spin_unlock_bh(&session->frwd_lock);

    /*
     * Unblock the scsi_devices — but since state=RECOVERY_FAILED,
     * new commands will get DID_TRANSPORT_FAILFAST instead of DISRUPTED.
     * EH will complete all held commands with DID_TRANSPORT_FAILFAST.
     */
    scsi_target_unblock(&session->cls_session->dev, SDEV_TRANSPORT_OFFLINE);

    wake_up_all(&session->ehwait);
}
```

The transition `ISCSI_STATE_FAILED → ISCSI_STATE_RECOVERY_FAILED` is the moment the path is
permanently lost. Everything before this point is recoverable. After this, dm-multipath removes
the path from the valid set.

---

## iscsi_eh_abort — `drivers/scsi/libiscsi.c`

Called by the SCSI EH kthread (day 6) to abort a specific command:

```c
int iscsi_eh_abort(struct scsi_cmnd *sc)
{
    struct iscsi_cls_session *cls_session =
        starget_to_session(scsi_target(sc->device));
    struct iscsi_session *session = cls_session->dd_data;
    struct iscsi_conn *conn;
    struct iscsi_task *task;
    int rc, age;

    mutex_lock(&session->eh_mutex);
    spin_lock_bh(&session->frwd_lock);

    /*
     * Validate that this command belongs to the CURRENT session.
     * sc->SCp.phase holds the session age at the time the command
     * was allocated. If it doesn't match session->age, the command
     * was from a previous session and is already gone.
     */
    age = sc->SCp.phase;
    if (session->age != age) {
        /* stale command — consider it aborted already */
        rc = SUCCESS;
        goto unlock;
    }

    if (session->state != ISCSI_STATE_LOGGED_IN) {
        /* cannot send TMF if session is down */
        rc = FAILED;
        goto unlock;
    }

    conn = session->leadconn;

    /* find the iscsi_task from sc->SCp.ptr */
    task = (struct iscsi_task *)sc->SCp.ptr;

    if (!task || !task->sc) {
        /* task completed normally between EH trigger and now */
        rc = SUCCESS;
        goto unlock;
    }

    iscsi_get_task(task);
    spin_unlock_bh(&session->frwd_lock);

    ISCSI_DBG_EH(session, "aborting [sc %p itt 0x%x]\n",
                 sc, task->itt);

    /* suspend command queue — don't let new commands race with abort */
    iscsi_suspend_queue(conn);

    /*
     * Send ABORT TASK TMF PDU.
     * The response from the target (TASK_MGMT_RESPONSE) will be
     * delivered via iscsi_tmf_rsp() in the RX path.
     *
     * We wait up to session->abort_timeout seconds (default 10s).
     */
    conn->tmabort_state = TMABORT_INITIAL;
    rc = iscsi_exec_task_mgmt_fn(conn, ISCSI_TM_FUNC_ABORT_TASK,
                                  session->age, task->itt);

    switch (rc) {
    case SUCCESS:
        rc = iscsi_eh_abort_cleanup(task);
        break;
    case FAILED:
    case TIMEDOUT:
        break;
    }

    iscsi_resume_queue(conn);
    iscsi_put_task(task);

    mutex_unlock(&session->eh_mutex);
    return rc;

unlock:
    spin_unlock_bh(&session->frwd_lock);
    mutex_unlock(&session->eh_mutex);
    return rc;
}
EXPORT_SYMBOL_GPL(iscsi_eh_abort);
```

---

## iscsi_eh_device_reset — LUN reset — `drivers/scsi/libiscsi.c`

```c
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
        /* session gone — cannot send TMF */
        mutex_unlock(&session->eh_mutex);
        return FAILED;
    }

    conn = session->leadconn;

    iscsi_suspend_queue(conn);

    /*
     * Send LOGICAL UNIT RESET TMF.
     * On LIO target: core_tmr_lun_reset() aborts all tasks for this LUN.
     * LUN reset causes a UNIT ATTENTION on all subsequent commands
     * (POWER ON, RESET, OR BUS DEVICE RESET OCCURRED).
     * Wait up to session->lu_reset_timeout seconds (default 15s).
     */
    rc = iscsi_exec_task_mgmt_fn(conn, func, session->age, 0);

    iscsi_resume_queue(conn);
    mutex_unlock(&session->eh_mutex);
    return rc;
}
EXPORT_SYMBOL_GPL(iscsi_eh_device_reset);
```

---

## iscsi_eh_recover_target — target reset — `drivers/scsi/libiscsi.c`

```c
int iscsi_eh_recover_target(struct scsi_cmnd *sc)
{
    struct iscsi_cls_session *cls_session =
        starget_to_session(scsi_target(sc->device));
    struct iscsi_session *session = cls_session->dd_data;
    int rc;

    mutex_lock(&session->eh_mutex);

    if (session->state == ISCSI_STATE_LOGGED_IN) {
        /* try TARGET WARM RESET first */
        rc = iscsi_eh_reset_helper(sc, ISCSI_TM_FUNC_TARGET_WARM_RESET);
    } else {
        rc = FAILED;
    }

    if (rc == FAILED) {
        /*
         * Cannot communicate with target.
         * Drop the connection and let recovery machinery reconnect.
         * This triggers: iscsi_conn_failure() →
         *   session->state = ISCSI_STATE_FAILED →
         *   replacement_timeout starts →
         *   iscsid reconnect attempt.
         *
         * If reconnect succeeds within replacement_timeout:
         *   session reconnects → DID_TRANSPORT_DISRUPTED clears →
         *   commands resubmitted.
         *
         * If NOT → replacement_timeout fires → DID_TRANSPORT_FAILFAST →
         *   dm-multipath fail_path().
         */
        iscsi_conn_failure(conn, ISCSI_ERR_CONN_FAILED);
        rc = SUCCESS; /* EH treated as handled — recovery machinery takes over */
    }

    mutex_unlock(&session->eh_mutex);
    return rc;
}
EXPORT_SYMBOL_GPL(iscsi_eh_recover_target);
```

---

## The full session-drop → path-failure chain

```
Target drops TCP session (RST or admin teardown)
    │
    ▼  iscsi_sw_tcp_error_report() / NOP timeout
iscsi_conn_failure(conn, ISCSI_ERR_CONN_FAILED)
    │  session->state = ISCSI_STATE_FAILED
    │  set_bit(ISCSI_SUSPEND_BIT, &conn->suspend_tx)
    │  scsi_target_block() → SDEV_TRANSPORT_OFFLINE on all sdevs
    │  iscsi_conn_error_event() → notify iscsid
    │
    ▼  [replacement_timeout countdown begins — default 120s]
    │
    │  [iscsid attempts reconnect: login → negotiate params → LOGGED_IN]
    │  [if reconnect succeeds within 120s: session recovers, commands resume]
    │
    │  [if ACL was removed (fencing): login rejected → reconnect fails]
    │
    ▼  [120s later — no reconnect]
iscsi_session_recovery_timedout()
    │  session->state = ISCSI_STATE_RECOVERY_FAILED
    │  scsi_target_unblock() → EH fires for all blocked commands
    │
    ▼  EH runs for each blocked command:
    │  iscsi_eh_abort() → FAILED (session gone)
    │  iscsi_eh_device_reset() → FAILED (session gone)
    │  iscsi_eh_recover_target() → FAILED
    │  scsi_eh_flush_done_q() → sc->result = DID_NO_CONNECT << 16
    │  scsi_finish_command(sc) → scsi_io_completion()
    │  scsi_result_to_blk_status() → BLK_STS_IOERR
    │
    ▼  dm-multipath:
    │  multipath_end_io() → blk_path_error(BLK_STS_IOERR) = true
    │  fail_path(pgpath) → atomic_dec(&m->nr_valid_paths)
    │
    ▼  [if last path]
    │  nr_valid_paths == 0
    │  New bios → multipath_map_bio() → bio_list_add(&m->queued_ios, bio)
    │
    ▼  [if no_path_retry=queue]
    Application I/O hangs until a path recovers (never, if fenced)
```

---

## Why session drop + ACL removal is the right fencing approach

```
Session drop ONLY:
    iscsid reconnects → gets back in → fencing incomplete

ACL removal ONLY:
    existing session still active → I/O continues → fencing incomplete

Session drop + ACL removal:
    1. Session drops → iscsi_conn_failure() → ISCSI_STATE_FAILED
    2. iscsid reconnects → Login Phase → target checks ACL → REJECT
    3. Login rejected → reconnect fails → replacement_timeout counts down
    4. At 120s → RECOVERY_FAILED → DID_TRANSPORT_FAILFAST → fail_path()
    5. dm-multipath: path permanently failed → I/O fails (or queues if queue mode)

For no_path_retry=queue:
    Step 4 above + all paths fail = queued_ios accumulates.
    To avoid hang: reduce replacement_timeout or set no_path_retry=fail.
```

---

## Key takeaways

- `iscsi_conn_failure()` is the entry point for all connection errors. It sets
  `ISCSI_STATE_FAILED`, suspends TX, and blocks the SCSI target device.
- `scsi_target_block()` sets `SDEV_TRANSPORT_OFFLINE` — new commands get `DID_TRANSPORT_DISRUPTED`
  (retry) not `FAILFAST` (permanent failure). Commands are held, not failed.
- `iscsi_session_recovery_timedout()` fires after `replacement_timeout` (default 120s). Sets
  `ISCSI_STATE_RECOVERY_FAILED`. Now `DID_TRANSPORT_FAILFAST` → dm-multipath `fail_path()`.
- EH (`iscsi_eh_abort`, `iscsi_eh_device_reset`, `iscsi_eh_recover_target`) all fail when the
  session is gone. EH then completes commands with `DID_NO_CONNECT`.
- `DID_NO_CONNECT` → `BLK_STS_IOERR` → `fail_path()` → `nr_valid_paths--`.
- `session->age` stamped in sc→SCp.phase prevents EH from aborting commands from the wrong session.
- Session drop + ACL removal = clean fence. Session drop alone = reconnect possible.

---

## Previous / Next

[Day 11 — iscsi_tcp RX path](day11.md) | [Day 13 — PR slow path initiator side](day13.md)
