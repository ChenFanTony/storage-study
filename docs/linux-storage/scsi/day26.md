# Day 26 — NVMe-oF target fabric comparison

**Week 4**: Advanced Topics  
**Time**: 1–2 hours  
**Reference**: `drivers/nvme/target/`, `drivers/nvme/host/`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

NVMe over Fabrics (NVMe-oF) is the modern alternative to iSCSI. It carries NVMe commands over
TCP, RDMA, or FC instead of SAS/PCIe. The kernel target lives at `drivers/nvme/target/` and is
much smaller than LIO (no SCSI mid layer, simpler command set, no fabric-agnostic backend
abstraction). For fencing it has a different philosophy: NVMe Reservations (NVMe spec §8.20)
mirror SCSI PR but with subtle differences. Understanding the comparison is useful when designing
storage that may run either fabric or both side-by-side.

---

## Architecture comparison

```
LIO (iSCSI target)                         NVMe-oF target (nvmet)
─────────────────                         ──────────────────────
                       fabric layer
iscsi_target.c                              nvmet_tcp.c / nvmet_rdma.c / nvmet_fc.c
target_core_fabric_ops table                nvmet_fabric_ops

                      target core
target_core_transport.c                     nvmet_core.c
se_cmd, se_session, se_lun                  nvmet_req, nvmet_ctrl, nvmet_ns

                    backend abstraction
target_backend_ops                          (none — direct to backend)
iblock, fileio, ramdisk, pscsi              file_ns, bdev_ns

                       command set
SCSI (SBC, SPC, SPC-3 PR, ALUA)             NVMe (NVM Command Set, Reservations, ANA)
```

Notable differences:

- **No fabric-agnostic core**: `nvmet` has direct paths from each fabric module to the backend.
  nvme-tcp talks to bdev_ns directly; there's no equivalent of LIO's
  fabric → core → backend split.
- **No SCSI mid layer involvement**: NVMe commands skip blk-mq's SCSI plumbing entirely. The
  initiator side (nvme-host) maps NVMe commands directly to blk-mq requests.
- **Simpler command structure**: every NVMe command is a 64-byte SQE (Submission Queue Entry).
  No CDB lengths, no AHS, no immediate-data quirks.

---

## struct nvmet_req — equivalent to se_cmd

```c
/* drivers/nvme/target/nvmet.h */
struct nvmet_req {
    struct nvme_command         *cmd;          /* the 64-byte SQE */
    struct nvme_completion      *cqe;          /* the 16-byte CQE */
    struct bio_vec              *sg;           /* data SGL */
    unsigned int                sg_cnt;
    size_t                      transfer_len;

    struct nvmet_port           *port;
    void                        (*execute)(struct nvmet_req *req);
    const struct nvmet_fabrics_ops *ops;

    struct nvmet_ns             *ns;           /* target namespace */
    struct nvmet_ctrl           *ctrl;         /* target controller */

    /*
     * Error handling — points to the byte/bit offset in the command
     * where the parser found a problem. Reported in CQE error_loc field.
     */
    u16                         error_loc;
};
```

`nvmet_req` is much smaller than LIO's `se_cmd` because there's less to track — no fabric-private
state pointer, no per-command kref (kref is on the controller / queue), no abort-completion
infrastructure (NVMe's abort is per-queue, not per-command).

---

## struct nvmet_ctrl — equivalent to se_session

```c
struct nvmet_ctrl {
    struct nvmet_subsys         *subsys;
    struct nvmet_sq             **sqs;        /* submission queues — array */

    /*
     * Controller identifier — assigned by target during connect.
     */
    u16                         cntlid;

    /*
     * Host identifier — sent by host during connect, identifies a
     * physical host (analogous to iSCSI initiator IQN).
     */
    uuid_t                      hostid;

    /*
     * Keep-alive — host sends Keep Alive command periodically.
     * If kato (Keep Alive Timeout) elapses without one, target tears
     * down the controller.
     */
    u32                         kato;
    struct delayed_work         ka_work;

    /*
     * I/O queues this controller has set up (via Create I/O Submission
     * Queue NVMe admin command).
     */
    u16                         max_qid;

    /*
     * Per-namespace state — for reservations and ANA.
     */
    struct list_head            reg_list;     /* reservation registrations */

    struct work_struct          fatal_err_work;
    struct work_struct          async_event_work;
};
```

`cntlid` (controller ID) is the per-controller identifier; `hostid` identifies the host. One
host may have multiple controllers (one per NVMe-oF connection), but the host ID is shared
across them — used for reservation registration.

---

## NVMe vs iSCSI command flow

```
iSCSI Command PDU (48 BHS + data segment)         NVMe Submission Queue Entry (64 bytes)
─────────────────────────────────────             ───────────────────────────────────────
  opcode (1 byte)                                   opc (1 byte)
  flags (RWFAttr)                                   flags (Fused, PSDT)
  TotalAHSLength + DataSegmentLength                cid (command ID, 16 bits)
  LUN (8 bytes)                                     nsid (namespace ID, 4 bytes)
  ITT                                               metadata pointer
  CmdSN, ExpStatSN                                  data pointer (PRP or SGL)
  Data length                                       command-specific dwords (cdw10..cdw15)
  CDB (16 bytes)                                    
  [optional AHS for >16-byte CDB]                   

  Response PDU: SCSI status + sense                 Completion Queue Entry (16 bytes):
                                                      command-specific dwords (2)
                                                      sq_head (flow control)
                                                      sq_id, cid (correlation)
                                                      status (16 bits — DNR + Phase + Status)
```

NVMe is denser. No separate CmdSN/ExpStatSN window — flow control is the SQ doorbell + CQE
sq_head field. No AHS — large commands use SGL chains directly. No status separate from
response — the CQE status is the only place errors live.

---

## The basic submit path

```c
/* Simplified — see drivers/nvme/target/core.c. */
bool nvmet_req_init(struct nvmet_req *req, struct nvmet_cq *cq,
                      struct nvmet_sq *sq, const struct nvmet_fabrics_ops *ops)
{
    u8 flags = req->cmd->common.flags;
    u16 status;

    req->cq = cq;
    req->sq = sq;
    req->ops = ops;
    req->sg = NULL;
    req->sg_cnt = 0;
    req->transfer_len = 0;
    req->cqe->status = 0;
    req->cqe->sq_head = 0;
    req->cqe->sq_id = cpu_to_le16(sq->qid);
    req->cqe->command_id = req->cmd->common.command_id;
    req->ns = NULL;
    req->error_loc = NVMET_NO_ERROR_LOC;

    /* Fused command not supported (rare anyway) */
    if (unlikely(flags & NVME_CMD_FUSE_MASK)) {
        req->error_loc = offsetof(struct nvme_common_command, flags);
        status = NVME_SC_INVALID_FIELD | NVME_SC_DNR;
        goto fail;
    }

    /*
     * Look up the namespace, set up backend.
     * For an admin command (sq->qid == 0): nvmet_parse_admin_cmd()
     * For an I/O command (sq->qid != 0): nvmet_parse_io_cmd()
     */
    if (unlikely(!percpu_ref_tryget_live(&sq->ref))) {
        status = NVME_SC_QP_NOT_READY | NVME_SC_DNR;
        goto fail;
    }

    if (sq->qid)
        status = nvmet_parse_io_cmd(req);
    else
        status = nvmet_parse_admin_cmd(req);

    if (status)
        goto fail;

    return true;

fail:
    nvmet_req_complete(req, status);
    return false;
}
```

The `percpu_ref` on the submission queue is the equivalent of LIO's `lun_ref` — when the queue
is being torn down, new commands get rejected.

---

## Block device backend — `nvmet_bdev_execute_rw`

```c
/* Simplified — see drivers/nvme/target/io-cmd-bdev.c. */
void nvmet_bdev_execute_rw(struct nvmet_req *req)
{
    unsigned int sg_cnt = req->sg_cnt;
    struct bio *bio;
    struct scatterlist *sg;
    blk_opf_t opf;
    int i, sector;

    if (!nvmet_check_transfer_len(req, ...))
        return;

    if (!req->sg_cnt) {
        nvmet_req_complete(req, 0);
        return;
    }

    if (req->cmd->rw.opcode == nvme_cmd_write) {
        opf = REQ_OP_WRITE | REQ_SYNC | REQ_IDLE;
        if (req->cmd->rw.control & NVME_RW_FUA)
            opf |= REQ_FUA;
    } else {
        opf = REQ_OP_READ;
    }

    sector = le64_to_cpu(req->cmd->rw.slba) <<
             (req->ns->blksize_shift - 9);

    /*
     * Build a chain of bios. Like iblock_execute_rw on LIO, but
     * without the indirection through target_backend_ops.
     */
    bio = bio_alloc(req->ns->bdev,
                     min(sg_cnt, BIO_MAX_VECS), opf, GFP_KERNEL);
    bio->bi_iter.bi_sector = sector;
    bio->bi_private = req;
    bio->bi_end_io = nvmet_bio_done;

    for_each_sg(req->sg, sg, req->sg_cnt, i) {
        while (bio_add_page(bio, sg_page(sg), sg->length, sg->offset)
                != sg->length) {
            struct bio *prev = bio;
            bio = bio_alloc(req->ns->bdev,
                              min(sg_cnt, BIO_MAX_VECS), opf, GFP_KERNEL);
            bio->bi_iter.bi_sector = bio_end_sector(prev);
            bio_chain(prev, bio);
            submit_bio(prev);
        }
        sg_cnt--;
    }

    submit_bio(bio);
}

static void nvmet_bio_done(struct bio *bio)
{
    struct nvmet_req *req = bio->bi_private;

    nvmet_req_complete(req,
                        blk_to_nvme_status(req, bio->bi_status));
    bio_put(bio);
}
```

`bio_chain()` is the simpler approach used here — earlier bios link to later bios, only the
final completion triggers `nvmet_req_complete()`. LIO's iblock uses an explicit pending counter
(`ibr->pending`); both achieve the same effect.

---

## NVMe Reservations — `drivers/nvme/target/pr.c`

NVMe Reservations were added to the kernel target in the 6.x series (specific version varies —
verify against your kernel). They mirror SCSI PR closely but with NVMe-style status codes:

```c
/* NVMe reservation types — analogous to PR_* but distinct values */
#define NVME_PR_WRITE_EXCLUSIVE              1
#define NVME_PR_EXCLUSIVE_ACCESS             2
#define NVME_PR_WRITE_EXCLUSIVE_REG_ONLY     3
#define NVME_PR_EXCLUSIVE_ACCESS_REG_ONLY    4
#define NVME_PR_WRITE_EXCLUSIVE_ALL_REGS     5
#define NVME_PR_EXCLUSIVE_ACCESS_ALL_REGS    6

/* Conflict status */
#define NVME_SC_RESERVATION_CONFLICT         0x83  /* (status type bits prepended) */
```

The host kernel's `nvme/host/pr.c` implements `pr_ops` analogous to `sd_pr_ops`. So
`/dev/nvme0n1` exposes the same PR ioctl interface as `/dev/sdX` — userspace tools (sg_persist
in compatibility mode, custom code via `IOC_PR_*`) work uniformly.

For NVMe over Fabrics specifically, when an NVMe Reservation Acquire returns conflict, the host
kernel's `nvme_complete_rq()` maps it to `BLK_STS_NEXUS` or `BLK_STS_RESV_CONFLICT` for the
block layer. The exact mapping depends on kernel version; always verify against
`drivers/nvme/host/core.c` for the kernel you target.

---

## ANA — Asymmetric Namespace Access

The NVMe equivalent of ALUA is ANA (NVMe spec §8.20). Same idea — per-namespace state
advertised to the host:

```
NVMe ANA states                         SCSI ALUA states
───────────────                         ─────────────────
ANA Optimized           = 0x01            ACTIVE_OPTIMIZED         = 0x0
ANA Non-Optimized       = 0x02            ACTIVE_NON_OPTIMIZED     = 0x1
ANA Inaccessible        = 0x03            STANDBY/UNAVAILABLE      = 0x2/0x3
ANA Persistent Loss     = 0x04            (no exact equivalent)
ANA Change              = 0x0F            TRANSITION               = 0xF
```

The mapping is approximate; ANA is a redesign with cleaner semantics. The host's
`nvme_mpath` (multipath) layer consumes ANA state directly — there's no equivalent of
`scsi_dh_alua` because ANA processing is built into nvme-host.

---

## Connection loss handling — kato vs replacement_timeout

NVMe-oF host's connection loss handling parameter is `--ctrl-loss-tmo` (controller loss
timeout, set when connecting). It is the analog of iSCSI's `replacement_timeout`. The default
is typically 600 seconds (10 minutes), much longer than iSCSI's 120s default.

Other related timeouts:
- `kato` (Keep Alive Timeout) — target's per-controller idle timeout. Default 120s.
- `--reconnect-delay` — host's delay between reconnect attempts. Default 10s.
- `--fast-io-fail-tmo` — how long the host queues I/O before failing it (similar in spirit to
  `no_path_retry=N` count in dm-multipath).

The NVMe host is more aggressive about retrying connections and slower to declare a host
permanently dead. This is a different tradeoff from iSCSI's defaults — better suited for
RDMA/datacenter where transient blips are common, less aggressive about visible failure for
unattended fencing scenarios.

---

## Why NVMe-oF target teardown is faster than iSCSI

```
NVMe-oF subsystem teardown                 iSCSI session teardown (day 25)
──────────────────────────                 ─────────────────────────────
nvmet_subsys_disconnect_ctrl()              iscsit_close_session()
    │                                          │
    ▼                                          ▼
percpu_ref_kill on all sqs                  iscsit_cause_connection_reinstatement
    │                                          │  socket forced error
    │  in-flight cmds drained via              │  kthread_stop on RX/TX
    │  percpu_ref drain                        ▼
    ▼                                       iscsit_release_commands_from_conn
nvme_transport->delete_ctrl()                  CMD_T_FABRIC_STOP per cmd
    │  close fabric connection                 ▼
    ▼                                       target_wait_for_sess_cmds
nvmet_ctrl_free                                kref drain
    │
    ▼
done
```

NVMe-oF target benefits from a simpler model:
- No `target_tmr_wq` ordering constraints (NVMe abort is per-queue, not per-cmd).
- No per-fabric callbacks like `queue_data_in`/`queue_status` to coordinate during teardown.
- `percpu_ref` on the SQ handles the "drain in-flight" step cleanly.

In practice, NVMe-oF target teardown completes in tens of milliseconds vs LIO's hundreds of
milliseconds to seconds.

---

## When to use NVMe-oF vs iSCSI

| Aspect | iSCSI | NVMe-oF |
|---|---|---|
| Latency | 100µs–1ms | 10µs–100µs |
| Throughput | bound by TCP | TCP, RDMA, or FC |
| CPU overhead | high (SCSI mid layer + iscsi_tcp) | lower |
| Tooling maturity | very mature | improving |
| Fencing options | PR, ALUA, ACL, session drop | Reservations, ANA, ACL, ctrl drop |
| Hardware needs | ethernet | RDMA (RoCE/iWARP) for best perf |
| Multi-path | dm-multipath | nvme_mpath built-in |

For new deployments, NVMe-oF over TCP (`nvme-tcp`) gives most of the latency benefit without
needing RDMA. Most modern storage appliances support both fabrics simultaneously.

---

## Key takeaways

- NVMe-oF target (`drivers/nvme/target/`) is structurally simpler than LIO: no fabric-agnostic
  core, no SCSI mid-layer involvement, direct fabric → backend paths.
- `nvmet_req` ≈ LIO's `se_cmd`. `nvmet_ctrl` ≈ `se_session`. `nvmet_ns` ≈ `se_lun`.
- NVMe Reservations mirror SCSI PR with similar semantics but distinct values
  (`NVME_PR_*`) and a different status code (`NVME_SC_RESERVATION_CONFLICT`, value depends on
  status-type bits). The host's `pr_ops` interface unifies both back to userspace.
- ANA (Asymmetric Namespace Access) is the NVMe equivalent of ALUA. The host's `nvme_mpath`
  consumes ANA state directly — no separate device handler.
- Connection loss handling: NVMe-oF host's `ctrl-loss-tmo` (default 600s) is the analog of
  iSCSI `replacement_timeout` (default 120s); NVMe is configured for longer retry tolerance.
- NVMe-oF target teardown is faster than LIO's because the model is simpler — `percpu_ref` on
  the SQ replaces LIO's multi-step kref drain.
- For new deployments needing fencing semantics: PR/Reservations work uniformly via `pr_ops`
  on either fabric.

---

## Previous / Next

[Day 25 — session teardown path](day25.md) | [Day 27 — iSCSI login sequence](day27.md)
