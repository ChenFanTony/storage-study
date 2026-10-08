# Day 26: First Contribution

## What this day covers

Make a real, submittable change to the SPDK codebase. Small and correct beats large
and broken.

---

## Good starter contribution types

Ranked by difficulty and risk:

### Tier 1: Documentation fix (lowest risk)

- fix a typo or grammatical error in `doc/nvmf.md` or inline code comments
- add a missing parameter description in a public header (`include/spdk/nvmf.h`)
- clarify an ambiguous sentence in `doc/bdev.md`
- update a comment that refers to a renamed function

```bash
# Find stale references in comments
grep -rn "nvmf_subsystem_add_ns\b" $SPDK_DIR/doc/ $SPDK_DIR/include/
# Check if the RPC name in docs matches the actual RPC method name
```

### Tier 2: Error log improvement (low risk)

Find a place where an error is silently returned or the log message is unhelpful:

```bash
# Look for SPDK_ERRLOG calls with generic messages
grep -n "SPDK_ERRLOG" $SPDK_DIR/lib/nvmf/subsystem.c | grep -i "failed\|error" | head -20
```

Add the specific reason, affected object name, or return code to the message.

Example improvement:

```c
// Before
SPDK_ERRLOG("Failed to add namespace\n");

// After
SPDK_ERRLOG("Failed to add namespace %s to subsystem %s: bdev already claimed\n",
             bdev_name, subsystem->subnqn);
```

### Tier 3: Input validation (medium risk)

Find a function that accepts a parameter without validating it:

```bash
# Look for functions that use a parameter without checking it
grep -n "assert\|SPDK_ERRLOG\|return -EINVAL" \
    $SPDK_DIR/lib/nvmf/subsystem.c | head -20
```

Example: does `nvmf_ns_add_host` validate that `hostnqn` is non-NULL and non-empty
before inserting it into the host list?

### Tier 4: New unit test case (medium risk)

Use the gap you identified in Day 25. Write a new test case following the patterns
you read.

---

## Contribution workflow

### Step 1: Fork and branch

```bash
cd $SPDK_DIR
git checkout -b my-fix-description
```

### Step 2: Make the change

Keep changes minimal and focused. One logical fix per commit.

### Step 3: Verify no regressions

```bash
# Run unit tests
$SPDK_DIR/test/unit/lib/nvmf/nvmf.sh

# Run checkpatch (SPDK code style check)
$SPDK_DIR/scripts/checkpatch.sh HEAD
```

SPDK uses Linux kernel coding style for C code. Key rules:

- tabs for indentation, not spaces
- lines under 100 characters
- no trailing whitespace
- function comments use `/**` Doxygen style in headers

### Step 4: Write the commit message

SPDK commit messages follow this format:

```
nvmf: fix missing bdev name in error log for namespace add failure

When spdk_nvmf_subsystem_add_ns_ext fails because the bdev is already
claimed, the error log does not include the bdev name or subsystem NQN,
making it difficult to diagnose the failure from logs alone.

Add the bdev name and subsystem NQN to the error message.

Signed-off-by: Your Name <your.email@example.com>
```

Format:

- subject: `component: short description` (under 72 chars)
- blank line
- body: why the change is needed, what it does
- blank line
- `Signed-off-by:` line (required for SPDK)

### Step 5: Submit

SPDK uses GitHub pull requests. Open a PR against the `main` branch of
`spdk/spdk`.

---

## If you wrote a new unit test

Structure your new test case to match existing ones:

```c
static void
test_nvmf_ns_add_host_null_hostnqn(void)
{
    struct spdk_nvmf_subsystem subsystem = {};
    int rc;

    /* Setup: initialize subsystem with one namespace */
    /* ... */

    /* Test: add NULL hostnqn should return -EINVAL */
    rc = spdk_nvmf_ns_add_host(&subsystem, 1, NULL, 0);
    CU_ASSERT_EQUAL(rc, -EINVAL);

    /* Cleanup */
}
```

Register it in the test suite:

```c
CU_ADD_TEST(suite, test_nvmf_ns_add_host_null_hostnqn);
```

Run it:

```bash
$SPDK_DIR/build/test/unit/lib/nvmf/subsystem/subsystem_ut
```

---

## If you fixed a doc or log issue

Verify your change:

```bash
# For doc changes: read the rendered output
# For log changes: trigger the code path and verify the new message appears
sudo $SPDK_DIR/scripts/rpc.py nvmf_subsystem_add_ns \
    nqn.already.claimed.bdev AlreadyClaimedBdev -n 1
# Should show your improved error message in SPDK logs
```

---

## What to record

After completing the contribution:

1. what type of change did you make?
2. what file(s) were modified?
3. did `checkpatch.sh` pass on the first try? if not, what did you fix?
4. did unit tests pass?
5. what did you learn about the codebase from making this change?

---

## What matters most after Day 26

1. A merged SPDK contribution, however small, means you understand the codebase well
   enough to change it safely.
2. `checkpatch.sh` is your first reviewer — run it before asking humans to review.
3. Good commit messages are as important as good code for SPDK maintainers.
4. The smallest correct contribution is better than a large incomplete one.

---

## Suggested next step

Day 27: performance baseline. Measure IOPS and latency for your AIO-backed namespace
using `bdevperf` and a Linux nvme initiator. Establish numbers you can compare against
after making changes.
