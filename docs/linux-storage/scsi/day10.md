# Day 10 — iscsi_tcp TX path

**Week 2**: iSCSI Initiator Kernel Code
**Time**: 1–2 hours
**Reference**: `drivers/scsi/iscsi_tcp.c`, `drivers/scsi/libiscsi_tcp.c`

---

## Overview

The TX path converts an `iscsi_task` (with its BHS and SGL) into bytes on a TCP socket. It runs
in a dedicated kthread per connection. The key challenge is that a single iSCSI PDU may span many
TCP segments (MSS ~64 KB typically), and the TX must be restartable — if the socket send buffer
is full, the kthread must save state and resume exactly where it left off on the next wakeup.

---

## Architecture: two layers

```
libiscsi (transport-agnostic)        iscsi_tcp (TCP-specific)
─────────────────────────────        ────────────────────────
iscsi_conn_send_pdu()           →    iscsi_sw_tcp_send_hdr()
iscsi_tcp_task_xmit()           →    iscsi_sw_tcp_xmit_segment()
iscsi_segment_seek_sg()              kernel_sendmsg() / kernel_sendpage()
```

`libiscsi_tcp.c` contains transport-agnostic TCP framing logic (segment management, SGL walking).
`iscsi_tcp.c` contains the socket-specific send/receive calls and the TX/RX kthreads.

---

## struct iscsi_tcp_conn — `drivers/scsi/iscsi_tcp.c`

The LLD-private data for a connection (stored in `conn->dd_data`):

```c
struct iscsi_tcp_conn {
    struct iscsi_conn       *iscsi_conn;  /* back-pointer to libiscsi conn */
    struct socket           *sock;        /* the TCP socket */

    /* TX state — tracks partial send progress */
    struct iscsi_segment    out;          /* current outgoing segment */

    /* RX state — tracks partial receive progress */
    struct iscsi_segment    in;           /* current incoming segment */
    int                     in_progress;  /* ISCSI_TCP_*_STATE */

    /* recv buffer for BHS */
    struct iscsi_hdr        hdr;          /* staged BHS buffer */
    char                    hdrext[4*ISCSI_ECRC_LEN]; /* AHS + digest */

    /* socket callbacks (saved originals) */
    void                    (*old_write_space)(struct sock *);
    void                    (*old_state_change)(struct sock *);
    void                    (*old_data_ready)(struct sock *);
    void                    (*old_error_report)(struct sock *);
};
```

---

## struct iscsi_segment — `drivers/scsi/libiscsi_tcp.h`

The segment is the fundamental TX/RX unit. It points to a region of memory (BHS, data, digest)
and tracks how far the send/receive has progressed:

```c
struct iscsi_segment {
    unsigned char           *data;        /* pointer to buffer (BHS or digest) */
    unsigned int            size;         /* total bytes in this segment */
    unsigned int            copied;       /* bytes already sent/received */

    /*
     * For data segments: instead of a flat buffer, segment may walk an SGL.
     * sg/sg_offset track position in the scsi_cmnd's bio_vec list.
     */
    struct scatterlist      *sg;          /* current SGL entry */
    unsigned int            sg_offset;   /* offset within current sg entry */
    unsigned int            sg_mapped;   /* bytes mapped from current sg */

    /* digest (CRC32C if DataDigest=CRC32C) */
    struct hash_desc        *hash;
    unsigned char           recv_digest[ISCSI_DIGEST_SIZE]; /* received digest */
    unsigned char           digest[ISCSI_DIGEST_SIZE];      /* computed digest */
    bool                    digest_len;   /* digest present? */
};
```

`copied` is the restart point. If `kernel_sendmsg()` sends only part of the segment (socket send
buffer full), the TX kthread saves `copied` and resumes from there on next wakeup.

---

## TX kthread — `drivers/scsi/iscsi_tcp.c`

```c
static int iscsi_sw_tcp_pdu_xmit(struct iscsi_task *task)
{
    struct iscsi_conn *conn = task->conn;
    unsigned int noreclaim_flag;
    struct iscsi_tcp_conn *tcp_conn = conn->dd_data;
    int rc = 0;

    noreclaim_flag = memalloc_noreclaim_save();

    /*
     * Send the PDU header (BHS + optional AHS).
     * This is always first — target cannot process data without header.
     */
    while (!iscsi_tcp_xmit_queuelen(conn)) {
        rc = iscsi_sw_tcp_xmit_segment(tcp_conn, &tcp_conn->out);
        if (rc < 0)
            goto done;

        if (rc > 0) {
            /* partial send — socket full, stop and retry on next wakeup */
            rc = -EAGAIN;
            goto done;
        }
        /* rc = 0: segment fully sent, move to next */
        break;
    }

done:
    memalloc_noreclaim_restore(noreclaim_flag);
    return rc;
}
```

The TX kthread loop in `iscsi_xmitworker()`:

```c
static void iscsi_xmitworker(struct work_struct *work)
{
    struct iscsi_conn *conn =
        container_of(work, struct iscsi_conn, xmitwork);
    struct iscsi_task *task;
    int rc;

    /*
     * Drain in priority order:
     *   1. mgmtqueue (NOP-Out, TMF, Logout)
     *   2. requeue   (commands being retried)
     *   3. cmdqueue  (normal SCSI commands)
     */
    for (;;) {
        task = iscsi_conn_get_task(conn);
        if (!task)
            break;

        rc = iscsi_xmit_task(conn, task);
        if (rc) {
            if (rc == -EAGAIN) {
                /* socket full — reschedule when write_space fires */
                break;
            }
            /* fatal send error */
            iscsi_conn_failure(conn, ISCSI_ERR_XMIT_FAILED);
            break;
        }
    }
}
```

`iscsi_conn_get_task()` pops from queues in priority order:

```c
static struct iscsi_task *iscsi_conn_get_task(struct iscsi_conn *conn)
{
    struct iscsi_task *task;

    spin_lock_bh(&conn->taskqueuelock);

    /* mgmtqueue first — NOP and TMF always go before data */
    task = list_first_entry_or_null(&conn->mgmtqueue,
                                     struct iscsi_task, running);
    if (task) {
        list_del_init(&task->running);
        goto out;
    }

    /* requeue next — commands being resent after partial send */
    task = list_first_entry_or_null(&conn->requeue,
                                     struct iscsi_task, running);
    if (task) {
        list_del_init(&task->running);
        goto out;
    }

    /* cmdqueue last — normal SCSI commands */
    task = list_first_entry_or_null(&conn->cmdqueue,
                                     struct iscsi_task, running);
    if (task)
        list_del_init(&task->running);

out:
    spin_unlock_bh(&conn->taskqueuelock);
    return task;
}
```

---

## iscsi_xmit_task — sending one task's PDUs — `drivers/scsi/libiscsi.c`

```c
static int iscsi_xmit_task(struct iscsi_conn *conn,
                             struct iscsi_task *task, bool was_requeued)
{
    int rc;

    /* hand to LLD transport to do the actual socket write */
    rc = conn->session->tt->xmit_task(task);

    if (rc == -EAGAIN) {
        /*
         * Partial send — socket buffer full.
         * Put task back on requeue list, stop TX.
         * write_space() callback will re-schedule the TX worker.
         */
        iscsi_requeue_task(task);
        return -EAGAIN;
    }

    if (!rc) {
        /*
         * Task fully transmitted.
         * Move to conn->taskqueue (awaiting response from target).
         */
        spin_lock_bh(&conn->taskqueuelock);
        list_add_tail(&task->running, &conn->taskqueue);
        task->state = ISCSI_TASK_RUNNING;
        spin_unlock_bh(&conn->taskqueuelock);
    }

    return rc;
}
```

For `iscsi_tcp`, `tt->xmit_task` = `iscsi_tcp_task_xmit()`:

```c
static int iscsi_tcp_task_xmit(struct iscsi_task *task)
{
    struct iscsi_conn *conn = task->conn;
    struct iscsi_tcp_task *tcp_task = task->dd_data;
    int rc = 0;

    /*
     * Three phases per task:
     *   Phase 1: Send the PDU header (BHS)
     *   Phase 2: Send immediate data (if any — piggybacked in Command PDU)
     *   Phase 3: Send unsolicited Data-Out PDUs (if InitialR2T=No)
     */

    /* Phase 1: BHS */
    if (task->hdr_len) {
        rc = iscsi_tcp_send_hdr(conn, task);
        if (rc)
            return rc;
    }

    /* Phase 2: immediate data in Command PDU data segment */
    if (task->imm_count) {
        rc = iscsi_tcp_send_data_in_pdu(conn, task);
        if (rc)
            return rc;
    }

    /* Phase 3: unsolicited Data-Out PDUs */
    while (task->unsol_r2t > 0) {
        rc = iscsi_tcp_send_unsolicited_data_out(conn, task);
        if (rc)
            return rc;
    }

    return 0; /* all data for this task has been queued to socket */
}
```

---

## iscsi_sw_tcp_xmit_segment — `drivers/scsi/iscsi_tcp.c`

The lowest-level send function. Writes bytes from a `iscsi_segment` into the TCP socket.

```c
static int iscsi_sw_tcp_xmit_segment(struct iscsi_tcp_conn *tcp_conn,
                                      struct iscsi_segment *segment)
{
    unsigned int copied = 0;
    int r = 0;

    while (!iscsi_tcp_segment_done(segment, 0, r)) {
        struct msghdr msg = { .msg_flags = MSG_DONTWAIT | MSG_NOSIGNAL };
        struct kvec iov;

        /* get a slice of the current segment to send */
        iscsi_tcp_segment_map(segment, 0);

        iov.iov_base = segment->sg_mapped + segment->sg_offset;
        iov.iov_len  = min(segment->size - segment->copied,
                           segment->sg_mapped - segment->sg_offset);

        /*
         * kernel_sendmsg() writes to the TCP socket.
         * May return less than requested if socket send buffer is full.
         * MSG_DONTWAIT: non-blocking — returns -EAGAIN if would block.
         */
        r = kernel_sendmsg(tcp_conn->sock, &msg, &iov, 1, iov.iov_len);

        if (r > 0) {
            segment->copied += r;
            copied += r;
        } else if (r == -EAGAIN) {
            /* socket full — stop, save state, return partial */
            return 1;  /* caller will requeue task */
        } else {
            /* error */
            return r;
        }
    }

    return 0; /* segment fully sent */
}
```

`iscsi_tcp_segment_done()` checks if `segment->copied >= segment->size`. If not, it advances
`segment->sg` and `segment->sg_offset` to point to the next piece of the SGL. This is how the
TX path walks the bio_vec SGL from the `scsi_cmnd` without copying data.

---

## write_space callback — restart after socket-full

When `kernel_sendmsg()` returns `-EAGAIN`, the TX kthread puts the task back on `conn->requeue`
and stops. It restarts when the socket's send buffer drains:

```c
static void iscsi_write_space(struct sock *sk)
{
    struct iscsi_conn *conn = sk->sk_user_data;
    struct iscsi_tcp_conn *tcp_conn = conn->dd_data;

    /* call original write_space first (wakes select/poll waiters) */
    tcp_conn->old_write_space(sk);

    ISCSI_DBG_TCP(conn, "iscsi_write_space\n");

    /* re-schedule the TX worker — socket has space again */
    iscsi_conn_queue_xmit(conn);
}
```

This callback is registered on the socket via `sk->sk_write_space = iscsi_write_space` during
`iscsi_conn_set_callbacks()`. It ensures the TX kthread resumes exactly when socket space is
available — no polling, no spinning.

---

## Data-Out PDU structure

For a 1 MB write with `MaxXmitDataSegmentLength = 262144` (256 KB):

```
Wire order:

[SCSI Command PDU]                  48-byte BHS
  opcode=0x01, W=1, F=1
  data_length=1MB, CDB=WRITE(16)
  ITT=0x01000042, CmdSN=100
  DataSegmentLength = 0 (no immediate data if ImmediateData=No)

[Data-Out PDU #0]                   48-byte BHS + 256KB data
  opcode=0x05
  ITT=0x01000042 (same ITT, links to command)
  TargetTransferTag = TTT from R2T (if solicited)
  DataSN=0
  BufferOffset=0
  DataSegmentLength=262144
  F=0 (not final)

[Data-Out PDU #1]                   48-byte BHS + 256KB data
  DataSN=1, BufferOffset=262144, F=0

[Data-Out PDU #2]
  DataSN=2, BufferOffset=524288, F=0

[Data-Out PDU #3]                   last one
  DataSN=3, BufferOffset=786432
  DataSegmentLength=262144
  F=1  ← Final bit set
        ← iscsit_check_dataout_payload() sets ICF_GOT_LAST_DATAOUT
        ← target_execute_cmd() called → backend I/O begins
```

The `F=1` on the last Data-Out PDU is what the target's `iscsit_decide_dataout_action()` watches
for, together with `write_data_done == data_length`, to call `target_submit_cmd()` (day 18).

---

## Key takeaways

- TX runs in a dedicated kthread per connection (`iscsi_xmitworker`), dispatched as a work item.
- Queue priority: mgmtqueue (NOP/TMF) → requeue (partial) → cmdqueue (new commands).
- `iscsi_tcp_task_xmit()` sends in three phases: BHS → immediate data → unsolicited Data-Out.
- `iscsi_sw_tcp_xmit_segment()` calls `kernel_sendmsg()` which may return partial writes.
  On partial: save state via `segment->copied`, return `-EAGAIN`, put task on requeue.
- `write_space` socket callback re-schedules the TX worker when socket buffer drains.
- The SGL (`bio_vec` from `scsi_cmnd->sdb`) is walked directly — no data copying.
- `F=1` in the last Data-Out PDU BHS is the signal the target uses to know all data arrived.
- `DataSegmentLength` is bounded by `min(MaxXmitDataSegmentLength, remaining_data)`.

---

## Previous / Next

[Day 9 — iscsi_queuecommand path](day09.md) | [Day 11 — iscsi_tcp RX path](day11.md)
