# Day 8 — libiscsi session and connection structs

**Week 2**: iSCSI Initiator Kernel Code
**Time**: 1–2 hours
**Reference**: `include/scsi/libiscsi.h`, `drivers/scsi/libiscsi.c`

---

## Overview

`libiscsi` is the kernel library implementing the iSCSI initiator protocol, shared by all iSCSI
transport drivers (`iscsi_tcp`, `ib_iser`, `cxgb4i`). It owns the session and connection state
machines, command queueing, CmdSN window management, and error recovery. Every function in week 2
works with these structs — know them before reading any iSCSI command path code.

---

## struct iscsi_session — `include/scsi/libiscsi.h`

```c
struct iscsi_session {
    struct iscsi_cls_session    *cls_session;   /* transport class wrapper */

    /*
     * Session parameters — negotiated during Login phase.
     * These directly control the five write data-flow paths on the target
     * (day 18). They are stored here after login negotiation and referenced
     * by iscsi_prep_scsi_cmd_pdu() when building Command PDU headers.
     */
    int                         initial_r2t_en;   /* InitialR2T=Yes(1) / No(0) */
    int                         imm_data_en;      /* ImmediateData=Yes(1) / No(0) */
    unsigned                    first_burst;      /* FirstBurstLength in bytes */
    unsigned                    max_burst;        /* MaxBurstLength in bytes */
    unsigned                    max_r2t;          /* MaxOutstandingR2T */
    int                         pdu_inorder_en;   /* DataPDUInOrder */
    int                         dataseq_inorder_en;/* DataSequenceInOrder */

    /*
     * CmdSN window — prevents initiator from overwhelming target.
     * Initiator may send CmdSN in range [exp_cmdsn, max_cmdsn].
     * Target advances max_cmdsn in every response (StatSN/ExpCmdSN field).
     * If window is closed (queued_cmdsn >= max_cmdsn), TX thread blocks.
     */
    __u32                       cmdsn;         /* next CmdSN to assign */
    __u32                       exp_cmdsn;     /* CmdSN we expect from target */
    __u32                       max_cmdsn;     /* upper CmdSN limit from target */
    __u32                       queued_cmdsn;  /* CmdSN assigned but not yet sent */

    /*
     * Task pool — pre-allocated iscsi_task structs.
     * Index into cmds[] is embedded in the ITT (lower 24 bits).
     * Pool size = cmds_max (typically 128 or 256).
     */
    struct iscsi_task           **cmds;
    int                         cmds_max;

    /* task pool management */
    struct iscsi_pool           cmdpool;

    /* locks — two-lock design to avoid deadlock between TX and RX paths */
    spinlock_t                  frwd_lock;  /* TX side: CmdSN, cmd queues */
    spinlock_t                  back_lock;  /* RX side: task completion */

    /* connections — one in single-connection sessions */
    struct list_head            connections;
    struct iscsi_conn           *leadconn;  /* primary connection */

    /*
     * State machine.
     * LOGGED_IN → normal operation
     * FAILED    → connection dropped, recovery in progress
     * RECOVERY_FAILED → replacement_timeout expired
     */
    int                         state;
    int                         age;        /* incremented each reconnect */
                                            /* packed into high 8 bits of ITT */

    /*
     * Recovery timeout.
     * After session drop, libiscsi waits up to replacement_timeout seconds
     * for reconnect before declaring the session dead.
     * Default: 120 seconds (ISCSI_DEF_REPLACEMENT_TMOUT).
     * During this window, commands are HELD — not failed.
     * After timeout: all commands get DID_TRANSPORT_FAILFAST.
     */
    int                         recovery_tmo;
    struct delayed_work         recovery_work; /* fires at recovery_tmo */

    struct mutex                eh_mutex;    /* serializes EH calls */

    /* Scsi_Host link */
    struct Scsi_Host            *host;

    /* statistics */
    struct iscsi_stats_custom   *custom_stats;
};

/* session states */
#define ISCSI_STATE_FREE            1  /* not yet logged in */
#define ISCSI_STATE_LOGGED_IN       2  /* active, commands can flow */
#define ISCSI_STATE_FAILED          3  /* connection dropped, recovering */
#define ISCSI_STATE_TERMINATE       4  /* being torn down */
#define ISCSI_STATE_IN_RECOVERY     5  /* reconnecting */
#define ISCSI_STATE_RECOVERY_FAILED 6  /* replacement_timeout expired */
#define ISCSI_STATE_LOGGING_OUT     7  /* logout in progress */
```

The `age` field is critical for preventing stale ITT matches. Every reconnect increments `age`.
The ITT format is:

```c
/* ITT = [age(8 bits) | task_index(24 bits)] */
static inline __u32 build_itt(struct iscsi_task *task, __u32 age)
{
    /* index of task in session->cmds[] array */
    unsigned int idx = task - task->conn->session->cmds[0];
    return (age << 24) | (idx & 0xFFFFFF);
}
```

If the initiator reconnects after a session drop, the new session has `age+1`. Any response PDU
from the target with an ITT from the old session (age bit mismatch) is rejected — preventing
crossed completions where a response for a command from session N is matched to a task in session N+1.

---

## struct iscsi_conn — `include/scsi/libiscsi.h`

```c
struct iscsi_conn {
    struct iscsi_cls_conn       *cls_conn;   /* transport class wrapper */
    void                        *dd_data;    /* LLD private data (iscsi_tcp_conn) */
    struct iscsi_session        *session;    /* owning session */

    /* TCP socket — managed by iscsi_tcp, referenced here */
    struct socket               *sock;

    /*
     * Connection parameters — negotiated during Login.
     */
    unsigned                    max_recv_dlength; /* MaxRecvDataSegmentLength */
                                                  /* target's receive limit */
    unsigned                    max_xmit_dlength; /* our MaxRecvDataSegmentLength */
                                                  /* our transmit limit */
    int                         hdrdgst_en;  /* HeaderDigest: CRC32C or None */
    int                         datadgst_en; /* DataDigest:   CRC32C or None */

    /*
     * TX queues — drained by the TX kthread in order:
     *   1. mgmtqueue   — NOP-Out, TMF, Logout (management PDUs)
     *   2. cmdqueue    — SCSI Command PDUs
     *   3. requeue     — commands being retried
     *
     * mgmtqueue has priority — management PDUs always go before data.
     */
    struct list_head            mgmtqueue;
    struct list_head            cmdqueue;
    struct list_head            requeue;

    spinlock_t                  taskqueuelock; /* protects above queues */

    /*
     * taskqueue — all tasks that have been sent and await response.
     * Keyed by ITT. RX thread looks up tasks here on response receipt.
     */
    struct list_head            taskqueue;

    /* connection ID — used in iSCSI PDU headers */
    __u16                       cid;

    /* StatSN tracking */
    __u32                       exp_statsn;  /* next StatSN we expect */
    __u32                       statsn;      /* StatSN we send */

    /* TX thread control */
    struct task_struct          *tx_task;    /* the TX kthread */
    int                         suspend_tx;  /* pause TX (EH in progress) */
    int                         suspend_rx;  /* pause RX */

    /*
     * NOP-In keepalive timer.
     * If target doesn't respond to NOP-Out within this time,
     * iscsi_conn_failure() is called.
     * Configured via: iscsiadm -m node -T ... --op update
     *   -n node.conn[0].timeo.noop_out_interval -v 5
     *   -n node.conn[0].timeo.noop_out_timeout  -v 5
     */
    struct timer_list           transport_timer;
    unsigned long               last_recv;   /* jiffies of last received PDU */
    unsigned long               recv_timeout;
    unsigned long               ping_timeout;

    /* connection state */
    int                         state;       /* ISCSI_CONN_* */

    /* statistics */
    struct iscsi_stats          stats;
};

/* connection states */
#define ISCSI_CONN_INITIAL_STAGE    0
#define ISCSI_CONN_STARTED          1
#define ISCSI_CONN_STOPPED          2
#define ISCSI_CONN_CLEANUP_WAIT     3
```

The two-queue TX design (mgmtqueue before cmdqueue) ensures that NOP-Out keepalives and TMF
abort requests are never blocked behind a backlog of data commands. This matters during EH — the
abort TMF must get through even if the command queue is saturated.

---

## struct iscsi_task — `include/scsi/libiscsi.h`

```c
struct iscsi_task {
    struct kref             refcount;       /* reference counted */
    struct iscsi_conn       *conn;          /* owning connection */
    struct scsi_cmnd        *sc;            /* the SCSI command (NULL for mgmt) */

    /*
     * State machine.
     * FREE → PENDING (allocated) → RUNNING (sent) → COMPLETED
     *                            → ABRT_TMF (abort in progress)
     */
    int                     state;

    atomic_t                refcount_mgmt;  /* for management task refs */

    /* PDU header — built by iscsi_prep_scsi_cmd_pdu() */
    struct iscsi_hdr        hdr;            /* 48-byte BHS */
    unsigned int            hdr_len;

    /* ITT — Initiator Task Tag */
    __u32                   itt;

    /* data tracking */
    unsigned int            imm_count;    /* immediate data bytes (in Command PDU) */
    unsigned int            unsol_r2t;    /* unsolicited Data-Out offset */
    unsigned int            data_count;   /* bytes sent so far */
    unsigned int            last_xfer_len;

    /* R2T (Ready To Transfer) tracking for solicited writes */
    struct r2t_info         *r2t;         /* current R2T being processed */
    struct iscsi_r2t_pool   r2t_pool;     /* pool of r2t_info structs */

    /* pointer to the scsi_cmnd's SGL */
    struct scsi_data_buffer *sdb;

    /* LLD private data — iscsi_tcp stores socket segment state here */
    void                    *dd_data;

    struct list_head        running;      /* link in conn->taskqueue or cmdqueue */
};

/* task states */
#define ISCSI_TASK_FREE         0  /* in task pool, not in use */
#define ISCSI_TASK_PENDING      1  /* allocated, not yet sent */
#define ISCSI_TASK_RUNNING      2  /* PDU sent, awaiting SCSI response */
#define ISCSI_TASK_ABRT_TMF     3  /* TMF ABORT_TASK sent for this task */
#define ISCSI_TASK_ABRT_SESS    4  /* session being terminated */
#define ISCSI_TASK_COMPLETED    5  /* response received */
#define ISCSI_TASK_REQUEUE_SCSIQ 6 /* being requeued to SCSI layer */
```

The `sc->SCp` opaque fields in `scsi_cmnd` are used by libiscsi to link back to the task:

```c
/* in iscsi_alloc_task() */
sc->SCp.phase = session->age;    /* record session age for EH validation */
sc->SCp.ptr   = (char *)task;   /* direct pointer to iscsi_task */
```

EH uses `sc->SCp.phase` to detect stale commands — if the session age in the command doesn't
match the current session age, the command belongs to a previous session and should be ignored.

---

## CmdSN window — `drivers/scsi/libiscsi.c`

```c
/*
 * Check if the CmdSN window is closed.
 * Window is [exp_cmdsn, max_cmdsn]. If queued_cmdsn >= max_cmdsn,
 * we cannot send more commands — the target hasn't acknowledged enough.
 */
static inline int iscsi_cmd_win_closed(struct iscsi_session *session)
{
    /*
     * Signed comparison handles CmdSN wraparound correctly.
     * CmdSN is a 32-bit counter that wraps — use (int) cast for signed math.
     */
    return (int)(session->queued_cmdsn - session->max_cmdsn) > 0;
}
```

When the window is closed, `iscsi_queuecommand()` returns `SCSI_MLQUEUE_TARGET_BUSY` — blk-mq
holds the request and retries later. The window opens when the target sends a response with an
updated `MaxCmdSN` field. This is processed by `iscsi_update_cmdsn()` in the RX path:

```c
static void iscsi_update_cmdsn(struct iscsi_session *session,
                                struct iscsi_nopin *hdr)
{
    uint32_t max_cmdsn = be32_to_cpu(hdr->max_cmdsn);
    uint32_t exp_cmdsn = be32_to_cpu(hdr->exp_cmdsn);

    /* only advance — never go backwards */
    if (iscsi_sna_lt(session->max_cmdsn, max_cmdsn)) {
        session->max_cmdsn = max_cmdsn;

        /*
         * Window just opened — wake the TX thread.
         * It was blocked in iscsi_cmd_win_closed() returning true.
         */
        if (!list_empty(&session->leadconn->cmdqueue) ||
            !list_empty(&session->leadconn->requeue))
            iscsi_conn_queue_work(session->leadconn);
    }

    if (iscsi_sna_lt(session->exp_cmdsn, exp_cmdsn))
        session->exp_cmdsn = exp_cmdsn;
}
```

`iscsi_sna_lt()` is Serial Number Arithmetic less-than — handles 32-bit counter wraparound
according to RFC 1982.

---

## iscsi_session_setup — `drivers/scsi/libiscsi.c`

```c
struct iscsi_cls_session *
iscsi_session_setup(struct iscsi_transport *iscsit,
                    struct Scsi_Host *shost,
                    uint16_t cmds_max,       /* task pool size */
                    int dd_size,             /* LLD private session data */
                    int cmd_task_size,       /* LLD private per-task data */
                    uint32_t initial_cmdsn,
                    unsigned int id)
{
    struct iscsi_session *session;
    struct iscsi_cls_session *cls_session;
    int cmd_i, scsi_cmds;

    if (cmds_max < 2)
        cmds_max = 2;

    /* reserve ISCSI_MGMT_CMDS_MAX slots for NOP/TMF tasks */
    scsi_cmds = cmds_max - ISCSI_MGMT_CMDS_MAX;

    cls_session = iscsi_alloc_session(shost, iscsit,
                                       sizeof(*session) + dd_size);
    if (!cls_session)
        return NULL;

    session = cls_session->dd_data;

    session->cls_session = cls_session;
    session->host        = shost;
    session->state       = ISCSI_STATE_FREE;
    session->cmds_max    = cmds_max;

    /* CmdSN initialisation */
    session->cmdsn        = initial_cmdsn;
    session->exp_cmdsn    = initial_cmdsn + 1;
    session->max_cmdsn    = initial_cmdsn + 1;
    session->queued_cmdsn = initial_cmdsn;

    /* recovery timeout — 120 seconds by default */
    session->recovery_tmo = ISCSI_DEF_REPLACEMENT_TMOUT; /* = 120 */

    /* EH defaults */
    session->fast_abort          = 1;
    session->abort_timeout       = 10;   /* seconds */
    session->lu_reset_timeout    = 15;   /* seconds */
    session->tgt_reset_interval  = 30;   /* seconds */

    /* allocate iscsi_task pool */
    if (iscsi_pool_init(&session->cmdpool, cmds_max,
                        (void ***)&session->cmds,
                        cmd_task_size + sizeof(struct iscsi_task)))
        goto cmdpool_alloc_fail;

    /* initialise each task slot */
    for (cmd_i = 0; cmd_i < cmds_max; cmd_i++) {
        struct iscsi_task *task = session->cmds[cmd_i];
        task->state = ISCSI_TASK_FREE;
        kref_init(&task->refcount);
    }

    spin_lock_init(&session->frwd_lock);
    spin_lock_init(&session->back_lock);
    mutex_init(&session->eh_mutex);
    INIT_LIST_HEAD(&session->connections);

    /* recovery timer — fires when replacement_timeout expires */
    INIT_DELAYED_WORK(&session->recovery_work,
                      iscsi_session_recovery_timedout);

    return cls_session;

cmdpool_alloc_fail:
    iscsi_free_session(cls_session);
    return NULL;
}
EXPORT_SYMBOL_GPL(iscsi_session_setup);
```

`ISCSI_DEF_REPLACEMENT_TMOUT = 120`. During these 120 seconds after a session drop:
- `session->state = ISCSI_STATE_FAILED`
- All new commands via `iscsi_queuecommand()` → `iscsi_session_chkready()` returns
  `DID_TRANSPORT_DISRUPTED` → blk-mq retries later
- Existing in-flight tasks remain in `conn->taskqueue`, not completed

After 120 seconds, `iscsi_session_recovery_timedout()` fires:

```c
static void iscsi_session_recovery_timedout(struct work_struct *work)
{
    struct iscsi_session *session =
        container_of(work, struct iscsi_session, recovery_work.work);

    spin_lock_bh(&session->frwd_lock);
    if (session->state != ISCSI_STATE_LOGGED_IN) {
        session->state = ISCSI_STATE_RECOVERY_FAILED;
        /*
         * Wake anyone blocked waiting for session to recover.
         * iscsi_session_chkready() will now return DID_TRANSPORT_FAILFAST
         * instead of DID_TRANSPORT_DISRUPTED.
         *
         * DID_TRANSPORT_FAILFAST → dm-multipath permanently fails the path
         * (blk_path_error() = true, fail_path() called).
         */
    }
    spin_unlock_bh(&session->frwd_lock);

    scsi_target_unblock(&session->cls_session->dev, SDEV_TRANSPORT_OFFLINE);
    wake_up_all(&session->ehwait);
}
```

---

## iscsi_conn_setup — `drivers/scsi/libiscsi.c`

```c
struct iscsi_cls_conn *
iscsi_conn_setup(struct iscsi_cls_session *cls_session,
                 int dd_size, uint32_t conn_idx)
{
    struct iscsi_session *session = cls_session->dd_data;
    struct iscsi_conn *conn;
    struct iscsi_cls_conn *cls_conn;
    void *data;

    cls_conn = iscsi_create_conn(cls_session, sizeof(*conn) + dd_size,
                                  conn_idx);
    if (!cls_conn)
        return NULL;

    conn = cls_conn->dd_data;

    conn->cls_conn  = cls_conn;
    conn->session   = session;
    conn->dd_data   = conn + 1;    /* LLD private data immediately after */

    conn->cid       = conn_idx;

    /* TX queues */
    INIT_LIST_HEAD(&conn->mgmtqueue);
    INIT_LIST_HEAD(&conn->cmdqueue);
    INIT_LIST_HEAD(&conn->requeue);
    INIT_LIST_HEAD(&conn->taskqueue);
    spin_lock_init(&conn->taskqueuelock);

    /* keepalive timer */
    timer_setup(&conn->transport_timer,
                iscsi_check_transport_timeouts, 0);

    return cls_conn;
}
EXPORT_SYMBOL_GPL(iscsi_conn_setup);
```

`iscsi_check_transport_timeouts()` fires periodically (every `noop_out_interval` seconds). If
`last_recv` is older than `recv_timeout`, it sends a NOP-Out. If that NOP-Out is not answered
within `ping_timeout`, it calls `iscsi_conn_failure()` — treating the connection as dead.

---

## iscsi_session_chkready — state gate for new commands

```c
/* called at the start of iscsi_queuecommand() */
int iscsi_session_chkready(struct iscsi_cls_session *cls_session)
{
    struct iscsi_session *session = cls_session->dd_data;
    unsigned long flags;
    int err;

    spin_lock_irqsave(&session->frwd_lock, flags);
    switch (session->state) {
    case ISCSI_STATE_LOGGED_IN:
        err = 0;           /* all good — accept the command */
        break;
    case ISCSI_STATE_LOGGING_OUT:
        err = DID_IMM_RETRY << 16;  /* retry immediately */
        break;
    case ISCSI_STATE_RECOVERY_FAILED:
        /*
         * replacement_timeout expired.
         * DID_TRANSPORT_FAILFAST → dm-multipath permanently fails path.
         * This is the end of the recovery road.
         */
        err = DID_TRANSPORT_FAILFAST << 16;
        break;
    case ISCSI_STATE_FREE:
        err = DID_TRANSPORT_FAILFAST << 16;
        break;
    default:
        /*
         * ISCSI_STATE_FAILED / IN_RECOVERY:
         * Session is recovering. DID_TRANSPORT_DISRUPTED → blk-mq retries.
         * The command is NOT failed permanently — it will be retried
         * once the session reconnects.
         */
        err = DID_TRANSPORT_DISRUPTED << 16;
        break;
    }
    spin_unlock_irqrestore(&session->frwd_lock, flags);
    return err;
}
EXPORT_SYMBOL_GPL(iscsi_session_chkready);
```

The distinction between `DID_TRANSPORT_DISRUPTED` and `DID_TRANSPORT_FAILFAST` is everything:

- `DISRUPTED` → `scsi_decide_disposition()` → `NEEDS_RETRY` → blk-mq requeues → command waits
- `FAILFAST` → `scsi_decide_disposition()` → `SUCCESS` (with error) → `BLK_STS_TRANSPORT` →
  `multipath_end_io()` → `blk_path_error()=true` → `fail_path()` → path permanently removed

---

## Key takeaways

- `iscsi_session` owns CmdSN window, task pool, state machine, and `replacement_timeout` timer.
- `iscsi_conn` owns the TCP socket, TX priority queues (mgmt before cmd), and keepalive timer.
- `iscsi_task` wraps `scsi_cmnd` with an ITT, tracks Data-Out state, and lives in the task pool.
- ITT encodes `session->age` in the high 8 bits — stale ITTs from previous sessions are rejected.
- `replacement_timeout = 120s` default: commands are HELD for 120s during recovery, not failed.
  After 120s, `ISCSI_STATE_RECOVERY_FAILED` → `DID_TRANSPORT_FAILFAST` → dm-multipath path fail.
- `DID_TRANSPORT_DISRUPTED` (during recovery window) = retry later.
- `DID_TRANSPORT_FAILFAST` (after timeout or permanent failure) = path permanently failed.
- CmdSN window: `iscsi_cmd_win_closed()` pauses TX. `iscsi_update_cmdsn()` in RX reopens it.
- mgmtqueue has priority over cmdqueue — NOP and TMF always get through even under load.

---

## Previous / Next

[Day 7 — dm-multipath core](day07.md) | [Day 9 — iscsi_queuecommand path](day09.md)
