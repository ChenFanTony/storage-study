# Day 12 — session failure and EH interaction

**Week 2**: iSCSI Initiator Kernel Code  
**Time**: 1–2 hours  
**Reference**: `drivers/scsi/libiscsi.c`, `drivers/scsi/scsi_transport_iscsi.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

When a TCP session breaks (RST, FIN, NOP-Out timeout), libiscsi must coordinate three things:

1. Stop sending new commands on this connection.
2. Mark in-flight commands so they can be replayed when the session reconnects.
3. Coordinate with the SCSI Error Handler (EH) and dm-multipath about what to fail / retry / queue.

The interaction between `iscsi_conn_failure()`, the SCSI mid-layer EH (day 6), and dm-multipath
(day 7) is the heart of the fencing problem. Understanding the timing here is essential.

---

## iscsi_conn_failure — entry point — `drivers/scsi/libiscsi.c`

Called whenever the connection breaks: TCP error, NOP-Out timeout, RX parse error, transmit
failure.

```c
/* Simplified — see drivers/scsi/libiscsi.c. */
void iscsi_conn_failure(struct iscsi_conn *conn, enum iscsi_err err)
{
    struct iscsi_session *session = conn->session;
    unsigned long flags;

    spin_lock_irqsave(&session->frwd_lock, flags);

    if (session->state == ISCSI_STATE_FAILED) {
        spin_unlock_irqrestore(&session->frwd_lock, flags);
        return; /* already failing — idempotent */
    }

    session->state = ISCSI_STATE_FAILED;
    conn->state    = ISCSI_CONN_FAILED;

    /*
     * Stop the TX worker — no new commands sent on this connection.
     */
    set_bit(ISCSI_SUSPEND_BIT, &conn->suspend_tx);
    set_bit(ISCSI_SUSPEND_BIT, &conn->suspend_rx);

    spin_unlock_irqrestore(&session->frwd_lock, flags);

    /*
     * Notify the iscsi transport class — this calls
     * iscsi_block_session() which calls scsi_target_block() to move the
     * SCSI devices toward SDEV_TRANSPORT_OFFLINE. Held bios get retried
     * by blk-mq instead of failed immediately.
     */
    iscsi_conn_error_event(conn->cls_conn, err);
}
```

---

## scsi_target_block — `drivers/scsi/scsi_lib.c`

Called by `iscsi_block_session()` from the transport class, this puts the per-LUN state machine
into a transport-blocked state:

```c
/* Simplified. */
int scsi_target_block(struct device *dev)
{
    if (scsi_is_target_device(dev))
        starget_for_each_device(to_scsi_target(dev), NULL,
                                  device_block);
    else
        device_for_each_child(dev, NULL, target_block);
    return 0;
}

static void device_block(struct scsi_device *sdev, void *data)
{
    int err;

    err = scsi_internal_device_block_nowait(sdev);
    /*
     * Sets sdev_state = SDEV_TRANSPORT_OFFLINE (or SDEV_BLOCK depending
     * on path). After this:
     *   - new commands hitting scsi_prep_state_check() get
     *     BLK_STS_TRANSPORT (held by blk-mq for retry)
     *   - in-flight commands are not aborted yet — EH will decide
     */
}
```

---

## In-flight command handling

When the connection fails, in-flight `iscsi_task` entries on `conn->taskqueue` need to be marked.
They cannot complete normally (response will never arrive). Two strategies:

1. **Wait for reconnect (ERL=1 mode):** keep the tasks pending. After reconnect, replay or expect
   the target to deliver responses (only with command-recovery negotiated, which is rare).
2. **Force-fail (default):** complete each task with `DID_TRANSPORT_DISRUPTED` after EH timeout.

Modern open-iscsi uses (2) by default. The transport class triggers `iscsi_session_recovery_timedout()`
after `recovery_tmo` jiffies (the kernel field is set from the userspace
`replacement_timeout` parameter, default 120s):

```c
/* Simplified — see scsi_transport_iscsi.c for the actual handler. */
static void iscsi_session_recovery_timedout(struct iscsi_cls_session *cls_session)
{
    struct iscsi_session *session = cls_session->dd_data;

    spin_lock_bh(&session->frwd_lock);
    session->state = ISCSI_STATE_RECOVERY_FAILED;
    spin_unlock_bh(&session->frwd_lock);

    /*
     * Transport class wakes EH and unblocks the SCSI devices into the
     * permanent-offline state. The actual unblock call is made by the
     * transport class machinery — not directly here. Held commands now
     * complete with DID_TRANSPORT_FAILFAST as the device transitions
     * out of the blocked state.
     */
}
```

The transition `ISCSI_STATE_FAILED → ISCSI_STATE_RECOVERY_FAILED` is the moment where:
- All held commands fail with `DID_TRANSPORT_FAILFAST` → `BLK_STS_TRANSPORT`
- dm-multipath sees `BLK_STS_TRANSPORT` and calls `fail_path()` for this path
- `nr_valid_paths` decrements
- If this was the last path AND `no_path_retry=queue` is set → bios queue indefinitely

---

## Recovery work — `drivers/scsi/libiscsi.c`

```c
/* Simplified — schedules userspace iscsid (via netlink) to drive the
 * actual reconnect; the kernel work just arms the recovery timer. */
static void iscsi_session_failure(struct iscsi_session *session,
                                   enum iscsi_err err)
{
    spin_lock_bh(&session->frwd_lock);
    session->state = ISCSI_STATE_FAILED;
    spin_unlock_bh(&session->frwd_lock);

    /*
     * Schedule recovery_work to fire after recovery_tmo.
     * If a reconnect succeeds before the timer fires, the work is cancelled.
     * If the timer fires, recovery is declared failed.
     *
     * recovery_tmo is the kernel-side mirror of the userspace
     * node.session.timeo.replacement_timeout (default 120s, pushed to the
     * kernel via sysfs at session creation).
     */
    schedule_delayed_work(&session->recovery_work,
                          session->recovery_tmo * HZ);
}
```

When the timer fires:
```c
static void iscsi_recovery_timed_out(struct work_struct *work)
{
    struct delayed_work *dwork = to_delayed_work(work);
    struct iscsi_session *session =
        container_of(dwork, struct iscsi_session, recovery_work);

    iscsi_session_recovery_timedout(session->cls_session);
}
```

---

## Userspace coordination via netlink

The kernel does not initiate reconnects itself. It relies on `iscsid` (open-iscsi userspace) to
attempt reconnection. The flow:

```
1. Kernel: iscsi_conn_failure()
2. Kernel: send ISCSI_KEVENT_CONN_ERROR netlink message to iscsid
3. iscsid receives error, marks session failed
4. iscsid: attempt reconnect — may take many attempts, each retrying TCP connect + Login
5a. Reconnect succeeds:
    iscsid sends ISCSI_UEVENT_TRANSPORT_EP_CONNECT, then ISCSI_UEVENT_START_CONN
    Kernel: cancel recovery_work, transition to ISCSI_STATE_LOGGED_IN
5b. Reconnect fails for replacement_timeout seconds:
    Kernel: recovery_work fires → ISCSI_STATE_RECOVERY_FAILED
    All held I/O fails → dm-multipath fail_path()
```

This split is important: the kernel timer (`recovery_tmo`) is just a deadline. The actual reconnect
attempts are made by `iscsid`, which uses its own retry logic (typically tries every
`node.conn[0].timeo.login_timeout` seconds).

---

## EH interaction during session failure

If the SCSI mid layer's command timer fires while the session is failed, EH wakes for that
command:

```
Command timer fires (default 30s)
    │
    ▼
scsi_times_out(scmd)
    │
    ▼
scsi_eh_scmd_add(scmd, SCSI_EH_CANCEL_CMD)
    │  scmd added to shost->eh_cmd_q
    │  scsi_eh_wakeup(shost) wakes EH kthread
    ▼
scsi_unjam_host()
    │
    ▼
scsi_eh_abort_cmds()
    │  for each scmd: try iscsi_eh_abort() (day 6)
    ▼
iscsi_eh_abort()
    │  session->state != ISCSI_STATE_LOGGED_IN
    │  → return FAILED
    ▼
scsi_eh_ready_devs()
    │  try iscsi_eh_device_reset() — fails (session not logged in)
    │  try iscsi_eh_target_reset() — drops session, triggers reconnect
    │  try host reset — also fails
    ▼
scsi_eh_offline_sdevs()
    │  set sdev_state = SDEV_OFFLINE
    │  scmd->result = DID_NO_CONNECT << 16
    │  scsi_finish_command(scmd)
    ▼
multipath_end_io()
    │  blk_path_error(BLK_STS_IOERR) = true → fail_path()
```

This path is taken when `eh_deadline` is short relative to `replacement_timeout`. With the default
`eh_deadline=-1`, EH keeps trying until either the session reconnects or `replacement_timeout`
expires.

---

## Suspend bits — gating new commands

`conn->suspend_tx` and `conn->suspend_rx` are checked in the queuecommand and TX paths:

```c
/* in iscsi_queuecommand() (day 9) */
if (test_bit(ISCSI_SUSPEND_BIT, &conn->suspend_tx)) {
    reason = SCSI_MLQUEUE_HOST_BUSY;
    goto reject;
}
```

Setting `suspend_tx` halts all dispatch on this connection. Set by:
- `iscsi_conn_failure()` — connection failed
- `__iscsi_conn_send_pdu()` — during certain TMF processing
- `iscsi_suspend_tx()` — explicit pause (called by `scsi_target_block()`)

Cleared by:
- `iscsi_unblock_session()` — after successful reconnect / login
- `iscsi_resume_tx()` — explicit resume

This is the same suspend mechanism used by EH to pause the connection during reset operations.

---

## State transition diagram with timing

```
Session state                Connection state           Devices state
═════════════                ════════════════           ═════════════

LOGGED_IN  ──TCP RST──┐
                      │
                      ▼
                FAILED                                  SDEV_TRANSPORT_OFFLINE
                  │                                         (held by blk-mq)
                  │ delayed_work armed (recovery_tmo)
                  │
        ┌─────────┴─────────┐
        │                   │
   reconnect              timeout
   succeeds               (replacement_timeout)
        │                   │
        ▼                   ▼
  LOGGED_IN              RECOVERY_FAILED                SDEV_OFFLINE (or
        │                   │                            transitions out of
        │                   │                            blocked → commands
        ▼                   ▼                            complete)
  Held cmds              Held cmds: DID_TRANSPORT_FAILFAST
  retried                blk_status: BLK_STS_TRANSPORT
        │                   │
                            ▼
                       multipath_end_io()
                            │
                            ▼
                       fail_path()
                       atomic_dec(nr_valid_paths)
                            │
                            ▼  (if nr_valid_paths==0 && queue_if_no_path)
                       Future bios → m->queued_bios (HANG)
```

---

## Why this matters for fencing

When a fenced node's session is dropped administratively on the target:

1. Target sends Async PDU `REQUEST_LOGOUT` (clean) OR sends TCP RST (abrupt).
2. Initiator: `iscsi_conn_failure()` → `ISCSI_STATE_FAILED`.
3. Initiator's `iscsid` tries to reconnect.
4. Target's ACL has been removed (or initiator IQN deleted) → Login Response: status 0x0203
   "Initiator not allowed".
5. `iscsid` keeps retrying — each attempt fails with the same auth rejection.
6. After `replacement_timeout` (120s default), kernel: `ISCSI_STATE_RECOVERY_FAILED`.
7. All paths `fail_path()`'d → `nr_valid_paths=0`.
8. New bios queue forever in `m->queued_bios` (assuming `no_path_retry=queue`).

Fencing achieved — the node cannot write to the SAN. But its applications hang on every I/O.
This is the trade-off `no_path_retry=queue` makes: data integrity > availability.

---

## Key takeaways

- `iscsi_conn_failure()` is the entry point for all session breaks. It sets state to FAILED and
  suspends TX/RX.
- `scsi_target_block()` (called by the iSCSI transport class) holds new commands at the SCSI mid
  layer with `BLK_STS_TRANSPORT` so they can retry once the session is back.
- `recovery_tmo` (the kernel field set from userspace `replacement_timeout`) is the deadline.
  After expiry, `ISCSI_STATE_RECOVERY_FAILED` — held commands fail with `DID_TRANSPORT_FAILFAST`.
- dm-multipath sees `BLK_STS_TRANSPORT` → `fail_path()` → `atomic_dec(&m->nr_valid_paths)`.
- The kernel does NOT do reconnects itself — `iscsid` (userspace) is in charge. Kernel just
  enforces the deadline.
- Async PDU `REQUEST_LOGOUT` (opcode 0x32, AsyncEvent 0x01) is the clean session-drop signal.
  TCP RST is the abrupt one.
- For session-drop fencing: target removes ACL → reconnect attempts fail at Login → after
  `replacement_timeout`, paths fail and (with `no_path_retry=queue`) bios queue forever.
- All references to a per-command session age use the SCSI command's private area (modern
  `iscsi_cmd(sc)` / `scsi_cmd_priv()`), not the legacy `sc->SCp` field which was removed in v6.2.

---

## Previous / Next

[Day 11 — iscsi_tcp RX path](day11.md) | [Day 13 — PR slow path: initiator side](day13.md)
