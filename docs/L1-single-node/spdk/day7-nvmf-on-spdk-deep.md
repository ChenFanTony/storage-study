# Day 7: NVMf on SPDK — Deep Request Flow

## What this day covers

A detailed walk through the actual function call chains in `lib/nvmf/ctrlr.c` and
`lib/nvmf/subsystem.c` for two request types:

- a normal read/write I/O command
- a PR RESERVE command

This note uses specific function names from the SPDK source. Verify each one in your
tree as you read — names are stable across recent releases but minor variants exist.

Source files:

- `lib/nvmf/ctrlr.c`
- `lib/nvmf/subsystem.c`
- `lib/nvmf/nvmf_bdev.c`
- `lib/nvmf/tcp.c`

---

## Entry point: how a request arrives

For TCP transport, the poll group thread runs:

```
nvmf_tcp_poll_group_poll()                     // registered as a poller, period=0
  -> nvmf_tcp_qpair_process_pending()
     -> nvmf_tcp_recv_buf_process()
        -> spdk_nvmf_request_exec(req)          // hands off to ctrlr.c
```

For RDMA transport the entry differs but terminates at the same
`spdk_nvmf_request_exec`. Everything below this point is transport-agnostic.

---

## spdk_nvmf_request_exec — the dispatch gate

```c
// lib/nvmf/ctrlr.c
void spdk_nvmf_request_exec(struct spdk_nvmf_request *req)
```

This is the central dispatch function. It runs on the QP thread.

What it does:

1. checks controller state (is the controller still active?)
2. routes by command type:

```c
switch (req->cmd->nvme_cmd.opc) {
    case SPDK_NVME_OPC_FABRIC:
        nvmf_ctrlr_process_fabrics_cmd(req);
        break;
    default:
        if (sq->qid == 0) {
            nvmf_ctrlr_process_admin_cmd(req);
        } else {
            nvmf_ctrlr_process_io_cmd(req);
        }
}
```

I/O commands (read, write, compare, dataset management) go to `nvmf_ctrlr_process_io_cmd`.
Admin commands (identify, get/set features, reservation commands on admin queue) go to
`nvmf_ctrlr_process_admin_cmd`.

---

## nvmf_ctrlr_process_io_cmd — I/O command path

```c
// lib/nvmf/ctrlr.c
static int nvmf_ctrlr_process_io_cmd(struct spdk_nvmf_request *req)
```

Call chain:

```
nvmf_ctrlr_process_io_cmd(req)
  -> nsid = cmd->nsid
  -> ns = _nvmf_subsystem_get_ns(ctrlr->subsystem, nsid)
  -> if ns == NULL: complete with INVALID_NAMESPACE

  -> nvmf_ns_reservation_request_check(ns, ctrlr, req)
     // checks if this host holds or conflicts with the active reservation
     // if conflict: complete with RESERVATION_CONFLICT, return
     // if no reservation or host is registrant with access: continue

  -> switch (cmd->opc):
       SPDK_NVME_OPC_READ:
         nvmf_bdev_ctrlr_read_cmd(ns->bdev, ns->desc, ch, req)
       SPDK_NVME_OPC_WRITE:
         nvmf_bdev_ctrlr_write_cmd(ns->bdev, ns->desc, ch, req)
       SPDK_NVME_OPC_DATASET_MANAGEMENT:
         nvmf_bdev_ctrlr_dsm_cmd(ns->bdev, ns->desc, ch, req)
       ...
```

The `ch` here is the per-QP io_channel for this namespace's bdev. It was opened when
the QP joined the poll group and the namespace was configured.

---

## nvmf_ns_reservation_request_check — PR conflict logic

```c
// lib/nvmf/subsystem.c
static int nvmf_ns_reservation_request_check(
    struct spdk_nvmf_ns *ns,
    struct spdk_nvmf_ctrlr *ctrlr,
    struct spdk_nvmf_request *req)
```

This runs on the QP thread, reading (not modifying) the PR state in `spdk_nvmf_ns`.

Logic summary:

```
if no reservation held (ns->holder == NULL):
    return 0  // no conflict, proceed

if this ctrlr's hostid is the holder:
    return 0  // holder always has access

switch (ns->rtype):
    WRITE_EXCLUSIVE:
        reads allowed for all registrants
        writes blocked for non-holders
    EXCLUSIVE_ACCESS:
        all I/O blocked for non-holders
    WRITE_EXCLUSIVE_REG_ONLY:
        reads allowed for all registrants
        writes blocked for non-registrants
    ...
```

If conflict detected: calls `spdk_nvmf_request_complete` with
`SPDK_NVME_SC_RESERVATION_CONFLICT` and returns non-zero. The caller returns without
submitting bdev I/O.

---

## nvmf_bdev_ctrlr_read_cmd — bdev submission

```c
// lib/nvmf/nvmf_bdev.c
int nvmf_bdev_ctrlr_read_cmd(
    struct spdk_bdev *bdev,
    struct spdk_bdev_desc *desc,
    struct spdk_io_channel *ch,
    struct spdk_nvmf_request *req)
```

What it does:

```
extract LBA, num_blocks from NVMe command
build iovec from req->iov[]
call spdk_bdev_readv_blocks(desc, ch, iov, iovcnt, lba, num_blocks,
                             nvmf_bdev_ctrlr_complete_cmd, req)
return SPDK_NVMF_REQUEST_EXEC_STATUS_ASYNCHRONOUS
```

The return value tells `ctrlr.c` not to complete the request yet — it is in flight.

---

## nvmf_bdev_ctrlr_complete_cmd — completion callback

```c
// lib/nvmf/nvmf_bdev.c
static void nvmf_bdev_ctrlr_complete_cmd(
    struct spdk_bdev_io *bdev_io,
    bool success,
    void *cb_arg)
```

Called by the bdev layer on the same QP thread when I/O completes.

```
req = cb_arg
if success:
    req->rsp->nvme_cpl.status.sc = SPDK_NVME_SC_SUCCESS
else:
    req->rsp->nvme_cpl.status.sc = SPDK_NVME_SC_INTERNAL_DEVICE_ERROR
spdk_bdev_free_io(bdev_io)
spdk_nvmf_request_complete(req)
```

`spdk_nvmf_request_complete` hands the completed request back to the transport layer,
which sends the CQE to the host.

---

## Full read command timeline (same thread throughout)

```
[QP thread]

nvmf_tcp_poll_group_poll
  nvmf_tcp_qpair_process_pending
    spdk_nvmf_request_exec(req)
      nvmf_ctrlr_process_io_cmd(req)
        nvmf_ns_reservation_request_check(ns, ctrlr, req)  // no conflict
        nvmf_bdev_ctrlr_read_cmd(bdev, desc, ch, req)
          spdk_bdev_readv_blocks(...)
            [bdev layer queues to AIO/NVMe/etc]
            return (async)
          return ASYNC
        return ASYNC
      return ASYNC
    return
  return
return  ← reactor continues polling

... later, same reactor iteration or next ...

[AIO/NVMe completion fires via poller]
  bdev layer calls nvmf_bdev_ctrlr_complete_cmd(bdev_io, true, req)
    spdk_bdev_free_io(bdev_io)
    spdk_nvmf_request_complete(req)
      nvmf_tcp_req_complete(req)
        [TCP sends CQE to host]
```

Zero thread switches. Zero locks. One CPU core handled the entire request.

---

## PR RESERVE command path

PR commands arrive on the admin queue as NVMe reservation commands (opcode 0x0D and
related). They go through `nvmf_ctrlr_process_admin_cmd` → reservation handler.

```
nvmf_ctrlr_process_admin_cmd(req)
  -> nvmf_ctrlr_reservation_report() / nvmf_ctrlr_reservation_register()
     / nvmf_ctrlr_reservation_acquire() / nvmf_ctrlr_reservation_release()
```

Each of these follows the same pattern:

```c
// lib/nvmf/ctrlr.c
static int nvmf_ctrlr_reservation_acquire(struct spdk_nvmf_request *req)
{
    // validate command fields
    // build a reservation update context
    nvmf_ns_reservation_request(req);   // dispatches to subsystem thread
    return SPDK_NVMF_REQUEST_EXEC_STATUS_ASYNCHRONOUS;
}
```

### nvmf_ns_reservation_request

```c
// lib/nvmf/subsystem.c
void nvmf_ns_reservation_request(void *ctx)
```

This function sends a message to the subsystem thread:

```c
spdk_thread_send_msg(ns->subsystem->thread,
                     nvmf_ns_reservation_update,
                     ctx);
```

The QP thread returns to polling immediately.

### nvmf_ns_reservation_update (runs on subsystem thread)

```c
// lib/nvmf/subsystem.c
static void nvmf_ns_reservation_update(void *ctx)
```

This is the serialized PR state machine. It runs exclusively on the subsystem thread.

```
switch (req_type):
    REGISTER:
        add or update registrant in ns->registrants[]
        update generation counter
    ACQUIRE:
        validate registrant exists
        if no holder: set ns->holder, ns->rtype, ns->crkey
        else if preempt: update holder
    RELEASE:
        validate holder
        clear ns->holder if releasing
        notify other registrants (ANA change or async event)
    REPORT: (read-only, but still serialized here for consistency)
        copy PR state into response buffer

if PTPL enabled:
    nvmf_ns_reservation_write_ptpl(ns)   // write PTPL file

// send completion message back to QP thread
spdk_thread_send_msg(qpair->thread,
                     nvmf_ns_reservation_update_done,
                     ctx);
```

### nvmf_ns_reservation_update_done (back on QP thread)

```c
static void nvmf_ns_reservation_update_done(void *ctx)
{
    spdk_nvmf_request_complete(req);  // send CQE to host
}
```

### PR command timeline

```
[QP thread]
  nvmf_ctrlr_reservation_acquire(req)
    nvmf_ns_reservation_request(req)
      spdk_thread_send_msg(subsystem->thread, nvmf_ns_reservation_update, ctx)
      return ASYNC
    return ASYNC

[Subsystem thread — next iteration]
  nvmf_ns_reservation_update(ctx)
    update ns->holder, ns->rtype, ns->crkey
    write PTPL if enabled
    spdk_thread_send_msg(qpair->thread, nvmf_ns_reservation_update_done, ctx)

[QP thread — next iteration]
  nvmf_ns_reservation_update_done(ctx)
    spdk_nvmf_request_complete(req)
      [TCP sends CQE to host]
```

Two thread hops. All PR state writes serialized on subsystem thread.
The QP thread never touches `ns->holder` directly — only reads it in the conflict check.

---

## nvmf_ctrlr_process_admin_cmd — identify and get/set features

For completeness, the other admin path:

```
nvmf_ctrlr_process_admin_cmd(req)
  switch (cmd->opc):
    SPDK_NVME_OPC_IDENTIFY:
      nvmf_ctrlr_identify(req)
        switch (cns):
          SPDK_NVME_IDENTIFY_CTRLR: fill identify controller data
          SPDK_NVME_IDENTIFY_NS:    fill identify namespace data from ns->bdev
          SPDK_NVME_IDENTIFY_ACTIVE_NS_LIST: walk subsystem->ns[]
    SPDK_NVME_OPC_GET_FEATURES / SET_FEATURES:
      nvmf_ctrlr_get_features(req) / nvmf_ctrlr_set_features(req)
    SPDK_NVME_OPC_ASYNC_EVENT_REQUEST:
      nvmf_ctrlr_async_event_request(req)  // held until event occurs
    SPDK_NVME_OPC_KEEP_ALIVE:
      nvmf_ctrlr_keep_alive(req)           // resets keep-alive timer
```

Identify namespace is interesting: it reads `ns->bdev->blocklen`, `ns->bdev->blockcnt`,
and the PR capability fields. These are read-only bdev properties set at bdev creation,
so no locking needed.

---

## subsystem.c: namespace add/remove

Understanding how namespaces are added is important for lab work.

```c
// lib/nvmf/subsystem.c
int spdk_nvmf_subsystem_add_ns_ext(
    struct spdk_nvmf_subsystem *subsystem,
    const char *bdev_name,
    const struct spdk_nvmf_ns_opts *opts,
    size_t opts_size,
    const char *ptpl_file)
```

What it does:

```
1. find bdev by name: spdk_bdev_get_by_name(bdev_name)
2. open bdev: spdk_bdev_open_ext(bdev_name, true, ...)  -> desc
3. claim bdev: spdk_bdev_module_claim_bdev(bdev, desc, &nvmf_bdev_module)
   -> FAILS if already claimed (already in another subsystem)
4. allocate spdk_nvmf_ns
5. set ns->bdev, ns->desc
6. if ptpl_file: load PTPL state from file -> ns->registrants[], ns->holder etc.
7. assign NSID
8. if !no_auto_visible: add to visible list for all hosts
9. insert into subsystem->ns[nsid-1]
```

Step 3 is the bdev exclusivity gate. Step 6 is the PTPL load-at-add-time behavior
you identified in your PR conclusion.

For namespace removal:

```c
int spdk_nvmf_subsystem_remove_ns(
    struct spdk_nvmf_subsystem *subsystem,
    uint32_t nsid)
```

```
1. get ns = subsystem->ns[nsid-1]
2. close all io_channels for this ns across all QPs (via message to each QP thread)
3. spdk_bdev_module_release_bdev(ns->bdev)  // release claim
4. spdk_bdev_close(ns->desc)
5. free ns
```

Step 2 requires cross-thread messages to each QP thread to close their channels.
This is why namespace removal is asynchronous and goes through the subsystem state machine.

---

## What matters most after Day 7

1. `spdk_nvmf_request_exec` is the single dispatch gate for all NVMe commands.
2. Normal I/O: QP thread → PR conflict check → bdev submit → completion cb → CQE. No thread switch.
3. PR commands: QP thread → message to subsystem thread → PR state update → message back → CQE. Two hops.
4. `nvmf_ns_reservation_request_check` reads PR state (no write). `nvmf_ns_reservation_update` writes PR state (subsystem thread only).
5. Namespace add calls `spdk_bdev_module_claim_bdev` — this is the exclusivity gate.
6. PTPL is loaded once at `spdk_nvmf_subsystem_add_ns_ext` time, not synced at runtime.
7. Namespace remove requires draining all QP channels via cross-thread messages before the bdev claim is released.
