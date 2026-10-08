# Day 16: Persistent Reservations Lab

## What this day covers

Exercise PR register, acquire, and conflict behavior across two hosts on one shared
namespace. Verify empirically what the code in `subsystem.c` implements.

Requires: Day 15 setup (two hosts connected to one subsystem, one shared namespace).

---

## NVMe PR concepts recap

Before running commands, confirm you can answer:

- **Registrant**: a host that has registered a reservation key with the namespace.
  Registration does not grant exclusive access — it just joins the PR domain.
- **Holder**: the registrant that has acquired the active reservation. The holder's
  reservation type determines what other hosts can and cannot do.
- **Reservation key (rkey)**: a 64-bit value chosen by the host, used to identify
  its reservation operations.
- **Reservation type**: controls what access non-holders have (write-exclusive,
  exclusive-access, etc.)

---

## nvme-cli PR commands

```bash
# Register a key
nvme resv-register <dev> --rkey=<new_key> --crkey=0 --racqa=0

# Acquire a reservation
nvme resv-acquire <dev> --rkey=<key> --rtype=<type> --racqa=0

# Report current reservation state
nvme resv-report <dev> --eds

# Release a reservation
nvme resv-release <dev> --rkey=<key> --rtype=<type> --rrela=0

# Unregister
nvme resv-register <dev> --rkey=0 --crkey=<current_key> --racqa=2
```

Reservation types:
- `1` = WRITE_EXCLUSIVE
- `2` = EXCLUSIVE_ACCESS
- `3` = WRITE_EXCLUSIVE_REGISTRANTS_ONLY
- `4` = EXCLUSIVE_ACCESS_REGISTRANTS_ONLY
- `5` = WRITE_EXCLUSIVE_ALL_REGISTRANTS
- `6` = EXCLUSIVE_ACCESS_ALL_REGISTRANTS

---

## Lab 1: Register and reserve (Host A only)

On Host A:

```bash
DEV=/dev/nvme0n1
RKEY_A=0xABCD1234

# Register key
nvme resv-register $DEV --rkey=$RKEY_A --crkey=0 --racqa=0
echo "Register result: $?"

# Acquire WRITE_EXCLUSIVE reservation
nvme resv-acquire $DEV --rkey=$RKEY_A --rtype=1 --racqa=0
echo "Acquire result: $?"

# Report state
nvme resv-report $DEV --eds
```

Expected report output:

- `gen`: generation counter (incremented on each state change)
- `rtype`: 1 (WRITE_EXCLUSIVE)
- `regctl`: 1 (one registrant)
- registrant entry: Host A's hostid, `rcsts=1` (holder)

---

## Lab 2: Observe conflict from Host B

### 2a: Host B reads (should succeed — WRITE_EXCLUSIVE allows reads by all)

On Host B:

```bash
DEV=/dev/nvme0n1

# Read — should succeed under WRITE_EXCLUSIVE
sudo dd if=$DEV of=/dev/null bs=4k count=1 iflag=direct
echo "Read result: $?"
```

Expected: success (return code 0). WRITE_EXCLUSIVE only blocks writes by non-holders.

### 2b: Host B writes (should fail — WRITE_EXCLUSIVE blocks writes by non-holders)

On Host B:

```bash
# Write — should fail with RESERVATION_CONFLICT
sudo dd if=/dev/urandom of=$DEV bs=4k count=1 oflag=direct 2>&1
echo "Write result: $?"
```

Expected: failure. The kernel NVMe driver will report an I/O error. The SPDK target
returns `SPDK_NVME_SC_RESERVATION_CONFLICT` in the CQE status field.

Check dmesg on Host B:

```bash
dmesg | tail -5
# Should show NVMe reservation conflict or I/O error
```

### 2c: Host B registers (should succeed — registration does not require holding reservation)

On Host B:

```bash
RKEY_B=0xBEEF5678

nvme resv-register $DEV --rkey=$RKEY_B --crkey=0 --racqa=0
echo "Register result: $?"

# Report — now shows two registrants
nvme resv-report $DEV --eds
```

Expected: registration succeeds. Report now shows two registrants: Host A (holder)
and Host B (registrant, not holder).

---

## Lab 3: Change reservation type to EXCLUSIVE_ACCESS

On Host A:

```bash
# Release current WRITE_EXCLUSIVE reservation
nvme resv-release $DEV_A --rkey=$RKEY_A --rtype=1 --rrela=0

# Acquire EXCLUSIVE_ACCESS
nvme resv-acquire $DEV_A --rkey=$RKEY_A --rtype=2 --racqa=0

nvme resv-report $DEV_A --eds
# rtype should now be 2
```

Now test Host B read (should fail — EXCLUSIVE_ACCESS blocks ALL I/O by non-holders):

```bash
# On Host B
sudo dd if=$DEV of=/dev/null bs=4k count=1 iflag=direct 2>&1
echo "Read result: $?"
# Expected: failure
```

---

## Lab 4: Preempt (Host B takes over)

Host B can preempt the reservation if it is a registrant:

```bash
# On Host B — preempt Host A's reservation
# racqa=2 means PREEMPT
nvme resv-acquire $DEV --rkey=$RKEY_B --crkey=$RKEY_A --rtype=1 --racqa=2
echo "Preempt result: $?"

nvme resv-report $DEV --eds
# Expected: Host B is now the holder, Host A is no longer holder
# (Host A may still be a registrant depending on preempt type)
```

After preempt, Host A's writes should now be rejected.

---

## Lab 5: Full cleanup

```bash
# On Host B — release and unregister
nvme resv-release $DEV --rkey=$RKEY_B --rtype=1 --rrela=0
nvme resv-register $DEV --rkey=0 --crkey=$RKEY_B --racqa=2

# On Host A — unregister (if still registered)
nvme resv-register $DEV_A --rkey=0 --crkey=$RKEY_A --racqa=2

# Verify clean state
nvme resv-report $DEV --eds
# Expected: no reservation, no registrants, gen incremented
```

---

## What to observe and record

For each lab step, record:

| Step | Command | Expected result | Actual result | Match? |
|---|---|---|---|---|
| Host A register | resv-register | success | | |
| Host A acquire WRITE_EXCL | resv-acquire rtype=1 | success | | |
| Host B read (WRITE_EXCL) | dd read | success | | |
| Host B write (WRITE_EXCL) | dd write | RESERVATION_CONFLICT | | |
| Host B register | resv-register | success | | |
| Host A acquire EXCL_ACCESS | resv-acquire rtype=2 | success | | |
| Host B read (EXCL_ACCESS) | dd read | RESERVATION_CONFLICT | | |
| Host B preempt | resv-acquire racqa=2 | success | | |

This table is your empirical verification of the access rules in `nvmf_ns_reservation_request_check`.

---

## Cross-reference with code

After the lab, open `lib/nvmf/subsystem.c` and find `nvmf_ns_reservation_request_check`.
For each test you ran, find the corresponding code path that produced the result you saw.

This connects the lab evidence to the implementation.

---

## What matters most after Day 16

1. WRITE_EXCLUSIVE allows reads by non-holders, blocks writes. Confirmed empirically.
2. EXCLUSIVE_ACCESS blocks all I/O by non-holders. Confirmed empirically.
3. Registration is separate from reservation — a non-holder can be a registrant.
4. Preempt is an atomic holder change — no gap between releasing old holder and setting new.
5. The `gen` counter increments on every PR state change — useful for detecting stale state.

---

## Suggested next step

Day 17: PTPL lab. Keep the setup from today but add a PTPL file to the namespace.
Exercise: acquire a reservation, restart the target, re-add the namespace with the
same PTPL file, verify the reservation survives.
