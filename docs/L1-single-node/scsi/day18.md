# Day 18 — iSCSI fabric RX thread

**Week 3**: LIO Target Kernel Code  
**Time**: 1–2 hours  
**Reference**: `drivers/target/iscsi/iscsi_target.c`, `drivers/target/iscsi/iscsi_target_nego.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

LIO's iSCSI RX path is symmetric to the initiator's RX (day 11): a thread reads bytes from the TCP
socket, parses BHS, dispatches by opcode. But target side has more to do — it owns the CmdSN
ordering, the unsolicited-data tracking, and the multiple variants of write data flow that depend
on negotiated session parameters. This day covers the RX thread and the five write data flows
that lead into `target_submit_cmd()`.

---

## RX thread structure — `drivers/target/iscsi/iscsi_target.c`

Each connection has a dedicated kthread: `iscsi_target_rx_thread`.

```c
/* Simplified — see drivers/target/iscsi/iscsi_target.c. */
int iscsi_target_rx_thread(void *arg)
{
    struct iscsit_conn *conn = arg;
    int ret;

    /* allow_signal allows kill_iscsi_thread() to wake us */
    allow_signal(SIGINT);

    while (!kthread_should_stop()) {
        /*
         * Read 48-byte BHS from socket.
         * iscsit_do_rx_data() handles partial reads, digest verification,
         * and signal-driven exit.
         */
        ret = iscsit_do_rx_data(conn, &conn->bhs_buffer, ISCSI_HDR_LEN);
        if (ret <= 0)
            break;

        /*
         * If HeaderDigest=CRC32C, read and validate the 4-byte digest.
         * On mismatch: send REJECT PDU, reset connection.
         */
        if (conn->conn_ops->HeaderDigest) {
            ret = iscsit_check_header_digest(conn);
            if (ret < 0)
                break;
        }

        /*
         * Dispatch by opcode.
         */
        ret = iscsit_process_rx_pdu(conn);
        if (ret < 0)
            break;
    }

    /* connection error — clean up */
    iscsit_take_action_for_connection_exit(conn);
    return 0;
}
```

The kthread blocks in the socket read until data arrives. Unlike the initiator's `sk_data_ready`
callback model, the target uses dedicated kthreads — one per connection — because iSCSI target
can have many concurrent connections from different initiators and per-connection threading
gives a clean processing context for each.

---

## iscsit_process_rx_pdu — opcode dispatch

```c
/* Simplified. */
static int iscsit_process_rx_pdu(struct iscsit_conn *conn)
{
    struct iscsi_hdr *hdr = (struct iscsi_hdr *)&conn->bhs_buffer;
    u8 opcode = hdr->opcode & ISCSI_OPCODE_MASK;

    switch (opcode) {
    case ISCSI_OP_SCSI_CMD:
        /* SCSI Command PDU — most common */
        return iscsit_handle_scsi_cmd(conn, hdr);

    case ISCSI_OP_SCSI_DATA_OUT:
        /* Solicited or unsolicited write data */
        return iscsit_handle_data_out(conn, hdr);

    case ISCSI_OP_NOOP_OUT:
        /* Initiator keepalive or ping reply */
        return iscsit_handle_nop_out(conn, hdr);

    case ISCSI_OP_SCSI_TMFUNC:
        /* Task Management Function (ABORT TASK, LUN RESET, etc.) */
        return iscsit_handle_task_mgt_cmd(conn, hdr);

    case ISCSI_OP_LOGOUT:
        /* Graceful session/connection close */
        return iscsit_handle_logout_cmd(conn, hdr);

    case ISCSI_OP_TEXT:
        /* Parameter renegotiation */
        return iscsit_handle_text_cmd(conn, hdr);

    case ISCSI_OP_SNACK:
        /* SNACK request — for ERL>0 recovery */
        return iscsit_handle_snack(conn, hdr);

    default:
        /* unknown opcode → REJECT PDU */
        return iscsit_send_reject(conn, hdr);
    }
}
```

---

## iscsit_handle_scsi_cmd — the heart of write flow

This function handles a Command PDU (opcode 0x01). It must decide what to do with any
piggybacked immediate data and what to expect for unsolicited data, then hand off to the target
core.

```c
/* Simplified — see drivers/target/iscsi/iscsi_target.c. */
static int iscsit_handle_scsi_cmd(struct iscsit_conn *conn,
                                    struct iscsi_hdr *hdr)
{
    struct iscsit_cmd *cmd;
    struct iscsi_scsi_req *cmd_hdr = (struct iscsi_scsi_req *)hdr;
    int rc;

    /*
     * Allocate iscsit_cmd for this command.
     * Fields in cmd reference: cmd->se_cmd (target core), cmd->init_task_tag,
     * cmd->cmd_flags.
     */
    cmd = iscsit_allocate_cmd(conn, TASK_INTERRUPTIBLE);
    if (!cmd)
        return -ENOMEM;

    /*
     * Step 1: parse the BHS, set up cmd state.
     */
    rc = iscsit_setup_scsi_cmd(conn, cmd, (unsigned char *)hdr);
    if (rc < 0)
        goto reject;

    /*
     * Step 2: allocate buffers for incoming write data, if any.
     * For reads or no-data: returns immediately with no allocation.
     * For writes: allocates SGL pages sized for data_length.
     */
    rc = iscsit_alloc_buffs(cmd);
    if (rc < 0)
        goto reject;

    /*
     * Step 3: process — checks CmdSN ordering, decides write data flow,
     * may submit to target core synchronously.
     */
    rc = iscsit_process_scsi_cmd(conn, cmd, (unsigned char *)hdr);
    if (rc < 0)
        goto reject;

    /*
     * Step 4: if the Command PDU has immediate data, handle it.
     * iscsit_get_dataout() may submit additional Data-Out reads from
     * the socket if more bytes follow.
     */
    if (cmd->immediate_data) {
        rc = iscsit_handle_immediate_data(cmd, (unsigned char *)hdr,
                                            cmd_hdr->dlength_be);
        if (rc < 0)
            goto reject;
    }

    return 0;

reject:
    iscsit_send_reject(conn, hdr);
    iscsit_release_cmd(cmd->se_cmd);
    return -1;
}
```

---

## iscsit_setup_scsi_cmd — building cmd state

```c
/* Simplified. */
int iscsit_setup_scsi_cmd(struct iscsit_conn *conn, struct iscsit_cmd *cmd,
                            unsigned char *buf)
{
    struct iscsi_scsi_req *hdr = (struct iscsi_scsi_req *)buf;
    int data_direction;
    int task_attr;

    /*
     * Extract task attribute from BHS flags byte.
     */
    switch (hdr->flags & ISCSI_FLAG_CMD_ATTR_MASK) {
    case ISCSI_ATTR_UNTAGGED:
    case ISCSI_ATTR_SIMPLE:
        task_attr = TCM_SIMPLE_TAG;
        break;
    case ISCSI_ATTR_ORDERED:
        task_attr = TCM_ORDERED_TAG;
        break;
    case ISCSI_ATTR_HEAD_OF_QUEUE:
        task_attr = TCM_HEAD_TAG;
        break;
    case ISCSI_ATTR_ACA:
        task_attr = TCM_ACA_TAG;
        break;
    default:
        task_attr = TCM_SIMPLE_TAG;
    }

    /*
     * Determine data direction from R/W flags.
     */
    if (hdr->flags & ISCSI_FLAG_CMD_READ)
        data_direction = DMA_FROM_DEVICE;
    else if (hdr->flags & ISCSI_FLAG_CMD_WRITE)
        data_direction = DMA_TO_DEVICE;
    else
        data_direction = DMA_NONE;

    cmd->iscsi_opcode      = ISCSI_OP_SCSI_CMD;
    cmd->i_state           = ISTATE_NEW_CMD;
    cmd->immediate_cmd     = ((hdr->opcode & ISCSI_OP_IMMEDIATE) != 0);
    cmd->init_task_tag     = hdr->itt;
    cmd->cmd_sn            = be32_to_cpu(hdr->cmdsn);
    cmd->exp_stat_sn       = be32_to_cpu(hdr->exp_statsn);
    cmd->data_direction    = data_direction;
    cmd->data_length       = be32_to_cpu(hdr->data_length);

    /*
     * Set ICF (iscsit cmd flags) bits.
     * ICF_NON_IMMEDIATE_UNSOLICITED_DATA is set when the initiator can
     * send unsolicited Data-Out PDUs after this command (InitialR2T=No
     * negotiated and W=1 in this PDU).
     */
    if (data_direction == DMA_TO_DEVICE) {
        if (!conn->sess->sess_ops->InitialR2T &&
            (hdr->flags & ISCSI_FLAG_CMD_UNSOL_DATA_EN))
            cmd->cmd_flags |= ICF_NON_IMMEDIATE_UNSOLICITED_DATA;
    }

    /*
     * Initialize the underlying se_cmd via target_init_cmd / fabric helper.
     */
    transport_init_se_cmd(&cmd->se_cmd, &iscsi_ops, conn->sess->se_sess,
                          cmd->data_length, cmd->data_direction,
                          task_attr, cmd->sense_buffer + 2,
                          scsilun_to_int(&hdr->lun));

    return 0;
}
```

---

## iscsit_process_scsi_cmd — the five write data flows

This is where one of the five distinct write data flows is selected based on:
- `ImmediateData` (was data piggybacked in the Command PDU?)
- `InitialR2T` (must initiator wait for R2T before sending unsolicited data?)
- `data_length` vs `first_burst_length` vs `max_burst_length`

The taxonomy below — paths A through E — is this document's pedagogical naming. RFC 7143 describes
the same flows but does not letter them.

```c
/* Simplified. */
int iscsit_process_scsi_cmd(struct iscsit_conn *conn, struct iscsit_cmd *cmd,
                              unsigned char *buf)
{
    struct iscsi_scsi_req *hdr = (struct iscsi_scsi_req *)buf;
    struct iscsi_session *sess = conn->sess;
    int dlen = be32_to_cpu(hdr->dlength_be) & 0x00ffffff;
    int rc;

    /*
     * Sequence the command in the CmdSN window.
     * Out-of-order commands wait until earlier ones are processed.
     */
    rc = iscsit_sequence_cmd(conn, cmd, buf, hdr->cmdsn);
    if (rc < 0)
        return rc;
    if (rc == CMDSN_LOWER_THAN_EXP)
        return 0;  /* duplicate — already processed, dropped */

    /*
     * Decide the write data flow.
     * Five pedagogical paths, named A–E below:
     */

    if (cmd->data_direction != DMA_TO_DEVICE) {
        /* Path A: read or no data — execute immediately */
        target_submit_cmd_map_sgls(&cmd->se_cmd, ..., NULL, 0, ...);
        return 0;
    }

    /*
     * Path B: ImmediateData=Yes + first_burst >= data_length
     *         All data piggybacked in this Command PDU.
     *         No Data-Out PDUs needed.
     */
    if (dlen >= cmd->data_length) {
        cmd->immediate_data = 1;
        cmd->cmd_flags |= ICF_GOT_LAST_DATAOUT;
        /* iscsit_handle_immediate_data() will copy and submit */
        return 0;
    }

    /*
     * Path C: ImmediateData=Yes + first_burst < data_length, InitialR2T=No
     *         Some data piggybacked, more comes as unsolicited Data-Out.
     *         No R2T needed — first_burst caps unsolicited bytes.
     */
    if (dlen > 0 && !sess->sess_ops->InitialR2T) {
        cmd->immediate_data = 1;
        cmd->unsolicited_data = 1;
        cmd->cmd_flags |= ICF_NON_IMMEDIATE_UNSOLICITED_DATA;
        return 0;
    }

    /*
     * Path D: ImmediateData=No, InitialR2T=No
     *         No piggybacked data; unsolicited Data-Out follows
     *         up to first_burst, then R2T for the rest.
     */
    if (dlen == 0 && !sess->sess_ops->InitialR2T) {
        cmd->unsolicited_data = 1;
        return 0;
    }

    /*
     * Path E: InitialR2T=Yes (most conservative; default in many configs)
     *         Target sends R2T(s); initiator sends solicited Data-Out only.
     */
    cmd->immediate_data = 0;
    cmd->unsolicited_data = 0;
    /* Send R2T immediately: */
    rc = iscsit_send_r2ts_to_fe(cmd, conn, true);
    if (rc < 0)
        return rc;

    return 0;
}
```

The five flows summarised:

| Path | ImmediateData | InitialR2T | What happens |
|------|---------------|------------|--------------|
| A | n/a | n/a | Read/no-data: submit immediately. |
| B | Yes | n/a | All data fits in Command PDU (piggybacked). |
| C | Yes | No | Piggybacked + unsolicited Data-Out (up to first_burst). |
| D | No | No | Unsolicited Data-Out (up to first_burst), then R2T for rest. |
| E | n/a | Yes | All data via solicited Data-Out (R2T-driven). |

Most modern targets default to Path E (InitialR2T=Yes) for predictable buffering. iSER and high-
performance setups often use Path D (InitialR2T=No, ImmediateData=No) for lower latency.

---

## iscsit_handle_data_out — write data PDUs

```c
/* Simplified. */
static int iscsit_handle_data_out(struct iscsit_conn *conn,
                                    struct iscsi_hdr *hdr)
{
    struct iscsi_data_hdr *dhdr = (struct iscsi_data_hdr *)hdr;
    struct iscsit_cmd *cmd;
    int rc;

    /*
     * Look up the command this Data-Out belongs to via ITT.
     */
    cmd = iscsit_find_cmd_from_itt(conn, dhdr->itt);
    if (!cmd) {
        return -1;
    }

    /*
     * Receive the data segment into the command's SGL pages.
     */
    rc = iscsit_get_dataout(conn, cmd, dhdr);
    if (rc < 0)
        return rc;

    /*
     * Update write_data_done counter.
     * Compare with data_length.
     */
    cmd->write_data_done += be32_to_cpu(dhdr->dlength_be) & 0x00ffffff;

    /*
     * Check F-bit. F=1 + write_data_done == data_length means ready
     * to execute on backend.
     */
    if (dhdr->flags & ISCSI_FLAG_CMD_FINAL) {
        cmd->cmd_flags |= ICF_GOT_LAST_DATAOUT;
        if (cmd->write_data_done == cmd->data_length) {
            /* Hand off to target core for backend execution */
            target_execute_cmd(&cmd->se_cmd);
        } else {
            /* More R2Ts still owed — send next one */
            iscsit_send_r2ts_to_fe(cmd, conn, false);
        }
    }

    return 0;
}
```

The `F=1` final-bit on the last Data-Out PDU is what triggers backend execution. Without it the
target waits for more PDUs, even if `write_data_done == data_length` happens to be true (which
is an initiator-side bug if the initiator sent the right amount but didn't set F=1).

---

## CmdSN ordering — `iscsit_sequence_cmd`

```c
/* Simplified — see iscsi_target_util.c. */
int iscsit_sequence_cmd(struct iscsit_conn *conn, struct iscsit_cmd *cmd,
                          unsigned char *buf, __be32 cmdsn_be)
{
    struct iscsi_session *sess = conn->sess;
    u32 cmdsn = be32_to_cpu(cmdsn_be);
    int ret;

    mutex_lock(&sess->cmdsn_mutex);

    /*
     * Compare cmdsn to sess->exp_cmd_sn.
     * Three cases:
     *   cmdsn == exp_cmd_sn: in-order, process now
     *   cmdsn  > exp_cmd_sn: out-of-order, queue and wait
     *   cmdsn  < exp_cmd_sn: duplicate (replay), drop silently
     */
    if (cmdsn == sess->exp_cmd_sn) {
        sess->exp_cmd_sn++;
        cmd->cmd_flags |= ICF_OOO_CMDSN;  /* clear: not out-of-order */
        ret = CMDSN_NORMAL_OPERATION;

        /* drain any queued commands that are now in-order */
        iscsit_execute_cmd(cmd, false);
        iscsit_execute_ooo_cmdsns(sess);
    } else if (iscsi_sna_gt(cmdsn, sess->exp_cmd_sn)) {
        /* out-of-order — queue */
        ret = iscsit_handle_ooo_cmdsn(sess, cmd, cmdsn);
    } else {
        /* duplicate — drop */
        ret = CMDSN_LOWER_THAN_EXP;
    }

    /* update session-wide MaxCmdSN window */
    sess->max_cmd_sn = sess->exp_cmd_sn + sess->cmd_sn_window;

    mutex_unlock(&sess->cmdsn_mutex);
    return ret;
}
```

Out-of-order CmdSN happens because the initiator can send commands faster than the target
processes them, and TCP can deliver in any order if they cross multiple connections (MC/S — rare
in practice). The target buffers OOO commands and runs them as the gap closes.

`iscsi_sna_gt` and `iscsi_sna_lt` implement RFC 1982 Serial Number Arithmetic — comparing
sequence numbers that may wrap around 2^32.

---

## Async PDU sending for fencing

The target sends Async PDUs (opcode 0x32) for clean session-drop signalling. This is the path
used by the session-drop fencing approach (day 25):

```c
/* drivers/target/iscsi/iscsi_target.c */
int iscsit_send_async_msg(struct iscsit_conn *conn, u16 cid, u8 async_event,
                            u8 async_vcode)
{
    struct iscsi_async *hdr;
    /* build BHS with opcode=0x32, async_event=0x01 (REQUEST_LOGOUT) etc. */

    /* queue to TX path */
    return iscsit_send_pdu(conn, async_pdu);
}
```

Use cases:
- `async_event = 0x01` — REQUEST LOGOUT — politely asks initiator to log out.
- `async_event = 0x02` — DROPPING THIS CONNECTION — inform of imminent connection drop.
- `async_event = 0x03` — DROPPING ALL CONNECTIONS — full session teardown.

Target administrative tools (`targetcli`) can trigger these via configfs writes that translate
into `iscsit_send_async_msg()` calls.

---

## Key takeaways

- iSCSI target uses one kthread per connection (`iscsi_target_rx_thread`), unlike the
  initiator's `sk_data_ready` callback model.
- `iscsit_process_rx_pdu()` dispatches by opcode. The most common is `ISCSI_OP_SCSI_CMD` (0x01).
- `iscsit_handle_scsi_cmd()` builds `iscsit_cmd`/`se_cmd`, allocates write buffers, and calls
  `iscsit_process_scsi_cmd()`.
- Five distinct write data flows depending on `ImmediateData` and `InitialR2T`:
  - Path A: read or no data
  - Path B: all data piggybacked
  - Path C: piggybacked + unsolicited Data-Out
  - Path D: unsolicited Data-Out + R2T for tail
  - Path E: all R2T-driven (most conservative)

  These letters are a documentation aid; the iSCSI spec describes the same combinations but does
  not letter them.
- `iscsit_handle_data_out()` accepts Data-Out PDUs and triggers `target_execute_cmd()` when the
  F-bit is set on the final PDU AND `write_data_done == data_length`.
- `iscsit_sequence_cmd()` enforces CmdSN ordering. OOO commands queue; duplicates drop.
- Async PDUs (opcode 0x32) carry session-management events (REQUEST LOGOUT, DROPPING
  CONNECTION) — used for clean fencing.

---

## Previous / Next

[Day 17 — target_core_transport completion path](day17.md) | [Day 19 — iSCSI fabric TX thread and Data-Out](day19.md)
