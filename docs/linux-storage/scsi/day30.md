# Day 30 — Cold re-read self test

**Week 4**: Advanced Topics  
**Time**: 1–2 hours  
**Reference**: All previous days
**Targets**: Linux mainline, mid-2025.

---

## Overview

The cold re-read is the final exercise. Every previous day built one chunk of the picture; this
day verifies it cohered. Read each question, answer from memory, then check against the
references. If you can answer 25+ confidently and trace the rest with one or two glances at the
linked days, the foundation is solid.

The questions are organized around the original fencing problem: what makes
`no_path_retry=queue` hang? Why does PR fencing succeed where session-drop alone might be
ambiguous? What are the exact code paths involved at each layer?

---

## Block layer (days 1–3)

### Q1 — what is `blk_rq_is_passthrough()` checking?

It checks whether `rq->cmd_flags & REQ_OP_MASK` is `REQ_OP_DRV_IN` or `REQ_OP_DRV_OUT`. These
ops mark the request as a passthrough SCSI command (PR, INQUIRY, TUR, etc.). Every layer of the
stack uses this check to give passthrough requests special handling: skip I/O scheduler, skip
multipath bio interception, skip retry logic, complete to `blk_execute_rq()` directly.

### Q2 — what does `blk_execute_rq(rq, at_head=true)` do, in order?

1. Sets `rq->end_io = blk_end_sync_rq` and `end_io_data = &wait`.
2. Calls `blk_execute_rq_nowait()`:
   - `blk_mq_insert_request(rq, BLK_MQ_INSERT_AT_HEAD)` — puts request at head of
     `hctx->dispatch`.
   - `blk_mq_run_hw_queue(rq->mq_hctx, false)` — dispatches inline (calls `queue_rq()`).
3. `wait_for_completion_io(&wait)` — sleeps using `TASK_UNINTERRUPTIBLE` and bumping
   `current->in_iowait` until the completion fires (which happens when `blk_end_sync_rq()` runs
   from the LLD's response).

### Q3 — why is head-of-queue insertion the right choice for PR commands?

Two reasons:
1. PR is the slow path that the caller is blocked on. Latency for PR matters; head-injection
   minimizes wait.
2. `hctx->dispatch` is drained FIRST in `blk_mq_sched_dispatch_requests()` before the I/O
   scheduler is consulted. Head-injected passthrough commands therefore always get sent before
   any normal I/O — important when normal I/O is queued behind back-pressure.

---

## SCSI mid layer (days 4–6)

### Q4 — what fields of `struct request` carry the SCSI CDB and result in current kernels?

Neither — modern kernels (since v5.18, commit `be6bfe36db17`) removed the `scsi_request`
wrapper. The CDB and SCSI result live on `struct scsi_cmnd`, which is embedded in the request's
PDU area accessed via `blk_mq_rq_to_pdu(rq)`. The `cmnd[]` array holds the CDB; the `result`
field packs `host_byte | status_byte`.

### Q5 — what does `scsi_decide_disposition()` return for `DID_TRANSPORT_FAILFAST`?

Always `SUCCESS`. The whole point of FAILFAST is "do not retry" — propagate the result upward
with the host_byte preserved so dm-multipath sees `BLK_STS_TRANSPORT` and calls `fail_path()`
on the path. There is no NEEDS_RETRY case for FAILFAST.

### Q6 — what makes `RESERVATION CONFLICT` skip EH?

`scsi_done()` checks `blk_rq_is_passthrough()` first — for passthrough, calls
`scsi_complete()` directly, bypassing the disposition machinery entirely. For normal I/O,
`scsi_decide_disposition()` returns `SUCCESS` for `SAM_STAT_RESERVATION_CONFLICT` (no retry),
and `scsi_noretry_cmd()` lists it explicitly. Either way: no EH.

### Q7 — when does the SCSI mid layer set `SDEV_TRANSPORT_OFFLINE`?

`iscsi_conn_failure()` calls `iscsi_suspend_tx()` which calls `scsi_target_block()`. That
function transitions devices through `SDEV_BLOCK`/`SDEV_TRANSPORT_OFFLINE` (depending on the
transport-class behavior). After this, `scsi_prep_state_check()` returns `BLK_STS_TRANSPORT`
for non-passthrough I/O — held by blk-mq for retry.

---

## dm-multipath (day 7, 14)

### Q8 — what is the exact line that implements `no_path_retry=queue` hang?

`bio_list_add(&m->queued_bios, bio)` in `multipath_map_bio()` (drivers/md/dm-mpath.c), executed
when:
1. `choose_pgpath()` returns NULL (`atomic_read(&m->nr_valid_paths) == 0`).
2. `m->queue_if_no_path == 1`.

The function returns `DM_MAPIO_SUBMITTED` — the bio is "handled" from dm's perspective but will
not complete until a path comes back and `process_queued_bios` drains the list.

### Q9 — what does `blk_path_error()` return for `BLK_STS_RESV_CONFLICT`?

`false` — added to the false-list in modern kernels (around v6.0). This means a reservation
conflict on normal I/O does NOT cause `fail_path()` and does NOT propagate as a path failure.
A stray PR conflict from one initiator therefore does not tear down dm-multipath paths for
others.

### Q10 — what userspace command stops a `queue_if_no_path` hang?

```
dmsetup message dm-0 0 fail_if_no_path
```

This sets `m->queue_if_no_path = 0` and triggers `process_queued_bios` to drain `m->queued_bios`.
With no path available and `queue_if_no_path` cleared, queued bios fail with `-EIO` —
applications see immediate errors instead of hanging.

---

## libiscsi initiator (days 8–12)

### Q11 — where does the per-command iSCSI state live in modern kernels?

In the SCSI command's private area, accessed via `iscsi_cmd(sc)` / `scsi_cmd_priv(sc)`. This is
the trailing region of the blk-mq request PDU, sized via `Scsi_Host_Template.cmd_size`. The
legacy `sc->SCp` field that older drivers used was removed in v6.2.

### Q12 — what is `replacement_timeout`'s real source?

A userspace setting in open-iscsi: `node.session.timeo.replacement_timeout` (default 120s).
At session creation, iscsid pushes this to the kernel via sysfs into `iscsi_session::recovery_tmo`.
There is no kernel constant named `ISCSI_DEF_REPLACEMENT_TMOUT`. The kernel just enforces
whatever value userspace supplied.

### Q13 — what is the iSCSI TX side: kthread or workqueue?

A workqueue handler (`iscsi_xmitworker`, a `work_struct` queued on the iscsi workqueue).
There is no dedicated kthread per connection. The `xmitwork` field of `iscsi_conn` is the
work_struct; `iscsi_conn_queue_work()` schedules it.

### Q14 — what's in the ITT's high bits?

The session age (`ISCSI_AGE_MASK = 0xf` in current code → 4 bits). `build_itt()` computes
`(session->age << ISCSI_AGE_SHIFT) | (task_index & ISCSI_ITT_MASK)`. The low bits are the
per-task index. After a reconnect, age is incremented, so old responses arrive with stale ITTs
and `iscsi_itt_to_ctask()` rejects them.

### Q15 — what is the chain from session drop to dm-multipath path failure?

1. Connection error → `iscsi_conn_failure()` sets `ISCSI_STATE_FAILED`.
2. Transport class wakes EH, blocks SCSI devices via `scsi_target_block()`.
3. `delayed_work recovery_work` is armed with delay = `recovery_tmo` (120s default).
4. iscsid (userspace) tries to reconnect; each attempt fails (e.g., ACL removed → Login rejected).
5. `recovery_tmo` expires → `iscsi_session_recovery_timedout()` →
   `ISCSI_STATE_RECOVERY_FAILED`.
6. Held commands fail with `DID_TRANSPORT_FAILFAST` → `BLK_STS_TRANSPORT`.
7. `multipath_end_io_bio()` sees the error, calls `fail_path()` for this path.
8. `atomic_dec(&m->nr_valid_paths)`. If this hits 0 with `queue_if_no_path=1`: future bios
   queue in `m->queued_bios`.

---

## PR slow path (days 13–14)

### Q16 — for `/dev/mapper/mpathN`, what is the call chain when `multipathd` issues PR REGISTER?

1. userspace ioctl `IOC_PR_REGISTER` on `/dev/mapper/mpathN`.
2. `blkdev_pr_ioctl()` → `bdev->bd_disk->fops->pr_ops->pr_register` = `dm_pr_register`.
3. `dm_call_pr()` → `iterate_devices(__dm_pr_register)`.
4. For each path: `__dm_pr_register()` → `dev->bdev->bd_disk->fops->pr_ops->pr_register` =
   `sd_pr_register`.
5. `sd_pr_register()` builds CDB (`opcode 0x5F`, sa=0x00 or 0x06), calls
   `scsi_execute_cmd(REQ_OP_DRV_OUT)`.
6. `scsi_execute_cmd()` → `blk_execute_rq(at_head=true)` → `iscsi_queuecommand()` → TX → wire.
7. Response: target's `core_scsi3_emulate_pro_register()` → status GOOD → response PDU.
8. Initiator's `iscsi_scsi_cmd_rsp()` → `scsi_complete()` → wakes `blk_execute_rq()`.
9. Repeat for next path.

### Q17 — why are PR commands not subject to `no_path_retry=queue`?

Because they take a structurally separate code path on the initiator. PR commands flow through
`pr_ops` (either `sd_pr_ops` for `/dev/sdX` or `dm_pr_ops` for `/dev/mapper/mpathN`) →
`scsi_execute_cmd()` → `blk_execute_rq()`. They never call `submit_bio()` and never enter
`multipath_map_bio()`, so they cannot land in `m->queued_bios`. As long as at least one TCP
session is alive, the PR command reaches the target.

### Q18 — what are the correct `enum pr_type` values?

From `include/uapi/linux/pr.h`:
```
PR_WRITE_EXCLUSIVE              = 1
PR_EXCLUSIVE_ACCESS             = 2
PR_WRITE_EXCLUSIVE_REG_ONLY     = 3
PR_EXCLUSIVE_ACCESS_REG_ONLY    = 4
PR_WRITE_EXCLUSIVE_ALL_REGS     = 5
PR_EXCLUSIVE_ACCESS_ALL_REGS    = 6
```

These are **not** the same as the SCSI on-the-wire type byte (0x01, 0x03, 0x05, 0x06, 0x07,
0x08). `sd_pr_type()` (initiator) and the target dispatcher do the translation.

---

## LIO target core (days 15–17)

### Q19 — what does `transport_lookup_cmd_lun()` do?

1. Walks the initiator's `se_node_acl->lun_entry_hlist` to find the requested LUN.
2. If not found → `TCM_NON_EXISTENT_LUN` (sense ILLEGAL REQUEST 25/00).
3. If found: `percpu_ref_tryget_live(&deve->se_lun->lun_ref)` — if false (LUN being torn down
   via `percpu_ref_kill()`), return failure.
4. Read-only check.
5. Set `cmd->se_lun` and `cmd->se_dev`. Return `TCM_NO_SENSE`.

### Q20 — why is `target_tmr_wq` ordered (`__WQ_ORDERED`)?

To prevent races between concurrent TMFs: two ABORT TASKs walking `sess_cmd_list` could
mis-account krefs; LUN_RESET interleaving with ABORT TASK could deadlock on per-cmd
`t_transport_stop_comp` waits; PREEMPT_AND_ABORT (which generates internal LUN_RESET_PRO) must
serialize with fabric-driven TMFs. Ordered execution removes these classes of bug. TMFs are
rare enough that single-threaded processing is acceptable.

### Q21 — what is `CMD_T_FABRIC_STOP` for?

It's a flag set during fabric session teardown to tell backend completion paths "the fabric is
gone, don't bother sending response PDUs for these commands". Distinguishes fabric shutdown
from per-command abort (`CMD_T_ABORTED`). Set by
`iscsit_release_commands_from_conn()` during `iscsit_close_session()`.

### Q22 — where is `core_tpg_check_initiator_node_acl()` defined?

`drivers/target/target_core_tpg.c`. It searches the TPG's ACL list for the InitiatorName.
Returns existing ACL if found; if `generate_node_acls=1` and none exists, auto-creates one;
otherwise returns NULL (login rejected). For fencing, `generate_node_acls=0` (static mode) is
required so removed initiators stay rejected.

---

## iSCSI fabric (days 18–19)

### Q23 — what are the five write paths in `iscsit_process_scsi_cmd()`?

This is the doc-internal taxonomy; RFC 7143 describes the same combinations but doesn't letter
them.

| Path | ImmediateData | InitialR2T | Description |
|---|---|---|---|
| A | n/a | n/a | Read or no-data: submit immediately. |
| B | Yes | n/a | All data piggybacked in Command PDU. |
| C | Yes | No | Piggybacked + unsolicited Data-Out (up to first_burst). |
| D | No | No | All unsolicited Data-Out + R2T for tail. |
| E | n/a | Yes | All R2T-driven Data-Out. |

### Q24 — what triggers `target_execute_cmd()` for a write?

`iscsit_handle_data_out()` receives Data-Out PDU. When `F=1` (Final bit) is set on this PDU AND
`cmd->write_data_done == cmd->data_length`, it calls `target_execute_cmd()`. The F-bit alone
without the byte count match means "this is the last in this burst — send R2T for the rest".
The byte count match without F=1 means "we have all the data but the initiator hasn't finalized
yet — wait" (initiator bug if it doesn't finalize).

### Q25 — what's the difference between Response and Status in a SCSI Response PDU?

- `response` (byte 2): iSCSI service response. 0x00 = "Command Completed at Target" (normal).
  0x01 = "Target Failure" (rare).
- `status` (byte 3): SCSI status byte. 0x00 GOOD, 0x02 CHECK CONDITION, 0x18 RESERVATION
  CONFLICT, 0x28 TASK SET FULL, etc.

For RESERVATION CONFLICT: response=0x00, status=0x18. The iSCSI level says "we ran the command";
the SCSI level says "but the target rejected it because of reservation".

---

## LIO PR + ALUA (days 20, 23)

### Q26 — what does `core_scsi3_emulate_pro_preempt()` do?

1. Validate caller is registered with the supplied `res_key`.
2. Walk `t10_reservation.registration_list`.
3. Remove every registration whose key matches `sa_res_key` (or all of them for
   `*_ALL_REGS` types with sa_res_key=0).
4. Queue UNIT ATTENTION (06h/2Ah/03h "RESERVATIONS PREEMPTED") on each preempted nexus.
5. If `PREEMPT_AND_ABORT` (0x05): also abort all in-flight commands from preempted nexuses.
6. If we preempted the holder: WE become the new holder (set type/scope from this command).
7. Increment `pr_generation`.
8. If APTPL active: persist to `/var/target/pr/aptpl_<dev>`.

### Q27 — what ALUA states reject I/O with NOT READY?

STANDBY (0x2), UNAVAILABLE (0x3), TRANSITION (0xF), OFFLINE (0xE). Each maps to sense
NOT_READY (0x02) with ASC=0x04 and ASCQ:
- STANDBY → 0x0B
- UNAVAILABLE → 0x0C
- TRANSITION → 0x0A
- OFFLINE → 0x12

LBA_DEPENDENT (0x4) is per-LBA — accept some, reject others. ACTIVE_OPTIMIZED (0x0) and
ACTIVE_NON_OPTIMIZED (0x1) accept I/O; the latter optionally with `nonop_delay_msecs` slowdown.

### Q28 — what commands always pass through, regardless of PR or ALUA state?

Per SPC-4 §5.8.6 / §5.11.2.7 always-allowed CDBs (the lists overlap heavily):
- INQUIRY (0x12)
- REPORT LUNS (0xA0)
- REQUEST SENSE (0x03)
- TEST UNIT READY (0x00) — varies by config
- PERSISTENT RESERVE IN (0x5E)
- PERSISTENT RESERVE OUT (0x5F)
- RELEASE (6/10) (0x17/0x57)
- READ CAPACITY (0x25/0x9E)
- REPORT TARGET PORT GROUPS (0xA3 sa=0x0A)
- SET TARGET PORT GROUPS (0xA4 sa=0x0A)

Without these, fenced initiators couldn't discover the topology, query state, or release stale
reservations. Fencing semantics rely on them.

---

## Session teardown (day 25, 27)

### Q29 — what's the call chain when an admin runs `rmdir
/sys/.../acls/iqn.client`?

1. configfs `rmdir` callback → `iscsi_target_drop_nodeacl()` (iSCSI fabric).
2. `core_tpg_del_initiator_node_acl()` (target_core_tpg.c).
3. Iterate active sessions for this ACL.
4. For each session: `iscsit_close_session()` → `iscsit_cause_connection_reinstatement()` →
   socket forced error + `kthread_stop()` on RX/TX threads.
5. `iscsit_release_commands_from_conn()` sets `CMD_T_FABRIC_STOP` per command.
6. `target_wait_for_sess_cmds()` waits for all kref drops (20s warning loop).
7. `transport_free_session()` and the ACL itself is freed.
8. Future logins from this IQN: `core_tpg_check_initiator_node_acl()` returns NULL → Login
   Response with `status_class=0x02`.

### Q30 — what's the longest "fenced" hang an application could see?

Bounded by `replacement_timeout` (default 120s from open-iscsi userspace, pushed to kernel) +
the dm-multipath `no_path_retry` count (if `queue_if_no_path` was cleared after retries) +
SCSI command timeout (default 30s).

For `no_path_retry=queue`: indefinite. The application hangs forever in `m->queued_bios` until
an admin runs `dmsetup message ... fail_if_no_path` or a path comes back.

For `no_path_retry=N` (e.g., 10): up to ~ N × per-path-retry-interval seconds before bios fail
with -EIO.

For `no_path_retry=fail`: the application fails immediately (within seconds of full path
loss).

---

## Self-evaluation rubric

- **30/30**: every question answered confidently with file/function references. The mental
  model is solid.
- **25–29**: foundation good. Re-read the days corresponding to weak answers.
- **20–24**: most pieces clear, some gaps. Useful to redo days 5, 7, 13, 14, 22 — these are the
  pivot points where layers connect.
- **<20**: re-read the cross-cutting summary in `CORRECTIONS.md` and revisit the diagrams
  in days 7, 12, 14, 16. The day-by-day study is best done with one or two specific failure
  scenarios in mind.

A useful exercise is to re-read day 7 (dm-multipath core) and day 16 (LIO submit path) and
trace a concrete WRITE through both layers end-to-end without referring back. If you can do
that, you understand the "happy path" — and from there the failure paths follow.

---

## What to study next

The cluster of topics adjacent to this study plan:

- **Filesystem-level interaction**: how XFS / ext4 / btrfs writes land as blk-mq submissions.
  Filesystem barriers, journaling, fsync semantics.
- **dm-thin / dm-cache**: other dm layers that interact with multipath. Their PR support is
  limited — worth knowing the gap.
- **NVMe-oF host side**: nvme-cli, controller management, ANA on the initiator. (Day 26 covered
  the target side.)
- **Real cluster managers**: pacemaker, corosync, sbd, watchdog. How they trigger fencing and
  what they expect from the storage layer.
- **Tracing**: `bpftrace` scripts to watch `target_complete_cmd`, `iscsi_queuecommand`,
  `multipath_map_bio` in production. Worth far more than reading code.

---

## Final notes

This study plan is structured as a single pass through the kernel storage stack focused on the
fencing problem. The primary insight is that **fencing relies on layer separation**: the fast
data path (`submit_bio` → `multipath_map_bio` → `iscsi_queuecommand`) and the slow control
path (`pr_ops` → `scsi_execute_cmd` → `blk_execute_rq`) share infrastructure but can fail
independently. PR fencing succeeds because the slow path stays alive even when the fast path is
hung in `m->queued_bios`.

Production hardening from here: pin to a specific kernel version, audit the `tpg_attrib` settings
(static ACLs, conservative timeouts), verify `multipathd` PR plugin configuration, and write
end-to-end fencing tests that include both clean (Async PDU) and abrupt (TCP RST) failure
modes.

---

## Previous

[Day 29 — SCSI sense data generation](day29.md)
