# Day 26 — NVMe-oF target fabric

**Week 4**: Deep Cuts — TMF, ALUA, configfs, NVMe-oF, Sense Data
**Time**: 1–2 hours
**Reference**: `drivers/nvme/target/core.c`, `drivers/nvme/target/io-cmd-bdev.c`, `drivers/nvme/target/fabrics-cmd.c`

---

## Overview

NVMe-oF (NVMe over Fabrics) is the modern alternative to iSCSI for block storage. On the target
side, Linux implements it in `drivers/nvme/target/`. Unlike iSCSI/LIO which uses `target_core_mod`
as the common fabric abstraction, NVMe-oF target has its own command path — though it shares some
concepts. Reading nvmet code reveals what LIO's abstraction costs and what a more direct path looks
like. It also shows where NVMe-oF PR (TP4049 / NVMe 1.4) diverges from SCSI PR.

---

## Architecture comparison

```
iSCSI target stack:                    NVMe-oF target stack:
─────────────────────────────          ─────────────────────────────
TCP socket                             RDMA / TCP / FC transport
    │                                       │
iscsi_target_mod (fabric)              nvmet_tcp / nvmet_rdma (fabric)
    │ se_cmd                                │ nvmet_req
target_core_mod                        nvmet core (core.c)
    │ se_device                             │ nvmet_ns
target_core_iblock.c                   nvmet_bdev_execute_rw()
    │                                       │
blkdev (block layer)                   blkdev (block layer)
```

The key difference: NVMe-oF target does NOT use `target_core_mod`. There is no `se_cmd`,
no `target_submission_wq`, no fabric ops table. NVMe-oF has its own simpler dispatch path.

---

## struct nvmet_req — `drivers/nvme/target/nvmet.h`

The NVMe-oF equivalent of `se_cmd`:

```c
struct nvmet_req {
    struct nvme_command     *cmd;          /* NVMe command (64-byte capsule) */
    struct nvme_completion  *cqe;          /* completion queue entry */
    struct nvmet_sq         *sq;           /* submission queue */
    struct nvmet_cq         *cq;           /* completion queue */
    struct nvmet_ns         *ns;           /* namespace (= block device) */

    /* data transfer */
    struct scatterlist      *sg;           /* scatter-gather list */
    int                     sg_cnt;        /* SGL entries */
    size_t                  transfer_len;  /* bytes to transfer */
    size_t                  data_len;      /* actual data length */

    /* inline SGL for small transfers */
    struct scatterlist      inline_sg[NVMET_MAX_INLINE_SGS];

    /* metadata (T10-DIF equivalent) */
    struct scatterlist      *metadata_sg;
    int                     metadata_sg_cnt;

    /* execute function — set during parse */
    void (*execute)(struct nvmet_req *req);

    /* completion */
    u16                     error_loc;     /* where in the command the error is */
    u32                     error_slba;    /* starting LBA for range errors */

    /* DMA mapping */
    struct device           *p2p_client;
    struct list_head        p2p_entry;
};
```

`nvmet_req->execute` is set by `nvmet_parse_io_cmd()` to the appropriate handler:
- `nvmet_bdev_execute_rw` for READ/WRITE on block namespaces
- `nvmet_bdev_execute_flush` for FLUSH
- `nvmet_bdev_execute_discard` for Dataset Management (TRIM/DISCARD)
- `nvmet_execute_identify` for IDENTIFY controller/namespace

---

## nvmet_req_init — `drivers/nvme/target/core.c`

```c
bool nvmet_req_init(struct nvmet_req *req, struct nvmet_cq *cq,
                    struct nvmet_sq *sq,
                    const struct nvmet_fabrics_ops *ops)
{
    struct nvme_command *cmd = req->cmd;
    u8 flags = cmd->common.flags;
    u16 status;

    req->sq  = sq;
    req->cq  = cq;
    req->ns  = NULL;
    req->sg  = NULL;
    req->sg_cnt = 0;
    req->transfer_len = 0;
    req->ops = ops;

    /* initialise completion entry */
    req->cqe->status         = 0;
    req->cqe->sq_head        = 0;
    req->cqe->sq_id          = sq->qid;
    req->cqe->command_id     = cmd->common.command_id;
    req->cqe->result.u64     = 0;

    /*
     * Lookup the namespace from the NSID in the command.
     * NVMe uses NSID (Namespace ID) instead of SCSI LUN.
     * Namespace = block device exposed by the controller.
     */
    if (likely(nvme_is_write(cmd) || cmd->common.opcode == nvme_cmd_read)) {
        req->ns = nvmet_find_namespace(sq->ctrl, cmd->rw.nsid);
        if (unlikely(!req->ns)) {
            status = NVME_SC_INVALID_NS | NVME_SC_DNR;
            goto fail;
        }
        nvmet_check_ana_state(req);  /* ALUA equivalent for NVMe */
    }

    /*
     * Parse the command and set req->execute function pointer.
     * For I/O commands: nvmet_parse_io_cmd().
     * For admin commands: nvmet_parse_admin_cmd().
     */
    status = nvmet_parse_io_cmd(req);
    if (status)
        goto fail;

    return true;

fail:
    nvmet_req_complete(req, status);
    return false;
}
```

Compare with `target_submit_cmd()` in LIO: both do namespace/LUN lookup, both check access state,
both set a function pointer for the execute handler. The NVMe-oF version is much more direct —
no workqueue at this point, no PR check (handled differently in NVMe).

---

## nvmet_parse_io_cmd — `drivers/nvme/target/io-cmd-bdev.c`

```c
u16 nvmet_bdev_parse_io_cmd(struct nvmet_req *req)
{
    switch (req->cmd->common.opcode) {
    case nvme_cmd_read:
    case nvme_cmd_write:
        req->execute = nvmet_bdev_execute_rw;
        return 0;

    case nvme_cmd_flush:
        req->execute = nvmet_bdev_execute_flush;
        return 0;

    case nvme_cmd_dsm:  /* Dataset Management = TRIM/DISCARD */
        req->execute = nvmet_bdev_execute_discard;
        return 0;

    case nvme_cmd_write_zeroes:
        req->execute = nvmet_bdev_execute_write_zeroes;
        return 0;

    default:
        pr_err("unhandled cmd %d on qid %d\n",
               req->cmd->common.opcode, req->sq->qid);
        return NVME_SC_INVALID_OPCODE | NVME_SC_DNR;
    }
}
```

---

## nvmet_bdev_execute_rw — `drivers/nvme/target/io-cmd-bdev.c`

The equivalent of `iblock_execute_rw()`. Notably simpler — no `se_device` indirection, no
workqueue, executes directly:

```c
static void nvmet_bdev_execute_rw(struct nvmet_req *req)
{
    unsigned int i = req->sg_cnt;
    struct bio *bio = NULL;
    struct scatterlist *sg;
    sector_t sector;
    blk_opf_t opf;
    int rc;
    struct bio_set *bs = &req->ns->bdev_bio_set;

    if (!nvmet_check_transfer_len(req, nvmet_rw_data_len(req)))
        return;

    if (!req->sg_cnt) {
        nvmet_req_complete(req, 0);
        return;
    }

    if (req->cmd->rw.opcode == nvme_cmd_write) {
        opf = REQ_OP_WRITE | REQ_SYNC | REQ_IDLE;
        if (req->cmd->rw.control & cpu_to_le16(NVME_RW_FUA))
            opf |= REQ_FUA;  /* Force Unit Access: flush after write */
    } else {
        opf = REQ_OP_READ;
    }

    /*
     * Convert SLBA (Starting LBA from NVMe command) to sector number.
     * NVMe uses 64-bit LBA, sector = slba * (ns->blksize_shift - 9)
     */
    sector = nvmet_lba_to_sector(req->ns, req->cmd->rw.slba);

    if (req->transfer_len <= NVMET_MAX_INLINE_DATA_LEN &&
        req->sg == req->inline_sg) {
        /* small I/O: use inline bio, no pool allocation needed */
        bio = bio_alloc(req->ns->bdev, req->sg_cnt, opf, GFP_KERNEL);
    } else {
        bio = bio_alloc_bioset(req->ns->bdev, req->sg_cnt, opf,
                               GFP_KERNEL, bs);
    }

    bio->bi_iter.bi_sector = sector;
    bio->bi_end_io         = nvmet_bio_done;
    bio->bi_private        = req;

    /*
     * Map SGL entries into the bio.
     * Same bio_add_page() loop as iblock_execute_rw().
     */
    for_each_sg(req->sg, sg, req->sg_cnt, i) {
        while (bio_add_page(bio, sg_page(sg), sg->length, sg->offset) != sg->length) {
            struct bio *prev = bio;

            bio = bio_alloc_bioset(req->ns->bdev, req->sg_cnt - i,
                                    opf, GFP_KERNEL, bs);
            bio->bi_iter.bi_sector = bio_end_sector(prev);
            bio->bi_end_io  = nvmet_bio_done;
            bio->bi_private = req;

            bio_chain(prev, bio);  /* chain bios for single completion */
            submit_bio(prev);
        }
    }

    submit_bio(bio);  /* last bio submission triggers the chain */
}
```

`bio_chain()` is a NVMe-oF optimization not used in LIO/iblock: it links bios so only the last
one calls the completion callback. This avoids the `pending` atomic counter approach that iblock
uses — cleaner for the case of multiple chained bios.

---

## nvmet_bio_done — completion

```c
static void nvmet_bio_done(struct bio *bio)
{
    struct nvmet_req *req = bio->bi_private;

    /*
     * bio_chain: if this bio has a parent, just put it and let the
     * parent's bi_end_io handle final completion.
     * The last bio in the chain (no parent) calls nvmet_req_complete().
     */
    nvmet_req_complete(req,
                       bio->bi_status ? NVME_SC_INTERNAL | NVME_SC_DNR : 0);
    bio_put(bio);
}
```

---

## nvmet_req_complete — `drivers/nvme/target/core.c`

```c
void nvmet_req_complete(struct nvmet_req *req, u16 status)
{
    struct nvmet_sq *sq = req->sq;

    if (!status)
        status = nvmet_check_transfer_len(req, req->transfer_len);

    req->cqe->status = cpu_to_le16(status << 1);

    /*
     * Call the transport-specific completion function.
     * For TCP: nvmet_tcp_queue_response()
     * For RDMA: nvmet_rdma_queue_response()
     *
     * This posts the NVMe completion queue entry (CQE) back to the initiator.
     * 16 bytes: sq_head, sq_id, command_id, status.
     *
     * No workqueue involvement — completion goes directly back to
     * the transport layer.
     */
    req->ops->queue_response(req);

    /* release namespace reference */
    if (req->ns)
        nvmet_put_namespace(req->ns);
}
EXPORT_SYMBOL_GPL(nvmet_req_complete);
```

Compare with LIO's completion path:
- LIO: `target_complete_cmd()` → `queue_work(target_completion_wq, ...)` → worker →
  `target_complete_ok_work()` → `se_tfo->queue_status()` → fabric TX
- NVMe-oF: `nvmet_req_complete()` → `req->ops->queue_response()` → transport TX directly

NVMe-oF has one fewer workqueue hop — the completion goes directly to the transport. This is a
meaningful latency difference for high-IOPS NVMe workloads.

---

## NVMe-oF PR — TP4049

```c
/*
 * NVMe Persistent Reservations (TP4049, added in NVMe 1.4) are
 * implemented differently from SCSI PR:
 *
 * NVMe PR commands:
 *   RESERVATION REGISTER  (opcode 0x0D, action 0x0)
 *   RESERVATION ACQUIRE   (opcode 0x0D, action 0x1)
 *   RESERVATION RELEASE   (opcode 0x0D, action 0x2)
 *   RESERVATION REPORT    (opcode 0x0E)
 *   RESERVATION PREEMPT   (opcode 0x0D, action 0x3)
 *
 * In nvmet: handled by nvmet_execute_pr_*() functions in
 * drivers/nvme/target/pr.c (added in kernel 6.0).
 *
 * NVMe reservation types:
 *   1 = Write Exclusive
 *   2 = Exclusive Access
 *   3 = Write Exclusive - Registrants Only
 *   4 = Exclusive Access - Registrants Only
 *   5 = Write Exclusive - All Registrants
 *   6 = Exclusive Access - All Registrants
 *
 * Conflict response: NVME_SC_RESERVATION_CONFLICT (0x19)
 * vs SCSI: SAM_STAT_RESERVATION_CONFLICT (0x18)
 *
 * Key difference from SCSI PR:
 *   NVMe PR uses the host NQN (NVMe Qualified Name) as the I_T nexus
 *   identifier, not an IQN.
 *   Registration is per-controller, not per-I_T nexus.
 */
```

---

## NVMe-oF vs iSCSI/LIO for the fencing use case

```
Fencing via NVMe-oF PR:
    Works similarly to SCSI PR.
    RESERVATION ACQUIRE → reservation held.
    Non-holder commands → NVME_SC_RESERVATION_CONFLICT returned immediately.
    No workqueue involvement — direct path.

Fencing via NVMe-oF subsystem/controller removal (equivalent to session drop):
    nvmet_subsys: target subsystem (equivalent to iSCSI target IQN)
    nvmet_ctrl:   per-host controller (equivalent to iSCSI session)

    Removing a host NQN from allowed_hosts:
        echo "" > /sys/kernel/config/nvmet/subsystems/<subsys>/allowed_hosts/<nqn>
        → nvmet_host_put() → controller becomes unauthorized
        → new connections rejected (NVME_SC_CONNECT_CTRL_BUSY or AUTH_REQUIRED)
        → existing controller: nvmet_ctrl_put() → controller teardown

    Much faster than iSCSI fencing:
        No replacement_timeout equivalent.
        NVMe-oF controller teardown is immediate.
        Host sees I/O errors within the fabric's timeout (seconds not minutes).
```

---

## Key differences: nvmet vs target_core_mod

| Aspect | target_core_mod (LIO) | nvmet (NVMe-oF) |
|---|---|---|
| Command struct | `se_cmd` (generic) | `nvmet_req` (NVMe-specific) |
| Workqueue | `target_submission_wq` + `target_completion_wq` | None — direct dispatch |
| Completion path | se_tfo->queue_status() → TX thread | req->ops->queue_response() → transport |
| PR | target_core_pr.c (SCSI SPC-4) | pr.c (NVMe TP4049) |
| Backend | target_backend_ops (iblock/fileio/pscsi) | Direct blkdev_issue_* |
| TMF | target_tmr_wq (ordered) | No TMF equivalent (abort via CID) |
| Config | configfs target/ tree | configfs nvmet/ tree |
| Fabric abstraction | se_tfo ops table | nvmet_fabrics_ops |

---

## Key takeaways

- NVMe-oF target does NOT use `target_core_mod`. It has its own `nvmet_req` struct and dispatch.
- `nvmet_req_init()` does NSID lookup (like LUN lookup), sets `req->execute` function pointer.
- `nvmet_bdev_execute_rw()` maps SGL to bios (same pattern as iblock) using `bio_chain()` for
  multi-bio chains — cleaner than iblock's pending counter.
- `nvmet_req_complete()` calls `req->ops->queue_response()` directly — no workqueue hop. One
  fewer latency step than LIO's `target_completion_wq`.
- NVMe PR (TP4049) uses similar concepts to SCSI PR but different command opcodes, conflict
  status code (`0x19`), and NQN-based I_T nexus identification.
- NVMe-oF controller teardown is faster than iSCSI session teardown — no `replacement_timeout`
  equivalent means fencing completes in seconds rather than up to 120s.
- The trade-off: nvmet's directness makes it faster but less general. LIO's abstraction (se_tfo,
  target_core_mod) means the same backend logic works for iSCSI, FC, SRP, and NVMe-oF fabrics.

---

## Previous / Next

[Day 25 — session teardown path](day25.md) | [Day 27 — iSCSI login sequence](day27.md)
