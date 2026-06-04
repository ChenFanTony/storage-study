# DAOS — Distributed Asynchronous Object Storage: Architect Deep Reference

> Companion to `docs/architecture/all-flash-architecture.md` (DAOS in context of all-flash architecture).
> DAOS is deployed at Argonne Aurora, LUMI, MareNostrum 5 — the largest HPC systems.

---

## Section 0: Abbreviation and Terminology Reference

### Core Object Model

| Term | Meaning |
|------|---------|
| Pool | Administrative and fault domain unit; spans multiple storage servers; owns a slice of physical capacity on each target |
| Container | Namespace within a pool; owns its own object index; versioned; transactional; roughly analogous to a filesystem |
| Object | The fundamental storage unit; identified by a 128-bit object ID; data distributed across pool targets per its object class |
| dkey | Distribution key: top-level key within an object; determines which target shard stores the associated akeys/extents |
| akey | Attribute key: secondary key within a dkey; associated with actual data (byte array, single-value record, or array record) |
| Extent | A contiguous range within an array-type akey; analogous to a byte range in a file |
| VOS | Versioned Object Store — the per-target local storage engine managing all objects on one target's SCM + NVMe |
| Target | A single storage unit = one NVMe SSD + its paired SCM region; each server has multiple targets (one per NVMe) |
| Rank | A DAOS server process (one per physical server, or one per NUMA node on large servers) |
| Shard | One copy of an object on one target; an object has N shards distributed per its placement |

### Storage Hardware

| Term | Meaning |
|------|---------|
| SCM | Storage Class Memory — Intel Optane DIMM (NVDIMM) used as persistent byte-addressable memory; access in nanoseconds |
| PMem | Persistent Memory — synonym for SCM/Optane in DAOS documentation |
| ADR | Asynchronous DRAM Refresh — Intel CPU feature that flushes CPU cache lines to Optane on power-loss event; makes stores durable without explicit fsync |
| NVMe | NVMe SSD — bulk data capacity tier; access in microseconds via SPDK |
| SPDK | Storage Performance Development Kit — user-space NVMe driver from Intel; no kernel, no block layer |

### Networking

| Term | Meaning |
|------|---------|
| CaRT | Collective and RPC Transport — DAOS's messaging layer; sits on top of libfabric |
| libfabric / OFI | OpenFabrics Interfaces — portable network API supporting InfiniBand, RoCE, TCP |
| RDMA | Remote Direct Memory Access — data transferred directly between client and server memory, bypassing CPU on both ends |
| Bulk transfer | DAOS term for RDMA data movement (as opposed to RPC for control/metadata) |
| self-forwarder | Client that can act as a DAOS server for collective operations (reduces server load) |

### Transaction and Versioning

| Term | Meaning |
|------|---------|
| Epoch | A 64-bit timestamp used as a logical transaction ID; every write is tagged with an epoch |
| HLC | Hybrid Logical Clock — combines physical time with a logical counter; provides globally consistent ordering without distributed coordination |
| DTX | Distributed Transaction — DAOS's mechanism for atomic updates spanning multiple objects and targets |
| DTX leader | The target that coordinates a distributed transaction; holds the transaction record until commit |
| Snapshot | A point-in-time consistent view of a container at a specific epoch; read-only |
| Aggregation | Background process that garbage-collects overwritten/deleted versions from VOS to reclaim SCM/NVMe space |
| Conditional update | An update that succeeds only if a precondition holds (e.g., "write only if record doesn't exist") |

### Placement and Fault Tolerance

| Term | Meaning |
|------|---------|
| Object class | Specifies distribution (how many shards across how many targets) and redundancy (replication factor or EC scheme) |
| OC | Object Class abbreviation: e.g., OC_SX (single shard, no redundancy), OC_RP_2G1 (2-way replication, 1 group) |
| Placement map | Pool-level data structure encoding all targets and fault domain hierarchy; used to compute object placement |
| Redundancy group | Set of targets that collectively store one erasure-coded stripe or one replica set |
| EC | Erasure Coding — k data shards + p parity shards; tolerates p target failures; DAOS uses Reed-Solomon |
| Rebuild | Process of reconstructing lost object shards after a target or server failure |
| Reintegration | Re-adding a repaired target to the pool and migrating its data back |
| Degrade mode | Operating while a target is offline; reads use EC reconstruction or redundant replicas |
| Exclude | Administrative removal of a failed target from the pool placement map |
| Drain | Graceful removal of a target: migrate its data before exclusion |

### API and Access

| Term | Meaning |
|------|---------|
| libdaos | Client-side DAOS library; implements the DAOS native API |
| libioil | I/O interception library; intercepts POSIX calls (read/write/open) and routes them to DAOS; no code change needed |
| dfuse | DAOS FUSE driver; mounts a container as a POSIX filesystem; slower than libioil but more compatible |
| MPI-IO | Message Passing Interface I/O — parallel I/O standard used by HPC applications; DAOS has a native ROMIO driver |
| HDF5 DAOS VOL | Virtual Object Layer plugin for HDF5; maps HDF5 groups/datasets directly to DAOS objects (no POSIX) |
| DFS | DAOS File System — DAOS-native POSIX-compatible file namespace; used by libioil and dfuse |
| Array API | DAOS API for N-dimensional dense arrays; maps to HPC simulation data layout |
| KV API | Simple key-value store API on DAOS objects |

---

## Section 1: Architecture Overview

### 1.1 The Full Stack

```
┌──────────────────────────────────────────────────────────────────┐
│                         COMPUTE NODES                            │
│                                                                   │
│  Application → MPI-IO → DAOS ROMIO   ─┐                        │
│  Application → HDF5   → DAOS VOL     ─┤→ libdaos               │
│  Application → POSIX  → libioil       ─┤   (user-space client)  │
│  Application → POSIX  → dfuse → FUSE ─┘                        │
│                              │                                    │
│                    libfabric / OFI                                │
│                    (InfiniBand, RoCE, TCP)                        │
└──────────────────────────────────────────────────────────────────┘
                              │
                     RDMA for bulk data
                     RPC for metadata/control
                              │
┌──────────────────────────────────────────────────────────────────┐
│                      STORAGE NODES (Ranks)                       │
│                                                                   │
│  daos_server process (user-space)                                │
│    ├── CaRT: RPC dispatcher                                      │
│    ├── Pool service (raft-based metadata)                        │
│    ├── Container service                                         │
│    └── Per-target I/O engine (one per NVMe)                     │
│          ├── VOS (Versioned Object Store)                        │
│          │     ├── Object index (DBTREE on SCM)                  │
│          │     ├── Free space (on SCM)                           │
│          │     └── Data: SCM (hot/small) + NVMe (cold/large)    │
│          └── SPDK (user-space NVMe driver)                       │
└──────────────────────────────────────────────────────────────────┘
```

### 1.2 Why User-Space Everywhere

Traditional storage stacks have multiple kernel-crossing points on the I/O path:

```
Traditional (Lustre/NFS):
  application write()
  → VFS (kernel)
  → filesystem driver (kernel)
  → block layer (kernel)
  → NVMe driver (kernel)
  → DMA to NVMe

  On client:
  → socket (kernel)
  → TCP/IP stack (kernel)
  → NIC driver (kernel)
  → network

Each kernel crossing: ~1-5μs syscall overhead + possible context switch (5-50μs).
At 1M IOPS: 1M × 5μs = 5 seconds/second spent in kernel overhead alone.

DAOS:
  application (libdaos native) or interception (libioil):
  → libdaos: user-space object mapping
  → libfabric: user-space RDMA post
  → NIC DMA (no CPU involved for bulk data)

  On server:
  → CaRT: user-space RPC dispatch (poll loop, no sleep/wake)
  → VOS: user-space object store
  → SPDK: user-space NVMe submission (no kernel, direct PCIe MMIO)

Kernel crossing count: ZERO on data path.
Result: 1-10μs end-to-end latency for small I/O; < 100μs for large I/O.
```

### 1.3 Pool Service — Raft-Based Metadata

The pool service manages pool-level metadata (target membership, placement map) using Raft consensus:

```
Pool service replicas: typically 3 or 5 servers run the pool service.
Leader: handles all pool metadata requests.
Followers: replicate pool metadata via Raft log.
Election: if leader dies, Raft elects a new leader from followers.

Pool metadata stored in: pmemobj (on SCM) using PMDK
Contents:
  - Placement map: all ranks and targets, fault domain tree
  - Target health state: enabled, disabled, rebuilding
  - Pool properties: space quota, ACLs, redundancy settings

Requests handled by pool service:
  - Pool connect/disconnect (client gets pool handle)
  - Target exclude/reintegrate (admin operations)
  - Placement map queries (clients cache locally)
```

---

## Section 2: Object Model — Pool → Container → Object → dkey → akey

DAOS has no concept of a filesystem natively. Everything is an object. Filesystem semantics are layered on top.

### 2.1 Hierarchy

```
Pool (spans N storage servers)
  │
  ├── Container A (e.g., "training-data-v1")
  │     ├── Object 1 (e.g., inode table for DFS)
  │     ├── Object 2 (e.g., file data)
  │     │     ├── dkey "0"    (byte range 0..1MB)
  │     │     │     └── akey "data"  → byte array [0..1048576]
  │     │     └── dkey "1"    (byte range 1MB..2MB)
  │     │           └── akey "data"  → byte array [1048576..2097152]
  │     └── Object 3 (e.g., directory)
  │           └── dkey "."   → akey "mode" = 0755, akey "size" = 4096
  │
  └── Container B (e.g., "checkpoint-epoch-100")
        └── Objects...

Each container has its own epoch space (independent versioning).
A snapshot freezes one container's epoch — reads always return the snapshot's state.
```

### 2.2 Object ID Structure

```
Object ID: two 64-bit integers (oid.hi, oid.lo)

oid.hi encoding (upper 64 bits):
  bits 63-32: reserved or type-specific
  bits 31-16: feature bits (e.g., EC, replication)
  bits 15-0:  object class (OC_SX, OC_RP_2G1, OC_EC_4P2G1, etc.)

oid.lo: application-defined identifier (e.g., inode number for DFS)

Object class examples:
  OC_SX        — 1 shard, no redundancy (scratch data)
  OC_RP_2G1   — 2-way replication, 1 redundancy group
  OC_RP_3G1   — 3-way replication, 1 redundancy group
  OC_EC_2P1G1 — EC 2+1 (2 data + 1 parity), 1 group
  OC_EC_4P2G1 — EC 4+2 (4 data + 2 parity), 1 group
  OC_EC_8P2G8 — EC 8+2, 8 redundancy groups (large objects, full striping)

Number of targets used = (data_shards + parity_shards) × group_count
For OC_EC_8P2G8: (8+2) × 8 = 80 targets involved per object
```

### 2.3 dkey and akey — The Key Hierarchy

```
Object → dkeys → akeys → data records

dkey (distribution key):
  - Determines which target shard the associated akeys live on
  - The key is hashed: target_index = hash(dkey) % shard_count
  - Changing the dkey changes which target you talk to
  - Used for: file block offsets (DFS uses dkey = block_index), array dimensions

akey (attribute key):
  - Resides on the target determined by its parent dkey
  - Associated with actual data: a byte array, single-value, or array records
  - Can be iterated; supports conditional fetch (only if exists, only if epoch X)

Three value types per akey:
  1. Single-value: one value per epoch (scalar; latest epoch wins)
     Example: file inode attributes (mode, size, uid, gid)
  2. Array: fixed-record-size array with arbitrary indices
     Example: file data as array[byte_offset] = byte_value
  3. Multi-value: multiple variable-length values per akey (like a mini-map)

Practical mapping for DFS (DAOS filesystem):
  File inode object:
    dkey "/"       → akey "mode", "size", "uid", "gid", "mtime"  (single-value)
  File data object:
    dkey 0         → akey "data" → array record[0..65535]         (byte array, 64KB)
    dkey 1         → akey "data" → array record[0..65535]         (64KB)
    dkey N         → akey "data" → array record[...]
  Directory object:
    dkey "filename" → akey "oid_hi", "oid_lo"                     (entry → inode object)
```

---

## Section 3: VOS — Versioned Object Store

VOS is the most important internal component. It is the per-target local storage engine that manages all objects on one target's SCM and NVMe. Understanding VOS is understanding DAOS's I/O model.

### 3.1 VOS Internal Structure

```
VOS instance (one per target):

  SCM (PMem region, memory-mapped via PMDK/libpmemobj):
  ┌─────────────────────────────────────────────────────┐
  │ VOS superblock (root pointers)                      │
  │                                                     │
  │ Container index (btree of container UUIDs)          │
  │   └── Per-container VOS:                           │
  │         Object index (btree keyed by oid)           │
  │           └── Per-object:                          │
  │                 dkey tree (btree keyed by dkey)     │
  │                   └── Per-dkey:                    │
  │                         akey tree (btree)           │
  │                           └── Value / extent tree  │
  │                                 (epoch history)     │
  │                                                     │
  │ Free space allocator (for SCM objects)              │
  │ DTX table (in-flight distributed transactions)      │
  └─────────────────────────────────────────────────────┘

  NVMe (via SPDK blob store):
  ┌─────────────────────────────────────────────────────┐
  │ SPDK blobstore                                      │
  │   └── Blobs (one per object shard or extent)       │
  │         Large value data: written here              │
  │         Each blob has an NVMe extent map on SCM     │
  └─────────────────────────────────────────────────────┘
```

### 3.2 Why SCM as Primary Storage (Not a Cache)

Traditional designs use DRAM as a cache in front of storage. DAOS treats SCM differently:

```
Traditional cache design:
  Write → DRAM (volatile) → async flush to disk
  DRAM is NOT durable → need WAL/journal for crash safety
  WAL write = write amplification (write twice: WAL + data)

DAOS SCM design:
  SCM (Optane DIMM) is:
    a) byte-addressable (like DRAM, not block I/O)
    b) persistent (non-volatile, survives power loss)
    c) cache-line granularity access (no 512B or 4KB sector)
    d) protected by ADR: CPU cache flushes to SCM on power failure

  Write path:
    Client RDMA → server receives data into SCM address space
    pmem_memcpy_persist() writes to SCM + issues clflush + sfence
    After clflush+sfence: data is DURABLY on SCM — no journal needed
    Total latency: RDMA (~2μs) + pmem write (~500ns) = ~3-5μs

  No WAL because: the write to SCM IS the durable record.
  The pmdk API (pmemobj_alloc, TX_ADD) wraps undo-log inside SCM transactions
  so that partial writes within one pmemobj transaction are atomic.
  This replaces JBD2/XFS log for DAOS metadata.
```

### 3.3 VOS Epoch History and MVCC

```
Every update to an akey or extent is tagged with an epoch (the transaction's HLC timestamp).
VOS stores ALL versions until aggregation removes old ones.

Epoch chain for akey "size" in a file inode:
  epoch 100: size = 0          (file created)
  epoch 150: size = 4096       (first write)
  epoch 200: size = 8192       (second write)
  epoch 250: size = 16384      (third write)

Read at epoch 300 (latest): returns size = 16384
Read at epoch 175 (snapshot): returns size = 4096 (latest at or before epoch 175)

This is multi-version concurrency control (MVCC):
  Readers never block writers (they read at their snapshot epoch).
  Writers create new epoch entries; old ones coexist until aggregation.

Aggregation (background GC):
  VOS aggregation walks the epoch history and removes superseded versions.
  Keeps the most recent version plus any snapshot-pinned versions.
  Frees SCM/NVMe space used by old versions.
  Triggered: when SCM usage exceeds threshold, or on schedule.
  Impact: brief CPU spike; no I/O stall for foreground operations.
```

### 3.4 Small vs Large Values: SCM vs NVMe Routing

VOS automatically routes data between SCM and NVMe based on size:

```
Thresholds (configurable, defaults):
  < 4KB: stored entirely on SCM (in-line in the btree leaf or nearby SCM allocation)
  ≥ 4KB: stored on NVMe via SPDK blob; SCM holds only the extent map pointer

Why this threshold:
  SCM is fast but expensive (high $/GB).
  NVMe is slower but cheap (low $/GB).
  Small metadata and hot data: SCM for sub-microsecond access.
  Large bulk data: NVMe for cost efficiency (still μs, not ms).

Migration:
  Data written to SCM first (always) → async migration to NVMe in background.
  This is the "staging" tier: SCM absorbs burst writes instantly;
  NVMe receives data in large sequential writes (amortizes NVMe write overhead).

Practical effect on write latency:
  Small write (< 4KB): SCM path → 1-5μs
  Large write (> 1MB): data goes to NVMe → 20-100μs
  BUT: large writes use RDMA bulk transfer → DMA to NVMe in parallel
       with client sending data → effective latency hides NVMe write time
```

---

## Section 4: Network Layer — CaRT and RDMA

### 4.1 CaRT Architecture

CaRT (Collective and RPC Transport) is DAOS's messaging layer. It abstracts libfabric and adds:

```
CaRT provides:
  - RPC: request-response for small metadata/control operations
  - Bulk transfer: RDMA for large data (DAOS calls this "bulk")
  - Collective operations: broadcast, reduce (for cluster-wide ops)
  - Fault detection: heartbeat monitoring of ranks

Two operation modes:
  1. RPC (for I/O requests < ~4KB, metadata):
     Client: crt_req_create() → crt_req_send()
     Server: registered handler dispatched from poll loop (no sleep/wake)
     Latency: 1-5μs (NIC to NIC, polling both sides)

  2. Bulk transfer (for data > ~4KB):
     Client: register local memory region with libfabric
     Server: receives bulk handle (descriptor of client memory region)
     Server: crt_bulk_transfer() → NIC DMA pull directly from client memory
     CPU involvement: near-zero (DMA engine does the work)
     Latency: payload/bandwidth + 2-5μs RDMA overhead

Server-side threading model:
  Each target runs an xstream (execution stream = pinned OS thread).
  An xstream handles one target's I/O via a tight poll loop:
    while (running) {
      crt_progress()        // drain the RPC queue
      vos_io_submit()       // submit pending SPDK I/O
      spdk_nvme_process_completions()  // harvest NVMe completions
    }
  No blocking syscalls, no sleep, no context switch.
  One CPU core per target → core-to-NVMe ratio = 1:1.
```

### 4.2 Why RDMA Changes the Latency Model

```
Traditional distributed storage read (Lustre, NFS):
  Client: read() → VFS → kernel → socket send (copy to kernel socket buffer)
  Network: TCP/IP stack processing on both ends
  Server: socket recv → VFS write → block I/O → data copied to response buffer
  Client: data copied from socket buffer to application buffer
  Copies: typically 2-4 memory copies end-to-end
  Latency on 100GbE: ~50-200μs

DAOS RDMA read:
  Client: register application buffer as RDMA region; send read RPC with key + offset
  Server: receives RPC, looks up VOS extent → gets SCM pointer or NVMe offset
    If SCM: crt_bulk_transfer() → NIC reads from server SCM directly into CLIENT buffer
    If NVMe: SPDK async read → completion → NIC reads from server DRAM into CLIENT buffer
  Client: no memcpy; data lands directly in application buffer
  Copies: 0 (RDMA zero-copy)
  Latency on InfiniBand HDR (200Gb/s): 2-10μs for small; 20-50μs for large

The RDMA path requires:
  - RDMA-capable network: InfiniBand or RoCE (RDMA over Converged Ethernet)
  - Server memory registered with the NIC (pinned, not pageable)
  - Client memory registered with the NIC (or registered on first use)
  TCP fallback: available but ~10× higher latency (no RDMA)
```

---

## Section 5: Object Placement

### 5.1 How Objects Are Placed

Object placement in DAOS uses a deterministic algorithm based on the pool's placement map — no central routing table needed.

```
Inputs:
  - Object ID (oid.hi encodes object class)
  - Pool placement map (fault domain tree: DC → rack → blade → server → target)
  - Object class: e.g., OC_EC_4P2G1 = 4+1 EC, 1 redundancy group → needs 5 targets

Algorithm (simplified):
  1. Hash (object_id, container_id) → pseudo-random seed
  2. Walk the fault domain tree, selecting targets at each level
     ensuring fault domain separation (2 shards not on same failure domain)
  3. For OC_EC_4P2G1 with 5 targets: select 5 distinct targets,
     no two on the same server (fault domain = server)

Result: a deterministic set of targets for each object.
Any client can independently compute the same placement.
No metadata lookup needed for placement (unlike Ceph's CRUSH which needs the map).

Placement map version:
  When a target is excluded, the placement map version increments.
  Objects need to be "rebuilt" to new targets.
  Clients cache the placement map; refreshed when stale (version mismatch detected).
```

### 5.2 Fault Domain Awareness

```
Placement map encodes fault domain hierarchy:
  Datacenter → Rack → Blade → Server → Target

Object placement respects fault domains:
  For a 3-way replica: shard 0, 1, 2 placed on 3 different servers (or racks if configured)
  So: losing one entire server never loses more than 1 shard of any object

Object class and fault domain:
  OC_RP_3G1 with fault_domain=rack: 3 replicas on 3 different racks
    → survives one rack failure
  OC_EC_4P2G1 with fault_domain=server: 5 targets on 5 different servers
    → survives one server failure
  OC_EC_8P2G8 with 80 targets across many servers: survives multiple simultaneous failures

Comparing to Ceph CRUSH:
  Both use fault-domain-aware placement.
  Difference: DAOS placement is deterministic from object ID alone;
  Ceph CRUSH requires the CRUSH map and PG mapping lookups.
  DAOS clients need only the placement map (cached); no MDS or monitor contact per I/O.
```

---

## Section 6: Distributed Transactions (DTX)

### 6.1 Why DTX

A single logical operation can span multiple objects on multiple targets. Example: creating a file in DFS requires:
- Updating the directory object (add a directory entry)
- Creating the new inode object
- These are on different targets

DTX makes these atomic.

### 6.2 DTX Protocol

```
DTX uses a two-phase commit variant optimized for the DAOS trust model:

Roles:
  DTX leader: the target hosting the first object in the operation
  DTX participants: all other targets involved

Phase 1 (Prepare):
  Leader sends PREPARE RPCs to all participants.
  Each participant:
    - Acquires intent lock for its objects
    - Writes the update to VOS (epoch-tagged, but marked "tentative")
    - Records a DTX entry in its DTX table (on SCM)
    - Responds OK or ABORT

  Leader, upon all-OK:
    - Writes COMMITTED status to its own DTX entry (on SCM, persistent)
    - This is the commit point (analogous to JBD2 commit block)

Phase 2 (Commit):
  Leader sends COMMIT RPCs to all participants.
  Participants mark their DTX entries as committed.
  DTX entries cleaned up asynchronously.

Crash recovery:
  If leader crashes after writing COMMITTED:
    On recovery, leader re-sends COMMIT to participants (idempotent).
  If leader crashes before COMMITTED:
    Participants see "tentative" DTX entries.
    After timeout: participants query each other / abort.
    DTX entry on SCM is the single source of truth.

DTX is optimized for the common case (no conflicts):
  Latency: ~2 RTTs for commit (prepare + commit)
  Most HPC I/O is non-conflicting → DTX overhead is rare
  Single-target operations (one object, one target): no DTX overhead
```

### 6.3 HLC — Hybrid Logical Clock

```
DAOS needs globally ordered epochs without a centralized clock service.
Problem: physical clocks on different servers drift (NTP accuracy ~1ms).
Solution: Hybrid Logical Clock (HLC) from Kulkarni et al. 2014.

HLC(node) = max(physical_time_ms, max_received_HLC) + logical_counter

Properties:
  - HLC is always >= local physical time (never goes backward)
  - HLC advances on message receipt (causally consistent)
  - Max divergence from physical time: bounded (configurable, default 500ms)
  - No central coordinator needed

DAOS epoch = HLC timestamp:
  Every write gets the sender's HLC as its epoch.
  Snapshots are taken at current HLC.
  Reading a snapshot at epoch E: VOS returns latest version ≤ E for each key.
  Reads are always consistent relative to their epoch.

Example:
  Server A sends write at HLC=100.
  Server B receives, sees HLC_B=50 (B's clock is behind) → sets HLC_B=101.
  Server B's next operation uses epoch ≥ 101.
  Result: Server B's events are causally after Server A's writes.
```

---

## Section 7: Fault Tolerance and Rebuild

### 7.1 Erasure Coding in DAOS

```
DAOS EC object (e.g., OC_EC_4P2G1: k=4, p=1):
  Data is divided into cells (cell_size = stripe_size / k).
  One stripe: 4 data cells + 1 parity cell = 5 cells on 5 targets.

Write path (full stripe):
  Client sends 4 data cells to 4 data targets via RDMA.
  One of the data targets (the "parity leader") computes the XOR parity.
  Parity cell sent to the parity target.
  All 5 targets persist.
  Latency: max(target write latencies) since they happen in parallel.

Write path (partial stripe — smaller than stripe_size):
  Partial-stripe writes accumulate in SCM on each target.
  When the full stripe worth of data is accumulated: full-stripe write proceeds.
  This avoids the read-modify-write problem (no need to read old parity).
  DAOS calls this "cell accumulation" — analogous to log-structured merge.

Read path (no failures):
  Client reads only the needed data cells (not parity).
  For a 4+1 EC object: reading one cell = contacting 1 target.
  Bandwidth amplification: 0 (read only what you need).

Read path (degraded — one target down):
  Client detects missing target (placement map shows excluded).
  Client reads k surviving data cells + reads extra parity cells.
  Reconstructs missing data: parity XOR or Reed-Solomon decode.
  No server involvement in reconstruction — client does it.
  Latency penalty: reads 4 targets instead of 1 target per cell.
```

### 7.2 Rebuild After Target Failure

```
Event: target T fails (server crash or NVMe failure).

1. Detection:
   DAOS server monitor detects T is unresponsive.
   Pool service leader (Raft) updates placement map: exclude T.
   Placement map version incremented and distributed to all servers.

2. Rebuild initiation:
   Pool service triggers rebuild operation.
   Rebuild is distributed: every remaining target participates.

3. Rebuild execution:
   For each object that had a shard on T:
     Surviving targets determine which objects were affected.
     (Determined from local VOS: which objects have shards on T per placement map.)
     For each affected object:
       Replica: read the surviving copy → write to the new target.
       EC: read k surviving shards → reconstruct → write to new target.
   All rebuild I/O uses background priority (doesn't starve foreground).

4. Rebuild completion:
   Placement map updated: new target replaces T for affected objects.
   Clients refresh their cached placement map.

DAOS rebuild vs Ceph recovery:
  Ceph: recovers PGs (placement groups), each PG has all objects for a hash range.
        Recovery is serial per PG; scales with PG count.
  DAOS: rebuilds individual objects in parallel across all surviving targets.
        No PG concept; each object is rebuilt independently.
        Rebuild throughput scales with number of surviving targets.
        On a 100-node cluster: rebuild uses 99 nodes in parallel.

Rebuild time estimate:
  Failed target had D GB of data.
  Surviving targets provide k surviving data shards per stripe.
  Aggregate rebuild bandwidth = Σ(surviving target NVMe bandwidth) / replication_factor
  For 100 targets each at 5 GB/s, k=4 EC: rebuild bandwidth ≈ 100 × 5 / 5 = 100 GB/s
  For D = 20TB: rebuild time ≈ 20TB / 100GB/s ≈ 200 seconds (~3 minutes)
  This is much faster than Ceph (which serial-scans PGs per OSD).
```

---

## Section 8: APIs

### 8.1 Native DAOS API

```c
// Pool operations
daos_pool_connect(uuid, sysname, DAOS_PC_RW, &poh, &pool_info, NULL);
daos_pool_disconnect(poh, NULL);

// Container operations
daos_cont_create(poh, &uuid, NULL, NULL);
daos_cont_open(poh, uuid, DAOS_COO_RW, &coh, &cont_info, NULL);
daos_cont_close(coh, NULL);
daos_cont_destroy(poh, uuid, 0, NULL);

// Object operations
daos_obj_open(coh, oid, DAOS_OO_RW, &oh, NULL);
daos_obj_close(oh, NULL);

// I/O: key-value fetch/update
d_iov_t dkey, akey;
d_sg_list_t sgl;
daos_iod_t iod;
daos_obj_update(oh, DAOS_TX_NONE, 0, &dkey, 1, &iod, &sgl, NULL);
daos_obj_fetch(oh, DAOS_TX_NONE, 0, &dkey, 1, &iod, &sgl, NULL, NULL);

// Transaction (for atomic multi-key updates)
daos_handle_t th;
daos_tx_open(coh, &th, 0, NULL);
daos_obj_update(oh1, th, ...);   // first update
daos_obj_update(oh2, th, ...);   // second update (different object)
daos_tx_commit(th, NULL);        // atomic commit of both
daos_tx_close(th, NULL);
```

### 8.2 DFS (DAOS File System) — POSIX Layer

```
DFS is the POSIX-compatible namespace built on DAOS objects.
Used by libioil (interception) and dfuse (FUSE mount).

Internal structure:
  One container = one DFS namespace.
  Directory object (OC_RP_3G1 or configured redundancy):
    dkey = filename
    akey = "inode_hi", "inode_lo"  → object ID of the file/subdir inode

  File inode object:
    dkey = "/"
    akeys: "mode", "uid", "gid", "size", "mtime", "ctime"
    (all single-value — latest epoch wins)

  File data object (may be same as inode or separate):
    dkey = block_index (0, 1, 2, ...)
    akey = "data"
    value = array of bytes for that 1MB block (default chunk size)

libioil operation:
  Intercepts: open(), read(), write(), close(), stat(), readdir(), etc.
  Translates: POSIX path → DFS lookup (directory walk) → object ID
  Routes: I/O directly to DAOS via libdaos (bypassing kernel VFS entirely)
  Activation: LD_PRELOAD=libioil.so ./application

dfuse operation:
  Mounts DFS as a FUSE filesystem: /daos/pool/container → POSIX path
  Any application (even those that can't use libioil) can access DAOS
  Overhead vs libioil: FUSE has kernel-crossing overhead (~5-20μs per operation)
  Use dfuse for: compatibility; use libioil for: maximum performance
```

### 8.3 MPI-IO and HDF5

```
MPI-IO native ROMIO driver:
  MPICH/OpenMPI include a ROMIO implementation.
  DAOS ROMIO driver: maps MPI_File_write_at() directly to daos_obj_update()
  with dkey = file_offset/chunk_size, akey = "data".
  No VFS, no syscall. Each MPI rank writes directly to its portion of the object.
  At scale (1000s of MPI ranks): all write in parallel to the same container,
  no MDS bottleneck, no single-node coordination.

HDF5 DAOS VOL (Virtual Object Layer):
  HDF5 groups → DAOS objects (one object per group)
  HDF5 datasets → DAOS array objects (multidimensional data)
  HDF5 attributes → DAOS single-value akeys
  Benefit: HDF5 data structure maps NATURALLY to DAOS object model.
  No path parsing, no POSIX inode overhead.
  Parallel writes: each HDF5 dataset chunk is one DAOS array slice → parallel.
  Used by: climate simulation (NetCDF4/HDF5), scientific computing frameworks.
```

---

## Section 9: Performance Profile

### 9.1 Where DAOS Excels

| Scenario | Reason |
|----------|--------|
| HPC checkpoint (burst write) | SCM absorbs burst at memory speed; background drain to NVMe; GPU not stalled |
| AI training data read | High IOPS random reads from NVMe pool; RDMA zero-copy to GPU memory (via GPUDirect) |
| Parallel simulation output | Many MPI ranks write simultaneously; no MDS bottleneck; linear bandwidth scaling |
| Small I/O metadata-heavy workload | SCM path: 1-5μs; no kernel, no context switch |
| Large sequential streaming | RDMA bulk transfer; saturates InfiniBand bandwidth |
| Versioned datasets | Snapshot at any epoch; compare two versions without copying |

### 9.2 Where DAOS Struggles

| Scenario | Root Cause | Mitigation |
|----------|-----------|------------|
| Generic POSIX applications | dfuse overhead (~5-20μs/op vs 1-5μs native); filesystem semantics mismatch | libioil interception for compatible apps |
| Random small overwrite workloads | VOS creates new epoch entry per write; aggregation needed to reclaim space | Tune aggregation frequency |
| Very small objects (< 1KB) x millions | Object index overhead dominates; SCM fills with index nodes | Batch small objects into larger ones; use akeys instead of separate objects |
| Workloads needing strong consistency without transactions | HLC-based ordering; eventual visibility without explicit snapshots | Use explicit DAOS transactions for consistency-sensitive paths |
| Legacy applications needing POSIX semantics exactly | DFS approximates POSIX; some operations (fcntl locks, mmap) not supported | dfuse for broader compatibility (slower) |
| No Optane SCM (only NVMe) | Without SCM tier: write latency = NVMe latency (~100-200μs) not SCM (~1-5μs) | Still outperforms Lustre; SCM is preferred for full advantage |

### 9.3 Latency Model

```
Operation                SCM path        NVMe path
─────────────────────────────────────────────────
Small write (< 4KB)      1-5μs           10-50μs (with SCM buffer: 1-5μs)
Large write (1MB)        N/A             50-200μs (RDMA + NVMe)
Small read (< 4KB, hot)  2-10μs          N/A (served from SCM)
Small read (< 4KB, cold) 10-30μs         (served from NVMe via SPDK)
Large read (1MB)         N/A             30-100μs (RDMA bulk from NVMe)
Metadata (stat, mkdir)   2-10μs          N/A (metadata always on SCM)
DTX commit (2 targets)   2 RTTs = 4-20μs (includes RDMA round-trip)

Comparison to Lustre (HDR InfiniBand):
  Metadata (stat): Lustre ~100-500μs (MDS processing) vs DAOS 2-10μs (no MDS)
  Small write:     Lustre ~200-500μs (kernel path) vs DAOS 1-5μs (user-space + SCM)
  Large write:     Lustre ~50-200μs vs DAOS ~50-200μs (comparable at large I/O)
  Bandwidth:       Lustre scales with OSS count; DAOS scales with target count — similar
```

### 9.4 Bandwidth Scaling

```
DAOS bandwidth scales (nearly) linearly with server count:

  N servers × T targets/server × B GB/s per target = N×T×B aggregate bandwidth

Example configuration (Aurora-class):
  256 storage servers × 8 NVMe targets/server × 5 GB/s per NVMe = 10,240 GB/s = 10 TB/s
  Client bandwidth: 256 servers × 100Gb/s IB = 3.2 TB/s (network-limited)

Practical limits:
  Network: InfiniBand HDR 200Gb/s per port = 25 GB/s per link
  Server NVMe: typically 4-8 NVMe drives, ~5 GB/s each → 20-40 GB/s per server
  Client: each compute node has 1-2 IB ports = 25-50 GB/s per node
  Bottleneck: usually network bandwidth between compute and storage

For AI training workloads:
  GPU memory bandwidth: 2TB/s (H100)
  NVMe-to-GPU via DAOS+GPUDirect: ~100-500 GB/s per node (limited by PCIe + IB)
  Training data prefetch: must feed GPUs fast enough → DAOS at scale achieves this
```

---

## Section 10: Key Failure Modes

### 1. Pool/Container Metadata Service Outage

```
Symptom: clients cannot connect to pool or container; daos pool query hangs.
Cause: pool service Raft leader unavailable; not enough replicas for quorum.

Diagnosis:
  dmg pool query pool_uuid      # hangs or errors
  dmg system query              # shows rank status
  dmesg on storage servers      # Raft election messages

Recovery:
  If majority of pool service replicas alive: Raft auto-elects new leader (seconds).
  If majority dead: pool service is unavailable. Requires admin intervention.
  Recovery: daos pool evict (evict clients) + daos pool exclude (remove dead ranks)
  + daos pool reintegrate (when replaced servers come back)
```

### 2. Target Failure (NVMe or Server)

```
Symptom: I/O errors or degraded performance; rebuild starts automatically.
Cause: NVMe failure, server crash, or network partition.

Automatic response:
  DAOS server monitor detects failure → excludes target from placement map.
  Rebuild initiates: surviving targets reconstruct lost shards.
  Clients switch to degraded mode (EC reconstruction from remaining shards).
  Rebuild progress visible: dmg pool query --show-rebuild.

Monitor:
  dmg pool query pool_uuid          # shows rebuild progress %
  daos pool list-attrs               # health state
  watch -n 5 'dmg system query'     # per-rank health

Post-rebuild:
  Replace failed hardware.
  dmg storage format /new_target    # format new NVMe
  dmg pool reintegrate              # add target back; data rebalanced
```

### 3. SCM Space Exhaustion (Metadata Overflow)

```
Symptom: writes fail with DER_NOSPACE; SCM usage high but NVMe has space.
Cause: too many small objects or VOS index nodes consuming SCM; aggregation lagging.

Diagnosis:
  daos container query --cont=uuid  # shows per-container usage
  Check VOS SCM allocation on servers: /proc/meminfo + pmem device usage.

Fix:
  Trigger manual aggregation: daos container set-prop --cont=uuid --attr=daos_agg_max_epoch=<now>
  Review object design: merge small objects (use akeys instead of separate objects).
  Increase SCM capacity (add Optane DIMMs) or reduce object count.
```

### 4. Placement Map Stale / Version Mismatch

```
Symptom: I/O returns -DER_STALE; clients see inconsistent views.
Cause: placement map version changed (target excluded/reintegrated) but client cache is stale.

Auto-recovery: libdaos detects version mismatch → refreshes placement map → retries.
Manual: daos pool query; dmg pool get-prop pool_uuid version.
If clients stuck: daos pool evict --pool=uuid (forces all clients to reconnect).
```

### 5. Clock Skew Exceeding HLC Threshold

```
Symptom: writes return -DER_HLC_SYNC; transactions fail with HLC violation.
Cause: HLC on two servers diverges by more than DAOS_HLC_MAX_SKEW (default 500ms).

Root cause: NTP misconfiguration or NTP step correction after long drift.
Fix: ensure all servers use PTP or a reliable NTP source with < 100ms drift.
daos system set-attr daos_hlc_max_skew=<ms> to adjust threshold (not a real fix).
```

---

## Section 11: Deployment and Configuration

### Pool and Container Creation

```bash
# Format storage (one-time, on storage servers)
dmg storage format

# Create a pool
dmg pool create \
  --size=100TB \                  # total pool size
  --tier-ratio=5 \                # 5% SCM, 95% NVMe
  --user=hpcuser \
  --group=hpcgroup \
  --properties=rd_fac:2 \         # default redundancy factor = 2
  MyPool

# Create a POSIX-compatible container
daos container create \
  --pool=MyPool \
  --type=POSIX \
  --label=training-data \
  --properties=rf:2,ec_cell_sz:65536

# Create an HDF5 container
daos container create \
  --pool=MyPool \
  --type=HDF5 \
  --label=simulation-output

# Mount with dfuse
dfuse --mountpoint=/mnt/daos --pool=MyPool --container=training-data

# Or use libioil (no FUSE, better performance)
export LD_PRELOAD=libioil.so
export D_IL_REPORT=1           # report I/O interception stats on exit
./my_hpc_app /mnt/daos/training-data/input.h5
```

### Key Properties

```bash
# Container properties relevant to performance and durability
daos container set-prop --pool=MyPool --cont=training-data \
  --attr=rf:2 \                  # redundancy factor (replicas or EC parity shards)
  --attr=ec_cell_sz:1048576 \   # EC cell size: 1MB (good for large sequential I/O)
  --attr=layout_ver:1 \
  --attr=cksum:adler32 \        # per-block checksum (adler32 or crc16/32)
  --attr=cksum_size:65536 \     # checksum chunk size
  --attr=srv_cksum:on           # verify checksums on server side

# Object class per container
daos container create \
  --pool=MyPool \
  --type=POSIX \
  --properties=oclass:EC_4P2G1  # default object class for files in this container
```

### Performance Tuning

```bash
# Client-side: tune RDMA buffer pool
export CRT_CREDIT_EP_CTX=32   # concurrent RPC credits per endpoint (default 32)
export DAOS_IO_BYPASS=0       # 0=normal path; 1=bypass checksums (development only)

# libioil tuning
export D_IL_MAX_EQ=32         # max event queue depth per thread

# Scrub schedule (server side)
daos pool set-prop --pool=MyPool \
  --attr=scrub:timed \         # timed: periodic scrub; lazy: only on access
  --attr=scrub_freq:604800     # every 7 days (in seconds)

# Aggregation tuning (server side, in daos_server.yml)
# engines:
#   - targets: 8
#     ...
#     storage:
#       - class: dcpm    # SCM tier
#       - class: nvme    # NVMe tier
```

---

## Section 12: Source Code Map

```
DAOS GitHub: https://github.com/daos-stack/daos

src/vos/           — Versioned Object Store (the most important directory)
  vos_obj.c        — Object operations: update, fetch, iterate
  vos_tree.c       — DBTREE (B-tree on PMem): the core index structure
  vos_aggregate.c  — Epoch aggregation (GC of old versions)
  vos_io.c         — I/O routing: SCM vs NVMe decision, bio calls
  vos_dtx.c        — Per-target DTX records (tentative/committed/aborted)

src/bio/           — Block I/O layer (sits between VOS and SPDK)
  bio_xstream.c    — Per-target xstream (execution stream / polling loop)
  bio_buffer.c     — DMA buffer management for RDMA bulk transfers
  bio_blob.c       — NVMe blob lifecycle (allocate, free, map)

src/cart/          — CaRT: RPC transport
  crt_rpc.c        — RPC creation, send, recv
  crt_bulk.c       — Bulk (RDMA) operations
  crt_group.c      — Group management (cluster membership)

src/pool/          — Pool service (Raft-based)
  srv_pool.c       — Pool service handlers
  pool_map.c       — Placement map management

src/container/     — Container service
  srv_container.c  — Container create/destroy/query
  srv_epoch.c      — Epoch management, snapshots

src/object/        — Object service (per-storage-target, handles I/O RPCs)
  obj_rpc.c        — RPC handlers: update, fetch, list
  obj_ec.c         — Erasure coding: encode, decode, reconstruct
  srv_obj.c        — Server-side object operation dispatch

src/dtx/           — Distributed transaction coordinator
  dtx_leader.c     — DTX leader: prepare/commit protocol
  dtx_resync.c     — DTX recovery after leader crash

src/client/        — Client library (libdaos)
  dc_pool.c        — Pool connect/disconnect
  dc_cont.c        — Container open/close/snapshot
  dc_obj.c         — Object open/close/update/fetch
  dc_tx.c          — Transaction open/commit/abort

src/dfs/           — DAOS File System (POSIX layer)
  dfs.c            — DFS namespace operations (create/read/write/stat)
  dfs_sys.c        — POSIX-level wrappers

src/ioil/          — I/O interception library (libioil)
  intercept.c      — POSIX syscall interception via __attribute__((alias))
```

---

## Section 13: DAOS vs Lustre vs Ceph vs NFS — Architect Comparison

| Dimension | DAOS | Lustre | Ceph (CephFS/RGW) | NFS |
|-----------|------|--------|-------------------|-----|
| Target hardware | SCM + NVMe (all-flash) | HDD or SSD | HDD or SSD | Any |
| Metadata server | Distributed (no MDS) | Single MDS (or clustered DNE) | Single active MDS (or HA pair) | NFS server |
| Data path | User-space (SPDK + libfabric) | Kernel (LNet + ldiskfs/ZFS) | Kernel (OSD + BlueStore) | Kernel (VFS + network) |
| Network | InfiniBand, RoCE, TCP | InfiniBand (LNet), RoCE | Ethernet (RBD/CephFS) | Ethernet |
| Small I/O latency | 1-10μs | 100-500μs | 500μs-5ms | 500μs-5ms |
| Large I/O bandwidth | Linear scaling, TB/s | Linear scaling, TB/s | Linear scaling, TB/s | Single-server limited |
| POSIX compliance | Approximate (libioil/dfuse) | Full | Full (CephFS) | Full |
| Snapshots | Instant (epoch-based) | Limited (Lustre HSM) | Yes (CephFS) | No |
| Versioning / MVCC | Built-in (epoch model) | No | No | No |
| Data checksums | Yes (per-block, optional) | No (on ZFS backend) | Yes (BlueStore) | No |
| Transactions | Yes (DTX, cross-object) | No | Limited | No |
| Erasure coding | Yes (native, flexible EC) | No (use mdadm) | Yes (native) | No |
| Multi-protocol | Array/KV/POSIX/HDF5/MPI-IO | POSIX/Lustre client | S3/RBD/CephFS | POSIX |
| Maturity | Production at Tier-0 HPC | Very mature (20+ years) | Mature | Very mature |
| Operational complexity | High (Optane required for full benefit) | Medium | High | Low |
| Best for | HPC, AI/ML, checkpoint | HPC traditional workloads | Cloud storage, object, block | General-purpose NAS |

**The key DAOS differentiation over Lustre/Ceph:**
1. **No kernel on data path** — 10-100× lower small I/O latency
2. **SCM tier** — write latency in μs, not ms; absorbs burst without stalling compute
3. **No MDS bottleneck** — metadata distributed via placement; no single point of congestion
4. **Epoch versioning** — point-in-time snapshots are instantaneous; no copy-on-write overhead
5. **Native HDF5/MPI-IO** — no POSIX translation overhead for HPC I/O patterns

---

## Quick Reference

```
Object hierarchy:
  Pool → Container → Object → dkey → akey → value/array

Object ID encoding:
  oid.hi: object class (OC_SX, OC_RP_2G1, OC_EC_4P2G1, etc.)
  oid.lo: application identifier (e.g., inode number)

VOS storage tiers:
  < 4KB: SCM (nanosecond access, in-line in DBTREE)
  ≥ 4KB: NVMe via SPDK blob (microsecond access)
  All: written to SCM first, migrated to NVMe in background

Why no WAL:
  SCM + ADR = persistent byte-addressable memory.
  clflush + sfence = durable. pmemobj transactions = atomic.
  No journal needed; DAOS writes are the durable record.

Epoch model:
  Every write tagged with HLC timestamp (epoch).
  VOS stores all versions → MVCC (readers never block writers).
  Aggregation GCs old epochs to reclaim space.
  Snapshot = immutable view at a specific epoch.

DTX (distributed transaction):
  2-phase commit with SCM-persisted commit record as atomicity point.
  Single-target ops: no DTX overhead.
  Multi-target atomic ops: 2 RTT latency overhead.

Rebuild:
  Object-level (not PG-level like Ceph).
  All surviving targets participate → O(cluster_size) rebuild bandwidth.
  50TB rebuild on 100-node cluster: ~minutes, not hours.

Access paths:
  libioil (LD_PRELOAD): best performance, POSIX interception
  dfuse (FUSE mount): full POSIX, ~5-20μs overhead vs native
  MPI-IO ROMIO: native for parallel HPC
  HDF5 VOL: native for scientific data

Key diagnostics:
  dmg system query                    # rank health
  dmg pool query pool_uuid            # pool status + rebuild %
  daos container query --cont=uuid    # container stats
  daos container list-attrs           # container properties
  daos pool list-attrs                # pool health attrs
```
