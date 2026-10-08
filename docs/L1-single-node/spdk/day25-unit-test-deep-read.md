# Day 25: Deep Read — One Unit Test File

## What this day covers

Read `test/unit/lib/nvmf/subsystem.c` in depth. Understand how SPDK developers
encode behavior expectations: mock infrastructure, test structure, assertion patterns,
and coverage strategy.

This is the prerequisite for Day 26, where you make your first code contribution.

---

## Unit test infrastructure in SPDK

SPDK uses CUnit for unit testing, plus its own mock layer.

Key patterns:

### CU_ASSERT macros

```c
CU_ASSERT(condition)              // assert condition is true
CU_ASSERT_EQUAL(a, b)            // assert a == b
CU_ASSERT_NOT_EQUAL(a, b)        // assert a != b
CU_ASSERT_PTR_NULL(ptr)          // assert ptr == NULL
CU_ASSERT_PTR_NOT_NULL(ptr)      // assert ptr != NULL
CU_ASSERT_STRING_EQUAL(s1, s2)   // assert strcmp(s1, s2) == 0
```

### Mock functions

Unit tests replace real SPDK functions with mocks. For example, instead of a real
bdev, tests use a mock that returns controllable values.

```bash
# Find mock definitions in the test file
grep -n "DEFINE_STUB\|MOCK_SET\|ut_bdev\|mock" \
    $SPDK_DIR/test/unit/lib/nvmf/subsystem.c | head -30
```

Common mock patterns:

```c
// Define a mock that returns a fixed value
DEFINE_STUB(spdk_bdev_get_by_name, struct spdk_bdev *,
            (const char *bdev_name), &g_bdev);

// Override a mock return value for one test
MOCK_SET(spdk_bdev_open_ext, -ENODEV);  // simulate open failure
```

---

## Reading the test file

Open `$SPDK_DIR/test/unit/lib/nvmf/subsystem.c`.

### Step 1: Find the test suite structure

```bash
grep -n "CU_pSuite\|CU_add_test\|suite_init\|suite_fini" \
    $SPDK_DIR/test/unit/lib/nvmf/subsystem.c
```

This shows you all test cases and their names.

### Step 2: Read the test infrastructure setup

Find `main()` or the test registration block. Note:

1. how is the mock bdev (`g_bdev` or similar) initialized?
2. how is the mock subsystem initialized?
3. is there a setup/teardown function called before/after each test?

### Step 3: Read three test cases in depth

Choose:

1. one test for `spdk_nvmf_subsystem_add_ns_ext` (namespace add)
2. one test for host ACL (`spdk_nvmf_subsystem_add_host`)
3. one test for PR or namespace visibility (search for `reservation` or `no_auto_visible`)

For each test, write down:

```
Test name: _______________

Mock setup:
  - what mock bdev state is set?
  - what mock return values are configured?

Test steps:
  1.
  2.
  3.

Assertions:
  - CU_ASSERT line 1: checks _______
  - CU_ASSERT line 2: checks _______

What behavior this test encodes:
  (one sentence)
```

---

## Specific areas to look for in subsystem.c unit tests

### Namespace add success path

```bash
grep -n "add_ns\|nvmf_subsystem_add_ns" \
    $SPDK_DIR/test/unit/lib/nvmf/subsystem.c | head -20
```

Find the test that verifies a namespace is correctly added: bdev opened, claim taken,
ns inserted into subsystem.

### Namespace add failure: bdev not found

```bash
grep -n "ENODEV\|get_by_name\|bdev_not_found" \
    $SPDK_DIR/test/unit/lib/nvmf/subsystem.c | head -10
```

### Namespace add failure: bdev already claimed

```bash
grep -n "claim\|EBUSY\|already" \
    $SPDK_DIR/test/unit/lib/nvmf/subsystem.c | head -10
```

### Host ACL tests

```bash
grep -n "add_host\|host_allowed\|allow_any" \
    $SPDK_DIR/test/unit/lib/nvmf/subsystem.c | head -20
```

### PR tests (if present)

```bash
grep -n "reservation\|resv\|registrant\|holder" \
    $SPDK_DIR/test/unit/lib/nvmf/subsystem.c | head -20
```

---

## Compare with ctrlr.c unit tests

Also briefly scan `test/unit/lib/nvmf/ctrlr.c`:

```bash
grep -n "def test_\|static void test_" \
    $SPDK_DIR/test/unit/lib/nvmf/ctrlr.c | head -20
```

Focus on:

1. is the PR conflict check tested for each reservation type?
2. is the NSID-not-found path tested?
3. is the host-NQN-not-allowed path tested?

---

## Identify a test gap

After reading, find one behavior you know exists in the code but is not tested, or
is tested incompletely.

Examples of good gaps:

- PR conflict check for `WRITE_EXCLUSIVE_REGISTRANTS_ONLY` missing a specific case
- namespace visibility check not tested when host is added then removed
- PTPL load failure case not tested (what if the file is malformed?)

Write it down in this format:

```
Gap identified: _______________

Why I think it is a gap:
  - behavior exists in: lib/nvmf/[file.c], function [name]
  - test file [test/unit/...] does not cover this case
  - I verified by: grep -n "[pattern]" test/unit/lib/nvmf/subsystem.c

This gap matters because:
  (one sentence)

To test it, I would:
  1. set up mock with [condition]
  2. call [function]
  3. assert [expected result]
```

This is your Day 26 contribution target.

---

## What to record

After reading:

1. how many test cases are in `subsystem.c`?
2. which three did you read in depth?
3. what gap did you identify?
4. did you find any tests you did not expect (surprising edge cases)?

---

## What matters most after Day 25

1. SPDK unit tests use mocks to isolate code under test — no real hardware needed.
2. `DEFINE_STUB` and `MOCK_SET` are how return values are controlled in tests.
3. CU_ASSERT patterns are consistent — once you read one test, you can read all of them.
4. Gaps in test coverage are your entry point for contributions.
5. The gap you identified today is your Day 26 task.

---

## Suggested next step

Day 26: make a real code contribution. Use the gap identified today to write a new
test case, fix a documentation mismatch, or add a validation check.
