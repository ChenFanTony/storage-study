# Day 1 — bio and request structs

**Week 1**: Block Layer — blk-mq and SCSI Mid Layer  
**Time**: 1–2 hours  
**Reference**: `include/linux/blk_types.h`, `include/linux/blkdev.h`, `block/bio.c`

---

## Why start here

Every I/O in the Linux kernel — whether from a filesystem, device-mapper, or SCSI passthrough — is
described by two structs: `bio` and `request`. Before reading any blk-mq, SCSI, or iSCSI code, you
need to know these cold. Every function you read for the next 29 days will accept, modify, or
complete one of them.

---

## struct bio — `include/linux/blk_types.h`

```c
struct bio {
    struct bio              *bi_next;    /* request queue link (for bio chains) */
    struct block_device     *bi_bdev;    /* target block device */
    blk_opf_t               bi_opf;     /* operation + flags + priority */
    unsigned short          bi_flags;   /* BIO_* status flags */
    unsigned short          bi_ioprio;  /* I/O priority */
    blk_status_t            bi_status;  /* completion status (BLK_STS_*) */

    struct bvec_iter        bi_iter;    /* cursor into bi_io_vec[] */

    bio_end_io_t            *bi_end_io; /* completion callback */
    void                    *bi_private;/* caller's private pointer */

    unsigned short          bi_vcnt;    /* number of bio_vec entries */
    unsigned short          bi_max_vecs;/* max entries allocated */
    atomic_t                __bi_cnt;   /* reference count */

    struct bio_vec          *bi_io_vec; /* the scatter-gather list */
    struct bio_set          *bi_pool;   /* pool this was allocated from */
};
```

### bi_opf — operation and flags packed into one field

```c
/* low 8 bits = REQ_OP_* operation */
#define REQ_OP_READ         0   /* read from device */
#define REQ_OP_WRITE        1   /* write to device */
#define REQ_OP_FLUSH        2   /* flush write-back cache */
#define REQ_OP_DISCARD      3   /* discard sectors */
#define REQ_OP_DRV_IN      34   /* passthrough read (INQUIRY, TUR, PR IN) */
#define REQ_OP_DRV_OUT     35   /* passthrough write (PR OUT, MODE SELECT) */

/* upper bits = modifier flags */
#define REQ_SYNC        (1ULL << __REQ_SYNC)     /* hint: no readahead */
#define REQ_META        (1ULL << __REQ_META)     /* metadata I/O */
#define REQ_PRIO        (1ULL << __REQ_PRIO)     /* high priority */
#define REQ_NOMERGE     (1ULL << __REQ_NOMERGE)  /* do not merge */
#define REQ_IDLE        (1ULL << __REQ_IDLE)     /* anticipate more I/O */
#define REQ_FAILFAST_DEV       (1ULL << __REQ_FAILFAST_DEV)
#define REQ_FAILFAST_TRANSPORT (1ULL << __REQ_FAILFAST_TRANSPORT)
#define REQ_FAILFAST_DRIVER    (1ULL << __REQ_FAILFAST_DRIVER)
```

`REQ_OP_DRV_IN` / `REQ_OP_DRV_OUT` are the flags that mark a request as "passthrough" — used by
`blk_rq_is_passthrough()` throughout the stack. When these are set, the request:
- skips the I/O scheduler
- is injected at the HEAD of the dispatch queue via `blk_execute_rq(at_head=true)`
- bypasses dm-multipath's normal bio interception
- is never subject to `no_path_retry=queue`

This is the root reason why PR commands behave fundamentally differently from READ/WRITE.

### bi_iter — position cursor into bi_io_vec

```c
struct bvec_iter {
    sector_t    bi_sector;      /* device sector (512-byte units) currently at */
    unsigned    bi_size;        /* remaining bytes to transfer */
    unsigned    bi_idx;         /* current index into bi_io_vec[] */
    unsigned    bi_bvec_done;   /* bytes completed in current bvec */
};
```

`bi_iter` is a cursor. As a bio is processed (or split across requests), only `bi_iter` advances —
`bi_io_vec` itself is never modified. This means a single `bio_vec` array can be safely referenced
by multiple consumers as long as each has its own `bvec_iter` copy.

Advancing the cursor:
```c
/* move bi_iter forward by 'bytes' bytes */
static inline void bio_advance_iter(const struct bio *bio,
                                     struct bvec_iter *iter,
                                     unsigned bytes)
{
    iter->bi_sector += bytes >> 9;   /* convert bytes → sectors */
    iter->bi_size   -= bytes;

    if (bio_no_advance_iter(bio))
        return;

    bio_advance_iter_single(bio, iter, bytes);
}
```

### bi_io_vec — the scatter-gather list

```c
struct bio_vec {
    struct page *bv_page;    /* physical memory page */
    unsigned    bv_len;      /* length of this segment in bytes */
    unsigned    bv_offset;   /* byte offset within the page */
};
```

A 1 MB write with 4 KB pages → 256 `bio_vec` entries, each `{page, 4096, 0}`. The device DMA
engine walks this list directly. No data is ever copied between layers — every layer just passes
the `bio` pointer down.

Iterating over a bio's segments:
```c
/* kernel macro for iterating all segments */
struct bio_vec bvec;
struct bvec_iter iter;

bio_for_each_segment(bvec, bio, iter) {
    /* bvec.bv_page   = page to DMA */
    /* bvec.bv_offset = offset in page */
    /* bvec.bv_len    = bytes in this segment */
    void *data = page_address(bvec.bv_page) + bvec.bv_offset;
}
```

---

## struct request — `include/linux/blkdev.h`

`request` is what blk-mq creates from one or more merged `bio`s. While a `bio` is the unit from
the submitter's perspective, a `request` is the unit the block layer schedules and the driver sends.

```c
struct request {
    struct request_queue    *q;          /* the queue this request belongs to */
    struct blk_mq_ctx       *mq_ctx;    /* per-CPU software queue context */
    struct blk_mq_hw_ctx    *mq_hctx;  /* hardware queue context */

    blk_opf_t               cmd_flags;  /* REQ_OP_* + REQ_* flags (same as bio) */
    req_flags_t             rq_flags;   /* internal RQF_* flags */

    int                     tag;        /* hardware tag (driver-visible) */
    int                     internal_tag; /* blk-mq internal tag */

    unsigned int            timeout;    /* command timeout in jiffies */

    /* data position */
    sector_t                __sector;   /* current sector */
    unsigned int            __data_len; /* total bytes to transfer */
    int                     nr_phys_segments; /* SGL entry count */

    /* bio chain — one request can hold multiple merged bios */
    struct bio              *bio;       /* first bio */
    struct bio              *biotail;   /* last bio */

    /* for SCSI passthrough — CDB and result */
    unsigned char           *cmd;       /* points to scsi_cmnd->cmnd[] */
    int                     result;     /* SCSI result (host|msg|status bytes) */

    /* completion */
    rq_end_io_fn            *end_io;    /* completion callback */
    void                    *end_io_data;
};
```

### Key rq_flags

```c
#define RQF_STARTED        ((__force req_flags_t)(1 << 1))  /* driver has seen it */
#define RQF_QUEUED         ((__force req_flags_t)(1 << 2))  /* on dispatch queue */
#define RQF_FAILED         ((__force req_flags_t)(1 << 10)) /* completed with error */
#define RQF_QUIET          ((__force req_flags_t)(1 << 11)) /* suppress error messages */
#define RQF_PREEMPT        ((__force req_flags_t)(1 << 12)) /* head-of-queue insertion */
#define RQF_DONTPREP       ((__force req_flags_t)(1 << 7))  /* skip prep_rq_fn */
```

`RQF_PREEMPT` is set when `blk_execute_rq(at_head=true)` is called. This causes the request to be
inserted at the front of `hctx->dispatch`, ahead of all pending I/O.

---

## bio_alloc — `block/bio.c`

```c
struct bio *bio_alloc(struct block_device *bdev,
                      unsigned short nr_vecs,
                      blk_opf_t opf,
                      gfp_t gfp_mask)
{
    struct bio *bio;

    /* allocate from per-CPU bio_slab or bio_set pool */
    bio = bio_alloc_bioset(bdev, nr_vecs, opf, gfp_mask, &fs_bio_set);
    if (!bio)
        return NULL;

    return bio;
}
```

`bio_set` provides fast slab allocation with a pre-allocated pool to avoid allocation failures
during memory pressure — critical for a storage stack that must make forward progress.

## bio_add_page — `block/bio.c`

```c
int bio_add_page(struct bio *bio, struct page *page,
                 unsigned len, unsigned offset)
{
    bool same_page = false;

    /* try to merge with the last bio_vec if pages are adjacent */
    if (!__bio_try_merge_page(bio, page, len, offset, &same_page)) {
        if (bio_full(bio, len))
            return 0;  /* no space — caller must submit and allocate new bio */
        __bio_add_page(bio, page, len, offset);
    }
    return len;
}
```

The merge attempt (`__bio_try_merge_page`) coalesces physically contiguous pages into a single
`bio_vec`, reducing the SGL entry count. For sequential writes this can halve the descriptor count.

---

## How bio and request relate

```
Application write(fd, buf, 1MB)
      │
      ▼  VFS / page cache
      │  bio_alloc(bdev, 256, REQ_OP_WRITE, GFP_KERNEL)
      │  bio_add_page() × 256  (one per 4KB page)
      │  submit_bio(bio)
      ▼
blk-mq (day 2)
      │  bio → request (new or merged with pending)
      │  tag allocated from hctx->tags
      │  request placed on software queue
      ▼
LLD queuecommand(request)     e.g. iscsi_queuecommand()
      │  walks request's bio chain → bi_io_vec[]
      │  builds Data-Out PDUs from bio_vec pages
      ▼
TCP / network → target → disk
      ▼
Completion interrupt / PDU received
      │  bio->bi_end_io() called for each bio in chain
      ▼
VFS told write is done → write() syscall returns
```

The bio's `bi_io_vec` is never copied during this journey. Each layer just advances `bi_iter` or
passes the pointer down. The DMA engine and the iSCSI TX path both read the same physical pages.

---

## Key takeaways

- `bio` = submitter's view of I/O. Carries data address (`bi_io_vec`), operation (`bi_opf`), target
  device, and completion callback.
- `request` = block layer's scheduling unit. Wraps one or more merged bios. Has a hardware tag.
- `bi_iter` is a cursor — only it advances. `bi_io_vec` stays fixed, enabling zero-copy across all
  layers.
- `REQ_OP_DRV_IN` / `REQ_OP_DRV_OUT` mark passthrough requests (PR, INQUIRY, TUR). Every layer
  checks `blk_rq_is_passthrough()` to give these requests special treatment.
- `RQF_PREEMPT` on a request means head-of-queue insertion — used by the slow path (day 3).
- Data is NEVER copied between layers. All layers share the same physical pages via `bio_vec`.

---

## Next

[Day 2 — blk-mq core dispatch](day02.md)
