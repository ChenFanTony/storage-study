# Month 2 Day 3: Raft — Log Compaction, Snapshots & Membership Changes

## Learning Objectives
- Understand why log compaction is necessary and when it triggers
- Follow the snapshot creation and transfer protocol precisely
- Understand joint consensus for safe membership changes
- Read etcd's snapshot and membership change source code

---

## 1. Why Log Compaction Is Necessary

```
Problem: Raft log grows unboundedly.
  Every write = one log entry
  After 1 year of 10K writes/second = 315 billion entries
  Recovery from log replay = impractical

Solution: Snapshot
  Periodically take a snapshot of the state machine
  Discard log entries before the snapshot point
  On recovery: load snapshot + replay only entries after snapshot
```

---

## 2. Snapshot Protocol

```
Each server independently decides when to snapshot:
  - When log grows beyond threshold (e.g., 100MB)
  - No coordination required — each server snapshots independently

Snapshot contents:
  - Last included index: highest log index covered by snapshot
  - Last included term: term of that entry
  - State machine state: complete state at that point

After snapshot:
  - Delete log entries up to last included index
  - Keep snapshot file on disk

Log structure after snapshot:
  [snapshot: covers index 0-1000] [log entries: 1001, 1002, 1003, ...]
```

### Snapshot transfer to lagging followers

```
Scenario: follower is far behind (crashed for days, just rejoined)
  Leader's log: entries 5001..5100 (entries 0-5000 discarded, snapshot exists)
  Follower's log: entries 0..100 (needs 101..5000 which leader doesn't have)

Solution: leader sends snapshot to follower (InstallSnapshot RPC)

InstallSnapshot RPC arguments:
  term              — leader's current term
  leaderId
  lastIncludedIndex — snapshot covers up to this index
  lastIncludedTerm  — term of last included entry
  offset            — byte offset of chunk (for large snapshots)
  data              — raw bytes of snapshot chunk
  done              — true if last chunk

Follower actions on receiving InstallSnapshot:
  1. If term < currentTerm: reject
  2. If snapshot is already in follower's log: just discard up to that point
  3. Otherwise: save snapshot, discard entire log, reset state machine
  4. Reply with current term

Performance concern:
  Snapshot transfer can be large (gigabytes for large state machines)
  Uses chunked transfer — leader sends multiple InstallSnapshot RPCs
  Follower applies snapshot atomically (all chunks received, then apply)
```

---

## 3. etcd Snapshot Source

```go
// etcd/server/etcdserver/server.go

// Trigger snapshot when log exceeds threshold
func (s *EtcdServer) snapshot(snapi uint64, confState raftpb.ConfState) {
    // 1. Get state machine snapshot (V3 store)
    d, err := s.v3backend.Snapshot()

    // 2. Create Raft snapshot metadata
    snap, err := s.r.raftStorage.CreateSnapshot(snapi, &confState, d)

    // 3. Save to disk
    s.r.storage.SaveSnap(snap)

    // 4. Compact log up to snapshot index
    s.r.raftStorage.Compact(snapi - s.Cfg.SnapshotCatchUpEntries)
    // SnapshotCatchUpEntries: keep some entries after snapshot
    // so fast followers don't need full snapshot transfer
}

// etcd/raft/raft.go: maybeSendSnapshot
// Leader detects follower needs snapshot when:
// nextIndex[follower] <= log.firstIndex() (leader doesn't have those entries)
func (r *raft) maybeSendSnapshot(to uint64, pr *tracker.Progress) bool {
    if pr.State != tracker.StateProbe {
        return false
    }
    snapshot := r.RaftLog.snapshot  // load from storage
    // Send InstallSnapshot RPC to follower
    r.send(pb.Message{
        To:       to,
        Type:     pb.MsgSnap,
        Snapshot: snapshot,
    })
}
```

---

## 4. Membership Changes: Joint Consensus

Adding or removing servers from a Raft cluster is dangerous if done naively:

```
Dangerous: direct switch from old config to new config
  Old cluster: {A, B, C}   — majority = 2
  New cluster: {A, B, C, D, E} — majority = 3

  If A, B, C haven't all switched at same time:
    A, B might form majority under OLD config (quorum = 2)
    C, D, E might form majority under NEW config (quorum = 3)
    Two leaders possible → split brain

Raft solution: Joint Consensus (two-phase membership change)

Phase 1: Enter joint configuration C_old,new
  - Log entry: "switch to joint config"
  - During joint config: majority requires quorum of BOTH old AND new config
  - A decision requires majority of {A,B,C} AND majority of {A,B,C,D,E}
  - Only one leader possible during joint config

Phase 2: Switch to new configuration C_new
  - Log entry: "switch to new config"
  - Once committed: joint config no longer needed
  - Cluster now uses only new config
```

```
Simpler alternative (etcd v3.4+): single-server membership changes
  Add or remove ONE server at a time
  A single-server change cannot create split brain
  (Adding one: majority increases by 1 — old quorum can't split from new)
  Practical and sufficient for most operations
```

---

## 5. Hands-On: etcd Membership Change

```bash
# Start 3-node cluster (from Day 2)
# Observe current member list
./etcdctl --endpoints=127.0.0.1:2379 member list --write-out=table

# Add a 4th member
./etcdctl --endpoints=127.0.0.1:2379 member add node4 \
    --peer-urls=http://127.0.0.1:2386

# Start node4 (must use --initial-cluster-state=existing)
./etcd --name node4 \
    --initial-advertise-peer-urls http://127.0.0.1:2386 \
    --listen-peer-urls http://127.0.0.1:2386 \
    --listen-client-urls http://127.0.0.1:2385 \
    --advertise-client-urls http://127.0.0.1:2385 \
    --initial-cluster "node1=http://127.0.0.1:2380,...,node4=http://127.0.0.1:2386" \
    --initial-cluster-state existing

# Observe: node4 receives snapshot from leader (check logs for "sent snapshot")

# Force a snapshot on the leader
./etcdctl --endpoints=127.0.0.1:2379 snapshot save /tmp/etcd-snapshot.db
# Check snapshot size
ls -lh /tmp/etcd-snapshot.db

# Remove a member
./etcdctl --endpoints=127.0.0.1:2379 member remove <member-id>
```

---

## 6. Self-Check Questions

1. Why can't the leader just replay all log entries to a lagging follower instead of sending a snapshot?
2. What is the danger of switching directly from old to new cluster configuration without joint consensus?
3. etcd keeps `SnapshotCatchUpEntries` log entries after a snapshot. Why?
4. A follower receives an InstallSnapshot RPC. Its local log has entries that conflict with the snapshot. What should it do?
5. During joint consensus, how many votes are needed to elect a leader for a 3→5 node cluster change?

## 7. Answers

1. The leader may have already compacted (deleted) the old log entries. If a follower is 5 million entries behind and the leader only keeps 100K entries, there's no log to send. The snapshot is the only way to bring the follower to a consistent state.
2. Without joint consensus: some servers switch to the new config while others haven't yet. The old and new configs can form independent majorities simultaneously (split brain). Two leaders emerge — both accept writes, logs diverge, data corruption results.
3. Fast-moving followers don't need a full snapshot transfer if they're only slightly behind. Keeping some entries after the snapshot lets the leader send individual AppendEntries to followers that are close behind, avoiding expensive snapshot transfers for followers that just had a brief hiccup.
4. Discard the entire local log. The snapshot represents a complete, committed state. Any local entries that conflict with the snapshot are by definition uncommitted (since the snapshot reached consensus) and must be discarded. The follower resets to the snapshot state and waits for subsequent AppendEntries.
5. Joint config requires majority of both: old {A,B,C} = 2, new {A,B,C,D,E} = 3. A leader must get votes from at least 2 members of {A,B,C} AND at least 3 members of {A,B,C,D,E}. In practice: getting 3 votes from {A,B,C,D,E} automatically satisfies the old majority if those 3 include at least 2 from {A,B,C} — which is almost always the case.

---

## Tomorrow: Day 4 — Raft: Production Failure Modes

We study the 5 most common Raft production failures: leader lease, pre-vote,
check-quorum, and the subtle ways Raft can stall without losing safety.
