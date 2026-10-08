# SPDK Learning Progress

## Current focus

- Begin Day 6: read lib/nvmf/nvmf_internal.h, lib/thread/thread.c, lib/bdev/bdev.c
- Complete 7-day architecture mini plan through Day 7
- Then move to Week 2 of the revised 30-day plan

---

## 7-Day Architecture Mini Plan

- [x] Day 1: Big picture overview — `day1-spdk-overview.md`
- [x] Day 2: Application framework — `day2-app-framework.md`
- [x] Day 3: Thread / reactor / poller model — `day3-thread-reactor-poller.md`
- [x] Day 4: I/O channel model — `day4-io-channel.md`
- [x] Day 5: bdev framework — `day5-bdev-framework.md`
- [ ] Day 6: Read core code — `day6-core-code.md` (note ready, code reading pending)
- [ ] Day 7: Integrate model with NVMf — `day7-nvmf-on-spdk-deep.md` (note ready, reading pending)

---

## 30-Day Revised Plan

### Week 1: Framework gap closure

- [x] Notes generated: Days 1–7
- [ ] Day 1: bdev lab (create Malloc, AIO, uring bdevs)
- [ ] Day 2: read lib/thread/thread.c — annotate 10 key functions
- [ ] Day 3: find per-thread queue pair creation in NVMe bdev
- [ ] Day 4: read lib/bdev/bdev.c — four focus areas
- [ ] Day 5: hands-on bdev lab
- [ ] Day 6: read nvmf_internal.h — fill in thread ownership table
- [ ] Day 7: light read ctrlr.c + subsystem.c threading boundaries

### Week 2: NVMf target mechanics

- [x] Notes generated: Days 8–14
- [ ] Day 8: TCP target with malloc bdev, initiator connect
- [ ] Day 9: AIO bdev replacement
- [ ] Day 10: host ACL modes
- [ ] Day 11: ctrlr.c deep read
- [ ] Day 12: subsystem.c deep read
- [ ] Day 13: end-to-end I/O trace
- [ ] Day 14: week review + writing exercises

### Week 3: Multi-host, PR, namespace visibility

- [x] Notes generated: Days 15–21
- [x] PR conceptual research complete (ahead of schedule)
- [ ] Day 15: two hosts, shared namespace lab
- [ ] Day 16: PR register/acquire/conflict lab
- [ ] Day 17: PTPL lab
- [ ] Day 18: PR conclusion verification
- [ ] Day 19: namespace visibility masking
- [ ] Day 20: exclusive namespace visibility
- [ ] Day 21: week review + finalize nvmet comparison doc

### Week 4: Debugging and contribution readiness

- [x] Notes generated: Days 22–30
- [ ] Day 22: tcp.c deep read
- [ ] Day 23: logging and gdb debugging
- [ ] Day 24: run tests
- [ ] Day 25: deep read one unit test
- [ ] Day 26: first contribution
- [ ] Day 27: performance baseline
- [ ] Day 28: failure path lab
- [ ] Day 29: build reusable lab guide
- [ ] Day 30: final lab

---

## All notes generated

### Plan documents
- `spdk-7day-architecture-plan.md`
- `spdk-30day-study-plan.md`
- `spdk-30day-study-plan-revised.md`
- `spdk-learning-progress.md` (this file)
- `study-index.md`

### Week 1
- `day1-spdk-overview.md`
- `day2-app-framework.md`
- `day3-thread-reactor-poller.md`
- `day4-io-channel.md`
- `day5-bdev-framework.md`
- `day6-core-code.md`
- `day7-nvmf-on-spdk.md`
- `day7-nvmf-on-spdk-deep.md`

### Week 2
- `day8-basic-tcp-target.md`
- `day9-aio-bdev.md`
- `day10-host-acls.md`
- `day11-ctrlr-deep-read.md`
- `day12-subsystem-deep-read.md`
- `day13-io-trace.md`
- `day14-week2-review.md`

### Week 3
- `day15-multi-host-shared-ns.md`
- `day16-pr-lab.md`
- `day17-ptpl-lab.md`
- `day18-pr-conclusion-verification.md`
- `day19-ns-visibility.md`
- `day20-exclusive-ns-visibility.md`
- `day21-week3-review.md`

### Week 4
- `day22-tcp-transport.md`
- `day23-logging-debugging.md`
- `day24-tests.md`
- `day25-unit-test-deep-read.md`
- `day26-first-contribution.md`
- `day27-performance-baseline.md`
- `day28-failure-paths.md`
- `day29-lab-guide.md`
- `day30-final-lab.md`

### Reference
- `spdk-pr-conclusion.md`
- `nvmet-vs-spdk-pr-and-visibility.md`
- `spdk-week2-lab.sh`

---

## Research completed ahead of schedule

The following Week 3 topics are complete at the conceptual level.
Lab verification is pending (Days 15–20).

- PR state is scoped to `spdk_nvmf_ns`, not `spdk_bdev`
- bdev claim exclusivity prevents same bdev in two subsystems
- PTPL file loaded at namespace-add time only (not synced at runtime)
- per-namespace host visibility via `--no-auto-visible` + `nvmf_ns_add_host`
- Linux nvmet PR: namespace-scoped, no per-namespace host ACLs upstream
- workarounds: single subsystem with ANA, or NVMe passthrough for hardware PR

See `spdk-pr-conclusion.md` for full details.

---

## Latest update

- Date: 2026-04-24
- Completed: all 30 day notes generated
- Completed: study-index.md created
- Completed: revised 30-day plan
- Next: Day 6 lab work — open lib/nvmf/nvmf_internal.h and fill in the thread
  ownership table from `day6-core-code.md`
