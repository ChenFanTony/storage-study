# Day 9 — iscsi_queuecommand path

**Week 2**: iSCSI Initiator Kernel Code  
**Time**: 1–2 hours  
**Reference**: `drivers/scsi/libiscsi.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

`iscsi_queuecommand()` is the LLD's `queuecommand()` — registered in `Scsi_Host_Template` and
called by `scsi_dispatch_cmd()` (day 4) after the SCSI mid layer builds the `scsi_cmnd`. It
allocates an `iscsi_task`, builds the iSCSI Command PDU BHS (Basic Header Segment), and queues
the task for the TX worker. This is where a SCSI command becomes an iSCSI PDU.

---

## iscsi_queuecommand — `drivers/scsi/libiscsi.c`

```c
/* Simplified — see drivers/scsi/libiscsi.c for the actual implementation. */
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
     * This is O(1) — pool uses a simple kfifo of free indices.
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
     * Queue the task and wake the TX worker.
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
    scsi_done(sc);   /* complete immediately with error */
    return 0;
}
EXPORT_SYMBOL_GPL(iscsi_queuecommand);
```

`SCSI_MLQUEUE_TARGET_BUSY` and `SCSI_MLQUEUE_HOST_BUSY` are NOT errors — they tell blk-mq to put
the request back on the software queue and retry dispatch later. The command is not failed.

`fault:` path is for permanent session failure — calls the global `scsi_done(sc)` helper, which
re-enters the SCSI mid layer at `scsi_io_completion()` (day 5).

---

## iscsi_alloc_task — `drivers/scsi/libiscsi.c`

```c
/* Simplified. Real implementation manages the kfifo via libiscsi pool helpers. */
static struct iscsi_task *iscsi_alloc_task(struct iscsi_conn *conn,
                                            struct scsi_cmnd *sc)
{
    struct iscsi_session *session = conn->session;
    struct iscsi_task *task;

    /*
     * Pop a free task index from the cmdpool kfifo.
     * O(1), no dynamic allocation.
     */
    if (!__kfifo_out(&session->cmdpool.queue,
                     (void *)&task, sizeof(void *)))
        return NULL;  /* pool empty — cmds_max in-flight already */

    /*
     * Stamp the current session age into the per-command private area.
     * EH later checks this against session->age — if the session has
     * reconnected since this command was allocated (age incremented),
     * the command is treated as already gone. This is the modern
     * replacement for sc->SCp.phase, which was removed in v6.2.
     */
    iscsi_cmd(sc)->age  = session->age;
    iscsi_cmd(sc)->task = task;

    kref_init(&task->refcount);
    task->state  = ISCSI_TASK_PENDING;
    task->conn   = conn;
    task->sc     = sc;

    /*
     * task->itt was set when this slot was added to the pool, computed
     * from session->age and a per-task index using ISCSI_AGE_SHIFT and
     * ISCSI_ITT_MASK. The pool gives stable indices, so itt persists
     * across alloc/free cycles for the same slot (with age bumping each
     * reconnect).
     */

    INIT_LIST_HEAD(&task->running);

    return task;
}
```

The pool is a `kfifo` of pointers / indices managed by `iscsi_pool_init()` /
`iscsi_pool_free()`. Pool exhaustion means `cmds_max` commands are already in flight — the driver
is at full depth.

---

## iscsi_prep_scsi_cmd_pdu — building the BHS — `drivers/scsi/libiscsi.c`

```c
/* Simplified — see libiscsi.c for the full implementation. */
static int iscsi_prep_scsi_cmd_pdu(struct iscsi_task *task)
{
    struct iscsi_conn    *conn    = task->conn;
    struct iscsi_session *session = conn->session;
    struct scsi_cmnd     *sc      = task->sc;

    /* hdr points to the 48-byte BHS in the task */
    struct iscsi_scsi_req *hdr =
        (struct iscsi_scsi_req *)task->hdr;

    unsigned transfer_length;

    memset(hdr, 0, sizeof(*hdr));

    /*
     * Opcode: always ISCSI_OP_SCSI_CMD for data commands.
     * Immediate bit NOT set — command goes through CmdSN ordering.
     */
    hdr->opcode = ISCSI_OP_SCSI_CMD;

    /*
     * Task attribute (RFC 7143 §11.2.2):
     *   ISCSI_ATTR_UNTAGGED          0x00
     *   ISCSI_ATTR_SIMPLE            0x01
     *   ISCSI_ATTR_ORDERED           0x02
     *   ISCSI_ATTR_HEAD_OF_QUEUE     0x03
     *   ISCSI_ATTR_ACA               0x04
     */
    hdr->flags = ISCSI_ATTR_SIMPLE;

    /*
     * Direction flags in the Command PDU flags field tell the target
     * which way data flows.
     */
    if (sc->sc_data_direction == DMA_TO_DEVICE) {
        hdr->flags |= ISCSI_FLAG_CMD_WRITE;
    } else if (sc->sc_data_direction == DMA_FROM_DEVICE) {
        hdr->flags |= ISCSI_FLAG_CMD_READ;
    }

    /* F-bit (Final): always set in the SCSI Command PDU itself */
    hdr->flags |= ISCSI_FLAG_CMD_FINAL;

    /*
     * LUN: packed into 8 bytes using SAM LUN format.
     */
    int_to_scsilun(sc->device->lun, &hdr->lun);

    /*
     * ITT: unique task identifier for this session.
     * Layout: [age : ISCSI_AGE_MASK bits | task_index : remainder]
     * (4 bits of age in current libiscsi.) Built by build_itt()
     * which uses ISCSI_AGE_SHIFT and ISCSI_ITT_MASK.
     */
    task->itt = build_itt(task->itt, session->age);
    hdr->itt  = task->itt;

    /*
     * CmdSN: command sequence number for this command.
     * Incremented after assigning. Immediate commands do NOT increment CmdSN.
     */
    hdr->cmdsn     = cpu_to_be32(session->cmdsn);
    session->cmdsn++;
    session->queued_cmdsn = session->cmdsn;

    /*
     * ExpStatSN: tell target what StatSN we've received so far.
     */
    hdr->exp_statsn = cpu_to_be32(conn->exp_statsn);

    /*
     * Data length: total bytes to transfer (32-bit big-endian).
     */
    transfer_length = scsi_transfer_length(sc);
    hdr->data_length = cpu_to_be32(transfer_length);

    /*
     * CDB: copy directly from scsi_cmnd. The iSCSI BHS holds 16 bytes
     * of CDB inline. CDBs longer than 16 bytes (e.g. CDB32) are carried
     * in an Additional Header Segment (AHS) per RFC 7143 §10.2.1 — the
     * iSCSI Command PDU itself has no `cdb_len` field.
     */
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
        hdr->flags |= ISCSI_FLAG_CMD_IMM_DATA_EN;
        task->imm_count = min3(transfer_length,
                               (unsigned)conn->max_xmit_dlength,
                               (unsigned)session->first_burst);
    }

    /*
     * Unsolicited Data-Out tracking.
     * If InitialR2T=No, we can send up to first_burst bytes
     * as unsolicited Data-Out PDUs after the Command PDU.
     */
    task->unsol_r2t = 0;
    if (sc->sc_data_direction == DMA_TO_DEVICE &&
        !session->initial_r2t_en) {
        hdr->flags |= ISCSI_FLAG_CMD_UNSOL_DATA_EN;
        task->unsol_r2t = min(transfer_length, (unsigned)session->first_burst)
                        - task->imm_count;
    }

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

CDBs longer than 16 bytes (rare — mostly 32-byte VARIABLE LENGTH CDB) are carried in a separate
AHS; `TotalAHSLength` advertises the AHS bytes that follow the BHS.

---

## iscsi_requeue_task — queuing for TX

```c
void iscsi_requeue_task(struct iscsi_task *task)
{
    struct iscsi_conn *conn = task->conn;

    /*
     * Add to conn->requeue list.
     * TX worker drains: mgmtqueue → requeue → cmdqueue.
     */
    spin_lock_bh(&conn->taskqueuelock);
    if (list_empty(&task->running)) {
        kref_get(&task->refcount);
        list_add_tail(&task->running, &conn->requeue);
    }
    spin_unlock_bh(&conn->taskqueuelock);

    /*
     * Schedule the TX work item. In modern libiscsi this is queued on
     * a workqueue, not signalled to a kthread.
     */
    iscsi_conn_queue_work(conn);
}
```

`iscsi_conn_queue_work()` calls `queue_work()` on the iscsi workqueue (or transport-specific
queue). The TX worker (`iscsi_xmitworker`) runs and drains the lists in priority order (day 10).

---

## Full call chain from scsi_dispatch_cmd to PDU queued

```
scsi_dispatch_cmd(cmd)                    [drivers/scsi/scsi_lib.c]
    │  host->hostt->queuecommand(host, cmd)
    ▼
iscsi_queuecommand(host, sc)              [drivers/scsi/libiscsi.c]
    │  iscsi_session_chkready()           gate 1: session state
    │  iscsi_cmd_win_closed()             gate 2: CmdSN window
    │  iscsi_alloc_task()                 pool alloc, age stamp via iscsi_cmd()
    │  iscsi_prep_scsi_cmd_pdu()          build 48-byte BHS
    │  iscsi_requeue_task()               put on conn->requeue
    │  iscsi_conn_queue_work()            schedule TX worker
    ▼
iscsi_xmitworker()                        [drivers/scsi/iscsi_tcp.c]  (day 10)
    │  sends BHS over TCP socket
    │  sends immediate data (if any)
    │  sends unsolicited Data-Out PDUs (if InitialR2T=No)
    ▼
TCP wire → target
```

---

## Key takeaways

- `iscsi_queuecommand()` has three gates: session state, CmdSN window, TX suspended.
  If any gate fails: `MLQUEUE_*_BUSY` → blk-mq retries, OR `fault:` → immediate error via
  `scsi_done()`.
- `iscsi_alloc_task()` pops from the task pool kfifo — O(1), no dynamic allocation. The session
  age is stamped into the SCSI command's private area (`iscsi_cmd(sc)`) for EH safety.
- `iscsi_prep_scsi_cmd_pdu()` fills every field of the 48-byte BHS:
  - `opcode = 0x01`, `flags` (R/W/F bits, task attr), `lun`, `itt`, `cmdsn`, `exp_statsn`,
    `data_length`, `cdb[]`.
- The iSCSI BHS holds 16 bytes of CDB inline; longer CDBs use AHS. There is no per-command
  `cdb_len` field in the BHS itself.
- ITT layout: `(session->age << ISCSI_AGE_SHIFT) | (task_index & ISCSI_ITT_MASK)` — session age
  in the high bits prevents cross-session response matches.
- `imm_count` = bytes piggybacked in Command PDU (ImmediateData=Yes path).
- `unsol_r2t` = bytes sendable as unsolicited Data-Out (InitialR2T=No path).
- These two fields directly control which of the five write paths `iscsit_process_scsi_cmd()`
  takes on the target side (day 18).
- After `iscsi_requeue_task()`, the TX worker is scheduled and sends the PDU over TCP.

---

## Previous / Next

[Day 8 — libiscsi session and connection structs](day08.md) | [Day 10 — iscsi_tcp TX path](day10.md)
