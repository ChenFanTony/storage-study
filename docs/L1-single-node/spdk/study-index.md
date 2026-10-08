# SPDK Study Notes — Index

Complete index of the SPDK study notes migrated from the private SPDK source
tree into this knowledge base.

---

## Recommended entry points

- [Track current progress](spdk-learning-progress.md)
- [Follow the revised 30-day plan](spdk-30day-study-plan-revised.md)
- [Start Week 1: SPDK overview](day1-spdk-overview.md)
- [Start Week 2: basic TCP target](day8-basic-tcp-target.md)
- [Start Week 3: multi-host shared namespace](day15-multi-host-shared-ns.md)
- [Start Week 4: TCP transport deep read](day22-tcp-transport.md)
- [Review Persistent Reservations conclusions](spdk-pr-conclusion.md)
- [Compare Linux nvmet with SPDK](nvmet-vs-spdk-pr-and-visibility.md)

---

## Plan documents

| File | Contents |
|---|---|
| `spdk-7day-architecture-plan.md` | Original 7-day mini plan |
| `spdk-30day-study-plan.md` | Original 30-day plan |
| `spdk-30day-study-plan-revised.md` | Revised 30-day plan reflecting actual progress |
| `spdk-learning-progress.md` | Progress tracker — update as days complete |
| `spdk-pr-conclusion.md` | PR research conclusions (code analysis + lab verified) |
| `nvmet-vs-spdk-pr-and-visibility.md` | nvmet vs SPDK comparison (lab verified) |

---

## Week 1: Framework (Days 1–7)

Architecture and mental model. Read before touching NVMf code.

| File | Day | Focus |
|---|---|---|
| `day1-spdk-overview.md` | 1 | What SPDK is, polling model, message passing, bdev, stack |
| `day2-app-framework.md` | 2 | spdk_app_start, subsystem init order, RPC control plane |
| `day3-thread-reactor-poller.md` | 3 | spdk_thread, reactors, pollers, message passing, ownership |
| `day4-io-channel.md` | 4 | Per-thread device context, io_device register, bdev channels |
| `day5-bdev-framework.md` | 5 | Descriptors, claims, I/O submit/complete, bdev modules |
| `day6-core-code.md` | 6 | Reading guide: lib/thread, lib/bdev, nvmf_internal.h |
| `day7-nvmf-on-spdk.md` | 7 | How NVMf uses threads, bdev, and pollers (overview) |
| `day7-nvmf-on-spdk-deep.md` | 7+ | Detailed function-level call chains for read and PR RESERVE |

**After Week 1 you can:** explain the reactor model, bdev abstraction, and how
NVMf sits on top of both.

---

## Week 2: NVMf Target Mechanics (Days 8–14)

Running a real target. Reading the core code.

| File | Day | Focus |
|---|---|---|
| `day8-basic-tcp-target.md` | 8 | TCP target setup, malloc bdev, initiator connect |
| `day9-aio-bdev.md` | 9 | AIO bdev from block device or file, swap from malloc |
| `day10-host-acls.md` | 10 | Default deny, allow_any_host, per-host allow list |
| `day11-ctrlr-deep-read.md` | 11 | ctrlr.c: connect, dispatch, namespace lookup, PR conflict check |
| `day12-subsystem-deep-read.md` | 12 | subsystem.c: ns add/remove, host visibility, PR update path |
| `day13-io-trace.md` | 13 | End-to-end I/O trace: code, logs, and gdb methods |
| `day14-week2-review.md` | 14 | Checklist + writing exercises: dispatch comparison, message passing |

**After Week 2 you can:** run a working TCP target, trace a command through ctrlr.c
and bdev, explain why PR updates cross to the subsystem thread.

---

## Week 3: Multi-Host, PR, Namespace Visibility (Days 15–21)

Lab verification of everything in `spdk-pr-conclusion.md`.

| File | Day | Focus |
|---|---|---|
| `day15-multi-host-shared-ns.md` | 15 | Two hosts, one shared namespace, verify PR domain |
| `day16-pr-lab.md` | 16 | Register, acquire, conflict, preempt across two hosts |
| `day17-ptpl-lab.md` | 17 | PTPL file, restart, re-add with ptpl-file, verify survival |
| `day18-pr-conclusion-verification.md` | 18 | Cross-reference lab results with spdk-pr-conclusion.md |
| `day19-ns-visibility.md` | 19 | no-auto-visible, nvmf_ns_add_host, dynamic visibility change |
| `day20-exclusive-ns-visibility.md` | 20 | Two hosts, two namespaces, exclusive visibility, separate PR domains |
| `day21-week3-review.md` | 21 | Checklist, finalize nvmet comparison doc, key insight writing |

**After Week 3 you can:** reproduce any multi-host topology, explain PTPL load timing,
demonstrate per-namespace host visibility, and explain why exclusive namespaces create
separate PR domains.

---

## Week 4: Debugging and Contribution Readiness (Days 22–30)

Going deeper and making changes.

| File | Day | Focus |
|---|---|---|
| `day22-tcp-transport.md` | 22 | tcp.c: connection accept, QP poll, PDU receive, in-capsule vs H2C |
| `day23-logging-debugging.md` | 23 | Log flags, runtime enable/disable, gdb breakpoints for PR and bdev |
| `day24-tests.md` | 24 | ns_masking.sh walkthrough, PR unit tests, finding coverage gaps |
| `day25-unit-test-deep-read.md` | 25 | CUnit patterns, mocks, DEFINE_STUB, identify one gap |
| `day26-first-contribution.md` | 26 | Doc fix / log improvement / new unit test — full commit workflow |
| `day27-performance-baseline.md` | 27 | bdevperf, fio over NVMf, baseline IOPS/latency table |
| `day28-failure-paths.md` | 28 | ns removal mid-I/O, TCP kill, kill -9, PTPL under abrupt restart |
| `day29-lab-guide.md` | 29 | Four reusable recipe scripts + quick reference card |
| `day30-final-lab.md` | 30 | Scored final exam: all topologies from scratch + 5 written questions |

**After Week 4 you can:** debug live NVMf issues with gdb, measure and explain
performance characteristics, make a submittable code contribution, and reproduce
any 30-day topology from memory.

---

## Lab scripts

| File | Recipes |
|---|---|
| `spdk-week2-lab.sh` | Day 8–10: malloc bdev, AIO bdev, host ACL tests |
| `day29-lab-guide.md` | Recipe A–D: single host, shared ns, exclusive ns, PTPL |

---

## Key reference points

### For PR debugging

1. `spdk-pr-conclusion.md` — conclusions and lab verification
2. `nvmet-vs-spdk-pr-and-visibility.md` — comparison with Linux nvmet
3. `day16-pr-lab.md` — exact commands for each reservation type
4. `day17-ptpl-lab.md` — PTPL setup and verification steps

### For multi-host configuration

1. `day15-multi-host-shared-ns.md` — shared namespace setup
2. `day20-exclusive-ns-visibility.md` — exclusive per-host namespaces

### For code reading

1. `day7-nvmf-on-spdk-deep.md` — function-level call chains
2. `day11-ctrlr-deep-read.md` — guided read of ctrlr.c
3. `day12-subsystem-deep-read.md` — guided read of subsystem.c
4. `day6-core-code.md` — struct ownership table

### For debugging a running target

1. `day23-logging-debugging.md` — log flags and gdb breakpoint patterns

---

## Progress tracking

Update `spdk-learning-progress.md` as days are completed.

Current status: see `spdk-learning-progress.md`
