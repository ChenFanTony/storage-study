# Day 19 — iSCSI fabric TX thread and Data-Out

**Week 3**: LIO Target Kernel Code  
**Time**: 1–2 hours  
**Reference**: `drivers/target/iscsi/iscsi_target.c`, `drivers/target/iscsi/iscsi_target_util.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

The target's TX path mirrors the initiator's: drain queues of pending PDUs, send them over TCP,
handle partial sends. But target TX is more elaborate because it generates a wider variety of
PDUs: SCSI Response, Data-In, R2T, NOP-In (keepalive), TMF Response, Async, Reject, Login
Response, Text Response. This day covers the TX thread structure and the per-command flag
machinery that drives it.

---

## TX thread — `drivers/target/iscsi/iscsi_target.c`

```c
/* Simplified — see drivers/target/iscsi/iscsi_target.c. */
int iscsi_target_tx_thread(void *arg)
{
    struct iscsit_conn *conn = arg;
    int ret;

    allow_signal(SIGINT);

    while (!kthread_should_stop()) {
        /*
         * Wait for work: response queue non-empty, immediate queue
         * non-empty, or signal (connection close).
         *
         * The exact wait condition has evolved; in current code the
         * thread waits on conn->queues_wq and exits when shutdown is
         * signalled.
         */
        ret = wait_for_tx_work(conn);
        if (ret < 0)
            break;

        /*
         * Drain queues in priority order.
         */
        for (;;) {
            struct iscsit_cmd *cmd;
            int state;

            /*
             * Higher priority: immediate queue (TMF responses, NOP-In
             * replies, async messages).
             */
            cmd = iscsit_get_cmd_from_immediate_queue(conn, &state);
            if (cmd) {
                iscsit_send_immediate_pdu(conn, cmd, state);
                continue;
            }

            /*
             * Lower priority: response queue (SCSI Response, Data-In, R2T).
             */
            cmd = iscsit_get_cmd_from_response_queue(conn, &state);
            if (cmd) {
                iscsit_send_response_pdu(conn, cmd, state);
                continue;
            }

            break;  /* no work — go back to wait */
        }
    }

    iscsit_take_action_for_connection_exit(conn);
    return 0;
}
```

The two-queue split (immediate vs response) is similar to the initiator's mgmtqueue/cmdqueue
split (day 10). Immediate-queue PDUs jump ahead — keepalives and aborts must not wait behind a
backlog of data.

---

## Command flags — ICF_* and i_state

Two distinct bitfields drive what the TX thread does for each command:

```c
/* drivers/target/iscsi/iscsi_target_core.h */

/*
 * cmd_flags: persistent state of the command (e.g. data flow type).
 */
enum cmd_flags_table {
    ICF_GOT_LAST_DATAOUT             = 0x01, /* F-bit seen on Data-Out */
    ICF_GOT_DATACK_SNACK             = 0x02, /* SNACK pending */
    ICF_NON_IMMEDIATE_UNSOLICITED_DATA = 0x04, /* expect unsolicited Data-Out */
    ICF_OOO_CMDSN                    = 0x10, /* command was out-of-order */
    /* further bits — verify against your kernel version */
};

/*
 * i_state: current TX state — what to send next.
 */
enum cmd_i_state_table {
    ISTATE_NO_STATE                  = 0,
    ISTATE_NEW_CMD                   = 1,
    ISTATE_DEFERRED_CMD              = 2,
    ISTATE_UNSOLICITED_DATA          = 3,
    ISTATE_RECEIVE_DATAOUT           = 4,
    ISTATE_RECEIVE_DATAOUT_RECOVERY  = 5,
    ISTATE_RECEIVED_LAST_DATAOUT     = 6,
    ISTATE_WITHIN_DATAOUT_RECOVERY   = 7,
    ISTATE_IN_CONNECTION_RECOVERY    = 8,
    ISTATE_RECEIVED_TASKMGT          = 9,
    ISTATE_SEND_ASYNCMSG             = 10,
    ISTATE_SENT_ASYNCMSG             = 11,
    ISTATE_SEND_DATAIN               = 12,
    ISTATE_SEND_LAST_DATAIN          = 13,
    ISTATE_SENT_LAST_DATAIN          = 14,
    ISTATE_SEND_LOGOUTRSP            = 15,
    ISTATE_SENT_LOGOUTRSP            = 16,
    ISTATE_SEND_NOPIN                = 17,
    ISTATE_SENT_NOPIN                = 18,
    ISTATE_SEND_REJECT               = 19,
    ISTATE_SENT_REJECT               = 20,
    ISTATE_SEND_R2T                  = 21,
    ISTATE_SENT_R2T                  = 22,
    ISTATE_SEND_R2T_RECOVERY         = 23,
    ISTATE_SENT_R2T_RECOVERY         = 24,
    ISTATE_SEND_LAST_R2T             = 25,
    ISTATE_SEND_LAST_R2T_RECOVERY    = 26,
    ISTATE_SEND_STATUS               = 27,
    ISTATE_SEND_STATUS_RECOVERY      = 28,
    ISTATE_SENT_STATUS               = 29,
    ISTATE_SEND_TASKMGTRSP           = 30,
    ISTATE_SENT_TASKMGTRSP           = 31,
    ISTATE_SEND_TEXTRSP              = 32,
    ISTATE_SENT_TEXTRSP              = 33,
    ISTATE_SEND_NOPIN_WANT_RESPONSE  = 34,
    ISTATE_SENT_NOPIN_WANT_RESPONSE  = 35,
    ISTATE_SEND_NOPIN_NO_RESPONSE    = 36,
    /* exact set varies by kernel version — verify against
     * drivers/target/iscsi/iscsi_target_core.h */
};
```

`cmd_flags` are sticky — set when something happens (e.g. F-bit Data-Out received) and cleared
during cleanup. `i_state` advances as the TX thread processes the command — `SEND_*` → `SENT_*`.

---

## iscsit_queue_status — fabric callback for status

When target core finishes a command and calls `cmd->se_tfo->queue_status()` (day 17), this is
what runs:

```c
/* Simplified. */
static int iscsit_queue_status(struct se_cmd *se_cmd)
{
    struct iscsit_cmd *cmd = container_of(se_cmd, struct iscsit_cmd, se_cmd);
    struct iscsit_conn *conn = cmd->conn;

    cmd->i_state = ISTATE_SEND_STATUS;

    /*
     * Add to response queue. iscsit_add_cmd_to_response_queue() bumps
     * a refcount and links onto conn->response_queue.
     */
    iscsit_add_cmd_to_response_queue(cmd, conn, cmd->i_state);

    /*
     * Wake TX thread.
     */
    wake_up(&conn->queues_wq);

    return 0;
}
```

When the TX thread later runs `iscsit_send_response_pdu()`, it sees `state == ISTATE_SEND_STATUS`
and dispatches to `iscsit_send_response()` which builds and sends the SCSI Response PDU.

---

## iscsit_send_response — SCSI Response PDU

```c
/* Simplified. */
static int iscsit_send_response(struct iscsit_cmd *cmd, struct iscsit_conn *conn)
{
    struct iscsi_scsi_rsp *hdr =
        (struct iscsi_scsi_rsp *)&cmd->pdu[0];
    struct iscsi_session *sess = conn->sess;
    int ret, sense_len = 0;

    memset(hdr, 0, ISCSI_HDR_LEN);

    hdr->opcode      = ISCSI_OP_SCSI_CMD_RSP;
    hdr->flags      |= ISCSI_FLAG_CMD_FINAL;

    /*
     * response field (byte 2) — iSCSI service response:
     *   0x00 = ISCSI_STATUS_CMD_COMPLETED
     *   0x01 = TARGET FAILURE (rare; transport error not seeable as SCSI)
     */
    hdr->response = ISCSI_STATUS_CMD_COMPLETED;

    /*
     * cmd_status field (byte 3) — SCSI status byte:
     *   0x00 GOOD
     *   0x02 CHECK CONDITION
     *   0x18 RESERVATION CONFLICT
     *   0x28 TASK SET FULL
     */
    hdr->cmd_status = cmd->se_cmd.scsi_status;

    /*
     * ITT — echo from Command PDU.
     */
    hdr->itt = cmd->init_task_tag;

    /*
     * StatSN — per-connection sequence number for status PDUs.
     */
    hdr->statsn      = cpu_to_be32(conn->stat_sn++);

    /*
     * ExpCmdSN, MaxCmdSN — flow-control update for initiator.
     */
    hdr->exp_cmdsn   = cpu_to_be32(sess->exp_cmd_sn);
    hdr->max_cmdsn   = cpu_to_be32(sess->max_cmd_sn);

    /*
     * Residual handling for under/overrun.
     */
    if (cmd->se_cmd.se_cmd_flags & SCF_OVERFLOW_BIT) {
        hdr->flags |= ISCSI_FLAG_CMD_OVERFLOW;
        hdr->residual_count = cpu_to_be32(cmd->residual_count);
    } else if (cmd->se_cmd.se_cmd_flags & SCF_UNDERFLOW_BIT) {
        hdr->flags |= ISCSI_FLAG_CMD_UNDERFLOW;
        hdr->residual_count = cpu_to_be32(cmd->residual_count);
    }

    /*
     * If CHECK CONDITION, the data segment carries sense data.
     * Format:
     *   bytes 0..1  = sense length (big-endian u16)
     *   bytes 2..   = the sense buffer (typically 18 bytes for fixed-format)
     */
    if (cmd->se_cmd.scsi_status == SAM_STAT_CHECK_CONDITION) {
        u16 sense_len = cmd->se_cmd.scsi_sense_length;

        put_unaligned_be16(sense_len, cmd->sense_buffer);
        hdr->dlength_be =
            cpu_to_be32(sense_len + 2);
    }

    /*
     * Send via socket (handle partial writes, digest if enabled).
     */
    ret = iscsit_fe_sendpage_sg(...);
    if (ret < 0)
        return ret;

    cmd->i_state = ISTATE_SENT_STATUS;
    return 0;
}
```

`iscsit_fe_sendpage_sg()` (or its modern equivalent using `sock_sendmsg` + iov_iter) walks the
PDU's headers and the optional data segment, sending bytes to the TCP socket. Handles partial
writes by saving state and resuming on the next thread wakeup.

---

## SCSI Response PDU wire format

The 48-byte BHS produced for SCSI Response (opcode 0x21):

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|0|  Opcode(0x21)|F|0|U|O|0|S|R|   Response   |   Status        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|TotalAHSLength |       DataSegmentLength (3 bytes big-endian)  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
+                          Reserved (8 bytes)                   +
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        ITT (4 bytes)                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          SNACK Tag                            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          StatSN                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          ExpCmdSN                             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          MaxCmdSN                             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          ExpDataSN                            |
|         (only meaningful for bidirectional commands)          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                Bidi Read Residual Count                       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       Residual Count                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

`Response` (byte 2) and `Status` (byte 3) are different fields:
- **Response** = iSCSI service response. 0x00 = "Command Completed at Target" (the normal case).
- **Status** = SCSI status byte. 0x00 GOOD, 0x02 CHECK CONDITION, 0x18 RESERVATION CONFLICT, etc.

For RESERVATION CONFLICT: `Response = 0x00`, `Status = 0x18`. The iSCSI level says "we ran the
command"; the SCSI level says "but the target rejected it because of reservation".

---

## R2T sending — iscsit_send_r2t

```c
/* Simplified. */
int iscsit_send_r2ts_to_fe(struct iscsit_cmd *cmd, struct iscsit_conn *conn,
                            bool send_first)
{
    struct iscsi_session *sess = conn->sess;
    u32 max_burst = sess->sess_ops->MaxBurstLength;
    u32 buffer_offset = cmd->next_burst_len;
    u32 xfer_len;

    /*
     * Compute the next burst size. min of:
     *   remaining data
     *   max_burst (negotiated)
     */
    xfer_len = min(cmd->data_length - cmd->next_burst_len, max_burst);

    cmd->r2t_offset    = buffer_offset;
    cmd->r2t_length    = xfer_len;
    cmd->ttt           = ++cmd->conn->ttt;
    cmd->cmd_flags    |= ICF_SENDING_R2T;
    cmd->i_state       = ISTATE_SEND_R2T;

    iscsit_add_cmd_to_response_queue(cmd, conn, cmd->i_state);

    cmd->next_burst_len += xfer_len;
    return 0;
}
```

The R2T (opcode 0x31) BHS carries:
- `ttt` (TargetTransferTag) — must be echoed by initiator in solicited Data-Out PDUs
- `data_offset` — buffer offset to send from
- `data_length` — bytes the initiator may send in response to this R2T
- `r2tsn` — R2T sequence number for this command

Multiple R2Ts may be outstanding (`MaxOutstandingR2T`). For very large writes the target sends
several R2Ts simultaneously; the initiator services them in parallel up to its send window.

---

## NOP-In — keepalives

The target sends NOP-In (opcode 0x20) periodically to detect dead connections. If the initiator
doesn't respond within `nop_in_response_timeout`, `iscsi_target_check_conn_state()` fails the
connection.

```c
/* Simplified. */
void iscsit_handle_nopin_response_timeout(struct timer_list *t)
{
    struct iscsit_conn *conn = from_timer(conn, t, nopin_response_timer);

    if (conn->nopin_response_timer_flags & ISCSI_TF_RUNNING) {
        pr_err("Did not receive NopIn Response within %u sec — failing conn\n",
               conn->sess->sess_ops->NopInTimeout);
        /*
         * iscsit_cause_connection_reinstatement() schedules conn cleanup.
         */
        iscsit_cause_connection_reinstatement(conn, 0);
    }
}
```

This is the analog of the initiator's NOP-Out timeout. Both sides use the same mechanism — a
keepalive PDU with WantResponse, plus a timer that catches the missing reply.

---

## Async PDU sending

```c
/* Simplified. */
int iscsit_send_async_msg(struct iscsit_conn *conn, u16 cid, u8 async_event,
                            u8 async_vcode)
{
    struct iscsi_async *hdr;
    struct iscsit_cmd *cmd;

    cmd = iscsit_allocate_cmd(conn, TASK_INTERRUPTIBLE);
    if (!cmd)
        return -1;

    cmd->iscsi_opcode = ISCSI_OP_ASYNC_EVENT;
    cmd->i_state      = ISTATE_SEND_ASYNCMSG;

    hdr = (struct iscsi_async *)&cmd->pdu[0];
    memset(hdr, 0, ISCSI_HDR_LEN);

    hdr->opcode       = ISCSI_OP_ASYNC_EVENT;
    hdr->flags        = ISCSI_FLAG_CMD_FINAL;
    hdr->itt          = RESERVED_ITT;  /* 0xffffffff for unsolicited */
    hdr->async_event  = async_event;
    hdr->async_vcode  = async_vcode;
    hdr->statsn       = cpu_to_be32(conn->stat_sn);
    hdr->exp_cmdsn    = cpu_to_be32(conn->sess->exp_cmd_sn);
    hdr->max_cmdsn    = cpu_to_be32(conn->sess->max_cmd_sn);

    /* queue to immediate queue (priority over response queue) */
    iscsit_add_cmd_to_immediate_queue(cmd, conn, ISTATE_SEND_ASYNCMSG);
    return 0;
}
```

For session-drop fencing (day 25), an admin-triggered call to `iscsit_send_async_msg(conn,
conn->cid, ISCSI_ASYNC_MSG_REQUEST_LOGOUT, 0)` produces a clean shutdown. The initiator's RX
thread receives this Async PDU (day 11) and triggers `iscsi_conn_failure()` — recovery starts
gracefully without TCP RST.

---

## Key takeaways

- Target uses two TX kthreads per connection: an RX thread (day 18) and a TX thread.
- TX queues split: `immediate_queue` (NOP-In, TMF response, Async, Logout response) drains first,
  then `response_queue` (SCSI Response, Data-In, R2T).
- Each command has `cmd_flags` (sticky state like ICF_GOT_LAST_DATAOUT) and `i_state`
  (current TX action: SEND_STATUS, SEND_DATAIN, SEND_R2T, etc.).
- SCSI Response PDU has TWO status fields:
  - `response` byte: iSCSI service response (0x00 = command completed)
  - `status` byte: SCSI status (0x00 GOOD, 0x18 RESERVATION CONFLICT, etc.)
- Sense data (CHECK CONDITION) is in the data segment: 2-byte length + sense buffer.
- R2T (opcode 0x31) carries `ttt` (must be echoed in Data-Out), `data_offset`, `data_length`.
- NOP-In keepalives detect dead connections; missed response triggers connection
  reinstatement.
- Async PDU `REQUEST_LOGOUT` (event 0x01) is the clean session-drop fencing signal.

---

## Previous / Next

[Day 18 — iSCSI fabric RX thread](day18.md) | [Day 20 — LIO Persistent Reservations](day20.md)
