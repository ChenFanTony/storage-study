# Day 24 — configfs control plane

**Week 4**: Advanced Topics  
**Time**: 1–2 hours  
**Reference**: `drivers/target/target_core_configfs.c`, `drivers/target/iscsi/iscsi_target_configfs.c`, `drivers/target/target_core_tpg.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

LIO is administered through configfs at `/sys/kernel/config/target/`. There are no ioctls or
netlink commands — every operation (create backstore, define TPG, add LUN, add ACL,
enable/disable) is a filesystem write. `targetcli` is a userspace shell that drives this
filesystem. Understanding the configfs layout and the kernel hooks behind each write is essential
for the ACL-removal fencing approach (day 25).

---

## configfs layout

```
/sys/kernel/config/target/
├── core/
│   └── iblock_0/                       # an HBA
│       └── disk0/                      # a backstore
│           ├── alua/
│           │   └── default_tg_pt_gp/
│           │       ├── alua_access_state    # 0..F (day 23)
│           │       ├── alua_access_type     # 1 implicit, 2 explicit, 3 both
│           │       └── members
│           ├── pr/
│           │   ├── res_aptpl_active         # APTPL toggle (day 20)
│           │   ├── res_holder
│           │   └── res_pr_registered_i_pts
│           ├── attrib/                  # block size, max_sectors, emulate_*, etc.
│           ├── statistics/
│           └── enable                   # 0|1 — enable backstore
└── iscsi/                              # iSCSI fabric module
    └── iqn.2025-01.com.example:tgt0/   # a target IQN (the "wwn" / target-name)
        └── tpgt_1/                     # Target Portal Group 1
            ├── acls/
            │   └── iqn.client.example/  # an initiator ACL
            │       ├── lun_0/           # mapped LUN for this ACL
            │       │   └── ...
            │       ├── auth/            # CHAP credentials
            │       └── attrib/          # queue_depth, etc.
            ├── attrib/                  # demo_mode, generate_node_acls, etc.
            ├── lun/
            │   └── lun_0/
            │       └── storage_object → /backstores/iblock_0/disk0
            ├── np/                      # network portals (ip:port pairs)
            └── enable                   # 0|1 — TPG accepting logins
```

Each directory and file is created/removed by mkdir/rmdir or echo, and the kernel module
intercepts the operation through `configfs_attribute` and `configfs_subsystem` callbacks.

---

## Backstore creation

```bash
# create an iblock backstore for /dev/sdb
mkdir /sys/kernel/config/target/core/iblock_0/disk0
echo "/dev/sdb" > /sys/kernel/config/target/core/iblock_0/disk0/udev_path
echo 1 > /sys/kernel/config/target/core/iblock_0/disk0/enable
```

What happens in the kernel:

```c
/* mkdir intercepted by configfs subsystem at target/core/iblock_0/ */

/* Simplified — see drivers/target/target_core_iblock.c. */
static struct se_device *iblock_alloc_device(struct se_hba *hba,
                                                const char *name)
{
    struct iblock_dev *ib_dev = kzalloc(sizeof(*ib_dev), GFP_KERNEL);
    /* attach to hba */
    return &ib_dev->dev;
}

/* later: echo /dev/sdb > udev_path triggers iblock_set_configfs_dev_params */
static ssize_t iblock_set_configfs_dev_params(struct se_device *dev,
                                                 const char *page,
                                                 ssize_t count)
{
    struct iblock_dev *ib_dev = IBLOCK_DEV(dev);
    /* parse "udev_path=/dev/sdb" */
    snprintf(ib_dev->ibd_udev_path, sizeof(ib_dev->ibd_udev_path),
             "%s", path);
    return count;
}

/* echo 1 > enable triggers iblock_configure_device (day 21) */
static int iblock_configure_device(struct se_device *dev)
{
    /* blkdev_get_by_path(), bioset_init(), probe attrs ... */
    return 0;
}
```

After `enable=1`, the device is online and ready to be mapped into a TPG.

---

## TPG creation

```bash
# create iSCSI target IQN and TPG
mkdir /sys/kernel/config/target/iscsi/iqn.2025-01.com.example:tgt0
mkdir /sys/kernel/config/target/iscsi/iqn.2025-01.com.example:tgt0/tpgt_1
```

```c
/* Simplified — see drivers/target/iscsi/iscsi_target_configfs.c. */
static struct se_wwn *iscsi_target_make_tiqn(struct target_fabric_configfs *tf,
                                                struct config_group *group,
                                                const char *name)
{
    struct iscsi_tiqn *tiqn;

    tiqn = iscsit_add_tiqn((unsigned char *)name);
    if (IS_ERR(tiqn))
        return ERR_CAST(tiqn);

    return &tiqn->tiqn_wwn;
}

static struct se_portal_group *iscsi_target_make_tpg(struct se_wwn *wwn,
                                                       struct config_group *group,
                                                       const char *name)
{
    struct iscsi_tiqn *tiqn = container_of(wwn, struct iscsi_tiqn, tiqn_wwn);
    struct iscsi_portal_group *tpg;
    u16 tpgt;

    /* parse "tpgt_1" → tpgt = 1 */
    if (sscanf(name, "tpgt_%hu", &tpgt) != 1)
        return ERR_PTR(-EINVAL);

    tpg = iscsit_alloc_portal_group(tiqn, tpgt);
    if (!tpg)
        return ERR_PTR(-ENOMEM);

    return &tpg->tpg_se_tpg;
}
```

---

## LUN attach

```bash
# map the backstore as LUN 0 of this TPG
mkdir /sys/kernel/config/target/iscsi/iqn.2025-01.com.example:tgt0/tpgt_1/lun/lun_0
ln -s /sys/kernel/config/target/core/iblock_0/disk0 \
      /sys/kernel/config/target/iscsi/iqn.2025-01.com.example:tgt0/tpgt_1/lun/lun_0/storage_object
```

```c
/* Simplified. */
static struct config_group *target_fabric_make_lun(struct config_group *group,
                                                     const char *name)
{
    struct se_lun *lun;
    struct se_portal_group *se_tpg = container_of(...);
    u64 unpacked_lun;

    /* parse "lun_0" → unpacked_lun = 0 */
    if (kstrtoull(name + 4, 0, &unpacked_lun) < 0)
        return ERR_PTR(-EINVAL);

    lun = core_tpg_alloc_lun(se_tpg, unpacked_lun);
    if (IS_ERR(lun))
        return ERR_CAST(lun);

    /* configfs group hooks for storage_object symlink etc. */
    return &lun->lun_group;
}

/* the symlink to storage_object triggers core_dev_add_lun() which binds
 * the LUN to its se_device and initializes lun_ref (percpu_ref). */
```

After this, the LUN is visible via REPORT LUNS to any initiator with the right ACL.

---

## ACL creation — the fencing hook

```bash
# allow this initiator IQN to access the TPG
mkdir /sys/kernel/config/target/iscsi/iqn.2025-01.com.example:tgt0/tpgt_1/acls/iqn.client.example
# map LUN 0 within this ACL
mkdir /sys/kernel/config/target/iscsi/iqn.2025-01.com.example:tgt0/tpgt_1/acls/iqn.client.example/lun_0
ln -s ../../../lun/lun_0 \
      /sys/kernel/config/target/iscsi/iqn.2025-01.com.example:tgt0/tpgt_1/acls/iqn.client.example/lun_0/...
```

```c
/* Simplified — see drivers/target/iscsi/iscsi_target_configfs.c. */
static struct se_node_acl *iscsi_target_make_nodeacl(
    struct se_portal_group *se_tpg,
    const char *name)
{
    struct se_node_acl *se_nacl_new, *se_nacl;
    struct iscsi_portal_group *tpg = container_of(se_tpg, ...);
    u32 cmdsn_depth;

    /*
     * core_tpg_check_initiator_node_acl() — defined in
     * drivers/target/target_core_tpg.c — performs the lookup that
     * decides whether to create a new ACL or return an existing one.
     * Behaviour depends on tpg_attrib.generate_node_acls.
     */
    se_nacl = core_tpg_check_initiator_node_acl(se_tpg,
                                                  (unsigned char *)name);
    if (IS_ERR(se_nacl))
        return se_nacl;

    cmdsn_depth = tpg->tpg_attrib.default_cmdsn_depth;
    se_nacl->queue_depth = cmdsn_depth;

    return se_nacl;
}
```

The function `core_tpg_check_initiator_node_acl()` lives in
`drivers/target/target_core_tpg.c`. It searches the TPG's ACL list for the IQN. If found:
return existing. If not:
- `generate_node_acls=1` (dynamic mode): auto-create a placeholder ACL with default LUN
  mappings.
- `generate_node_acls=0` (static mode, default in many configurations): only allow IQNs that
  have been explicitly added.

The default value of `generate_node_acls` has changed across LIO versions. Check the value for
your kernel before relying on it; for fencing-controlled environments the safest practice is to
explicitly set `generate_node_acls=0`.

For fencing, **static ACLs are essential**. Otherwise, a fenced initiator simply re-logs in,
gets an auto-generated ACL, and bypasses the fence.

---

## ACL removal — `rmdir` triggers session teardown

When the cluster decides to fence node A:

```bash
# remove node A's ACL — this is the fencing hook
rmdir /sys/kernel/config/target/iscsi/iqn.2025-01.com.example:tgt0/tpgt_1/acls/iqn.client.A
```

```c
/* Simplified. */
static void iscsi_target_drop_nodeacl(struct se_node_acl *se_nacl)
{
    struct se_portal_group *se_tpg = se_nacl->se_tpg;
    struct iscsi_portal_group *tpg = container_of(se_tpg, ...);

    core_tpg_del_initiator_node_acl(se_tpg, se_nacl, 1);
    /* this calls __core_tpg_del_initiator_node_acl() which:
     *   1. detaches the ACL from the TPG list
     *   2. iterates active sessions for this ACL
     *   3. calls iscsit_close_session() on each (day 25)
     *   4. frees per-LUN dev_entries
     *   5. kfree(se_nacl)
     */
}
```

The session is forcibly closed. The initiator's TCP connection sees an RST or FIN. Subsequent
reconnect attempts fail at Login because the IQN is no longer in the ACL list — Login Response
reports status class 0x02 (Initiator Error), detail 0x01 (Authentication Failure) or 0x03
(Initiator Not Found).

After `replacement_timeout` (open-iscsi userspace default 120s, pushed to the kernel via
sysfs), the initiator's session declares `RECOVERY_FAILED` → all paths fail → bios queue or
fail per `no_path_retry` setting (day 12).

---

## Disabling the LUN — the alternative fencing path

Instead of removing the ACL, an admin can disable the LUN globally:

```bash
echo 0 > /sys/kernel/config/target/iscsi/iqn.../tpgt_1/lun/lun_0/enable
```

But there's no `enable` attribute on `lun_X` in stock LIO — what's actually controlled is the
backstore's `enable`:

```bash
echo 0 > /sys/kernel/config/target/core/iblock_0/disk0/enable
```

When this is written:

```c
/* Simplified — see drivers/target/target_core_device.c. */
static ssize_t target_dev_enable_store(struct config_item *item,
                                          const char *page, size_t count)
{
    struct se_device *dev = to_device(item);
    int ret;
    bool flag;

    ret = kstrtobool(page, &flag);
    if (ret)
        return ret;

    if (flag) {
        ret = target_configure_device(dev);
    } else {
        /* disable: percpu_ref_kill on every LUN's lun_ref,
         * wait for in-flight commands to drain,
         * tear down backend connection */
        target_unconfigure_device(dev);
    }
    return count;
}
```

After this, `transport_lookup_cmd_lun()` (day 16) fails for every LUN backed by this device —
new commands return NOT READY immediately. dm-multipath sees the failures and retries on other
paths; if all paths back to the same backstore, all paths fail.

This approach is too coarse for fencing in most setups (it disables the LUN for ALL initiators,
not just the fenced one). Per-initiator fencing requires ACL removal or PR.

---

## TPG enable/disable

```bash
echo 0 > /sys/kernel/config/target/iscsi/iqn.../tpgt_1/enable
```

This stops the TPG from accepting new logins. Existing sessions are NOT torn down. Useful for
maintenance.

```c
static ssize_t lio_target_tpg_enable_store(struct config_item *item,
                                              const char *page, size_t count)
{
    struct iscsi_portal_group *tpg = ...;
    bool flag;

    if (kstrtobool(page, &flag) < 0)
        return -EINVAL;

    if (flag) {
        iscsit_tpg_enable_portal_group(tpg);
    } else {
        iscsit_tpg_disable_portal_group(tpg, /* force = */ 0);
        /* if force=1, also forcibly close all existing sessions */
    }
    return count;
}
```

For fencing, `force=1` (write `0` to enable when in use) is the heavy hammer — drops every
session on this TPG immediately.

---

## What targetcli does on top

`targetcli /backstores/iblock create disk0 /dev/sdb` translates to:
- `mkdir /sys/kernel/config/target/core/iblock_0/disk0`
- `echo "/dev/sdb" > .../udev_path`
- `echo 1 > .../enable`

Plus pretty-printing, error checking, persistence to JSON (`/etc/target/saveconfig.json`), and
restoration on boot via the `target` systemd unit.

For automated fencing scripts, calling configfs directly (no targetcli) is simplest:

```bash
#!/bin/bash
# fence-node.sh <fenced-node-iqn>
FENCED_IQN="$1"
ACL_PATH=/sys/kernel/config/target/iscsi/iqn.../tpgt_1/acls/$FENCED_IQN
[ -d "$ACL_PATH" ] && rmdir "$ACL_PATH"
```

A single rmdir does everything: detach ACL → close session → reject future logins.

---

## Key takeaways

- LIO has no ioctl interface — everything goes through configfs at
  `/sys/kernel/config/target/`.
- Backstore creation: mkdir under `core/<plugin>_N/`, write attributes, `echo 1 > enable`.
- TPG creation: mkdir under `iscsi/<iqn>/tpgt_N`. LUN attach: mkdir
  `tpgt_N/lun/lun_M` + symlink to a backstore.
- ACL creation: mkdir `tpgt_N/acls/<initiator-iqn>` →
  `iscsi_target_make_nodeacl()` calls `core_tpg_check_initiator_node_acl()` (in
  `drivers/target/target_core_tpg.c`). Behaviour depends on `generate_node_acls`.
- For fencing, `generate_node_acls=0` (static mode) is required — explicitly verify the value
  for your kernel and configure if needed; otherwise a fenced node simply re-creates its ACL on
  reconnect.
- ACL removal (`rmdir`) is the primary fencing hook: detaches ACL → closes session →
  rejects future logins.
- Backstore `enable=0` is too coarse for per-initiator fencing — affects all initiators.
- TPG `enable=0` (with force) drops every session on the TPG.
- `targetcli` is just a friendly wrapper around mkdir/echo to configfs.

---

## Previous / Next

[Day 23 — ALUA](day23.md) | [Day 25 — session teardown path](day25.md)
