# Day 24 — configfs: LIO control plane

**Week 4**: Deep Cuts — TMF, ALUA, configfs, NVMe-oF, Sense Data
**Time**: 1–2 hours
**Reference**: `drivers/target/target_core_configfs.c`, `drivers/target/iscsi/iscsi_target_configfs.c`

---

## Overview

configfs is the kernel filesystem that LIO uses as its control plane. Every `targetcli` command
ultimately writes to or reads from configfs. The kernel provides a generic configfs framework
(`fs/configfs/`) and LIO registers its objects into it. Understanding how a configfs write
translates to kernel struct changes — especially ACL deletion — is essential for implementing
the session-drop fencing approach cleanly.

---

## configfs object hierarchy

```
/sys/kernel/config/target/                    ← root (target_core_configfs.c)
    core/                                     ← backstores
        iblock_0/                             ← iblock subsystem
            <device_name>/                    ← se_device
                attrib/                       ← device attributes
                alua/                         ← ALUA port groups
    iscsi/                                    ← iSCSI fabric (iscsi_target_configfs.c)
        <target_iqn>/                         ← iscsi_tiqn
            tpgt_1/                           ← iscsi_tpg (Target Portal Group)
                param/                        ← session parameters
                portals/                      ← IP:port endpoints
                    <ip>:<port>/
                luns/                         ← LUN mappings
                    lun_0/
                        <link> → ../../core/iblock_0/<device>
                acls/                         ← initiator access control
                    <initiator_iqn>/          ← se_node_acl
                        attrib/
                        auth/
                        mapped_luns/
                            mapped_lun_0/
                                <link> → ../../../luns/lun_0
```

Each directory in this tree corresponds to a configfs `config_item` or `config_group`. Creating
a directory calls the `make_group()` callback. Deleting (rmdir) calls `drop_item()`.

---

## How configfs works — the kernel side

```c
/*
 * A configfs item has:
 *   - config_item_type: defines the operations (show, store, make, drop)
 *   - config_group: a directory that can contain children
 *   - configfs_attribute: a file with show/store callbacks
 *
 * Example: writing to an attribute file:
 *   echo "1" > /sys/kernel/config/target/core/iblock_0/dev/attrib/block_size
 *   → VFS write → configfs_write_iter() → attr->store(item, buf, len)
 *   → target_core attribute store callback
 */

/* Generic attribute structure */
struct configfs_attribute {
    const char  *ca_name;
    struct module *ca_owner;
    umode_t     ca_mode;
    ssize_t     (*show)(struct config_item *, char *);
    ssize_t     (*store)(struct config_item *, const char *, size_t);
};
```

---

## ACL creation — `drivers/target/iscsi/iscsi_target_configfs.c`

When `targetcli` does `acls create wwn=iqn.2024-01.com.example:host`:

```c
/*
 * mkdir /sys/kernel/config/target/iscsi/<tiqn>/tpgt_1/acls/<initiator_iqn>
 * → configfs calls make_group() for the acls directory
 * → iscsi_target_configfs.c's acl make_group callback:
 */
static struct config_group *iscsi_tpg_initiator_make_acl(
    struct config_group *group,
    const char *name)         /* name = initiator IQN string */
{
    struct iscsi_tpg_acl *acl;
    struct se_portal_group *se_tpg = group->cg_item.ci_parent...;
    struct se_node_acl *se_nacl;

    /*
     * core_tpg_add_initiator_node_acl() creates the se_node_acl:
     *   - allocates se_node_acl
     *   - copies initiatorname string
     *   - initialises lun_entry_hlist, acl_sess_list
     *   - adds to se_tpg->acl_node_list
     */
    se_nacl = core_tpg_add_initiator_node_acl(se_tpg, name);
    if (IS_ERR(se_nacl))
        return ERR_CAST(se_nacl);

    acl = kzalloc(sizeof(*acl), GFP_KERNEL);
    acl->se_nacl = se_nacl;
    config_group_init_type_name(&acl->acl_group,
                                 name,
                                 &iscsi_tpg_initiator_acl_cit);
    return &acl->acl_group;
}
```

---

## ACL deletion — the fencing control path

When `targetcli` does `acls delete wwn=<initiator_iqn>`:

```c
/*
 * rmdir /sys/kernel/config/target/iscsi/<tiqn>/tpgt_1/acls/<initiator_iqn>
 * → configfs calls drop_item()
 */
static void iscsi_tpg_initiator_drop_acl(
    struct config_group *group,
    struct config_item *item)
{
    struct iscsi_tpg_acl *acl = container_of(item, struct iscsi_tpg_acl, ...);
    struct se_portal_group *se_tpg = ...;

    /*
     * core_tpg_del_initiator_node_acl() removes the ACL:
     *   1. Removes se_nacl from se_tpg->acl_node_list
     *   2. Closes all active sessions for this initiator
     *   3. Frees se_nacl (after sessions drain)
     */
    core_tpg_del_initiator_node_acl(se_tpg, acl->se_nacl);

    kfree(acl);
}
```

```c
/* target_core_configfs.c */
int core_tpg_del_initiator_node_acl(struct se_portal_group *tpg,
                                     struct se_node_acl *acl)
{
    LIST_HEAD(sess_list);
    struct se_session *sess, *sess_tmp;
    unsigned long flags;
    int rc;

    mutex_lock(&tpg->acl_node_mutex);

    /*
     * Remove ACL from the TPG's ACL list.
     * New login attempts from this IQN will now fail:
     *   core_tpg_check_initiator_node_acl() returns NULL
     *   → login rejected with ISCSI_STATUS_CLS_INITIATOR_ERR
     */
    list_del(&acl->acl_list);

    /*
     * Collect all active sessions for this ACL.
     * Move them to a local list for teardown.
     */
    spin_lock_irqsave(&acl->acl_sess_lock, flags);
    list_splice_init(&acl->acl_sess_list, &sess_list);
    spin_unlock_irqrestore(&acl->acl_sess_lock, flags);

    mutex_unlock(&tpg->acl_node_mutex);

    /*
     * Close each active session.
     * For iSCSI: se_tfo->close_session() = iscsit_close_session()
     *
     * iscsit_close_session() (day 25):
     *   - Sends Async PDU (if configured) requesting logout
     *   - Waits for sess_cmd_list to drain
     *   - Closes TCP connection
     */
    list_for_each_entry_safe(sess, sess_tmp, &sess_list, sess_list) {
        struct se_portal_group *se_tpg = sess->se_tpg;
        se_tpg->se_tpg_tfo->close_session(sess);
    }

    /*
     * Wait for reference count on se_nacl to drop to 0.
     * In-flight commands hold a reference.
     */
    target_put_nacl(acl);

    return 0;
}
```

This is the exact code path that runs when `targetcli` deletes an ACL during fencing. It:
1. Removes the ACL → future logins rejected
2. Closes existing sessions → TCP torn down → EH triggered on initiator
3. Waits for in-flight commands to drain safely

---

## Login check — how ACL removal blocks reconnects

```c
/*
 * Called during iSCSI Login Phase to check if the initiator is allowed.
 * In iscsi_target_login.c → iscsit_process_login():
 */
struct se_node_acl *core_tpg_check_initiator_node_acl(
    struct se_portal_group *tpg,
    unsigned char *initiatorname)
{
    struct se_node_acl *acl;

    mutex_lock(&tpg->acl_node_mutex);

    /*
     * Linear search of tpg->acl_node_list for matching IQN.
     * If ACL was removed by core_tpg_del_initiator_node_acl():
     *   list_del(&acl->acl_list) removed it
     *   → this search returns NULL
     */
    list_for_each_entry(acl, &tpg->acl_node_list, acl_list) {
        if (!strcmp(acl->initiatorname, initiatorname)) {
            mutex_unlock(&tpg->acl_node_mutex);
            return acl;  /* found — login proceeds */
        }
    }

    mutex_unlock(&tpg->acl_node_mutex);

    /*
     * Not found.
     * If tpg->tpg_attrib.generate_node_acl = 1 (dynamic ACLs):
     *   Create a new ACL on-the-fly and allow login.
     * Else:
     *   Return NULL → login rejected.
     *
     * For fencing: ensure generate_node_acl = 0 (default in LIO).
     */
    if (tpg->tpg_attrib.generate_node_acl)
        return core_tpg_get_initiator_node_acl_dynamic(tpg, initiatorname);

    return NULL;  /* ← initiator is fenced: login rejected */
}
```

When this returns NULL, `iscsit_process_login()` sends a Login Response PDU with status
`ISCSI_STATUS_CLS_INITIATOR_ERR` (0x02) and reason `ISCSI_LOGIN_STATUS_TGT_NOT_FOUND` (0x01).

On the initiator side, this causes `iscsi_login_thread()` → `iscsi_login_failed()` →
`iscsi_conn_failure()`. The reconnect attempt fails. `replacement_timeout` counts down. After
120s: `ISCSI_STATE_RECOVERY_FAILED` → `DID_TRANSPORT_FAILFAST` → dm-multipath `fail_path()`.

---

## LUN enable/disable — `drivers/target/target_core_configfs.c`

```c
/*
 * echo 0 > /sys/kernel/config/target/core/iblock_0/<dev>/enable
 * → calls target_core_dev_enable_store()
 */
static ssize_t target_core_dev_enable_store(struct config_item *item,
                                              const char *page, size_t count)
{
    struct se_dev_attrib *da = to_attrib(item);
    struct se_device *dev    = da->da_dev;
    bool enable;

    if (strtobool(page, &enable))
        return -EINVAL;

    if (!enable) {
        /*
         * Disable the device.
         * Sets dev->dev_flags |= DF_SHUTDOWN.
         *
         * Effect: transport_lookup_cmd_lun() calls
         *   percpu_ref_tryget_live(&lun->lun_ref) which returns false
         *   → TCM_NON_EXISTENT_LUN → ILLEGAL REQUEST to initiator.
         *
         * In-flight commands complete normally.
         * New commands are rejected.
         *
         * This is the LUN offline mechanism.
         * For initiator with no_path_retry=queue: causes indefinite hang
         * (as discussed in day 7) because all paths return CHECK CONDITION
         * NOT_READY → dm-multipath marks all paths failed → queue_ios.
         */
        target_dev_setup_virtual_lba_map(dev);
    }

    return count;
}
```

This confirms the earlier analysis: LUN disable alone is not clean for fencing. It causes
`TCM_NON_EXISTENT_LUN` (or `NOT_READY` depending on implementation), which dm-multipath
treats as a path error, marking all paths failed, and `no_path_retry=queue` hangs.

---

## Session parameter attributes — `iscsi_target_configfs.c`

```c
/*
 * Reading/writing iSCSI session parameters via configfs:
 * cat /sys/kernel/config/target/iscsi/<tiqn>/tpgt_1/param/MaxRecvDataSegmentLength
 * → calls iscsi_tpg_param_show_attr()
 *
 * These parameters are the defaults for new sessions.
 * They are negotiated during Login Phase — the connection-specific
 * values end up in conn->conn_ops->MaxRecvDataSegmentLength.
 *
 * Key parameters for understanding write data paths (day 18):
 *   ImmediateData=Yes/No       → imm_data_en in iscsi_session
 *   InitialR2T=Yes/No          → initial_r2t_en
 *   FirstBurstLength=<bytes>   → first_burst
 *   MaxBurstLength=<bytes>     → max_burst
 *   MaxRecvDataSegmentLength=<bytes> → max_recv_dlength
 *   MaxOutstandingR2T=<n>      → max_r2t
 */
```

---

## Dynamic vs static ACLs

```c
/*
 * tpg->tpg_attrib.generate_node_acl controls ACL mode:
 *
 * Static ACLs (generate_node_acl=0, default):
 *   Admin must explicitly create ACL for each initiator IQN.
 *   Fencing is precise: remove specific IQN's ACL.
 *   targetcli: acls create wwn=<iqn> / acls delete wwn=<iqn>
 *
 * Dynamic ACLs (generate_node_acl=1):
 *   Any initiator can connect. ACL created automatically on first login.
 *   Fencing is harder: removing a dynamic ACL doesn't prevent reconnect
 *   because a new dynamic ACL would be created.
 *   For fencing with dynamic ACLs: need additional mechanism
 *   (firewall rule, IP-based block, or switch-level port disable).
 *
 * targetcli: /iscsi/<tiqn>/tpgt1 set attribute generate_node_acl=0
 */
```

---

## The fencing sequence through configfs

```bash
#!/bin/bash
# Fence a specific initiator via targetcli (configfs) + session drop

TARGET_IQN="iqn.2024-01.com.example:target"
INITIATOR_IQN="iqn.2024-01.com.example:host-to-fence"
TPGT="tpgt_1"

# Step 1: Remove ACL — blocks reconnect immediately
# (core_tpg_del_initiator_node_acl called → login check returns NULL)
targetcli /iscsi/${TARGET_IQN}/${TPGT}/acls \
    delete wwn=${INITIATOR_IQN}

# After this:
# - Existing session: still active (sessions are not force-closed yet
#   unless core_tpg_del_initiator_node_acl closes them — it does)
# - New login attempts: rejected with ISCSI_LOGIN_STATUS_TGT_NOT_FOUND
#
# core_tpg_del_initiator_node_acl() closes existing sessions via
# se_tfo->close_session() = iscsit_close_session()
# → iscsit_close_connection() → TCP teardown

echo "Initiator ${INITIATOR_IQN} fenced."
echo "Existing session torn down, reconnect blocked."
echo "Initiator replacement_timeout (120s) begins now."
echo "After 120s: DID_TRANSPORT_FAILFAST → dm-multipath fail_path()"
```

---

## Key takeaways

- configfs is LIO's control plane. Every `targetcli` operation maps to a VFS write/mkdir/rmdir
  on `/sys/kernel/config/target/`.
- ACL creation: `mkdir <initiator_iqn>` → `make_group()` → `core_tpg_add_initiator_node_acl()`.
- ACL deletion: `rmdir <initiator_iqn>` → `drop_item()` → `core_tpg_del_initiator_node_acl()`.
  This (1) removes ACL from list (blocking future logins), (2) closes active sessions via
  `se_tfo->close_session()`, (3) waits for se_nacl reference to drop.
- `core_tpg_check_initiator_node_acl()` is called during Login Phase. Returns NULL when ACL
  removed → login rejected with `ISCSI_STATUS_CLS_INITIATOR_ERR`.
- On initiator: login rejection → `iscsi_conn_failure()` → `replacement_timeout` → `RECOVERY_FAILED`
  → `DID_TRANSPORT_FAILFAST` → dm-multipath `fail_path()`.
- LUN disable (`echo 0 > enable`) is NOT clean for fencing with `no_path_retry=queue` — causes
  all paths to fail via `NOT_READY`, with no recovery trigger.
- Dynamic ACLs (`generate_node_acl=1`) make fencing harder — always use static ACLs in HA setups.

---

## Previous / Next

[Day 23 — ALUA](day23.md) | [Day 25 — session teardown path](day25.md)
