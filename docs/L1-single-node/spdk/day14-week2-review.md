# Day 14: Week 2 Review

## What this day covers

Consolidate everything from Week 2 into a clear mental model.

No new labs today. Write, draw, and explain.

---

## Review checklist

Go through each item. If you cannot explain it confidently, go back to the relevant
day note before continuing.

### From Day 8 (basic TCP target)

- [ ] What is the exact RPC sequence to export one bdev over TCP?
- [ ] What does `nvmf_subsystem_add_ns` do to the bdev? (what field changes?)
- [ ] What does `nvme id-ctrl` on the initiator show, and where does each field come from?

### From Day 9 (AIO bdev)

- [ ] What is the difference between malloc, AIO, and NVMe bdev from NVMf's perspective?
- [ ] What does the AIO bdev use to complete I/O asynchronously? (hint: poller + what syscall?)
- [ ] Does a write from the initiator survive a target restart with AIO? With malloc?

### From Day 10 (host ACLs)

- [ ] What are the three host ACL modes and how do you configure each?
- [ ] At what point in the connection lifecycle is the host NQN checked?
- [ ] Does removing a host from the allow list disconnect an active session?

### From Day 11 (ctrlr.c)

- [ ] What is the entry point for all NVMe commands?
- [ ] How does ctrlr.c distinguish admin queue commands from I/O queue commands?
- [ ] Where is the host NQN checked during connect?
- [ ] What does the PR conflict check read from `spdk_nvmf_ns`? Does it write anything?

### From Day 12 (subsystem.c)

- [ ] What is the exact sequence inside `spdk_nvmf_subsystem_add_ns_ext`?
- [ ] What error is returned if the bdev is already claimed?
- [ ] Why does namespace removal require a subsystem state transition?
- [ ] What thread owns PR state writes?
- [ ] When is PTPL loaded?

### From Day 13 (I/O trace)

- [ ] How many thread switches does a normal read command involve?
- [ ] How many thread switches does a PR RESERVE command involve?
- [ ] What are the two threads involved in a PR command round trip?

---

## Writing exercise 1: SPDK vs Linux nvmet dispatch

Write a plain-language comparison of how an I/O command reaches storage in SPDK
vs Linux nvmet. Aim for one page.

Suggested structure:

**Linux nvmet path:**

```
host sends NVMe command over TCP
  -> nvmet_tcp: receive and parse
  -> nvmet_req_execute
  -> nvmet_parse_io_cmd
  -> nvmet_bdev_execute (for block device namespaces)
  -> submit_bio / blk_execute_rq_nowait
  -> block layer, scheduler, driver
  -> interrupt / completion
  -> nvmet sends CQE to host
```

**SPDK nvmf path:**

```
(fill in from your Day 11–13 reading)
```

**Key differences:**

1. _______________
2. _______________
3. _______________

---

## Writing exercise 2: Why message passing at the subsystem boundary?

Answer this question in your own words (3–5 paragraphs):

> Why does SPDK send a message to the subsystem thread for PR updates instead of
> just taking a mutex on the namespace struct?

Guide:

- What would a mutex approach look like?
- What are the performance costs of a mutex on the hot I/O path?
- What does SPDK's threading model guarantee that makes a mutex unnecessary?
- What does the subsystem thread serialization give you that a per-namespace mutex would not?
- Is there a case where the message-passing approach has higher latency? (yes — PR commands)
  Is that an acceptable tradeoff?

---

## Writing exercise 3: One-page summary of the NVMf request lifecycle

Write a single-page summary covering:

1. how a host connects and what state is created
2. how an I/O command travels from transport to bdev and back
3. how a PR command travels from transport to subsystem thread and back
4. how a host disconnects and what state is cleaned up

Use actual function names where you know them. Leave blanks for anything you are
still unsure of — those are your remaining gaps.

---

## What your notes directory should look like after Week 2

```
docs/L1-single-node/spdk/
  day8-basic-tcp-target.md       lab + RPC sequence
  day9-aio-bdev.md               AIO bdev setup and behavior
  day10-host-acls.md             three ACL modes, code location
  day11-ctrlr-deep-read.md       annotated reading notes
  day12-subsystem-deep-read.md   annotated reading notes
  day13-io-trace.md              completed trace with actual function names
  day14-week2-review.md          this file + your written answers
```

If any of the day notes are incomplete, finish them before moving to Week 3.

---

## Gap check before Week 3

Week 3 is primarily lab work: multi-host, PR in practice, namespace visibility.
You need the following to be solid before starting:

**Must be solid:**

- [ ] Can set up a working TCP target from scratch in under 10 minutes
- [ ] Understand what the bdev claim is and why it matters for PR
- [ ] Know which thread owns PR state and why
- [ ] Know what PTPL does and when it is loaded

**Nice to have:**

- [ ] Can set breakpoints in `nvmf_ns_reservation_request_check` and see them fire
- [ ] Have seen `nvmf_ns_reservation_update` in the call stack at least once

---

## What matters most after Day 14

1. You have seen the complete NVMf stack from transport to bdev and back.
2. The message-passing model is not just an architectural preference — it is what allows
   SPDK to avoid mutexes on the hot I/O path entirely.
3. PR commands have inherently higher latency than I/O commands because of the
   cross-thread round trip. This is a known and accepted tradeoff.
4. You are ready for Week 3 lab work. The concepts are all in place.

---

## Suggested next step

Week 3, Day 15: multi-host lab. One subsystem, one namespace, two hosts connected
simultaneously. Verify both see the same NSID and are in the same PR domain.
