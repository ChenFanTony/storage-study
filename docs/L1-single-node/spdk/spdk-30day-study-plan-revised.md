# SPDK 30-Day Study Plan (Revised)

This is a revised plan based on actual progress as of 2026-04-23.

## What is already done

- Day 1 of 7-day architecture mini plan: big picture overview complete
- Day 2–5 notes generated: app framework, thread/reactor/poller, io_channel, bdev
- PR conclusion research: fully complete and ahead of schedule
  - PR is namespace-scoped in `spdk_nvmf_ns`
  - bdev claim exclusivity understood
  - PTPL load-at-ns-add behavior understood
  - Linux nvmet comparison complete
  - Per-namespace host visibility (`no_auto_visible`) understood conceptually

## Adjusted goal

After 30 days from now, you should be able to:

- run `nvmf_tgt` confidently
- export Linux-backed devices through SPDK
- configure one-host and multi-host access
- debug `lib/nvmf/ctrlr.c`, `lib/nvmf/subsystem.c`, and bdev interactions
- make small code changes and validate them
- verify in the lab everything already understood conceptually about PR and namespace visibility

---

## Week 1: Close The Framework Gap (Days 1–7)

You have the conceptual notes. This week is about building the real mental model through
code reading and hands-on work.

### Day 1

- Read `day2-app-framework.md`
- Start `spdk_tgt` and `nvmf_tgt`
- List available RPCs with `scripts/rpc.py rpc_get_methods`
- Deliverable: startup flow note from process launch to RPC-ready state

### Day 2

- Read `day3-thread-reactor-poller.md`
- Read `lib/thread/thread.c` with focus on:
  - `spdk_thread_create`
  - `spdk_thread_send_msg`
  - poller registration and execution
- Deliverable: annotate 10 key functions in your own words

### Day 3

- Read `day4-io-channel.md`
- Read `lib/thread/thread.c` io_channel section
- Find where NVMe bdev creates per-thread queue pairs via `create_cb`
- Deliverable: short note "what io_channel solves and where I found it in code"

### Day 4

- Read `day5-bdev-framework.md`
- Read `lib/bdev/bdev.c`:
  - `spdk_bdev_open_ext`
  - `spdk_bdev_module_claim_bdev`
  - `spdk_bdev_read`
  - `spdk_bdev_io` allocation from channel pool
- Deliverable: annotated reading notes on these four areas

### Day 5

- Hands-on bdev lab:
  - create `Malloc0`
  - create one `Aio` bdev from a file or block device
  - create one `uring` bdev if available
  - inspect with `bdev_get_bdevs`
  - delete and recreate
- Deliverable: working lab script

### Day 6

- Read `day6-core-code.md` (see 7-day plan Day 6 notes)
- Read `lib/nvmf/nvmf_internal.h` in full
- List the 10 most important structs and their ownership thread
- Deliverable: `day6-core-structs.md`

### Day 7

- Read `day7-nvmf-on-spdk.md` (see 7-day plan Day 7 notes)
- Light read of `lib/nvmf/ctrlr.c` and `lib/nvmf/subsystem.c`
- Goal: understand threading boundaries, not full feature mastery
- Deliverable: "How an NVMf request moves through SPDK" one-pager

---

## Week 2: NVMf Target Mechanics (Days 8–14)

### Day 8

- Run TCP target end to end
- Export one malloc bdev through one subsystem
- Connect from a Linux initiator
- Verify with `nvme list` and `nvme id-ns`

### Day 9

- Replace malloc with AIO-backed real device
- `bdev_aio_create /dev/xxx Aio0`
- Export and connect
- Confirm block size and count match the device

### Day 10

- Host ACLs practice:
  - `nvmf_subsystem_add_host`
  - `allow_any_host true/false`
  - test that a non-allowed host is rejected
- Deliverable: ACL behavior notes

### Day 11

- Deep read: `lib/nvmf/ctrlr.c`
- Focus on:
  - request dispatch entry point
  - namespace lookup
  - reservation conflict check location
  - command routing to subsystem thread
- Deliverable: annotated reading notes

### Day 12

- Deep read: `lib/nvmf/subsystem.c`
- Focus on:
  - `spdk_nvmf_subsystem_add_ns_ext` and the bdev claim call
  - host visibility bookkeeping
  - listener and host rules
  - PR state fields in `spdk_nvmf_ns`
- Deliverable: annotated reading notes

### Day 13

- Trace one read command end to end in code and in a running target
- Map: receive → request object → namespace lookup → bdev submit → completion
- Use log tracing or gdb if needed
- Deliverable: `day13-io-trace.md`

### Day 14

- Review week
- Write comparison: SPDK `ctrlr.c` dispatch vs Linux `nvmet` dispatch path
- Explain in your own words why message passing is used at the subsystem boundary

---

## Week 3: Multi-Host, PR Lab, Namespace Visibility (Days 15–21)

Note: Days 17–18 of the original plan (PR conceptual study) are already complete.
This week is lab verification of what you already understand.

### Day 15

- One subsystem, two hosts, one shared namespace
- Both hosts connect and verify they see the same NSID
- Confirm both are in the same PR domain

### Day 16

- PR lab: register from host A, reserve from host A
- Attempt register and reserve from host B
- Observe conflict behavior
- Deliverable: PR lab notes with command output

### Day 17

- PTPL lab:
  - enable PTPL on a reservation
  - stop the target
  - restart and reapply namespace config
  - verify reservation survives
- Deliverable: PTPL lab notes

### Day 18

- ~~PR conceptual study~~ ALREADY DONE
- Instead: write a clean summary of everything verified in Days 15–17
- Cross-reference against `spdk-pr-conclusion.md` and note any surprises
- Deliverable: updated or confirmed `spdk-pr-conclusion.md`

### Day 19

- Namespace visibility masking:
  - create namespace with `no_auto_visible=true`
  - use `nvmf_ns_add_host` / `nvmf_ns_remove_host`
  - verify host sees / does not see the namespace

### Day 20

- Two hosts, two namespaces, one subsystem:
  - host A sees only NSID 1
  - host B sees only NSID 2
- Verify from both initiators with `nvme id-ns` and `nvme list`

### Day 21

- Review week
- Write `nvmet-vs-spdk-pr-and-visibility.md`:
  - host ACL model comparison
  - namespace visibility comparison
  - PR scope comparison
  - operational workflow comparison
- This is the lab-verified version of your existing PR conclusion doc

---

## Week 4: Debugging, Performance, Contribution Readiness (Days 22–30)

### Day 22

- Read `lib/nvmf/tcp.c`
- Focus on:
  - queue pair handling
  - request receive flow
  - buffer lifecycle
- Deliverable: reading notes

### Day 23

- Logging and debugging:
  - enable NVMf debug logs
  - attach gdb to running target
  - set breakpoint in `nvmf_ns_reservation_update_state`
  - trace request opcodes and NSIDs
- Deliverable: debug lab notes

### Day 24

- Run tests:
  - `test/nvmf/target/ns_masking.sh`
  - PR-related unit tests if present
- Deliverable: test run notes

### Day 25

- Deep read one unit test:
  - `test/unit/lib/nvmf/subsystem.c` or `ctrlr.c`
- Understand how SPDK developers encode behavior expectations
- Deliverable: annotated test notes

### Day 26

- Make a small real fix:
  - doc mismatch
  - error log improvement
  - missing validation check
  - small test case addition
- Deliverable: draft patch or commit

### Day 27

- Performance baseline:
  - `bdevperf` on AIO-backed bdev
  - Linux nvme initiator read/write
  - measure IOPS and latency for one exported namespace
- Deliverable: perf numbers with config notes

### Day 28

- Failure path lab:
  - remove a namespace while host is connected
  - disconnect a host mid-session
  - restart target and reapply config
  - observe PTPL behavior
- Deliverable: failure lab notes

### Day 29

- Build reusable lab guide `spdk-lab-guide.md`:
  - target setup script
  - one-host export recipe
  - two-host shared-namespace recipe
  - host-masked namespace recipe

### Day 30

- Final lab from scratch, no notes:
  - start target
  - create transport
  - add AIO-backed device
  - export to one host
  - export shared namespace to two hosts
  - export two separate namespaces to two hosts
  - explain PR behavior clearly
  - verify PTPL survives restart

---

## What To Read In Code

Priority order:

1. `lib/nvmf/nvmf_internal.h` — structs and ownership
2. `lib/nvmf/ctrlr.c` — request dispatch and PR conflict check
3. `lib/nvmf/subsystem.c` — namespace/host management and PR state
4. `lib/bdev/bdev.c` — open, claim, submit, complete
5. `lib/thread/thread.c` — thread, poller, io_channel, message passing
6. `lib/nvmf/tcp.c` — transport layer
7. `doc/nvmf.md` — feature reference
8. `test/nvmf/target/ns_masking.sh` — end-to-end behavior tests

---

## Milestones

### By Day 7

- framework mental model solid: app init, reactor, poller, io_channel, bdev all understood
- bdev lab working

### By Day 14

- NVMf target running with real backing device
- can explain request flow through `ctrlr.c` and `subsystem.c`

### By Day 21

- all PR and namespace visibility scenarios verified in lab
- `nvmet-vs-spdk-pr-and-visibility.md` written from lab evidence

### By Day 30

- can debug and modify SPDK NVMf target code with confidence
- reusable lab guide ready for future reference
