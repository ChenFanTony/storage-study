# Day 2: SPDK Application Framework

## What this day covers

How an SPDK application starts, initializes its subsystems, and reaches RPC-ready state.

This is important because when you read NVMf target code, you will see calls like
`spdk_nvmf_tgt_create`, `spdk_nvmf_transport_create`, and subsystem state machines.
Those only make sense once you understand what calls them and in what order.

Source references:

- `lib/event/app.c`
- `lib/event/reactor.c`
- `include/spdk/event.h`
- `app/nvmf_tgt/nvmf_tgt.c`

---

## Entry point: spdk_app_start

Every SPDK application starts with `spdk_app_start`.

```c
int spdk_app_start(struct spdk_app_opts *opts, spdk_msg_fn start_fn, void *ctx);
```

What it does:

- parses options
- initializes the environment layer (DPDK hugepages, PCI, memory)
- sets up the reactor framework
- calls `spdk_subsystem_init` to initialize registered subsystems
- when subsystem init is complete, calls `start_fn` on the app thread
- blocks until `spdk_app_stop` is called

Your `start_fn` is where you create your transports, subsystems, and namespaces via RPC or
direct API.

---

## Subsystem initialization

SPDK has a concept of registered subsystems. These are components that need ordered
startup and shutdown.

Examples:

- `bdev` subsystem
- `nvmf` subsystem
- `iscsi` subsystem

Each subsystem registers with a dependency order. SPDK initializes them in order, and each
subsystem calls a completion callback when it is ready. Shutdown runs in reverse.

This is why you cannot call `bdev_malloc_create` before the bdev subsystem is initialized.
The framework enforces ordering.

Key struct:

```c
struct spdk_subsystem {
    const char *name;
    spdk_subsystem_init_fn init;
    spdk_subsystem_fini_fn fini;
    TAILQ_ENTRY(spdk_subsystem) tailq;
};
```

---

## RPC control plane

Once `start_fn` runs, the application is ready to accept JSON-RPC calls.

SPDK uses its own JSON-RPC server, typically listening on a UNIX socket at
`/var/tmp/spdk.sock` by default.

Key points:

- RPCs run on the app thread
- RPC handlers call into SPDK APIs directly
- `scripts/rpc.py` sends JSON-RPC calls over that socket

Contrast with Linux:

| Linux nvmet | SPDK |
|---|---|
| configfs: `mkdir`, `echo`, `ln` | JSON-RPC: method calls with JSON params |
| sysfs for status | JSON-RPC `get_*` methods |
| persistent on reboot if configured | state is in-memory; scripts recreate on restart |

---

## nvmf_tgt startup flow

For `nvmf_tgt` specifically, the flow looks like:

```
main()
  -> spdk_app_start(opts, nvmf_tgt_started, NULL)
     -> env init (hugepages, PCI, memory)
     -> reactor init
     -> subsystem init chain
        -> bdev subsystem init
        -> nvmf subsystem init
     -> nvmf_tgt_started() called on app thread
        -> spdk_nvmf_tgt_create()
        -> create transports via RPC or hardcoded config
        -> JSON-RPC server ready
```

At this point, `scripts/rpc.py` calls work.

---

## spdk_app_stop and shutdown

To shut down:

```c
void spdk_app_stop(int rc);
```

This triggers reverse-order subsystem finalization. Each subsystem gets a chance to drain
I/O and release resources before the next one shuts down.

Why this matters for NVMf:

- in-flight I/O must complete or be aborted
- controllers must be destroyed before the transport is torn down
- bdevs must be released before bdev subsystem fini

---

## Comparison with kernel module init

| Kernel | SPDK |
|---|---|
| `module_init` / `module_exit` | `spdk_app_start` / `spdk_app_stop` |
| kernel module dependencies via `MODULE_SOFTDEP` | subsystem registration with explicit deps |
| sysfs / configfs for runtime config | JSON-RPC |
| `printk` | `SPDK_INFOLOG` / `SPDK_DEBUGLOG` |
| process does not own memory mapping | app owns hugepage pool |

---

## What matters most after Day 2

1. `spdk_app_start` is the single entry point for all SPDK apps.
2. Subsystems initialize in dependency order; do not assume a service is ready before its
   subsystem init callback fires.
3. The app thread is where RPC handlers run. It is an SPDK thread, not just a plain
   POSIX thread.
4. `nvmf_tgt` is a thin wrapper: it calls `spdk_app_start` and then sets up the NVMf
   target in the start callback.
5. State is in-memory. Persistence requires re-running your setup script or using
   SPDK's JSON config save/load feature.

---

## Suggested next step

Day 3: the reactor, SPDK thread, and poller model. This is what the app thread actually
is, and how all work in SPDK gets scheduled.
