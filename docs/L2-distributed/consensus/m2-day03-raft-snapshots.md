# Month 2 Day 3: Raft — Log Compaction, Snapshots & Membership Changes

<!-- study-nav -->
[← Previous: Day 2](m2-day02-raft-leader-election.md) | [Next: Day 4 — Raft: Production Failure Modes →](m2-day04-raft-failures.md)

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

A Raft snapshot is a checkpoint of the **applied state machine**, not merely a
copy of some log entries. It replaces a committed log prefix while preserving
the information Raft needs to reason about the boundary.

### 2.1 The mental model

Suppose entries through index 1000 are committed and applied:

```
Before compaction:

Raft log:
  [1][2][3] ... [999][1000][1001][1002]
                         ↑
                  lastApplied = 1000

State machine:
  x = 10
  y = 20
  ...
```

The member serializes the state produced by entries 1–1000 and records which
log entry produced that state:

```
Snapshot:
  lastIncludedIndex = 1000
  lastIncludedTerm  = 7
  state             = complete state machine after entry 1000
  configuration     = cluster membership at that point

After compaction:

  [snapshot through (index=1000, term=7)] [1001][1002][1003]...
```

The pair `(lastIncludedIndex, lastIncludedTerm)` acts like a virtual log entry
at the snapshot boundary. Raft still needs it for log-matching checks even
though the physical entries before that point have been deleted.

### 2.2 Snapshot safety invariant

A snapshot may include only entries that are both:

1. **Committed** — future valid leaders must preserve them.
2. **Applied** — their effects are already present in the captured state
   machine.

An uncommitted or unapplied entry must never be represented in the snapshot.
Snapshotting does not create a new consensus decision; it only changes the
local representation of decisions already made by Raft.

Each member chooses when to snapshot independently. Members can therefore have
snapshots at different indices without affecting protocol safety.

### 2.3 Safe creation and compaction order

A member creates a snapshot in this order:

```
1. Choose snapshot index i, where i <= lastApplied
2. Capture state machine state exactly through i
3. Record lastIncludedIndex=i, lastIncludedTerm=log[i].term,
   and the membership configuration
4. Write snapshot to a temporary file
5. Flush data and metadata; verify checksum if supported
6. Atomically publish the snapshot
7. Only now compact log entries covered by the durable snapshot
8. Retain entries after i for writes that occurred while snapshotting
```

The ordering is a crash-safety requirement:

| Crash point | Recovery result |
|-------------|-----------------|
| Before snapshot is durable | Ignore the partial snapshot; old log still exists |
| After snapshot is durable but before compaction | Load the snapshot; duplicate old log entries are harmless |
| After compaction | Safe because the durable snapshot replaces the deleted prefix |

Deleting the log first is unsafe: a crash during snapshot creation could leave
neither the old log nor a complete snapshot.

Implementations often retain a catch-up window of entries covered by the
snapshot. This uses extra space but lets a briefly delayed follower receive
ordinary `AppendEntries` rather than a large snapshot.

### 2.4 Writes can continue during snapshot creation

The state machine checkpoint must correspond to one precise applied index, but
the cluster does not have to stop accepting writes:

```
snapshot captures state through index 1000
                         |
                         v
snapshot worker:  [state at 1000] ------------------> durable snapshot
Raft continues:                       [1001][1002][1003]...
```

Copy-on-write or MVCC-capable storage engines can hold a stable read view while
new commands continue to apply. Entries after the chosen snapshot index remain
in the log and are replayed after restoring the snapshot.

### 2.5 Restart recovery

When a member restarts:

```
1. Load the newest complete, valid snapshot
2. Restore the state machine and membership configuration
3. Restore the snapshot boundary (lastIncludedIndex, lastIncludedTerm)
4. Set lastApplied and commitIndex to at least lastIncludedIndex
5. Replay committed log entries after the snapshot index
6. Resume normal AppendEntries processing
```

For example, loading a snapshot through 5000 and replaying entries 5001–5100
is equivalent to replaying entries 1–5100 from an empty state machine.

### 2.6 When the leader sends a snapshot

The leader normally catches up a follower by decrementing that follower's
`nextIndex` and retrying `AppendEntries`. A snapshot becomes necessary when:

```
nextIndex[follower] < leader.firstRetainedLogIndex
```

Example:

```
Leader snapshot:      through index 5000
Leader retained log:  5001..5100
Follower log:         0..100

Follower needs 101..5000, but the leader has compacted those entries.
AppendEntries cannot fill the gap.
```

The recovery path becomes:

```
Leader                                      Follower
  |                                             |
  |----------- InstallSnapshot ---------------->|
  |       state through index 5000              |
  |                                             | receive into temporary storage
  |                                             | verify and atomically install
  |<---------------- success -------------------|
  |                                             |
  |----------- AppendEntries ------------------>|
  |             entries 5001 onward             |
```

The extended Raft protocol describes these `InstallSnapshot` fields:

```
term              — leader's current term
leaderId          — identifies the current leader
lastIncludedIndex — highest log index represented by the snapshot
lastIncludedTerm  — term of the boundary entry
offset            — chunk offset for a large snapshot
data              — snapshot chunk
done              — whether this is the final chunk
```

Concrete Raft libraries may use a different transport or stream the database
outside the core Raft message, but the safety information is the same.

### 2.7 Installing a snapshot on a follower

A follower must not expose a partially received snapshot. It writes chunks to
temporary storage, verifies the completed image, then installs it atomically.

The follower processes a completed snapshot as follows:

```
1. Reject it if message.term < currentTerm
2. Step down if message.term is newer
3. Ignore it if lastIncludedIndex <= commitIndex (snapshot is stale)
4. Atomically replace the state machine with the snapshot state
5. Restore membership and advance commitIndex/lastApplied to the snapshot index
6. Reconcile the local log at the snapshot boundary:

   If local log contains (lastIncludedIndex, lastIncludedTerm):
     discard the prefix through lastIncludedIndex
     retain the suffix after it

   Otherwise:
     discard the local log
     begin again at the snapshot boundary

7. Acknowledge installation
8. Receive subsequent entries with AppendEntries
```

Keeping a suffix is safe only when the boundary entry matches. By Raft's Log
Matching Property, equal index and term imply that the preceding history is
the same. Later uncommitted suffix entries can still be repaired by normal
`AppendEntries` conflict handling.

Snapshot installation does not require a new quorum decision: the snapshot
already represents a committed prefix. A snapshot may also be behind the
leader's current commit index; the follower catches up with retained entries
after installation.

### 2.8 Performance tradeoffs

| Snapshot policy | Benefit | Cost |
|-----------------|---------|------|
| Frequent snapshots | Short recovery replay, smaller log | More checkpoint I/O and CPU |
| Infrequent snapshots | Less checkpoint overhead | Larger log, longer restart and memory pressure |
| Large retained catch-up window | Fewer snapshot transfers to mildly slow followers | More log storage |
| Small retained catch-up window | Less retained log | More large transfers |

The right threshold depends on state size, write rate, disk bandwidth, follower
latency, and acceptable restart time.

---

## 3. How etcd Maps These Ideas

etcd v3 separates several pieces that a simplified Raft diagram often draws as
one snapshot:

| etcd artifact | Purpose |
|---------------|---------|
| `member/snap/db` | bbolt state machine containing applied KV data and its consistent Raft index |
| WAL files | Recent Raft entries, hard state, checksums, and snapshot markers needed for restart |
| Transferred `*.snap.db` | Full backend checkpoint received when a follower is too far behind |
| `etcdctl snapshot save` output | Operator-managed point-in-time backup for disaster recovery |

The internal compaction flow is conceptually:

```go
// Conceptual flow; exact function names vary by etcd version.
if appliedIndex-lastSnapshotIndex >= snapshotCount {
    // Metadata says which committed/applied prefix the backend represents.
    raftSnapshot := createSnapshot(appliedIndex, appliedTerm, confState)

    persistSnapshotMarker(raftSnapshot) // make recovery boundary durable first

    compactIndex := appliedIndex - snapshotCatchUpEntries
    compactRaftLog(compactIndex)        // retain a follower catch-up window
}

// If a follower asks for an index older than the retained log:
if nextIndex[follower] < firstRetainedIndex {
    sendSnapshot(follower, backendCheckpoint, raftSnapshot.Metadata)
}
```

The `--snapshot-count` setting controls approximately how many applied
transactions trigger internal snapshot/compaction work.
`--snapshot-catchup-entries` controls the retained log window used to help
slow followers catch up without transferring the full backend.

### Internal snapshot versus backup

These operations have different purposes:

```
Internal Raft snapshot/compaction:
  - automatic member housekeeping
  - bounds retained Raft history
  - supports member restart and lagging-follower recovery
  - not intended as an operator's portable backup

etcdctl snapshot save backup.db:
  - downloads a point-in-time copy of the backend database
  - intended for disaster recovery
  - does NOT force the server's internal Raft snapshot threshold
  - does NOT directly trigger Raft log compaction
```

References:

- [etcd persistent storage files](https://etcd.io/docs/v3.7/learning/persistent-storage-files/)
- [etcd database snapshot procedure](https://etcd.io/docs/v3.7/tasks/operator/how-to-save-database/)
- [etcd server configuration fields](https://pkg.go.dev/go.etcd.io/etcd/server/v3/embed#Config)

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

# If node4 is behind the leader's retained log, observe an internal
# snapshot transfer in the server logs. Otherwise it catches up by log replay.

# Create an operator backup. This does NOT force internal Raft compaction.
./etcdctl --endpoints=127.0.0.1:2379 snapshot save /tmp/etcd-backup.db

# Validate and inspect the backup
./etcdutl --write-out=table snapshot status /tmp/etcd-backup.db
ls -lh /tmp/etcd-backup.db

# To observe internal snapshotting in a disposable lab, start members with
# small thresholds, generate enough writes, and inspect the server logs:
#   --snapshot-count=1000
#   --snapshot-catchup-entries=100

# Remove a member
./etcdctl --endpoints=127.0.0.1:2379 member remove <member-id>
```

---

## 6. Self-Check Questions

1. Why can't the leader just replay all log entries to a lagging follower instead of sending a snapshot?
2. What is the danger of switching directly from old to new cluster configuration without joint consensus?
3. etcd keeps `SnapshotCatchUpEntries` log entries after a snapshot. Why?
4. A follower receives an InstallSnapshot RPC. When may it retain the log suffix after the snapshot index, and when must it discard the local log?
5. During joint consensus, how many votes are needed to elect a leader for a 3→5 node cluster change?
6. Why must a member persist a snapshot before deleting the log entries it covers?
7. What is the difference between an internal etcd Raft snapshot and `etcdctl snapshot save`?

## 7. Answers

1. The leader may have already compacted (deleted) the old log entries. If a follower is 5 million entries behind and the leader only keeps 100K entries, there's no log to send. The snapshot is the only way to bring the follower to a consistent state.
2. Without joint consensus: some servers switch to the new config while others haven't yet. The old and new configs can form independent majorities simultaneously (split brain). Two leaders emerge — both accept writes, logs diverge, data corruption results.
3. Fast-moving followers don't need a full snapshot transfer if they're only slightly behind. Keeping some entries after the snapshot lets the leader send individual AppendEntries to followers that are close behind, avoiding expensive snapshot transfers for followers that just had a brief hiccup.
4. If the follower has an entry at `lastIncludedIndex` with the same `lastIncludedTerm`, Log Matching proves the prefix agrees, so it may discard that prefix and retain the suffix. If the boundary entry is missing or has a different term, the follower cannot prove continuity and must discard its local log, install the snapshot, and receive later entries again.
5. Joint config requires majority of both: old {A,B,C} = 2, new {A,B,C,D,E} = 3. A leader must get votes from at least 2 members of {A,B,C} AND at least 3 members of {A,B,C,D,E}. In practice: getting 3 votes from {A,B,C,D,E} automatically satisfies the old majority if those 3 include at least 2 from {A,B,C} — which is almost always the case.
6. If the member deletes the log first and crashes before the snapshot is durable, it loses both representations of the committed prefix. Persisting and atomically publishing the snapshot first makes every crash point recoverable; leftover duplicate log entries can be discarded later.
7. An internal snapshot is automatic protocol housekeeping used to compact Raft history and recover members. `etcdctl snapshot save` downloads a point-in-time backend database for operator-managed disaster recovery; it does not force the internal snapshot threshold or directly compact the Raft log.

---

## Tomorrow: Day 4 — Raft: Production Failure Modes

We study the 5 most common Raft production failures: leader lease, pre-vote,
check-quorum, and the subtle ways Raft can stall without losing safety.
