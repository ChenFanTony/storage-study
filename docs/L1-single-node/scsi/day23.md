# Day 23 — ALUA

**Week 4**: Advanced Topics  
**Time**: 1–2 hours  
**Reference**: `drivers/target/target_core_alua.c`, `include/target/target_core_base.h`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

ALUA — Asymmetric Logical Unit Access (SPC-4 §5.11) — lets a target advertise per-port-group
state for each LUN: which paths are optimized for I/O, which are standby, which are
transitioning. dm-multipath uses this information through `scsi_dh_alua` to bias path selection.
For fencing, ALUA states are an alternative or complement to PR: a target can move a LUN's port
group to UNAVAILABLE for the fenced node and to ACTIVE/OPTIMIZED for the surviving node, and the
multipath layer handles the rest.

---

## ALUA states — `include/target/target_core_base.h`

```c
/* SPC-4 §5.11.2.7 — Asymmetric access state values */
#define ALUA_ACCESS_STATE_ACTIVE_OPTIMIZED       0x0
#define ALUA_ACCESS_STATE_ACTIVE_NON_OPTIMIZED   0x1
#define ALUA_ACCESS_STATE_STANDBY                0x2
#define ALUA_ACCESS_STATE_UNAVAILABLE            0x3
#define ALUA_ACCESS_STATE_LBA_DEPENDENT          0x4
#define ALUA_ACCESS_STATE_OFFLINE                0xE
#define ALUA_ACCESS_STATE_TRANSITION             0xF
```

What each state means for I/O:

| State | I/O allowed? | dm-multipath behavior |
|---|---|---|
| ACTIVE_OPTIMIZED (0x0) | yes, fast path | preferred — full bandwidth |
| ACTIVE_NON_OPTIMIZED (0x1) | yes, slower | usable; commands get optional `alua_nonop_delay_msec` delay |
| STANDBY (0x2) | no, NOT_READY | path failed; multipath retries elsewhere |
| UNAVAILABLE (0x3) | no, NOT_READY | path failed |
| LBA_DEPENDENT (0x4) | depends per LBA | rare — used for federated/ranged setups |
| OFFLINE (0xE) | no | path failed |
| TRANSITION (0xF) | no, NOT_READY | path is moving between states; retry |

For NOT_READY states the target sends sense `NOT READY (0x02) / 0x04 / <ascq>` where ASCQ
distinguishes:
- `0x0A` ASYMMETRIC ACCESS STATE TRANSITION
- `0x0B` TARGET PORT IN STANDBY STATE
- `0x0C` TARGET PORT IN UNAVAILABLE STATE

The initiator's `scsi_check_sense()` (day 5) maps these to NEEDS_RETRY → blk-mq requeue → another
path attempt by dm-multipath.

---

## struct t10_alua_tg_pt_gp — target port group

```c
/* include/target/target_core_base.h */
struct t10_alua_tg_pt_gp {
    char                    tg_pt_gp_name[ALUA_GROUP_NAME_LEN];

    /*
     * The current ALUA state for this group.
     */
    int                     tg_pt_gp_alua_access_state;

    /*
     * Implicit vs explicit transitions:
     *   implicit — target moves states on its own (e.g., based on
     *              backend events, controller failover)
     *   explicit — initiator moves states via SET TARGET PORT GROUPS CDB
     */
    int                     tg_pt_gp_alua_access_type;     /* TPGS_IMPLICIT_ALUA / EXPLICIT */

    /*
     * Configurable delay (ms) imposed on commands going through a
     * non-optimized path. Encourages multipath to drift toward optimized.
     */
    int                     tg_pt_gp_alua_nonop_delay_msecs;
    int                     tg_pt_gp_trans_delay_msecs;

    /*
     * Group ID — what the initiator sees in REPORT TARGET PORT GROUPS.
     */
    u16                     tg_pt_gp_id;

    /*
     * Members — the LUN ports that belong to this group.
     * Populated via configfs (echo /backstores/.../<dev>/alua/default_tg_pt_gp/...).
     */
    struct list_head        tg_pt_gp_lun_list;
    spinlock_t              tg_pt_gp_lock;

    /*
     * Pending state transition, if any.
     */
    struct delayed_work     tg_pt_gp_transition_work;
    int                     tg_pt_gp_alua_pending_state;

    /*
     * Counters for outstanding I/O during transition (must drain
     * before transition completes).
     */
    atomic_t                tg_pt_gp_ref_cnt;
    atomic_t                tg_pt_gp_alua_pending_count;

    struct se_device        *tg_pt_gp_dev;
};
```

A LUN belongs to exactly one tg_pt_gp at any time. Multiple LUNs can share a group; moving the
group's state moves all member LUNs together — the typical pattern for a controller failover
that affects many LUNs.

---

## State check on every command — `core_alua_state_check`

```c
/* Simplified — see drivers/target/target_core_alua.c. */
sense_reason_t core_alua_state_check(struct se_cmd *cmd, char *cdb,
                                       u8 *alua_ascq)
{
    struct se_lun *lun = cmd->se_lun;
    struct t10_alua_tg_pt_gp *tg_pt_gp;
    int alua_access_state;

    /*
     * Some CDBs are always allowed regardless of ALUA state per SPC-4
     * §5.11.2.7 Table 36:
     *   INQUIRY, REPORT LUNS, REPORT TARGET PORT GROUPS,
     *   SET TARGET PORT GROUPS, READ MEDIA SERIAL NUMBER,
     *   REQUEST SENSE, RECEIVE DIAGNOSTIC RESULTS, SEND DIAGNOSTIC,
     *   PERSISTENT RESERVE IN, PERSISTENT RESERVE OUT, ACCESS CONTROL IN,
     *   ACCESS CONTROL OUT, etc.
     *
     * Without these always-allowed commands, ALUA discovery and PR-based
     * fencing would deadlock when a path is in STANDBY.
     */
    if (target_alua_cdb_always_allowed(cdb))
        return 0;

    spin_lock(&lun->lun_tg_pt_gp_lock);
    tg_pt_gp = lun->lun_tg_pt_gp;
    if (!tg_pt_gp) {
        spin_unlock(&lun->lun_tg_pt_gp_lock);
        return 0;  /* no ALUA configured */
    }
    alua_access_state = tg_pt_gp->tg_pt_gp_alua_access_state;
    spin_unlock(&lun->lun_tg_pt_gp_lock);

    switch (alua_access_state) {
    case ALUA_ACCESS_STATE_ACTIVE_OPTIMIZED:
        return 0;  /* fast path */

    case ALUA_ACCESS_STATE_ACTIVE_NON_OPTIMIZED:
        /*
         * Optionally apply nonop_delay_msec — slows commands on this
         * path. msleep_interruptible so signals (TMF, abort) can wake.
         */
        if (tg_pt_gp->tg_pt_gp_alua_nonop_delay_msecs)
            msleep_interruptible(tg_pt_gp->tg_pt_gp_alua_nonop_delay_msecs);
        return 0;

    case ALUA_ACCESS_STATE_STANDBY:
        *alua_ascq = ASCQ_04H_ALUA_TGT_PORT_STANDBY;
        return TCM_CHECK_CONDITION_NOT_READY;

    case ALUA_ACCESS_STATE_UNAVAILABLE:
        *alua_ascq = ASCQ_04H_ALUA_TGT_PORT_UNAVAILABLE;
        return TCM_CHECK_CONDITION_NOT_READY;

    case ALUA_ACCESS_STATE_TRANSITION:    /* 0xF */
        *alua_ascq = ASCQ_04H_ALUA_STATE_TRANSITION;
        return TCM_CHECK_CONDITION_NOT_READY;

    case ALUA_ACCESS_STATE_OFFLINE:       /* 0xE */
        *alua_ascq = ASCQ_04H_ALUA_OFFLINE;
        return TCM_CHECK_CONDITION_NOT_READY;

    case ALUA_ACCESS_STATE_LBA_DEPENDENT:
        /*
         * Per-LBA decision. Rare. Caller (target_setup_cmd_from_cdb)
         * checks each LBA against the group's table.
         */
        return target_alua_lba_dependent_check(cmd);
    }

    return 0;
}
```

This check runs in `target_setup_cmd_from_cdb()` (day 16) — before the reservation check.
A path in STANDBY rejects every I/O before any backend work.

---

## State transitions — explicit (initiator-driven)

```c
/* Simplified — see core_alua_do_port_transition. */
int core_alua_do_port_transition(struct se_device *dev,
                                   struct t10_alua_tg_pt_gp *tg_pt_gp,
                                   int explicit, int new_state)
{
    int old_state, transition_allowed;

    spin_lock(&tg_pt_gp->tg_pt_gp_lock);
    old_state = tg_pt_gp->tg_pt_gp_alua_access_state;

    /*
     * Validate the transition. Some moves are illegal (e.g., from
     * UNAVAILABLE directly to ACTIVE_OPTIMIZED without going through
     * TRANSITION first).
     */
    transition_allowed = core_alua_check_transition(old_state, new_state);
    if (!transition_allowed) {
        spin_unlock(&tg_pt_gp->tg_pt_gp_lock);
        return -EINVAL;
    }

    /*
     * Set state to TRANSITION first.
     * During this window, all I/O on this path returns NOT_READY/
     * STATE_TRANSITION — initiator retries on other paths.
     */
    tg_pt_gp->tg_pt_gp_alua_pending_state = new_state;
    tg_pt_gp->tg_pt_gp_alua_access_state =
        ALUA_ACCESS_STATE_TRANSITION;
    spin_unlock(&tg_pt_gp->tg_pt_gp_lock);

    /*
     * Queue UNIT ATTENTION on every initiator using LUNs in this group:
     *   06h/2Ah/06h = ASYMMETRIC ACCESS STATE CHANGED
     * This signals "rediscover ALUA state on next command".
     */
    list_for_each_entry(lun, &tg_pt_gp->tg_pt_gp_lun_list, lun_tg_pt_gp_link) {
        list_for_each_entry(sess, &dev->dev_sess_list, sess_list) {
            /*
             * core_scsi3_ua_allocate() walks the session's nexus
             * device entries and queues a UA for the LUN.
             */
            core_scsi3_ua_allocate(sess->se_node_acl,
                                     lun->unpacked_lun, 0x2A, 0x06);
        }
    }

    /*
     * Wait for in-flight commands targeting this group to drain.
     * Drainage is bounded by trans_delay_msecs.
     */
    if (tg_pt_gp->tg_pt_gp_trans_delay_msecs)
        msleep_interruptible(tg_pt_gp->tg_pt_gp_trans_delay_msecs);

    /*
     * Commit the new state.
     */
    spin_lock(&tg_pt_gp->tg_pt_gp_lock);
    tg_pt_gp->tg_pt_gp_alua_access_state = new_state;
    tg_pt_gp->tg_pt_gp_alua_pending_state = 0;
    spin_unlock(&tg_pt_gp->tg_pt_gp_lock);

    return 0;
}
```

---

## SET TARGET PORT GROUPS CDB — `target_emulate_set_target_port_groups`

The wire CDB that explicit-mode initiators use:

```
opcode 0xA4 (MAINTENANCE OUT), service action 0x0A (SET TARGET PORT GROUPS)
parameter list per target port group:
  byte 0: ASYMMETRIC ACCESS STATE (4 bits — new state)
  bytes 2-3: TARGET PORT GROUP (16 bits — group ID)
```

Userspace `multipathd` can drive this through SG_IO when `multipath.conf` has
`hardware_handler "1 alua"` and the target advertises explicit ALUA.

---

## Implicit transitions — target-driven

The target can move states on its own — for example, when a backend goes offline:

```c
/* Pseudocode — illustrating the trigger pattern. */
void backend_failure_handler(struct se_device *dev)
{
    struct t10_alua_tg_pt_gp *tg_pt_gp = dev->t10_alua.default_tg_pt_gp;

    if (!tg_pt_gp)
        return;

    /*
     * Backend just failed. Move the group to UNAVAILABLE so the
     * initiators stop sending I/O down this path.
     */
    core_alua_do_port_transition(dev, tg_pt_gp, false /* implicit */,
                                   ALUA_ACCESS_STATE_UNAVAILABLE);
}
```

Implicit transitions don't require SET TARGET PORT GROUPS from the initiator; the target just
moves state and queues UA. Initiators discover via REPORT TARGET PORT GROUPS or via the UA on
their next command.

---

## REPORT TARGET PORT GROUPS — initiator's discovery CDB

```
opcode 0xA3 (MAINTENANCE IN), service action 0x0A
returns: per-group descriptors with:
  - asymmetric access state
  - status code (last reason for state change)
  - target port group ID
  - target port count + descriptors
```

`scsi_dh_alua` (the kernel's ALUA device handler) issues this command after seeing a
state-changed UA. The result populates dm-multipath's per-path state — paths in STANDBY/UNAV are
moved out of the active priority group automatically.

---

## ALUA + dm-multipath integration

```
multipath device created
    │
    ▼
multipath.conf has hardware_handler "1 alua"
    │
    ▼
each path's scsi_device gets attached to scsi_dh_alua
    │
    ▼
scsi_dh_alua sends INQUIRY → reads TPGS bits (implicit/explicit support)
    │
    ▼
scsi_dh_alua sends REPORT TARGET PORT GROUPS
    │
    ▼
for each path:
    state = ACTIVE_OPTIMIZED → assign to high-priority pg
    state = ACTIVE_NON_OPTIMIZED → assign to low-priority pg
    state = STANDBY/UNAV → mark path failed initially
    │
    ▼
choose_pgpath() prefers high-priority pg → sends I/O to optimized paths only
    │
    ▼
Target moves state (implicit) → sends UA on next command
    │
    ▼
scsi_dh_alua sees UA, re-reads TPG, updates path priorities
    │
    ▼
multipathd reconfigures pg priorities → I/O migrates to new optimized paths
```

---

## ALUA-based fencing

A target-side admin can implement fencing without PR:

1. Cluster decides node A is fenced.
2. Target removes node A's ACL OR target moves node A's LUN port group to
   ALUA_ACCESS_STATE_UNAVAILABLE.
3. Node A's commands return NOT_READY/UNAVAILABLE.
4. dm-multipath on node A retries on other paths — but those are also UNAVAILABLE for node A.
5. After `no_path_retry` exhausts: bios queue (`queue_if_no_path=1`) or fail (-EIO).

ALUA-based fencing is "soft" like PR fencing: connectivity is maintained, only access is
restricted. It's simpler than PR (no key management, no `multipathd` PR plugin) but per-LUN
granularity is courser (per-group, not per-initiator).

PR vs ALUA tradeoff:
- **PR**: fine-grained per-initiator control. Cluster-driven from any node. Survives target
  reboots (with APTPL). Initiators must register and `multipathd` must support PR.
- **ALUA**: target-side decision. Coarser (per group). No client-side support needed beyond
  `scsi_dh_alua`. Doesn't survive target reboot unless the orchestrator re-applies state.

---

## Key takeaways

- ALUA states (`ALUA_ACCESS_STATE_*`) tell initiators which paths to use. ACTIVE_OPTIMIZED is
  the fast path; STANDBY/UNAVAILABLE/OFFLINE/TRANSITION are reasons to retry elsewhere.
- `core_alua_state_check()` runs in `target_setup_cmd_from_cdb()` and returns
  TCM_CHECK_CONDITION_NOT_READY with appropriate ASCQ for inactive states. Always-allowed CDBs
  (INQUIRY, REPORT LUNS, REPORT TARGET PORT GROUPS, REQUEST SENSE, PR IN/OUT, etc.) bypass.
- `t10_alua_tg_pt_gp` is the per-group state. LUNs belong to exactly one group. Moving the
  group's state moves all member LUNs together.
- Transitions: explicit (initiator-driven via SET TARGET PORT GROUPS CDB) or implicit
  (target-driven). State change queues UA `06h/2Ah/06h` so initiators rediscover.
- `scsi_dh_alua` (initiator-side device handler) consumes REPORT TARGET PORT GROUPS results
  and biases dm-multipath path selection.
- ALUA-based fencing is an alternative to PR: target moves a node's group to UNAVAILABLE.
  Simpler than PR but coarser (per-group) and doesn't survive target reboot without external
  state.

---

## Previous / Next

[Day 22 — Task Management Functions](day22.md) | [Day 24 — configfs control plane](day24.md)
