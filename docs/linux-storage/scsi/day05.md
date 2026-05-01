# Day 5 — SCSI completion and disposition

**Week 1**: Block Layer — blk-mq and SCSI Mid Layer  
**Time**: 1–2 hours  
**Reference**: `drivers/scsi/scsi_lib.c`

---

## Overview

When a SCSI command completes, the LLD calls `scsi_done()`. From there, `scsi_io_completion()`
reads `cmd->result` and sense data, then calls `scsi_decide_disposition()` to determine what to
do: succeed, retry, or escalate to EH. This is the routing brain of the SCSI mid layer and the
exact point where `RESERVATION CONFLICT` and `NOT READY` diverge into completely different paths.

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
    blk_complete_request(scsi_cmd_to_rq(cmd));
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
static enum scsi_disposition scsi_decide_disposition(struct scsi_cmnd *scmd)
{
    int status = scmd->result;

    /*
     * First check the host_byte — transport-level result.
     * If host reported an error, SCSI status is irrelevant.
     */
    if (host_byte(status) != DID_OK) {
        switch (host_byte(status)) {

        case DID_TRANSPORT_FAILFAST:
            /*
             * Transport says: don't retry on any path.
             * dm-multipath maps this to a permanent path failure.
             * Set by libiscsi after replacement_timeout expires.
             */
            if (scmd->retries < scmd->allowed &&
                !(scmd->cmd_flags & REQ_FAILFAST_MASK))
                return NEEDS_RETRY;
            return SUCCESS; /* complete with the error, don't EH */

        case DID_NO_CONNECT:
        case DID_TRANSPORT_DISRUPTED:
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
     * host_byte is DID_OK — check SCSI status from target.
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
         * *** KEY CASE FOR OUR FENCING DISCUSSION ***
         *
         * RESERVATION CONFLICT (0x18) means the initiator tried to
         * access a LUN it does not hold a reservation for.
         *
         * Return SUCCESS — this tells scsi_softirq_done() to call
         * scsi_finish_command(), which completes the request to blk-mq
         * with the conflict status in scmd->result.
         *
         * No retry. No EH escalation. No LUN reset.
         * The error propagates immediately to the caller.
         *
         * For normal I/O: the filesystem / dm-multipath sees BLK_STS_IOERR.
         * For passthrough (PR commands): scsi_execute_cmd() gets -EIO.
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

## scsi_check_sense — parsing CHECK CONDITION — `drivers/scsi/scsi_lib.c`

```c
static enum scsi_disposition scsi_check_sense(struct scsi_cmnd *scmd)
{
    struct scsi_device *sdev = scmd->device;
    struct scsi_sense_hdr sshdr;

    /* parse the 18-byte sense buffer into a structured form */
    if (!scsi_command_normalize_sense(scmd, &sshdr))
        return FAILED;  /* unparseable sense → EH */

    if (scsi_sense_is_deferred(scmd))
        return NEEDS_RETRY;

    switch (sshdr.sense_key) {

    case NO_SENSE:
        return SUCCESS;

    case RECOVERED_ERROR:
        return /* check if error recovery succeeded */ SUCCESS;

    case NOT_READY:
        /*
         * ASC 0x04 = "LOGICAL UNIT NOT READY"
         * ASCQ distinguishes the reason:
         */
        if (sshdr.asc == 0x04) {
            switch (sshdr.ascq) {
            case 0x01:
                /*
                 * NOT READY / LOGICAL UNIT IS IN PROCESS OF BECOMING READY
                 * Transient state — retry.
                 * *** This feeds into no_path_retry=queue hang ***
                 * All paths return this → all paths fail via EH →
                 * dm-multipath no valid paths → queue holds bios.
                 */
                return NEEDS_RETRY;
            case 0x02:
                /*
                 * NOT READY / LOGICAL UNIT NOT READY, INITIALIZING CMD REQUIRED
                 * i.e. LUN was explicitly taken offline by admin.
                 * → FAILED → EH → DID_NO_CONNECT → path failure.
                 * Still causes no_path_retry=queue hang if all paths fail.
                 */
                return FAILED;
            case 0x0a:
                /* ASYMMETRIC ACCESS STATE TRANSITION — ALUA */
                return NEEDS_RETRY;
            default:
                return NEEDS_RETRY;
            }
        }
        return NEEDS_RETRY;

    case UNIT_ATTENTION:
        /*
         * Power on, reset, mode page changed, etc.
         * Always retry — these are transient events.
         * The UA is consumed on retry (target clears it).
         */
        if (sdev->expecting_cc_ua) {
            sdev->expecting_cc_ua = 0;
            return NEEDS_RETRY;
        }
        scsi_handle_sdev_quirk(scmd);
        return NEEDS_RETRY;

    case ILLEGAL_REQUEST:
        return SUCCESS;  /* permanent error, no retry */

    case ABORTED_COMMAND:
        /* might be retriable */
        if (sshdr.asc == 0x10) /* IDNF */
            return SUCCESS;
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

---

## scsi_queue_insert and scsi_requeue_command

When `NEEDS_RETRY` is returned, the command goes back into blk-mq:

```c
void scsi_queue_insert(struct scsi_cmnd *cmd, int reason)
{
    struct scsi_device *device = cmd->device;
    struct request_queue *q = device->request_queue;
    struct request *req = scsi_cmd_to_rq(cmd);

    scsi_unprep_request(req);

    /*
     * For SCSI_MLQUEUE_DEVICE_BUSY (TASK_SET_FULL, BUSY status):
     * delay dispatch by SCSI_QUEUE_DELAY (3ms) to avoid hammering
     * a temporarily saturated device.
     */
    if (reason == SCSI_MLQUEUE_DEVICE_BUSY)
        blk_mq_delay_run_hw_queues(q, SCSI_QUEUE_DELAY);

    blk_mq_requeue_request(req, true);  /* put back in hw queue */
}

static void scsi_requeue_command(struct request_queue *q, struct scsi_cmnd *cmd)
{
    struct request *req = scsi_cmd_to_rq(cmd);

    scsi_unprep_request(req);
    blk_mq_requeue_request(req, false);
    blk_mq_run_hw_queue(req->mq_hctx, false);
}
```

`blk_mq_requeue_request()` puts the request back into the hw queue's list. dm-multipath may then
pick it up via `multipath_map_bio()` and try a different path. If all paths return `NEEDS_RETRY`,
dm-multipath cycles through all paths, all fail, all go back to the requeue list, and if
`no_path_retry=queue` the bios accumulate in `m->queued_ios`.

---

## The NOT READY → queue hang path vs RESERVATION CONFLICT → immediate error

```
RESERVATION CONFLICT (PR path)         NOT READY (LUN offline / becoming ready)
───────────────────────────────         ────────────────────────────────────────
Target returns status 0x18              Target returns CHECK CONDITION + sense
    │                                       │  NOT READY / ASC 04 / ASCQ 01 or 02
    ▼                                       ▼
scsi_done()                             scsi_done()
    │  blk_rq_is_passthrough=true           │  blk_rq_is_passthrough=false
    │  → scsi_complete() directly           │  → blk_complete_request() → softirq
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
caller gets -ENODEV immediately             ▼
                                        dm-multipath tries next path
                                            │  same result on all paths
                                            ▼
                                        all pgpaths fail → nr_valid_paths=0
                                            │
                                            ▼  (no_path_retry=queue)
                                        multipath_map_bio(): bio_list_add()
                                            │
                                            ▼
                                        application hangs forever
```

---

## scsi_result_to_blk_status — what dm-multipath sees

```c
static blk_status_t scsi_result_to_blk_status(struct scsi_cmnd *cmd, int result)
{
    switch (host_byte(result)) {
    case DID_OK:
        if (scsi_status_is_good(result))
            return BLK_STS_OK;
        return BLK_STS_IOERR;  /* RESERVATION CONFLICT → BLK_STS_IOERR */

    case DID_TRANSPORT_FAILFAST:
        return BLK_STS_TRANSPORT; /* → dm-multipath permanent path failure */

    case DID_TARGET_FAILURE:
        return BLK_STS_TARGET;

    case DID_NEXUS_FAILURE:
        return BLK_STS_NEXUS;

    case DID_MEDIUM_ERROR:
        return BLK_STS_MEDIUM;

    case DID_ALLOC_FAILURE:
        return BLK_STS_DEV_RESOURCE; /* → MLQUEUE / retry */

    default:
        return BLK_STS_IOERR;
    }
}
```

`BLK_STS_TRANSPORT` from `DID_TRANSPORT_FAILFAST` causes dm-multipath's `multipath_end_io()` to
call `fail_path()` immediately without retry on another path. This is the behavior after
`replacement_timeout` expires — the session is declared dead, paths are failed permanently.

---

## Key takeaways

- `scsi_done()` short-circuits for passthrough (`blk_rq_is_passthrough=true`): calls
  `scsi_complete()` directly, skipping disposition and EH entirely.
- `scsi_decide_disposition()` routes based on `host_byte` and `status_byte`:
  - `RESERVATION CONFLICT (0x18)` → `SUCCESS` → immediate completion, no retry
  - `NOT READY / becoming ready` → `NEEDS_RETRY` → `scsi_queue_insert()` → back to blk-mq
  - `NOT READY / offline` → `FAILED` → EH → eventually `DID_NO_CONNECT`
  - `DID_TRANSPORT_FAILFAST` → `BLK_STS_TRANSPORT` → dm-multipath permanent path failure
- `scsi_queue_insert()` puts failed commands back into blk-mq — this is what feeds the
  dm-multipath retry loop and ultimately the `no_path_retry=queue` hang.
- `scsi_result_to_blk_status()` converts SCSI result codes to blk-mq status seen by dm-multipath.
- `DID_TRANSPORT_FAILFAST` is the key status for clean path failure notification to dm-multipath.

---

## Previous / Next

[Day 4 — SCSI mid layer queueing](day04.md) | [Day 6 — SCSI error handler](day06.md)
