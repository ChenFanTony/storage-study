# Day 12: Deep Read — lib/nvmf/subsystem.c

## What this day covers

A guided read through `lib/nvmf/subsystem.c` focused on:

1. namespace add and the bdev claim
2. host visibility bookkeeping
3. listener and host rules
4. PR state update path

This is the complement to Day 11. `ctrlr.c` handles per-connection command processing.
`subsystem.c` owns subsystem-level state that is shared across all connections.

---

## How to approach this file

Like `ctrlr.c`, this file is large. Use the function list approach:

```bash
grep -n "^static\|^int\|^void\|^bool\|^struct spdk_nvmf" \
    $SPDK_DIR/lib/nvmf/subsystem.c | less
```

Focus areas for today are marked with section headers below.

---

## Area 1: Namespace add — bdev claim

### Entry point

```c
int spdk_nvmf_subsystem_add_ns_ext(
    struct spdk_nvmf_subsystem *subsystem,
    const char *bdev_name,
    const struct spdk_nvmf_ns_opts *opts,
    size_t opts_size,
    const char *ptpl_file)
```

This is what `nvmf_subsystem_add_ns` RPC calls.

What to look for in sequence:

1. `spdk_bdev_get_by_name(bdev_name)` — find the bdev by name
2. `spdk_bdev_open_ext(...)` — open a descriptor
3. `spdk_bdev_module_claim_bdev(bdev, desc, &nvmf_bdev_module)` — claim it
   - if this fails, the bdev is already claimed → return error
4. allocate and zero `struct spdk_nvmf_ns`
5. populate `ns->bdev`, `ns->desc`, `ns->nsid`
6. if `ptpl_file != NULL`: call the PTPL load function → loads registrants and holder
7. if `opts->no_auto_visible == false`: add to all-hosts visibility list
8. insert into `subsystem->ns[nsid - 1]`

Record: what exact error code is returned when `spdk_bdev_module_claim_bdev` fails?
This is the error you will see if you try to add the same bdev to two subsystems.

---

## Area 2: Namespace remove

```c
int spdk_nvmf_subsystem_remove_ns(
    struct spdk_nvmf_subsystem *subsystem,
    uint32_t nsid)
```

What to look for:

1. does it close io_channels immediately, or via messages to QP threads?
2. where is `spdk_bdev_module_release_bdev` called?
3. where is `spdk_bdev_close` called?
4. is the removal synchronous or asynchronous?

Note: namespace removal goes through the subsystem state machine
(`SPDK_NVMF_SUBSYSTEM_PAUSING` → `SPDK_NVMF_SUBSYSTEM_PAUSED` → remove → resume).
This is because active QP threads may be using the namespace's io_channel.

Record: what subsystem state is required before a namespace can be removed?

---

## Area 3: Host visibility

### Auto-visible (default)

When `no_auto_visible == false`:

Look for a function that adds the namespace to a per-subsystem "all hosts can see this"
list. Find what structure tracks this.

### Per-host visibility

```c
int spdk_nvmf_ns_add_host(
    struct spdk_nvmf_subsystem *subsystem,
    uint32_t nsid,
    const char *hostnqn,
    uint32_t flags)

int spdk_nvmf_ns_remove_host(
    struct spdk_nvmf_subsystem *subsystem,
    uint32_t nsid,
    const char *hostnqn)
```

What to look for:

1. what struct stores the per-namespace host visibility list?
2. is this list separate from the subsystem-level allowed_hosts list?
3. how does the visibility check in `ctrlr.c` query this list?

The function you found in Day 11 Area 3 (per-host visibility check) calls into
subsystem.c. Find the implementation of that function here.

---

## Area 4: Listener management

```c
int spdk_nvmf_subsystem_add_listener(
    struct spdk_nvmf_subsystem *subsystem,
    struct spdk_nvmf_transport_id *trid,
    spdk_nvmf_tgt_subsystem_listen_done_fn cb_fn,
    void *cb_arg)
```

What to look for:

1. what struct stores a listener?
2. where is the transport notified that a new listener is being added?
3. is this synchronous or does it send a message?

Listeners are simpler than namespaces. Record: what fields does a listener struct hold?

---

## Area 5: PR state update path

This is the most important part of this file for your PR work.

### nvmf_ns_reservation_update

```c
static void nvmf_ns_reservation_update(void *ctx)
```

This runs on the **subsystem thread** (sent via `spdk_thread_send_msg` from the QP thread).

What to look for:

1. what context struct is passed in? what fields does it contain?
2. how does it dispatch to the specific reservation operation (register/acquire/release/report)?
3. for `ACQUIRE`: where does it set `ns->holder`, `ns->rtype`, `ns->crkey`?
4. for `RELEASE`: where does it clear `ns->holder`?
5. for `PREEMPT`: where does it change the holder?
6. where is PTPL write triggered? what function writes the PTPL file?
7. where does it send the completion message back to the QP thread?

Fill in this call map:

```
nvmf_ns_reservation_update(ctx)         [subsystem thread]
  -> switch (ctx->op_type):
       REGISTER:   nvmf_ns_reservation_register(ns, ctx)
       ACQUIRE:    nvmf_ns_reservation_acquire(ns, ctx)
       RELEASE:    nvmf_ns_reservation_release(ns, ctx)
       REPORT:     nvmf_ns_reservation_report(ns, ctx)
  -> if PTPL: nvmf_ns_reservation_write_ptpl(ns)
  -> spdk_thread_send_msg(qpair_thread, nvmf_ns_reservation_update_done, ctx)
```

Verify the actual function names from the source and correct any discrepancies.

---

## Area 6: PTPL load and write

Find:

```c
static int nvmf_ns_reservation_load_ptpl(struct spdk_nvmf_ns *ns, const char *file)
```

or equivalent.

What to look for:

1. when is this called? (should be inside `spdk_nvmf_subsystem_add_ns_ext`)
2. what format is the PTPL file? (JSON?)
3. what fields are loaded into `spdk_nvmf_ns`?

Then find the PTPL write function:

1. when is it called? (after every reservation state change)
2. does it write synchronously on the subsystem thread?

Record: what happens to in-flight reservations if the target crashes between a state
change and the PTPL write completing? Is this a race?

---

## Area 7: Subsystem state machine

Find the subsystem state enum and the transition functions:

```c
enum spdk_nvmf_subsystem_state {
    SPDK_NVMF_SUBSYSTEM_INACTIVE,
    SPDK_NVMF_SUBSYSTEM_ACTIVATING,
    SPDK_NVMF_SUBSYSTEM_ACTIVE,
    SPDK_NVMF_SUBSYSTEM_PAUSING,
    SPDK_NVMF_SUBSYSTEM_PAUSED,
    SPDK_NVMF_SUBSYSTEM_DEACTIVATING,
};
```

What to look for:

1. what transitions does `spdk_nvmf_subsystem_start` trigger?
2. what transitions does `spdk_nvmf_subsystem_stop` trigger?
3. what transitions does `spdk_nvmf_subsystem_pause` trigger?
4. why does namespace removal require the PAUSING/PAUSED states?

---

## What to write in your notes

After reading, write down:

### Namespace add
- exact sequence of calls in `spdk_nvmf_subsystem_add_ns_ext`
- error returned when bdev already claimed
- when PTPL is loaded

### Namespace remove
- why it requires subsystem state transition
- sequence of channel close and bdev release

### Host visibility
- struct name for per-namespace host list
- function name for the visibility check
- difference between subsystem-level and namespace-level host lists

### PR update path
- context struct name passed to `nvmf_ns_reservation_update`
- which fields of `spdk_nvmf_ns` are written
- where completion is sent back to QP thread

### PTPL
- file format
- when written (every state change)
- when loaded (at namespace add, not at runtime)

---

## What matters most after Day 12

1. `spdk_nvmf_subsystem_add_ns_ext` is where the bdev claim happens — this is the exclusivity gate.
2. PTPL is loaded at namespace-add time, not synchronized at runtime. This confirms your PR conclusion.
3. PR state writes are all serialized on the subsystem thread via `nvmf_ns_reservation_update`.
4. Namespace removal requires subsystem pause to safely close QP io_channels.
5. Per-namespace host visibility is a separate list from subsystem-level allowed_hosts.

---

## Suggested next step

Day 13: trace one I/O request end to end using both your notes and a running target.
Combine the call chains from Day 11 and Day 12 into one unified flow diagram.
