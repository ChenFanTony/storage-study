# Day 25 — session teardown path

**Week 4**: Deep Cuts — TMF, ALUA, configfs, NVMe-oF, Sense Data
**Time**: 1–2 hours
**Reference**: `drivers/target/iscsi/iscsi_target.c`, `drivers/target/target_core_transport.c`

---

## Overview

Session teardown is the mechanism by which a target closes a connection and drains all in-flight
commands safely. It is central to both planned shutdown and fencing. The key requirement: no
command must be completed after the session memory is freed, and no command must be lost without
a response. `sess_tearing_down` and `sess_cmd_list` drain are the mechanisms that guarantee this.

---

## iscsit_close_session — `drivers/target/iscsi/iscsi_target.c`

```c
void iscsit_close_session(struct se_session *se_sess)
{
    struct iscsi_session *sess = se_sess->fabric_sess_ptr;

    /*
     * Step 1: Mark session as being torn down.
     * New commands arriving after this point are rejected:
     * transport_lookup_cmd_lun() checks sess_tearing_down and returns
     * TCM_LOGICAL_UNIT_COMMUNICATION_FAILURE for new commands.
     */
    spin_lock_bh(&se_sess->sess_cmd_lock);
    se_sess->sess_tearing_down = 1;
    spin_unlock_bh(&se_sess->sess_cmd_lock);

    /*
     * Step 2: Close all connections on this session.
     */
    iscsit_close_connection(sess->leadconn);

    /*
     * Step 3: Wait for all in-flight commands to drain.
     * Blocks until sess_cmd_list is empty.
     */
    target_wait_for_sess_cmds(se_sess);

    /*
     * Step 4: Release the session memory.
     */
    iscsit_dec_session_usage_count(sess);
    target_put_session(se_sess);
}
```

---

## iscsit_close_connection — `drivers/target/iscsi/iscsi_target.c`

```c
int iscsit_close_connection(struct iscsi_conn *conn)
{
    struct iscsi_session *sess = conn->sess;

    /*
     * Optional: send Async PDU requesting logout before closing.
     * ISCSI_ASYNC_MSG_REQUEST_LOGOUT:
     *   Tells initiator: logout gracefully, Time2Wait=0, Time2Retain=0.
     *   Cleaner than abrupt TCP RST — gives initiator a chance to
     *   complete in-flight commands before the connection closes.
     *
     * If the connection is already broken (TCP error), this is skipped.
     */
    if (!conn->conn_logout_reason &&
        sess->sess_ops->SessionType == NORMAL_SESSION) {
        iscsit_send_async_msg(conn, conn->cid,
                               ISCSI_ASYNC_MSG_REQUEST_LOGOUT, 0);
    }

    /*
     * Stop the TX kthread.
     * kthread_stop() + flush_work() drains any pending PDU sends.
     * No more data is sent to the initiator after this.
     */
    iscsit_stop_tx_thread(conn);

    /*
     * Stop the RX kthread.
     * Any partially-received PDU is abandoned.
     */
    iscsit_stop_rx_thread(conn);

    /*
     * Close the TCP socket.
     * sock_release() sends TCP FIN (graceful) or RST (if send buffer has data).
     * On initiator: sk_state_change callback fires ->
     *   iscsi_sw_tcp_state_change() -> iscsi_conn_failure(ISCSI_ERR_CONN_FAILED).
     */
    if (conn->sock) {
        sock_release(conn->sock);
        conn->sock = NULL;
    }

    /*
     * Abort all commands on this connection.
     * Sets CMD_T_ABORTED | CMD_T_FABRIC_STOP on each se_cmd.
     * Backend I/O continues to completion, but no response PDU is sent.
     * Each completed command calls target_put_sess_cmd() which drains
     * from sess_cmd_list, eventually completing the wait in
     * target_wait_for_sess_cmds().
     */
    iscsit_release_commands_from_conn(conn);

    return 0;
}
```

---

## iscsit_release_commands_from_conn — aborting in-flight commands

```c
static void iscsit_release_commands_from_conn(struct iscsi_conn *conn)
{
    struct iscsit_cmd *cmd, *cmd_tmp;
    struct se_cmd *se_cmd;

    spin_lock_bh(&conn->cmd_lock);

    list_for_each_entry_safe(cmd, cmd_tmp,
                              &conn->conn_cmd_list, i_conn_node) {
        se_cmd = &cmd->se_cmd;

        spin_lock(&se_cmd->t_state_lock);

        if (se_cmd->transport_state & CMD_T_COMPLETE) {
            spin_unlock(&se_cmd->t_state_lock);
            continue;  /* already done — nothing to do */
        }

        /*
         * CMD_T_ABORTED: checked in target_execute_cmd() before dispatch.
         * If set before the command reaches the backend:
         *   command is skipped entirely (not submitted to iblock/fileio).
         *
         * CMD_T_FABRIC_STOP: tells target_complete_cmd() not to call
         *   se_tfo->queue_status() — no response PDU is sent.
         *   The fabric (iSCSI) layer is already gone.
         */
        se_cmd->transport_state |= CMD_T_ABORTED | CMD_T_FABRIC_STOP;

        spin_unlock(&se_cmd->t_state_lock);
    }

    spin_unlock_bh(&conn->cmd_lock);
}
```

---

## target_wait_for_sess_cmds — `drivers/target/target_core_transport.c`

```c
void target_wait_for_sess_cmds(struct se_session *se_sess)
{
    struct se_cmd *se_cmd;
    unsigned long flags;

    /*
     * Walk sess_cmd_list and identify any commands needing TAS
     * (Task Aborted Status). TAS commands get SAM_STAT_TASK_ABORTED
     * sent to the initiator to inform it the command was aborted.
     *
     * For fencing teardown: CMD_T_FABRIC_STOP is set, so queue_status()
     * is not called. TAS is only relevant for planned shutdowns where
     * the fabric is still alive.
     */
    spin_lock_irqsave(&se_sess->sess_cmd_lock, flags);
    list_for_each_entry(se_cmd, &se_sess->sess_cmd_list, se_cmd_list) {
        bool aborted = !!(se_cmd->transport_state & CMD_T_ABORTED);
        pr_debug("Waiting for se_cmd %p (aborted=%d)\n",
                 se_cmd, aborted);
    }
    spin_unlock_irqrestore(&se_sess->sess_cmd_lock, flags);

    /*
     * The actual wait.
     * sess_wait_comp is completed in target_release_cmd_kref()
     * when the last se_cmd is removed from sess_cmd_list.
     *
     * This may take up to the maximum backend I/O latency:
     * for spinning disks, potentially seconds.
     * For fast NVMe backends: microseconds to milliseconds.
     */
    wait_for_completion(&se_sess->sess_wait_comp);
}
EXPORT_SYMBOL(target_wait_for_sess_cmds);
```

The completion is triggered in `target_release_cmd_kref()` (called from `target_put_sess_cmd()`
when the command reference reaches zero):

```c
static void target_release_cmd_kref(struct kref *kref)
{
    struct se_cmd *se_cmd = container_of(kref, struct se_cmd, cmd_kref);
    struct se_session *se_sess = se_cmd->se_sess;
    struct completion *compl = NULL;
    unsigned long flags;

    spin_lock_irqsave(&se_sess->sess_cmd_lock, flags);

    /* remove from sess_cmd_list */
    list_del_init(&se_cmd->se_cmd_list);

    /*
     * If session teardown is waiting AND the list is now empty:
     * signal the waiter in target_wait_for_sess_cmds().
     */
    if (se_sess->sess_tearing_down && list_empty(&se_sess->sess_cmd_list))
        compl = &se_sess->sess_wait_comp;

    spin_unlock_irqrestore(&se_sess->sess_cmd_lock, flags);

    /* release LUN reference */
    if (se_cmd->lun_ref_active)
        percpu_ref_put(&se_cmd->se_lun->lun_ref);

    /* free SGL pages */
    transport_free_pages(se_cmd);

    /* fabric-specific cleanup */
    se_cmd->se_tfo->release_cmd(se_cmd);

    /* wake teardown waiter — after all cleanup is done */
    if (compl)
        complete(compl);
}
```

Memory safety is guaranteed: `complete(compl)` is called only AFTER `se_cmd->se_tfo->release_cmd()`
— which frees the `iscsit_cmd` embedding the `se_cmd`. The waiter in `target_wait_for_sess_cmds()`
wakes after all commands are freed, not before.

---

## sess_tearing_down as a gate for new commands

```c
/* transport_lookup_cmd_lun() in target_core_transport.c */
sense_reason_t transport_lookup_cmd_lun(struct se_cmd *se_cmd, u64 unpacked_lun)
{
    struct se_session *se_sess = se_cmd->se_sess;
    unsigned long flags;

    spin_lock_irqsave(&se_sess->sess_cmd_lock, flags);

    if (se_sess->sess_tearing_down) {
        /*
         * Session is closing. Reject new commands immediately.
         * The se_cmd is NOT added to sess_cmd_list.
         * transport_generic_request_failure() will be called,
         * which calls target_complete_cmd() with COMMUNICATION_FAILURE.
         * Since CMD_T_FABRIC_STOP is set, no response PDU is sent.
         */
        spin_unlock_irqrestore(&se_sess->sess_cmd_lock, flags);
        return TCM_LOGICAL_UNIT_COMMUNICATION_FAILURE;
    }

    /*
     * Add to sess_cmd_list for teardown tracking.
     * This reference is dropped by target_put_sess_cmd().
     */
    list_add_tail(&se_cmd->se_cmd_list, &se_sess->sess_cmd_list);

    spin_unlock_irqrestore(&se_sess->sess_cmd_lock, flags);

    /* proceed with LUN resolution */
    return TCM_NO_SENSE;
}
```

---

## Complete fencing teardown timeline

```
Admin: targetcli acls delete wwn=<initiator_iqn>
    │
    ▼  core_tpg_del_initiator_node_acl()
    │   list_del(&acl->acl_list)     ← login check returns NULL immediately
    │   se_tfo->close_session()      ← for each active session
    │
    ▼  iscsit_close_session(se_sess)
    │   sess_tearing_down = 1        ← new commands rejected
    │
    ▼  iscsit_close_connection(conn)
    │   iscsit_send_async_msg(REQUEST_LOGOUT)  ← clean signal to initiator
    │   iscsit_stop_tx_thread()
    │   iscsit_stop_rx_thread()
    │   sock_release()               ← TCP FIN/RST sent
    │   iscsit_release_commands_from_conn()
    │       CMD_T_ABORTED | CMD_T_FABRIC_STOP set on all in-flight cmds
    │
    ▼  target_wait_for_sess_cmds(se_sess)
    │   [blocks until sess_cmd_list is empty]
    │
    │   [parallel: in-flight backend I/O completes]
    │   iblock_bio_done() -> target_complete_cmd()
    │     CMD_T_ABORTED set: route to aborted path
    │     CMD_T_FABRIC_STOP set: no response PDU
    │     target_put_sess_cmd() -> kref drops to 0
    │     target_release_cmd_kref()
    │       list_del(&se_cmd->se_cmd_list)
    │       if list_empty: complete(&sess_wait_comp)
    │
    ▼  target_wait_for_sess_cmds() returns
    │   target_put_session(se_sess) ← free session memory
    │   target_put_nacl(acl)        ← free ACL
    │
    [On initiator — parallel timeline]
    TCP FIN/RST -> iscsi_conn_failure(ISCSI_ERR_CONN_FAILED)
    session->state = ISCSI_STATE_FAILED
    iscsid reconnect loop begins:
        Login PDU sent to target
        target: core_tpg_check_initiator_node_acl() returns NULL
        target sends Login Response: ISCSI_STATUS_CLS_INITIATOR_ERR
        iscsid: login failed -> wait and retry (iscsi_session_recovery_timedout)
    [120 seconds later, replacement_timeout fires]
    session->state = ISCSI_STATE_RECOVERY_FAILED
    iscsi_session_chkready() returns DID_TRANSPORT_FAILFAST
    SCSI EH: DID_NO_CONNECT on all held commands
    blk_mq_complete_request() -> dm-multipath multipath_end_io()
    blk_path_error() = true -> fail_path(pgpath)
    atomic_dec(&m->nr_valid_paths)
    [if last path]: nr_valid_paths = 0
    Application I/O: queued (no_path_retry=queue) or -EIO (no_path_retry=fail)
```

---

## Tuning replacement_timeout for faster fencing

The 120-second default `replacement_timeout` means the full fencing sequence takes ~120s per
path. For HA environments this is often too long.

```bash
# On the initiator — reduce replacement_timeout to 10 seconds
# Applied per target node in /etc/iscsi/nodes/<target>/<ip>/default
iscsiadm -m node -T <target_iqn> -p <ip>:<port> \
    --op update -n node.session.timeo.replacement_timeout -v 10

# Verify
iscsiadm -m node -T <target_iqn> -p <ip>:<port> --op show | \
    grep replacement_timeout
```

With `replacement_timeout=10`, fencing completes in ~10s per path instead of ~120s. The tradeoff:
transient network blips that recover in 10-120s will now cause unnecessary path failures.

For a production fencing system, a good balance is `replacement_timeout=30` combined with
`no_path_retry=fail` to get fast error propagation without excessively triggering on flaps.

---

## Key takeaways

- `iscsit_close_session()` is the teardown entry point: sets `sess_tearing_down`, closes
  connections, waits for `sess_cmd_list` to drain, then frees memory.
- `sess_tearing_down = 1` gates new commands: `transport_lookup_cmd_lun()` rejects them.
- `iscsit_close_connection()` optionally sends `ASYNC_MSG_REQUEST_LOGOUT` (clean fencing signal),
  stops TX/RX threads, closes TCP socket, sets `CMD_T_ABORTED | CMD_T_FABRIC_STOP` on all cmds.
- `CMD_T_FABRIC_STOP`: no response PDU sent. `CMD_T_ABORTED`: don't dispatch to backend (if not
  yet submitted); if already in backend, complete with aborted status when backend finishes.
- `target_wait_for_sess_cmds()` blocks on `sess_wait_comp`. Signalled in
  `target_release_cmd_kref()` when `sess_cmd_list` becomes empty after the last command drops
  its reference — guaranteeing memory is freed only after all commands are done.
- `core_tpg_del_initiator_node_acl()` removes ACL first (blocking reconnect), then calls
  `close_session()` for each active session. Order matters: removing ACL first prevents race
  where session closes but initiator reconnects before ACL is removed.
- `replacement_timeout` (default 120s) controls how long the initiator waits before declaring
  the session permanently failed. Reduce it for faster HA failover.

---

## Previous / Next

[Day 24 — configfs: LIO control plane](day24.md) | [Day 26 — NVMe-oF target fabric](day26.md)
