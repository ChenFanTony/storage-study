# Day 30 — Cold re-read day

**Week 4**: Deep Cuts — TMF, ALUA, configfs, NVMe-oF, Sense Data
**Time**: 1–2 hours
**Tool**: [elixir.bootlin.com](https://elixir.bootlin.com) — latest stable kernel

---

## Overview

Day 30 is different from every other day. No new material. No guided reading. You re-read five
specific functions cold — using only elixir.bootlin.com for cross-references, no notes. The goal
is not to memorize them but to verify that you can follow every line, every branch, and every
struct field reference without searching. Where you stall is exactly what to revisit.

---

## The five functions to re-read

### 1. `iscsit_process_scsi_cmd()` — `drivers/target/iscsi/iscsi_target.c`

**What to verify you can follow:**
- Why `target_submit_cmd()` is called for reads before any data arrives but not for writes
- Exactly when `iscsit_handle_immediate_data()` is called vs when the function returns early
- The `ICF_NON_IMMEDIATE_UNSOLICITED_DATA` flag setting and what it triggers
- How `iscsit_set_unsolicited_dataout_sequence_range()` prepares for incoming Data-Out PDUs
- Why `ICF_OOO_CMDSN` prevents `target_execute_cmd()` even when `ICF_GOT_LAST_DATAOUT` is set

**If you stall:** revisit day 18.

---

### 2. `target_submit_cmd()` — `drivers/target/target_core_transport.c`

**What to verify you can follow:**
- The order of checks: init → LUN lookup → PR check → ALUA check → execution
- Why `TCM_RESERVATION_CONFLICT` from PR check bypasses `transport_generic_new_cmd()` entirely
- How `transport_lookup_cmd_lun()` uses `percpu_ref_tryget_live()` for hot-unplug safety
- Where `se_cmd` is added to `se_sess->sess_cmd_list` and why that matters for teardown
- What `target_queue_submission()` actually does (sets work fn, calls queue_work)

**If you stall:** revisit days 16 and 17.

---

### 3. `core_scsi3_pr_seq_non_holder()` — `drivers/target/target_core_pr.c`

**What to verify you can follow:**
- The difference between WRITE_EXCLUSIVE and EXCLUSIVE_ACCESS for non-holders
- Why registered non-holders can read under WRITE_EXCLUSIVE but not under EXCLUSIVE_ACCESS
- How `core_scsi3_locate_pr_reg()` finds the registration for the current initiator
- Why `RESERVATION CONFLICT` is returned immediately without involving any workqueue
- What `dev->dev_pr_res_holder` contains and when it is NULL

**If you stall:** revisit day 20.

---

### 4. `blk_execute_rq()` — `block/blk-exec.c`

**What to verify you can follow:**
- What `DECLARE_COMPLETION_ONSTACK(wait)` creates and where it lives (stack frame)
- The exact sequence: `rq->end_io = blk_end_sync_rq` → `blk_execute_rq_nowait()` →
  `wait_for_completion_io()` — and that dispatch happens BEFORE the wait
- Why `at_head=true` causes the request to be dispatched before scheduler-queued I/O
- What `blk_end_sync_rq()` does when called from the completion softirq
- Why this path is immune to `no_path_retry=queue` (no bio interception possible)

**If you stall:** revisit day 3.

---

### 5. `multipath_map_bio()` — `drivers/md/dm-mpath.c`

**What to verify you can follow:**
- The exact condition: `!choose_pgpath()` AND `m->queue_if_no_path` → `bio_list_add()`
- What `DM_MAPIO_SUBMITTED` tells dm-core (bio held, don't touch it)
- What `DM_MAPIO_KILL` tells dm-core (fail bio with -EIO)
- The `REQ_FAILFAST_TRANSPORT` flag added when a path is found — why it's there
- How `process_queued_io_list()` drains `m->queued_ios` when a path returns

**If you stall:** revisit days 7 and 14.

---

## The self-assessment

After re-reading each function, answer these questions without looking at your notes:

### Block layer
- What flag on a blk-mq request marks it as passthrough? Where is this checked?
- What does `hctx->dispatch` contain, and in what order is it drained relative to the scheduler?
- What is the role of `blk_end_sync_rq()` and what data structure does it signal?

### iSCSI initiator
- What does `iscsi_session_chkready()` return when `session->state = ISCSI_STATE_RECOVERY_FAILED`?
- How does the ITT encode the session age, and what happens if the age bits don't match?
- What is the difference between `DID_TRANSPORT_DISRUPTED` and `DID_TRANSPORT_FAILFAST` for
  dm-multipath path management?

### iSCSI target — fabric layer
- Name the five write data-flow paths and the session parameters that control which one is taken.
- What are the two conditions that together trigger setting `ICF_GOT_LAST_DATAOUT`?
- What does `CMD_T_FABRIC_STOP` prevent that `CMD_T_ABORTED` alone does not?

### Target core
- In `target_submit_cmd()`, what happens to a command if `sess_tearing_down = 1`?
- What function does the completion workqueue worker call to send the result back to the fabric?
- Why is `target_tmr_wq` ordered (`alloc_ordered_workqueue`) while `target_submission_wq` is not?

### PR and fencing
- What is the exact SCSI status byte for `RESERVATION CONFLICT`? Is there sense data?
- After ACL removal, why does the fenced initiator still have 120 seconds of I/O before path failure?
- What kernel function is the single location where a login is rejected when ACL is missing?

---

## Answers (verify against these after self-assessment)

**Block layer:**
- `REQ_OP_DRV_IN` / `REQ_OP_DRV_OUT`, checked by `blk_rq_is_passthrough()` at multiple sites.
- `hctx->dispatch` holds requests that couldn't be sent (driver returned `BLK_STS_RESOURCE`).
  It is drained FIRST in `blk_mq_sched_dispatch_requests()`, before the I/O scheduler.
- `blk_end_sync_rq()` stores the error in `data->ret` and calls `complete(data->done)` to wake
  the thread sleeping in `wait_for_completion_io()`.

**iSCSI initiator:**
- `DID_TRANSPORT_FAILFAST << 16`.
- `build_itt()` packs `session->age` into the high 8 bits. Mismatch → task not found → error.
- `DISRUPTED` → `NEEDS_RETRY` → blk-mq requeues (retriable). `FAILFAST` → `SUCCESS` (with error)
  → `BLK_STS_TRANSPORT` → dm-multipath `blk_path_error()=true` → `fail_path()`.

**iSCSI target — fabric:**
- Path A (READ/none), B (ImmediateData only), C (immed+unsolicited), D (unsolicited only),
  E (solicited R2T). Controlled by `ImmediateData` and `InitialR2T` session parameters.
- `F-bit = 1` in the last Data-Out PDU BHS AND `write_data_done == data_length`.
- `CMD_T_FABRIC_STOP` prevents `se_tfo->queue_status()` from being called — no response PDU
  is sent. `CMD_T_ABORTED` alone only stops backend dispatch and routes to the aborted path.

**Target core:**
- `transport_lookup_cmd_lun()` returns `TCM_LOGICAL_UNIT_COMMUNICATION_FAILURE` immediately,
  before the command is added to `sess_cmd_list`.
- `cmd->se_tfo->queue_status(cmd)` — for iSCSI this is `iscsit_queue_status()`.
- `target_tmr_wq` is ordered to prevent concurrent TMF operations from racing on `sess_cmd_list`
  and command state, which would cause use-after-free when the same command is aborted twice.

**PR and fencing:**
- Status byte `0x18` (`SAM_STAT_RESERVATION_CONFLICT`). No sense data. DataSegmentLength = 0
  in the iSCSI Response PDU.
- `replacement_timeout` (default 120s) is the window during which libiscsi holds commands waiting
  for session recovery. Login rejection means reconnect fails, but the timeout must expire before
  `ISCSI_STATE_RECOVERY_FAILED` is set and `DID_TRANSPORT_FAILFAST` is returned.
- `core_tpg_check_initiator_node_acl()` in `drivers/target/target_core_configfs.c`.

---

## What to do with gaps

If you stalled on any question above, do not treat it as failure — treat it as a directed pointer.
The day number next to each stall tells you exactly what to re-read:

| Stall topic | Re-read |
|---|---|
| blk_rq_is_passthrough, hctx->dispatch | Days 2, 3 |
| DID_TRANSPORT_DISRUPTED vs FAILFAST | Days 8, 12 |
| ICF_GOT_LAST_DATAOUT, five write paths | Days 18, 19 |
| CMD_T_FABRIC_STOP, sess_tearing_down | Days 17, 25 |
| core_scsi3_pr_seq_non_holder | Day 20 |
| replacement_timeout timeline | Days 8, 12 |
| core_tpg_check_initiator_node_acl | Days 24, 27 |

---

## You are done

If you reached day 30 and the cold re-read was mostly smooth, you have:

- The complete initiator stack: VFS → bio → blk-mq → SCSI mid → libiscsi → TCP wire
- The complete target stack: TCP → RX thread → target_core → backend → TX thread → TCP
- Every workqueue and what it serializes and why
- The exact chain from `targetcli acls delete` to `dm-multipath fail_path()`
- The exact code path that makes PR immune to `no_path_retry=queue`
- The complete sense data construction and parsing loop between target and initiator

Open `drivers/target/target_core_transport.c` in elixir. You should be able to read any
function in it and place it immediately in the architecture without searching. That is the goal.

---

## Previous

[Day 29 — SCSI sense data generation](day29.md)
