# Day 9 — iscsi_queuecommand path

**Week 2**: iSCSI Initiator Kernel Code
**Time**: 1–2 hours
**Reference**: `drivers/scsi/libiscsi.c`

---

## Overview

`iscsi_queuecommand()` is the LLD's `queuecommand()` — registered in `Scsi_Host_Template` and
called by `scsi_dispatch_cmd()` (day 4) after the SCSI mid layer builds the `scsi_cmnd`. It
allocates an `iscsi_task`, builds the iSCSI Command PDU BHS (Basic Header Segment), and queues
the task for the TX kthread. This is where a SCSI command becomes an iSCSI PDU.

---

## iscsi_queuecommand — `drivers/scsi/libiscsi.c`

```c
int iscsi_queuecommand(struct Scsi_Host *host, struct scsi_cmnd *sc)
{
    struct iscsi_cls_session *cls_session;
    struct iscsi_session *session;
    struct iscsi_conn *conn;
    struct iscsi_task *task;
    int reason = 0;

    cls_session = starget_to_session(scsi_target(sc->device));
    session = cls_session->dd_data;

    spin_lock_bh(&session->frwd_lock);

    /*
     * Gate 1: session state check.
     * If not LOGGED_IN, return an appropriate error code that tells
     * blk-mq whether to retry (DISRUPTED) or permanently fail (FAILFAST).
     */
    reason = iscsi_session_chkready(cls_session);
    if (reason) {
        sc->result = reason;
        goto fault;
    }

    /*
     * Gate 2: CmdSN window check.
     * If target has not advanced max_cmdsn enough, we cannot send more.
     * Return SCSI_MLQUEUE_TARGET_BUSY — blk-mq will retry this request
     * when the queue is kicked again (after next response arrives).
     */
    if (iscsi_cmd_win_closed(session)) {
        reason = SCSI_MLQUEUE_TARGET_BUSY;
        goto reject;
    }

    conn = session->leadconn;

    if (!conn || !iscsi_conn_is_active(conn)) {
        reason = SCSI_MLQUEUE_HOST_BUSY;
        goto reject;
    }

    /*
     * Gate 3: TX not suspended (EH in progress may suspend TX).
     */
    if (test_bit(ISCSI_SUSPEND_BIT, &conn->suspend_tx)) {
        reason = SCSI_MLQUEUE_HOST_BUSY;
        goto reject;
    }

    /*
     * Allocate an iscsi_task from the session's pre-allocated pool.
     * This is O(1) — pool uses a simple freelist.
     */
    task = iscsi_alloc_task(conn, sc);
    if (!task) {
        reason = SCSI_MLQUEUE_HOST_BUSY;
        goto reject;
    }

    /*
     * Build the 48-byte BHS for the SCSI Command PDU.
     * Fills in: opcode, flags, LUN, ITT, CmdSN, ExpStatSN, CDB, data_length.
     */
    if (!iscsi_prep_scsi_cmd_pdu(task)) {
        reason = SCSI_MLQUEUE_HOST_BUSY;
        goto prep_reject;
    }

    /*
     * Queue the task for the TX thread.
     * The TX kthread drains cmdqueue and sends the PDU.
     */
    iscsi_requeue_task(task);

    spin_unlock_bh(&session->frwd_lock);
    return 0;

prep_reject:
    iscsi_complete_task(task, ISCSI_TASK_REQUEUE_SCSIQ);
reject:
    spin_unlock_bh(&session->frwd_lock);
    return reason;

fault:
    spin_unlock_bh(&session->frwd_lock);
    sc->scsi_done(sc);   /* complete immediately with error */
    return 0;
}
EXPORT_SYMBOL_GPL(iscsi_queuecommand);
```

`SCSI_MLQUEUE_TARGET_BUSY` and `SCSI_MLQUEUE_HOST_BUSY` are NOT errors — they tell blk-mq to put
the request back on the software queue and retry dispatch later. The command is not failed.

`fault:` path is for permanent session failure — `sc->scsi_done(sc)` calls the completion
callback immediately, propagating the error up through `scsi_io_completion()` (day 5).

---

## iscsi_alloc_task — `drivers/scsi/libiscsi.c`

```c
static struct iscsi_task *iscsi_alloc_task(struct iscsi_conn *conn,
                                            struct scsi_cmnd *sc)
{
    struct iscsi_session *session = conn->session;
    struct iscsi_task *task;

    /*
     * Get a free task from the pool.
     * iscsi_pool_get() pops from the freelist — O(1), no allocation.
     */
    if (!kfifo_out(&session->cmdpool.queue,
                   (void **)&task, sizeof(void *)))
        return NULL;  /* pool empty — cmds_max in-flight already */

    sc->SCp.phase = session->age;   /* stamp current session age */
    sc->SCp.ptr   = (char *)task;   /* link scsi_cmnd → iscsi_task */

    refcount_set(&task->refcount, 1);
    task->state  = ISCSI_TASK_PENDING;
    task->conn   = conn;
    task->sc     = sc;
    task->have_checked_conn = false;

    /* link back for EH — task can find its scsi_cmnd */
    task->itt    = ISCSI_RESERVED_TAG;  /* not yet assigned */

    INIT_LIST_HEAD(&task->running);

    return task;
}
```

The pool is a `kfifo` of void pointers. `kfifo_out()` pops one without any locking beyond the
`frwd_lock` already held by the caller. Task pool exhaustion means `cmds_max` commands are
already in flight — the driver is at full depth.

---

## iscsi_prep_scsi_cmd_pdu — building the BHS — `drivers/scsi/libiscsi.c`

```c
static int iscsi_prep_scsi_cmd_pdu(struct iscsi_task *task)
{
    struct iscsi_conn    *conn    = task->conn;
    struct iscsi_session *session = conn->session;
    struct scsi_cmnd     *sc      = task->sc;

    /* hdr points to the 48-byte BHS in the task */
    struct iscsi_scsi_req *hdr =
        (struct iscsi_scsi_req *)task->hdr;

    unsigned hdrlength, transfer_length;

    tt = sc->sc_data_direction;

    memset(hdr, 0, sizeof(*hdr));

    /*
     * Opcode: always ISCSI_OP_SCSI_CMD for data commands.
     * Immediate bit NOT set — command goes through CmdSN ordering.
     */
    hdr->opcode = ISCSI_OP_SCSI_CMD;

    /*
     * Task attribute (from sc->device->simple_tags):
     *   ISCSI_ATTR_SIMPLE    (0x00) — most commands
     *   ISCSI_ATTR_ORDERED   (0x02) — ordered (e.g. WRITE SAME)
     *   ISCSI_ATTR_HEAD_OF_QUEUE (0x01) — EH passthrough
     *   ISCSI_ATTR_ACA       (0x04) — Auto Contingent Allegiance
     */
    hdr->flags = ISCSI_ATTR_SIMPLE;

    /*
     * Data direction flags embedded in the command PDU flags field.
     * These tell the target which direction data flows.
     */
    if (sc->sc_data_direction == DMA_TO_DEVICE) {
        hdr->flags |= ISCSI_FLAG_CMD_WRITE;
        /*
         * ImmediateData: can we piggyback write data in this PDU?
         * If session->imm_data_en=1 AND data_length <= first_burst,
         * we set the F-bit here and include data in the data segment.
         */
        if (session->imm_data_en) {
            hdr->flags |= ISCSI_FLAG_CMD_IMM_DATA_EN;
        }
        /*
         * InitialR2T=No: we can send unsolicited Data-Out PDUs
         * without waiting for R2T from the target.
         */
        if (!session->initial_r2t_en) {
            hdr->flags |= ISCSI_FLAG_CMD_UNSOL_DATA_EN;
        }
    } else if (sc->sc_data_direction == DMA_FROM_DEVICE) {
        hdr->flags |= ISCSI_FLAG_CMD_READ;
    }

    /* F-bit (Final): always set in the SCSI Command PDU itself */
    hdr->flags |= ISCSI_FLAG_CMD_FINAL;

    /*
     * LUN: packed into 8 bytes using SAM LUN format.
     * e.g. LUN 0 = 0x0000000000000000
     *      LUN 1 = 0x0001000000000000 (peripheral device addressing)
     */
    int_to_scsilun(sc->device->lun, &hdr->lun);

    /*
     * ITT: unique task identifier for this session.
     * Format: [age(8) | task_index(24)]
     * The target copies this into every response PDU.
     */
    task->itt = build_itt(task, session->age);
    hdr->itt  = task->itt;

    /*
     * CmdSN: command sequence number for this command.
     * Incremented after assigning (pre-increment for next command).
     * Immediate commands do NOT increment CmdSN.
     */
    hdr->cmdsn     = cpu_to_be32(session->cmdsn);
    session->cmdsn++;
    session->queued_cmdsn++;

    /*
     * ExpStatSN: tell target what StatSN we've received so far.
     * Target uses this to know which responses we've acknowledged.
     */
    hdr->exp_statsn = cpu_to_be32(conn->exp_statsn);

    /*
     * Data length: total bytes to transfer (in 32-bit big-endian).
     * For reads: this is how many bytes we want back.
     * For writes: total write data length.
     */
    transfer_length = scsi_transfer_length(sc);
    hdr->data_length = cpu_to_be32(transfer_length);

    /*
     * CDB: copy directly from scsi_cmnd.
     * cmd_len is 6, 10, 12, 16, or 32 depending on command type.
     * e.g. READ(10): 10 bytes, WRITE(16): 16 bytes
     */
    hdr->cdb_len = sc->cmd_len;
    BUG_ON(sc->cmd_len > sizeof(hdr->cdb));
    memcpy(hdr->cdb, sc->cmnd, sc->cmd_len);

    /*
     * Calculate immediate data count.
     * We can send min(transfer_length, first_burst, max_xmit_dlength)
     * bytes piggybacked in the Command PDU data segment.
     *
     * If imm_data_en=0 or this is a read, imm_count = 0.
     */
    task->imm_count = 0;
    if (sc->sc_data_direction == DMA_TO_DEVICE &&
        session->imm_data_en) {
        task->imm_count = min3(transfer_length,
                               conn->max_xmit_dlength,
                               session->first_burst);
    }

    /*
     * Unsolicited Data-Out tracking.
     * If InitialR2T=No, we can send up to first_burst bytes
     * as unsolicited Data-Out PDUs after the Command PDU.
     * unsol_r2t tracks how many unsolicited bytes remain to send.
     */
    task->unsol_r2t = 0;
    if (sc->sc_data_direction == DMA_TO_DEVICE &&
        !session->initial_r2t_en) {
        task->unsol_r2t = min(transfer_length, session->first_burst)
                        - task->imm_count;
    }

    /*
     * Point task->sdb to the scsi_cmnd's scatter-gather buffer.
     * The TX path reads this SGL to build Data-Out PDU data segments.
     */
    task->sdb = scsi_out(sc);

    return 1; /* success */
}
```

### The BHS wire layout (48 bytes)

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|0|  Opcode(0x01)|F|R|W| ATTR  |            Reserved            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|TotalAHSLength |       DataSegmentLength (3 bytes big-endian)  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
+                          LUN (8 bytes)                        +
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        ITT (4 bytes)                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                   Expected Data Transfer Length               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           CmdSN                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           ExpStatSN                           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
+                          CDB (16 bytes)                       +
|                                                               |
|                                                               |
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

Opcode = `0x01` (ISCSI_OP_SCSI_CMD). The Immediate bit (bit 6 of byte 0) is NOT set for normal
commands — they carry a CmdSN and go through ordering. Management PDUs (NOP-Out, TMF) often set
the Immediate bit so they skip CmdSN ordering and go out on the wire ASAP.

---

## iscsi_requeue_task — queuing for TX

```c
void iscsi_requeue_task(struct iscsi_task *task)
{
    struct iscsi_conn *conn = task->conn;

    /*
     * Add to conn->requeue (highest priority within data commands).
     * TX thread drains: mgmtqueue → requeue → cmdqueue.
     */
    spin_lock_bh(&conn->taskqueuelock);
    if (list_empty(&task->running)) {
        kref_get(&task->refcount);
        list_add_tail(&task->running, &conn->requeue);
    }
    spin_unlock_bh(&conn->taskqueuelock);

    /* wake the TX kthread */
    iscsi_conn_queue_xmit(conn);
}

static inline void iscsi_conn_queue_xmit(struct iscsi_conn *conn)
{
    struct iscsi_cls_conn *cls_conn = conn->cls_conn;
    if (cls_conn && cls_conn->transport->xmit_task)
        cls_conn->transport->xmit_task(conn);  /* for iscsi_tcp: wake TX kthread */
}
```

---

## Full call chain from scsi_dispatch_cmd to PDU queued

```
scsi_dispatch_cmd(cmd)                    [drivers/scsi/scsi_lib.c]
    │  cmd->scsi_done = scsi_done
    │  host->hostt->queuecommand(host, cmd)
    ▼
iscsi_queuecommand(host, sc)              [drivers/scsi/libiscsi.c]
    │  iscsi_session_chkready()           gate 1: session state
    │  iscsi_cmd_win_closed()             gate 2: CmdSN window
    │  iscsi_alloc_task()                 pool alloc, link sc↔task
    │  iscsi_prep_scsi_cmd_pdu()          build 48-byte BHS
    │  iscsi_requeue_task()               put on conn->requeue
    │  iscsi_conn_queue_xmit()            wake TX kthread
    ▼
iscsi_xmit_task() / TX kthread            [drivers/scsi/iscsi_tcp.c]  (day 10)
    │  sends BHS over TCP socket
    │  sends immediate data (if any)
    │  sends unsolicited Data-Out PDUs (if InitialR2T=No)
    ▼
TCP wire → target
```

---

## Key takeaways

- `iscsi_queuecommand()` has three gates: session state, CmdSN window, TX suspended.
  If any gate fails: `MLQUEUE_*_BUSY` → blk-mq retries, OR `fault:` → immediate error.
- `iscsi_alloc_task()` pops from the task pool kfifo — O(1), no dynamic allocation.
- `iscsi_prep_scsi_cmd_pdu()` fills every field of the 48-byte BHS:
  - `opcode = 0x01`, `flags` (R/W/F bits, task attr), `lun`, `itt`, `cmdsn`, `exp_statsn`,
    `data_length`, `cdb[]`.
- ITT = `(session->age << 24) | task_index` — session age prevents cross-session response matches.
- `imm_count` = bytes piggybacked in Command PDU (ImmediateData=Yes path).
- `unsol_r2t` = bytes sendable as unsolicited Data-Out (InitialR2T=No path).
- These two fields directly control which of the five write paths `iscsit_process_scsi_cmd()`
  takes on the target side (day 18).
- After `iscsi_requeue_task()`, the TX kthread wakes and sends the PDU over TCP.

---

## Previous / Next

[Day 8 — libiscsi session and connection structs](day08.md) | [Day 10 — iscsi_tcp TX path](day10.md)
