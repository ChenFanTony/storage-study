# Month 2 Day 2: Raft — Leader Election & Log Replication

## Learning Objectives
- Understand Raft leader election: RequestVote, term numbers, vote granting rules
- Follow a write from client to committed log entry at source level
- Understand log matching property and why it guarantees safety
- Know exactly what happens to in-flight writes during leader election
- Read TiKV's `raft-rs` source alongside the dissertation

---

## 1. Raft's Core Guarantee

Before reading source: understand the invariant Raft maintains.

```
Leader Completeness Property:
  If a log entry is committed in a given term, that entry will be present
  in the logs of all leaders for all higher-numbered terms.

This means:
  - A new leader always has all committed entries
  - A new leader never loses committed entries
  - Uncommitted entries CAN be lost during leader change

Safety: Raft never returns a different answer for a committed entry.
Liveness: Raft makes progress as long as a majority of servers are up.
```

---

## 2. Server States and Term Numbers

```
Server states:
  FOLLOWER  → CANDIDATE → LEADER
      ↑___________________________↓ (leader steps down)
      ↑_________↓ (election fails or sees higher-term leader)

Term number:
  - Monotonically increasing integer
  - Each election attempt increments term
  - If server sees message with higher term: immediately becomes follower
  - Stale messages (lower term) are rejected

State per server:
  currentTerm  — latest term seen (persistent)
  votedFor     — candidate voted for in currentTerm (persistent)
  log[]        — log entries (persistent)
  commitIndex  — highest committed index (volatile)
  lastApplied  — highest applied to state machine (volatile)
  nextIndex[]  — for leaders: next index to send to each follower
  matchIndex[] — for leaders: highest index known replicated to follower
```

---

## 3. Leader Election: Precise Protocol

```
Trigger: follower doesn't hear from leader within election timeout (150-300ms)

Candidate actions:
  1. Increment currentTerm
  2. Vote for self (votedFor = self)
  3. Reset election timer
  4. Send RequestVote RPCs to all other servers

RequestVote RPC arguments:
  term          — candidate's current term
  candidateId   — who is asking
  lastLogIndex  — index of candidate's last log entry
  lastLogTerm   — term of candidate's last log entry

Vote granting rules (server grants vote if ALL true):
  1. candidate.term >= server.currentTerm
  2. server hasn't already voted in this term (votedFor == null or candidateId)
  3. candidate's log is AT LEAST AS UP-TO-DATE as server's log

"At least as up-to-date" definition (critical for safety):
  if candidate.lastLogTerm > server.lastLogTerm: candidate wins
  if candidate.lastLogTerm == server.lastLogTerm:
    if candidate.lastLogIndex >= server.lastLogIndex: candidate wins
  else: server rejects

Why this matters:
  A server with all committed entries has a higher lastLogTerm/lastLogIndex
  A candidate that didn't receive all commits cannot win a majority vote
  → New leader always has all committed entries (Leader Completeness)
```

---

## 4. Log Replication: The Write Path

```
Client write path:
  1. Client sends write to leader
  2. Leader appends entry to its local log (not yet committed)
     entry = {term: currentTerm, index: nextIndex, data: clientData}
  3. Leader sends AppendEntries RPC to all followers in parallel

AppendEntries RPC arguments:
  term          — leader's currentTerm
  leaderId      — so followers can redirect clients
  prevLogIndex  — index of entry before new ones
  prevLogTerm   — term of entry at prevLogIndex
  entries[]     — new log entries to append (empty for heartbeat)
  leaderCommit  — leader's commitIndex

Follower AppendEntries handling:
  1. If term < currentTerm: reject (stale leader)
  2. Log consistency check:
     if log[prevLogIndex].term != prevLogTerm: reject (log mismatch)
     → leader decrements nextIndex[follower] and retries
  3. If consistency check passes:
     - Delete any conflicting entries (entries after prevLogIndex with wrong term)
     - Append new entries
     - Update commitIndex = min(leaderCommit, lastNewEntry)
     - Return success

Commit:
  Leader commits entry when stored on majority of servers
  (majority = (N/2 + 1) where N = cluster size)
  Leader updates commitIndex
  Leader applies committed entries to state machine
  Leader replies to client (success)

Follower commit:
  Followers learn of commit via next AppendEntries (leaderCommit field)
  Apply committed entries to state machine
```

---

## 5. Log Matching Property

This is the invariant that makes Raft safe:

```
Log Matching Property:
  If two entries in different logs have the same index and term,
  then the logs are identical in all entries up through that index.

Proof sketch:
  - Leader creates at most one entry per index per term
  - AppendEntries consistency check ensures follower's log matches
    leader's log at prevLogIndex before appending
  - By induction: if log[i] matches, log[0..i] matches

Consequence:
  Once a majority have accepted entry at index i with term t,
  any future leader (who must get votes from majority) will have
  entry at index i with term t → committed entries are never lost
```

---

## 6. What Happens to In-Flight Writes During Leader Election

This is the architect's critical question:

```
Scenario: 5-node cluster, leader has 3 uncommitted entries

Timeline:
  t=0: Leader appends entries A, B, C to local log
  t=1: Leader sends AppendEntries to followers 2, 3, 4, 5
  t=2: Followers 2, 3 receive entries (2 of 4 followers = not quorum yet)
  t=3: Leader crashes (before receiving majority acks)

State:
  Leader (crashed):  [A, B, C] — all uncommitted
  Follower 2:        [A, B, C] — all uncommitted
  Follower 3:        [A, B, C] — all uncommitted
  Follower 4:        []        — didn't receive
  Follower 5:        []        — didn't receive

Election:
  Any of 2, 3, 4, 5 can become leader
  Case 1: Follower 4 becomes leader (log = [])
    → Wins election (has same lastLogTerm as 4, 5 but higher term)
    → Wait — can follower 4 win? Its log is LESS up-to-date than 2, 3
    → Follower 4 needs votes from majority (3 of 4 remaining)
    → Followers 2, 3 will REJECT vote for follower 4 (follower 4's log
       is less up-to-date)
    → Follower 4 cannot win!

  Case 2: Follower 2 or 3 becomes leader (log = [A, B, C])
    → Can win majority (gets votes from 4, 5 who have shorter logs — 
       follower 2/3 is at least as up-to-date as them)
    → New leader has [A, B, C] but entries are UNCOMMITTED
    → New leader does NOT commit these entries immediately
    → New leader only commits entries from ITS CURRENT TERM
       (Raft's "leader only commits entries from current term" rule)
    → A, B, C may eventually get committed if a new write from current term
       replicates and the new leader includes them

Result for client:
  Client sent write A, B, C but got no acknowledgment (leader crashed)
  Client must retry → idempotency token required to prevent duplicates
  A, B, C may or may not end up committed (depends on election outcome)
  This is correct behavior: only after client gets ack can it assume committed
```

---

## 7. TiKV Source: Following the Write Path

```
TiKV uses raft-rs (Rust Raft library). Key files:

src/raft/raft.rs          — core Raft state machine
src/raft/log.rs           — RaftLog (append, find, commit)
src/raft/tracker.rs       — ProgressTracker (follower progress)

Read in order:
1. raft.rs: step() — main entry for all messages
2. raft.rs: handle_append_entries() — follower processes AppendEntries
3. raft.rs: maybe_commit() — leader checks if quorum reached
4. log.rs: maybe_commit() — updates commitIndex
5. raft.rs: bcast_append() — leader broadcasts to followers
```

```rust
// raft-rs: leader commits when majority have matchIndex >= entry index
fn maybe_commit(&mut self) -> bool {
    // Find the highest index replicated to majority:
    let mut mis: Vec<u64> = self.prs.iter()
        .map(|(_, pr)| pr.matched)
        .collect();
    mis.sort_unstable_by(|a, b| b.cmp(a));  // descending
    let mci = mis[self.quorum() - 1];        // majority index

    // Only commit if entry is from current term (safety rule):
    self.raft_log.maybe_commit(mci, self.term)
}

// Note: only commits entries from current term
// This prevents committing entries from previous terms that
// might be incorrectly assumed committed (Raft §5.4.2)
```

---

## 8. Hands-On: etcd Cluster Observation

```bash
# Install etcd
wget https://github.com/etcd-io/etcd/releases/download/v3.5.9/etcd-v3.5.9-linux-amd64.tar.gz
tar xzf etcd-v3.5.9-linux-amd64.tar.gz

# Start 3-node cluster (3 terminals)
# Node 1:
./etcd --name node1 \
    --initial-advertise-peer-urls http://127.0.0.1:2380 \
    --listen-peer-urls http://127.0.0.1:2380 \
    --listen-client-urls http://127.0.0.1:2379 \
    --advertise-client-urls http://127.0.0.1:2379 \
    --initial-cluster-token etcd-cluster-1 \
    --initial-cluster "node1=http://127.0.0.1:2380,node2=http://127.0.0.1:2382,node3=http://127.0.0.1:2384" \
    --initial-cluster-state new

# Node 2 (different ports):
./etcd --name node2 \
    --initial-advertise-peer-urls http://127.0.0.1:2382 \
    --listen-peer-urls http://127.0.0.1:2382 \
    --listen-client-urls http://127.0.0.1:2381 \
    --advertise-client-urls http://127.0.0.1:2381 \
    --initial-cluster-token etcd-cluster-1 \
    --initial-cluster "node1=http://127.0.0.1:2380,node2=http://127.0.0.1:2382,node3=http://127.0.0.1:2384" \
    --initial-cluster-state new

# Node 3 similarly on ports 2384/2383

# Check status
./etcdctl --endpoints=127.0.0.1:2379 endpoint status --write-out=table

# Write and observe replication
./etcdctl --endpoints=127.0.0.1:2379 put /test/key1 "value1"
./etcdctl --endpoints=127.0.0.1:2381 get /test/key1   # reads from follower

# Force leader election (kill current leader)
# Find leader:
./etcdctl --endpoints=127.0.0.1:2379,127.0.0.1:2381,127.0.0.1:2383 \
    endpoint status --write-out=table | grep "true"
# Kill that node's process → observe election in other nodes' logs
# New leader should be elected within 300ms

# Observe Raft log index
./etcdctl --endpoints=127.0.0.1:2379 endpoint status --write-out=json \
    | python3 -m json.tool | grep -E "raftIndex|raftTerm"
```

---

## 9. Self-Check Questions

1. A 5-node Raft cluster. Leader crashes with 2 uncommitted entries. Can a follower with an empty log win the election? Why?
2. What is the Log Matching Property and why does it guarantee safety?
3. Why does Raft require a leader to only commit entries from its current term? What failure does this prevent?
4. A client sends a write to the leader. The leader appends to its log and sends AppendEntries to followers, then crashes before any follower responds. What happened to the write?
5. In a 5-node cluster, the minimum quorum for commit is 3. Two followers are partitioned from the leader. Can the cluster still accept writes?

## 10. Answers

1. No. A follower with empty log has lastLogIndex=0, lastLogTerm=0. Followers with the 2 uncommitted entries have lastLogIndex=2, lastLogTerm=currentTerm. When voting, those followers compare lastLogTerm/lastLogIndex and reject the empty-log candidate as less up-to-date. The empty-log follower can only get votes from other empty-log followers — not a majority. Only a follower with the uncommitted entries can win (though it still won't commit those entries until it adds an entry from its own term).
2. Log Matching Property: if two logs have an entry with the same (index, term), all preceding entries are identical. This holds because: (a) leader creates one entry per (index, term) and never overwrites, (b) AppendEntries consistency check ensures the follower's log matches at prevLogIndex before appending. By induction, once entries agree at position i, they agree at 0..i. This guarantees committed entries are never contradicted.
3. Raft §5.4.2: committing entries from previous terms is unsafe. Example: entry from term 2 is replicated to majority, but a new leader from term 3 could overwrite it before committing (if the new leader doesn't have it). By only committing entries from the current term, the new leader can only commit entries it knows are fully replicated under its own leadership, guaranteeing safety.
4. The write is lost from the client's perspective — the client received no acknowledgment (leader crashed). The entry may or may not survive depending on which follower becomes the new leader. If a follower with the entry becomes leader, it may eventually be committed; if a follower without it becomes leader, the entry will be overwritten. The client must retry with an idempotency token.
5. Yes — the leader + 2 connected followers = 3 nodes = quorum. The leader can still commit entries. The 2 partitioned followers cannot accept writes (they're not the leader), and they fall behind. When the partition heals, they receive missing entries via AppendEntries and catch up.

---

## Tomorrow: Day 3 — Raft: Log Compaction, Snapshots & Membership Changes

We cover snapshot transfer to lagging followers, log truncation, and
joint consensus for safely adding/removing cluster members.
