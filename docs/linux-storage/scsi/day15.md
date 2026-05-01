# Day 15 — target core structs

**Week 3**: LIO Target Core — Fabric to Backend
**Time**: 1–2 hours
**Reference**: `include/target/target_core_base.h`, `include/target/target_core_fabric.h`

---

## Overview

LIO's target core (`target_core_mod`) is fabric-agnostic. The same `se_cmd`, `se_device`,
`se_session`, and `se_lun` structs are used whether the fabric is iSCSI, FC, NVMe-oF, or SRP.
The fabric-specific code (iSCSI PDU handling, FC frame processing) plugs into the core via
`target_core_fabric_ops` (`se_tfo`). Before reading any target core code, know these structs —
every function in week 3 works with them.

---

## struct se_cmd — `include/target/target_core_base.h`

The central command struct. One per SCSI command in flight on the target.

```c
struct se_cmd {
    /* SCSI command attributes */
    u8                      scsi_status;      /* SAM_STAT_GOOD, CHECK_CONDITION, etc. */
    u8                      scsi_asc;         /* Additional Sense Code */
    u8                      scsi_ascq;        /* ASC Qualifier */
    u16                     scsi_sense_reason;/* TCM_* sense reason code */

    unsigned char           *t_task_cdb;      /* pointer to CDB bytes */
    unsigned char           __t_task_cdb[TCM_MAX_COMMAND_SIZE]; /* inline CDB storage */

    /* data transfer */
    u32                     data_length;      /* total bytes to transfer */
    u32                     residual_count;   /* bytes not transferred */
    enum dma_data_direction data_direction;   /* DMA_TO/FROM_DEVICE or DMA_NONE */

    /*
     * Scatter-gather list for data.
     * For writes: filled by iSCSI fabric from Data-Out PDUs.
     * For reads: filled by backend, sent as Data-In PDUs.
     */
    struct scatterlist      *t_data_sg;
    unsigned int            t_data_nents;     /* number of SGL entries */
    u32                     t_data_sg_nents_order; /* for page allocation */

    /* protection (T10-DIF) */
    struct scatterlist      *t_prot_sg;
    unsigned int            t_prot_nents;

    /*
     * Transport state machine flags.
     * Multiple bits can be set simultaneously.
     * Protected by se_cmd->t_state_lock.
     */
    u32                     transport_state;
    spinlock_t              t_state_lock;
    struct completion       t_transport_stop_comp;

    /*
     * Work item for target_submission_wq and target_completion_wq.
     * queue_work(target_submission_wq, &se_cmd->work) queues execution.
     * queue_work(target_completion_wq, &se_cmd->work) queues completion.
     */
    struct work_struct      work;

    /* task management */
    struct list_head        se_cmd_list;      /* link in se_sess->sess_cmd_list */
    struct kref             cmd_kref;         /* reference count */

    /* LUN and session */
    struct se_lun           *se_lun;          /* LUN this command targets */
    struct se_session       *se_sess;         /* session that submitted this */
    struct se_device        *se_dev;          /* the backend device */

    /*
     * Fabric ops pointer — used to call back to the fabric layer.
     * e.g.: se_cmd->se_tfo->queue_status() sends the SCSI Response PDU.
     */
    const struct target_core_fabric_ops *se_tfo;

    /* PR (Persistent Reservation) check result */
    sense_reason_t          pr_res_key;       /* TCM_RESERVATION_CONFLICT if denied */

    /* ALUA result */
    int                     alua_nonop_delay; /* ms to delay if non-optimized path */

    /* tag — used by some fabrics for response matching */
    u64                     tag;

    /* timing */
    u32                     cmd_sn;           /* CmdSN for iSCSI ordering */
};

/*
 * transport_state bit flags — track command lifecycle.
 * These replace the old cmd->t_state enum with fine-grained bits.
 */
#define CMD_T_ABORTED       (1 << 0)   /* command was aborted */
#define CMD_T_ACTIVE        (1 << 1)   /* command is active in target core */
#define CMD_T_COMPLETE      (1 << 2)   /* backend I/O complete */
#define CMD_T_SENT          (1 << 3)   /* response PDU sent to initiator */
#define CMD_T_STOP          (1 << 4)   /* command is being stopped (TMF) */
#define CMD_T_TAS           (1 << 5)   /* Task Aborted Status to be sent */
#define CMD_T_FABRIC_STOP   (1 << 6)   /* fabric layer has stopped this cmd */
#define CMD_T_REQUEST_STOP  (1 << 7)   /* stop was requested */
#define CMD_T_BUSY          (1 << 8)   /* command is busy (requeue) */
```

`se_cmd->work` is the critical field that enables the workqueue design. The same `work_struct`
is used for both submission and completion — it is re-initialised between uses.

---

## struct se_device — `include/target/target_core_base.h`

Represents a backend storage object (block device, file, ramdisk).

```c
struct se_device {
    /* device attributes */
    u32                     dev_index;        /* unique device index */
    u64                     dev_sectors;      /* total sectors */
    u32                     dev_attrib;       /* device attribute flags */

    /*
     * Transport ops — the backend plugin interface.
     * Set when backend registers (iblock, fileio, pscsi).
     * Called via: se_dev->transport->execute_cmd(cmd)
     */
    const struct target_backend_ops *transport;
    struct target_backend   *tb;              /* backend instance */

    /*
     * PR state — Persistent Reservation registrations and holder.
     * Protected by se_device->dev_reservation_lock.
     */
    struct t10_pr_registration *dev_pr_res_holder; /* current reservation holder */
    struct list_head        t10_pr_reg_list;  /* all registered keys */
    spinlock_t              dev_reservation_lock;
    struct t10_reservation  dev_t10_pr;

    /* ALUA state */
    struct t10_alua         t10_alua;

    /* LUN list — LUNs exposing this device */
    struct list_head        dev_sep_list;

    /* queue depth */
    u32                     queue_depth;      /* max in-flight commands */
    atomic_t                simple_cmds;      /* current in-flight count */

    /* statistics */
    struct se_dev_stat      dev_stats;

    /* backend private data */
    void                    *transport_private;
};
```

`se_dev->transport->execute_cmd(cmd)` is the single dispatch point into the backend. Every
command goes through this — the backend may be iblock (calls blkdev_issue_*), fileio (calls
kernel_write/read), or pSCSI (calls scsi_execute_cmd on the underlying device).

---

## struct se_session — `include/target/target_core_base.h`

One per iSCSI session (or FC login, SRP session, etc.) on the target side.

```c
struct se_session {
    /* fabric private — for iSCSI: points to iscsit_session */
    void                    *fabric_sess_ptr;

    /* node ACL — authentication and LUN mapping for this initiator */
    struct se_node_acl      *se_node_acl;

    /* in-flight command list — used during session teardown */
    struct list_head        sess_cmd_list;    /* all active se_cmds */
    spinlock_t              sess_cmd_lock;

    /* session state for teardown synchronisation */
    unsigned int            sess_tearing_down; /* 1 = session closing */

    /* wait queue for session drain */
    wait_queue_head_t       sess_wait_queue;

    /* statistics */
    struct se_session_stat  session_stats;
};
```

`sess_tearing_down` and `sess_cmd_list` are the mechanism for safe session teardown. When
`iscsit_close_session()` is called (day 25), it sets `sess_tearing_down = 1` and then waits
via `target_wait_for_sess_cmds()` for `sess_cmd_list` to drain before freeing memory.

---

## struct se_lun — `include/target/target_core_base.h`

Represents a LUN exposed by a target portal group.

```c
struct se_lun {
    u64                     unpacked_lun;    /* LUN number (0, 1, 2...) */

    /* atomic reference to the device — supports hot-unplug */
    struct se_device __rcu  *lun_se_dev;     /* RCU-protected device pointer */

    /* ALUA target port group for this LUN */
    struct se_port_stat_grps port_stat_grps;
    struct list_head        lun_deve_list;   /* list of se_dev_entry */

    /* portal group this LUN belongs to */
    struct se_portal_group  *lun_tpg;

    /* configfs node */
    struct config_group     lun_group;

    /* enable/disable state (admin control) */
    bool                    lun_shutdown;    /* true = LUN disabled */
    bool                    lun_access_ro;   /* read-only flag */

    struct percpu_ref        lun_ref;        /* for safe command completion */
};
```

`lun_se_dev` is RCU-protected — reading it requires `rcu_read_lock()`. This allows safe
hot-unplug: the admin can remove a backend device while commands are in flight. The RCU mechanism
ensures in-flight commands still have a valid device pointer until completion.

`lun_shutdown` is set when a LUN is disabled via configfs (`echo 0 > enable`). The target core
checks this before accepting new commands.

---

## struct target_core_fabric_ops (se_tfo) — `include/target/target_core_fabric.h`

The ops table that makes target_core fabric-agnostic. Each fabric registers one of these.

```c
struct target_core_fabric_ops {
    struct module           *module;
    const char              *name;         /* "iscsi", "fc", "srp", etc. */

    /*
     * Queue a SCSI status response back to the initiator.
     * For iSCSI: iscsit_queue_status() builds and sends SCSI Response PDU.
     * For FC: builds and sends FCP_RSP frame.
     *
     * This is the completion callback from target_core → fabric layer.
     * Called from target_complete_ok_work() (completion workqueue).
     */
    int (*queue_status)(struct se_cmd *);

    /*
     * Queue data to the initiator (for reads).
     * For iSCSI: sends Data-In PDUs.
     * For FC: sends FCP_DATA frames.
     */
    int (*queue_data_in)(struct se_cmd *);

    /*
     * Queue a task management response.
     * For iSCSI: sends SCSI Task Management Response PDU.
     */
    int (*queue_tm_rsp)(struct se_cmd *);

    /* abort a command — fabric-specific abort mechanism */
    void (*aborted_task)(struct se_cmd *);

    /* session management */
    void (*close_session)(struct se_session *);
    u32  (*sess_get_index)(struct se_session *);
    u32  (*sess_get_initiator_sid)(struct se_session *, unsigned char *, u32);

    /* get initiator name for ACL lookup */
    char *(*get_fabric_name)(void);
    char *(*get_initiator_node_name)(struct se_session *, unsigned char *);
    int  (*check_stop_free)(struct se_cmd *);

    /* configfs ops for fabric-specific attributes */
    const struct target_core_param_table *tpg_auth_table;
};
```

For iSCSI, the `se_tfo` is registered in `drivers/target/iscsi/iscsi_target.c`:

```c
static const struct target_core_fabric_ops iscsi_ops = {
    .module                 = THIS_MODULE,
    .name                   = "iscsi",
    .queue_data_in          = iscsit_queue_data_in,
    .queue_status           = iscsit_queue_status,     /* ← sends SCSI Response PDU */
    .queue_tm_rsp           = iscsit_queue_tm_rsp,
    .aborted_task           = iscsit_aborted_task,
    .check_stop_free        = iscsit_check_stop_free,
    .close_session          = iscsit_close_session,
    .sess_get_index         = iscsit_sess_get_index,
    .get_fabric_name        = iscsit_get_fabric_name,
    .get_initiator_node_name = iscsit_get_initiator_node_name,
};
```

When `target_complete_ok_work()` runs in `target_completion_wq`, it calls:

```c
cmd->se_tfo->queue_status(cmd);
/* → iscsit_queue_status() → iscsit_send_response() → TX kthread → wire */
```

This is the seam between target_core_mod and iscsi_target_mod.

---

## struct se_node_acl — `include/target/target_core_base.h`

The per-initiator access control entry. One per allowed initiator IQN per target portal group.

```c
struct se_node_acl {
    char                    initiatorname[TRANSPORT_IQN_LEN]; /* IQN string */

    /* LUN mapping — which LUNs this initiator can see */
    struct hlist_head       lun_entry_hlist;     /* hash of se_dev_entry */
    spinlock_t              lun_entry_lock;

    /* PR — per-initiator registration list */
    struct list_head        acl_list;            /* link in tpg->acl_list */

    /* session list — all active sessions for this initiator */
    struct list_head        acl_sess_list;
    spinlock_t              acl_sess_lock;
    u32                     acl_sess_count;

    /* dynamic ACL flag — created on first connect if dynamic ACLs enabled */
    bool                    dynamic_node_acl;

    /* queue depth for this initiator */
    u32                     queue_depth;

    /* configfs */
    struct config_group     acl_group;
    struct se_portal_group  *se_tpg;             /* owning portal group */
};
```

When the admin removes an ACL (`targetcli /iscsi/.../acls delete wwn=<iqn>`), the configfs
`rmdir` handler calls `core_tpg_del_initiator_node_acl()`. Active sessions for this IQN are
torn down via `target_put_nacl()`. New login attempts from the same IQN fail at
`core_tpg_check_initiator_node_acl()` — this is the login rejection mechanism for fencing.

---

## struct t10_pr_registration — `include/target/target_core_base.h`

One per registered key per device. The PR state machine lives in these.

```c
struct t10_pr_registration {
    /* the 64-bit reservation key registered by this initiator */
    u64                     pr_res_key;

    /* I_T nexus this registration belongs to */
    struct se_node_acl      *pr_reg_nacl;    /* which initiator */
    struct se_lun           *pr_reg_deve;    /* which LUN */
    u32                     pr_res_mapped_lun; /* mapped LUN number */

    /* reservation type if this registration holds the reservation */
    u8                      pr_res_type;     /* PR_TYPE_* */
    u8                      pr_res_scope;    /* LU_SCOPE or ELEMENT_SCOPE */

    /* APTPL — persist through power loss */
    bool                    pr_reg_aptpl;

    /* list links */
    struct list_head        pr_reg_list;     /* link in se_device->t10_pr_reg_list */
    struct list_head        pr_reg_abort_list; /* for TMF abort tracking */

    /* generation counter — incremented on each PR OUT command */
    u32                     pr_res_generation;
};
```

`se_device->dev_pr_res_holder` points to the `t10_pr_registration` of the initiator currently
holding the reservation. When `core_scsi3_pr_seq_non_holder()` checks whether an incoming command
is allowed, it compares the command's I_T nexus against `dev_pr_res_holder->pr_reg_nacl`.

---

## struct target_backend_ops — `include/target/target_core_backend.h`

The backend plugin interface. Registered by iblock, fileio, pscsi.

```c
struct target_backend_ops {
    const char  *name;              /* "iblock", "fileio", "pscsi", "rd_mcp" */
    u8          inquiry_prod[17];   /* INQUIRY product identification string */
    u8          inquiry_rev[5];     /* INQUIRY product revision level */

    /*
     * Attach / detach a storage object.
     * Called when admin creates/removes a backstore via configfs.
     */
    int         (*attach_hba)(struct se_hba *, u32);
    void        (*detach_hba)(struct se_hba *);
    int         (*pmode_enable_hba)(struct se_hba *, unsigned long);

    /* create/destroy a se_device */
    struct se_device *(*alloc_device)(struct se_hba *, const char *);
    int         (*configure_device)(struct se_device *);
    int         (*destroy_device)(struct se_device *);
    void        (*free_device)(struct se_device *);

    /*
     * Execute a SCSI command.
     * The backend calls target_complete_cmd() when done.
     * Return value: TCM_NO_SENSE (success start) or sense reason (fail).
     */
    sense_reason_t (*execute_cmd)(struct se_cmd *);

    /* pass-through commands the backend handles directly */
    sense_reason_t (*parse_cdb)(struct se_cmd *);

    /* ALUA support */
    int         (*set_configfs_dev_params)(struct se_device *, const char *, ssize_t);
    ssize_t     (*show_configfs_dev_params)(struct se_device *, char *);
};
```

For iblock, `execute_cmd` is `iblock_execute_cmd()`. It checks the CDB opcode and dispatches to:
- `iblock_execute_rw()` for READ/WRITE
- `iblock_execute_flush()` for FLUSH
- `iblock_execute_discard()` for DISCARD / UNMAP
- Emulated handlers in `target_core_transport.c` for INQUIRY, MODE SENSE, etc.

---

## How the structs connect — the LUN resolution chain

When a command arrives from the initiator, target_core resolves it through this chain:

```
iSCSI Command PDU arrives
    │  LUN field in BHS (8 bytes packed)
    ▼
iscsit_process_scsi_cmd()
    │  unpack LUN → lun number
    ▼
target_submit_cmd(se_cmd, se_sess, cdb, data_dir, tag, data_length, lun)
    │
    ├── lookup se_lun from se_sess->se_node_acl->lun_entry_hlist[lun]
    │     If not found: TCM_NON_EXISTENT_LUN → ILLEGAL REQUEST sense
    │
    ├── se_cmd->se_lun = se_lun
    ├── se_cmd->se_dev = rcu_dereference(se_lun->lun_se_dev)
    │     If NULL (LUN disabled): TCM_NON_EXISTENT_LUN
    │
    ├── core_scsi3_pr_seq_non_holder()  ← PR check
    │     If non-holder: se_cmd->scsi_status = SAM_STAT_RESERVATION_CONFLICT
    │     → transport_generic_request_failure() → queue_status() → Response PDU
    │
    ├── core_alua_state_check()         ← ALUA check
    │
    └── transport_generic_new_cmd()     ← proceed to execution
```

---

## Key takeaways

- `se_cmd` is the central command struct. Contains CDB, SGL, SCSI status, transport state bits,
  and a `work_struct` for workqueue dispatch.
- `transport_state` bits (`CMD_T_*`) track the command's lifecycle across the workqueue handoffs.
- `se_device->transport->execute_cmd()` is the single backend dispatch point.
- `se_tfo` is the fabric ops table — `queue_status()` is how target_core hands completed commands
  back to the fabric (iSCSI, FC, etc.) for response PDU generation.
- `se_node_acl` holds the initiator IQN, LUN mapping, and session list. Removing it blocks new
  logins and starts teardown of existing sessions — the fencing control plane.
- `t10_pr_registration` is the PR state — `dev_pr_res_holder` points to the reservation holder.
- `se_lun->lun_se_dev` is RCU-protected — safe hot-unplug without stopping in-flight I/O.
- `lun_shutdown` gates new command acceptance at the LUN level.

---

## Previous / Next

[Day 14 — dm-multipath PR ops and path management](day14.md) | [Day 16 — target_core_transport submit path](day16.md)
