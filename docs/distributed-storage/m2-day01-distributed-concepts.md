# Month 2 Day 1: Distributed Storage Concepts — Gap-Fill

## Context
You know single-node storage deeply. This is a directed audit of distributed
storage fundamentals — not a tutorial, but a precision check on the concepts
that underpin everything in Weeks 1–4. Timebox: 1.5 hours.

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

## 4. The Gap-Fill Worksheet

Answer these precisely before proceeding to Day 2.
If you can't answer precisely, research it now.

| Question | Precise Answer |
|----------|---------------|
| What is the difference between linearizability and serializability? | |
| S3 before 2020 was eventually consistent for some operations. Which ones and why? | |
| Ceph with default settings: CP or AP? What changes this? | |
| In Raft, what consistency does a leader read provide? A follower read? | |
| What is a "stale read" and under what conditions can it happen in a linearizable system? | |
| What is the difference between "read-your-writes" and linearizability? | |

---

## 5. Replication Terminology

Precise definitions for Week 1–2:

```
Leader / Primary:
  The single replica that accepts writes (in leader-based replication).
  Ensures single serialization point.

Follower / Secondary / Replica:
  Receives replicated writes from leader.
  May or may not serve reads (configurable in Raft).

Quorum:
  Minimum number of replicas that must acknowledge an operation
  for it to be considered committed.
  Write quorum W + Read quorum R > N (total replicas) ensures overlap.
  Standard: W = R = majority = (N/2 + 1)

Epoch / Term:
  A logical time period during which one leader is valid.
  In Raft: "term". In Zab: "epoch". In Paxos: "ballot number".
  Monotonically increasing; used to reject stale messages.

Log Index / LSN:
  Position in the replicated log. Each entry has a unique (term, index) pair.
  Used for log matching and recovery.

Commit Index:
  The highest log index known to be committed (replicated to majority).
  Entries at or below commit index are durable.
```

---

## 6. Self-Check

Before Day 2, answer without looking anything up:

1. A client writes to a Raft leader. The leader crashes after sending the write to 2 of 4 followers (quorum = 3). Is the write committed? What happens on leader re-election?

2. DynamoDB uses eventual consistency by default. A client writes key K then immediately reads K. Is the read guaranteed to return the new value? What must the client do to guarantee it?

3. Ceph by default uses primary-copy replication. Is this linearizable? What could break linearizability?

## 7. Answers

1. Not committed — only 2 of 4 followers received it, quorum is 3. On leader re-election, the new leader will not have this entry in its committed log. If the crashed leader restarts, its uncommitted entry may be overwritten if the new leader's log diverges. The write is lost from the client's perspective (no acknowledgment was sent, since the leader crashed before confirming to client).

2. Not guaranteed with default eventual consistency. The read may go to a different replica that hasn't received the write yet. To guarantee read-your-writes: use `ConsistentRead=True` in DynamoDB (strong consistency), or use the same session/token mechanism for causal consistency.

3. Ceph's primary-copy is linearizable for the single PG (placement group) level — the primary serializes all reads and writes. What could break it: reading from a replica (not primary) that hasn't received the latest write yet; split-brain during network partition if fence/epoch mechanism fails; stale reads from a primary that lost quorum but doesn't know it yet (solved by epoch/lease mechanism).

---

## Tomorrow: Day 2 — Raft: Leader Election & Log Replication

We read Ongaro's dissertation Chapters 3–4 and trace a write from client
to committed log entry, including what happens during leader election
with in-flight writes.
