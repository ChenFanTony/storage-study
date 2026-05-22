# Day 11 — iscsi_tcp RX path

**Week 2**: iSCSI Initiator Kernel Code  
**Time**: 1–2 hours  
**Reference**: `drivers/scsi/iscsi_tcp.c`, `drivers/scsi/libiscsi.c`, `drivers/scsi/libiscsi_tcp.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

The RX path receives iSCSI PDUs from the TCP socket, matches them to outstanding tasks by ITT,
and completes the `scsi_cmnd` back to the SCSI mid layer. It is driven by the socket's
`sk_data_ready` callback — no polling, no dedicated RX kthread in the software initiator. The
design must handle: partial PDU receives (TCP may deliver headers and data in pieces), multiple
PDU types (SCSI Response, Data-In, R2T, NOP-In, Async, Reject), and digest validation.

---

## sk_data_ready — the RX entry point

When TCP delivers data to the socket, the kernel calls `sk->sk_data_ready`. libiscsi registers
its own callback during `iscsi_conn_set_callbacks()`:

```c
/* Simplified — see iscsi_tcp.c for the actual receive setup. Newer
 * kernels use sk_receive_queue walking and skb iov_iter helpers; older
 * versions used tcp_read_sock(). */
static void iscsi_sw_tcp_data_ready(struct sock *sk)
{
    struct iscsi_conn *conn;
    struct iscsi_tcp_conn *tcp_conn;
    read_descriptor_t rd_desc;

    read_lock_bh(&sk->sk_callback_lock);
    conn     = sk->sk_user_data;
    tcp_conn = conn->dd_data;

    /* Pull bytes out of the receive queue and feed iscsi_sw_tcp_recv() */
    rd_desc.arg.data = conn;
    rd_desc.count    = 1;
    tcp_read_sock(sk, &rd_desc, iscsi_sw_tcp_recv);

    read_unlock_bh(&sk->sk_callback_lock);
}
```

`tcp_read_sock()` (or its modern equivalent) calls the receive callback repeatedly with pieces of
the socket's receive buffer until no more data is available.

---

## iscsi_sw_tcp_recv — `drivers/scsi/iscsi_tcp.c`

```c
static int iscsi_sw_tcp_recv(read_descriptor_t *rd_desc,
                              struct sk_buff *skb,
                              unsigned int offset,
                              size_t len)
{
    struct iscsi_conn *conn = rd_desc->arg.data;
    struct iscsi_tcp_conn *tcp_conn = conn->dd_data;
    unsigned int consumed = 0;
    int rc;

    if (test_bit(ISCSI_SUSPEND_BIT, &conn->suspend_rx)) {
        rd_desc->count = 0;
        return 0;
    }

    while (len > 0) {
        /*
         * Feed bytes into the current incoming segment.
         * The segment may be:
         *   - BHS (48 bytes)
         *   - data segment (variable, up to MaxRecvDataSegmentLength)
         *   - digest (4 bytes CRC32C)
         */
        rc = iscsi_sw_tcp_recv_data(conn, skb, offset, len);
        if (rc < 0) {
            iscsi_conn_failure(conn, ISCSI_ERR_CONN_FAILED);
            return 0;
        }

        consumed += rc;
        offset   += rc;
        len      -= rc;

        /*
         * Check if the current segment is complete.
         * If so, advance to the next segment (BHS → data → digest).
         */
        if (iscsi_tcp_segment_done(tcp_conn, &tcp_conn->in, 1, rc)) {
            /* PDU complete — process it */
            rc = iscsi_tcp_recv_pdu(conn, &tcp_conn->hdr,
                                     tcp_conn->in.data, tcp_conn->in.size);
            if (rc)
                return 0;
        }
    }

    return consumed;
}
```

---

## BHS receive and opcode dispatch — `drivers/scsi/libiscsi.c`

When the 48-byte BHS is fully received, it is passed to libiscsi for dispatch by opcode:

```c
/* Simplified — see drivers/scsi/libiscsi.c. */
int __iscsi_complete_pdu(struct iscsi_conn *conn, struct iscsi_hdr *hdr,
                         char *data, int datalen)
{
    uint8_t opcode = hdr->opcode & ISCSI_OPCODE_MASK;

    switch (opcode) {
    case ISCSI_OP_SCSI_CMD_RSP:
        /*
         * SCSI Response PDU — command complete.
         * Contains SCSI status (GOOD, CHECK CONDITION, RESERVATION CONFLICT)
         * and optionally sense data.
         */
        return iscsi_scsi_cmd_rsp(conn, hdr, data, datalen);

    case ISCSI_OP_SCSI_DATA_IN:
        /*
         * Data-In PDU — read data from target.
         * Contains DataSN, offset, data segment.
         * If S-bit set: status is piggybacked (no separate Response PDU).
         */
        return iscsi_data_in_rsp(conn, hdr);

    case ISCSI_OP_R2T:
        /*
         * Ready To Transfer — target requesting write data.
         * Triggers send of solicited Data-Out PDUs.
         */
        return iscsi_r2t_rsp(conn, hdr);

    case ISCSI_OP_NOOP_IN:
        /*
         * NOP-In — keepalive response or unsolicited probe from target.
         * Reset the transport timer (prevents connection teardown).
         */
        return iscsi_nop_in_rsp(conn, hdr);

    case ISCSI_OP_ASYNC_EVENT:
        /*
         * Async Message — target-initiated events.
         * AsyncEvent values include:
         *   0x01 = REQUEST LOGOUT
         *   0x02 = DROPPING_CONNECTION
         *   0x03 = DROPPING_ALL_CONNECTIONS
         *
         * Used in target-side fencing approaches (day 24/25).
         */
        return iscsi_async_msg_rsp(conn, hdr);

    case ISCSI_OP_REJECT:
        /* target rejected our PDU — protocol error */
        return iscsi_handle_reject(conn, hdr, data, datalen);

    case ISCSI_OP_LOGIN_RSP:
    case ISCSI_OP_TEXT_RSP:
        /* handled during login/text negotiation, not here */
        return iscsi_login_rsp(conn, hdr);

    case ISCSI_OP_SCSI_TMFUNC_RSP:
        /* TMF response — wake EH waiting for abort/reset confirmation */
        return iscsi_tmf_rsp(conn, hdr);

    default:
        iscsi_conn_failure(conn, ISCSI_ERR_BAD_OPCODE);
        return ISCSI_ERR_BAD_OPCODE;
    }
}
```

---

## iscsi_scsi_cmd_rsp — command completion — `drivers/scsi/libiscsi.c`

The most important RX path — completing a SCSI command:

```c
/* Simplified — see drivers/scsi/libiscsi.c. */
static int iscsi_scsi_cmd_rsp(struct iscsi_conn *conn, struct iscsi_hdr *hdr,
                               char *data, int datalen)
{
    struct iscsi_scsi_rsp *rhdr = (struct iscsi_scsi_rsp *)hdr;
    struct iscsi_session *session = conn->session;
    struct iscsi_task *task;
    struct scsi_cmnd *sc;
    uint16_t senselen;

    /*
     * Look up the task by ITT.
     * ITT in the response must match a task in conn->taskqueue.
     * If age bits don't match (stale ITT from old session) → reject.
     */
    task = iscsi_itt_to_ctask(conn, rhdr->itt);
    if (!task) {
        iscsi_conn_failure(conn, ISCSI_ERR_BAD_ITT);
        return ISCSI_ERR_BAD_ITT;
    }

    sc = task->sc;

    /*
     * Update CmdSN window — target tells us new max_cmdsn.
     * This may unblock the queuecommand path if the window was closed.
     */
    iscsi_update_cmdsn(session, (struct iscsi_nopin *)hdr);

    /*
     * Update StatSN.
     */
    conn->exp_statsn = be32_to_cpu(rhdr->statsn) + 1;

    /*
     * Set the SCSI result.
     * sc->result = (host_byte << 16) | status_byte
     *
     * rhdr->cmd_status is the SCSI status byte:
     *   0x00 = GOOD
     *   0x02 = CHECK CONDITION (with sense data in data segment)
     *   0x18 = RESERVATION CONFLICT
     *   0x28 = TASK SET FULL
     *
     * rhdr->response is the iSCSI service response:
     *   0x00 = ISCSI_STATUS_CMD_COMPLETED
     *   0x01 = TARGET FAILURE
     */
    if (rhdr->response == ISCSI_STATUS_CMD_COMPLETED) {
        sc->result = (DID_OK << 16) | rhdr->cmd_status;

        if (rhdr->cmd_status == SAM_STAT_CHECK_CONDITION && datalen >= 2) {
            /*
             * Sense data format in the PDU data segment:
             *   bytes [0..1]: sense length (big-endian u16)
             *   bytes [2..]:  the sense buffer
             */
            senselen = get_unaligned_be16(data);

            if (senselen > SCSI_SENSE_BUFFERSIZE)
                senselen = SCSI_SENSE_BUFFERSIZE;

            memcpy(sc->sense_buffer, data + 2, senselen);
            sc->sense_len = senselen;
        }
    } else {
        /* iSCSI-level failure (not SCSI status) */
        sc->result = DID_ERROR << 16;
    }

    /*
     * Complete the task — this calls the global scsi_done(sc) which is
     * scsi_done() → scsi_decide_disposition() (day 5).
     *
     * From here, RESERVATION CONFLICT flows:
     *   sc->result = DID_OK | SAM_STAT_RESERVATION_CONFLICT
     *   passthrough short-circuits via scsi_complete()
     *   blk_execute_rq() wakes
     *   scsi_execute_cmd() returns -EIO
     */
    iscsi_complete_task(task, ISCSI_TASK_COMPLETED);
    return 0;
}
```

---

## iscsi_complete_task — `drivers/scsi/libiscsi.c`

```c
static void iscsi_complete_task(struct iscsi_task *task, int state)
{
    struct iscsi_conn *conn = task->conn;
    struct scsi_cmnd *sc = task->sc;

    /* remove from taskqueue — no longer awaiting response */
    spin_lock_bh(&conn->taskqueuelock);
    list_del_init(&task->running);
    spin_unlock_bh(&conn->taskqueuelock);

    task->state = state;

    /* return task to pool */
    iscsi_put_task(task);

    /*
     * Call the global scsi_done() helper — it dispatches to either
     * scsi_complete() for passthrough (which wakes blk_execute_rq) or
     * the softirq/disposition path for normal I/O (day 5).
     */
    if (sc)
        scsi_done(sc);
}
```

---

## iscsi_data_in_rsp — handling read data — `drivers/scsi/libiscsi.c`

For READ commands, the target sends Data-In PDUs instead of (or before) the SCSI Response PDU:

```c
static int iscsi_data_in_rsp(struct iscsi_conn *conn, struct iscsi_hdr *hdr)
{
    struct iscsi_data_rsp *rhdr = (struct iscsi_data_rsp *)hdr;
    struct iscsi_task *task;
    struct scsi_cmnd *sc;

    task = iscsi_itt_to_ctask(conn, rhdr->itt);
    if (!task)
        return ISCSI_ERR_BAD_ITT;

    sc = task->sc;

    /*
     * The data segment following this BHS contains read data.
     * iscsi_tcp routes the receive directly into the bio_vec pages of
     * the scsi_cmnd's SGL via iscsi_segment_seek_sg() — zero-copy in
     * the absence of digest checking. With DataDigest enabled, the
     * data is also fed to the CRC32C hash as it lands.
     */

    task->datasn = be32_to_cpu(rhdr->datasn);

    /*
     * S-bit (Status bit): if set, SCSI status is piggybacked in this
     * Data-In PDU. No separate SCSI Response PDU will follow.
     * This saves one round-trip for reads.
     */
    if (rhdr->flags & ISCSI_FLAG_DATA_STATUS) {
        sc->result = (DID_OK << 16) | rhdr->cmd_status;
        iscsi_complete_task(task, ISCSI_TASK_COMPLETED);
    }

    return 0;
}
```

---

## iscsi_r2t_rsp — R2T handling — `drivers/scsi/libiscsi.c`

When `InitialR2T=Yes`, the target sends R2T PDUs to grant permission to send write data:

```c
static int iscsi_r2t_rsp(struct iscsi_conn *conn, struct iscsi_hdr *hdr)
{
    struct iscsi_r2t_rsp *rhdr = (struct iscsi_r2t_rsp *)hdr;
    struct iscsi_task *task;
    struct iscsi_r2t_info *r2t;

    task = iscsi_itt_to_ctask(conn, rhdr->itt);
    if (!task)
        return ISCSI_ERR_BAD_ITT;

    /*
     * Allocate an r2t_info from the per-task R2T pool.
     * Fields from the R2T PDU:
     *   r2t->data_offset = buffer offset to start sending from
     *   r2t->data_length = how many bytes to send in response
     *   r2t->ttt         = TargetTransferTag (must echo in Data-Out PDUs)
     */
    r2t = iscsi_tcp_get_curr_r2t(task);
    if (!r2t)
        return ISCSI_ERR_R2TSN;

    r2t->data_offset = be32_to_cpu(rhdr->data_offset);
    r2t->data_length = be32_to_cpu(rhdr->data_length);
    r2t->ttt         = rhdr->ttt;

    /*
     * Queue the task for TX to send the solicited Data-Out PDUs.
     * TX will use r2t->data_offset and r2t->data_length to know
     * which portion of the SGL to send.
     */
    iscsi_requeue_task(task);

    return 0;
}
```

---

## iscsi_async_msg_rsp — Async PDU — `drivers/scsi/libiscsi.c`

```c
static int iscsi_async_msg_rsp(struct iscsi_conn *conn, struct iscsi_hdr *hdr)
{
    struct iscsi_async *rhdr = (struct iscsi_async *)hdr;

    iscsi_update_cmdsn(conn->session, (struct iscsi_nopin *)hdr);

    switch (rhdr->async_event) {
    case ISCSI_ASYNC_MSG_SCSI_EVENT:
        /* SCSI UA event — re-check device */
        break;

    case ISCSI_ASYNC_MSG_REQUEST_LOGOUT:
        /*
         * Target is requesting we logout.
         * Used in the session-drop fencing approach (day 25):
         * target admin drops session → Async PDU sent → initiator
         * logs out gracefully → no abrupt TCP RST → cleaner teardown.
         */
        iscsi_conn_failure(conn, ISCSI_ERR_CONN_FAILED);
        break;

    case ISCSI_ASYNC_MSG_DROPPING_CONNECTION:
        /* target dropping this connection — reconnect */
        iscsi_conn_failure(conn, ISCSI_ERR_CONN_FAILED);
        break;

    case ISCSI_ASYNC_MSG_DROPPING_ALL_CONNECTIONS:
        /* target dropping all connections — full session recovery */
        iscsi_conn_failure(conn, ISCSI_ERR_CONN_FAILED);
        break;

    case ISCSI_ASYNC_MSG_PARAM_NEGOTIATION:
        /* target wants to renegotiate session parameters */
        break;
    }

    return 0;
}
```

`ISCSI_ASYNC_MSG_REQUEST_LOGOUT` is what a well-behaved target sends before closing a session
(e.g. during the session-drop fencing approach). The initiator calls `iscsi_conn_failure()` which
starts the recovery machinery — cleaner than a TCP RST.

---

## Complete RX flow for a SCSI Response PDU

```
TCP socket receives bytes
    │  sk_data_ready() fires (socket callback)
    ▼
iscsi_sw_tcp_data_ready()
    │  tcp_read_sock() → iscsi_sw_tcp_recv()
    ▼
iscsi_sw_tcp_recv_data()
    │  copies bytes into tcp_conn->in (iscsi_segment for BHS)
    │  segment->copied advances
    ▼
BHS fully received (48 bytes):
__iscsi_complete_pdu()
    │  opcode = ISCSI_OP_SCSI_CMD_RSP (0x21)
    ▼
iscsi_scsi_cmd_rsp()
    │  iscsi_itt_to_ctask() → find iscsi_task by ITT
    │  iscsi_update_cmdsn() → advance max_cmdsn window
    │  sc->result = DID_OK | cmd_status   e.g. 0x00000018 for RESERVATION CONFLICT
    │  if CHECK CONDITION: copy sense_buffer
    ▼
iscsi_complete_task()
    │  remove task from conn->taskqueue
    │  return task to pool
    │  scsi_done(sc)               (global helper)
    ▼
scsi_done()                           [drivers/scsi/scsi_lib.c]
    │  blk_rq_is_passthrough? → yes (PR) → scsi_complete() directly
    │                           → no       → blk_mq_complete_request() → softirq
    ▼
scsi_io_completion() / scsi_softirq_done()
    │  scsi_decide_disposition()
    │    RESERVATION CONFLICT → SUCCESS → blk_mq_complete_request()
    │    CHECK CONDITION / NOT Ready  → NEEDS_RETRY → scsi_queue_insert()
    ▼
blk_execute_rq() returns (for PR)    OR    multipath retries / queues (for I/O)
```

---

## Key takeaways

- RX is driven by the `sk_data_ready` socket callback — no polling kthread for iscsi_tcp.
- The receive routine incrementally fills `iscsi_segment` structs for BHS, data, and digest —
  handles partial TCP delivery naturally via `segment->copied`.
- Opcode dispatch in `__iscsi_complete_pdu()` routes to the appropriate handler.
- `iscsi_scsi_cmd_rsp()` finds the task by ITT, sets `sc->result`, copies sense data, and calls
  the global `scsi_done(sc)` helper → re-enters the SCSI mid layer.
- For PR (passthrough): `scsi_done()` short-circuits via `scsi_complete()` → wakes
  `blk_execute_rq()` immediately.
- For normal I/O: `scsi_decide_disposition()` routes by status:
  `RESERVATION CONFLICT` → SUCCESS, `NOT READY` → NEEDS_RETRY, `DID_NO_CONNECT` → FAILED.
- `iscsi_async_msg_rsp()` handles `ASYNC_MSG_REQUEST_LOGOUT` — this is the clean fencing signal.
- Data-In PDUs write directly into bio_vec pages (zero copy) when no digest is checked; with
  DataDigest enabled the same data is fed through CRC32C as it arrives.
- R2T PDUs trigger solicited Data-Out by requeuing the task to the TX worker.

---

## Previous / Next

[Day 10 — iscsi_tcp TX path](day10.md) | [Day 12 — session failure and EH interaction](day12.md)
