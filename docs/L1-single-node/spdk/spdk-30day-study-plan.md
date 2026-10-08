# SPDK 30-Day Study Plan

This plan is focused on a kernel-to-SPDK transition with emphasis on SPDK NVMe-oF target work.

## Goal

After 30 days, you should be able to:

- run `nvmf_tgt` confidently
- export Linux-backed devices through SPDK
- configure one-host and multi-host access
- understand SPDK PR behavior and namespace visibility
- debug `lib/nvmf/ctrlr.c`, `lib/nvmf/subsystem.c`, and bdev interactions
- make small code changes and validate them

## Week 1: Environment And Mental Model

### Day 1

- Build SPDK and run basic apps.
- Build the tree, run `spdk_tgt` and `nvmf_tgt`, inspect `scripts/rpc.py`, and list available RPCs.

### Day 2

- Learn the SPDK architecture from a kernel engineer's view.
- Compare:
  - kernel threads/workqueues vs SPDK threads/pollers
  - bio/block layer vs SPDK bdev
  - nvmet configfs vs SPDK RPC
  - kernel completion path vs SPDK callback/message passing

### Day 3

- Hugepages, device setup, and userspace model.
- Understand `scripts/setup.sh`, PCI binding, hugepage usage, and what changes when storage moves from kernel to userspace.

### Day 4

- Learn the bdev layer.
- Create:
  - `Malloc0`
  - one `Aio` bdev from a file or block device
  - one `uring` bdev if available

### Day 5

- Read `lib/bdev/bdev.c`.
- Focus on:
  - bdev open/close
  - descriptors
  - claims
  - I/O submission/completion

### Day 6

- Learn JSON-RPC workflow.
- Practice creating and removing:
  - bdevs
  - subsystems
  - listeners
  - hosts
  - namespaces

### Day 7

- Review and rebuild from scratch.
- Write a shell script that:
  - starts `nvmf_tgt`
  - creates a transport
  - creates one bdev
  - creates one subsystem
  - exports one namespace

## Week 2: NVMf Target Basics

### Day 8

- Read `doc/nvmf.md` and run a basic TCP target.
- Export one malloc bdev through one subsystem and connect from a Linux initiator.

### Day 9

- Replace malloc with a real backend.
- Use `bdev_aio_create /dev/xxx Aio0` and export that instead.

### Day 10

- Host ACLs.
- Practice:
  - `nvmf_subsystem_add_host`
  - `allow_any_host`
- Understand the default deny model.

### Day 11

- Read `lib/nvmf/ctrlr.c`.
- Focus on:
  - request dispatch
  - namespace lookup
  - reservation conflict checks
  - command routing to subsystem thread

### Day 12

- Read `lib/nvmf/subsystem.c`.
- Focus on:
  - add/remove namespace
  - host visibility
  - listener/host rules
  - namespace bookkeeping

### Day 13

- Trace one I/O request end to end.
- Pick one read command and map:
  - receive
  - request object
  - namespace lookup
  - bdev submission
  - completion

### Day 14

- Review week.
- Explain in your own words:
  - why SPDK uses message passing
  - where subsystem state lives
  - where namespace state lives
  - how NVMf commands reach bdev

## Week 3: Multi-Host, PR, And Namespace Visibility

### Day 15

- Export one namespace to two hosts.
- Build the exact setup:
  - one subsystem
  - one namespace
  - two allowed hosts
  - both hosts connect

### Day 16

- Verify shared-namespace behavior.
- From both hosts:
  - discover
  - connect
  - inspect NSIDs
  - confirm both see the same namespace

### Day 17

- Study PR implementation.
- Read:
  - `lib/nvmf/nvmf_internal.h`
  - `lib/nvmf/subsystem.c`
  - `lib/nvmf/ctrlr.c`
- Focus on:
  - registrants
  - holder
  - reservation key/type
  - conflict logic
  - PTPL

### Day 18

- Reproduce PR conclusions in your notes.
- Write down:
  - PR is namespace-scoped
  - PR state lives in `spdk_nvmf_ns`
  - same exact bdev cannot normally be added to two subsystems
  - shared PR works only when hosts share the same namespace

### Day 19

- Namespace visibility masking.
- Practice:
  - add namespaces with `--no-auto-visible`
  - use `nvmf_ns_add_host`
  - use `nvmf_ns_remove_host`

### Day 20

- Two hosts, different namespaces, same subsystem.
- Build:
  - host A sees only NSID 1
  - host B sees only NSID 2
- Verify from both initiators.

### Day 21

- Review week.
- Create a concise comparison note:
  - Linux `nvmet`
  - SPDK `nvmf_tgt`
- For:
  - host ACL model
  - namespace visibility
  - PR scope
  - operational workflow

## Week 4: Debugging And Contribution Readiness

### Day 22

- Transport-specific study.
- Read `lib/nvmf/tcp.c` unless your real deployment is RDMA.
- Understand queue pair handling and request receive flow.

### Day 23

- Logging and debugging.
- Practice:
  - enabling NVMf debug logs
  - attaching `gdb`
  - setting breakpoints in `nvmf_ns_reservation_update_state`
  - tracing request opcodes and NSIDs

### Day 24

- Tests.
- Read and run relevant tests:
  - `test/nvmf/target/ns_masking.sh`
  - PR-related unit tests if present
  - target-side namespace tests

### Day 25

- Read one unit test deeply.
- Pick `test/unit/lib/nvmf/subsystem.c` or `ctrlr.c`.
- Understand how SPDK developers encode behavior expectations.

### Day 26

- Make a small doc/code fix.
- Good starter tasks:
  - fix a doc mismatch
  - improve an error log
  - add a validation check
  - add a tiny test case

### Day 27

- Learn performance basics.
- Use:
  - `bdevperf`
  - Linux `nvme` initiator
- Measure simple latency and IOPS for one exported namespace.

### Day 28

- Failure-path study.
- Practice:
  - remove a namespace
  - disconnect a host
  - restart target
  - reapply config
  - observe behavior with PTPL if used

### Day 29

- Build a reusable lab guide.
- Write your own:
  - target setup script
  - one-host export recipe
  - two-host shared-namespace recipe
  - host-masked namespace recipe

### Day 30

- Final lab.
- From scratch, without notes:
  - start target
  - create transport
  - add AIO-backed device
  - export to one host
  - export shared namespace to two hosts
  - export two separate namespaces to two hosts
  - explain PR behavior clearly

## What To Read In Code

Read these first:

- `lib/nvmf/ctrlr.c`
- `lib/nvmf/subsystem.c`
- `lib/nvmf/nvmf_internal.h`
- `lib/bdev/bdev.c`
- `doc/nvmf.md`
- `test/nvmf/target/ns_masking.sh`

## Best Daily Routine

Use 2 to 4 hours/day:

- 45 min reading docs/code
- 60 to 90 min lab work
- 30 min notes
- 15 min recap: "what changed in my mental model today?"

## Milestones

### By Day 7

- create/export one SPDK namespace

### By Day 14

- explain request flow in `ctrlr.c` and `subsystem.c`

### By Day 21

- implement and verify per-host namespace visibility

### By Day 30

- debug and modify SPDK NVMf target code with confidence
