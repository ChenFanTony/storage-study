# Day 21: Week 3 Review

## What this day covers

Consolidate Week 3 into a clean, lab-verified reference document comparing SPDK and
Linux nvmet across all four axes: host ACL, namespace visibility, PR, and workflow.

---

## Review checklist

### From Day 15 (multi-host shared namespace)
- [ ] One subsystem + one namespace + two hosts = one PR domain
- [ ] Write from Host A readable from Host B via same namespace object
- [ ] `nvmf_get_subsystems` shows two controllers on the same subsystem

### From Day 16 (PR lab)
- [ ] WRITE_EXCLUSIVE: reads allowed for non-holders, writes blocked
- [ ] EXCLUSIVE_ACCESS: all I/O blocked for non-holders
- [ ] Registration does not require holding the reservation
- [ ] Preempt changes holder atomically
- [ ] `nvme resv-report` shows correct state after each operation

### From Day 17 (PTPL lab)
- [ ] PTPL file created on first PR state change
- [ ] Reservation survives restart when `--ptpl-file` re-specified
- [ ] Reservation does NOT survive without `--ptpl-file` on re-add
- [ ] PTPL is loaded at namespace-add time only

### From Day 18 (PR conclusion verification)
- [ ] All original PR conclusion points confirmed or corrected
- [ ] Lab-verified section added to `spdk-pr-conclusion.md`

### From Day 19 (namespace visibility masking)
- [ ] `--no-auto-visible` starts namespace invisible to all hosts
- [ ] `nvmf_ns_add_host` grants visibility per host per namespace
- [ ] `nvmf_ns_remove_host` revokes visibility live
- [ ] Both hosts can be granted or denied independently

### From Day 20 (exclusive namespace visibility)
- [ ] Host A sees only NSID 1, Host B sees only NSID 2 from same subsystem
- [ ] Storage isolation confirmed: separate backing devices, separate data
- [ ] PR isolation confirmed: Host A's PR on NSID 1 does not affect NSID 2

---

## Writing exercise: finalize nvmet-vs-spdk-pr-and-visibility.md

Open `nvmet-vs-spdk-pr-and-visibility.md` (generated earlier). Update the Lab
Verification Checklist at the bottom:

```markdown
## Lab Verification Results

Verified: 2026-[DATE]
SPDK version: [git log --oneline -1]

- [x] Day 15: Two hosts connected to one namespace — both see same NSID ✓
- [x] Day 16: Host A registers/reserves; Host B sees RESERVATION_CONFLICT ✓
- [x] Day 17: PTPL survives restart with same ptpl_file on re-add ✓
- [x] Day 19: no-auto-visible + nvmf_ns_add_host — host-selective visibility ✓
- [x] Day 20: Two namespaces, two hosts, exclusive visibility confirmed ✓

### Corrections to original document
[list anything that differed from predictions]

### Surprises
[anything unexpected]
```

---

## The key insight to articulate

Write one paragraph in your own words answering:

> What does SPDK's per-namespace host visibility enable that Linux nvmet cannot do
> in a single subsystem, and why would you care?

This should cover:

- the topology (one NQN, multiple hosts, different namespaces per host)
- the PR implication (separate namespace objects = separate PR domains)
- the operational advantage (one NQN to manage instead of N subsystems)
- the Linux nvmet workaround and its cost (separate NQNs, more discovery entries,
  more controller overhead)

---

## Summary table: everything you built in Week 3

| Day | Topology | Key verification |
|---|---|---|
| 15 | 1 subsystem, 1 ns, 2 hosts | shared PR domain confirmed |
| 16 | same, with PR active | WRITE_EXCL and EXCL_ACCESS conflict behavior verified |
| 17 | same, with PTPL | reservation survives restart with ptpl_file |
| 18 | — | PR conclusion doc updated with lab evidence |
| 19 | 1 subsystem, 1 masked ns | per-host visibility grant/revoke live |
| 20 | 1 subsystem, 2 masked ns | exclusive per-host namespaces, separate PR domains |

---

## Gap check before Week 4

Week 4 is debugging, performance, and contribution readiness. Before starting:

**Must be solid:**
- [ ] Can reproduce any Week 3 topology from scratch in under 15 minutes
- [ ] Understand why PTPL requires re-specifying the file path on restart
- [ ] Can explain the difference between subsystem-level ACL and namespace-level visibility
- [ ] Know that per-namespace visibility creates separate PR domains

**Nice to have:**
- [ ] Have seen `nvmf_ns_reservation_update` execute in gdb
- [ ] Have read the PTPL JSON file and understand its fields
- [ ] Have tried at least one of the optional edge cases from Day 18

---

## What matters most after Day 21

1. Week 3 is complete. Every major SPDK multi-host and PR behavior has been tested.
2. Your notes are now the authoritative reference for this configuration space.
3. The nvmet comparison document is lab-verified, not just code-reasoned.
4. You are ready for Week 4: debugging internals, performance measurement, and
   making real code contributions.

---

## Suggested next step

Week 4, Day 22: read `lib/nvmf/tcp.c`. Understand the transport layer — queue pair
handling, request receive, buffer lifecycle. This is the entry point for all the
command flows you traced in Week 2.
