# Day 11: Deep Read — lib/nvmf/ctrlr.c

## What this day covers

A guided read through `lib/nvmf/ctrlr.c` focused on four areas:

1. controller creation (host connect path)
2. request dispatch
3. namespace lookup
4. reservation conflict check

This is a code reading day. Have the file open in your editor alongside this note.

---

## How to read ctrlr.c

This file is large (~4000+ lines). Do not read it linearly.

Use this note as a map. Find each function, read it, then come back and add your own
annotations.

Useful shell command to find functions quickly:

```bash
grep -n "^static\|^int\|^void\|^bool\|^struct" \
    $SPDK_DIR/lib/nvmf/ctrlr.c | less
```

---

## Area 1: Controller creation — host connect path

### Entry point

```c
static int nvmf_ctrlr_cmd_connect(struct spdk_nvmf_request *req)
```

This is called when a host sends a `CONNECT` Fabric command. It runs on the QP thread.

What to look for:

1. where is the host NQN extracted from the connect command?
2. where is `spdk_nvmf_subsystem_host_allowed` called?
3. what happens if the host is not allowed?
4. where is the `spdk_nvmf_ctrlr` struct allocated?
5. where are io_channels opened for each namespace?

Key call sequence to trace:

```
nvmf_ctrlr_cmd_connect(req)
  -> validate connect command fields
  -> find subsystem by NQN
  -> spdk_nvmf_subsystem_host_allowed(subsystem, hostnqn)
     -> if false: complete with CONNECT_INVALID_PARAMETERS
  -> nvmf_ctrlr_create(subsystem, req)
     -> allocate spdk_nvmf_ctrlr
     -> assign cntlid
     -> open io_channels for each namespace
     -> add to subsystem->ctrlrs list
```

Record: what thread does `nvmf_ctrlr_create` run on?

---

## Area 2: Request dispatch

### Entry point

```c
void spdk_nvmf_request_exec(struct spdk_nvmf_request *req)
```

This is the single dispatch gate for all NVMe commands.

What to look for:

1. how does it distinguish Fabric commands from NVMe commands?
2. how does it distinguish admin queue (SQ 0) from I/O queues?
3. what does it do if the controller is in a bad state?

The core switch:

```c
if (spdk_unlikely(req->qpair->qid == 0)) {
    nvmf_ctrlr_process_admin_cmd(req);
} else {
    nvmf_ctrlr_process_io_cmd(req);
}
```

Record: what does `spdk_nvmf_request_exec` return? Why is the return value important?

---

## Area 3: Namespace lookup

### Inside nvmf_ctrlr_process_io_cmd

```c
static int nvmf_ctrlr_process_io_cmd(struct spdk_nvmf_request *req)
```

What to look for:

1. how is the NSID extracted from the command?
2. what function is called to look up the namespace?
3. what happens if the NSID does not exist?
4. what happens if the namespace is not visible to this host?

Key call:

```c
ns = _nvmf_subsystem_get_ns(ctrlr->subsystem, nsid);
if (ns == NULL || ns->bdev == NULL) {
    // complete with INVALID_NAMESPACE_OR_FORMAT
}
```

After finding `ns`, look for the host visibility check. For namespaces with
`no_auto_visible`, there is an additional check that the connecting host is in the
namespace's host visibility list.

Record: what is the exact function that checks per-namespace host visibility?

---

## Area 4: Reservation conflict check

### nvmf_ns_reservation_request_check

```c
static int nvmf_ns_reservation_request_check(
    struct spdk_nvmf_ns *ns,
    struct spdk_nvmf_ctrlr *ctrlr,
    struct spdk_nvmf_request *req)
```

What to look for:

1. what fields of `spdk_nvmf_ns` does it read?
2. how does it identify the current host? (hint: host UUID / hostid, not NQN)
3. what are the conditions for returning `RESERVATION_CONFLICT`?
4. for which reservation types is a non-holder still allowed to read?
5. what is the fast path when `ns->holder == NULL`?

Read the switch on `ns->rtype` carefully. Map each reservation type to its access rule:

| rtype | Non-registrant | Registrant (non-holder) | Holder |
|---|---|---|---|
| WRITE_EXCLUSIVE | read ?, write ? | read ?, write ? | all |
| EXCLUSIVE_ACCESS | read ?, write ? | read ?, write ? | all |
| WRITE_EXCLUSIVE_REG_ONLY | read ?, write ? | read ?, write ? | all |
| EXCLUSIVE_ACCESS_REG_ONLY | read ?, write ? | read ?, write ? | all |

Fill in the table from the code. This is your definitive PR access rule reference.

---

## Area 5: Admin command dispatch (lighter read)

```c
static int nvmf_ctrlr_process_admin_cmd(struct spdk_nvmf_request *req)
```

Find the switch on `cmd->opc`. Identify which opcodes are handled and what functions
they call. You do not need to read each handler in depth today.

Key ones to locate:

- `SPDK_NVME_OPC_IDENTIFY` → `nvmf_ctrlr_identify`
- `SPDK_NVME_OPC_GET_FEATURES` / `SET_FEATURES`
- `SPDK_NVME_OPC_ASYNC_EVENT_REQUEST`
- `SPDK_NVME_OPC_KEEP_ALIVE`
- reservation commands → which function handles them?

---

## Area 6: Controller disconnect / teardown

Find:

```c
static void nvmf_ctrlr_destroy(struct spdk_nvmf_ctrlr *ctrlr, ...)
```

or equivalent. What to look for:

1. where are io_channels closed?
2. where is the controller removed from the subsystem?
3. does disconnect send a message to the subsystem thread?

This is the reverse of the connect path. Understanding it helps with failure path
debugging in Week 4.

---

## What to write in your notes

After reading, write down for each area:

### Controller create
- function name for connect entry point
- where host NQN check happens
- thread this runs on

### Request dispatch
- function name for dispatch gate
- how admin vs I/O queue is distinguished
- return values and what they mean

### Namespace lookup
- function used for NSID → ns struct
- error returned for invalid NSID
- function for per-host visibility check

### PR conflict check
- fields of spdk_nvmf_ns read by conflict check
- completed access rule table (fill in from code)
- what is returned on conflict

---

## What matters most after Day 11

1. `spdk_nvmf_request_exec` is the single entry point for all commands.
2. Host NQN is checked at connect time in `nvmf_ctrlr_cmd_connect`.
3. NSID lookup is a simple array index: `subsystem->ns[nsid - 1]`.
4. PR conflict check reads `ns->holder` and `ns->rtype` without modifying them.
5. PR state writes happen on the subsystem thread, not here.

---

## Suggested next step

Day 12: deep read of `lib/nvmf/subsystem.c`. This is where namespace add/remove,
host visibility, and PR state updates actually live.
