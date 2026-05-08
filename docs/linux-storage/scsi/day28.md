# Day 28 — ERL1 and ERL2 error recovery

**Week 4**: Advanced Topics  
**Time**: 1–2 hours  
**Reference**: `drivers/target/iscsi/iscsi_target_erl1.c`, `iscsi_target_erl2.c`, `drivers/scsi/libiscsi.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

iSCSI defines three Error Recovery Levels (ERL):

- **ERL=0**: session-level only. Any fatal error → drop session → reconnect.
- **ERL=1**: within-connection recovery. SNACK-based PDU retransmission for digest errors.
- **ERL=2**: connection recovery. Tasks can be reassigned to a new connection without restart.

In practice ERL=0 dominates production. ERL=1 is supported but rarely enabled in real workloads.
ERL=2 is partially implemented in LIO and largely deprecated on the initiator side after Mike
Christie's 2017 cleanup. Today's content covers what does exist for ERL>0 — useful when
diagnosing logs that mention SNACK or task reassign.

---

## SNACK PDU — RFC 7143 §10.16

SNACK is the recovery primitive for ERL=1. Sent by initiator (RX side) when it detects a
problem:

```
opcode 0x10 (SNACK Request)
flags:
  byte 1 bits 0-3: SNACK Type
    0x0 = Data/R2T SNACK    — request retransmission of Data-In or R2T
    0x1 = Status SNACK      — request retransmission of SCSI Response
    0x2 = DataACK           — acknowledge received Data-In (initiator → target)
    0x3 = R-Data SNACK      — request retransmission of Data-In with discrepancy

ITT:        the command this SNACK refers to
TargetTransferTag:  TTT to identify which R2T/transfer we mean
BegRun:     starting BegRun (DataSN or StatSN)
RunLength:  how many sequential PDUs we want
ExpStatSN:  next StatSN we expect
```

Use case: HeaderDigest or DataDigest CRC32C mismatch. Initiator's RX detects bad CRC, drops the
PDU, and sends a SNACK to ask for retransmission.

---

## Initiator side: detecting and requesting retransmit

```c
/* Simplified — illustrative; the libiscsi RX handles digest verification
 * and may issue a SNACK or fail the connection depending on negotiated ERL. */
static int iscsi_check_data_digest(struct iscsi_conn *conn,
                                     struct iscsi_segment *segment)
{
    u32 expected, actual;

    expected = segment->recv_digest;
    actual   = compute_crc32c(segment->data, segment->copied);

    if (expected == actual)
        return 0;  /* good */

    /* digest mismatch — corruption */

    if (conn->session->sess_ops->ErrorRecoveryLevel >= 1) {
        /* ERL>=1 — send SNACK, expect retransmission */
        iscsi_send_snack_recovery(conn, current_task);
        return -EAGAIN;  /* retry */
    } else {
        /* ERL=0 — drop session */
        iscsi_conn_failure(conn, ISCSI_ERR_DATA_DGST_ERROR);
        return -EIO;
    }
}
```

---

## Target side: handling SNACK — `drivers/target/iscsi/iscsi_target_erl1.c`

```c
/* Simplified — see drivers/target/iscsi/iscsi_target_erl1.c. */
int iscsit_handle_snack(struct iscsit_conn *conn, unsigned char *buf)
{
    struct iscsi_snack *hdr = (struct iscsi_snack *)buf;
    u8 type = hdr->flags & ISCSI_FLAG_SNACK_TYPE_MASK;
    int ret;

    /*
     * Verify ERL>=1 was negotiated.
     */
    if (conn->sess->sess_ops->ErrorRecoveryLevel < 1) {
        return iscsit_reject_cmd(conn, ISCSI_REASON_PROTOCOL_ERROR, buf);
    }

    switch (type) {
    case ISCSI_FLAG_SNACK_TYPE_DATA_OR_R2T:
        /*
         * Retransmit Data-In or R2T PDUs identified by BegRun..BegRun+RunLength.
         */
        ret = iscsit_handle_data_or_r2t_snack(conn, hdr);
        break;

    case ISCSI_FLAG_SNACK_TYPE_STATUS:
        /*
         * Retransmit SCSI Response PDUs identified by BegRun=StatSN.
         */
        ret = iscsit_handle_status_snack(conn, hdr);
        break;

    case ISCSI_FLAG_SNACK_TYPE_DATA_ACK:
        /*
         * Initiator is ACKing receipt of Data-In PDUs.
         * Allows target to drop retained copies (memory cleanup).
         */
        ret = iscsit_handle_data_ack(conn, hdr);
        break;

    case ISCSI_FLAG_SNACK_TYPE_RDATA:
        /* R-Data SNACK — handled similarly to DATA_OR_R2T */
        ret = iscsit_handle_data_or_r2t_snack(conn, hdr);
        break;

    default:
        ret = iscsit_reject_cmd(conn, ISCSI_REASON_PROTOCOL_ERROR, buf);
    }

    return ret;
}
```

For Status SNACK, the target must have retained the SCSI Response PDU after sending it (in case
the initiator misses it). Retention is controlled by negotiated parameters
`MaxOutstandingUnexpectedStatuses` and similar. Memory cost: typically modest (a few KB per
session) but adds up if many sessions are open with ERL>=1.

---

## DataACK — initiator clears target's retransmit buffers

```c
/* Simplified — illustrative shape. */
static int iscsit_handle_data_ack(struct iscsit_conn *conn,
                                    struct iscsi_snack *hdr)
{
    u32 begrun = be32_to_cpu(hdr->begrun);
    struct iscsit_cmd *cmd;

    cmd = iscsit_find_cmd_from_itt(conn, hdr->itt);
    if (!cmd)
        return -1;

    /*
     * Target had retained Data-In PDUs ≥ begrun in its retransmit buffer.
     * Initiator now ACKs receipt — drop them.
     */
    iscsit_drop_retained_data_in_pdus(cmd, begrun);

    return 0;
}
```

Without DataACK, the target retains every Data-In until... when? The spec says until the
command completes (Status ACK). DataACK lets the initiator say "I've safely processed up
through BegRun, so you can free buffers". Reduces target memory pressure.

---

## ERL=2: connection recovery and task reassignment

ERL=2 lets a session migrate active tasks to a new connection within the session, without
restarting the SCSI commands. Useful when one TCP connection of a multi-connection session
fails.

```c
/* Simplified — see drivers/target/iscsi/iscsi_target_erl2.c.
 * LIO target's ERL=2 support is partial; the function is named
 * iscsit_task_reassign_complete_*; semantics handle the typical cases.
 * Production deployments rarely exercise this code. */
int iscsit_task_reassign_complete_write(struct iscsit_cmd *cmd,
                                          struct iscsi_task_mgmt *tmf)
{
    /*
     * Task is being moved from old connection to new one (reassigned).
     * For a write task in mid-flight:
     *   - any Data-Out PDUs received on old connection are kept
     *   - new R2Ts will go on the new connection
     *   - state continuity preserved across the connection break
     */
    cmd->cmd_flags |= ICF_REASSIGNED;
    /* re-arm any pending R2T on the new connection */
    iscsit_send_r2ts_to_fe(cmd, /* new conn */, false);
    return 0;
}
```

The TASK REASSIGN TMF (function code 0x08) is the trigger. Initiator side stops the old
connection, opens a new one within the same session (same TSIH), and issues TASK REASSIGN to
move each in-flight ITT.

In practice: very few deployments use this. Multi-connection iSCSI itself is rare; using ERL=2
on top of MC/S even rarer. The code paths exist and are exercised by interop test suites.

---

## OOO_CMDSN handling — CmdSN window with gaps

When commands arrive out of order (different connections in MC/S, or initiator reordering), the
target must buffer them until the gap closes:

```c
/* Simplified — see drivers/target/iscsi/iscsi_target_util.c.
 * The actual function is iscsit_execute_ooo_cmdsns(). */
int iscsit_execute_ooo_cmdsns(struct iscsi_session *sess)
{
    struct iscsit_cmd *cmd, *cmd_p;
    struct iscsi_ooo_cmdsn *ooo_cmdsn;
    u32 ooo_count = 0;

    /*
     * sess->ooo_cmdsn_list holds out-of-order commands.
     * After each in-order command's exp_cmd_sn advances, walk the list
     * and execute any commands that are now in-order.
     */
    list_for_each_entry_safe(ooo_cmdsn, ..., &sess->ooo_cmdsn_list, ooo_list) {
        if (ooo_cmdsn->cmdsn != sess->exp_cmd_sn)
            break;  /* still gaps */

        cmd = ooo_cmdsn->cmd;

        /* now in-order — execute */
        cmd->cmd_flags |= ICF_GOT_LAST_DATAOUT;  /* if applicable */
        target_submit_cmd_map_sgls(&cmd->se_cmd, ...);

        /* advance window */
        sess->exp_cmd_sn++;
        ooo_count++;

        list_del(&ooo_cmdsn->ooo_list);
        kfree(ooo_cmdsn);
    }

    return ooo_count;
}
```

`ICF_OOO_CMDSN` is a marker the target uses to remember "this command was out-of-order when
received". After the gap closes and `iscsit_execute_ooo_cmdsns()` advances the queue, the
command is dispatched normally — the bit lets the TX path recognize that it's processing a
delayed-but-now-ordered command.

The interaction between `ICF_OOO_CMDSN` and `ICF_GOT_LAST_DATAOUT` is the key insight for OOO
write handling: a write command may have arrived OOO, all its Data-Out PDUs may have arrived
(both before and after the gap closed), but the target must wait for both conditions before
executing — the command must be in-order in the CmdSN window AND all data must be received.

---

## Why most production stays on ERL=0

The trade-offs:

| ERL=0 | ERL=1 | ERL=2 |
|---|---|---|
| Simple state | SNACK retransmit machinery | Full task reassignment state |
| Drop session on any error | Retransmit individual PDUs | Move tasks across connections |
| Recovery via reconnect | Recovery within session | Recovery within session, no restart |
| Trivially correct | Digest-driven retransmit | Complex synchronization |
| All initiators support | Most initiators support | Few deployments use |
| Replacement_timeout bound | No timeout for SNACK retry | Per-task reassign timeout |

For modern Ethernet (where digest errors are extremely rare — TCP checksums + Ethernet FCS
catch nearly everything), ERL>0 buys little. The code exists for completeness and historical
compatibility (legacy iSCSI HBAs that needed it).

For fencing analysis, ERL=0 is the correct mental model. Session drops cleanly on any failure;
recovery is the dm-multipath / replacement_timeout story (day 12).

---

## Why ERL>0 might be enabled

Niche reasons it might be turned on:
- Slow / lossy WAN iSCSI (rare; usually you'd run RDMA over WAN instead).
- Compliance requirement to support all RFC features.
- Interop testing of different vendors' implementations.
- Legacy applications that can't tolerate session resets.

For everyone else: leave at ERL=0. open-iscsi default is ERL=0, LIO accepts whatever the
initiator offers (capped at the kernel's max supported level).

---

## Diagnostic value

When debugging, knowing what ERL is negotiated tells you what to expect in logs:

- `Login parameters` showing `ErrorRecoveryLevel=0` → expect session drops, no SNACK/Reassign
  log lines.
- `ErrorRecoveryLevel=1` → may see "SNACK received" or "retransmit" log lines on digest errors.
- `ErrorRecoveryLevel=2` → may see "Task Reassign" log lines on connection failover.

If you see ERL=1/2 log lines but expected ERL=0, check your `iscsid.conf` and target config —
something has been overridden.

---

## Key takeaways

- ERL levels: 0 (session), 1 (PDU/SNACK), 2 (task reassignment). ERL=0 dominates production.
- SNACK (opcode 0x10) is the ERL=1 recovery primitive. Types: Data/R2T, Status, DataACK,
  R-Data.
- Status SNACK retransmission requires target to retain SCSI Response PDUs — small memory cost.
- DataACK lets initiator tell target "I have these PDUs, you can drop the retained copies".
- ERL=2 task reassignment is implemented in LIO partially, in libiscsi initiator largely
  removed in 2017 cleanup. Rarely exercised.
- OOO_CMDSN handling buffers commands that arrived before earlier ones; releases them as gaps
  close. `ICF_OOO_CMDSN` flag tracks this state. The interaction with `ICF_GOT_LAST_DATAOUT`
  matters for OOO writes.
- Modern Ethernet rarely has digest errors → ERL>0 buys little. Default to ERL=0.
- For fencing reasoning, ERL=0 is the right model — session drops, replacement_timeout
  governs recovery time.

---

## Previous / Next

[Day 27 — iSCSI login sequence](day27.md) | [Day 29 — SCSI sense data generation](day29.md)
