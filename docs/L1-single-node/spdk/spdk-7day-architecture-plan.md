# SPDK 7-Day Architecture Mini Plan

Goal: build a solid SPDK architecture model before diving into NVMf details.

## Day 1: Big Picture

Understand what SPDK is and why it exists.

Focus on:

- user-space storage stack
- polling instead of interrupt-driven/blocking model
- module/layered design
- difference from kernel storage path

Deliverable:

- one-page note: "What SPDK is, what problem it solves, and how it differs from Linux kernel storage"

## Day 2: Application Framework

Learn how an SPDK app starts, initializes subsystems, and exposes RPC.

Focus on:

- app startup flow
- initialization order
- shutdown flow
- JSON-RPC control plane

Practice:

- start `spdk_tgt`
- start `nvmf_tgt`
- inspect available RPCs

Deliverable:

- startup flow note from process launch to RPC-ready state

## Day 3: Thread / Reactor / Poller Model

This is the most important architecture concept.

Focus on:

- `spdk_thread`
- reactors
- pollers
- message passing
- why SPDK avoids blocking

You should be able to explain:

- SPDK thread is not the same as a POSIX thread
- work moves by messages, not locks first
- polling is central to performance model

Deliverable:

- diagram: reactor -> SPDK thread -> poller -> callback/message

## Day 4: I/O Channel Model

Understand `io_channel`, because many SPDK modules depend on it.

Focus on:

- per-thread resource model
- device/module context
- why channels exist
- how channels reduce contention

You should be able to explain:

- why one module does not store all runtime I/O state globally
- why each thread gets local context

Deliverable:

- short note: "What problem `io_channel` solves in SPDK"

## Day 5: bdev Framework

This is the architectural center of most SPDK storage services.

Focus on:

- what a bdev is
- descriptors
- claims
- I/O submit/complete model
- backend modules under bdev

Practice:

- create `Malloc`
- create `AIO`
- inspect bdevs with RPC

Deliverable:

- block diagram:
  app/service -> bdev layer -> backend module -> device/file

## Day 6: Read Core Code

Read selected files with architecture in mind, not line-by-line perfection.

Read:

- `lib/bdev/bdev.c`
- `lib/thread/*`
- `lib/event/*` if relevant in your tree

Focus on:

- object ownership
- callbacks
- polling/message boundaries
- abstraction boundaries

Deliverable:

- note listing the 10 most important structs/functions you found

## Day 7: Integrate The Model

Now connect framework to one real service, preferably NVMf.

Read lightly:

- `doc/nvmf.md`
- `lib/nvmf/ctrlr.c`
- `lib/nvmf/subsystem.c`

Goal is not feature mastery yet. Goal is to answer:

- how NVMf uses SPDK threads
- how NVMf uses bdev
- where subsystem state lives
- where namespace state lives

Deliverable:

- one architecture summary:
  "How an NVMf request moves through SPDK"

## What You Must Understand By The End

By day 7, you should be able to explain clearly:

- why SPDK is user-space and polling-based
- what reactors, SPDK threads, and pollers do
- what `io_channel` is for
- why `bdev` is the central abstraction
- how services like NVMf sit on top of bdev
- why SPDK code is organized around asynchronous callbacks and message passing

## Best Daily Routine

For each day:

- 30 to 45 min docs
- 45 to 60 min code reading
- 30 to 60 min hands-on practice
- 15 min write your own summary

## Suggested Output Files

Create these notes as you go:

- `day1-spdk-overview.md`
- `day3-thread-reactor-poller.md`
- `day4-io-channel.md`
- `day5-bdev-framework.md`
- `day7-nvmf-on-spdk.md`
