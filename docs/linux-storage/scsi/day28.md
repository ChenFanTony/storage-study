# Day 28 — ERL1 and ERL2 error recovery

**Week 4**: Deep Cuts — TMF, ALUA, configfs, NVMe-oF, Sense Data
**Time**: 1–2 hours
**Reference**: `drivers/target/iscsi/iscsi_target_erl0.c`, `drivers/target/iscsi/iscsi_target_erl1.c`, `drivers/target/iscsi/iscsi_target_erl2.c`

---

## Overview

iSCSI defines three Error Recovery Levels (ERL). ERL=0 is what almost all production deployments
use — connection drop means restart. ERL=1 and ERL=2 add digest-error retransmission and
session-level task reassignment. Reading these files shows exactly what ERL=0 deliberately does
NOT handle, and how `ICF_OOO_CMDSN` and `ICF_GOT_LAST_DATAOUT` interact with recovery. It also
reveals the ICF_OOO_CMDSN + data interaction that was referenced in day 18.

---

## ERL=0: Connection-level recovery — `drivers/target/iscsi/iscsi_target_erl0.c`

ERL=0 is the baseline. On any transport error, the connection is dropped and all commands on it
are abandoned. The initiator reconnects and re-issues commands.

```c
/*
 * iscsit_handle_erl0_recovery() — called when the connection drops.
 *
 * For ERL=0: there is nothing to recover.
 * All in-flight commands on this connection are "lost" from the
 * target's perspective — they will not be retransmitted.
 *
 * iscsit_release_commands_from_conn() (day 25) already sets
 * CMD_T_ABORTED on all commands. Those commands complete without
 * a response PDU (CMD_T_FABRIC_STOP set).
 *
 * The initiator's SCSI layer sees DID_NO_CONNECT for all in-flight
 * commands when the session recovery times out (day 12).
 */
static void iscsit_handle_erl0_recovery(struct iscsi_conn *conn)
{
    /*
     * Reset the connection state machine.
     * No PDU retransmission. No SNACK. Just close and wait for reconnect.
     */
    iscsit_cause_connection_reinstatement(conn, 0);
}
```

Key implication for fencing: ERL=0 means once the TCP connection drops, the target does NOT
try to retransmit any response PDUs. The initiator gets no responses for in-flight commands —
they timeout via `replacement_timeout` and then fail with `DID_TRANSPORT_FAILFAST`. This is
the behavior we rely on for clean fencing.

---

## ERL=1: Digest error recovery — `drivers/target/iscsi/iscsi_target_erl1.c`

ERL=1 allows recovery from Header or Data digest mismatches without dropping the connection.

### SNACK — Selective Negative Acknowledgement

```c
/*
 * iscsit_handle_r2t_snack() — initiator requests R2T retransmission.
 *
 * If the initiator receives a corrupted R2T PDU (HeaderDigest mismatch),
 * it sends a SNACK (opcode 0x10) with:
 *   RunLength = number of missing PDUs
 *   BegRun    = starting DataSN or R2TSN of the missing range
 *
 * The target retransmits the requested R2T PDUs.
 */
int iscsit_handle_r2t_snack(struct iscsi_conn *conn,
                              unsigned char *buf)
{
    struct iscsi_snack *hdr = (struct iscsi_snack *)buf;
    struct iscsit_cmd *cmd;
    u32 beg_run = be32_to_cpu(hdr->begrun);
    u32 run_len = be32_to_cpu(hdr->runlength);

    /*
     * Find the command by ITT (Initiator Task Tag from SNACK PDU).
     */
    cmd = iscsit_find_cmd_from_itt(conn, hdr->itt);
    if (!cmd) {
        pr_err("SNACK: ITT 0x%08x not found\n", hdr->itt);
        return -1;
    }

    /*
     * Retransmit R2T PDUs in the range [beg_run, beg_run + run_len).
     * These PDUs were lost due to network corruption.
     *
     * The r2t_pool for this command still holds the R2T data,
     * so we can regenerate them without involving the backend again.
     */
    return iscsit_retransmit_r2ts(cmd, beg_run, run_len);
}
```

```c
/*
 * iscsit_handle_data_ack() — called when initiator ACKs received data.
 *
 * For ERL=1 with DataDigest: initiator ACKs each Data-In PDU.
 * Target tracks DataACK SNACK responses to know which data was received.
 * If ACK is missing for a PDU: retransmit that PDU.
 *
 * ICF_GOT_DATACK_SNACK flag: set when a DataACK SNACK is received.
 * This flag is checked in the TX path to know we need to retransmit.
 */
static int iscsit_handle_data_ack(struct iscsi_conn *conn,
                                   struct iscsi_snack *hdr)
{
    struct iscsit_cmd *cmd;
    u32 ack_sn = be32_to_cpu(hdr->begrun);

    cmd = iscsit_find_cmd_from_itt(conn, hdr->itt);
    if (!cmd)
        return -1;

    /*
     * Mark that we received a DataACK SNACK.
     * ICF_GOT_DATACK_SNACK tells the TX path that the initiator
     * has confirmed receipt of data up to ack_sn.
     */
    cmd->cmd_flags |= ICF_GOT_DATACK_SNACK;
    cmd->acked_data_sn = ack_sn;

    return 0;
}
```

---

## ICF_OOO_CMDSN — out-of-order CmdSN interaction with data

The interaction between out-of-order CmdSN and write data that we referenced in day 18:

```c
/*
 * Scenario: initiator sends commands in order A(CmdSN=5), B(CmdSN=6).
 * Network delivers B before A. Target receives B first.
 *
 * iscsit_handle_scsi_cmd() for B:
 *   iscsit_sequence_cmd() → CMDSN_HIGHER_THAN_EXP (5 expected, got 6)
 *   cmd_B queued on sess->ooo_cmdsn_list
 *   ICF_OOO_CMDSN set on cmd_B
 *   iscsit_process_scsi_cmd() NOT called yet for cmd_B
 *
 * If cmd_B is a WRITE with InitialR2T=No:
 *   Problem: the target called target_submit_cmd() and set up Data-Out receive,
 *   but we haven't called target_submit_cmd() yet (cmd is OOO-queued).
 *
 * Solution: when cmd_A finally arrives and its CmdSN fills the gap,
 *   iscsit_execute_cmd() is called to re-drive cmd_B.
 *   At that point, if ICF_GOT_LAST_DATAOUT is ALSO set on cmd_B
 *   (all write data arrived while it was OOO-queued):
 *     target_execute_cmd() is called directly — data is ready.
 *   If ICF_GOT_LAST_DATAOUT is NOT set:
 *     target_submit_cmd() is called and the write data path begins.
 */

static int iscsit_execute_cmd(struct iscsit_cmd *cmd, int ooo)
{
    struct se_cmd *se_cmd = &cmd->se_cmd;
    struct iscsi_conn *conn = cmd->conn;
    int ret;

    /*
     * Re-drive an out-of-order command after its CmdSN gap is filled.
     * ooo=1: this was an OOO command being re-driven.
     */
    if (cmd->data_direction == DMA_TO_DEVICE) {
        if (cmd->cmd_flags & ICF_GOT_LAST_DATAOUT) {
            /*
             * All write data arrived (via Data-Out PDUs) while the
             * command was OOO-queued. We can execute directly.
             *
             * This is the only place where ICF_GOT_LAST_DATAOUT is
             * checked OUTSIDE of iscsit_check_dataout_payload().
             */
            target_execute_cmd(se_cmd);
            return 0;
        }
        /*
         * Data not yet complete — call target_submit_cmd() to set up
         * the write data receive path. Data-Out PDUs will follow.
         */
    }

    ret = iscsit_process_scsi_cmd(conn, cmd,
                                   (struct iscsi_scsi_req *)cmd->pdu);
    return ret;
}
```

This is the complete ICF_OOO_CMDSN + ICF_GOT_LAST_DATAOUT interaction:

```
Write command arrives OOO (CmdSN=6, expected=5):
    iscsit_handle_scsi_cmd()
    → CMDSN_HIGHER_THAN_EXP
    → ICF_OOO_CMDSN set on cmd
    → cmd queued on ooo_cmdsn_list
    → iscsit_process_scsi_cmd() NOT called

Data-Out PDUs arrive for this command (same ITT):
    iscsit_handle_data_out()
    → iscsit_check_dataout_payload()
    → F-bit=1, write_data_done == data_length
    → ICF_GOT_LAST_DATAOUT set
    → NORMALLY: target_execute_cmd() called
    → BUT: ICF_OOO_CMDSN is set → skip target_execute_cmd()
    →      (command is still OOO-queued, can't execute yet)

CmdSN=5 (the gap) finally arrives:
    iscsit_handle_scsi_cmd() for CmdSN=5
    → CMDSN_NORMAL_OPERATION
    → iscsit_process_scsi_cmd() called for CmdSN=5

Gap filled: iscsit_execute_ooo_cmdsn() re-drives CmdSN=6:
    iscsit_execute_cmd(cmd_6, ooo=1)
    → cmd_6->cmd_flags & ICF_GOT_LAST_DATAOUT is TRUE
    → target_execute_cmd() called directly
    → backend I/O begins
```

---

## ERL=2: Session-level recovery — `drivers/target/iscsi/iscsi_target_erl2.c`

ERL=2 allows commands to survive connection drops via TASK_REASSIGN TMF.

```c
/*
 * iscsit_handle_task_reassign() — ERL=2 only.
 *
 * When a connection drops (ERL=2), the initiator can:
 *   1. Reconnect and establish a new connection on the same session
 *   2. Send TASK_REASSIGN TMF for each in-flight command
 *   3. Target reassigns the command to the new connection
 *   4. Resume Data-Out or Data-In from where it left off
 *
 * This is extremely complex and rarely implemented.
 * Almost no iSCSI deployments use ERL=2 in production.
 */
int iscsit_handle_task_reassign(struct iscsi_conn *conn,
                                 unsigned char *buf)
{
    struct iscsi_tm *hdr = (struct iscsi_tm *)buf;
    struct iscsit_cmd *cmd;

    /*
     * Find the command being reassigned by Referenced Task Tag (rtt).
     * The command must still be active on the old connection.
     */
    cmd = iscsit_find_cmd_from_rtt(conn->sess, hdr->rtt);
    if (!cmd) {
        /*
         * Command not found: either already completed or never existed.
         * Return TMR_TASK_DOES_NOT_EXIST.
         */
        return iscsit_task_reassign_complete(conn, hdr,
                                              TASK_REASSIGN_DOES_NOT_EXIST);
    }

    /*
     * Check ICF_GOT_LAST_DATAOUT to decide reassignment behavior:
     *
     * If ICF_GOT_LAST_DATAOUT is SET:
     *   All write data was already received before the connection dropped.
     *   The command is in the backend (or awaiting dispatch).
     *   Reassignment just moves the response path to the new connection.
     *   No need to re-collect write data.
     *
     * If ICF_GOT_LAST_DATAOUT is NOT set (write command, data incomplete):
     *   Data collection must restart.
     *   Target resets write_data_done to the checkpoint.
     *   Initiator will re-send Data-Out PDUs from the checkpoint offset.
     */
    if (cmd->cmd_flags & ICF_GOT_LAST_DATAOUT) {
        /*
         * Data complete. Just reassign the connection and
         * let the response go to the new connection.
         */
        return iscsit_task_reassign_complete_write(cmd, hdr, conn);
    }

    /*
     * Data incomplete. Reassign and restart data collection.
     * The DataSN and offset checkpoint is stored in cmd->write_data_done.
     */
    return iscsit_task_reassign_complete(conn, hdr,
                                          TASK_REASSIGN_REASSIGNED);
}
```

```c
/*
 * iscsit_task_reassign_complete_write() — ERL=2 write reassignment
 * when ICF_GOT_LAST_DATAOUT is set.
 */
static int iscsit_task_reassign_complete_write(struct iscsit_cmd *cmd,
                                                struct iscsi_tm *hdr,
                                                struct iscsi_conn *conn)
{
    /*
     * Move the command to the new connection.
     * The se_cmd is still valid — it may be in target_submission_wq
     * or already executing in the backend.
     */
    iscsit_reassign_cmd_to_conn(cmd, conn);

    /*
     * Since ICF_GOT_LAST_DATAOUT is set, we know the backend I/O
     * was already submitted (or is about to be submitted).
     * The response will now go to the new connection when it arrives.
     */
    return 0;
}
```

---

## ERL comparison table

| Feature | ERL=0 | ERL=1 | ERL=2 |
|---|---|---|---|
| Header digest recovery | No — drop connection | Yes — SNACK retransmit | Yes |
| Data digest recovery | No — drop connection | Yes — Data-Out re-request | Yes |
| Command recovery across connection drop | No | No | Yes — TASK_REASSIGN |
| ICF_GOT_LAST_DATAOUT usage | Gate for execute | Gate for execute | Gate for reassign path |
| ICF_OOO_CMDSN interaction | Deferred execute | Same | Same |
| Production usage | Ubiquitous | Rare | Almost never |
| Complexity | Low | Medium | Very high |
| LIO implementation | Complete | Complete | Partial (basic) |

---

## ERL=0 and fencing

For our fencing context, ERL=0 behavior is exactly what we want:

```
Connection drop (TCP RST from target after ACL removal):
    ERL=0 behavior:
    → No SNACK, no retransmit, no task reassignment
    → iscsit_release_commands_from_conn() aborts all commands
    → All aborted commands complete without response (CMD_T_FABRIC_STOP)
    → Initiator: all in-flight commands → DID_NO_CONNECT (after EH)
    → dm-multipath: fail_path() after replacement_timeout

ERL=1/2 would complicate fencing:
    ERL=1: initiator might SNACK for retransmission after reconnect
           But reconnect is blocked (ACL removed) → SNACK never arrives
           → same end result, just with extra retry attempts
    ERL=2: initiator might attempt TASK_REASSIGN on new connection
           But new connection blocked (ACL removed) → TASK_REASSIGN never sent
           → same end result

Conclusion: ERL=0 is the cleanest for fencing. ERL=1/2 add complexity
but don't change the end result when the ACL is removed.
```

---

## Key takeaways

- ERL=0: connection drop → all commands lost, no recovery. Production standard.
- ERL=1: digest errors → SNACK → retransmit. `ICF_GOT_DATACK_SNACK` tracks ACKed data.
- ERL=2: connection drop → TASK_REASSIGN → command moves to new connection. Almost never used.
- `ICF_OOO_CMDSN` + `ICF_GOT_LAST_DATAOUT` interaction: when a write command arrives OOO and its
  data arrives while it's still queued (OOO), the data is buffered and `ICF_GOT_LAST_DATAOUT`
  is set but `target_execute_cmd()` is skipped. When `iscsit_execute_cmd()` re-drives the command
  (after gap fills), it sees `ICF_GOT_LAST_DATAOUT` and calls `target_execute_cmd()` directly.
- In ERL=2's `iscsit_task_reassign_complete_write()`, `ICF_GOT_LAST_DATAOUT` determines whether
  data collection needs to restart — the only other place besides `iscsit_check_dataout_payload()`
  where this flag is the decision point.
- For fencing: ERL=0 is cleanest. ERL=1/2 add retry complexity but blocked reconnect (ACL
  removed) ensures the same end result — `DID_TRANSPORT_FAILFAST` → `fail_path()`.

---

## Previous / Next

[Day 27 — iSCSI login sequence](day27.md) | [Day 29 — SCSI sense data generation](day29.md)
