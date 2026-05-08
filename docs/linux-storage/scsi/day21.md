# Day 21 — LIO backends: iblock, fileio, ramdisk, pscsi

**Week 3**: LIO Target Kernel Code  
**Time**: 1–2 hours  
**Reference**: `drivers/target/target_core_iblock.c`, `target_core_file.c`, `target_core_rd.c`, `target_core_pscsi.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

LIO separates fabric (iSCSI/FC/etc.) from backend storage. A backend implements
`struct target_backend_ops` with an `execute_cmd` that turns a `se_cmd` into actual I/O. Four
backends are upstream: `iblock` (block devices), `fileio` (regular files), `ramdisk`,
`pscsi` (SCSI passthrough). Choice of backend affects performance, features (PR, ALUA, T10-DIF),
and recovery semantics.

---

## struct target_backend_ops — `include/target/target_core_backend.h`

```c
struct target_backend_ops {
    char            name[16];

    /* Module reference */
    struct module   *owner;

    /* Lifecycle */
    int             (*attach_hba)(struct se_hba *, u32);
    void            (*detach_hba)(struct se_hba *);
    struct se_device *(*alloc_device)(struct se_hba *, const char *);
    int             (*configure_device)(struct se_device *);
    void            (*destroy_device)(struct se_device *);
    void            (*free_device)(struct se_device *);

    /* I/O dispatch */
    sense_reason_t  (*parse_cdb)(struct se_cmd *cmd);
    sense_reason_t  (*execute_cmd)(struct se_cmd *cmd);

    /* Capabilities */
    u32             (*get_blocks)(struct se_device *);
    u32             (*get_block_size)(struct se_device *);
    sector_t        (*get_alignment_offset_lbas)(struct se_device *);
    unsigned int    (*get_lbppbe)(struct se_device *);
    unsigned int    (*get_io_min)(struct se_device *);
    unsigned int    (*get_io_opt)(struct se_device *);
    unsigned char   *(*get_sense_buffer)(struct se_cmd *);

    /* configfs */
    ssize_t         (*set_configfs_dev_params)(struct se_device *,
                                                 const char *, ssize_t);
    ssize_t         (*show_configfs_dev_params)(struct se_device *,
                                                  char *);

    /* Transport flags */
    u32             transport_flags_changeable;
    u32             transport_flags_default;
};
```

`execute_cmd` is the function the target core calls (via `target_execute_cmd_work` on
`target_submission_wq`) when it's time to do actual I/O.

---

## iblock — backed by a Linux block device

The most common backend. Wraps a `/dev/sdX`, `/dev/nvme0n1`, `/dev/dm-N`, etc.

### iblock_alloc_device

```c
/* Simplified — see drivers/target/target_core_iblock.c. */
static struct se_device *iblock_alloc_device(struct se_hba *hba,
                                                const char *name)
{
    struct iblock_dev *ib_dev;

    ib_dev = kzalloc(sizeof(*ib_dev), GFP_KERNEL);
    if (!ib_dev)
        return NULL;

    /* configfs writes the path here later via set_configfs_dev_params */
    return &ib_dev->dev;
}

static int iblock_configure_device(struct se_device *dev)
{
    struct iblock_dev *ib_dev = IBLOCK_DEV(dev);
    struct block_device *bd;
    fmode_t mode;

    mode = FMODE_READ | FMODE_WRITE | FMODE_EXCL;

    /* open the configured block device path */
    bd = blkdev_get_by_path(ib_dev->ibd_udev_path, mode, ib_dev,
                              NULL);
    if (IS_ERR(bd))
        return PTR_ERR(bd);

    ib_dev->ibd_bd = bd;

    /* set up bio_set for fast bio allocation under memory pressure */
    bioset_init(&ib_dev->ibd_bio_set, IBLOCK_BIO_POOL_SIZE,
                offsetof(struct iblock_req, ib_bio), BIOSET_NEED_BVECS);

    /* probe device attributes (block size, max sectors, etc.) */
    dev->dev_attrib.hw_block_size       = bdev_logical_block_size(bd);
    dev->dev_attrib.hw_max_sectors      = queue_max_hw_sectors(bdev_get_queue(bd));
    dev->dev_attrib.hw_queue_depth      = bdev_get_queue(bd)->nr_requests;
    dev->dev_attrib.is_nonrot           = blk_queue_nonrot(bdev_get_queue(bd));
    dev->dev_attrib.fua_write_emulated  = false;

    return 0;
}
```

### iblock_execute_rw — the I/O entry

```c
/* Simplified. */
sense_reason_t iblock_execute_rw(struct se_cmd *cmd, struct scatterlist *sgl,
                                   u32 sgl_nents,
                                   enum dma_data_direction data_direction)
{
    struct iblock_dev *ib_dev = IBLOCK_DEV(cmd->se_dev);
    struct iblock_req *ibr;
    struct bio *bio;
    sector_t block_lba = target_to_linux_sector(cmd, cmd->t_task_lba);
    int sg_num = sgl_nents;
    blk_opf_t opf;
    unsigned int op_flags = 0;
    struct scatterlist *sg;
    int i;

    /* allocate request tracking struct (one per se_cmd) */
    ibr = kzalloc(sizeof(*ibr), GFP_KERNEL);
    if (!ibr)
        return TCM_OUT_OF_RESOURCES;
    cmd->priv = ibr;

    /*
     * blk_opf_t builds the operation + flags word:
     *   data_direction → REQ_OP_READ or REQ_OP_WRITE
     *   FUA            → REQ_FUA (force unit access)
     *   sync writes    → REQ_SYNC
     */
    opf = (data_direction == DMA_FROM_DEVICE) ? REQ_OP_READ : REQ_OP_WRITE;
    if (cmd->se_cmd_flags & SCF_FUA)
        op_flags |= REQ_FUA;

    /*
     * Allocate first bio. nr_vecs caps the number of bio_vec entries
     * in this bio; if SGL has more, we'll chain additional bios.
     * BIO_MAX_VECS is 256 in modern kernels.
     */
    bio = bio_alloc_bioset(ib_dev->ibd_bd,
                             min_t(unsigned short, sg_num, BIO_MAX_VECS),
                             opf | op_flags, GFP_NOIO,
                             &ib_dev->ibd_bio_set);
    if (!bio) {
        kfree(ibr);
        return TCM_OUT_OF_RESOURCES;
    }

    bio->bi_iter.bi_sector = block_lba;
    bio->bi_private = ibr;
    bio->bi_end_io = iblock_bio_done;

    atomic_set(&ibr->pending, 1);  /* one bio in flight */

    /*
     * Walk the SGL, adding pages to the bio. When this bio fills up
     * (returns 0 from bio_add_pc_page), allocate a chained bio.
     */
    for_each_sg(sgl, sg, sgl_nents, i) {
        while (bio_add_pc_page(bdev_get_queue(ib_dev->ibd_bd),
                                 bio, sg_page(sg), sg->length,
                                 sg->offset) == 0) {
            /* this bio is full — chain a new one */
            atomic_inc(&ibr->pending);
            bio = iblock_get_bio(cmd, block_lba, sg_num - i, opf);
            /* link via bi_next */
            bio->bi_next = ibr->ib_bio;
            ibr->ib_bio = bio;
        }
        block_lba += sg->length >> SECTOR_SHIFT;
    }

    /* submit the bio chain */
    iblock_submit_bios(&list);

    return 0;
}
```

### iblock_bio_done — completion

```c
static void iblock_bio_done(struct bio *bio)
{
    struct se_cmd *cmd = bio->bi_private;
    struct iblock_req *ibr = cmd->priv;

    if (bio->bi_status) {
        atomic_inc(&ibr->ib_bio_err_cnt);
        smp_mb__after_atomic();
    }

    bio_put(bio);

    /* When all bios are done, complete the se_cmd. */
    if (atomic_dec_and_test(&ibr->pending)) {
        if (atomic_read(&ibr->ib_bio_err_cnt))
            target_complete_cmd(cmd, SAM_STAT_CHECK_CONDITION);
        else
            target_complete_cmd(cmd, SAM_STAT_GOOD);

        kfree(ibr);
    }
}
```

The chain pattern is important: a multi-bio request decrements `ibr->pending` only when its
last bio completes. Earlier bios just `bio_put()`; only the final one calls
`target_complete_cmd()`. Order of completion among the bios doesn't matter for correctness —
only the count does.

---

## fileio — backed by a regular file

Useful for testing, snapshot images, sparse files. Slower than iblock because it goes through
the VFS / page cache.

```c
/* Simplified — see drivers/target/target_core_file.c. */
sense_reason_t fd_execute_rw(struct se_cmd *cmd, struct scatterlist *sgl,
                              u32 sgl_nents,
                              enum dma_data_direction data_direction)
{
    struct fd_dev *fd_dev = FD_DEV(cmd->se_dev);
    struct file *file = fd_dev->fd_file;
    struct iov_iter iter;
    struct bio_vec *bvec;
    loff_t pos = (loff_t)cmd->t_task_lba * dev->dev_attrib.block_size;
    ssize_t ret;
    int i;

    /* convert SGL to bio_vec for iov_iter */
    bvec = kcalloc(sgl_nents, sizeof(*bvec), GFP_KERNEL);
    for_each_sg(sgl, sg, sgl_nents, i) {
        bvec[i].bv_page   = sg_page(sg);
        bvec[i].bv_len    = sg->length;
        bvec[i].bv_offset = sg->offset;
    }

    iov_iter_bvec(&iter,
                   data_direction == DMA_TO_DEVICE ? WRITE : READ,
                   bvec, sgl_nents, cmd->data_length);

    if (data_direction == DMA_FROM_DEVICE) {
        ret = vfs_iter_read(file, &iter, &pos, 0);
    } else {
        ret = vfs_iter_write(file, &iter, &pos, 0);
        if (cmd->se_cmd_flags & SCF_FUA) {
            /* fsync to flush to disk */
            vfs_fsync_range(file, pos - cmd->data_length, pos, 1);
        }
    }

    kfree(bvec);

    if (ret < 0)
        return TCM_LOGICAL_UNIT_COMMUNICATION_FAILURE;

    target_complete_cmd(cmd, SAM_STAT_GOOD);
    return 0;
}
```

Note: this function is synchronous — it blocks until the VFS read/write returns. Therefore it
runs on `target_submission_wq` (queued via `target_execute_cmd`) so it doesn't block the iSCSI
RX thread. Real upstream `fd_execute_rw` may use `call_read_iter()`/`call_write_iter()`
helpers depending on the kernel version.

---

## ramdisk — backed by kernel memory

Pure kernel pages, fastest possible backend (no I/O), used for benchmarks and tests.

```c
/* Simplified. */
sense_reason_t rd_execute_rw(struct se_cmd *cmd, struct scatterlist *sgl,
                               u32 sgl_nents,
                               enum dma_data_direction data_direction)
{
    struct rd_dev *rd_dev = RD_DEV(cmd->se_dev);
    struct rd_dev_sg_table *table;
    struct scatterlist *rd_sg;
    void *rd_addr, *cmd_addr;
    u32 src_len, table_idx, rd_offset = 0;
    int i;

    /*
     * The ramdisk maintains its own SGL of pages (one for the whole device).
     * Map by LBA → table->sg_table → page within.
     */
    table = rd_get_sg_table(rd_dev, rd_offset);

    /*
     * Memcpy in either direction.
     * For READ: target buffer ← ramdisk pages
     * For WRITE: target buffer → ramdisk pages
     */
    for_each_sg(sgl, sg, sgl_nents, i) {
        if (data_direction == DMA_FROM_DEVICE) {
            memcpy(sg_virt(sg), sg_virt(rd_sg) + rd_offset, sg->length);
        } else {
            memcpy(sg_virt(rd_sg) + rd_offset, sg_virt(sg), sg->length);
        }
        rd_offset += sg->length;
    }

    target_complete_cmd(cmd, SAM_STAT_GOOD);
    return 0;
}
```

---

## pscsi — SCSI command passthrough

Wraps a SCSI device by passing commands through unchanged. Useful for proxying tape drives,
optical drives, or chained SCSI to an initiator. Limitations: no PR emulation (target relies on
the underlying device's PR support), no ALUA, no T10-DIF.

```c
/* Simplified — see drivers/target/target_core_pscsi.c. */
sense_reason_t pscsi_execute_cmd(struct se_cmd *cmd)
{
    struct pscsi_dev_virt *pdv = PSCSI_DEV(cmd->se_dev);
    struct scsi_device *sd = pdv->pdv_sd;
    unsigned char *cdb = cmd->t_task_cdb;
    struct request *req;
    int data_direction;
    blk_opf_t opf;

    /*
     * Build a passthrough request directly via blk_get_request.
     * Bypasses pscsi-internal queueing — the underlying SCSI mid layer
     * handles dispatch.
     */
    opf = (cmd->data_direction == DMA_FROM_DEVICE)
            ? REQ_OP_DRV_IN : REQ_OP_DRV_OUT;

    req = blk_mq_alloc_request(sd->request_queue, opf, 0);
    if (IS_ERR(req))
        return TCM_OUT_OF_RESOURCES;

    /* copy CDB into the request's scsi_cmnd */
    struct scsi_cmnd *scmd = blk_mq_rq_to_pdu(req);
    memcpy(scmd->cmnd, cdb, cmd->t_task_cdb_size);
    scmd->cmd_len = cmd->t_task_cdb_size;

    /* map our SGL into the request */
    blk_rq_map_kern(...);

    req->end_io = pscsi_req_done;
    req->end_io_data = cmd;
    req->timeout = PS_TIMEOUT_DISK;

    blk_execute_rq_nowait(req, false);
    return 0;
}
```

---

## Backend comparison

| Backend | Backing | Latency | PR | ALUA | T10-DIF | Use case |
|---|---|---|---|---|---|---|
| iblock | block device | µs | yes | yes | yes | most common |
| fileio | regular file | ms | yes | yes | no | testing, sparse |
| ramdisk | kernel pages | ns | yes | yes | no | benchmark |
| pscsi | SCSI passthrough | depends | underlying | no | no | tape, SES, optical |

For fencing setups, **iblock is the default**. PR is fully emulated by LIO regardless of
backend (except pscsi), so the underlying block device doesn't need to support PR — LIO does it.
ALUA likewise.

---

## How execute_cmd is called

```
target_execute_cmd(cmd)                   [target_core_transport.c]
    │
    ├── synchronous emulated commands run inline
    │   (TUR, READ CAPACITY, REPORT LUNS, INQUIRY, PR commands)
    │
    └── data commands queue to target_submission_wq
            │
            ▼
    target_execute_cmd_work(work)
            │  cmd->se_dev->transport->execute_cmd(cmd)
            ▼
    iblock_execute_cmd / fd_execute_cmd / rd_execute_cmd
            │  routes to _rw, _sync_cache, _unmap, _write_same etc.
            ▼
    backend submits I/O (bio for iblock, vfs_iter_* for fileio)
            │
            ▼  asynchronous: I/O completes later
    bio->bi_end_io = iblock_bio_done (or equivalent)
            │
            ▼
    target_complete_cmd(cmd, SAM_STAT_GOOD or CHECK_CONDITION)
            │
            ▼
    queue to target_completion_wq → response sent to initiator
```

---

## Key takeaways

- LIO is fabric/backend split: same iSCSI fabric works with iblock, fileio, ramdisk, pscsi.
- `target_backend_ops.execute_cmd` is the entry point. Called via `target_submission_wq` for
  data I/O; called inline for emulated short commands.
- `iblock` allocates bios, walks the SGL, chains bios when one fills up. Completion via
  `iblock_bio_done` decrements pending count; last bio triggers `target_complete_cmd`.
- `fileio` uses `vfs_iter_read/write` (or `call_read_iter`/`call_write_iter` in newer code).
  Synchronous — runs on submission workqueue.
- `ramdisk` is pure memcpy. Lowest latency.
- `pscsi` proxies CDBs to an underlying SCSI device via passthrough — no LIO emulation of PR/ALUA.
- PR is fully emulated by LIO core (`target_core_pr.c`), independent of backend (except pscsi).
  Same goes for ALUA. So fencing semantics work uniformly across iblock/fileio/ramdisk.

---

## Previous / Next

[Day 20 — LIO Persistent Reservations](day20.md) | [Day 22 — Task Management Functions](day22.md)
