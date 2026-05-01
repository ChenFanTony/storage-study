# Day 4 — SCSI mid layer: queueing

**Week 1**: Block Layer — blk-mq and SCSI Mid Layer  
**Time**: 1–2 hours  
**Reference**: `drivers/scsi/scsi_lib.c`, `include/scsi/scsi_cmnd.h`, `drivers/scsi/scsi.c`

---

## Overview

The SCSI mid layer sits between blk-mq and the Low Level Driver (LLD). Its job: translate a
blk-mq `request` into a `scsi_cmnd`, call the LLD's `queuecommand()`, and handle the result. It
also owns retry counting and the gate to EH. Understanding how `scsi_cmnd` is built and what
`REQ_OP_DRV_IN/OUT` means in this layer is essential for tracing both normal I/O and PR commands.

---

## struct scsi_cmnd — `include/scsi/scsi_cmnd.h`

```c
struct scsi_cmnd {
    struct scsi_device  *device;           /* which device this goes to */
    struct list_head     eh_entry;         /* link in error handler queue */
    struct delayed_work  abort_work;       /* timer for abort escalation */
    struct rcu_head      rcu;

    int                  eh_eflags;        /* EH internal state flags */

    /*
     * CDB — Command Descriptor Block.
     * The actual SCSI command bytes. e.g. for WRITE(10):
     *   cmnd[0] = 0x2A (WRITE_10)
     *   cmnd[1] = 0 (flags)
     *   cmnd[2..5] = LBA (big-endian)
     *   cmnd[6] = 0
     *   cmnd[7..8] = transfer length (big-endian)
     *   cmnd[9] = 0 (control)
     *
     * For PERSISTENT RESERVE OUT (from sd_pr_reserve):
     *   cmnd[0] = 0x5F (PERSISTENT_RESERVE_OUT)
     *   cmnd[1] = action (REGISTER, RESERVE, RELEASE...)
     *   cmnd[2] = type | scope
     *   cmnd[3..6] = 0
     *   cmnd[7..8] = parameter list length
     *   cmnd[9] = 0
     */
    unsigned char        cmnd[32];
    int                  cmd_len;          /* CDB length (6, 10, 12, 16, or 32) */

    /* data transfer */
    enum dma_data_direction sc_data_direction; /* DMA_TO/FROM_DEVICE or DMA_NONE */

    struct scsi_data_buffer sdb;           /* main data SGL */
    struct scsi_data_buffer *prot_sdb;     /* T10-DIF protection SGL */

    unsigned int         underflow;        /* error if less than this transferred */

    /*
     * Sense data buffer — filled by target on CHECK CONDITION.
     * 96 bytes is enough for any standard sense response.
     * Format:
     *   [0]    response code (0x70 fixed, 0x72 descriptor)
     *   [2]    sense key (NOT_READY=0x02, ILLEGAL_REQUEST=0x05, etc.)
     *   [7]    additional sense length
     *   [12]   ASC  (additional sense code)
     *   [13]   ASCQ (additional sense code qualifier)
     */
    unsigned int         sense_len;
    unsigned char        sense_buffer[SCSI_SENSE_BUFFERSIZE]; /* 96 bytes */

    /*
     * result — packed SCSI result code:
     *   bits 31-24: driver_byte  (unused since 5.x kernels)
     *   bits 23-16: host_byte    (DID_OK, DID_NO_CONNECT, DID_TRANSPORT_FAILFAST...)
     *   bits  7- 0: status_byte  (SAM_STAT_GOOD, SAM_STAT_CHECK_CONDITION,
     *                             SAM_STAT_RESERVATION_CONFLICT...)
     */
    int                  result;

    unsigned int         extra_len;        /* extra request queue bytes */

    /* retry accounting */
    int                  retries;          /* current retry count */
    int                  allowed;          /* maximum retries (from scsi_execute_cmd) */

    /* timing */
    unsigned long        jiffies_at_alloc; /* for timeout calculation */
    int                  timeout_per_command;

    /*
     * Completion callback — set to scsi_finish_command() for normal I/O.
     * For passthrough (scsi_execute_cmd), set to a sync completion wrapper.
     */
    void (*scsi_done)(struct scsi_cmnd *);

    /* LLD private storage — libiscsi stores iscsi_task pointer here */
    struct scsi_pointer  SCp;
};
```

The `result` field layout:

```c
/* extracting components from result */
#define host_byte(result)   (((result) >> 16) & 0xff)
#define status_byte(result) ((result) & 0xff)

/* host_byte values — set by the transport / EH */
#define DID_OK              0x00  /* no transport error */
#define DID_NO_CONNECT      0x01  /* could not connect before timeout */
#define DID_BUS_BUSY        0x02  /* bus busy */
#define DID_TIME_OUT        0x03  /* timed out */
#define DID_ABORT           0x05  /* command aborted */
#define DID_RESET           0x06  /* device was reset */
#define DID_SOFT_ERROR      0x0b  /* retriable transport error */
#define DID_TRANSPORT_FAILFAST 0x0e /* non-retriable transport error */

/* status_byte values — returned by target in SCSI Response PDU */
#define SAM_STAT_GOOD                 0x00
#define SAM_STAT_CHECK_CONDITION      0x02  /* sense data available */
#define SAM_STAT_CONDITION_MET        0x04
#define SAM_STAT_BUSY                 0x08
#define SAM_STAT_INTERMEDIATE         0x10
#define SAM_STAT_RESERVATION_CONFLICT 0x18  /* PR conflict — our key focus */
#define SAM_STAT_TASK_SET_FULL        0x28
#define SAM_STAT_TASK_ABORTED         0x40
```

When iSCSI delivers `RESERVATION CONFLICT`:
- `host_byte = DID_OK` (transport worked fine)
- `status_byte = SAM_STAT_RESERVATION_CONFLICT` (0x18)
- No sense data (RESERVATION CONFLICT has no sense key — it is its own status)

`scsi_decide_disposition()` (day 5) sees `status_byte = 0x18` and returns `SUCCESS` immediately —
no retry, no EH. The conflict propagates directly to the caller.

---

## scsi_queue_rq — `drivers/scsi/scsi_lib.c`

This is the `queue_rq` blk-mq callback registered by the SCSI mid layer. Called by
`blk_mq_dispatch_rq_list()` for every request.

```c
static blk_status_t scsi_queue_rq(struct blk_mq_hw_ctx *hctx,
                                   const struct blk_mq_queue_data *bd)
{
    struct request *req = bd->rq;
    struct request_queue *q = req->q;
    struct scsi_device *sdev = q->queuedata;  /* scsi_device for this queue */
    struct Scsi_Host *shost = sdev->host;
    /* scsi_cmnd is embedded directly in the request's PDU area */
    struct scsi_cmnd *cmd = blk_mq_rq_to_pdu(req);
    blk_status_t ret;
    int reason;

    /*
     * Check device state — if device is offline or being deleted,
     * reject the request immediately without sending to the LLD.
     */
    ret = prep_to_mq(scsi_prep_state_check(sdev, req));
    if (ret != BLK_STS_OK)
        goto out_put_budget;

    ret = BLK_STS_RESOURCE;

    /*
     * Check host-level queue depth. The Scsi_Host has a separate
     * can_queue limit on top of the per-hctx tag limit.
     */
    if (!scsi_host_queue_ready(q, shost, sdev, cmd))
        goto out_put_budget;

    if (!(req->rq_flags & RQF_DONTPREP)) {
        /*
         * Build the scsi_cmnd — copy CDB, set up SGL, etc.
         * For normal I/O: scsi_setup_fs_cmnd()
         * For passthrough: scsi_setup_scsi_cmnd()
         */
        ret = prep_to_mq(scsi_prep_fn(q, req));
        if (ret != BLK_STS_OK)
            goto out_dec_host_busy;
        req->rq_flags |= RQF_DONTPREP;
    }

    /*
     * Final device state check — device could have gone offline
     * between the prep check and here.
     */
    if (unlikely(!scsi_device_online(sdev))) {
        scmd->result = DID_NO_CONNECT << 16;
        scsi_done(cmd);
        return BLK_STS_OK;
    }

    scsi_log_send(cmd);

    /*
     * Hand off to the LLD. For iscsi_tcp this is iscsi_queuecommand().
     * The LLD is responsible for sending the PDU over the network.
     */
    scsi_dispatch_cmd(cmd);
    return BLK_STS_OK;

out_dec_host_busy:
    scsi_dec_host_busy(shost, cmd);
out_put_budget:
    scsi_mq_put_budget(q, budget_token);
    switch (ret) {
    case BLK_STS_OK:
        break;
    case BLK_STS_RESOURCE:
    case BLK_STS_ZONE_RESOURCE:
        blk_mq_delay_run_hw_queues(q, SCSI_QUEUE_DELAY);
        break;
    default:
        blk_mq_end_request(req, ret);
    }
    return ret;
}
```

`blk_mq_rq_to_pdu(req)` returns the `scsi_cmnd` embedded in the request's per-driver PDU area.
This embedding is set up during host registration:

```c
/* in scsi_mq_setup_tags() — called when registering a Scsi_Host */
shost->tag_set.cmd_size = sizeof(struct scsi_cmnd)
                        + shost->hostt->cmd_size; /* LLD extra size */
```

So the memory layout of a blk-mq request for a SCSI device is:
```
[struct request][struct scsi_cmnd][LLD private data (iscsi_task etc.)]
```

All in one contiguous allocation. No separate kmalloc for `scsi_cmnd`.

---

## scsi_prep_state_check — device state gating

```c
static enum scsi_disposition
scsi_prep_state_check(struct scsi_device *sdev, struct request *req)
{
    switch (sdev->sdev_state) {
    case SDEV_CREATED:
    case SDEV_RUNNING:
        return SCSI_MLQUEUE_GOOD;      /* device is ready */

    case SDEV_QUIESCE:
        /*
         * Device is being quiesced (e.g. for EH).
         * Passthrough commands are allowed through (for EH itself to use).
         * Normal I/O is rejected with MLQUEUE_DEVICE_BUSY (retry later).
         */
        if (blk_rq_is_passthrough(req))
            return SCSI_MLQUEUE_GOOD;
        return SCSI_MLQUEUE_DEVICE_BUSY;

    case SDEV_OFFLINE:
        /*
         * Device taken offline by admin (echo offline > /sys/block/sdX/device/state)
         * All commands fail immediately.
         */
        scmd->result = DID_NO_CONNECT << 16;
        return SCSI_MLQUEUE_TERMINATE;

    case SDEV_TRANSPORT_OFFLINE:
        /*
         * iSCSI session dropped — iscsi_conn_failure() sets this.
         * All commands get DID_NO_CONNECT → EH → path failure.
         */
        if (!blk_rq_is_passthrough(req)) {
            scmd->result = DID_TRANSPORT_DISRUPTED << 16;
            return SCSI_MLQUEUE_TERMINATE;
        }
        return SCSI_MLQUEUE_GOOD;  /* let EH passthrough commands through */

    case SDEV_DEL:
        scmd->result = DID_NO_CONNECT << 16;
        return SCSI_MLQUEUE_TERMINATE;

    default:
        return SCSI_MLQUEUE_DEVICE_BUSY;
    }
}
```

`SDEV_TRANSPORT_OFFLINE` is set by `iscsi_conn_failure()` when the TCP session drops. At that
point, new I/O commands from the filesystem get `DID_TRANSPORT_DISRUPTED` without hitting the
wire. EH wakes, tries to recover the session, and eventually either reconnects or calls
`scsi_device_set_state(sdev, SDEV_OFFLINE)` + `DID_NO_CONNECT` on all pending commands.

---

## scsi_execute_cmd — `drivers/scsi/scsi_lib.c`

The kernel API for synchronous passthrough SCSI commands. Used by `sd_pr_reserve()`, path checkers,
INQUIRY handlers, etc.

```c
int scsi_execute_cmd(struct scsi_device *sdev,
                     const unsigned char *cmd,  /* CDB bytes */
                     blk_opf_t opf,             /* REQ_OP_DRV_IN or REQ_OP_DRV_OUT */
                     void *buffer,              /* data buffer (or NULL) */
                     unsigned int bufflen,      /* buffer length */
                     int timeout,               /* timeout in jiffies */
                     int retries,               /* allowed retries */
                     const struct scsi_exec_args *args)
{
    struct request *req;
    struct scsi_cmnd *scmd;
    int ret;

    /*
     * Allocate a request with REQ_OP_DRV_IN or REQ_OP_DRV_OUT.
     * blk_rq_is_passthrough() will return true — this request gets
     * special treatment at every layer (head injection, no retry, etc.)
     */
    req = scsi_alloc_request(sdev->request_queue, opf,
                             args ? args->req_flags : 0);
    if (IS_ERR(req))
        return PTR_ERR(req);

    scmd = blk_mq_rq_to_pdu(req);

    /*
     * Copy the CDB into the embedded scsi_cmnd.
     * For PR OUT: cmd = {0x5F, action, type, 0, 0, 0, 0, 0, 18, 0}
     */
    scmd->cmd_len = COMMAND_SIZE(cmd[0]);
    memcpy(scmd->cmnd, cmd, scmd->cmd_len);

    scmd->allowed = retries;

    if (bufflen) {
        /*
         * Map the kernel buffer into the request's SGL.
         * This avoids copying — the DMA engine reads directly from buffer.
         */
        ret = blk_rq_map_kern(sdev->request_queue, req,
                              buffer, bufflen, GFP_NOIO);
        if (ret)
            goto out;
    }

    req->timeout = timeout;

    if (args) {
        if (args->sense)
            scmd->sense_buffer = args->sense;
        if (args->sshdr)
            scmd->sense_buffer = sense; /* for parsing later */
    }

    /*
     * blk_execute_rq() injects at head and blocks until done.
     * This is the synchronous slow path (day 3).
     */
    ret = blk_execute_rq(req, args ? args->at_head : false);

    /*
     * On return, scmd->result has the packed SCSI result.
     * Translate to an errno if needed.
     */
    if (scmd->result & ~0xff)
        ret = -EIO;

    if (args) {
        if (args->resid)
            *args->resid = scsi_get_resid(scmd);
        if (args->sense_len)
            *args->sense_len = scmd->sense_len;
        if (args->result)
            *args->result = scmd->result;
    }

out:
    blk_mq_free_request(req);
    return ret;
}
```

For a PR OUT command, `sd_pr_reserve()` calls this with:
- `cmd = {0x5F, 0x01, type<<4, 0,0,0,0,0,0x18,0}` — PERSISTENT RESERVE OUT / RESERVE action
- `opf = REQ_OP_DRV_OUT`
- `buffer` = 24-byte PR parameter list (key values)
- `bufflen = 24`
- `timeout = 10 * HZ`
- `retries = 1`

The `scsi_cmnd->cmnd[]` array holds these bytes and they are transmitted verbatim as the CDB in
the iSCSI Command PDU.

---

## scsi_alloc_sgtable — `drivers/scsi/scsi.c`

For passthrough commands with data, `blk_rq_map_kern()` builds the SGL:

```c
int blk_rq_map_kern(struct request_queue *q, struct request *rq,
                    void *kbuf, unsigned int len, gfp_t gfp_mask)
{
    int reading = rq_data_dir(rq) == READ;
    unsigned long addr = (unsigned long) kbuf;
    int do_copy = 0;
    struct bio *bio;
    int ret;

    /* check alignment — if not page-aligned, we need a bounce buffer */
    if (!blk_rq_aligned(q, addr, len) || object_is_on_stack(kbuf))
        do_copy = 1;

    if (!do_copy) {
        bio = bio_map_kern(q, kbuf, len, gfp_mask);
    } else {
        bio = bio_copy_kern(q, kbuf, len, gfp_mask, reading);
    }

    if (IS_ERR(bio))
        return PTR_ERR(bio);

    bio->bi_opf &= ~REQ_OP_MASK;
    bio->bi_opf |= req_op(rq);

    ret = blk_rq_append_bio(rq, bio);
    /* ... */
    return ret;
}
```

For the 24-byte PR parameter list, `bio_map_kern()` creates a single-entry bio pointing directly
at the caller's kernel buffer. No copy needed if aligned. The DMA engine reads from this buffer
when the iSCSI TX path sends the Data-Out PDU.

---

## scsi_dispatch_cmd — calling the LLD

```c
static int scsi_dispatch_cmd(struct scsi_cmnd *cmd)
{
    struct Scsi_Host *host = cmd->device->host;
    int rtn = 0;

    atomic_inc(&cmd->device->iorequest_cnt);

    /* check host state again right before calling LLD */
    if (unlikely(host->shost_state == SHOST_DEL)) {
        cmd->result = (DID_NO_CONNECT << 16);
        scsi_done(cmd);
        return 0;
    }

    /* cmd->scsi_done is the completion callback back to SCSI mid layer */
    cmd->scsi_done = scsi_done;

    /*
     * Call the LLD's queuecommand function.
     * For iscsi_tcp: iscsi_queuecommand()
     * For qla2xxx FC: qla2xxx_queuecommand()
     */
    rtn = host->hostt->queuecommand(host, cmd);

    if (rtn) {
        atomic_dec(&cmd->device->iorequest_cnt);
        if (rtn != SCSI_MLQUEUE_DEVICE_BUSY &&
            rtn != SCSI_MLQUEUE_TARGET_BUSY) {
            /* hard error from LLD */
            cmd->result = (DID_ERROR << 16);
            scsi_done(cmd);
        }
    }

    return rtn;
}
```

`scsi_done` (set as `cmd->scsi_done`) is what the LLD calls when it receives the SCSI Response
PDU from the target — this re-enters the SCSI mid layer at `scsi_io_completion()` (day 5).

---

## Key takeaways

- `scsi_cmnd` is embedded directly in the blk-mq request PDU area — one contiguous allocation.
- `result` packs `host_byte | status_byte` — each is checked independently in `scsi_decide_disposition()`.
- `scsi_queue_rq()` checks device state, builds `scsi_cmnd`, and calls `scsi_dispatch_cmd()`.
- `scsi_execute_cmd()` is the passthrough API — CDB goes in `scmd->cmnd[]`, data maps via
  `blk_rq_map_kern()`, then `blk_execute_rq()` sends synchronously.
- `SDEV_TRANSPORT_OFFLINE` set by `iscsi_conn_failure()` causes `DID_TRANSPORT_DISRUPTED` on all
  new commands — they don't touch the wire, EH takes over.
- `SAM_STAT_RESERVATION_CONFLICT` (0x18) in `status_byte` + `DID_OK` in `host_byte` = immediate
  error, no retry, no EH.

---

## Previous / Next

[Day 3 — blk_execute_rq the slow path](day03.md) | [Day 5 — SCSI completion and disposition](day05.md)
