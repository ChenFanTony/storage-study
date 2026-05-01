# Day 18 — iSCSI fabric RX thread

**Week 3**: LIO Target Core — Fabric to Backend
**Time**: 1–2 hours
**Reference**: `drivers/target/iscsi/iscsi_target.c`

---

## Overview

The iSCSI fabric's RX side is a dedicated kthread per connection that reads PDUs from the TCP
socket, decodes them by opcode, and routes them to the appropriate handler. For SCSI commands
the routing ends at `iscsit_process_scsi_cmd()` — the boundary between iSCSI fabric and target
core. This is the function you saw in the earlier conversation. Today you read the actual source.

---

## iscsi_target_rx_thread — `drivers/target/iscsi/iscsi_target.c`

```c
static int iscsi_target_rx_thread(void *arg)
{
    struct iscsi_conn *conn = arg;
    bool printed_notice = false;
    int rc;

    /*
     * Allow the TX thread to run concurrently.
     * TX and RX use separate locks so they can overlap.
     */
    allow_signal(SIGINT);

    while (!kthread_should_stop()) {
        /*
         * Block until data arrives on the socket.
         * iscsi_conn_set_callbacks() registered sk_data_ready to
         * wake this thread when TCP delivers data.
         *
         * For the target-side RX: this is a blocking read loop,
         * unlike the initiator side which uses sk_data_ready callbacks.
         * The target uses a dedicated kthread because:
         *   1. Performance: dedicated CPU for I/O intensive targets
         *   2. Simplicity: blocking read avoids async state machines
         */
        rc = iscsit_get_rx_pdu(conn);

        if (rc == ISCSI_ERR_NO_NUM_CMDS_STAT) {
            /*
             * Target overloaded — send ASYNC message to initiator
             * requesting it back off, then continue.
             */
            if (!printed_notice) {
                pr_notice("iSCSI target resource limit reached on %s\n",
                          conn->sess->sess_ops->InitiatorName);
                printed_notice = true;
            }
            continue;
        }

        if (!rc)
            continue;

        /*
         * rc > 0: connection-level error.
         * Close the connection — session recovery begins.
         */
        iscsit_cause_connection_reinstatement(conn, 0);
        break;
    }

    iscsit_take_action_for_connection_exit(conn, &conn_freed);
    return 0;
}
```

---

## iscsit_get_rx_pdu — PDU receive and opcode dispatch

```c
static int iscsit_get_rx_pdu(struct iscsi_conn *conn)
{
    int ret;
    u8 buffer[ISCSI_HDR_LEN], opcode;
    u32 checksum = 0, digest = 0;
    struct iscsi_hdr *hdr = (struct iscsi_hdr *)buffer;

    /*
     * Read the 48-byte BHS from the socket.
     * iscsit_do_crypto_hash_recv() handles:
     *   - blocking read via kernel_recvmsg()
     *   - optional HeaderDigest CRC32C validation
     */
    ret = iscsit_recv_msg(conn, buffer, ISCSI_HDR_LEN);
    if (ret < 0)
        return ret;

    /* validate header digest if negotiated */
    if (conn->conn_ops->HeaderDigest) {
        ret = iscsit_recv_msg(conn, (u8 *)&digest, ISCSI_CRC_LEN);
        if (ret < 0)
            return ret;
        checksum = iscsit_do_crypto_hash_buf(conn->conn_rx_hash, buffer,
                                              ISCSI_HDR_LEN, 0, NULL);
        if (digest != checksum) {
            pr_err("HeaderDigest mismatch: received 0x%08x, computed 0x%08x\n",
                   digest, checksum);
            return ISCSI_ERR_HEADER_DGST;
        }
    }

    /*
     * Dispatch by opcode (low 6 bits of byte 0).
     * Immediate bit is bit 6 — cleared before comparing.
     */
    opcode = hdr->opcode & ISCSI_OPCODE_MASK;

    switch (opcode) {
    case ISCSI_OP_SCSI_CMD:
        /*
         * SCSI Command PDU — the main data path.
         * Handles: read commands, write commands, no-data commands.
         * Calls iscsit_handle_scsi_cmd() → iscsit_process_scsi_cmd().
         */
        ret = iscsit_handle_scsi_cmd(conn, (struct iscsi_scsi_req *)hdr);
        break;

    case ISCSI_OP_SCSI_DATA_OUT:
        /*
         * Data-Out PDU — write data from initiator.
         * Accumulates write data into the se_cmd SGL.
         * When all data received (ICF_GOT_LAST_DATAOUT):
         *   calls target_execute_cmd() → backend I/O.
         */
        ret = iscsit_handle_data_out(conn, (struct iscsi_data *)hdr);
        break;

    case ISCSI_OP_NOOP_OUT:
        /*
         * NOP-Out — keepalive from initiator.
         * If ITT != ISCSI_RESERVED_TAG: response required (NOP-In).
         * Resets conn->last_recv timestamp.
         */
        ret = iscsit_handle_nop_out(conn, (struct iscsi_nopin *)hdr);
        break;

    case ISCSI_OP_SCSI_TMFUNC:
        /*
         * Task Management Function — abort, reset, etc.
         * Queued to target_tmr_wq (ordered — runs serially).
         */
        ret = iscsit_handle_task_mgt_cmd(conn, (struct iscsi_tm *)hdr);
        break;

    case ISCSI_OP_TEXT:
        /*
         * Text Request — used for SendTargets discovery and
         * parameter renegotiation.
         */
        ret = iscsit_handle_text_cmd(conn, (struct iscsi_text *)hdr);
        break;

    case ISCSI_OP_LOGOUT:
        /*
         * Logout Request — initiator requesting clean session close.
         * Sends Logout Response, then closes connection.
         */
        ret = iscsit_handle_logout_cmd(conn, (struct iscsi_logout *)hdr);
        break;

    case ISCSI_OP_SNACK:
        /* SNACK Request — retransmission request (ERL > 0) */
        ret = iscsit_handle_snack(conn, (struct iscsi_snack *)hdr);
        break;

    default:
        pr_err("Got unknown iSCSI OpCode: 0x%02x\n", opcode);
        return ISCSI_ERR_BAD_OPCODE;
    }

    return ret;
}
```

---

## iscsit_handle_scsi_cmd — `drivers/target/iscsi/iscsi_target.c`

Allocates the `iscsit_cmd`, extracts fields from the BHS, and calls
`iscsit_process_scsi_cmd()`:

```c
static int iscsit_handle_scsi_cmd(struct iscsi_conn *conn,
                                   struct iscsi_scsi_req *hdr)
{
    int data_direction, rc = 0;
    bool dump_payload = false;
    struct iscsit_cmd *cmd;

    /*
     * Allocate an iscsit_cmd (the iSCSI-layer command struct).
     * The se_cmd is embedded inside iscsit_cmd.
     * Memory layout: [iscsit_cmd][se_cmd][...]
     */
    cmd = iscsit_allocate_cmd(conn, TASK_INTERRUPTIBLE);
    if (!cmd)
        return iscsit_add_reject(conn, ISCSI_REASON_BOOKMARK_NO_RESOURCES,
                                  (unsigned char *)hdr);

    /*
     * Extract fields from the 48-byte BHS.
     */

    /* data direction from W and R bits */
    if (hdr->flags & ISCSI_FLAG_CMD_WRITE)
        data_direction = DMA_TO_DEVICE;
    else if (hdr->flags & ISCSI_FLAG_CMD_READ)
        data_direction = DMA_FROM_DEVICE;
    else
        data_direction = DMA_NONE;

    /* task attribute: Simple, Ordered, Head of Queue, ACA */
    cmd->data_direction = data_direction;
    cmd->data_length    = be32_to_cpu(hdr->data_length);
    cmd->cmd_flags      |= ICF_NON_IMMEDIATE_UNSOLICITED_DATA;

    /* ITT — used to match Data-Out PDUs and response PDUs */
    cmd->init_task_tag  = hdr->itt;

    /* CmdSN — for ordering check */
    cmd->cmd_sn         = be32_to_cpu(hdr->cmdsn);

    /* ExpStatSN — what the initiator expects from us */
    cmd->exp_stat_sn    = be32_to_cpu(hdr->exp_statsn);

    /* LUN from BHS (8-byte packed format → unpack to integer) */
    cmd->se_cmd.orig_fe_lun = scsilun_to_int(
        (struct scsi_lun *)hdr->lun);

    /* copy CDB from BHS */
    memcpy(cmd->cdb, hdr->cdb, MAX_COMMAND_SIZE);

    /*
     * CmdSN ordering check.
     * iSCSI requires commands to be executed in CmdSN order
     * (for Simple task attribute with ordered session).
     *
     * iscsit_sequence_cmd() checks CmdSN against conn->sess->exp_cmd_sn.
     * Returns:
     *   CMDSN_NORMAL_OPERATION: CmdSN is next expected → proceed
     *   CMDSN_HIGHER_THAN_EXP:  out of order → queue cmd, wait for gap
     *   CMDSN_LOWER_THAN_EXP:   duplicate → silently discard
     *   CMDSN_ERROR_CANNOT_RECOVER: protocol error → tear down connection
     */
    rc = iscsit_sequence_cmd(conn, cmd, (unsigned char *)hdr, hdr->cmdsn);
    if (rc == CMDSN_LOWER_THAN_EXP) {
        /* duplicate — already executed */
        target_put_sess_cmd(&cmd->se_cmd);
        return 0;
    }
    if (rc == CMDSN_ERROR_CANNOT_RECOVER)
        return rc;

    /*
     * If CMDSN_HIGHER_THAN_EXP: cmd is queued on sess->ooo_cmdsn_list.
     * It will be re-driven when the gap fills via iscsit_execute_cmd().
     * We do NOT call iscsit_process_scsi_cmd() now for OOO commands.
     */
    if (rc == CMDSN_HIGHER_THAN_EXP)
        return 0;

    /*
     * CMDSN_NORMAL_OPERATION: proceed to process the command.
     */
    return iscsit_process_scsi_cmd(conn, cmd, hdr);
}
```

---

## iscsit_process_scsi_cmd — `drivers/target/iscsi/iscsi_target.c`

The bridge between iSCSI fabric and target core. Controls the five write data-flow paths.

```c
int iscsit_process_scsi_cmd(struct iscsi_conn *conn,
                              struct iscsit_cmd *cmd,
                              struct iscsi_scsi_req *hdr)
{
    int cmdsn_ret = 0;
    u8 imm_data = 0, unsolicited_data = 0;

    /*
     * Allocate the data buffer (SGL) for this command.
     * For writes: SGL will receive Data-Out bytes.
     * For reads: SGL will hold data read from backend.
     * For no-data: skipped.
     */
    if (cmd->data_length) {
        if (iscsit_alloc_buffs(cmd) < 0) {
            return iscsit_add_reject_cmd(cmd,
                ISCSI_REASON_BOOKMARK_NO_RESOURCES,
                (unsigned char *)hdr);
        }
    }

    /*
     * Determine which write data path applies.
     * Controlled by session parameters negotiated during Login:
     *   - ImmediateData (imm_data_en): data piggybacked in Command PDU
     *   - InitialR2T (initial_r2t_en): solicited vs unsolicited
     */
    if (cmd->data_direction == DMA_TO_DEVICE) {

        if (conn->sess->sess_ops->ImmediateData) {
            /* check if Command PDU has a data segment */
            if (hdr->flags & ISCSI_FLAG_CMD_IMM_DATA_EN &&
                cmd->data_length > 0)
                imm_data = 1;
        }

        if (!conn->sess->sess_ops->InitialR2T) {
            /*
             * InitialR2T=No: initiator may send unsolicited Data-Out
             * PDUs up to FirstBurstLength without waiting for R2T.
             */
            if (!imm_data || cmd->data_length > conn->sess->sess_ops->FirstBurstLength)
                unsolicited_data = 1;
        }
    }

    /*
     * Hand off to target core. For reads and no-data commands:
     * target_submit_cmd() queues to target_submission_wq immediately.
     * For writes: target_submit_cmd() sets up the receive path but
     * does NOT execute until all data arrives.
     */
    rc = target_submit_cmd(&cmd->se_cmd, conn->sess->se_sess,
                            cmd->cdb, &cmd->se_cmd.sense_buffer[0],
                            cmd->se_cmd.orig_fe_lun,
                            cmd->data_length,
                            iscsit_task_attr(cmd->task_attr),
                            cmd->data_direction, 0);
    if (rc < 0) {
        iscsit_set_unsupported_task_attr(cmd);
        return rc;
    }

    if (!imm_data && !unsolicited_data) {
        /*
         * PATH A (READ / no-data): target_submit_cmd() has already
         * queued to target_submission_wq. Nothing more needed here.
         *
         * PATH E (InitialR2T=Yes, no immediate data):
         * Send R2T PDU to grant permission to send write data.
         * target_submit_cmd() called write_pending() which called
         * iscsit_request_r2t(). The initiator will send Data-Out
         * PDUs when it receives the R2T.
         */
        return 0;
    }

    if (imm_data) {
        /*
         * PATH B / PATH C: Command PDU contains immediate data.
         * Read the data segment from the socket right now.
         * iscsit_handle_immediate_data() reads from TCP and fills the SGL.
         */
        rc = iscsit_handle_immediate_data(cmd, hdr,
                                           be32_to_cpu(hdr->data_length));
        if (rc == ISCSI_STATE_FULL_FEATURE_PHASE)
            return 0;     /* need more Data-Out PDUs (PATH C) */
        if (rc < 0)
            return rc;

        /* if all data received inline (PATH B): cmd already submitted */
    }

    if (unsolicited_data) {
        /*
         * PATH C / PATH D: unsolicited Data-Out PDUs expected.
         * Set up sequence range for expected DataSN/offset tracking.
         * RX thread will process Data-Out PDUs via iscsit_handle_data_out().
         * When ICF_GOT_LAST_DATAOUT is set, target_execute_cmd() is called.
         */
        iscsit_set_unsolicited_dataout_sequence_range(cmd);
    }

    return 0;
}
```

---

## iscsit_handle_immediate_data — reading inline write data

```c
static int iscsit_handle_immediate_data(struct iscsit_cmd *cmd,
                                         struct iscsi_scsi_req *hdr,
                                         u32 length)
{
    struct iscsi_conn *conn = cmd->conn;
    struct iscsi_datain_req *dr;
    int rx_got;

    /*
     * Read the data segment from the TCP socket into the SGL.
     * iscsit_map_iovec() maps SGL entries to iovec for kernel_recvmsg().
     * Reads exactly 'length' bytes (the DataSegmentLength from BHS).
     */
    rx_got = iscsit_recv_data_segment(cmd, length);
    if (rx_got != length) {
        pr_err("iscsit_recv_data_segment() received %d bytes, expected %d\n",
               rx_got, length);
        return ISCSI_STATE_CXN_TIMEOUT;
    }

    cmd->write_data_done += length;

    /*
     * If all data received (immediate data covered all of data_length):
     * call target_execute_cmd() to start backend I/O.
     *
     * This sets ICF_GOT_LAST_DATAOUT and transitions to
     * ISTATE_RECEIVED_LAST_DATAOUT.
     */
    if (cmd->write_data_done == cmd->data_length) {
        cmd->cmd_flags |= ICF_GOT_LAST_DATAOUT;
        cmd->i_state    = ISTATE_RECEIVED_LAST_DATAOUT;

        /*
         * All data is in the SGL. Submit to target core for execution.
         * This calls target_execute_cmd() → queue to target_submission_wq.
         */
        target_execute_cmd(&cmd->se_cmd);
        return ISCSI_STATE_FULL_FEATURE_PHASE;
    }

    /*
     * Not all data arrived inline (PATH C: immediate + unsolicited Data-Out).
     * Return to RX thread to wait for more Data-Out PDUs.
     */
    return ISCSI_STATE_FULL_FEATURE_PHASE;
}
```

---

## iscsit_handle_data_out — receiving Data-Out PDUs

Called for each Data-Out PDU (opcode `0x05`):

```c
static int iscsit_handle_data_out(struct iscsi_conn *conn,
                                   struct iscsi_data *hdr)
{
    struct iscsit_cmd *cmd;
    int rc;
    bool ooo_cmdsn = false;

    /*
     * Find the iscsit_cmd by ITT.
     * ITT in the Data-Out BHS must match an outstanding write command.
     */
    cmd = iscsit_find_cmd_from_itt(conn, hdr->itt);
    if (!cmd) {
        pr_err("Data-Out ITT: 0x%08x not found\n", hdr->itt);
        return iscsit_add_reject(conn, ISCSI_REASON_BOOKMARK_INVALID,
                                  (unsigned char *)hdr);
    }

    /*
     * iscsit_check_dataout_hdr() validates:
     *   - DataSN is expected (in-order delivery check)
     *   - BufferOffset is within data_length
     *   - DataSegmentLength doesn't exceed MaxRecvDataSegmentLength
     */
    rc = iscsit_check_dataout_hdr(conn, (unsigned char *)hdr, cmd);
    if (rc < 0)
        return rc;

    /*
     * Read the data segment from the socket into the SGL at the
     * correct offset (hdr->offset).
     * iscsit_recv_data_segment() uses kernel_recvmsg() with iovec
     * mapped to the correct SGL entries for this offset.
     */
    rc = iscsit_check_dataout_payload(cmd, hdr, ooo_cmdsn);
    if (rc < 0)
        return rc;

    return 0;
}
```

`iscsit_check_dataout_payload()` is where `ICF_GOT_LAST_DATAOUT` is set:

```c
static int iscsit_check_dataout_payload(struct iscsit_cmd *cmd,
                                         struct iscsi_data *hdr,
                                         bool data_ooo)
{
    struct iscsi_conn *conn = cmd->conn;
    int rc, ooo_cmdsn;
    u32 payload_length = ntoh24(hdr->dlength);

    /* receive data into SGL */
    rc = iscsit_recv_data_segment(cmd, payload_length);
    if (rc < 0)
        return rc;

    cmd->write_data_done += payload_length;

    /*
     * iscsit_decide_dataout_action() checks:
     *   1. F-bit (Final): hdr->flags & ISCSI_FLAG_DATA_EOS
     *   2. cmd->write_data_done == cmd->data_length
     *
     * Returns DATAOUT_SEND_TO_TRANSPORT when both are true.
     */
    switch (iscsit_decide_dataout_action(cmd, hdr, &ooo_cmdsn)) {
    case DATAOUT_SEND_R2T:
        /* more data needed — send another R2T */
        iscsit_send_r2t_for_recovery(cmd);
        break;

    case DATAOUT_SEND_TO_TRANSPORT:
        /*
         * F-bit set AND write_data_done == data_length.
         * ALL write data has been received.
         *
         * Set ICF_GOT_LAST_DATAOUT and transition state.
         * Then call target_execute_cmd() to begin backend I/O.
         */
        spin_lock_bh(&cmd->istate_lock);
        cmd->cmd_flags |= ICF_GOT_LAST_DATAOUT;     /* ← THE FLAG */
        cmd->i_state    = ISTATE_RECEIVED_LAST_DATAOUT;
        spin_unlock_bh(&cmd->istate_lock);

        /*
         * If ICF_OOO_CMDSN is set: this command arrived out of CmdSN order.
         * Don't execute yet — wait for iscsit_execute_cmd() to re-drive it
         * once the CmdSN gap is filled.
         */
        if (!(cmd->cmd_flags & ICF_OOO_CMDSN))
            target_execute_cmd(&cmd->se_cmd);
        break;

    case DATAOUT_WITHIN_COMMAND_RECOVERY:
        /* ERL > 0: data digest mismatch, requesting retransmit */
        break;

    case DATAOUT_CANNOT_RECOVER:
        return -1;
    }

    return 0;
}
```

---

## iscsit_decide_dataout_action

```c
static enum dataout_action iscsit_decide_dataout_action(
    struct iscsit_cmd *cmd,
    struct iscsi_data *hdr,
    int *ooo_cmdsn)
{
    /*
     * F-bit: Final bit in Data-Out BHS flags.
     * Set by initiator in the last Data-Out PDU for a burst.
     * For solicited data: last PDU of the R2T burst.
     * For unsolicited data: last PDU of the FirstBurst.
     */
    bool f_bit = !!(hdr->flags & ISCSI_FLAG_DATA_EOS);

    /*
     * If F-bit is set AND all data has been received:
     * → complete, hand off to backend
     */
    if (f_bit && cmd->write_data_done == cmd->data_length)
        return DATAOUT_SEND_TO_TRANSPORT;

    /*
     * F-bit set but more data needed (another R2T burst):
     * → send R2T for next chunk
     */
    if (f_bit && cmd->write_data_done < cmd->data_length)
        return DATAOUT_SEND_R2T;

    /*
     * F-bit not set: more PDUs in this burst expected.
     * Continue receiving.
     */
    return DATAOUT_WITHIN_COMMAND_RECOVERY;
}
```

---

## The five write paths — how they map to code

| Path | Condition | Code path |
|------|-----------|-----------|
| A — READ/no-data | `data_direction != DMA_TO_DEVICE` | `target_submit_cmd()` → `target_execution_wq` immediately |
| B — Immediate data only | `ImmediateData=Yes`, `data_length <= FirstBurst` | `iscsit_handle_immediate_data()` → `write_data_done == data_length` → `target_execute_cmd()` |
| C — Immediate + unsolicited | `ImmediateData=Yes`, `data_length > FirstBurst`, `InitialR2T=No` | `iscsit_handle_immediate_data()` partial + wait for Data-Out PDUs via `iscsit_handle_data_out()` |
| D — Unsolicited only | `ImmediateData=No`, `InitialR2T=No` | `iscsit_set_unsolicited_dataout_sequence_range()` + wait for Data-Out PDUs |
| E — Solicited (R2T) | `InitialR2T=Yes` | `write_pending()` → `iscsit_request_r2t()` → wait for Data-Out PDUs after R2T response |

In all write paths, `target_execute_cmd()` is called only after
`cmd->cmd_flags & ICF_GOT_LAST_DATAOUT` is set — guaranteeing the SGL is fully populated.

---

## Key takeaways

- `iscsi_target_rx_thread` is a blocking kthread per connection. It loops calling
  `iscsit_get_rx_pdu()` which reads the BHS and dispatches by opcode.
- Opcode `0x01` (SCSI_CMD) → `iscsit_handle_scsi_cmd()` → CmdSN check →
  `iscsit_process_scsi_cmd()`.
- `iscsit_process_scsi_cmd()` calls `target_submit_cmd()` for all commands, then handles the
  write data-flow paths (immediate data, unsolicited Data-Out, R2T).
- `ICF_GOT_LAST_DATAOUT` is set in `iscsit_check_dataout_payload()` when F-bit=1 AND
  `write_data_done == data_length`. `target_execute_cmd()` is called immediately after.
- CmdSN ordering: `CMDSN_HIGHER_THAN_EXP` parks the command on `ooo_cmdsn_list`. It is
  re-driven by `iscsit_execute_cmd()` when the gap fills.
- Opcode `0x04` (SCSI_TMFUNC) → TMF → queued to `target_tmr_wq` (ordered).
- Opcode `0x06` (LOGOUT) → `iscsit_handle_logout_cmd()` → clean session close. This is the
  opcode sent by the initiator in response to an Async PDU requesting logout (fencing path).

---

## Previous / Next

[Day 17 — target_core_transport completion path](day17.md) | [Day 19 — iSCSI fabric TX thread and Data-Out](day19.md)
