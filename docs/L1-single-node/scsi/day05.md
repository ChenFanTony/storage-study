# Day 5 — SCSI completion and disposition

**Week 1**: Block Layer — blk-mq and SCSI Mid Layer  
**Time**: 1–2 hours  
**Reference**: `drivers/scsi/scsi_lib.c`, `drivers/scsi/scsi_error.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

When a SCSI command completes, the LLD calls the global `scsi_done()` helper. From there,
`scsi_io_completion()` reads `cmd->result` and sense data, then calls `scsi_decide_disposition()`
to determine what to do: succeed, retry, or escalate to EH. This is the routing brain of the SCSI
mid layer and the exact point where `RESERVATION CONFLICT` and `NOT READY` diverge into
completely different paths.

---

## scsi_done — `drivers/scsi/scsi_lib.c`

```c
/* called by LLD when a command completes */
void scsi_done(struct scsi_cmnd *cmd)
{
    /*
     * For passthrough requests (PR, INQUIRY, TUR):
     * blk_rq_is_passthrough() returns true.
     * Skip ALL retry and EH logic. Complete directly to blk-mq.
     * This is why PR conflict returns immediately to the caller.
     */
    if (blk_rq_is_passthrough(scsi_cmd_to_rq(cmd))) {
        scsi_complete(cmd);
        return;
    }

    /*
     * For normal I/O (READ/WRITE):
     * raise a BLOCK softirq — deferring full completion processing
     * out of the interrupt/softirq context that called scsi_done.
     */
    blk_mq_complete_request(scsi_cmd_to_rq(cmd));
}

/* softirq handler for normal I/O completion */
static void scsi_softirq_done(struct request *rq)
{
    struct scsi_cmnd *cmd = blk_mq_rq_to_pdu(rq);
    int disposition;

    disposition = scsi_decide_disposition(cmd);

    switch (disposition) {
    case SUCCESS:
        scsi_finish_command(cmd);   /* complete to blk-mq */
        break;
    case NEEDS_RETRY:
        scsi_queue_insert(cmd, SCSI_MLQUEUE_EH_RETRY);
        break;
    case ADD_TO_MLQUEUE:
        scsi_queue_insert(cmd, SCSI_MLQUEUE_DEVICE_BUSY);
        break;
    default:
        scsi_eh_scmd_add(cmd);      /* hand to EH kthread */
        break;
    }
}
```

The passthrough short-circuit in `scsi_done()` is crucial: PR commands call `scsi_complete(cmd)`
directly, which calls `blk_mq_complete_request()` → `blk_end_sync_rq()` → `complete()` →
wakes `blk_execute_rq()`. No disposition check, no retry, no EH possible.

---

## scsi_decide_disposition — `drivers/scsi/scsi_lib.c`

```c
/* Simplified — see scsi_lib.c for the full routing logic. The actual
 * upstream function:
 *   1. short-circuits for passthrough (already handled in scsi_done)
 *   2. checks deferred-error sense
 *   3. switches on host_byte
 *   4. switches on status_byte
 *   5. handles sense for CHECK CONDITION via scsi_check_sense()
 */
static enum scsi_disposition scsi_decide_disposition(struct scsi_cmnd *scmd)
{
    int status = scmd->result;

    /*
     * Step 1: check the host_byte — transport-level result.
     * If host reported an error, SCSI status is irrelevant.
     */
    if (host_byte(status) != DID_OK) {
        switch (host_byte(status)) {

        case DID_TRANSPORT_FAILFAST:
            /*
             * Transport says: don't retry on any path.
             * dm-multipath maps this to a permanent path failure.
             * Set after replacement_timeout expires (day 12).
             *
             * Always returns SUCCESS so the result propagates upward
             * with the host_byte preserved — the whole point of
             * FAILFAST is "do not retry".
             */
            return SUCCESS;

        case DID_TRANSPORT_DISRUPTED:
            /*
             * Transport disruption that may be recoverable.
             * If retries remain, NEEDS_RETRY; otherwise return SUCCESS
             * with the error so it propagates up.
             */
            if (scmd->retries < scmd->allowed)
                return NEEDS_RETRY;
            return SUCCESS;

        case DID_NO_CONNECT:
            return FAILED;  /* → EH */

        case DID_SOFT_ERROR:
            goto maybe_retry;

        case DID_RESET:
            return SUCCESS; /* reset completed the command */

        case DID_ABORT:
            return SUCCESS; /* abort completed the command */

        default:
            return FAILED;  /* → EH */
        }
    }

    /*
     * Step 2: host_byte is DID_OK — check SCSI status from target.
     */
    switch (status_byte(status)) {

    case SAM_STAT_GOOD:
        return SUCCESS;

    case SAM_STAT_CHECK_CONDITION:
        /*
         * Target returned sense data.
         * Parse sense key / ASC / ASCQ to decide disposition.
         */
        return scsi_check_sense(scmd);

    case SAM_STAT_RESERVATION_CONFLICT:
        /*
         * *** KEY CASE FOR FENCING ***
         *
         * RESERVATION CONFLICT (0x18) means the initiator tried to
         * access a LUN it does not hold a reservation for.
         *
         * scsi_noretry_cmd() also returns true for this status, which
         * keeps the result on the SUCCESS path (no retry). It propagates
         * to blk-mq with the status byte preserved.
         *
         * For passthrough (PR commands): scsi_execute_cmd() returns -EIO
         *   to the caller — handled before we get here, via the early
         *   short-circuit in scsi_done().
         * For normal I/O: scsi_result_to_blk_status() maps the status to
         *   BLK_STS_RESV_CONFLICT (modern kernels) — blk_path_error()
         *   returns false for it, so dm-multipath does NOT fail the path.
         */
        return SUCCESS;

    case SAM_STAT_CONDITION_MET:
        return SUCCESS;

    case SAM_STAT_TASK_SET_FULL:
        /*
         * Target's command queue is full.
         * Requeue at blk-mq level — not an error, just back-pressure.
         */
        return ADD_TO_MLQUEUE;

    case SAM_STAT_BUSY:
        /*
         * Target is temporarily busy (LUN not yet ready, transitioning).
         * Retry after delay.
         */
        goto maybe_retry;

    case SAM_STAT_TASK_ABORTED:
        return FAILED;  /* → EH */

    default:
        return FAILED;
    }

maybe_retry:
    if (scmd->retries < scmd->allowed) {
        scmd->retries++;
        return NEEDS_RETRY;
    }
    /* retries exhausted */
    return SUCCESS;  /* complete with the error status */
}
```

---

## scsi_check_sense — parsing CHECK CONDITION — `drivers/scsi/scsi_error.c`

```c
/* Simplified. Real function lives in scsi_error.c and handles many more
 * sense keys / quirks; the structure below highlights the common cases. */
static enum scsi_disposition scsi_check_sense(struct scsi_cmnd *scmd)
{
    struct scsi_device *sdev = scmd->device;
    struct scsi_sense_hdr sshdr;

    /* parse the 18-byte sense buffer into a structured form */
    if (!scsi_command_normalize_sense(scmd, &sshdr))
        return FAILED;  /* unparseable sense → EH */

    if (scsi_sense_is_deferred(&sshdr))
        return NEEDS_RETRY;

    switch (sshdr.sense_key) {

    case NO_SENSE:
        return SUCCESS;

    case RECOVERED_ERROR:
        return SUCCESS;

    case NOT_READY:
        /*
         * ASC 0x04 = "LOGICAL UNIT NOT READY"
         * ASCQ distinguishes the reason. Common values:
         */
        if (sshdr.asc == 0x04) {
            switch (sshdr.ascq) {
            case 0x01:
                /*
                 * NOT READY / LU IN PROCESS OF BECOMING READY.
                 * Transient state — retry.
                 */
                return NEEDS_RETRY;
            case 0x02:
                /*
                 * NOT READY / INITIALIZING COMMAND REQUIRED.
                 * The LUN expects a START STOP UNIT (or similar) to
                 * bring it online. Conventionally retried (so the SCSI
                 * mid-layer eventually issues the init via EH).
                 */
                return NEEDS_RETRY;
            case 0x0a:
                /* ASYMMETRIC ACCESS STATE TRANSITION — ALUA */
                return NEEDS_RETRY;
            case 0x0b:
                /* TARGET PORT IN STANDBY STATE — ALUA */
                return NEEDS_RETRY;
            case 0x12:
                /* OFFLINE — admin took the LUN offline */
                return SUCCESS;        /* permanent error, propagate */
            default:
                return NEEDS_RETRY;
            }
        }
        return NEEDS_RETRY;

    case UNIT_ATTENTION:
        /*
         * Power on, reset, mode page changed, ALUA state changed, etc.
         * Always retry — the UA is consumed on retry (target clears it).
         */
        return NEEDS_RETRY;

    case ILLEGAL_REQUEST:
        return SUCCESS;  /* permanent error, no retry */

    case ABORTED_COMMAND:
        return NEEDS_RETRY;

    case MEDIUM_ERROR:
    case VOLUME_OVERFLOW:
        return SUCCESS;  /* permanent medium error */

    case DATA_PROTECT:
        return SUCCESS;  /* permanent write protect */

    case HARDWARE_ERROR:
        return FAILED;   /* → EH */
    }

    return FAILED;  /* default: EH */
}
```

`NOT_READY ASCQ=0x02` ("INITIALIZING COMMAND REQUIRED") is conventionally retriable in upstream
SCSI — the LUN is requesting that an initialization command (typically START STOP UNIT) be
issued. The "admin offline" case is closer to ASCQ=0x12 ("OFFLINE"), which is a permanent error.

---

## scsi_queue_insert and scsi_requeue_command

When `NEEDS_RETRY` is returned, the command goes back into blk-mq:

```c
void scsi_queue_insert(struct scsi_cmnd *cmd, int reason)
{
    struct scsi_device *device = cmd->device;
    struct request_queue *q = device->request_queue;
    struct request *req = scsi_cmd_to_rq(cmd);

    /*
     * For SCSI_MLQUEUE_DEVICE_BUSY (TASK_SET_FULL, BUSY status):
     * delay dispatch by SCSI_QUEUE_DELAY (3ms) to avoid hammering
     * a temporarily saturated device.
     */
    if (reason == SCSI_MLQUEUE_DEVICE_BUSY)
        blk_mq_delay_run_hw_queues(q, SCSI_QUEUE_DELAY);

    blk_mq_requeue_request(req, true);  /* put back in hw queue */
}
```

`blk_mq_requeue_request()` puts the request back into the hw queue's list. dm-multipath may then
select a different path on the next dispatch. If all paths return `NEEDS_RETRY` (e.g. NOT READY
on every path) and they all fail via EH eventually with `DID_TRANSPORT_*`, dm-multipath's
`fail_path()` runs and — under `no_path_retry=queue` — bios accumulate in `m->queued_bios`.

---

## NOT READY → queue hang vs RESERVATION CONFLICT → immediate error

```
RESERVATION CONFLICT (PR path)         NOT READY (LUN offline / becoming ready)
───────────────────────────────         ────────────────────────────────────────
Target returns status 0x18              Target returns CHECK CONDITION + sense
    │                                       │  NOT READY / ASC 04 / ASCQ 01
    ▼                                       ▼
scsi_done()                             scsi_done()
    │  blk_rq_is_passthrough=true           │  blk_rq_is_passthrough=false
    │  → scsi_complete() directly           │  → blk_mq_complete_request() → softirq
    ▼                                       ▼
blk_end_sync_rq()                       scsi_softirq_done()
    │  complete() wakes caller              │
    ▼                                       ▼
scsi_execute_cmd() returns -EIO         scsi_decide_disposition()
    │  or RESERVATION CONFLICT                  │  NOT READY / becoming ready
    ▼  status code                             │  → NEEDS_RETRY
sd_pr_reserve() reports conflict            ▼
    │                                   scsi_queue_insert()
    ▼                                       │  request back in blk-mq
caller gets -EIO immediately                ▼
                                        dm-multipath tries next path
                                            │  same result on all paths
                                            ▼
                                        EH eventually fails → DID_TRANSPORT_FAILFAST
                                            │
                                        fail_path() per path
                                            │
                                            ▼  nr_valid_paths == 0
                                            ▼  (no_path_retry=queue)
                                        multipath_map_bio(): bio_list_add(queued_bios)
                                            │
                                            ▼
                                        application hangs forever
```

---

## scsi_result_to_blk_status — what dm-multipath sees

```c
/* Simplified — actual function lives in scsi_lib.c and is named
 * __scsi_error_from_host_byte() / scsi_result_to_blk_status() depending
 * on kernel version. */
static blk_status_t scsi_result_to_blk_status(struct scsi_cmnd *cmd, int result)
{
    /* Reservation conflict has its own dedicated blk_status_t. */
    if (status_byte(result) == SAM_STAT_RESERVATION_CONFLICT)
        return BLK_STS_RESV_CONFLICT;

    switch (host_byte(result)) {
    case DID_OK:
        if (scsi_status_is_good(result))
            return BLK_STS_OK;
        return BLK_STS_IOERR;

    case DID_TRANSPORT_FAILFAST:
        return BLK_STS_TRANSPORT;     /* → dm-mpath permanent path failure */

    case DID_TRANSPORT_DISRUPTED:
        return BLK_STS_IOERR;

    case DID_TRANSPORT_MARGINAL:
        return BLK_STS_AGAIN;

    case DID_NO_CONNECT:
        return BLK_STS_IOERR;

    default:
        return BLK_STS_IOERR;
    }
}
```

`BLK_STS_TRANSPORT` from `DID_TRANSPORT_FAILFAST` causes dm-multipath's `multipath_end_io()` to
call `fail_path()` immediately. This is the behavior after `replacement_timeout` expires — the
session is declared dead, paths are failed permanently.

`BLK_STS_RESV_CONFLICT` (added in the v6.0 timeframe) is the dedicated mapping for reservation
conflict. `blk_path_error()` returns false for `BLK_STS_RESV_CONFLICT`, so dm-multipath does NOT
fail the path — a stray reservation conflict from one initiator does not cause every other
initiator's paths to be torn down.

---

## Key takeaways

- `scsi_done()` short-circuits for passthrough (`blk_rq_is_passthrough=true`): calls
  `scsi_complete()` directly, skipping disposition and EH entirely.
- `scsi_decide_disposition()` routes based on `host_byte` and `status_byte`:
  - `RESERVATION CONFLICT (0x18)` → `SUCCESS` → immediate completion, no retry
  - `NOT READY / becoming ready` → `NEEDS_RETRY` → `scsi_queue_insert()` → back to blk-mq
  - `NOT READY / OFFLINE (ASCQ=0x12)` → `SUCCESS` → propagate, no retry
  - `DID_TRANSPORT_FAILFAST` → always `SUCCESS` (no retry on FAILFAST) → `BLK_STS_TRANSPORT`
- `scsi_queue_insert()` puts retry-able commands back into blk-mq — this is what feeds the
  dm-multipath retry loop and ultimately the `no_path_retry=queue` hang when EH eventually
  exhausts.
- `scsi_result_to_blk_status()` converts SCSI result codes to blk_status_t. Modern kernels map
  reservation conflict to `BLK_STS_RESV_CONFLICT` (not `BLK_STS_IOERR`), and `blk_path_error()`
  returns false for it — dm-multipath does not fail paths on reservation conflict.
- `DID_TRANSPORT_FAILFAST` is the key status for clean path failure notification to dm-multipath.

---

## Previous / Next

[Day 4 — SCSI mid layer queueing](day04.md) | [Day 6 — SCSI error handler](day06.md)
