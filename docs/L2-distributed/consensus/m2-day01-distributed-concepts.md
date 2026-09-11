# Month 2 Day 1: Distributed Storage Foundations & Consensus Map

<!-- study-nav -->
[Next: Day 2 — Raft: Leader Election & Log Replication →](m2-day02-raft-leader-election.md)

## Context
You know single-node storage deeply. Before studying one consensus protocol in
detail, build a map of the problem space: what replication does, what consensus
adds, and how Paxos, Multi-Paxos, Raft, Viewstamped Replication, and Zab relate.
This prevents protocol-specific terms from obscuring the common ideas.
Timebox: 1.5 hours.

---

## 1. Consistency Models: Precise Definitions

Most engineers use these terms loosely. Architects must use them precisely
because the consistency model determines what applications can and cannot rely on.

### Linearizability (strongest)
```
Definition: every operation appears to take effect instantaneously at some
point between its invocation and its completion, and operations are ordered
consistently with real time.

In practice:
  - A read always returns the most recent completed write
  - Once a write is acknowledged, all subsequent reads see it (globally)
  - The system behaves as if there is a single copy of the data

Examples: etcd, ZooKeeper, Ceph with strong reads, S3 (since 2020)

Test: if write W completes before read R starts, R must return W's value.
      If two concurrent writes, some serialization exists — all readers
      see the same serialization.
```

### Sequential Consistency (weaker)
```
Definition: operations appear to execute in some sequential order consistent
with each process's program order, but not necessarily real time.

In practice:
  - Each client's operations appear in order (from that client's perspective)
  - But different clients may disagree on global ordering
  - A client may read stale data (not the latest write from another client)

Examples: Many distributed caches, some database secondaries
```

### Causal Consistency (weaker still)
```
Definition: writes that are causally related are seen by all processes
in the same order. Concurrent writes may be seen in different orders.

In practice:
  - If you write X and then read X and write Y based on it:
    any process that sees Y must also see X
  - "Happens-before" relationships are preserved
  - Unrelated writes can appear in any order

Examples: MongoDB causal sessions, some geo-distributed databases
```

### Eventual Consistency (weakest)
```
Definition: if no new updates are made, all replicas will eventually
converge to the same value.

In practice:
  - No timing guarantee on when convergence happens
  - Reads may return stale data indefinitely (during partition)
  - Concurrent writes may result in conflicts requiring resolution

Examples: Cassandra (tunable), DynamoDB (default reads), CouchDB
```

---

## 2. CAP Theorem: The Precise Statement

```
CAP Theorem (Gilbert & Lynch, 2002):
  In the presence of a network partition, a distributed system cannot
  simultaneously provide both:
    C: Consistency (linearizability)
    A: Availability (every request receives a response)

CRITICAL: "network partition" is not optional — networks do partition.
The theorem says: when a partition occurs, choose C or A.

What CAP does NOT say:
  ✗ You must always sacrifice C or A (only during partitions)
  ✗ CA systems are impossible (they just can't handle partitions)
  ✗ Consistency means ACID consistency (it means linearizability)

Storage system examples:
  CP (consistent, partition-tolerant, not always available):
    etcd, ZooKeeper, Ceph (strong mode)
    → During partition: some nodes refuse requests rather than return stale data

  AP (available, partition-tolerant, not always consistent):
    Cassandra (tunable), DynamoDB (default), CouchDB
    → During partition: all nodes accept requests but may diverge
```

---

## 3. PACELC: Beyond CAP

CAP only addresses partition behavior. PACELC adds the non-partition case:

```
PACELC:
  If Partition: choose between A (availability) and C (consistency)
  Else (no partition): choose between L (latency) and C (consistency)

Why it matters:
  Partitions are rare in well-operated datacenters.
  But latency vs consistency is a constant tradeoff.

  To get linearizability: writes must wait for quorum acknowledgment
    → higher latency (extra round trips to replicas)

  To get lower latency: acknowledge before full quorum
    → weaker consistency (risk of stale reads after failure)

Storage examples:
  etcd:    PA/EC — partition=available, else=consistent (waits for quorum)
  DynamoDB: PA/EL — partition=available, else=low latency (eventual)
  Spanner: PC/EC — partition=consistent (unavailable), else=consistent
           (uses TrueTime for external consistency across DCs)
```

---

## 4. Replication Is Not Consensus

Replication and consensus are related, but they are not synonyms.

```
Replication:
  Keep copies of data on multiple servers.

Consensus:
  Make non-faulty servers agree on one decision despite failures,
  delays, retries, and competing proposals.

Replicated state machine:
  Use consensus repeatedly to make every replica apply the same
  commands in the same order.
```

Copying a write to three servers is replication. It becomes a consensus
protocol only when the system also defines which value or order wins during
concurrency and failure, when a result is final, and how a recovering server
rejoins without changing an already-decided result.

Leader election alone is also not consensus. Election determines who may
coordinate decisions; the protocol must still preserve decisions across
leader changes.

---

## 5. From One Decision to a Replicated Log

This distinction explains why Raft visibly contains log replication while
basic Paxos appears not to.

```
Single-decree consensus:
  slot 7 → choose exactly one value

Replicated-log consensus:
  slot 1 → SET x=1
  slot 2 → SET y=2
  slot 3 → DELETE z

State-machine replication:
  Every replica applies the decided slots in the same order
  → every replica reaches the same state.
```

- Basic Paxos chooses one value for one slot.
- A sequence of Paxos instances creates a replicated log.
- Multi-Paxos makes that sequence efficient by using a stable leader.
- Raft specifies leader election, a contiguous replicated log, commit rules,
  and recovery as one integrated protocol.

Therefore, the useful comparison is **Raft versus Multi-Paxos**, not Raft
versus one instance of basic Paxos.

---

## 6. Consensus Algorithm Landscape

Start with the common problem, then learn how each protocol organizes it:

| Protocol | Primary abstraction | Leadership | How it forms an ordered log | Distinctive point |
|----------|---------------------|------------|-----------------------------|-------------------|
| Basic Paxos | One chosen value | Proposers compete by ballot | It does not by itself; one instance covers one slot | Minimal safety foundation |
| Multi-Paxos | Repeated ordered slots | A stable proposer normally acts as leader | Runs Phase 2 for each slot after establishing leadership | Efficient but many operational details are left to implementations |
| Raft | Contiguous replicated log | Explicit election by term | Leader sends `AppendEntries`; followers accept only matching prefixes | Designed as a complete, understandable protocol |
| Viewstamped Replication | Replicated operations | Primary chosen for each view | Primary assigns operation numbers and replicas acknowledge them | View change explicitly transfers the safe log |
| Zab | Atomic broadcast of transactions | Leader chosen for each epoch | Leader establishes a total order and broadcasts transactions | Designed for ZooKeeper's ordering and recovery needs |
| PBFT family | Byzantine-fault-tolerant decisions | Depends on the protocol/view | Replicas vote through additional phases before ordering requests | Handles malicious/arbitrary faults, unlike the crash-fault protocols above |

Paxos, Multi-Paxos, Raft, Viewstamped Replication, and Zab are usually studied
under a **crash-fault** model: a server may stop, restart, or become unreachable,
but it does not deliberately forge protocol messages. Byzantine protocols use
a stronger failure model and require more replicas and communication.

### Relationship map

```
Consensus
├── One decision
│   └── Basic Paxos
├── Ordered decisions / replicated state machine
│   ├── Multi-Paxos
│   ├── Raft
│   ├── Viewstamped Replication
│   └── Zab (atomic broadcast)
└── Byzantine-fault consensus
    └── PBFT and descendants
```

These protocols provide comparable safety outcomes in overlapping failure
models, but they are not the same algorithm. Their leader-change rules, log
shape, message flow, and amount of specification differ.

---

## 7. Shared Vocabulary Across Protocols

Names differ, but the underlying roles are often comparable:

| General idea | Raft | Multi-Paxos | Viewstamped Replication | Zab |
|--------------|------|-------------|--------------------------|-----|
| Leadership generation | Term | Ballot/proposal number | View | Epoch |
| Ordered position | Log index | Slot | Operation number | Transaction ID/counter |
| Normal replication | `AppendEntries` | `Accept` for a slot | `Prepare`/`PrepareOK` | Broadcast proposal/ack |
| Leader-change mechanism | `RequestVote` plus log check | Phase 1 plus recovery | View change | Discovery and synchronization |
| Finality | Entry committed | Value chosen | Operation committed | Transaction committed |

Important: these are conceptual correspondences, not identical RPCs. For
example, Raft's `RequestVote` does not perform the same recovery work as Paxos
Phase 1. Raft restricts who can win; a Multi-Paxos leader discovers accepted
values and completes or repairs slots.

Common terms used throughout this week:

```
Leader / Primary:
  The replica coordinating ordering during a leadership generation.

Follower / Backup / Acceptor:
  A server that persists and acknowledges protocol state. Exact powers
  depend on the algorithm.

Quorum:
  A set large enough to intersect another relevant quorum. Majority
  quorums are common: floor(N/2) + 1.

Term / Ballot / View / Epoch:
  A monotonically ordered leadership generation used to reject stale work.

Log index / Slot / Operation number:
  A position in the ordered command history.

Committed / Chosen / Decided:
  The protocol's point of no return: future valid leaders must preserve
  the result. "Stored on one replica" is not the same as committed.
```

---

## 8. Recommended Learning Order

```
1. Consistency, failure models, quorum intersection
2. Replication versus consensus
3. Single decision versus a sequence of log slots
4. Algorithm landscape and terminology mapping          ← today
5. Raft election, replication, and recovery              ← Days 2–4
6. Basic Paxos, Multi-Paxos, VR, and Zab comparison       ← Days 5–6
7. Choose a protocol from workload and failure needs      ← Day 7
```

Raft is studied in detail first because its specification exposes the complete
replicated-log lifecycle clearly. Paxos then reveals the smaller consensus
primitive and how Multi-Paxos builds a similar service from repeated slots.
The overview comes first so this teaching order is not mistaken for a taxonomy.

---

## 9. Gap-Fill Worksheet

Answer these before proceeding to Day 2:

| Question | Precise Answer |
|----------|----------------|
| What is the difference between replication and consensus? | |
| What is the difference between single-decree Paxos and Multi-Paxos? | |
| Why is Raft usually compared with Multi-Paxos rather than basic Paxos? | |
| What do a Raft log index and a Multi-Paxos slot represent? | |
| Why is electing a leader insufficient to preserve committed data? | |
| Which failure assumption separates Raft/Paxos from PBFT-style protocols? | |

---

## 10. Answers

1. Replication creates multiple copies. Consensus supplies rules that make
   replicas choose one safe result or order despite concurrency and failures.
2. Single-decree Paxos chooses one value. Multi-Paxos uses ordered Paxos slots
   plus stable leadership to implement an efficient stream of decisions.
3. Raft and Multi-Paxos both implement a replicated command log. One basic
   Paxos instance decides only one value for one slot.
4. Both identify one position in the ordered command history.
5. A new leader must preserve decisions made before it was elected. That
   requires log/accepted-value eligibility and recovery rules, not merely a
   mechanism for selecting a live server.
6. Raft and ordinary Paxos assume crash faults. PBFT-style protocols also
   account for Byzantine servers that behave arbitrarily or maliciously.

---

## Tomorrow: Day 2 — Raft: Leader Election & Log Replication

With the algorithm map established, we read Ongaro's dissertation Chapters
3–4 and trace a write from client to committed log entry, including what
happens during leader election with in-flight writes.
