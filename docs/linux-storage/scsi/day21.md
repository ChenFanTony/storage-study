# Day 21 — LIO backends

**Week 3**: LIO Target Core — Fabric to Backend
**Time**: 1–2 hours
**Reference**: `drivers/target/target_core_iblock.c`, `drivers/target/target_core_file.c`, `drivers/target/target_core_pscsi.c`

---

## Overview

LIO supports multiple backend plugins — iblock (block device), fileio (file), and pscsi (SCSI
passthrough). Each implements `target_backend_ops.execute_cmd`. The backend receives an `se_cmd`
with a fully-populated SGL and must call `target_complete_cmd()` when done. Understanding iblock
most deeply is worth the time — it is the production backend for real storage and the one that
shows exactly how the SGL from the iSCSI fabric maps to block layer I/O.

---

## iblock backend — `drivers/target/target_core_iblock.c`

### struct iblock_dev

```c
struct iblock_dev {
    struct block_device     *ibd_bd;         /* the underlying block device */
    struct bio_set          ibd_bio_set;     /* pre-allocated bio pool */
    struct iblock_req       *ibd_bio_err_lock; /* for error tracking */
    struct request_queue    *ibd_request_queue;
};
```

`ibd_bd` is the `struct block_device` for `/dev/sda`, `/dev/nvme0n1`, etc. All block I/O goes
through this device — iblock is essentially a thin pass-through from LIO's SGL to the block layer.

---

### iblock_execute_rw — `drivers/target/target_core_iblock.c`

The main execute function for READ and WRITE commands:

```c
static sense_reason_t iblock_execute_rw(struct se_cmd *cmd, struct scatterlist *sgl,
                                         u32 sgl_nents, enum dma_data_direction data_direction)
{
    struct se_device *dev     = cmd->se_dev;
    struct iblock_dev *ib_dev = IBLOCK_DEV(dev);
    struct iblock_req *ibr;
    struct bio *bio;
    struct bio_list list;
    struct scatterlist *sg;
    sector_t block_lba;
    u32 sg_num = sgl_nents;
    unsigned bio_cnt;
    int i;

    /*
     * Translate the SCSI LBA from the CDB to a block layer sector number.
     * LBA is in cmd->t_task_lba (set by parse_cdb from CDB bytes).
     * Block layer uses 512-byte sectors.
     * Device logical block size may differ (4096 bytes):
     *   sector = lba * (dev_attrib.block_size / 512)
     */
    block_lba = target_to_linux_sector(dev, cmd->t_task_lba);

    ibr = kzalloc(sizeof(struct iblock_req), GFP_KERNEL);
    if (!ibr)
        goto fail;

    cmd->priv = ibr;

    /* atomic reference count — one per bio submitted */
    atomic_set(&ibr->pending, 1);
    ibr->cmd = cmd;

    bio_list_init(&list);

    /*
     * Convert the se_cmd SGL into one or more bios.
     * Each bio can hold up to BIO_MAX_VECS (256) pages.
     * A large SGL (e.g. 1MB / 4KB pages = 256 entries) may need
     * multiple bios chained together.
     */
    bio = iblock_get_bio(cmd, block_lba, sgl_nents, data_direction);
    if (!bio)
        goto fail_free_ibr;

    bio_list_add(&list, bio);
    bio_cnt = 1;

    for_each_sg(sgl, sg, sgl_nents, i) {
        /*
         * Try to add this SGL entry to the current bio.
         * bio_add_page() returns 0 if bio is full (BIO_MAX_VECS reached).
         */
        if (bio_add_page(bio, sg_page(sg), sg->length, sg->offset) != sg->length) {
            /*
             * Current bio is full. Allocate a new bio for the next sector.
             * Update block_lba: advance by bytes consumed so far.
             */
            block_lba += bio_sectors(bio);
            atomic_inc(&ibr->pending);  /* one more bio in flight */

            bio = iblock_get_bio(cmd, block_lba, sg_num, data_direction);
            if (!bio)
                goto fail_put_bios;

            bio_list_add(&list, bio);
            bio_cnt++;

            /* retry adding this sg to the new bio */
            if (bio_add_page(bio, sg_page(sg), sg->length, sg->offset) != sg->length)
                goto fail_put_bios;
        }
        sg_num--;
    }

    /*
     * Submit all bios in the list.
     * Each bio goes through the block layer (blk-mq) to the device.
     * The block device may be an NVMe SSD, a spinning disk, or even
     * another iSCSI target (chained targets).
     */
    while ((bio = bio_list_pop(&list))) {
        /* completion callback: iblock_bio_done */
        bio->bi_end_io  = iblock_bio_done;
        bio->bi_private = cmd;

        submit_bio(bio);  /* ← back into blk-mq on the target side */
    }

    return TCM_NO_SENSE;  /* 0: I/O submitted, not yet complete */

fail_put_bios:
    while ((bio = bio_list_pop(&list)))
        bio_put(bio);
fail_free_ibr:
    kfree(ibr);
fail:
    return TCM_LOGICAL_UNIT_COMMUNICATION_FAILURE;
}
```

`submit_bio()` on the target side goes into blk-mq just like any filesystem write — the target
IS a block device consumer. The I/O eventually reaches the device driver (NVMe, SATA, etc.) and
completes via `iblock_bio_done()`.

---

### iblock_bio_done — completion callback

```c
static void iblock_bio_done(struct bio *bio)
{
    struct se_cmd *cmd = bio->bi_private;
    struct iblock_req *ibr = cmd->priv;

    /*
     * Track I/O errors: if any bio in the chain failed, record it.
     * blk_status_to_sense() maps BLK_STS_IOERR → MEDIUM_ERROR sense.
     */
    if (bio->bi_status)
        atomic_inc(&ibr->bio_err_cnt);

    bio_put(bio);

    /*
     * Decrement the pending count. When it reaches 0, all bios for
     * this command have completed. Call target_complete_cmd().
     *
     * If ibr->bio_err_cnt > 0: complete with CHECK_CONDITION (medium error).
     * Otherwise: complete with SAM_STAT_GOOD.
     */
    if (atomic_dec_and_test(&ibr->pending)) {
        if (atomic_read(&ibr->bio_err_cnt)) {
            target_complete_cmd(cmd, SAM_STAT_CHECK_CONDITION);
            /*
             * sense data will be built by transport_generic_request_failure
             * from the error type.
             */
        } else {
            target_complete_cmd(cmd, SAM_STAT_GOOD);
        }
        kfree(ibr);
    }
}
```

`atomic_dec_and_test(&ibr->pending)` implements a simple barrier: the last bio to complete
triggers `target_complete_cmd()`. For a 1MB write split across 4 bios, `ibr->pending` starts
at 4 (+ 1 initial = 5 minus the initial dec-and-test = 4 real bios). Each bio completion
decrements; the last one fires `target_complete_cmd()`.

---

### iblock_get_bio — allocating bios from the pool

```c
static struct bio *iblock_get_bio(struct se_cmd *cmd, sector_t lba,
                                   u32 sg_num, enum dma_data_direction data_dir)
{
    struct iblock_dev *ib_dev = IBLOCK_DEV(cmd->se_dev);
    struct bio *bio;

    /*
     * Allocate from the pre-created bio_set (ib_dev->ibd_bio_set).
     * bio_set ensures allocation never fails even under memory pressure
     * by maintaining a reserved pool of bios.
     *
     * GFP_NOIO: don't trigger page reclaim that might need I/O —
     * would cause a deadlock in the I/O path.
     */
    bio = bio_alloc_bioset(ib_dev->ibd_bd,
                           min_t(u32, sg_num, BIO_MAX_VECS),
                           (data_dir == DMA_TO_DEVICE) ?
                               REQ_OP_WRITE : REQ_OP_READ,
                           GFP_NOIO,
                           &ib_dev->ibd_bio_set);
    if (!bio) {
        pr_err("Unable to allocate memory for bio\n");
        return NULL;
    }

    bio->bi_iter.bi_sector = lba;  /* starting sector for this bio */
    return bio;
}
```

---

## fileio backend — `drivers/target/target_core_file.c`

### struct fd_dev

```c
struct fd_dev {
    struct file     *fd_file;        /* the backing file (open with O_LARGEFILE|O_NOATIME) */
    u64             fd_dev_size;     /* file size in bytes */
    u32             fd_block_size;   /* logical block size (512 or 4096) */
};
```

### fd_execute_rw — `drivers/target/target_core_file.c`

```c
static sense_reason_t fd_execute_rw(struct se_cmd *cmd, struct scatterlist *sgl,
                                     u32 sgl_nents, enum dma_data_direction data_direction)
{
    struct se_device *dev = cmd->se_dev;
    struct fd_dev *fd_dev = FD_DEV(dev);
    struct file *fd = fd_dev->fd_file;
    struct scatterlist *sg;
    struct iov_iter iter;
    struct kvec *iov;
    loff_t pos;
    size_t len = 0;
    int i, ret;

    /*
     * Convert SGL to kvec array for kernel_write/kernel_read.
     * Each SGL entry → one kvec entry.
     */
    iov = kcalloc(sgl_nents, sizeof(struct kvec), GFP_KERNEL);
    if (!iov)
        return TCM_LOGICAL_UNIT_COMMUNICATION_FAILURE;

    for_each_sg(sgl, sg, sgl_nents, i) {
        iov[i].iov_base = sg_virt(sg);  /* virtual address of page */
        iov[i].iov_len  = sg->length;
        len += sg->length;
    }

    /* file position = LBA × block_size */
    pos = (loff_t)cmd->t_task_lba * fd_dev->fd_block_size;

    if (data_direction == DMA_TO_DEVICE) {
        /*
         * Write to file using kernel_write().
         * The file may be on ext4, xfs, tmpfs, etc.
         * This eventually goes through the page cache (unless O_DIRECT).
         */
        iov_iter_kvec(&iter, WRITE, iov, sgl_nents, len);
        ret = vfs_iter_write(fd, &iter, &pos, 0);
    } else {
        /* Read from file */
        iov_iter_kvec(&iter, READ, iov, sgl_nents, len);
        ret = vfs_iter_read(fd, &iter, &pos, 0);
    }

    kfree(iov);

    if (ret < 0 || ret != len) {
        pr_err("fd_execute_rw(): vfs_%s returned %d\n",
               (data_direction == DMA_TO_DEVICE) ? "write" : "read", ret);
        target_complete_cmd(cmd, SAM_STAT_CHECK_CONDITION);
        return 0;
    }

    target_complete_cmd(cmd, SAM_STAT_GOOD);
    return 0;
}
```

fileio calls `vfs_iter_write()` / `vfs_iter_read()` — synchronous VFS calls. The `target_submission_wq`
worker blocks until the file I/O completes. This is why fileio has higher latency than iblock
for real storage — iblock uses async bio submission and the worker returns immediately.

---

## pSCSI backend — `drivers/target/target_core_pscsi.c`

pSCSI passes commands through to a real SCSI device on the target machine — useful for tape
drives, optical, or chained SCSI targets.

```c
static sense_reason_t pscsi_execute_cmd(struct se_cmd *cmd)
{
    struct scatterlist *sgl = cmd->t_data_sg;
    u32 sgl_nents          = cmd->t_data_nents;
    struct pscsi_dev_virt *pdv = PSCSI_DEV(cmd->se_dev);
    struct scsi_device *sd     = pdv->pdv_sd;  /* underlying scsi_device */
    sense_reason_t rc;

    /*
     * Use scsi_execute_cmd() — the SCSI mid-layer synchronous slow path
     * (the same one initiators use for PR commands, day 13).
     *
     * This sends the CDB from the remote initiator directly to the
     * local SCSI device. Essentially: iSCSI → target → local SCSI bus.
     *
     * timeout: cmd->timeout_per_command or PSCSI_DEFAULT_TIMEOUT.
     * retries: 0 (target core handles retries).
     */
    rc = scsi_execute_cmd(sd,
                          cmd->t_task_cdb,
                          (cmd->data_direction == DMA_TO_DEVICE) ?
                              REQ_OP_DRV_OUT : REQ_OP_DRV_IN,
                          sgl ? sg_virt(sgl) : NULL,
                          cmd->data_length,
                          PSCSI_DEFAULT_TIMEOUT,
                          0,
                          NULL);

    if (rc) {
        /* error: copy sense from local scsi_cmnd to se_cmd->sense_buffer */
        memcpy(cmd->sense_buffer, sd->last_sense, SCSI_SENSE_BUFFERSIZE);
        target_complete_cmd(cmd, SAM_STAT_CHECK_CONDITION);
    } else {
        target_complete_cmd(cmd, SAM_STAT_GOOD);
    }

    return 0;
}
```

Notice that pSCSI calls `scsi_execute_cmd()` — the same function called by `sd_pr_reserve()` on
the initiator side. This means pSCSI execution blocks the `target_submission_wq` worker thread
for the entire I/O duration. This is acceptable for low-throughput devices (tape, optical) but
unsuitable for high-speed storage.

---

## Backend comparison

| Aspect | iblock | fileio | pscsi |
|---|---|---|---|
| Storage object | block device (`/dev/sdX`, `/dev/nvmeX`) | regular file | SCSI device |
| I/O model | async bio → blk-mq | sync vfs_iter_write/read | sync scsi_execute_cmd |
| Worker blocks? | No (returns immediately) | Yes (blocks on VFS) | Yes (blocks on SCSI) |
| Performance | Highest | Medium | Lowest |
| Use case | Production storage | Dev/testing, ramdisk-backed | Tape, optical, chained SCSI |
| UNMAP/DISCARD | Yes (blkdev_issue_discard) | Yes (fallocate PUNCH_HOLE) | Pass-through |
| Write-back cache | Controlled by device | Controlled by page cache | Pass-through |

---

## The SGL → bio conversion in detail

For a 1MB WRITE command with 256 4KB pages:

```
se_cmd->t_data_sg: [page_0, 4096, 0] [page_1, 4096, 0] ... [page_255, 4096, 0]
se_cmd->t_data_nents: 256

iblock_execute_rw():
    bio_0: pages 0..255 (256 × 4096 = 1MB if BIO_MAX_VECS >= 256)
    submit_bio(bio_0)

iblock_bio_done(bio_0):
    ibr->pending: 1 → 0
    atomic_dec_and_test: true
    target_complete_cmd(cmd, SAM_STAT_GOOD)

target_complete_cmd():
    queue_work(target_completion_wq, &cmd->work)

target_complete_ok_work():
    cmd->se_tfo->queue_status(cmd)  [write — no Data-In PDUs needed]
    = iscsit_queue_status()
    TX thread sends SCSI Response PDU: status=0x00 (GOOD)
```

For large I/O that exceeds BIO_MAX_VECS pages, multiple bios are chained with `ibr->pending`
tracking them all. The last bio's `iblock_bio_done()` triggers `target_complete_cmd()`.

---

## Key takeaways

- iblock converts the `se_cmd` SGL into one or more bios and calls `submit_bio()` — async.
  `iblock_bio_done()` is called by the block layer when done. `ibr->pending` tracks all in-flight
  bios; the last completion calls `target_complete_cmd(SAM_STAT_GOOD)`.
- fileio calls `vfs_iter_write()` / `vfs_iter_read()` synchronously in the `target_submission_wq`
  worker. Simpler but blocks the worker thread for the I/O duration.
- pSCSI calls `scsi_execute_cmd()` — the same slow path used for PR on the initiator. Blocks
  the worker thread. Only for low-throughput pass-through devices.
- All three call `target_complete_cmd()` when done — this is the only required interface.
- `GFP_NOIO` for bio allocation prevents deadlocks: allocating memory during I/O must not
  trigger page reclaim that itself needs I/O.
- iblock's `bio_set` (`ibd_bio_set`) pre-allocates bios, ensuring allocation never fails even
  under memory pressure — required for a target that must make forward progress.

---

## Week 3 complete

Days 15–21 now cover the complete target core stack: structs (15) → submit path (16) →
completion path (17) → iSCSI RX thread (18) → TX thread and state machine (19) → PR (20) →
backends (21). You can now trace any command from TCP socket receipt through target_core to
backend I/O and back to the response PDU.

Ready to continue with **Week 4: TMF, ALUA, configfs, session teardown, NVMe-oF, and sense data**.

---

## Previous / Next

[Day 20 — LIO Persistent Reservations](day20.md) | [Day 22 — Task Management Functions](day22.md)
