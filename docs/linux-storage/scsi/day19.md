# Day 19 — iSCSI fabric TX thread and Data-Out handling

**Week 3**: LIO Target Core — Fabric to Backend
**Time**: 1–2 hours
**Reference**: `drivers/target/iscsi/iscsi_target.c`, `include/target/iscsi/iscsi_target_core.h`

---

## Overview

The iSCSI fabric TX side is a dedicated kthread per connection that drains a response queue and
sends PDUs over the socket. It handles SCSI Response PDUs, Data-In PDUs (for reads), R2T PDUs
(for solicited writes), NOP-In, TMF Response, and Async PDUs. Today also covers the complete
`cmd_flags_table` and `cmd_i_state_table` enums — the internal state machine that tracks every
command from arrival to response.

---

## iscsi_target_tx_thread — `drivers/target/iscsi/iscsi_target.c`

```c
static int iscsi_target_tx_thread(void *arg)
{
    struct iscsi_conn *conn = arg;
    bool conn_freed = false;

    /*
     * TX kthread priority: elevated (nice = -1) to ensure responses
     * go out quickly even under load.
     */
    allow_signal(SIGINT);

    while (!kthread_should_stop()) {
        /*
         * Wait for work. iscsit_add_cmd_to_response_queue() adds
         * an iscsit_cmd to conn->response_queue and wakes this thread.
         */
        wait_event_interruptible(conn->queues_wq,
            !iscsit_conn_all_queues_empty(conn) || kthread_should_stop());

        if (kthread_should_stop())
            break;

        /*
         * Process the response queue.
         * iscsit_get_response_pdu_list() retrieves PDUs to send.
         */
check_queue:
        if (list_empty(&conn->conn_cmd_list)) {
            /*
             * conn_cmd_list: commands with responses ready.
             * Check conn->response_queue for management PDUs too.
             */
            if (!list_empty(&conn->response_queue))
                goto get_response;
            continue;
        }

        list_for_each_entry_safe(cmd, cmd_tmp,
                                  &conn->conn_cmd_list, i_conn_node) {
            /*
             * Dispatch by cmd->i_state.
             * Each state corresponds to a specific PDU type to send.
             */
            switch (cmd->i_state) {
            case ISTATE_SEND_DATAIN:
                /* send Data-In PDU (read data to initiator) */
                rc = iscsit_send_datain(cmd, conn);
                break;
            case ISTATE_SEND_STATUS:
                /* send SCSI Response PDU */
                rc = iscsit_send_response(cmd, conn);
                break;
            case ISTATE_SEND_STATUS_RECOVERY:
                rc = iscsit_send_recovery_response(cmd, conn);
                break;
            case ISTATE_SEND_LOGOUTRSP:
                rc = iscsit_send_logout_response(cmd, conn);
                break;
            case ISTATE_SEND_ASYNCMSG:
                /* send Async PDU — used for fencing (day 25) */
                rc = iscsit_send_async_msg(cmd, conn);
                break;
            case ISTATE_SEND_NOPIN:
                rc = iscsit_send_nopin(cmd, conn);
                break;
            case ISTATE_SEND_REJECT:
                rc = iscsit_send_reject(cmd, conn);
                break;
            case ISTATE_SEND_TASKMGTRSP:
                rc = iscsit_send_task_mgt_rsp(cmd, conn);
                break;
            case ISTATE_SEND_R2T:
                /* send R2T — grant permission to send write data */
                rc = iscsit_send_r2t(cmd, conn);
                break;
            }

            if (rc < 0) {
                iscsit_cause_connection_reinstatement(conn, 0);
                goto transport_err;
            }
        }
get_response:
        /* also drain management response queue (NOP-In, etc.) */
        if (!iscsit_send_conn_mgmt_response(conn))
            goto check_queue;
    }

transport_err:
    iscsit_take_action_for_connection_exit(conn, &conn_freed);
    return 0;
}
```

---

## iscsit_send_response — SCSI Response PDU — `drivers/target/iscsi/iscsi_target.c`

```c
static int iscsit_send_response(struct iscsit_cmd *cmd,
                                 struct iscsi_conn *conn)
{
    struct iscsi_cmd_rsp *hdr;
    int iov_count = 0;
    u32 padding = 0, pdu_length = 0;

    hdr = (struct iscsi_cmd_rsp *)cmd->pdu;
    memset(hdr, 0, sizeof(*hdr));

    /*
     * Build the SCSI Response PDU BHS (48 bytes):
     *
     * Byte 0: opcode = 0x21 (ISCSI_OP_SCSI_CMD_RSP)
     * Byte 1: flags (o=overflow, u=underflow, O,U residual flags)
     * Byte 2: response = 0x00 (ISCSI_STATUS_CMD_COMPLETED)
     * Byte 3: cmd_status = se_cmd->scsi_status
     *           0x00 = GOOD
     *           0x02 = CHECK CONDITION
     *           0x18 = RESERVATION CONFLICT
     *           0x28 = TASK SET FULL
     * Bytes 4-7: DataSegmentLength (sense data length, 0 for no sense)
     * Bytes 8-11: ITT (Initiator Task Tag — copied from Command PDU)
     * Bytes 12-15: SNACK Tag (0 unless SNACK requested)
     * Bytes 16-19: StatSN (connection-level sequence number)
     * Bytes 20-23: ExpCmdSN (next CmdSN we expect from initiator)
     * Bytes 24-27: MaxCmdSN (CmdSN window upper bound)
     * Bytes 28-31: ExpDataSN (for bidirectional, otherwise 0)
     * Bytes 32-35: BidiResidualCount
     * Bytes 36-39: ResidualCount
     */
    hdr->opcode    = ISCSI_OP_SCSI_CMD_RSP;
    hdr->flags     = ISCSI_FLAG_CMD_FINAL;
    hdr->response  = ISCSI_STATUS_CMD_COMPLETED;
    hdr->cmd_status = cmd->se_cmd.scsi_status;  /* 0x00, 0x02, 0x18, etc. */

    /* ITT: echo back the Initiator Task Tag from the Command PDU */
    hdr->itt = cmd->init_task_tag;

    /* StatSN: increment per connection for each response sent */
    cmd->stat_sn = conn->stat_sn++;
    hdr->statsn  = cpu_to_be32(cmd->stat_sn);

    /* ExpCmdSN, MaxCmdSN: update the initiator's CmdSN window */
    iscsit_increment_maxcmdsn(cmd, conn->sess);
    hdr->exp_cmdsn = cpu_to_be32(conn->sess->exp_cmd_sn);
    hdr->max_cmdsn = cpu_to_be32((u32) atomic_read(&conn->sess->max_cmd_sn));

    /*
     * Sense data: present only for CHECK CONDITION (scsi_status = 0x02).
     * Format in data segment:
     *   2 bytes: sense data length (big-endian)
     *   N bytes: actual sense data from se_cmd->sense_buffer
     *
     * For RESERVATION CONFLICT (0x18): no sense data, DataSegmentLength = 0.
     * For GOOD (0x00): no sense data.
     */
    if (hdr->cmd_status == SAM_STAT_CHECK_CONDITION) {
        /* 2-byte sense length prefix + sense data */
        u32 sense_length = cmd->se_cmd.scsi_sense_length;

        /* write 2-byte BE length into data segment */
        put_unaligned_be16(sense_length, cmd->sense_iovecs[0].iov_base);
        cmd->sense_iovecs[0].iov_len  = 2;
        cmd->sense_iovecs[1].iov_base = cmd->se_cmd.sense_buffer;
        cmd->sense_iovecs[1].iov_len  = sense_length;

        pdu_length = 2 + sense_length;  /* DataSegmentLength */
        iov_count  = 2;

        /* padding to 4-byte boundary */
        padding = ((-pdu_length) & 3);
    }

    hdr->dlength[0] = (pdu_length >> 16) & 0xFF;
    hdr->dlength[1] = (pdu_length >>  8) & 0xFF;
    hdr->dlength[2] =  pdu_length        & 0xFF;

    /* optional: add HeaderDigest CRC32C after BHS */
    if (conn->conn_ops->HeaderDigest) {
        u32 crc = iscsit_do_crypto_hash_buf(conn->conn_tx_hash,
                                             (u8 *)hdr, ISCSI_HDR_LEN, 0, NULL);
        cmd->conn_digests[0] = cpu_to_be32(crc);
        iov_count++;
    }

    /* send over socket: kernel_sendmsg(conn->sock, ...) */
    rc = iscsit_send_tx_data(cmd, conn, 1);
    if (rc < 0) {
        pr_err("iscsit_send_tx_data() failed: %d\n", rc);
        return rc;
    }

    /* cleanup: remove from response queue, release se_cmd reference */
    iscsit_ack_response(cmd);
    return 0;
}
```

---

## cmd_flags_table — `include/target/iscsi/iscsi_target_core.h`

```c
enum cmd_flags_table {
    /*
     * Set in iscsit_check_dataout_payload() when:
     *   F-bit = 1 in the last Data-Out PDU AND write_data_done == data_length.
     * Guards the call to target_execute_cmd():
     *   target_execute_cmd() is ONLY called when this flag is set.
     * Also checked by ERL2 TASK_REASSIGN recovery to know if data
     * collection is complete.
     */
    ICF_GOT_LAST_DATAOUT          = 0x00000001,

    /*
     * Set when the DataACK SNACK is received (ERL > 0 only).
     * Indicates initiator has acknowledged data sent.
     */
    ICF_GOT_DATACK_SNACK          = 0x00000002,

    /*
     * Set when the Command PDU contained a data segment (ImmediateData).
     * Used to track whether immediate data was processed.
     */
    ICF_NON_IMMEDIATE_UNSOLICITED_DATA = 0x00000004,

    /*
     * Set when the last R2T has been sent for a solicited write.
     * No more R2T PDUs will be sent after this.
     */
    ICF_SENT_LAST_R2T             = 0x00000008,

    /*
     * Set when the command arrived with CmdSN higher than expected
     * (out-of-order CmdSN). The command is held on ooo_cmdsn_list.
     * Guards target_execute_cmd(): if ICF_OOO_CMDSN is set when
     * ICF_GOT_LAST_DATAOUT is also set, execution is deferred until
     * iscsit_execute_cmd() re-drives the command in CmdSN order.
     */
    ICF_OOO_CMDSN                 = 0x00000010,

    /* Immediate Data was present in the SCSI Command PDU */
    ICF_IMMEDIATE_DATA            = 0x00000040,

    /* Free the iscsit_cmd in iscsit_check_stop_free() */
    ICF_FREE_CMD_ON_STF           = 0x00000080,
};
```

---

## cmd_i_state_table — `include/target/iscsi/iscsi_target_core.h`

```c
enum cmd_i_state_table {
    /* initial state after iscsit_allocate_cmd() */
    ISTATE_NEW_CMD                 = 0,

    /* SCSI command received, waiting for write data or ready to execute */
    ISTATE_RECEIVE_DATAOUT         = 1,

    /* all write data received — ready to hand to target core */
    ISTATE_RECEIVED_LAST_DATAOUT   = 2,

    /* command being processed by target core / backend */
    ISTATE_PROCESSING              = 3,

    /* read data ready to send — TX thread will send Data-In PDUs */
    ISTATE_SEND_DATAIN             = 4,

    /* SCSI Response PDU ready to send (write/no-data completed) */
    ISTATE_SEND_STATUS             = 5,

    /* SCSI Response PDU for error recovery */
    ISTATE_SEND_STATUS_RECOVERY    = 6,

    /* R2T PDU ready to send (solicited write, grant more data) */
    ISTATE_SEND_R2T                = 7,

    /* all R2T PDUs sent for this command */
    ISTATE_SENT_LAST_R2T           = 8,

    /* NOP-In PDU ready to send (keepalive response) */
    ISTATE_SEND_NOPIN              = 9,

    /* TMF Response PDU ready to send */
    ISTATE_SEND_TASKMGTRSP         = 10,

    /* Logout Response PDU ready to send */
    ISTATE_SEND_LOGOUTRSP          = 11,

    /* Async PDU ready to send (fencing, parameter negotiation) */
    ISTATE_SEND_ASYNCMSG           = 12,

    /* Reject PDU ready to send (protocol error) */
    ISTATE_SEND_REJECT             = 13,

    /* command fully completed and freed */
    ISTATE_COMPLETED               = 14,

    /* TMF cleanup state */
    ISTATE_REMOVE                  = 15,
};
```

The TX kthread dispatches on `cmd->i_state`. The state is set by various parts of the code:
- `target_complete_ok_work()` sets `ISTATE_SEND_DATAIN` (read) or `ISTATE_SEND_STATUS` (write)
  via `iscsit_queue_data_in()` / `iscsit_queue_status()`
- `iscsit_request_r2t()` sets `ISTATE_SEND_R2T`
- `iscsit_handle_task_mgt_cmd()` sets `ISTATE_SEND_TASKMGTRSP` after TMF completes
- `iscsit_send_async_msg()` sets `ISTATE_SEND_ASYNCMSG` for fencing

---

## iscsit_queue_status — fabric callback from target_core

```c
/*
 * Called by target_complete_ok_work() via:
 *   cmd->se_tfo->queue_status(cmd)
 * = iscsit_queue_status() for iSCSI fabric.
 *
 * This transitions the command to ISTATE_SEND_STATUS and adds it to
 * conn->conn_cmd_list for the TX thread to process.
 */
int iscsit_queue_status(struct se_cmd *se_cmd)
{
    struct iscsit_cmd *cmd = container_of(se_cmd, struct iscsit_cmd, se_cmd);

    cmd->i_state = ISTATE_SEND_STATUS;
    iscsit_add_cmd_to_conn_list(cmd, cmd->conn);

    wake_up(&cmd->conn->queues_wq);  /* wake TX thread */
    return 0;
}
```

`iscsit_add_cmd_to_conn_list()` adds the cmd to `conn->conn_cmd_list` under the response lock.
The TX kthread wakes, picks up the cmd, sees `i_state = ISTATE_SEND_STATUS`, and calls
`iscsit_send_response()`.

---

## iscsit_send_datain — Data-In PDU for reads

```c
static int iscsit_send_datain(struct iscsit_cmd *cmd,
                               struct iscsi_conn *conn)
{
    struct iscsi_datain_req *dr;
    struct iscsi_datain datain;
    int eodr = 0, ret, iov_ret, iov_count = 0;

    /*
     * Get the next Data-In PDU descriptor from cmd's datain_req list.
     * Each descriptor specifies: offset, length, DataSN, flags.
     */
    dr = iscsit_get_datain_req(cmd);
    if (!dr)
        return -1;

    memset(&datain, 0, sizeof(struct iscsi_datain));
    datain.length = dr->length;
    datain.offset = dr->offset;

    /*
     * iscsit_build_datain_pdu() fills the 48-byte Data-In BHS:
     *   opcode = 0x25 (ISCSI_OP_SCSI_DATA_IN)
     *   F-bit: set on last PDU
     *   A-bit: acknowledge requested (if DataACK SNACK enabled)
     *   S-bit: status piggybacked (if this is the last PDU)
     *   DataSN: per-command sequence number
     *   BufferOffset: byte offset in data buffer
     *   ResidualCount: if S-bit set
     */
    iscsit_build_datain_pdu(cmd, conn, &datain, dr, &eodr);

    /*
     * Map SGL entries to iovec for kernel_sendmsg().
     * The actual read data pages are in cmd->se_cmd.t_data_sg.
     * No copying — kernel_sendmsg() DMA-reads directly from the pages.
     */
    iov_ret = iscsit_map_iovec(cmd, cmd->iov_data, datain.offset,
                                datain.length);

    /* send BHS + data segment over socket */
    ret = iscsit_send_tx_data(cmd, conn, 1);

    if (eodr) {
        /*
         * Last Data-In PDU sent.
         * If S-bit was set: status already piggybacked.
         *   → no separate SCSI Response PDU needed.
         * If S-bit not set: transition to ISTATE_SEND_STATUS.
         *   → TX thread will send SCSI Response PDU next.
         */
        if (datain.flags & ISCSI_FLAG_DATA_STATUS) {
            /* status was piggybacked — command complete */
            iscsit_ack_response(cmd);
        } else {
            cmd->i_state = ISTATE_SEND_STATUS;
            iscsit_add_cmd_to_conn_list(cmd, conn);
        }
    }

    return ret;
}
```

---

## iscsit_send_async_msg — Async PDU for fencing

```c
/*
 * Send an Async PDU to the initiator.
 * Used in the session-drop fencing approach:
 *   iscsit_send_async_msg(conn, ISCSI_ASYNC_MSG_REQUEST_LOGOUT, ...)
 *
 * AsyncEvent types (RFC 7143 section 11.8):
 *   0x00 = SCSI Async event (UA available)
 *   0x01 = Logout requested (target wants initiator to logout)
 *   0x02 = Drop connection (target will drop this connection)
 *   0x03 = Drop all connections (target will drop session)
 *   0x04 = Renegotiate parameters
 */
int iscsit_send_async_msg(struct iscsi_conn *conn,
                           u16 cid,
                           u8 async_event,
                           u8 async_vcode)
{
    struct iscsit_cmd *cmd;
    struct iscsi_async *hdr;

    cmd = iscsit_allocate_mgmt_cmd(conn);
    if (!cmd)
        return -ENOMEM;

    hdr = (struct iscsi_async *)cmd->pdu;
    memset(hdr, 0, sizeof(*hdr));

    hdr->opcode      = ISCSI_OP_ASYNC_EVENT;
    hdr->flags       = ISCSI_FLAG_CMD_FINAL;
    hdr->async_event = async_event;  /* e.g. ISCSI_ASYNC_MSG_REQUEST_LOGOUT */
    hdr->async_vcode = async_vcode;
    hdr->statsn      = cpu_to_be32(conn->stat_sn++);
    hdr->exp_cmdsn   = cpu_to_be32(conn->sess->exp_cmd_sn);
    hdr->max_cmdsn   = cpu_to_be32(
        (u32) atomic_read(&conn->sess->max_cmd_sn));

    /*
     * For ISCSI_ASYNC_MSG_REQUEST_LOGOUT:
     *   Parameter1 (param1) = Time2Wait: seconds before initiator may retry
     *   Parameter2 (param2) = Time2Retain: seconds during which initiator
     *                         may resume connection before data is lost
     */
    if (async_event == ISCSI_ASYNC_MSG_REQUEST_LOGOUT ||
        async_event == ISCSI_ASYNC_MSG_DROPPING_CONNECTION ||
        async_event == ISCSI_ASYNC_MSG_DROPPING_ALL_CONNECTIONS) {
        hdr->param1 = cpu_to_be16(0);  /* Time2Wait = 0: logout now */
        hdr->param2 = cpu_to_be16(0);  /* Time2Retain = 0: no grace period */
    }

    cmd->i_state = ISTATE_SEND_ASYNCMSG;
    iscsit_add_cmd_to_conn_list(cmd, conn);
    wake_up(&conn->queues_wq);

    return 0;
}
```

When the initiator receives this Async PDU with `async_event = 0x01` (REQUEST_LOGOUT):
- `iscsi_async_msg_rsp()` in `libiscsi.c` calls `iscsi_conn_failure()`
- Session recovery begins on the initiator
- `replacement_timeout` countdown starts
- After 120s (or when login is rejected): `DID_TRANSPORT_FAILFAST` → `fail_path()`

This is the cleanest fencing mechanism — no abrupt TCP RST, no ambiguous timeout.

---

## Key takeaways

- TX kthread dispatches on `cmd->i_state`. Each state maps to a specific PDU type.
- `iscsit_send_response()` builds the full 48-byte SCSI Response BHS:
  - `cmd_status` = `se_cmd->scsi_status` (0x00 GOOD, 0x02 CHECK CONDITION, 0x18 RESERVATION CONFLICT)
  - Sense data is in the data segment only for `CHECK CONDITION` (2-byte prefix + sense bytes)
  - `RESERVATION CONFLICT` has `DataSegmentLength = 0` — no sense data
  - `ExpCmdSN` / `MaxCmdSN` advance the initiator's CmdSN window
- `cmd_flags_table`:
  - `ICF_GOT_LAST_DATAOUT` = all write data received, safe to execute
  - `ICF_OOO_CMDSN` = out-of-order CmdSN, defer execution
- `cmd_i_state_table`: 15 states tracking command from arrival through all PDU types to completion.
- `iscsit_queue_status()` is the fabric callback from `target_complete_ok_work()`. Sets
  `i_state = ISTATE_SEND_STATUS` and wakes the TX kthread.
- `iscsit_send_async_msg()` with `ISCSI_ASYNC_MSG_REQUEST_LOGOUT` is the clean fencing PDU —
  initiator starts logout, `replacement_timeout` fires if ACL is also removed.

---

## Previous / Next

[Day 18 — iSCSI fabric RX thread](day18.md) | [Day 20 — LIO Persistent Reservations](day20.md)
