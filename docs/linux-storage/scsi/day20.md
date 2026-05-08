# Day 20 — LIO Persistent Reservations

**Week 3**: LIO Target Kernel Code  
**Time**: 1–2 hours  
**Reference**: `drivers/target/target_core_pr.c`, `include/target/target_core_base.h`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

The PR state machine in LIO is the heart of every fencing strategy. When the cluster says
"prevent node A from writing", the surviving node sends a `PERSISTENT RESERVE OUT PREEMPT`
that ends up here. Day 13/14 covered the initiator side; today is what happens on the target.

---

## struct t10_reservation — `include/target/target_core_base.h`

The per-device PR state, embedded in `se_device`:

```c
struct t10_reservation {
    /*
     * Generation counter — incremented on any change to PR state.
     * Initiators read it via PERSISTENT RESERVE IN READ KEYS to detect
     * stale views.
     */
    u32                         pr_generation;

    /*
     * Linked list of all registrations on this device.
     * One entry per (initiator IQN, ISID) tuple.
     */
    struct list_head            registration_list;
    spinlock_t                  registration_lock;

    /*
     * The current reservation holder (if any).
     * Points into registration_list.
     */
    struct t10_pr_registration  *pr_res_holder;
    int                         pr_res_type;       /* SCSI type byte: 0x01–0x08 */
    int                         pr_res_scope;      /* always LU_SCOPE = 0 */

    /*
     * APTPL — Activate Persist Through Power Loss.
     * If set, registrations and reservation survive target reboots.
     * Stored in /var/target/pr/ via configfs hooks.
     */
    int                         pr_aptpl_active;
    char                        pr_aptpl_buf[PR_APTPL_MAX_IPORT_LEN];

    /*
     * Holder's I_T nexus pointers (cached for fast checks in hot path).
     */
    struct se_node_acl          *pr_res_holder_acl;
    u64                         pr_res_holder_sa_res_key;
};
```

---

## struct t10_pr_registration — per-registration state

```c
struct t10_pr_registration {
    char                        pr_iport[PR_APTPL_MAX_IPORT_LEN];   /* IQN+ISID */
    char                        pr_tport[PR_APTPL_MAX_TPORT_LEN];   /* target portal */

    u64                         pr_res_key;        /* the registered key */
    u64                         pr_res_mapped_lun; /* LUN this is for */
    u32                         pr_res_generation;

    /*
     * Linkage: the I_T nexus this registration represents.
     */
    struct se_node_acl          *pr_reg_nacl;
    struct se_lun               *pr_reg_lun;
    struct se_dev_entry         *pr_reg_deve;

    /*
     * Holder flag: 1 if this registration currently holds the reservation.
     * Otherwise pr_res_holder in t10_reservation points to a different entry.
     */
    int                         pr_reg_all_tg_pt;  /* registered on all paths? */

    struct list_head            pr_reg_list;
    struct list_head            pr_reg_aptpl_list;
};
```

A registration represents one initiator-port to target-port path with a key. When an initiator
issues PR REGISTER on each of N paths, N entries are created — same `pr_iport` (IQN), same key,
different `pr_tport`s.

---

## CDB dispatch — target_core_pr.c

```c
/* Simplified — see drivers/target/target_core_pr.c. */
sense_reason_t target_scsi3_emulate_pr_out(struct se_cmd *cmd)
{
    unsigned char *cdb = cmd->t_task_cdb;
    u8 sa = cdb[1] & 0x1f;       /* service action — low 5 bits of byte 1 */
    u8 type = cdb[2] & 0x0f;     /* type — low 4 bits of byte 2 */
    u8 scope = (cdb[2] >> 4);    /* scope — high 4 bits — must be 0 (LU) */

    if (scope != PR_SCOPE_LU_SCOPE)
        return TCM_INVALID_CDB_FIELD;

    switch (sa) {
    case PRO_REGISTER:                /* 0x00 */
        return core_scsi3_emulate_pro_register(cmd, ...);
    case PRO_RESERVE:                 /* 0x01 */
        return core_scsi3_emulate_pro_reserve(cmd, type, ...);
    case PRO_RELEASE:                 /* 0x02 */
        return core_scsi3_emulate_pro_release(cmd, type, ...);
    case PRO_CLEAR:                   /* 0x03 */
        return core_scsi3_emulate_pro_clear(cmd, ...);
    case PRO_PREEMPT:                 /* 0x04 */
        return core_scsi3_emulate_pro_preempt(cmd, type, false);
    case PRO_PREEMPT_AND_ABORT:       /* 0x05 */
        return core_scsi3_emulate_pro_preempt(cmd, type, true);
    case PRO_REGISTER_AND_IGNORE:     /* 0x06 */
        return core_scsi3_emulate_pro_register(cmd, ..., true /* ignore */);
    case PRO_REGISTER_AND_MOVE:       /* 0x07 */
        return core_scsi3_emulate_pro_register_and_move(cmd, ...);
    default:
        return TCM_INVALID_CDB_FIELD;
    }
}
```

---

## REGISTER service action

```c
/* Simplified — illustrative; the real function handles many edge cases. */
static sense_reason_t core_scsi3_emulate_pro_register(struct se_cmd *cmd,
                                                       u64 res_key,
                                                       u64 sa_res_key,
                                                       int aptpl,
                                                       int all_tg_pt,
                                                       int spec_i_pt,
                                                       bool ignore_key)
{
    struct se_device *dev = cmd->se_dev;
    struct se_session *se_sess = cmd->se_sess;
    struct t10_pr_registration *pr_reg, *pr_reg_e;
    sense_reason_t ret = 0;

    spin_lock(&dev->t10_pr.registration_lock);

    /*
     * Find existing registration for this I_T nexus.
     */
    pr_reg_e = __core_scsi3_locate_pr_reg(dev, se_sess);

    if (pr_reg_e) {
        /*
         * Existing registration found — must match res_key (unless ignore_key).
         */
        if (!ignore_key && pr_reg_e->pr_res_key != res_key) {
            spin_unlock(&dev->t10_pr.registration_lock);
            return TCM_RESERVATION_CONFLICT;
        }

        if (sa_res_key == 0) {
            /*
             * sa_res_key=0 → unregister this initiator.
             * If this initiator was the holder, release the reservation.
             */
            if (dev->t10_pr.pr_res_holder == pr_reg_e)
                __core_scsi3_complete_pro_release(dev, ...);

            list_del(&pr_reg_e->pr_reg_list);
            kmem_cache_free(t10_pr_reg_cache, pr_reg_e);
        } else {
            /*
             * sa_res_key != 0 → update the key.
             */
            pr_reg_e->pr_res_key = sa_res_key;
        }
    } else {
        /*
         * No existing registration — create one.
         */
        if (sa_res_key == 0) {
            spin_unlock(&dev->t10_pr.registration_lock);
            return TCM_RESERVATION_CONFLICT;
        }

        /* GFP_KERNEL is appropriate here — we're in process context */
        pr_reg = kmem_cache_zalloc(t10_pr_reg_cache, GFP_KERNEL);
        if (!pr_reg) {
            spin_unlock(&dev->t10_pr.registration_lock);
            return TCM_OUT_OF_RESOURCES;
        }

        pr_reg->pr_res_key = sa_res_key;
        pr_reg->pr_reg_nacl = se_sess->se_node_acl;
        snprintf(pr_reg->pr_iport, ..., "%s,i,0x%s",
                 se_sess->se_node_acl->initiatorname, ...);

        list_add_tail(&pr_reg->pr_reg_list,
                       &dev->t10_pr.registration_list);
    }

    /*
     * Increment the generation counter — initiators see this in
     * READ_KEYS responses.
     */
    dev->t10_pr.pr_generation++;

    /*
     * If APTPL=1, persist to /var/target/pr/aptpl_*.
     */
    if (aptpl) {
        ret = core_scsi3_update_and_write_aptpl(dev, true);
    }

    spin_unlock(&dev->t10_pr.registration_lock);
    return ret;
}
```

---

## PREEMPT — the fencing primitive

```c
/* Simplified. */
static sense_reason_t core_scsi3_emulate_pro_preempt(struct se_cmd *cmd,
                                                      int type,
                                                      bool abort)
{
    struct se_device *dev = cmd->se_dev;
    struct se_session *se_sess = cmd->se_sess;
    struct t10_pr_registration *pr_reg, *pr_reg_n;
    struct t10_pr_registration *pr_holder;
    u64 res_key, sa_res_key;
    sense_reason_t ret;

    /*
     * Parse parameter list:
     *   res_key    = our existing key (must match our registration)
     *   sa_res_key = key of registration to preempt
     */

    spin_lock(&dev->t10_pr.registration_lock);

    pr_reg_n = __core_scsi3_locate_pr_reg(dev, se_sess);
    if (!pr_reg_n) {
        spin_unlock(&dev->t10_pr.registration_lock);
        return TCM_RESERVATION_CONFLICT;  /* we're not registered */
    }
    if (pr_reg_n->pr_res_key != res_key) {
        spin_unlock(&dev->t10_pr.registration_lock);
        return TCM_RESERVATION_CONFLICT;  /* wrong key */
    }

    pr_holder = dev->t10_pr.pr_res_holder;

    /*
     * For *_ALL_REGS types: sa_res_key=0 is allowed and means "preempt all
     * other registrations".
     */
    if (sa_res_key == 0 && !type_is_all_regs(dev->t10_pr.pr_res_type)) {
        spin_unlock(&dev->t10_pr.registration_lock);
        return TCM_INVALID_PARAMETER_LIST;
    }

    /*
     * Walk registration_list, removing every entry whose key matches
     * sa_res_key (or all of them for the all-regs case).
     */
    list_for_each_entry_safe(pr_reg, pr_reg_n,
                              &dev->t10_pr.registration_list,
                              pr_reg_list) {
        if (pr_reg == cmd_reg)
            continue;   /* don't remove our own */

        if (sa_res_key != 0 && pr_reg->pr_res_key != sa_res_key)
            continue;

        /*
         * Queue UNIT ATTENTION on the preempted initiator's nexus.
         * Sense will be: 0x06 / 0x2A / 0x03 = "RESERVATIONS PREEMPTED"
         * The next command from that initiator gets this UA.
         */
        core_scsi3_ua_allocate(pr_reg->pr_reg_nacl,
                                pr_reg->pr_res_mapped_lun,
                                0x2A, 0x03);

        /*
         * If PREEMPT_AND_ABORT (0x05): also abort all in-flight
         * commands from this initiator. Calls core_tmr_abort_task()
         * walking sess_cmd_list.
         */
        if (abort)
            core_scsi3_aborted_task_set(dev, pr_reg);

        list_del(&pr_reg->pr_reg_list);
        kmem_cache_free(t10_pr_reg_cache, pr_reg);
    }

    /*
     * If we preempted the holder: WE become the new holder.
     * Set type and scope from this PREEMPT command.
     */
    if (pr_holder && pr_holder_was_preempted) {
        dev->t10_pr.pr_res_holder = pr_reg_n;
        dev->t10_pr.pr_res_type = type;
        dev->t10_pr.pr_res_scope = PR_SCOPE_LU_SCOPE;
    }

    dev->t10_pr.pr_generation++;

    if (dev->t10_pr.pr_aptpl_active)
        core_scsi3_update_and_write_aptpl(dev, true);

    spin_unlock(&dev->t10_pr.registration_lock);
    return 0;
}
```

After this function returns, the preempted initiator's I_T nexus is no longer registered. Any
subsequent READ/WRITE from that initiator hits `target_check_reservation()` (day 16) and gets
`TCM_RESERVATION_CONFLICT` → status byte 0x18.

---

## The reservation check — `target_check_reservation`

```c
/* Simplified — illustrative shape; real function in drivers/target/target_core_pr.c. */
sense_reason_t target_check_reservation(struct se_cmd *cmd)
{
    struct se_device *dev = cmd->se_dev;
    struct t10_pr_registration *holder;
    u8 *cdb = cmd->t_task_cdb;
    u8 op = cdb[0];

    if (!dev->t10_pr.pr_res_holder)
        return 0;  /* no reservation — anyone can do anything */

    /*
     * Always-allowed CDBs per SPC-4 §5.8.6 (regardless of reservation):
     *   INQUIRY (0x12)
     *   REPORT LUNS (0xA0)
     *   REQUEST SENSE (0x03)
     *   RELEASE (6/10) (0x17/0x57)
     *   PERSISTENT RESERVE IN (0x5E)
     *   PERSISTENT RESERVE OUT (0x5F)
     *   READ CAPACITY (0x25/0x9E)
     *   START STOP UNIT (0x1B) — varies by config
     *   TEST UNIT READY (0x00)
     *
     * Without this list, fencing breaks: a fenced initiator must still
     * be able to call PR IN to read keys, REPORT LUNS to discover, etc.
     */
    if (target_pr_cdb_always_allowed(op))
        return 0;

    spin_lock(&dev->dev_reservation_lock);

    holder = dev->t10_pr.pr_res_holder;

    /* Are we the holder? */
    if (target_check_reservation_holder(cmd, holder)) {
        spin_unlock(&dev->dev_reservation_lock);
        return 0;
    }

    /* Type-specific access:
     *   PR_WRITE_EXCLUSIVE          : non-holders can read, not write
     *   PR_EXCLUSIVE_ACCESS         : non-holders cannot read or write
     *   PR_*_REG_ONLY               : registered non-holders share access
     *   PR_*_ALL_REGS               : every registered initiator shares
     */
    if (target_check_reservation_type_allows(cmd, holder)) {
        spin_unlock(&dev->dev_reservation_lock);
        return 0;
    }

    spin_unlock(&dev->dev_reservation_lock);

    /*
     * Conflict — return TCM_RESERVATION_CONFLICT.
     * scsi_status will become SAM_STAT_RESERVATION_CONFLICT (0x18).
     * No backend I/O. No sense data attached.
     */
    return TCM_RESERVATION_CONFLICT;
}
```

The PR check is synchronous and runs before backend dispatch. Cost: a single spinlock + list
walk. Latency: well under 1µs even for hundreds of registrations. PR conflict generation does
not consume backend I/O resources.

---

## Why PR fencing is robust

The full chain when a fencing PREEMPT arrives:

```
Surviving node sends PR PREEMPT (initiator side, day 13)
    │
    ▼
Initiator: scsi_execute_cmd() → blk_execute_rq() → iscsi_queuecommand()
TX → TCP → target
    │
    ▼
Target RX thread → iscsit_handle_scsi_cmd() (day 18)
    │
    ▼
target_submit_cmd() → target_setup_cmd_from_cdb()
    │  CDB = 0x5F PR OUT, sa=0x04 PREEMPT
    │  parse_cdb routes to target_scsi3_emulate_pr_out
    ▼
core_scsi3_emulate_pro_preempt()
    │  walks registration_list
    │  removes fenced node's registration
    │  queues UNIT ATTENTION on fenced node's nacl
    │  abort=true (PREEMPT_AND_ABORT) → aborts in-flight from fenced node
    │  if fenced node was holder → surviving node becomes holder
    │
    ▼
return TCM_NO_SENSE → status GOOD
    ▼
target_complete_cmd(SAM_STAT_GOOD) → response sent
    ▼
Surviving node: PR succeeded. From this moment:
    - fenced node's READ/WRITE → RESERVATION CONFLICT (status 0x18)
    - fenced node sees BLK_STS_RESV_CONFLICT (modern kernels)
    - blk_path_error() returns false → multipath does NOT fail path
    - application gets -EIO immediately on each I/O
```

The fenced node may still have a healthy TCP session — `iscsi_conn_failure()` doesn't fire,
sessions don't drop. PR is "soft" fencing: connectivity remains, only reservation-protected
I/O is blocked. If the cluster also wants hard isolation (e.g. node removed from network), a
separate STONITH action is needed.

---

## APTPL — surviving target reboots

```c
/* Simplified. */
int core_scsi3_update_and_write_aptpl(struct se_device *dev, bool active)
{
    char *aptpl_buf;
    int len;

    /*
     * Format:
     *   PR_REG_START
     *   initiator_iqn
     *   key
     *   ... per registration
     *   PR_REG_END
     *   reservation_holder_iport
     *   reservation_type
     *   ... etc
     *
     * Write to /var/target/pr/aptpl_<dev_alias>.
     * This is read at target startup by core_scsi3_load_pr_aptpl().
     */
    aptpl_buf = kzalloc(PR_APTPL_MAX_IPORT_LEN * 2, GFP_KERNEL);
    /* ... build buffer ... */

    return core_scsi3_update_aptpl_buf(dev, aptpl_buf, len);
}
```

When `target_core_pr_aptpl_active=1` is set on the device via configfs, every PR change is
persisted. After a reboot, `core_scsi3_load_pr_aptpl()` rebuilds `t10_reservation` from the file
— the cluster's fencing state survives target restarts.

---

## Why PR commands are not subject to no_path_retry=queue

A common confusion: "are PR commands themselves immune to the multipath hang?" The answer is
**yes, but for the right reason**:

- PR commands flow on the *initiator* via `dm_pr_ops` → `sd_pr_ops` → `scsi_execute_cmd()` →
  `blk_execute_rq()` (day 13/14). They never go through `multipath_map_bio()`, so they cannot
  enter `m->queued_bios`.
- On the *target* side, PR commands DO go through `target_submission_wq` like every other
  command. There is no special workqueue bypass.
- The "immunity" is structural at the initiator: PR uses a different code path entirely. As long
  as at least one TCP session is alive, the PR command reaches the target and gets a response.

This is the property that makes PR-based fencing reliable when normal I/O is hung. The fenced
node's normal I/O queues forever in `m->queued_bios`; the surviving node's PR commands fly
through unrelated to that queue.

---

## Reservation type semantics — the SCSI type byte

| Linux PR_* | Wire byte | Holder | Registered non-holder | Unregistered |
|---|---|---|---|---|
| WRITE_EXCLUSIVE | 0x01 | RW | R | R |
| EXCLUSIVE_ACCESS | 0x03 | RW | — | — |
| WRITE_EXCLUSIVE_REG_ONLY | 0x05 | RW | RW | R |
| EXCLUSIVE_ACCESS_REG_ONLY | 0x06 | RW | RW | — |
| WRITE_EXCLUSIVE_ALL_REGS | 0x07 | RW | RW | R |
| EXCLUSIVE_ACCESS_ALL_REGS | 0x08 | RW | RW | — |

For multipath fencing the typical type is `WRITE_EXCLUSIVE_ALL_REGS` (0x07): every registered
node has full read/write, unregistered nodes can only read. PREEMPT removes a registration →
that node becomes "unregistered" → can no longer write.

Always-allowed commands (INQUIRY, REPORT LUNS, REQUEST SENSE, PR IN/OUT, RELEASE) bypass these
rules so the fenced node can still discover the topology and observe state.

---

## Key takeaways

- `t10_reservation` lives in `se_device`. `registration_list` holds all per-I_T-nexus
  registrations; `pr_res_holder` points to the current reservation holder.
- PR OUT service actions: REGISTER, RESERVE, RELEASE, CLEAR, PREEMPT, PREEMPT_AND_ABORT,
  REGISTER_AND_IGNORE, REGISTER_AND_MOVE.
- Linux's `enum pr_type` (1–6) is NOT the same as the SCSI on-the-wire type byte (0x01–0x08).
  `sd_pr_type()` (initiator) and the target dispatcher do the translation.
- PREEMPT removes registrations matching the supplied key, queues UNIT ATTENTION on each, and
  optionally aborts in-flight commands (PREEMPT_AND_ABORT).
- `target_check_reservation()` is the gate. Always-allowed commands per SPC-4 (INQUIRY, REPORT
  LUNS, REQUEST SENSE, PR IN/OUT, RELEASE) bypass the check.
- TCM_RESERVATION_CONFLICT → status byte 0x18 → no sense attached by LIO. Modern initiators map
  to `BLK_STS_RESV_CONFLICT` and `blk_path_error()` returns false (no path failure).
- APTPL (`Activate Persist Through Power Loss`) persists PR state to
  `/var/target/pr/aptpl_<dev>` for survival across target reboots.
- PR commands are not subject to `no_path_retry=queue` because they take the initiator's
  passthrough path, not the dm-multipath bio path. The surviving node's PR PREEMPT can fly
  through even when normal I/O is hung.

---

## Previous / Next

[Day 19 — iSCSI fabric TX thread and Data-Out](day19.md) | [Day 21 — LIO backends](day21.md)
