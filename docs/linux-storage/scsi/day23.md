# Day 23 — ALUA

**Week 4**: Deep Cuts — TMF, ALUA, configfs, NVMe-oF, Sense Data
**Time**: 1–2 hours
**Reference**: `drivers/target/target_core_alua.c`

---

## Overview

ALUA (Asymmetric Logical Unit Access) is the mechanism by which a storage target exposes
different access states on different target ports. It is the foundation of active-active and
active-passive HA configurations. On the initiator side, dm-multipath uses ALUA state information
to select optimized paths. On the target side, LIO implements ALUA via Target Port Groups (TPGs)
and per-port access states. Every incoming I/O command is checked against the ALUA state of the
target port it arrived on.

---

## ALUA concepts

```
Target Port Group (TPGT):
    A set of target ports with the same access state.
    Access state applies to the WHOLE group simultaneously.

Access states (per TPGT):
    Active/Optimized (A/O)     = preferred path, full performance
    Active/Non-Optimized (A/N) = working but suboptimal (secondary path)
    Standby                    = not processing I/O, will transition if needed
    Unavailable                = not accessible
    Offline (vendor-specific)  = administratively disabled
    Transitioning              = changing between states

Initiator behavior:
    dm-multipath selects Active/Optimized paths first.
    Falls back to Active/Non-Optimized if A/O paths fail.
    Does not use Standby/Unavailable paths.
```

---

## Key structs — `drivers/target/target_core_alua.c`

```c
/*
 * t10_alua: per-device ALUA state.
 * Embedded in se_device.
 */
struct t10_alua {
    enum alua_type          alua_type;        /* ALUA_ACCESS_TYPE_* */
    spinlock_t              lock;

    /* list of all target port groups for this device */
    struct list_head        tg_pt_gps_list;
    u32                     alua_tg_pt_gps_count;
};

/*
 * t10_alua_tg_pt_gp: one target port group.
 * A group has an ID, an access state, and a list of ports in the group.
 */
struct t10_alua_tg_pt_gp {
    u16                     tg_pt_gp_id;          /* group ID (1-based) */

    /*
     * Current access state for all ports in this group.
     * ALUA_ACCESS_STATE_* values:
     *   0x0 = Active/Optimized
     *   0x1 = Active/Non-Optimized
     *   0x2 = Standby
     *   0x3 = Unavailable
     *   0xf = Offline (LIO extension)
     */
    int                     tg_pt_gp_alua_access_state;

    /* for transition: pending target state */
    int                     tg_pt_gp_alua_pending_state;
    int                     tg_pt_gp_alua_previous_state;

    /*
     * Non-optimized delay: ms to sleep before processing I/O
     * on an Active/Non-Optimized path. Forces initiator to prefer A/O.
     * Default: 100ms.
     */
    int                     tg_pt_gp_nonop_delay_msecs;

    /* transition delay: ms between state change checks */
    int                     tg_pt_gp_trans_delay_msecs;

    /* transition work item */
    struct delayed_work      tg_pt_gp_transition_work;

    struct list_head         tg_pt_gp_list;       /* link in t10_alua.tg_pt_gps_list */
    struct list_head         tg_pt_gp_mem_list;   /* all ports in this group */

    atomic_t                 tg_pt_gp_ref_cnt;

    /* configfs */
    struct config_group      tg_pt_gp_group;
    struct se_device         *tg_pt_gp_dev;
};
```

---

## core_alua_state_check — called on every command

```c
/*
 * Called from target_submit_cmd() for every incoming SCSI command.
 * Checks the ALUA state of the target port this command arrived on.
 *
 * Returns:
 *   TCM_NO_SENSE (0)         = access allowed
 *   TCM_ALU_TG_PT_STANDBY    = port in Standby state → NOT READY
 *   TCM_ALUA_TG_PT_UNAVAILABLE = port Unavailable → NOT READY
 *   TCM_CHECK_CONDITION_UNIT_ATTENTION = transitioning → UA
 */
sense_reason_t core_alua_state_check(struct se_cmd *cmd)
{
    struct se_device *dev  = cmd->se_dev;
    struct se_lun    *lun  = cmd->se_lun;
    struct t10_alua_tg_pt_gp *tg_pt_gp;
    int out_alua_state, nonop;

    if (!lun->lun_tg_pt_gp)
        return TCM_NO_SENSE;  /* no ALUA configured — allow all */

    tg_pt_gp = lun->lun_tg_pt_gp;

    /*
     * Read the current access state atomically.
     * No lock needed for reading — state changes are atomic.
     */
    out_alua_state = tg_pt_gp->tg_pt_gp_alua_access_state;

    switch (out_alua_state) {
    case ALUA_ACCESS_STATE_ACTIVE_OPTIMIZED:
        /*
         * Best case: full speed, no delay.
         * Allow all commands immediately.
         */
        return TCM_NO_SENSE;

    case ALUA_ACCESS_STATE_ACTIVE_NON_OPTIMIZED:
        /*
         * Non-optimized: I/O is allowed but we delay it slightly
         * to encourage the initiator to use an optimized path instead.
         *
         * tg_pt_gp_nonop_delay_msecs (default 100ms):
         * The command is still executed, just with a delay.
         * dm-multipath notices the latency and prefers A/O paths.
         */
        nonop = tg_pt_gp->tg_pt_gp_nonop_delay_msecs;
        if (nonop > 0)
            msleep(nonop);
        return TCM_NO_SENSE;

    case ALUA_ACCESS_STATE_STANDBY:
        /*
         * Standby: port is not processing I/O.
         *
         * Returns TCM_ALUA_TG_PT_STANDBY →
         *   transport_generic_request_failure() →
         *   sense: NOT READY, ASC=0x04, ASCQ=0x0B
         *          (LOGICAL UNIT NOT ACCESSIBLE, TARGET PORT IN STANDBY STATE)
         *
         * Initiator receives CHECK CONDITION with this sense.
         * dm-multipath: NOT_READY → path failure → tries another group.
         */
        return TCM_ALUA_TG_PT_STANDBY;

    case ALUA_ACCESS_STATE_UNAVAILABLE:
        /*
         * Unavailable: sense NOT READY, ASC=0x04, ASCQ=0x0C
         *              (LOGICAL UNIT NOT ACCESSIBLE, TARGET PORT IN UNAVAILABLE STATE)
         */
        return TCM_ALUA_TG_PT_UNAVAILABLE;

    case ALUA_ACCESS_STATE_TRANSITION:
        /*
         * ALUA state transition in progress.
         * Returns UNIT ATTENTION: ALUA TG PT TRANSITIONING
         * sense key=UNIT_ATTENTION, ASC=0x29, ASCQ=0x06
         *
         * Initiator should retry after the transition completes.
         */
        return TCM_CHECK_CONDITION_UNIT_ATTENTION;

    case ALUA_ACCESS_STATE_OFFLINE:
        /* LIO-specific: administratively offline */
        return TCM_ALUA_TG_PT_UNAVAILABLE;

    default:
        return TCM_NO_SENSE;
    }
}
```

---

## core_alua_check_nonop_delay — implementing the delay

```c
/*
 * For Active/Non-Optimized paths, LIO adds a configurable delay
 * to each command to discourage initiators from using this path.
 *
 * The delay is implemented with msleep() inside the target_submission_wq
 * worker thread. This is acceptable because:
 *   1. Non-optimized paths carry less traffic by design
 *   2. The delay is short (default 100ms) and configurable
 *   3. The target_submission_wq has unlimited workers (WQ_MEM_RECLAIM, 0)
 *      so other commands are not blocked by this sleep
 */
static void core_alua_check_nonop_delay(struct t10_alua_tg_pt_gp *tg_pt_gp)
{
    if (!tg_pt_gp->tg_pt_gp_nonop_delay_msecs)
        return;

    if (in_interrupt())
        return;  /* can't sleep in interrupt context */

    /*
     * msleep_interruptible: sleep but can be woken by signal.
     * If a TMF abort arrives for this command during the delay,
     * the signal will wake msleep and the abort can proceed.
     */
    msleep_interruptible(tg_pt_gp->tg_pt_gp_nonop_delay_msecs);
}
```

---

## core_alua_do_port_transition — state change — `drivers/target/target_core_alua.c`

Admin or automated transition (e.g. on path failure):

```c
int core_alua_do_port_transition(struct t10_alua_tg_pt_gp *l_tg_pt_gp,
                                  struct se_device *l_dev,
                                  struct se_port *l_port,
                                  struct se_node_acl *l_nacl,
                                  int new_state,
                                  int explicit)
{
    struct se_device *dev;
    struct t10_alua_tg_pt_gp *tg_pt_gp;
    int prev_state;

    /*
     * Set state to TRANSITIONING atomically.
     * Commands arriving during transition get UNIT ATTENTION (transitioning).
     */
    prev_state = l_tg_pt_gp->tg_pt_gp_alua_access_state;
    l_tg_pt_gp->tg_pt_gp_alua_access_state = ALUA_ACCESS_STATE_TRANSITION;

    /*
     * Wait for transition delay (tg_pt_gp_trans_delay_msecs, default 3000ms).
     * This gives in-flight I/O time to complete before the state switches.
     */
    if (l_tg_pt_gp->tg_pt_gp_trans_delay_msecs)
        msleep_interruptible(l_tg_pt_gp->tg_pt_gp_trans_delay_msecs);

    /*
     * Apply new state.
     * All subsequent commands on this TPG will see the new state.
     */
    l_tg_pt_gp->tg_pt_gp_alua_access_state = new_state;
    l_tg_pt_gp->tg_pt_gp_alua_previous_state = prev_state;

    /*
     * Issue UNIT ATTENTION to ALL sessions accessing this device.
     * UA: ASYMMETRIC ACCESS STATE CHANGED
     * sense key=UNIT_ATTENTION, ASC=0x2A, ASCQ=0x06
     *
     * Every initiator's next command will get CHECK CONDITION.
     * dm-multipath: on UNIT ATTENTION → retry → re-query ALUA state
     * → discovers new preferred paths → updates routing.
     */
    core_scsi3_ua_allocate_non_block(l_dev, l_nacl, 0x2A, 0x06);

    /*
     * If IMPLICIT ALUA transition (not explicit from host):
     * log the transition for management visibility.
     */
    if (!explicit) {
        pr_debug("ALUA[%s]: Implicit transition from %s to %s\n",
                 l_tg_pt_gp->tg_pt_gp_group.cg_item.ci_name,
                 core_alua_dump_state(prev_state),
                 core_alua_dump_state(new_state));
    }

    return 0;
}
```

---

## REPORT TARGET PORT GROUPS — SCSI command

Initiators discover ALUA state via the `REPORT TARGET PORT GROUPS` command (opcode `0xA3/0x0A`).
LIO emulates this command entirely in target_core_alua.c:

```c
/*
 * core_emulate_report_target_port_groups() builds the response:
 *
 * For each target port group:
 *   Byte 0[7:4] = PREF (preferred group flag)
 *   Byte 0[3:0] = ALUA_ACCESS_STATE_*
 *   Byte 1      = ALUA_SUPPORT_* flags (T_SUP, U_SUP, S_SUP, AN_SUP, AO_SUP)
 *   Bytes 2-3   = Target Port Group ID (big-endian)
 *   Byte 4      = Status code (active, standby, unavailable, transitioning, ...)
 *   Byte 5      = Vendor Specific
 *   Byte 6      = Initiator ports count
 *   Byte 7      = (reserved)
 *   [port descriptor list: each port's Relative Target Port ID]
 *
 * dm-multipath reads this response via pg_init to determine which
 * paths are optimized and which are non-optimized.
 */
```

---

## SET TARGET PORT GROUPS — explicit ALUA transition

```c
/*
 * Initiator can request an ALUA state change via:
 *   SET TARGET PORT GROUPS (opcode 0xA4/0x0A)
 *
 * Only allowed if ALUA type is EXPLICIT or BOTH.
 * Target validates the requested state transitions and applies them.
 *
 * Used by cluster software (Pacemaker, Corosync) to explicitly
 * promote/demote paths when doing planned failover.
 *
 * Example workflow:
 *   1. Controller A going down (planned)
 *   2. Controller B sends SET TARGET PORT GROUPS to promote its ports to A/O
 *   3. All initiators get UNIT ATTENTION (state changed)
 *   4. Initiators re-query REPORT TARGET PORT GROUPS
 *   5. dm-multipath switches to Controller B's ports
 */
```

---

## ALUA and dm-multipath interaction

```c
/*
 * When dm-multipath does path checking (via the path_checker polling):
 *
 * 1. Issues TEST UNIT READY to each path
 * 2. If TUR returns CHECK CONDITION / NOT_READY (STANDBY/UNAVAILABLE):
 *    → path marked as failing → pg_init triggered
 *
 * pg_init: dm-multipath queries ALUA state:
 *    Issues REPORT TARGET PORT GROUPS
 *    Parses response: which ports are A/O, A/N, Standby, etc.
 *    Updates path priorities:
 *      A/O paths get priority 50 (preferred)
 *      A/N paths get priority 10 (fallback)
 *      Standby/Unavailable: excluded from active pool
 *
 * After pg_init: multipath_map_bio() uses the updated path priorities
 * to route I/O to A/O paths preferentially.
 *
 * The nonop_delay in LIO reinforces this: if an initiator accidentally
 * sends I/O to an A/N path, the 100ms delay makes it "slow" enough
 * that the path selector switches to A/O.
 */
```

---

## Admin control via configfs

```bash
# View current ALUA state
cat /sys/kernel/config/target/iscsi/<iqn>/tpgt_1/param/AllaMode

# Change ALUA state for a target port group via sysfs
echo "Active/NonOptimized" > \
  /sys/kernel/config/target/core/iblock_0/<device>/alua/default_tg_pt_gp/alua_access_state

# Valid state strings:
#   Active/Optimized
#   Active/NonOptimized
#   Standby
#   Unavailable
#   Offline
```

Each write to `alua_access_state` calls `core_alua_do_port_transition()` with `explicit=1`.

---

## Key takeaways

- ALUA state is per-Target Port Group (TPGT), not per-LUN. All ports in a group share the state.
- `core_alua_state_check()` is called for every incoming command in `target_submit_cmd()`.
  Active/Optimized: immediate. Non-Optimized: delayed (default 100ms). Standby/Unavailable:
  CHECK CONDITION NOT_READY. Transitioning: UNIT ATTENTION.
- `core_alua_do_port_transition()` sets TRANSITIONING state, waits for delay, then sets new
  state and issues UNIT ATTENTION to all initiators.
- `REPORT TARGET PORT GROUPS` is the SCSI command dm-multipath uses (via pg_init) to discover
  which paths are optimized. LIO emulates this entirely in target_core_alua.c.
- The non-optimized delay (default 100ms) encourages initiators to prefer A/O paths without
  blocking I/O on A/N paths entirely.
- ALUA is how active-active HA is implemented: two controllers each have their own TPGT in
  Active/Optimized state for different LUNs. Failover = state transition + UNIT ATTENTION.

---

## Previous / Next

[Day 22 — Task Management Functions](day22.md) | [Day 24 — configfs: LIO control plane](day24.md)
