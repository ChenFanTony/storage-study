# Day 11 — iscsi_tcp RX path

**Week 2**: iSCSI Initiator Kernel Code
**Time**: 1–2 hours
**Reference**: `drivers/scsi/iscsi_tcp.c`, `drivers/scsi/libiscsi.c`, `drivers/scsi/libiscsi_tcp.c`

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
static void iscsi_sw_tcp_data_ready(struct sock *sk)
{
    struct iscsi_conn *conn;
    struct iscsi_tcp_conn *tcp_conn;
    read_descriptor_t rd_desc;

    read_lock(&sk->sk_callback_lock);
    conn     = sk->sk_user_data;
    tcp_conn = conn->dd_data;

    /*
     * Use tcp_read_sock() which calls our recv_actor callback
     * for each available segment in the socket receive buffer.
     * More efficient than read() — no user/kernel copy, works with
     * kernel sk_buff chain directly.
     */
    rd_desc.arg.data = conn;
    rd_desc.count    = 1;  /* process as much as available */
    tcp_read_sock(sk, &rd_desc, iscsi_sw_tcp_recv_segment);

    read_unlock(&sk->sk_callback_lock);

    /* if we got a complete PDU, process it */
    iscsi_conn_check_and_flush(conn);
}
```

`tcp_read_sock()` calls `iscsi_sw_tcp_recv_segment()` repeatedly with pieces of the socket's
receive buffer until no more data is available.

---

## iscsi_sw_tcp_recv_segment — `drivers/scsi/iscsi_tcp.c`

```c
static int iscsi_sw_tcp_recv_segment(read_descriptor_t *rd_desc,
                                      struct sk_buff *skb,
                                      unsigned int offset,
                                      size_t len)
{
    struct iscsi_conn *conn = rd_desc->arg.data;
    struct iscsi_tcp_conn *tcp_conn = conn->dd_data;
    struct iscsi_segment *segment = &tcp_conn->in;
    unsigned int consumed = 0;
    int rc;

    if (conn->suspend_rx) {
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
        if (iscsi_tcp_segment_done(&tcp_conn->in, 1, rc)) {
            rc = iscsi_tcp_hdr_recv_done(tcp_conn, segment);
            if (rc) {
                /* PDU complete — process it */
                iscsi_conn_recv_pdu(conn);
            }
        }
    }

    return consumed;
}
```

---

## BHS receive and opcode dispatch — `drivers/scsi/libiscsi.c`

When the 48-byte BHS is fully received, `iscsi_tcp_hdr_recv_done()` passes it to libiscsi for
dispatch:

```c
static int iscsi_tcp_hdr_recv_done(struct iscsi_tcp_conn *tcp_conn,
                                    struct iscsi_segment *segment)
{
    struct iscsi_conn *conn = tcp_conn->iscsi_conn;
    struct iscsi_hdr *hdr   = tcp_conn->in_hdr;

    /* validate header digest if enabled */
    if (conn->hdrdgst_en) {
        /* compute CRC32C of the 48-byte BHS and compare */
        if (iscsi_verify_hdr_digest(tcp_conn, hdr))
            return ISCSI_ERR_HDR_DGST;
    }

    /* dispatch by opcode — libiscsi handles the PDU */
    return iscsi_tcp_recv_pdu(conn, hdr);
}
```

`iscsi_tcp_recv_pdu()` dispatches by opcode:

```c
int iscsi_tcp_recv_pdu(struct iscsi_conn *conn, struct iscsi_hdr *hdr)
{
    uint8_t opcode = hdr->opcode & ISCSI_OPCODE_MASK;

    switch (opcode) {
    case ISCSI_OP_SCSI_CMD_RSP:
        /*
         * SCSI Response PDU — command complete.
         * Contains SCSI status (GOOD, CHECK CONDITION, RESERVATION CONFLICT)
         * and optionally sense data.
         */
        return iscsi_scsi_cmd_rsp(conn, hdr);

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
         * AsyncEvent=1: request logout
         * AsyncEvent=2: drop connection
         * AsyncEvent=3: drop all connections and reconnect
         * Used in the target-side fencing approach (day 24/25).
         */
        return iscsi_async_msg_rsp(conn, hdr);

    case ISCSI_OP_REJECT:
        /* target rejected our PDU — protocol error */
        return iscsi_reject_rsp(conn, hdr);

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
static int iscsi_scsi_cmd_rsp(struct iscsi_conn *conn, struct iscsi_hdr *hdr)
{
    struct iscsi_cmd_rsp *rhdr = (struct iscsi_cmd_rsp *)hdr;
    struct iscsi_session *session = conn->session;
    struct iscsi_task *task;
    struct scsi_cmnd *sc;
    int senselen = 0;

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
     * This may unblock the TX thread if the window was closed.
     */
    iscsi_update_cmdsn(session, (struct iscsi_nopin *)hdr);

    /*
     * Update StatSN — must be exactly conn->exp_statsn.
     * If not, protocol error.
     */
    conn->exp_statsn = be32_to_cpu(rhdr->statsn) + 1;

    /*
     * Check for sense data (present when response = CHECK CONDITION).
     * Sense data immediately follows the Response PDU BHS in the
     * data segment (first 2 bytes = sense length, then sense data).
     */
    if (rhdr->response == ISCSI_STATUS_CMD_COMPLETED) {
        /*
         * Set the SCSI result in scsi_cmnd.
         * sc->result = (host_byte << 16) | status_byte
         *
         * rhdr->cmd_status is the SCSI status:
         *   0x00 = GOOD
         *   0x02 = CHECK CONDITION (with sense data in data segment)
         *   0x18 = RESERVATION CONFLICT
         *   0x28 = TASK SET FULL
         */
        sc->result = (DID_OK << 16) | rhdr->cmd_status;

        if (rhdr->cmd_status == SAM_STAT_CHECK_CONDITION) {
            /* parse sense data from the PDU data segment */
            uint16_t senselen_be;
            memcpy(&senselen_be, conn->data, 2);
            senselen = be16_to_cpu(senselen_be);

            if (senselen > SCSI_SENSE_BUFFERSIZE)
                senselen = SCSI_SENSE_BUFFERSIZE;

            memcpy(sc->sense_buffer,
                   conn->data + 2,    /* skip the 2-byte length field */
                   senselen);
            sc->sense_len = senselen;
        }
    } else {
        /* iSCSI-level failure (not SCSI status) */
        sc->result = DID_ERROR << 16;
    }

    /*
     * Complete the task — this calls sc->scsi_done(sc) which is
     * scsi_done() → scsi_io_completion() → scsi_decide_disposition()
     * (day 5).
     *
     * From here, RESERVATION CONFLICT flows:
     *   sc->result = DID_OK | SAM_STAT_RESERVATION_CONFLICT
     *   scsi_decide_disposition() → SUCCESS
     *   blk-mq completes the request
     *   scsi_execute_cmd() / sd_pr_reserve() gets the error
     */
    iscsi_complete_scsi_task(task, 0, 0);
    return 0;
}
```

---

## iscsi_complete_scsi_task — `drivers/scsi/libiscsi.c`

```c
static void iscsi_complete_scsi_task(struct iscsi_task *task,
                                      uint32_t exp_cmdsn,
                                      uint32_t max_cmdsn)
{
    struct iscsi_conn *conn = task->conn;
    struct scsi_cmnd *sc = task->sc;

    /* remove from taskqueue — no longer awaiting response */
    spin_lock_bh(&conn->taskqueuelock);
    list_del_init(&task->running);
    spin_unlock_bh(&conn->taskqueuelock);

    task->state = ISCSI_TASK_COMPLETED;

    /* return task to pool */
    iscsi_complete_task(task, ISCSI_TASK_COMPLETED);

    /*
     * Call the SCSI completion callback.
     * sc->scsi_done = scsi_done (set in scsi_dispatch_cmd, day 4).
     * For passthrough (PR): sc->scsi_done = scsi_complete (bypasses disposition).
     */
    if (sc) {
        sc->scsi_done(sc);  /* → scsi_io_completion() → disposition → app */
    }
}
```

---

## iscsi_data_in_rsp — handling read data — `drivers/scsi/libiscsi.c`

For READ commands, the target sends Data-In PDUs instead of (or before) the SCSI Response PDU:

```c
static int iscsi_data_in_rsp(struct iscsi_conn *conn, struct iscsi_hdr *hdr)
{
    struct iscsi_data *rhdr = (struct iscsi_data *)hdr;
    struct iscsi_task *task;
    struct scsi_cmnd *sc;

    task = iscsi_itt_to_ctask(conn, rhdr->itt);
    if (!task)
        return ISCSI_ERR_BAD_ITT;

    sc = task->sc;

    /*
     * The data segment following this BHS contains read data.
     * Copy it into sc's SGL at the offset specified by buffer_offset.
     *
     * iscsi_tcp handles this by setting up tcp_conn->in to receive
     * the data segment directly into the bio_vec pages — zero copy.
     */

    /* update expected DataSN */
    task->exp_datasn = be32_to_cpu(rhdr->datasn) + 1;

    /*
     * S-bit (Status bit): if set, SCSI status is piggybacked in this
     * Data-In PDU. No separate SCSI Response PDU will follow.
     * This saves one round-trip for reads.
     */
    if (rhdr->flags & ISCSI_FLAG_DATA_STATUS) {
        sc->result = (DID_OK << 16) | rhdr->cmd_status;
        iscsi_complete_scsi_task(task, 0, 0);
    }

    return 0;
}
```

Data-In PDUs write directly into the `scsi_cmnd`'s SGL pages via `iscsi_segment_seek_sg()` —
this is the read zero-copy path. No intermediate buffer.

---

## iscsi_r2t_rsp — R2T handling — `drivers/scsi/libiscsi.c`

When `InitialR2T=Yes`, the target sends R2T PDUs to grant permission to send write data:

```c
static int iscsi_r2t_rsp(struct iscsi_conn *conn, struct iscsi_hdr *hdr)
{
    struct iscsi_r2t_rsp *rhdr = (struct iscsi_r2t_rsp *)hdr;
    struct iscsi_task *task;
    struct r2t_info *r2t;

    task = iscsi_itt_to_ctask(conn, rhdr->itt);
    if (!task)
        return ISCSI_ERR_BAD_ITT;

    /*
     * Allocate an r2t_info to track this R2T.
     * Fields from the R2T PDU:
     *   r2t->data_offset = buffer offset to start sending from
     *   r2t->data_length = how many bytes to send in response
     *   r2t->ttt         = TargetTransferTag (must echo in Data-Out PDUs)
     */
    r2t = iscsi_pool_get(&task->r2t_pool);
    if (!r2t)
        return ISCSI_ERR_R2T_FAILURE;

    r2t->data_offset = be32_to_cpu(rhdr->data_offset);
    r2t->data_length = be32_to_cpu(rhdr->data_length);
    r2t->ttt         = rhdr->ttt;
    r2t->datasn      = 0;
    r2t->sent        = 0;

    task->r2t = r2t;

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
    │  tcp_read_sock() → iscsi_sw_tcp_recv_segment()
    ▼
iscsi_sw_tcp_recv_data()
    │  copies bytes into tcp_conn->in (iscsi_segment for BHS)
    │  segment->copied advances
    ▼
BHS fully received (48 bytes):
iscsi_tcp_hdr_recv_done()
    │  verify header digest (if enabled)
    ▼
iscsi_tcp_recv_pdu()
    │  opcode = ISCSI_OP_SCSI_CMD_RSP (0x21)
    ▼
iscsi_scsi_cmd_rsp()
    │  iscsi_itt_to_ctask() → find iscsi_task by ITT
    │  iscsi_update_cmdsn() → advance max_cmdsn window
    │  sc->result = DID_OK | cmd_status   e.g. 0x00000018 for RESERVATION CONFLICT
    │  if CHECK CONDITION: copy sense_buffer
    ▼
iscsi_complete_scsi_task()
    │  remove task from conn->taskqueue
    │  return task to pool (kfifo_in)
    │  sc->scsi_done(sc)
    ▼
scsi_done()                           [drivers/scsi/scsi_lib.c]
    │  blk_rq_is_passthrough? → yes (PR) → scsi_complete() directly
    │                           → no       → blk_complete_request() → softirq
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

- RX is driven by `sk_data_ready` socket callback — no polling kthread for iscsi_tcp.
- `tcp_read_sock()` + `iscsi_sw_tcp_recv_segment()` incrementally fills `iscsi_segment` structs
  for BHS, data, and digest — handles partial TCP delivery naturally via `segment->copied`.
- Opcode dispatch in `iscsi_tcp_recv_pdu()` routes to the appropriate handler.
- `iscsi_scsi_cmd_rsp()` finds the task by ITT, sets `sc->result`, copies sense data, and calls
  `sc->scsi_done(sc)` → re-enters the SCSI mid layer.
- For PR (passthrough): `sc->scsi_done` = `scsi_complete()` → bypasses `scsi_decide_disposition()`
  → wakes `blk_execute_rq()` immediately.
- For normal I/O: `scsi_decide_disposition()` routes by status:
  `RESERVATION CONFLICT` → SUCCESS, `NOT READY` → NEEDS_RETRY, `DID_NO_CONNECT` → FAILED.
- `iscsi_async_msg_rsp()` handles `ASYNC_MSG_REQUEST_LOGOUT` — this is the clean fencing signal.
- Data-In PDUs write directly into bio_vec pages — zero copy read path.
- R2T PDUs trigger solicited Data-Out by requeuing the task to the TX kthread.

---

## Previous / Next

[Day 10 — iscsi_tcp TX path](day10.md) | [Day 12 — session failure and EH interaction](day12.md)
