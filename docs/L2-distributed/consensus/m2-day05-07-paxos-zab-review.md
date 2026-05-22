# Month 2 Day 5: Paxos Variants & Multi-Paxos

## Learning Objectives
- Understand Paxos Phase 1 and Phase 2 precisely
- Understand Multi-Paxos's optimization for stable leaders
- Map Multi-Paxos to Raft's steady-state behavior
- Know why Google chose Paxos (Chubby) and what problems they hit

---

## 1. Basic Paxos: Two Phases

Paxos solves consensus for a single value (single-decree Paxos).

```
Roles:
  Proposer: tries to get a value accepted
  Acceptor: votes on proposals
  Learner: learns the decided value
  (One server can play all roles)

Phase 1: Prepare (leader election equivalent)
  Proposer picks proposal number N (must be unique, monotonically increasing)
  Sends Prepare(N) to majority of acceptors

  Acceptor responds to Prepare(N):
    If N > any previously promised proposal number:
      Promise: "I won't accept proposals numbered < N"
      Return: (highest_accepted_number, highest_accepted_value) if any
    Else: reject

Phase 2: Accept (log replication equivalent)
  If proposer receives promises from majority:
    Choose value V:
      If any acceptor returned a previously accepted value:
        V = value with highest accepted proposal number
        (must respect already-accepted values for safety)
      Else: V = proposer's own value
    Send Accept(N, V) to majority of acceptors

  Acceptor responds to Accept(N, V):
    If N >= promised proposal number: accept, record (N, V)
    Else: reject

Commit:
  Value V is decided when majority accepts (N, V)
  Learners are notified
```

### Why Phase 1 must respect previously accepted values

```
Safety scenario:
  Round 1: Proposer A gets value X accepted by acceptors 1, 2 (majority of 3)
  Round 2: Proposer B starts new round (higher proposal number)
  B receives promises from acceptors 2, 3
  Acceptor 2 tells B: "I previously accepted X"
  B MUST use X as its value (even though B wants Y)

Why: X might already be decided (if A got acks from 1 and 2).
  If B uses Y, and X is decided, we'd have two different decisions.
  Paxos prevents this: if any acceptor has accepted a value,
  proposers must continue with that value.
```

---

## 2. Multi-Paxos: Optimizing for Stable Leaders

Basic Paxos requires 2 round trips per value — expensive for a stream of values (log entries).

```
Multi-Paxos insight:
  If one proposer wins Phase 1 with proposal N:
  It can skip Phase 1 for subsequent values (same N covers all future slots)
  Only Phase 2 needed per log entry in steady state

Steady-state Multi-Paxos:
  Leader sends Accept(N, V, slot_i) for each new value
  Acceptors respond
  No Prepare round needed until leader changes

This is exactly Raft's steady-state behavior:
  Raft leader: runs Phase 2 (AppendEntries) for each entry
  Raft election: runs Phase 1 equivalent (RequestVote + log comparison)
  Raft term number: Paxos proposal number
  Raft log index: Paxos slot number
```

---

## 3. Paxos Made Live: Google's Experience

```
Google built Chubby (distributed lock service) using Paxos.
Key lessons from "Paxos Made Live" (Chandra et al., 2007):

1. Multi-Paxos is underspecified
   The paper doesn't describe: leader election, log management,
   snapshot, membership changes. All must be designed.

2. Disk failures are tricky
   Acceptor must persist (promised_number, accepted_value).
   Disk corruption can violate safety — need checksums + repair.

3. Master leases for read performance
   Same as Raft leader lease: master gets lease, serves reads locally.
   Requires clock synchronization assumption.

4. Epoch numbers for correctness
   Each master epoch has a unique number.
   Prevents old master from interfering with new master.
   Same as Raft term numbers.

5. Membership changes require care
   Same split-brain problem as Raft.
   Google used a "simple" approach: reconfigure through Paxos log.
```

---

## 4. Multi-Paxos vs Raft: Key Differences

| Aspect | Multi-Paxos | Raft |
|--------|-------------|------|
| Leader election | Any node can propose (concurrent proposers possible) | Explicit election, one candidate at a time |
| Log holes | Possible (slots can be accepted out of order) | Not possible (log is always contiguous) |
| Leader completeness | Must query previous slots to fill holes | New leader always has all committed entries |
| Specification completeness | Underspecified (left to implementer) | Fully specified (dissertation covers all cases) |
| Implementation complexity | Higher (handle holes, concurrent proposers) | Lower (Raft designed for understandability) |

---

## 5. Self-Check

1. In basic Paxos, why must a new proposer use the previously accepted value if any acceptor reports one?
2. Multi-Paxos reduces to one round trip per log entry in steady state. What event forces a return to two round trips?
3. What is a "log hole" in Multi-Paxos and why can't Raft have holes?

## 6. Answers

1. Safety: that value may already be decided (accepted by majority in a previous round). Using a different value would create two different committed values for the same slot — violating consensus. By continuing the previously accepted value, the new proposer either commits what was already decided or safely proposes a new value if nothing was decided.
2. Leader change. When a new leader takes over, it must run Phase 1 (Prepare) to learn about any previously accepted values in all slots it hasn't seen. Only after Phase 1 completes can it resume Phase 2-only operation.
3. A log hole is a slot that hasn't been decided yet while later slots have been decided. In Multi-Paxos, a leader might accept slot 5 and 7 but not 6 (if the Phase 2 for slot 6 was lost). Raft prevents holes because AppendEntries requires prevLogIndex/prevLogTerm consistency — entry N+1 can't be accepted without entry N, so the log is always a contiguous prefix.

---

# Month 2 Day 6: Viewstamped Replication & ZooKeeper's Zab

## Learning Objectives
- Understand Viewstamped Replication's view change protocol
- Understand Zab's epoch-based recovery and how it differs from Raft
- Know why ZooKeeper chose Zab over Paxos
- Understand ZooKeeper's consistency model (not linearizable — sequential)

---

## 1. Viewstamped Replication (VR)

VR (Liskov & Cowling, 2012 revision) is a replication protocol contemporaneous with Paxos.

```
VR key concepts:
  View: a period during which one replica is the primary
  View number: monotonically increasing (equivalent to Raft term)
  Op-number: log index (equivalent to Raft log index)
  Commit-number: highest committed op (equivalent to Raft commitIndex)

Normal operation (same as Raft steady state):
  Primary receives request
  Primary broadcasts Prepare(view, op-number, message) to backups
  Backups reply PrepareOK
  Primary commits when f+1 responses received (f = max failures)
  Primary sends Commit to backups

View change (equivalent to Raft leader election):
  Replica suspects primary → sends StartViewChange(view+1)
  When f+1 StartViewChange received → send DoViewChange to new primary
  DoViewChange includes: view, log, commit-number
  New primary selects log with highest (view, op-number) → same as Raft
  New primary broadcasts StartView(new_view, log, ...) → backups catch up
```

### Key difference from Raft
```
VR: new primary explicitly collects logs from f+1 replicas (DoViewChange)
    selects most complete log
    sends full log to all backups (StartView)

Raft: new leader doesn't collect logs from followers
      followers send AppendEntries responses → leader learns what they have
      leader sends missing entries to each follower individually

VR view change: O(n) messages to primary, then O(n) from primary
Raft election: O(n) RequestVote, then O(n) AppendEntries
Both: O(n) messages, similar complexity
```

---

## 2. Zab: ZooKeeper Atomic Broadcast

ZooKeeper uses Zab (not Paxos) for two reasons:
1. Zab provides total order broadcast (not just consensus on single values)
2. Zab's recovery is designed for ZooKeeper's specific semantics

```
Zab phases:
  Phase 0: Leader election (fast-leader-election algorithm)
  Phase 1: Discovery (equivalent to Paxos Phase 1)
  Phase 2: Synchronization (bring all followers up to date)
  Phase 3: Broadcast (steady-state, equivalent to Paxos Phase 2)

Key concept: epoch
  Each leader has an epoch number (equivalent to Raft term)
  Epoch is persistent — survives crashes
  All transactions tagged with (epoch, counter)
  
Zab vs Raft comparison:
  Both: leader-based, epoch/term numbered, majority quorum
  Zab: designed for ordered broadcast (FIFO delivery guarantee)
  Raft: designed for replicated state machine (log-based)
  Zab: explicit discovery phase queries followers for their state
  Raft: implicit — leader sends AppendEntries, learns follower state from responses
```

---

## 3. ZooKeeper Consistency: Sequential, Not Linearizable

```
ZooKeeper provides:
  ✓ Sequential consistency for writes (total order, all clients agree)
  ✓ FIFO client ordering (client's ops appear in order to all servers)
  ✗ NOT linearizable reads by default

Why not linearizable reads:
  ZooKeeper allows reads from any follower (not just leader)
  Followers may be slightly behind → stale reads possible
  This is intentional: read throughput scales with cluster size

sync() operation:
  Client calls sync() before read to ensure "read-your-writes":
  sync() flushes pending writes → follower catches up → then read
  After sync(): read returns data at least as recent as last write

Use case: ZooKeeper is used for coordination (locks, leader election)
  Readers typically call sync() before critical reads
  Or: clients send reads to leader (LREAD flag) for linearizability
```

---

## 4. Self-Check

1. ZooKeeper is often described as providing "sequential consistency." What does this mean for a client doing a write followed by a read to a different follower?
2. How does Zab's epoch recovery differ from Raft's term-based recovery?
3. Why did ZooKeeper's designers choose Zab over Paxos?

## 5. Answers

1. Sequential consistency means: all operations appear in some total order consistent with each client's program order. But a follower read immediately after a leader write may return stale data (before the write replicates). The client must call sync() first to ensure the follower has applied all previous writes before reading.
2. Zab's Phase 1 (Discovery) explicitly queries followers to find the highest epoch and transaction ID, then the new leader explicitly synchronizes all followers to that state. Raft's leader discovery is implicit — the election vote includes lastLogTerm/lastLogIndex, ensuring the winner has the most complete log, and then AppendEntries synchronizes followers. Both achieve the same safety guarantee, but Zab's approach is more explicit about the recovery phases.
3. Two reasons: (a) Multi-Paxos is underspecified and doesn't naturally describe total-order broadcast with FIFO delivery, which ZooKeeper needs. Zab was designed specifically for this semantic. (b) At the time ZooKeeper was designed (2007), Paxos implementations were complex and poorly documented. Zab provided a cleaner, better-specified protocol for ZooKeeper's specific requirements.

---

# Month 2 Day 7: Consensus Week Review

## Objective
Synthesize Days 1–6 into defensible architecture decisions.
Two deliverables: comparison matrix + design scenario answer.

---

## 1. Consensus Protocol Comparison Matrix

Fill this in from memory before checking:

| Aspect | Raft | Multi-Paxos | Zab |
|--------|------|-------------|-----|
| Leader election mechanism | | | |
| Log holes possible? | | | |
| Steady-state round trips per write | | | |
| Membership change approach | | | |
| Consistency model provided | | | |
| Best suited for | | | |
| Main production implementations | | | |

---

## 2. Design Scenario: Replicated Write-Ahead Log

**Brief:** You are building a distributed database. You need a replicated
write-ahead log (WAL) that:
- Provides linearizable writes
- Handles up to 2 node failures in a 5-node cluster
- Supports leader lease for low-latency reads
- Handles rolling upgrades (membership changes)
- Expected write rate: 50K entries/second, avg 1KB each

**Design questions:**

1. Choose a consensus protocol. Justify.
2. Quorum configuration: how many nodes, what quorum size?
3. Leader lease: implement it or use Read Index? Justify given the write rate.
4. How do you handle a lagging follower that's 10 million entries behind?
5. A node crashes and recovers. Walk through its recovery sequence.
6. You need to add a 6th node for maintenance. What is the safe procedure?

---

## 3. Reference Answers

**1. Protocol:** Raft. Reasons: fully specified (no need to design membership changes, log compaction, etc.); excellent production implementations (etcd's raft library, TiKV's raft-rs); 5-node cluster handles 2 failures (majority = 3); Raft's strong leader model is ideal for WAL (single writer). Multi-Paxos would work but requires more implementation work. Zab is designed for broadcast, not WAL.

**2. Quorum:** 5 nodes, majority quorum = 3. Tolerates 2 simultaneous failures. Alternative: 3 nodes (tolerates 1 failure, lower cost) — choose based on failure domain requirements.

**3. Leader lease vs Read Index:** At 50K writes/second, Read Index adds one RTT per read (read throughput limited). Leader lease is better at this write rate — but requires clock synchronization within the lease duration. Use leader lease with a conservative budget (e.g., 500ms lease, assume max 100ms clock skew). For financial data: Read Index (safety over performance).

**4. Lagging follower:** Leader has already snapshotted entries before position X. Send InstallSnapshot RPC with current state machine snapshot (~GB-scale), then resume AppendEntries from snapshot point. During snapshot transfer: follower is in StateSnapshot mode, leader doesn't send AppendEntries. After snapshot: resume normal log replication.

**5. Node recovery sequence:**
- Node starts, loads persistent state: currentTerm, votedFor, log
- Sends RequestVote or responds to AppendEntries
- If log is complete: joins as follower, receives AppendEntries to catch up
- If log is far behind: receives InstallSnapshot, then AppendEntries
- Begins serving reads after applying committed entries
- Announces readiness to client-facing layer

**6. Adding 6th node (safe procedure):**
- Add node in "learner" mode first (receives log but doesn't vote)
- Wait for learner to catch up to current commit index
- Then promote to full voter (single-server membership change)
- 6-node cluster now has majority = 4 (worse than 5-node which has majority = 3)
- Consider: add 7th node to restore original fault tolerance ratio

---

## Tomorrow: Day 8 — Erasure Coding: Reed-Solomon Math

Week 2 begins. We derive the mathematics of Reed-Solomon codes,
implement RS(4,2) from scratch, and understand why GF(2^8) is the field.
