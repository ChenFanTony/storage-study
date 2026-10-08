# Day 30: Final Lab

## What this day covers

From scratch, no notes open, reproduce every topology from the 30-day plan and
explain PR behavior clearly.

This is the test. If you can do this, the 30 days worked.

---

## Rules

- No notes open during the lab portion
- No copy-pasting from lab scripts (type the commands)
- Notes are allowed only during the explanation writing at the end
- Time yourself

---

## Part 1: Environment (target: under 5 minutes)

Set up hugepages and start a working `nvmf_tgt` with one TCP transport.

Verify RPC is working before proceeding.

---

## Part 2: Single host export (target: under 5 minutes)

Create an AIO bdev from a real block device. Export it as NSID 1 in a new subsystem.
Connect one host. Verify with `nvme id-ns`.

Checkpoint:

- [ ] bdev shows `claimed: true` after namespace add
- [ ] initiator shows correct geometry in `nvme id-ns`
- [ ] one read succeeds from the initiator

---

## Part 3: Two hosts, shared namespace (target: under 5 minutes)

Connect a second host to the same subsystem. Both should see NSID 1.

Checkpoint:

- [ ] both hosts see the same NSID 1
- [ ] both hosts see the same `nguid` in `nvme id-ns`
- [ ] write from Host A is readable from Host B
- [ ] `nvmf_get_subsystems` shows two controllers on the subsystem

---

## Part 4: PR across two hosts (target: under 10 minutes)

With both hosts connected to the shared namespace:

1. Host A registers a key
2. Host A acquires WRITE_EXCLUSIVE reservation
3. Verify Host B can read but cannot write
4. Host B registers a key
5. Switch reservation to EXCLUSIVE_ACCESS
6. Verify Host B cannot read or write
7. Host B preempts (takes the reservation)
8. Verify Host A cannot write
9. Clean up all reservations

Checkpoint:

- [ ] each expected success/failure matches the reservation type rules
- [ ] `nvme resv-report` shows correct state after each operation
- [ ] after cleanup, `nvme resv-report` shows no registrants

---

## Part 5: PTPL (target: under 10 minutes)

With a PTPL-configured namespace:

1. acquire a reservation from Host A
2. enable PTPL via SET FEATURES
3. verify PTPL file was written
4. stop the target
5. restart and re-add namespace with same PTPL file
6. reconnect Host A
7. verify reservation survived

Checkpoint:

- [ ] PTPL file exists and contains reservation state before restart
- [ ] reservation is present in `nvme resv-report` after restart
- [ ] repeat without `--ptpl-file` and verify state is empty

---

## Part 6: Exclusive namespace visibility (target: under 10 minutes)

Create a new subsystem with two AIO bdevs. Add both namespaces as `--no-auto-visible`.
Grant Host A visibility to NSID 1, Host B visibility to NSID 2.

Checkpoint:

- [ ] Host A sees only NSID 1
- [ ] Host B sees only NSID 2
- [ ] Host A cannot access NSID 2
- [ ] Host B cannot access NSID 1
- [ ] write from Host A goes to correct backing device
- [ ] PR registration on Host A's namespace does not affect Host B's namespace

---

## Part 7: Teardown

Remove all subsystems cleanly. Verify no orphaned bdev claims.

```bash
sudo $SPDK_DIR/scripts/rpc.py bdev_get_bdevs
# All bdevs should show claimed: false after subsystem deletion
```

---

## Part 8: Explanation (written, notes allowed)

After completing the lab, write answers to these questions without looking at your
lab notes:

### Question 1

> A colleague asks: "We have two SPDK targets. Can we set up one bdev and share it
> across both targets so hosts connecting to either target share a PR domain?"
>
> What do you tell them? What is the fundamental reason this does not work in current SPDK?

Answer: ___

### Question 2

> Another colleague asks: "We need host A and host B to connect to the same NQN but
> see different namespaces. Host A gets /dev/sdb, host B gets /dev/sdc. We also need
> PR to work within each host's namespace independently. How do we configure this?"
>
> Walk through the exact RPC sequence.

Answer: ___

### Question 3

> A third colleague asks: "We set up PTPL. We killed the target hard (kill -9). When
> we restarted, the reservation was gone. What did we do wrong?"
>
> What is the likely cause and what is the fix?

Answer: ___

### Question 4

> Someone reports a bug: "Host A holds a WRITE_EXCLUSIVE reservation. Host B is
> sending reads and they succeed. Reads should be blocked, shouldn't they?"
>
> Is this actually a bug? Explain.

Answer: ___

### Question 5

> "We want to add the same bdev to two NVMf subsystems simultaneously. The second
> `nvmf_subsystem_add_ns` call fails. We need this for DR (Disaster Recovery)
> failover. What are our options?"
>
> Name at least two architectural approaches.

Answer: ___

---

## Scoring

Count how many checkpoints you completed without consulting notes:

- Part 1–3: 5 checkpoints each = 15
- Part 4: 4 checkpoints = 4
- Part 5: 3 checkpoints = 3
- Part 6: 6 checkpoints = 6
- Part 7: 1 checkpoint = 1
- Part 8: 5 questions = 5

Total possible: 34

**Score interpretation:**

- 30–34: you own this material
- 24–29: solid, minor gaps to fill
- 18–23: good foundation, review weak areas
- below 18: revisit the week(s) where you scored poorly

---

## After the final lab

Record:

1. total time for Parts 1–7 (should be under 45 minutes)
2. your checkpoint score
3. which questions in Part 8 required the most thought
4. one thing you want to learn next that this plan did not cover

---

## What comes next

You have completed the 30-day plan. Suggested directions from here:

**Go deeper on SPDK:**
- RDMA transport (`lib/nvmf/rdma.c`)
- lvol: logical volumes, snapshots, clones
- vhost: virtio block and SCSI for VM storage
- SPDK's own NVMe driver internals (`lib/nvme/`)

**Go broader on NVMe-oF:**
- Fabric discovery service
- ANA (Asymmetric Namespace Access) for multi-path
- NVMe-oF over Fibre Channel

**Make more contributions:**
- pick an open GitHub issue labeled `good first issue`
- write a test for a PR behavior you know is untested
- improve error messages throughout `lib/nvmf/`

**Apply it:**
- build a real multi-host storage configuration for your team
- benchmark SPDK NVMe passthrough vs AIO at your workloads
- profile the target under load and find the bottleneck
