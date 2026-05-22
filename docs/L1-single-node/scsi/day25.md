# Day 25 — session teardown path

**Week 4**: Advanced Topics  
**Time**: 1–2 hours  
**Reference**: `drivers/target/iscsi/iscsi_target.c`, `drivers/target/target_core_transport.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

Session teardown is the operation triggered by ACL removal (day 24), TPG disable, or unmounting
the target stack. It must:

1. Stop accepting new commands on the session.
2. Drain in-flight commands cleanly (let backend I/O finish, send any pending responses).
3. Close the TCP socket(s).
4. Free per-session memory.

Doing this without races against in-flight TMFs, completions, and configfs operations is what
makes the session-drop-based fencing approach reliable. The session must be GONE — not "going
away" — by the time the configfs `rmdir` returns, otherwise an admin script that reads
`/sys/.../sessions` after fencing could see stale state.

---

## Entry points

```
ACL rmdir → core_tpg_del_initiator_node_acl()
    └── for each session: iscsit_close_session(sess, force=1)

TPG disable (force=1) → iscsit_tpg_disable_portal_group()
    └── for each session in TPG: iscsit_close_session()

Connection failure (RX/TX error)
    └── iscsit_take_action_for_connection_exit()
        └── iscsit_close_connection()
            └── if last connection: iscsit_close_session()

Logout PDU received from initiator
    └── iscsit_logout_post_handler() → iscsit_close_session()
```

All paths converge on `iscsit_close_session()` for full session teardown, or
`iscsit_close_connection()` for per-connection teardown when MC/S has more connections.

---

## iscsit_close_session — `drivers/target/iscsi/iscsi_target.c`

```c
/* Simplified — see drivers/target/iscsi/iscsi_target.c. */
void iscsit_close_session(struct iscsi_session *sess)
{
    struct iscsi_portal_group *tpg = sess->tpg;
    struct se_session *se_sess = sess->se_sess;
    struct iscsit_conn *conn, *tmp;

    /*
     * Step 1: mark session as terminating.
     * Block new logins on additional connections (MC/S).
     */
    spin_lock_bh(&sess->session_lock);
    sess->session_state = TARG_SESS_STATE_LOGGED_IN;
    sess->session_state = TARG_SESS_STATE_FREE;
    spin_unlock_bh(&sess->session_lock);

    /*
     * Step 2: close all connections in this session. In MC/S=1 (the
     * common case) there's just sess->leadconn; with MC/S>1 the kernel
     * walks sess->sess_conn_list. Connection close stops the RX/TX
     * threads and closes sockets.
     */
    list_for_each_entry_safe(conn, tmp, &sess->sess_conn_list, conn_list) {
        iscsit_cause_connection_reinstatement(conn, 1 /* sleep */);
        /* This signals the RX kthread to exit. The TX kthread sees
         * the wait_event condition flip and also exits. */
    }

    /*
     * Step 3: wait for all in-flight commands to release.
     * target_wait_for_sess_cmds() walks se_sess->sess_cmd_list and
     * blocks until every cmd's kref drops to zero (commands completing
     * normally, or being aborted by TMR).
     */
    target_wait_for_sess_cmds(se_sess);

    /*
     * Step 4: free per-session resources.
     */
    iscsit_release_commands_from_conn(NULL, sess);
    transport_free_session(se_sess);
    kfree(sess);
}
```

---

## iscsit_cause_connection_reinstatement — kicking the threads out

```c
/* Simplified. */
void iscsit_cause_connection_reinstatement(struct iscsit_conn *conn, int sleep)
{
    /* signal RX/TX threads */
    spin_lock_bh(&conn->state_lock);
    conn->conn_state = TARG_CONN_STATE_IN_LOGOUT;
    spin_unlock_bh(&conn->state_lock);

    /*
     * Force socket-level errors so RX thread's recv returns -EINTR
     * and TX thread's send returns -EPIPE.
     * sk_state_change → wakes any blocked socket calls.
     */
    if (conn->sock) {
        struct sock *sk = conn->sock->sk;

        sk->sk_err = ECONNRESET;
        sk->sk_state_change(sk);
    }

    /*
     * If sleep=1, wait for both threads to exit.
     */
    if (sleep) {
        if (conn->tx_thread)
            kthread_stop(conn->tx_thread);
        if (conn->rx_thread)
            kthread_stop(conn->rx_thread);
    }
}
```

The forced socket error ensures the threads wake up promptly. Without it, an idle RX thread
blocked in `tcp_read_sock()` would never notice that the session is being torn down.

---

## iscsit_release_commands_from_conn — flagging in-flight commands

```c
/* Simplified — see drivers/target/iscsi/iscsi_target.c. */
void iscsit_release_commands_from_conn(struct iscsit_conn *conn,
                                          struct iscsi_session *sess)
{
    struct iscsit_cmd *cmd, *tmp;
    struct se_session *se_sess = sess->se_sess;
    struct se_cmd *se_cmd;

    /*
     * Walk the session's in-flight commands. For each:
     *   1. Take a kref (so cmd can't free under us).
     *   2. Set CMD_T_FABRIC_STOP — tells target core "fabric is going,
     *      don't send any more responses for this command."
     *   3. Drop kref.
     *
     * The actual completion drainage happens via
     * target_wait_for_sess_cmds() called next.
     */
    spin_lock(&se_sess->sess_cmd_lock);
    list_for_each_entry_safe(se_cmd, tmp, &se_sess->sess_cmd_list,
                              se_cmd_list) {
        if (!target_get_sess_cmd_kref(se_cmd))
            continue;

        spin_lock(&se_cmd->t_state_lock);
        se_cmd->transport_state |= CMD_T_FABRIC_STOP;
        spin_unlock(&se_cmd->t_state_lock);

        spin_unlock(&se_sess->sess_cmd_lock);

        /*
         * Wake any backend thread waiting for fabric to do something
         * (e.g., write_pending data delivery).
         */
        complete(&se_cmd->t_transport_stop_comp);

        target_put_sess_cmd(se_cmd);
        spin_lock(&se_sess->sess_cmd_lock);
    }
    spin_unlock(&se_sess->sess_cmd_lock);
}
```

`CMD_T_FABRIC_STOP` (added around 2017) is the marker that distinguishes "fabric is going away,
let in-flight I/O drain naturally" from `CMD_T_ABORTED` (per-command TMF abort). Backend
completion paths check this flag and skip fabric callbacks like `queue_data_in` /
`queue_status` — there's no point sending PDUs on a closed socket.

---

## target_wait_for_sess_cmds — the drain

```c
/* Simplified — see drivers/target/target_core_transport.c. */
void target_wait_for_sess_cmds(struct se_session *se_sess)
{
    struct se_cmd *se_cmd, *tmp_cmd;
    bool rc = false;
    unsigned long flags;

    spin_lock_irqsave(&se_sess->sess_cmd_lock, flags);
    list_for_each_entry_safe(se_cmd, tmp_cmd,
                              &se_sess->sess_cmd_list, se_cmd_list) {
        list_del_init(&se_cmd->se_cmd_list);
        spin_unlock_irqrestore(&se_sess->sess_cmd_lock, flags);

        /*
         * Wait for this command's kref to drop to zero.
         * Backend completion / TMR processing decrements the kref
         * (via target_release_cmd_kref) — eventually it hits zero.
         *
         * For commands stuck in backend (e.g., a long-running write to
         * a slow-responding iblock device), this can take a while.
         * The original wait used a 20-second warning loop; modern code
         * uses wait_event() on a session-wide predicate, with a periodic
         * pr_warn loop if drainage takes too long.
         */
        rc = wait_event_timeout(se_cmd->free_wait,
                                  kref_read(&se_cmd->cmd_kref) == 0,
                                  msecs_to_jiffies(20 * 1000));
        if (!rc)
            pr_warn("se_cmd %p still has refs after 20s\n", se_cmd);

        spin_lock_irqsave(&se_sess->sess_cmd_lock, flags);
    }
    spin_unlock_irqrestore(&se_sess->sess_cmd_lock, flags);
}
```

This is the key drain function. By the time `target_wait_for_sess_cmds()` returns, every command
that was on `sess_cmd_list` has been freed via `target_release_cmd_kref()`. The session is
quiescent.

---

## Connection close — sockets and threads

```c
/* Simplified. */
int iscsit_close_connection(struct iscsit_conn *conn)
{
    /* stop RX thread */
    if (conn->rx_thread)
        kthread_stop(conn->rx_thread);
    /* stop TX thread */
    if (conn->tx_thread)
        kthread_stop(conn->tx_thread);

    /*
     * Release the socket. sock_release calls sock->ops->release which
     * for TCP issues either a graceful close (FIN) or an abrupt close
     * (RST) depending on socket state — if the send buffer has data
     * outstanding and SO_LINGER is not set, it tends to FIN; under
     * load with unsent data it may RST. The choice depends on the
     * exact socket state and configuration.
     */
    if (conn->sock) {
        sock_release(conn->sock);
        conn->sock = NULL;
    }

    /*
     * Drop conn from session's connection list.
     */
    spin_lock_bh(&conn->sess->conn_lock);
    list_del(&conn->conn_list);
    conn->sess->nconn--;
    spin_unlock_bh(&conn->sess->conn_lock);

    /* Free per-conn buffers, login state, etc. */
    iscsit_free_conn(conn);

    return 0;
}
```

The TCP RST vs FIN distinction matters for the initiator's experience:

- **FIN (graceful close)**: initiator's RX gets `read() = 0`, treated as clean disconnect.
  `iscsi_conn_failure(ISCSI_ERR_CONN_FAILED)` runs. Session enters recovery.
- **RST (abrupt close)**: initiator's RX gets `-ECONNRESET`. Same `iscsi_conn_failure()` runs,
  same recovery.

In practice the path is nearly identical from the initiator's perspective. What matters more is
whether the target sent an Async PDU `REQUEST_LOGOUT` (day 19) BEFORE closing the socket —
that's the difference between "fenced cleanly" and "session just dropped".

---

## The clean fencing protocol (target-driven)

A well-behaved fencing implementation on the target side does this:

```
1. Cluster decides node A is fenced.
2. Target admin runs:
     a. iscsit_send_async_msg(conn, ASYNC_MSG_REQUEST_LOGOUT)
        Initiator sees the Async PDU, calls iscsi_conn_failure() to
        start clean session recovery. open-iscsi userspace would attempt
        to log back in, but ACL is gone, login rejected.
     b. (after small delay)
        rmdir /sys/.../acls/iqn.client.A
        Forcibly closes session if still up. Future logins from this
        IQN are rejected at LoginRequest with status class 0x02.
3. Initiator's recovery_tmo (replacement_timeout, default 120s from
   open-iscsi userspace, pushed to kernel via sysfs) expires.
4. ISCSI_STATE_RECOVERY_FAILED → all I/O fails with
   DID_TRANSPORT_FAILFAST → BLK_STS_TRANSPORT.
5. dm-multipath fail_path() per path → nr_valid_paths reaches 0.
6. With no_path_retry=queue: bios queue in m->queued_bios → application
   hangs forever (the desired fenced state).
   Without queue_if_no_path: bios fail with -EIO → application sees
   immediate error (hot-fence semantics).
```

The Async PDU step is courtesy. Without it, the initiator's first hint of trouble is the TCP
disconnect — same end result, just less friendly.

---

## Why MC/S complicates the picture

Multiple Connections per Session lets one iSCSI session span multiple TCP connections — useful
for bandwidth aggregation. For session teardown:

- `iscsit_close_connection()` only closes one connection.
- If other connections still exist, the session stays alive (degraded) — initiator may keep
  using it via the surviving connection.
- For fencing, you must close ALL connections OR force `iscsit_close_session()` which iterates
  the whole list.

`rmdir` of an ACL takes the second path: it iterates all sessions of all connections.

In practice, MC/S is rarely deployed (most iSCSI uses dm-multipath instead, with one connection
per session per path). The kernel supports it but most production setups have `nconn=1`.

---

## Race analysis: rmdir vs in-flight TMF

Consider:
- Thread A: configfs `rmdir` of node A's ACL.
- Thread B: TMF (LUN_RESET) sent by node A still in flight.

```
Time   Thread A (rmdir)                       Thread B (TMR work)
─────  ──────────────────────                ──────────────────────
T0     core_tpg_del_initiator_node_acl()     in core_tmr_lun_reset()
T1     walks sess_conn_list                  walking sess_cmd_list
T2     finds active session                   takes krefs on commands
T3     starts iscsit_close_session()
T4                                            calls target_handle_aborted_cmd
T5     calls iscsit_release_commands_from_conn
T6                                            wait_for_completion_timeout()
T7     target_wait_for_sess_cmds()
       (waits for kref to drop)
T8                                            target_put_sess_cmd() final
T9     proceeds, frees session
```

The kref-during-walk pattern in TMR (day 17, day 22) is what saves us. Even though `rmdir` is
trying to free everything, the TMR has krefs that prevent free. Once TMR completes its drain,
those krefs drop, and `rmdir` can proceed.

`target_tmr_wq` being `__WQ_ORDERED` also helps — at most one TMR is in flight per device, so
Thread B's wait above is a finite operation.

---

## Sysfs visibility during teardown

While teardown is in progress, other userspace tools may read
`/sys/kernel/config/target/iscsi/.../sessions` or similar. The configfs node hasn't been removed
yet; `rmdir` is blocked in the kernel. Reading the session info would block on the same lock.

For administration scripts: never assume `rmdir` returns instantly. With slow backends or many
in-flight commands, it can take seconds. The 20-second warning in `target_wait_for_sess_cmds()`
gives an upper-bound expectation; in practice well-tuned setups complete in < 1s.

---

## Key takeaways

- Session teardown enters via `iscsit_close_session()`, called from ACL removal, TPG disable,
  Logout PDU, or connection failure.
- `iscsit_cause_connection_reinstatement()` forces socket errors to wake the RX/TX threads,
  then `kthread_stop()` waits for them to exit.
- `iscsit_release_commands_from_conn()` sets `CMD_T_FABRIC_STOP` on each in-flight command —
  signals backend "don't bother sending fabric responses for these".
- `target_wait_for_sess_cmds()` is the kref-based drain. Returns when every command has been
  released via `target_release_cmd_kref()`. Has a 20-second warning loop for stuck commands.
- TCP close may produce FIN or RST depending on socket buffer state and configuration. Both
  trigger `iscsi_conn_failure()` on the initiator — same recovery path.
- The clean target-side fencing protocol: send `ASYNC_MSG_REQUEST_LOGOUT`, then `rmdir` ACL.
- MC/S complicates teardown — must close ALL connections; rare in practice (most setups use
  dm-multipath instead).
- The kref-during-walk pattern in TMR + `target_tmr_wq` ordering prevents races between
  in-flight TMFs and configfs teardown.
- `replacement_timeout` (default 120s, set from open-iscsi userspace via sysfs) is the
  initiator-side bound on how long held I/O waits before failing with
  `DID_TRANSPORT_FAILFAST`.

---

## Previous / Next

[Day 24 — configfs control plane](day24.md) | [Day 26 — NVMe-oF target fabric comparison](day26.md)
