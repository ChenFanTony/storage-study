# Day 8 — libiscsi session and connection structs

**Week 2**: iSCSI Initiator Kernel Code  
**Time**: 1–2 hours  
**Reference**: `drivers/scsi/libiscsi.c`, `include/scsi/libiscsi.h`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative; verify struct layouts against the kernel version you're studying.

---

## Overview

libiscsi is the transport-agnostic core of the iSCSI initiator. `iscsi_tcp` (TCP) and `iser` (RDMA)
both plug into it. The two central structs — `iscsi_session` and `iscsi_conn` — hold the entire
state machine of an iSCSI session: parameter values, command pool, sequence numbers, error state.
Reading their definitions before any function code is the only way to follow what the functions
do.

---

## struct iscsi_session — `include/scsi/libiscsi.h`

```c
struct iscsi_session {
    struct iscsi_cls_session    *cls_session;
    /*
     * Target-side identifiers established during Login Phase.
     */
    char                        *targetname;       /* IQN of the target */
    char                        *initiatorname;    /* our IQN */
    int                         tpgt;              /* Target Portal Group Tag */

    /*
     * SAM I_T_L (Initiator-Target-LUN) nexus identifier.
     * Used by SCSI mid layer for command routing.
     */
    int                         age;               /* incremented on every reconnect */
    int                         queued_cmdsn;      /* CmdSN allocated, not yet sent */

    /*
     * State machine — set by transport class on login/logout/failure.
     */
    int                         state;             /* ISCSI_STATE_* */
    int                         recovery_failed;
    struct mutex                eh_mutex;          /* serialize EH actions */

    /*
     * Pre-allocated command pool. cmds_max is negotiated during Login,
     * pushed in from open-iscsi userspace (default 128).
     */
    int                         cmds_max;
    struct iscsi_task           **cmds;            /* array of task pointers */
    /*
     * Note: cmds is an array of POINTERS — pointer subtraction across
     * elements does not give an index. Each iscsi_task carries its own
     * itt assigned at allocation time. ITT is built from the session age
     * and a per-task index using ISCSI_AGE_MASK / ISCSI_AGE_SHIFT.
     */

    /*
     * Free list (kfifo) of command pool entries.
     * Pop from this in iscsi_alloc_task() — O(1).
     */
    struct iscsi_pool           cmdpool;

    /*
     * iSCSI sequence numbers (RFC 7143 §11):
     */
    uint32_t                    cmdsn;             /* next CmdSN to send */
    uint32_t                    exp_cmdsn;         /* next CmdSN target expects */
    uint32_t                    max_cmdsn;         /* upper bound of CmdSN window */

    /*
     * Negotiated session parameters.
     * These names map to RFC 7143 keys exchanged during Login.
     */
    int                         initial_r2t_en;    /* InitialR2T=Yes (1) or No (0) */
    int                         imm_data_en;       /* ImmediateData=Yes/No */
    int                         first_burst;       /* FirstBurstLength bytes */
    int                         max_burst;         /* MaxBurstLength bytes */
    int                         max_r2t;           /* MaxOutstandingR2T */

    /*
     * Connection list. The kernel supports MC/S (multiple connections per session)
     * but in practice most deployments use a single connection — sess->leadconn
     * is that connection.
     */
    int                         conns_count;
    struct iscsi_conn           *leadconn;         /* the one connection in MC/S=1 */

    /*
     * recovery_tmo: how long to wait for reconnect before declaring the
     * session dead. The value is pushed to the kernel from userspace via
     * sysfs at session creation — open-iscsi defaults
     * node.session.timeo.replacement_timeout to 120s. There is no kernel
     * symbol named ISCSI_DEF_REPLACEMENT_TMOUT.
     */
    int                         recovery_tmo;

    /*
     * Locks: front-end (frwd) and back-end (back) lock split.
     * Reduces contention between the queuecommand path and the
     * completion path. Some older code used a single session->lock.
     */
    spinlock_t                  frwd_lock;        /* protects: state, cmdsn, queued cmds */
    spinlock_t                  back_lock;        /* protects: completion-side data */

    /*
     * Recovery work — scheduled when state goes to FAILED.
     * On expiry, transitions to ISCSI_STATE_RECOVERY_FAILED.
     */
    struct delayed_work         recovery_work;

    void                        *dd_data;          /* LLD private (e.g. iscsi_tcp) */
};

/* Session states */
enum {
    ISCSI_STATE_FREE                = 1,
    ISCSI_STATE_LOGGED_IN           = 2,
    ISCSI_STATE_FAILED              = 3,    /* connection broken, recovery in progress */
    ISCSI_STATE_TERMINATE           = 4,
    ISCSI_STATE_IN_RECOVERY         = 5,
    ISCSI_STATE_RECOVERY_FAILED     = 6,    /* recovery_tmo expired */
    ISCSI_STATE_LOGGING_OUT         = 7,
};
```

`session->age` is the Session Age — incremented every time the session reconnects. Combined with
the per-task index it forms the ITT (Initiator Task Tag). `ISCSI_AGE_MASK` is small (4 bits in
modern source); the rest of the ITT word is the index. Stale responses from a previous session
fail the age check in `iscsi_itt_to_ctask()` and are silently dropped.

---

## struct iscsi_conn — `include/scsi/libiscsi.h`

```c
struct iscsi_conn {
    struct iscsi_cls_conn       *cls_conn;
    void                        *dd_data;          /* LLD private (iscsi_tcp_conn) */

    struct iscsi_session        *session;          /* parent session */

    /*
     * Connection state — overlaps but is not identical to session state.
     * Tracks per-connection lifecycle within the session.
     */
    int                         id;                /* CID */
    int                         c_stage;           /* connection stage */

    /*
     * Per-connection sequence numbers.
     */
    uint32_t                    exp_statsn;        /* next StatSN we expect */

    /*
     * Negotiated connection parameters.
     */
    int                         hdrdgst_en;        /* HeaderDigest=CRC32C */
    int                         datadgst_en;       /* DataDigest=CRC32C */
    int                         max_recv_dlength;  /* MaxRecvDataSegmentLength */
    int                         max_xmit_dlength;  /* MaxXmitDataSegmentLength */

    /*
     * Suspend bits — checked in queuecommand() and the TX path.
     * Set during EH and session failure to halt new commands.
     */
    unsigned long               suspend_tx;        /* ISCSI_SUSPEND_BIT */
    unsigned long               suspend_rx;

    /*
     * TX work item (drained by the iscsi workqueue, not a dedicated kthread
     * in modern code). Wakes when commands are queued.
     */
    struct work_struct          xmitwork;

    /*
     * Three command queues, drained by the TX worker in priority order:
     *   1. mgmtqueue  — NOP-Out, TMF, Logout (highest)
     *   2. requeue    — partial sends being resumed
     *   3. cmdqueue   — normal SCSI commands
     */
    struct list_head            mgmtqueue;
    struct list_head            cmdqueue;
    struct list_head            requeue;
    spinlock_t                  taskqueuelock;

    /*
     * In-flight tasks awaiting response from target.
     */
    struct list_head            taskqueue;

    /*
     * Error tracking.
     */
    unsigned long               err_flags;         /* ISCSI_ERR_* bits */

    struct iscsi_task           *task;             /* current TX task being sent */
};

/* Suspend bit positions */
#define ISCSI_SUSPEND_BIT        0
```

The `frwd_lock`/`back_lock` split was added in part to allow concurrent execution of the
queuecommand path and the response path under load, without one blocking the other on a single
session-wide lock.

---

## struct iscsi_task — `include/scsi/libiscsi.h`

```c
struct iscsi_task {
    /*
     * 48-byte BHS template — filled in by iscsi_prep_scsi_cmd_pdu().
     * Sent verbatim as the iSCSI Command PDU header.
     */
    unsigned char                hdr_buff[ISCSI_DEF_MAX_RECV_SEG_LEN];
    char                        *hdr;
    int                         hdr_len;

    /*
     * ITT — Initiator Task Tag. Built by build_itt() from session age and
     * task index. Echoed by target in every response PDU.
     */
    itt_t                       itt;

    /*
     * Sequence numbers.
     */
    uint32_t                    cmdsn;             /* CmdSN this task carries */
    uint32_t                    datasn;            /* DataSN counter for Data-In */
    uint32_t                    exp_datasn;        /* expected next DataSN */

    /*
     * Write data tracking.
     */
    int                         imm_count;         /* immediate data bytes */
    int                         unsol_r2t;         /* unsolicited Data-Out remaining */

    /*
     * Pointer to the SCSI command this task represents (NULL for management
     * tasks like NOP-Out).
     */
    struct scsi_cmnd            *sc;

    /*
     * Completion / refcount.
     */
    struct kref                 refcount;
    int                         state;             /* ISCSI_TASK_* */

    /*
     * Per-LLD private data follows in memory.
     * Modern libiscsi finds this via task->dd_data, sized by transport
     * cmd_size during host registration.
     */
    void                        *dd_data;
};

enum {
    ISCSI_TASK_PENDING,
    ISCSI_TASK_RUNNING,
    ISCSI_TASK_COMPLETED,
    ISCSI_TASK_REQUEUE_SCSIQ,
    ISCSI_TASK_ABRT_TMF,
    ISCSI_TASK_ABRT_SESS_RECOV,
};
```

---

## Linkage from scsi_cmnd to iscsi_task

```c
/*
 * Modern libiscsi stores the per-command iscsi_task in the SCSI command's
 * private area (the bytes immediately after struct scsi_cmnd in the
 * blk-mq request PDU). The legacy approach of stashing pointers in
 * sc->SCp.ptr / sc->SCp.phase was removed in v6.2 — struct scsi_cmnd no
 * longer has an SCp field at all.
 *
 * The libiscsi helper looks like:
 */
static inline struct iscsi_cmd *iscsi_cmd(struct scsi_cmnd *sc)
{
    return scsi_cmd_priv(sc);  /* trailing private area in the PDU */
}
/*
 * struct iscsi_cmd holds a pointer to the iscsi_task and the session age
 * at the time the command was allocated. The age is what lets the EH path
 * reject stale commands from a previous (now-recovered) session without
 * touching the new session's state.
 */
```

The session-age stamp prevents a command issued before a session reconnect from being treated as
in-flight after the reconnect. After `session->age++` in recovery, any old commands are
distinguishable by age mismatch.

---

## ITT format

```c
/*
 * ITT layout (32 bits, exact split varies — verify against the kernel
 * version you target):
 *
 *   [age : ISCSI_AGE_MASK bits | task_index : remainder]
 *
 * In current libiscsi:
 *   ISCSI_AGE_MASK    is 0xf  (4 bits — Session Age)
 *   ISCSI_AGE_SHIFT   is 28
 *   index occupies the low 28 bits
 *
 * build_itt() computes:
 *   itt = (session->age << ISCSI_AGE_SHIFT) | (task->index & ISCSI_ITT_MASK);
 *
 * Older comments and external docs sometimes describe the high 8 bits as
 * the age — that was true in much earlier kernels. Always confirm against
 * include/scsi/libiscsi.h for the version you're studying.
 */
```

---

## State diagram

```
Login successful
    │
    ▼
ISCSI_STATE_LOGGED_IN
    │
    │  TCP error / NOP timeout / RX parse error
    ▼
ISCSI_STATE_FAILED
    │  recovery_work scheduled with delay = recovery_tmo (sysfs value
    │  pushed from userspace; open-iscsi default 120s)
    │
    ├── iscsid reconnects → ISCSI_STATE_LOGGED_IN
    │
    └── recovery_tmo expires → ISCSI_STATE_RECOVERY_FAILED
        │
        ▼
        Held commands fail with DID_TRANSPORT_FAILFAST
        dm-multipath: fail_path()
```

---

## Memory layout

```
iscsi_session
   ├── cmds[] (array of pointers)
   │      ├── cmds[0] → iscsi_task → (sc, hdr, dd_data, ...)
   │      ├── cmds[1] → iscsi_task → ...
   │      └── ... cmds_max entries
   ├── cmdpool (kfifo of free indices into cmds[])
   ├── frwd_lock / back_lock
   ├── delayed_work recovery_work
   └── leadconn → iscsi_conn
                      ├── mgmtqueue / cmdqueue / requeue lists
                      ├── taskqueue (in-flight)
                      ├── xmitwork (TX work item)
                      └── dd_data → iscsi_tcp_conn → socket, etc.
```

---

## Key takeaways

- `iscsi_session` holds long-lived state: target IQN, sequence numbers, command pool, negotiated
  parameters, and a recovery work item.
- `iscsi_conn` holds per-connection state: connection-specific sequence numbers (`exp_statsn`),
  per-connection negotiated parameters, three task queues drained by a TX work item.
- `iscsi_task` is one in-flight SCSI command. ITT is built from session age + task index.
- The TX side is a workqueue handler (`xmitwork`), not a dedicated kthread per connection.
- `frwd_lock` / `back_lock` split reduces lock contention between queuecommand and completion.
- `recovery_tmo` (the kernel field) is set from the userspace
  `node.session.timeo.replacement_timeout` (default 120s) at session creation. There is no kernel
  constant named `ISCSI_DEF_REPLACEMENT_TMOUT`.
- The legacy `sc->SCp` field is gone (removed in v6.2). Per-command iSCSI state lives in the SCSI
  command's private area (`scsi_cmd_priv()`).
- ITT bit layout has `age` in the high bits (4 bits in current code, masked by `ISCSI_AGE_MASK =
  0xf`); older docs may describe a wider age field — always verify.
- The kernel supports MC/S (multiple connections per session) but most deployments use one;
  `sess->leadconn` is that connection.

---

## Previous / Next

[Day 7 — dm-multipath core](day07.md) | [Day 9 — iscsi_queuecommand path](day09.md)
