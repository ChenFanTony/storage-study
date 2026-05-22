# Day 15 — target core structs

**Week 3**: LIO Target Kernel Code  
**Time**: 1–2 hours  
**Reference**: `drivers/target/target_core_base.h`, `drivers/target/target_core_*.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative; verify struct layouts against the kernel version you're studying.

---

## Overview

LIO (Linux-IO) is the in-kernel SCSI target. It is fabric-agnostic: iSCSI, iSER, FC, FCoE, vhost,
loopback all plug in as fabric modules. The core data structures — `se_session`, `se_cmd`,
`se_lun`, `se_node_acl` — are shared. Understanding these is the foundation for every following
day.

---

## struct se_session — `drivers/target/target_core_base.h`

The I_T nexus from the target's perspective. One per logged-in initiator connection.

```c
struct se_session {
    /*
     * Session command list — every in-flight command for this session.
     * Walked during TMR (TMF processing) and on session shutdown.
     */
    struct list_head            sess_cmd_list;
    spinlock_t                  sess_cmd_lock;

    /*
     * Reference count + completion for clean teardown.
     * Drained during target_wait_for_sess_cmds() — waits for in-flight
     * commands to finish before declaring the session gone.
     */
    struct percpu_ref           cmd_count;
    struct completion           stop_done;

    /*
     * Session-level Unit Attentions queued for delivery.
     * Used for "PR PREEMPTED" UA, ALUA state changes, etc.
     */
    struct list_head            sess_acl_list;
    spinlock_t                  sess_uacl_lock;

    /*
     * Per-session ACL — points to se_node_acl for this initiator.
     * Determines what LUNs are visible.
     */
    struct se_node_acl          *se_node_acl;

    /*
     * Tag pool for command IDs (matches initiator's ITT space).
     */
    struct sbitmap_queue        sess_tag_pool;

    /*
     * Fabric-private data.
     * For iSCSI: points to struct iscsit_session.
     * Accessible via container_of in fabric code.
     */
    void                        *fabric_sess_ptr;

    /*
     * Pre-allocated command pool — one per tag in sess_tag_pool.
     * Sized via sess_cmd_buf_pool / sess_cmd_buf_pool_size to amortize
     * the cost of per-command allocations.
     */
    struct kmem_cache           *sess_cmd_cache;

    struct list_head            sess_list;
};
```

Fabric modules register a tag space via `transport_alloc_session_tags()`, so the target can
allocate per-command storage in O(1) — same idea as libiscsi's command pool on the initiator
side.

---

## struct se_cmd — `drivers/target/target_core_base.h`

The target-side per-command structure. Equivalent in scope to initiator's `iscsi_task` +
`scsi_cmnd`.

```c
struct se_cmd {
    /*
     * Pointers up the stack:
     *   se_sess  — the session this command belongs to
     *   se_lun   — the target LUN
     *   se_dev   — the backstore device behind the LUN
     */
    struct se_session           *se_sess;
    struct se_lun               *se_lun;
    struct se_device            *se_dev;

    /*
     * SCSI status output:
     *   scsi_status: SAM_STAT_GOOD / CHECK_CONDITION / RESERVATION_CONFLICT
     *   scsi_sense_reason: TCM_* internal reason (mapped to ASC/ASCQ later)
     *   sense_buffer: 96 bytes filled by transport_send_check_condition_and_sense
     */
    u8                          scsi_status;
    u16                         scsi_sense_reason;
    unsigned char               sense_buffer[TRANSPORT_SENSE_BUFFER];

    /*
     * Data direction and length.
     */
    enum dma_data_direction     data_direction;
    u32                         data_length;
    u32                         residual_count;

    /*
     * SCSI CDB.
     * t_task_cdb points to either __t_task_cdb (inline storage for
     * up to TCM_MAX_COMMAND_SIZE = 32 bytes) or to an externally-allocated
     * buffer for variable-length CDBs that exceed 32 bytes.
     */
    unsigned char               *t_task_cdb;
    unsigned char               __t_task_cdb[TCM_MAX_COMMAND_SIZE];
    unsigned int                t_task_cdb_size;

    /*
     * Transport state — bitmap of CMD_T_* flags.
     */
    unsigned long               transport_state;
    spinlock_t                  t_state_lock;
    enum transport_state_table  t_state;

    /*
     * SGL — points to data buffer for this command.
     * For READ: filled by backend after I/O, sent to initiator.
     * For WRITE: filled from initiator's Data-Out, then read by backend.
     */
    struct scatterlist          *t_data_sg;
    unsigned int                t_data_nents;
    struct scatterlist          *t_bidi_data_sg;
    unsigned int                t_bidi_data_nents;

    /*
     * Reference count — multiple paths can hold a reference:
     *   - fabric (initial)
     *   - backend I/O in progress
     *   - TMR processing (abort)
     */
    struct kref                 cmd_kref;

    /*
     * Completion for synchronization between abort handler and
     * normal completion path.
     */
    struct completion           t_transport_stop_comp;
    struct completion           free_compl;

    /*
     * Workqueue handlers.
     * cmd->work is queued to one of:
     *   target_submission_wq — for backend execution
     *   target_completion_wq — for response generation
     */
    struct work_struct          work;

    /*
     * Task attribute (RFC 7143 §11.2.2 / SAM):
     *   MSG_SIMPLE_TAG = 0x20
     *   MSG_HEAD_TAG   = 0x21
     *   MSG_ORDERED_TAG = 0x22
     *   MSG_ACA_TAG    = 0x24
     */
    int                         sam_task_attr;

    /*
     * Fabric-private data.
     * For iSCSI: points to struct iscsit_cmd.
     */
    struct se_tmr_req           *se_tmr_req;

    struct list_head            se_cmd_list;        /* on session list */

    /*
     * Persistent reservation context — used by PR state machine.
     */
    struct t10_pr_registration  *pr_reg;
};

/* CMD_T_* transport state bits */
enum {
    CMD_T_ABORTED       = 0,    /* abort requested via TMF */
    CMD_T_ACTIVE        = 1,    /* command is being processed */
    CMD_T_COMPLETE      = 2,    /* completion has been delivered */
    CMD_T_SENT          = 3,    /* response sent to initiator */
    CMD_T_STOP          = 4,    /* abort/free is waiting */
    CMD_T_FAILED        = 5,
    CMD_T_FABRIC_STOP   = 6,    /* fabric session is going away */
    CMD_T_TAS           = 7,    /* Task Aborted Status flag — send 0x40 */
};
```

The `t_task_cdb` indirection allows variable-length CDBs (rare — mostly 32-byte VARIABLE LENGTH
CDB) without bloating every `se_cmd`. For the common case (CDB <= 32 bytes), `t_task_cdb` points
into `__t_task_cdb[]` — no extra allocation.

`CMD_T_TAS` (Task Aborted Status, 0x40) is set when the SCSI standard requires sending a
TASK_ABORTED status to other initiators (e.g. one initiator aborts a command via TMF; other
initiators with the same I_T nexus get the abort status). `CMD_T_FABRIC_STOP` — added in 2017 —
is the fabric-shutdown flag, distinguishing "session is going away" from generic per-command
abort, so `release_cmd` can wait for in-flight I/O to drain without competing with TMF
handling. (The fix is well-attested in commit history; the exact memory-safety reasoning is
inference, not in the upstream commit message.)

---

## struct se_lun — `drivers/target/target_core_base.h`

```c
struct se_lun {
    u64                         unpacked_lun;       /* the LUN number */

    /*
     * Pointer to the backstore device.
     * Set during configfs LUN attach (echo /backstore/iblock_0/disk0/...
     * > /target/iscsi/.../tpgt_1/lun/lun_0/storage_object)
     */
    struct se_device            *lun_se_dev;

    /*
     * Per-LUN reference count.
     * percpu_ref_kill() is called during LUN removal — after that,
     * percpu_ref_tryget_live() returns false, blocking new commands.
     */
    struct percpu_ref           lun_ref;

    /*
     * lun_shutdown — set when LUN is being removed.
     * Used in conjunction with lun_ref to coordinate teardown.
     */
    bool                        lun_shutdown;
    bool                        lun_access_ro;     /* read-only */

    /*
     * ALUA state for this LUN's port.
     */
    struct t10_alua_tg_pt_gp    *lun_tg_pt_gp;
    spinlock_t                  lun_tg_pt_gp_lock;

    /*
     * Per-LUN ACL (links from se_node_acl).
     */
    struct se_lun_acl           *lun_acl;

    struct list_head            lun_list;
};
```

The `lun_ref` is the gate. When configfs removes a LUN:
```
echo 0 > /sys/kernel/config/target/iscsi/.../tpgt_1/lun/lun_0/enable
```
the kernel calls `core_tpg_remove_lun()` which calls `percpu_ref_kill(&lun->lun_ref)`. Subsequent
`transport_lookup_cmd_lun()` calls fail because `percpu_ref_tryget_live()` returns false — new
commands cannot bind to this LUN.

In-flight commands holding a reference complete normally; once they all drop their refs, the
percpu_ref's `release` function runs and the LUN object is freed.

---

## struct se_node_acl — `drivers/target/target_core_base.h`

The ACL for an initiator. Created via configfs when an initiator IQN is added to a TPG.

```c
struct se_node_acl {
    char                        initiatorname[TRANSPORT_IQN_LEN];

    /*
     * Backpointer to the TPG this ACL belongs to.
     */
    struct se_portal_group      *se_tpg;

    /*
     * LUN mappings — which LUNs this initiator can see.
     * One entry per mapped LUN.
     */
    struct hlist_head           lun_entry_hlist;

    /*
     * dynamic_node_acl: 1 = auto-created (generate_node_acl=1)
     *                  0 = manually created via configfs (static)
     */
    bool                        dynamic_node_acl;
    bool                        dynamic_stop;

    /*
     * Authentication info (CHAP, etc.).
     */
    struct iscsi_node_auth      node_auth;

    /*
     * Active sessions using this ACL.
     */
    struct list_head            acl_sess_list;
    spinlock_t                  device_list_lock;

    /*
     * ACL queue depth and other limits.
     */
    u32                         queue_depth;

    struct list_head            acl_list;
};
```

When an admin removes an initiator's ACL (`rmdir
/sys/kernel/config/target/iscsi/.../tpgt_1/acls/iqn.client.example`), the corresponding
`se_node_acl` is freed. Any active session for that initiator is forcibly torn down. This is the
target-side hook for fencing: deleting the ACL kills the session.

---

## struct se_device — `drivers/target/target_core_base.h`

The backstore device.

```c
struct se_device {
    /*
     * Backstore type: iblock, fileio, ramdisk, pscsi.
     * Determines which target_backend_ops table is used.
     */
    const struct target_backend_ops *transport;

    /*
     * Device-level state and locking.
     */
    spinlock_t                  dev_reservation_lock;
    struct se_session           *dev_reserved_node_acl;  /* SCSI-2 reserve only */

    /*
     * Persistent Reservation state (SPC-3/4).
     */
    struct t10_reservation      t10_pr;

    /*
     * Active commands and stats.
     */
    atomic_long_t               num_cmds;
    atomic_long_t               read_bytes;
    atomic_long_t               write_bytes;

    /*
     * Backstore identification.
     */
    char                        dev_alias[SE_DEV_ALIAS_LEN];
    char                        t10_wwn_unit_serial[INQUIRY_VPD_SERIAL_LEN];

    /*
     * SCSI device attributes (block size, max sectors, etc.).
     */
    struct se_dev_attrib        dev_attrib;

    /*
     * ALUA state — this device's target port group(s).
     */
    struct t10_alua             t10_alua;
};
```

`dev->t10_pr` is the central PR state — registrations, reservations, type — protected by
`dev->dev_reservation_lock`. Day 20 covers this in detail.

---

## struct target_core_fabric_ops — `include/target/target_core_fabric.h`

The fabric module's plug-in interface. Each fabric (iSCSI, FC, etc.) provides a complete table:

```c
struct target_core_fabric_ops {
    const char  *name;
    const char  *fabric_name;

    /* TPG / WWN configfs handlers */
    int         (*tpg_get_inst_index)(struct se_portal_group *);

    /* Session lifecycle */
    void        (*close_session)(struct se_session *);
    void        (*shutdown_session)(struct se_session *);

    /* Command lifecycle */
    void        (*release_cmd)(struct se_cmd *);
    int         (*write_pending)(struct se_cmd *);
    int         (*queue_data_in)(struct se_cmd *);
    int         (*queue_status)(struct se_cmd *);
    void        (*queue_tm_rsp)(struct se_cmd *);
    void        (*aborted_task)(struct se_cmd *);

    int         (*get_cmd_state)(struct se_cmd *);

    /* Fabric tweaks */
    u32         (*sess_get_index)(struct se_session *);
    u32         (*get_pr_transport_id)(struct se_node_acl *,
                                          struct t10_pr_registration *,
                                          int *, unsigned char *);

    /* Session helpers */
    struct se_wwn   *(*fabric_make_wwn)(struct target_fabric_configfs *,
                                          struct config_group *,
                                          const char *);
    void            (*fabric_drop_wwn)(struct se_wwn *);

    struct se_portal_group *(*fabric_make_tpg)(struct se_wwn *,
                                                struct config_group *,
                                                const char *);
    void                    (*fabric_drop_tpg)(struct se_portal_group *);
};
```

For iSCSI, this is `iscsi_ops` in `drivers/target/iscsi/iscsi_target_configfs.c`. The
`queue_data_in`, `queue_status`, `release_cmd`, `write_pending` callbacks are how the target core
hands off to the iSCSI fabric for actual PDU transmission and tear-down.

---

## Memory layout summary

```
se_session (per logged-in initiator)
    ├── sess_cmd_list (in-flight commands)
    │       ├── se_cmd #1 → t_data_sg (SGL) → backend pages
    │       ├── se_cmd #2 → ...
    │       └── ...
    ├── se_node_acl (which LUNs this initiator can see)
    │       └── lun_entry_hlist → se_lun #0, #1, ...
    └── fabric_sess_ptr → iscsit_session (iSCSI-specific state)

se_lun (per mapped LUN per TPG)
    ├── lun_se_dev → se_device (backstore)
    ├── lun_ref (percpu_ref — gates new commands during shutdown)
    └── lun_tg_pt_gp → ALUA TG_PT group

se_device (per backstore)
    ├── transport → target_backend_ops (iblock, fileio, ...)
    ├── t10_pr → registrations, holder, type
    ├── t10_alua → port groups, states
    └── dev_attrib → block size, max_sectors, emulate_*, etc.
```

---

## Key takeaways

- `se_session` is the I_T nexus on the target — one per logged-in initiator connection.
- `se_cmd` is one in-flight SCSI command. `transport_state` bitmap (`CMD_T_*`) tracks abort,
  active, complete, fabric-stop. CDB lives in `t_task_cdb`/`__t_task_cdb`.
- `se_lun` has `lun_ref` (percpu_ref) — the gate for blocking new commands during LUN removal.
  `percpu_ref_kill()` is what causes `transport_lookup_cmd_lun()` to fail.
- `se_node_acl` is the per-initiator ACL — removing it (configfs `rmdir`) tears down the session.
- `se_device` holds the backstore and `t10_pr` (PR state).
- `target_core_fabric_ops` is the fabric plug-in interface. iSCSI provides
  `queue_data_in`/`queue_status`/`release_cmd`/`write_pending` to do per-fabric I/O and
  cleanup.
- `CMD_T_TAS` makes target send TASK_ABORTED (0x40) to other initiators.
- `CMD_T_FABRIC_STOP` distinguishes fabric shutdown from per-command abort, ensuring
  `release_cmd` waits for in-flight I/O cleanly during teardown.

---

## Previous / Next

[Day 14 — dm-multipath PR ops and path management](day14.md) | [Day 16 — target_core_transport submit path](day16.md)
