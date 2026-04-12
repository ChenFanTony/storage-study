# Month 2 Day 4: Raft — Production Failure Modes

## Learning Objectives
- Know the 5 most common Raft production failure patterns
- Understand leader lease, pre-vote, and check-quorum optimizations
- Read TiKV blog posts and etcd issue tracker for real incidents
- Know what each mitigation costs and when to apply it

---

## 1. Failure Mode 1: Disruptive Elections (Flapping)

### Problem
```
Scenario: a partitioned follower repeatedly disrupts the cluster.

Timeline:
  Server D is partitioned from the cluster (can't reach A, B, C leader)
  D doesn't hear heartbeats → election timeout → increments term → RequestVote
  D's RequestVote reaches A, B, C with higher term
  A, B, C see higher term → step down as leader → new election
  D loses election (can't get majority — it's partitioned)
  But: cluster was disrupted — leader stepped down unnecessarily
  D times out again → repeats → cluster never makes progress

This is a liveness failure: cluster is safe but unavailable.
```

### Mitigation: Pre-Vote
```
Pre-Vote adds a "would you vote for me?" phase before incrementing term:

Pre-RequestVote RPC:
  Before incrementing term, candidate asks: "Would you vote for me?"
  If server responds "yes": then proceed with real RequestVote (increment term)
  If server responds "no": don't disrupt current leader

A server responds "yes" to Pre-Vote only if:
  - It hasn't heard from a leader recently (election timeout passed)
  - OR candidate's log is at least as up-to-date

Result: partitioned server can't disrupt cluster
  - D sends Pre-Vote to A, B, C
  - A, B, C are hearing from leader → respond "no"
  - D doesn't increment term → no disruption
```

```go
// etcd/raft/raft.go
func (r *raft) campaign(t CampaignType) {
    if t == campaignPreElection {
        r.becomePreCandidate()
        voteMsg = pb.MsgPreVote
        // Don't increment term yet
        term = r.Term + 1  // hypothetical term
    } else {
        r.becomeCandidate()
        voteMsg = pb.MsgVote
        term = r.Term  // already incremented
    }
}
```

---

## 2. Failure Mode 2: Stale Leader Serving Reads

### Problem
```
Scenario: network partition creates a "deposed leader"

Timeline:
  5-node cluster: A (leader), B, C, D, E
  Partition: A isolated from B, C, D, E
  B, C, D, E elect new leader (say B)
  A doesn't know it's deposed (no messages reach it)
  Client reads from A → A serves stale data (B has newer writes)
  This violates linearizability!
```

### Mitigation: Leader Lease
```
Leader lease: leader tracks when it last received a quorum of heartbeat responses.
If lease hasn't expired (within election timeout): leader is still valid.
If lease expired: leader steps down before serving reads.

Assumption: clocks are synchronized within bounded skew.
Risk: if clock skew > election timeout, a "deposed" leader may think
      its lease is valid when it isn't.
TiKV uses leader lease with a conservative clock skew budget.

Alternative: Read Index (safer, higher latency)
  Before serving read: leader sends heartbeat, waits for quorum response.
  Only serves read after confirming it's still leader (quorum heard from it).
  Cost: one round trip per read → higher read latency.
  Benefit: doesn't rely on clock synchronization.
```

---

## 3. Failure Mode 3: Slow Follower Causes Commit Stall

### Problem
```
Scenario: one slow follower degrades write latency for the entire cluster.

3-node cluster: quorum = 2
Follower C is slow (high latency, loaded disk)
Leader needs ack from 1 follower (A or C) to commit.
If A acks quickly: commits fine.
If A is temporarily partitioned: leader waits for C → high latency.

5-node cluster: quorum = 3
If two followers are slow: leader must wait for both slow ones.
Write latency = max of (N/2+1) fastest followers.
```

### Mitigation: Follower Pipelining + Flow Control
```
Without pipelining:
  Leader sends entry → waits for ack → sends next entry
  RTT per entry → serialized, slow

With pipelining (Raft default):
  Leader sends entries without waiting for acks (up to maxInflight)
  Follower acks entries as they're received
  Leader advances nextIndex optimistically

Flow control (etcd):
  MaxInflightMsgs: max in-flight AppendEntries per follower
  If follower is slow: leader backs off (reduces MaxInflightMsgs)
  Prevents overwhelming slow follower with retransmissions
```

---

## 4. Failure Mode 4: Log Divergence After Network Partition

### Problem
```
Scenario: minority leader continues accepting writes during partition.

5-node cluster, quorum = 3:
  Partition: {A (leader), B} | {C, D, E}
  A continues accepting writes (thinks it's leader, has 2 nodes)
  BUT: A can't commit! (only 2 of 5 = no quorum)
  A buffers writes in its log but can't commit them.
  C, D, E elect new leader (say C).
  C commits new writes.
  Partition heals: A (old leader) receives higher-term message from C.
  A steps down, reverts uncommitted entries, follows C.
  A's buffered uncommitted writes are DISCARDED.

Result: no data loss (A's writes were never committed/acked to client).
But: A was serving reads from its stale log during partition!
```

### Mitigation: Check-Quorum
```
Check-quorum: leader steps down if it hasn't heard from majority recently.

Leader periodically checks: have I received responses from majority lately?
If not (within election timeout): step down → become follower.
Now partitioned leader refuses to serve reads rather than serving stale data.

etcd config:
HeartbeatTick: how often leader sends heartbeats
ElectionTick: how long without heartbeat before follower starts election
check_quorum: leader steps down if no quorum response within ElectionTick
```

---

## 5. Failure Mode 5: Thundering Herd on Leader Recovery

### Problem
```
Scenario: leader restarts after crash.

Timeline:
  Leader crashes, all followers start election timers simultaneously.
  Multiple followers time out within same window → multiple candidates.
  Split votes: A votes for itself, B votes for itself, C votes for B.
  No majority → re-election → repeat.
  Can take many rounds before a leader is elected.
```

### Mitigation: Randomized Election Timeout
```
Each server randomizes its election timeout independently:
  [150ms, 300ms] — random value in this range.

Result:
  One server almost always times out first → sends RequestVote.
  Others hear RequestVote → reset their timers.
  First candidate usually wins before others time out.
  Probability of split vote dramatically reduced.

Still possible: two servers with nearly identical timeouts.
But: with randomization, expected elections to converge = ~1.5.
```

---

## 6. Production Configuration Reference

```yaml
# etcd production Raft tuning
heartbeat-interval: 100ms      # how often leader sends heartbeats
election-timeout: 1000ms       # follower waits this long before election
                                # must be >> heartbeat-interval
                                # typically 10× heartbeat

# TiKV raft-store configuration
raft-base-tick-interval: 1s
raft-heartbeat-ticks: 2        # heartbeat every 2 ticks = 2s
raft-election-timeout-ticks: 10 # election after 10 ticks = 10s

# Key invariant: election-timeout >> heartbeat-interval
# Too small: spurious elections (network jitter looks like leader failure)
# Too large: slow failure detection (leader takes long to be replaced)
```

---

## 7. Self-Check Questions

1. A 5-node cluster has one node partitioned. That node keeps timing out and trying to start elections. What mitigation prevents this from disrupting the cluster?
2. What is the difference between leader lease and Read Index for linearizable reads? Which is safer?
3. Check-quorum causes a leader to step down if it can't hear from majority. What problem does this solve?
4. Why does Raft use randomized election timeouts instead of a fixed timeout?
5. A leader is buffering 1000 uncommitted writes (partition, no quorum). The partition heals and a new leader was elected during the partition. What happens to those 1000 writes?

## 8. Answers

1. Pre-Vote. Before incrementing its term, the partitioned node sends Pre-RequestVote. Other nodes respond "no" (they're hearing from the current leader). The partitioned node doesn't increment its term and doesn't disrupt the cluster.
2. Leader lease: leader assumes it's still valid based on last quorum response time — relies on clock synchronization, lower latency (no extra round trip). Read Index: leader confirms it's still leader by getting a quorum heartbeat response before serving each read — doesn't rely on clocks, higher latency (one extra RTT). Read Index is safer; leader lease is a performance optimization with a correctness risk if clocks are skewed beyond the budget.
3. Without check-quorum: a partitioned leader thinks it's still leader and serves reads from its stale log — violating linearizability. With check-quorum: the partitioned leader detects it can't hear from majority, steps down, and refuses to serve reads. Clients are redirected to the new leader.
4. Fixed timeouts: if all servers crash simultaneously and restart, they all start election timers simultaneously — guaranteed split vote, multiple rounds needed. Randomized: one server almost always times out first, wins election before others time out. Reduces mean time to elect a leader from O(elections) to O(1).
5. The 1000 uncommitted writes are discarded. When the partition heals, the old leader receives a higher-term AppendEntries from the new leader. Old leader steps down, discovers its log has entries not in the new leader's committed log, and overwrites them. The clients that sent those writes either already timed out or will receive errors — they must retry. No data loss (the writes were never committed or acked).

---

## Tomorrow: Day 5 — Paxos Variants & Multi-Paxos

We read Paxos Made Simple and Paxos Made Live, understand the two-phase
protocol precisely, and map Multi-Paxos to Raft's steady-state behavior.
