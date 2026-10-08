# Day 18: PR Conclusion Verification

## What this day covers

Cross-reference the lab results from Days 15–17 against `spdk-pr-conclusion.md`.

This is a writing and verification day, not a new lab. The goal is to produce a
lab-verified version of your PR conclusion — one where every claim is backed by
either code evidence or empirical lab observation.

---

## Why this matters

Your original `spdk-pr-conclusion.md` was written from code analysis and reasoning.
It is likely correct. But there may be edge cases, version differences, or subtle
behaviors that only show up in a running system.

Today you either confirm each point or note a discrepancy.

---

## Verification checklist

Work through each point in `spdk-pr-conclusion.md` and mark it as confirmed,
corrected, or still untested.

### Point 1: PR scope is per spdk_nvmf_ns

**Original claim:** PR state is scoped to `struct spdk_nvmf_ns`, not `spdk_bdev`.

**Lab evidence from Day 15–16:**
- [ ] Both hosts operated on the same `spdk_nvmf_ns`
- [ ] PR registered on Host A was visible in `nvme resv-report` on Host B
- [ ] Confirmed: PR state is shared across hosts on the same namespace object

**Status:** _____ (confirmed / corrected: _______ )

---

### Point 2: Same bdev cannot be in two subsystems

**Original claim:** `spdk_bdev_module_claim_bdev` is exclusive; same bdev in two
subsystems is rejected.

**Lab test (if not done):**

```bash
# With Aio0 already in subsystem A:
sudo $SPDK_DIR/scripts/rpc.py nvmf_create_subsystem \
    nqn.2024-01.io.spdk:subsys-b -a -s SPDK00000000000002

sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.2024-01.io.spdk:subsys-b Aio0 -n 1
# Expected: error — bdev already claimed
```

Record the exact error message returned.

**Status:** _____ (confirmed / corrected: _______ )

---

### Point 3: PR state not shared between two namespace objects on same media

**Original claim:** if somehow two namespace objects mapped to the same media, PR state
would not be shared (they would be separate `spdk_nvmf_ns` objects).

**Note:** this cannot be directly tested in SPDK because the bdev claim prevents it.
This remains a code-reasoning conclusion.

**Status:** untestable directly — confirmed by code analysis

---

### Point 4: Normal shared-volume model

**Original claim:** one subsystem, one namespace, multiple hosts = correct shared model.

**Lab evidence from Day 15:**
- [ ] Two hosts connected to one subsystem
- [ ] Both saw NSID 1
- [ ] Write from Host A was readable from Host B
- [ ] PR domain was shared

**Status:** _____ (confirmed / corrected: _______ )

---

### Point 5: Per-namespace host visibility

**Original claim:** SPDK supports per-namespace host visibility via `no_auto_visible=true`
and `nvmf_ns_add_host` / `nvmf_ns_remove_host`.

**Lab evidence:** (from Day 19–20 — not yet tested)

**Status:** pending — test in Days 19–20

---

### Point 6: PR only applies among hosts sharing same namespace

**Original claim:** if Host A and Host B do not share the same NSID, they are not in
the same PR domain for that storage.

**Lab evidence from Day 16:**
- [ ] PR registered by Host A was enforced against Host B on the shared namespace
- [ ] Logically follows: if they had different namespace objects, no enforcement

**Status:** _____ (confirmed by implication / corrected: _______ )

---

### Point 7: PTPL behavior

**Original claim:** PTPL files are loaded only at namespace-add time, not synchronized
at runtime.

**Lab evidence from Day 17:**
- [ ] PTPL file created after first PR state change
- [ ] File survived target stop
- [ ] Reservation restored when `--ptpl-file` specified on re-add
- [ ] Reservation NOT restored when `--ptpl-file` omitted on re-add

**Status:** _____ (confirmed / corrected: _______ )

---

### Point 8: Linux nvmet comparison

**Original claim:** Linux nvmet PR is namespace-scoped but host ACL is subsystem-scoped,
no per-namespace host visibility upstream.

**Status:** based on upstream source review — no lab test needed unless you have a
Linux nvmet setup available.

---

## Write your updated conclusion

After filling in the checklist, write a new section at the bottom of
`spdk-pr-conclusion.md`:

```markdown
## Lab Verification Results (Week 3)

Verified: 2026-[DATE]
SPDK version: [output of git log --oneline -1 in SPDK dir]

### Confirmed
- [list each confirmed point]

### Corrected
- [list any corrections with evidence]

### Still pending lab verification
- [list anything not yet tested]

### Surprises or edge cases found
- [anything unexpected from the lab]
```

---

## Additional edge cases to test (optional)

If time allows, test these edge cases not covered in the original conclusion:

### Edge case 1: Registration survives holder preempt

```bash
# Host A acquires, Host B preempts
# Does Host A remain a registrant after preempt?
nvme resv-report $DEV --eds
# Check if Host A still appears in registrants list
```

### Edge case 2: AEN (Async Event Notification) on PR change

When PR state changes, the target may send an AEN to other connected hosts.

```bash
# On Host B (not the holder), watch for AEN while Host A does PR operations
nvme admin-passthru ... # check for async events
# Or simply watch dmesg for reservation change notifications
```

### Edge case 3: Reservation conflict behavior under queue depth

```bash
# Submit many I/Os from Host B while Host A holds EXCLUSIVE_ACCESS
# Verify all are rejected with RESERVATION_CONFLICT, none succeed
fio --filename=/dev/nvme0n1 --rw=write --bs=4k --numjobs=1 \
    --iodepth=32 --runtime=5 --time_based --name=conflict-test
# All should fail
```

---

## What matters most after Day 18

1. Your PR conclusion is now lab-verified, not just code-reasoned.
2. Any discrepancies are documented and understood.
3. The combination of code analysis + lab evidence is the strongest possible understanding.
4. You are ready for namespace visibility lab work in Days 19–20.

---

## Suggested next step

Day 19: namespace visibility masking. Create namespaces with `--no-auto-visible` and
use `nvmf_ns_add_host` / `nvmf_ns_remove_host` to control which host sees which NSID.
