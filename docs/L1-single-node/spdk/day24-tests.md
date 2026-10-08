# Day 24: Tests — ns_masking.sh and PR Unit Tests

## What this day covers

Read and run SPDK's own tests for namespace masking and PR. Understanding how SPDK
tests its own behavior is essential before making code changes.

---

## Why read the tests

SPDK tests are the authoritative specification of intended behavior. They tell you:

- exactly which RPC sequences produce which outcomes
- what error codes are expected for invalid operations
- which edge cases the developers considered important enough to test
- how to set up and tear down test environments reliably

If you want to add a feature or fix a bug, you need to understand the existing test
patterns first.

---

## Test file locations

```bash
# NVMf functional tests
ls $SPDK_DIR/test/nvmf/target/

# NVMf unit tests
ls $SPDK_DIR/test/unit/lib/nvmf/

# Run all NVMf unit tests
$SPDK_DIR/test/unit/lib/nvmf/nvmf.sh
```

---

## Reading ns_masking.sh

```bash
cat $SPDK_DIR/test/nvmf/target/ns_masking.sh
```

This test exercises per-namespace host visibility. Read it and map each section to
what you did manually in Days 19–20.

What to look for:

### Test setup pattern

```bash
# The test likely follows this pattern:
nvmftestinit     # start nvmf_tgt with test config
createsubsystem  # create subsystem
addlistener      # add TCP listener
addbdev          # create test bdev (malloc or null)
addns --no-auto-visible
```

Note how the test creates bdevs and subsystems. Does it use helper functions from
`$SPDK_DIR/test/common/`?

### Verification pattern

```bash
# How does the test verify host A sees NSID 1 but not NSID 2?
# Look for nvme id-ns, nvme list, or similar initiator commands
# Look for checks on return codes
```

### Cleanup pattern

```bash
# How does the test tear down?
# Does it use traps for cleanup on failure?
```

---

## Running ns_masking.sh

**Prerequisites:** two initiator hosts or one host with two different NQNs configured.

```bash
# Run with output
sudo $SPDK_DIR/test/nvmf/target/ns_masking.sh 2>&1 | tee /tmp/ns_masking_run.log

# Check result
echo "Exit code: $?"
```

If the test fails, the log shows which step failed and what the expected vs actual
output was.

---

## Reading NVMf unit tests

Unit tests test individual functions without a running target. They use mock objects
for bdev, transport, and thread.

```bash
ls $SPDK_DIR/test/unit/lib/nvmf/
# subsystem.c   <- tests for subsystem.c functions
# ctrlr.c       <- tests for ctrlr.c functions
# tcp.c         <- tests for tcp.c functions
```

### Read test/unit/lib/nvmf/subsystem.c

This file tests functions in `lib/nvmf/subsystem.c`. Read it with this focus:

1. how are mock bdevs created for tests?
2. which function is called to test `spdk_nvmf_subsystem_add_ns_ext`?
3. how is the bdev claim failure case tested?
4. are there PR-specific test cases? what do they verify?

```bash
grep -n "reservation\|resv\|PTPL\|ptpl" \
    $SPDK_DIR/test/unit/lib/nvmf/subsystem.c
```

### Read test/unit/lib/nvmf/ctrlr.c

Focus on:

1. how is the PR conflict check tested?
2. is there a test for each reservation type?
3. how is the host NQN check tested?

```bash
grep -n "reservation\|CONFLICT\|hostnqn" \
    $SPDK_DIR/test/unit/lib/nvmf/ctrlr.c
```

---

## Running unit tests

```bash
# Build first
cd $SPDK_DIR
./configure && make -j$(nproc)

# Run subsystem unit tests
$SPDK_DIR/test/unit/lib/nvmf/nvmf.sh

# Or run just the subsystem test
$SPDK_DIR/build/test/unit/lib/nvmf/subsystem/subsystem_ut
```

Unit tests run fast (seconds) and do not require hugepages or hardware.

---

## Adding a test observation

Pick one test case from `subsystem.c` unit tests. For that test case, write down:

1. what function is being tested?
2. what input conditions are set up?
3. what is the expected output or return code?
4. how does the test verify the expectation? (CU_ASSERT, return value check?)

Example format:

```
Test: test_nvmf_subsystem_add_ns_bdev_claimed

Setup:
  - create mock bdev "bdev1"
  - create subsystem
  - add bdev1 as namespace (first add — should succeed)

Action:
  - try to add bdev1 as namespace again (same or different subsystem)

Expected:
  - second add returns -EINVAL or -EBUSY
  - first namespace is unaffected

Verification method:
  - CU_ASSERT_EQUAL(rc, -EINVAL)
```

This exercise teaches you how SPDK developers think about correctness.

---

## PR-specific test search

If there are PR unit tests, find them:

```bash
grep -rn "reservation\|nvmf_ns_reservation" \
    $SPDK_DIR/test/unit/lib/nvmf/ | head -20

grep -rn "resv" $SPDK_DIR/test/nvmf/ | grep -v ".pyc" | head -20
```

Record what PR behaviors are tested vs what is only tested via functional tests or
not tested at all. Gaps in test coverage are good targets for contributions.

---

## What to record

After reading and running tests:

1. what does `ns_masking.sh` test that you did not test manually?
2. what does it NOT test that you tested manually?
3. are there PR unit tests? do they cover all reservation types?
4. what is one gap in test coverage you noticed?

---

## What matters most after Day 24

1. Tests are the specification. If behavior is not tested, it may not be intentional.
2. Unit tests are fast and do not require hardware — run them often during development.
3. Functional tests like `ns_masking.sh` require a full target and initiator setup.
4. Test gaps are contribution opportunities.

---

## Suggested next step

Day 25: deep read of one unit test file. Pick `test/unit/lib/nvmf/subsystem.c` and
understand how SPDK developers encode correctness — mock setup, test structure, and
assertion patterns.
