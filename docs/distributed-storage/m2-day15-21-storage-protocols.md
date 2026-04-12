# Month 2 Days 15–21: Storage Network Protocols

---

# Day 15: iSCSI Protocol Internals

## Learning Objectives
- Understand iSCSI PDU format and session establishment
- Follow command numbering and error recovery
- Configure iSCSI target and initiator; trace PDUs

---

## 1. iSCSI Architecture

iSCSI maps SCSI commands over TCP/IP — the "poor man's Fibre Channel."

```
iSCSI stack:
  Application
    → SCSI command layer (struct scsi_cmnd)
      → iSCSI initiator driver (drivers/scsi/libiscsi.c)
        → TCP/IP network
          → iSCSI target (targetcli / LIO)
            → SCSI backend (block device, file, etc.)

Key concepts:
  IQN (iSCSI Qualified Name): unique identifier for initiator/target
    Format: iqn.YYYY-MM.reverse.domain:name
    Example: iqn.2026-04.com.example:storage-target-1

  Session: a logical connection between initiator and target
    Multiple TCP connections per session (MCS — Multi-Connection Session)
    Session survives TCP reconnects (Error Recovery)

  Connection: one TCP connection within a session

  LUN (Logical Unit Number): a specific storage device on the target
```

---

## 2. iSCSI PDU Format

```
iSCSI PDU (Protocol Data Unit):
  Basic Header Segment (BHS): 48 bytes, always present
    Opcode: command type (0x01=SCSI command, 0x25=login, etc.)
    Flags: F (final), R (read), W (write), etc.
    DataSegmentLength: length of data following header
    InitiatorTaskTag (ITT): identifies this command (like blk-mq tag)
    CmdSN: command sequence number (for ordering)
    ExpStatSN: expected status sequence number from target

  Additional Header Segments (AHS): optional, variable
  Header Digest: CRC32 of header (optional)
  Data Segment: actual SCSI data
  Data Digest: CRC32 of data (optional)
```

---

## 3. Session Establishment (Login Sequence)

```
Phase 1: Security Negotiation
  Initiator → LoginRequest (SecurityNegotiation stage)
    AuthMethod=CHAP or None
  Target → LoginResponse
    CHAP challenge if needed

Phase 2: Operational Parameter Negotiation
  Initiator → LoginRequest (OperationalNegotiation stage)
    MaxRecvDataSegmentLength=65536
    MaxBurstLength=262144
    FirstBurstLength=65536
    ImmediateData=Yes
    DataPDUInOrder=Yes
    DataSequenceInOrder=Yes
  Target → LoginResponse (with agreed parameters)

Phase 3: Full Feature Phase
  Both sides now exchange SCSI commands
  InitiatorTaskTag sequences from 0, increments per command
  CmdSN sequences from 0 (like TCP sequence numbers but for iSCSI)
```

---

## 4. Command Numbering & Error Recovery

```
iSCSI command sequence numbers (like Raft log indices):
  CmdSN: initiator's command sequence number (monotonically increasing)
  StatSN: target's status sequence number (monotonically increasing)
  ExpCmdSN: target's expected next CmdSN (window management)
  MaxCmdSN: highest CmdSN target will accept (flow control)

Commands are re-ordered prevention:
  Window: [ExpCmdSN, MaxCmdSN] defines accepted range
  Duplicate detection: target ignores CmdSN < ExpCmdSN
  Flow control: initiator stops if CmdSN > MaxCmdSN

Error Recovery Levels:
  Level 0 (Session Recovery): TCP disconnect → rebuild entire session
  Level 1 (Digest Error Recovery): data corruption → retransmit PDU
  Level 2 (Connection Recovery): TCP connection lost → recover within session
    Initiator reconnects, target replays outstanding commands

Advantage of Level 2 over Level 0:
  Session state (LUN access, negotiated parameters) preserved
  Only in-flight commands need recovery
  Faster than full session rebuild
```

---

## 5. Hands-On: iSCSI Target + Initiator

```bash
# Install targetcli (iSCSI target)
apt install targetcli-fb open-iscsi

# Create iSCSI target
targetcli
/> backstores/block create name=lun0 dev=/dev/sdb
/> iscsi/ create iqn.2026-04.com.example:target1
/> iscsi/iqn.2026-04.com.example:target1/tpg1/luns create /backstores/block/lun0
/> iscsi/iqn.2026-04.com.example:target1/tpg1/ set attribute authentication=0
/> iscsi/iqn.2026-04.com.example:target1/tpg1/portals create 0.0.0.0 3260
/> saveconfig
/> exit

# Connect initiator
iscsiadm -m discovery -t st -p 127.0.0.1
iscsiadm -m node -T iqn.2026-04.com.example:target1 -p 127.0.0.1 -l

# Verify
lsblk   # new /dev/sdX should appear
cat /proc/scsi/scsi

# Trace iSCSI PDUs with tcpdump/Wireshark
tcpdump -i lo -w /tmp/iscsi.pcap port 3260
# In another terminal: do some I/O to the iSCSI device
dd if=/dev/urandom of=/dev/sdX bs=1M count=10
# Analyze in Wireshark: filter "iscsi"
# Observe: Login PDUs, SCSI Command PDUs, Data-In/Data-Out PDUs

# DM-Multipath with iSCSI (two paths to same target)
# Configure two portal addresses on target, connect both
iscsiadm -m node -T iqn... -p 192.168.1.10 -l
iscsiadm -m node -T iqn... -p 192.168.2.10 -l
# Both paths appear as separate /dev/sdX devices
# DM-Multipath combines them: /dev/dm-X
multipath -ll   # show multipath topology
```

---

## 6. Self-Check

1. What is the iSCSI InitiatorTaskTag and how does it correspond to blk-mq's tag?
2. iSCSI Error Recovery Level 2 allows a connection to fail without losing the session. What must the target preserve for this to work?
3. iSCSI uses CmdSN for flow control. What happens if an initiator sends CmdSN > MaxCmdSN?

## 7. Answers

1. InitiatorTaskTag (ITT) is a 32-bit value chosen by the initiator to identify an in-flight command — same role as blk-mq's tag. On completion, the target returns the same ITT so the initiator can match the response to the original command. Like blk-mq tags: allocate ITT on command submission, free on completion, uniqueness within a session.
2. The target must preserve the session state: negotiated parameters (MaxBurstLength, etc.), LUN mappings, and the list of in-flight commands with their CmdSN values. When the initiator reconnects, it sends a TaskManagement Request with "REASSIGN TASKS" to resume in-flight commands on the new connection. The target uses the preserved CmdSN list to replay status for completed commands.
3. The initiator should not send CmdSN > MaxCmdSN — this violates the flow control window. If it does, the target drops the command (as if not received). The initiator's CmdSN window management should prevent this; if it happens due to a bug, the command times out and the initiator retransmits.

---

# Day 16: NFS v4 & pNFS Architecture

## Learning Objectives
- Understand NFSv4's stateful operations vs NFSv3's stateless model
- Understand pNFS parallel data access: layout types and client behavior
- Know when pNFS solves real performance problems vs adds complexity

---

## 1. NFSv3 vs NFSv4: The Stateful Shift

```
NFSv3 (stateless):
  Every operation is self-contained (no server state needed)
  File handle: opaque identifier for file (no server state lookup)
  Locking: separate NLM (Network Lock Manager) protocol
  Failure recovery: server restart transparent (client just retries)

NFSv4 (stateful, RFC 3530/5661):
  Server maintains state: open files, locks, delegations
  Client ID: registered with server, survives minor network glitches
  Compound operations: multiple RPCs in one round trip (LOOKUP+OPEN+READ)
  Delegations: server grants client "you can cache this file" for period
  Locking: built into protocol (not separate NLM)

Why stateful:
  Better performance (compound ops, delegations)
  Better semantics (close-to-open consistency guaranteed)
  Better security (integrated Kerberos via RPCSEC_GSS)

Downside of stateful:
  Server crash requires grace period (clients reclaim state)
  Grace period: 90 seconds (clients re-open files, reclaim locks)
  During grace: server only accepts reclaim operations
```

---

## 2. pNFS: Parallel NFS

```
Standard NFS: all data goes through metadata server (MDS)
  Client → MDS → (MDS reads/writes storage) → Client
  MDS is bottleneck for large clusters

pNFS (parallel NFS, RFC 5661 extension):
  Client → MDS: "give me a layout for this file"
  MDS → Client: layout (map of file offset ranges → storage locations)
  Client → Storage directly (bypasses MDS for data)
  Client → MDS: layout return/commit when done

Layout types:
  FILE layout: data on NFS servers (NFSv4.1 servers serving file chunks)
  BLOCK layout: data on SAN/iSCSI LUNs (client writes directly to block device)
  OBJECT layout: data on object storage (OSD-based)
  FLEXFILES layout: data on multiple NFSv3/4 servers with flexible mapping

pNFS FLEXFILES (most common):
  MDS hands out FLEXFILES layout pointing to data servers (DS)
  Client reads/writes directly to DS (bypassing MDS for data path)
  Useful for: parallel file system access, large file workloads
```

---

## 3. Hands-On: NFSv4 Setup & Compound Operation Observation

```bash
# Server setup
apt install nfs-kernel-server
echo "/export 192.168.1.0/24(rw,sync,no_subtree_check,fsid=0)" >> /etc/exports
exportfs -ra

# Client mount (NFSv4)
mount -t nfs4 server:/export /mnt/nfs4
# Verify NFSv4 is used
nfsstat -m | grep vers

# Capture NFSv4 compound operations
tcpdump -i eth0 -w /tmp/nfs4.pcap port 2049
# Do file operations
ls /mnt/nfs4
cat /mnt/nfs4/testfile
# Analyze in Wireshark: NFS compound ops show multiple operations per RPC
```

---

## 4. Self-Check

1. What is an NFSv4 delegation and what performance benefit does it provide?
2. pNFS separates metadata from data path. What does the client contact the MDS for vs the DS?
3. An NFSv4 server crashes and restarts. What is the grace period and why is it needed?

## 5. Answers

1. An NFSv4 delegation is a guarantee from the server to the client: "you are the only one accessing this file; cache it freely." With a read delegation, the client can serve reads from its local cache without contacting the server. With a write delegation, the client can write and cache locally, batching writes to server. The server revokes the delegation when another client needs access. Performance benefit: eliminates round trips for repeated reads/writes to the same file.
2. MDS: metadata operations (LOOKUP, OPEN, CLOSE, GETATTR, layout requests/returns). DS: data operations (READ, WRITE). The client gets a layout from the MDS that maps file offset ranges to specific DS addresses, then accesses DS directly for data, completely bypassing the MDS data path.
3. Grace period (90 seconds by default): time after restart during which the server only accepts state reclaim operations. Needed because: the server lost all its in-memory state (open files, locks). During grace, clients re-open files and reclaim locks. Only after grace can the server confirm that all state is re-established (or declare state lost). Without grace, a client might think it holds a lock that the server has forgotten — inconsistency.

---

# Day 17: SMB3 & Multichannel

## Key Content (Condensed)

```
SMB3 key features over SMB2:
  Encryption: AES-128-GCM or AES-128-CCM per-session or per-share
  Signing: HMAC-SHA256 or AES-128-CMAC (authentication)
  Multichannel: multiple TCP connections per session (parallel data transfer)
  Persistent handles: survive server restart (transparent failover for VMs)
  Directory leasing: client caches directory contents

SMB3 Multichannel:
  Client discovers server NICs via IOCTL (NETWORK_INTERFACE_INFO)
  Establishes multiple TCP connections across different NIC pairs
  Distributes I/O across connections (bandwidth aggregation)
  Single file can be accessed via multiple channels simultaneously
  
  Benefit: 2×10GbE → 20Gbps effective bandwidth for file I/O
  Use case: Windows Server file shares for VMs, SQL Server data files

SMB vs NFS:
  SMB: better Windows integration, encryption native, Multichannel
  NFS: better Linux integration, lower overhead, pNFS for parallel access
  Choose SMB: Windows clients, need encryption, need transparent failover
  Choose NFS: Linux clients, HPC, performance-critical
```

---

# Day 18: Fibre Channel & FCoE

## Key Content (Condensed)

```
FC Architecture:
  FC fabric: switches connecting hosts (initiators) to storage (targets)
  WWN (World Wide Name): 64-bit unique identifier (like MAC address)
  FLOGI: fabric login — host registers with fabric switch
  PLOGI: port login — host establishes session with target
  
Zoning: FC's security mechanism
  Hard zoning: enforced by switch hardware
    Switch drops frames between ports not in same zone
  Soft zoning: enforced by fabric name server (less secure)
    Name server filters — hosts can still discover non-zone members
  
  Zone = set of WWNs that can communicate
  Common practice: one initiator WWN + one target WWN per zone
  
NPIV (N-Port ID Virtualization):
  One physical FC HBA → multiple virtual N-Ports (VPorts)
  Each VPort has its own WWN
  Use: virtualization — each VM gets dedicated WWN for zoning
  
FCoE (Fibre Channel over Ethernet):
  FC frames carried over 10GbE (lossless Ethernet required)
  Requires: DCB (Data Center Bridging) — PFC (Priority Flow Control)
  PFC: per-priority pause frames prevent FC frame drops
  
FC vs iSCSI vs NVMe-oF:
  FC: lowest latency, most mature, expensive HW
  iSCSI: cheap (standard NICs), higher latency, TCP overhead
  NVMe-oF/RDMA: lowest latency (near-local), modern, expensive HW
  NVMe-oF/TCP: cheap, moderate latency, no special HW
  
FC replacement trajectory:
  New deployments: NVMe-oF/TCP or RDMA
  Existing FC: still heavily deployed (10+ year refresh cycles)
  FCoE: largely failed (complexity, DCB requirements)
```

---

# Day 19: Storage Network Protocol Comparison & Decision Guide

## The Decision Matrix

| Protocol | Latency | Throughput | CPU Overhead | HW Cost | Ops Complexity | Best For |
|----------|---------|------------|--------------|---------|----------------|----------|
| Local NVMe | ~50µs | Device max | Minimal | Low (standard) | Low | Single-server |
| iSCSI | ~300µs | Near wire | High (TCP) | Low | Medium | General enterprise, mixed OS |
| NVMe-oF/TCP | ~200µs | Near wire | Medium | Low | Medium | Cloud-native, disaggregated |
| NVMe-oF/RDMA | ~70µs | Near wire | Very low | High (RDMA NIC) | High | High-performance, low-latency |
| NFSv4/pNFS | ~500µs | High (parallel) | Medium | Low | Medium | File workloads, Linux |
| SMB3 | ~500µs | High (multichannel) | Medium | Low | Medium | File workloads, Windows |
| FC | ~100µs | High | Low (offload) | Very high | Very high | Legacy enterprise SAN |

## Design Scenarios

### Scenario 1: Greenfield enterprise, mixed Windows/Linux VMs
**Answer:** NVMe-oF/TCP for block storage (VM images, databases) + SMB3 for file shares (Windows VMs) + NFSv4 for Linux shared storage. No FC — cost not justified. iSCSI acceptable alternative to NVMe-oF/TCP if NVMe-oF target software not mature at your site.

### Scenario 2: HPC cluster, 100 compute nodes, parallel file system
**Answer:** NFSv4.1 with pNFS FLEXFILES layout pointing to multiple data servers. Or: Lustre (purpose-built parallel FS). Not iSCSI/FC (block-level, no shared namespace). Not SMB (Windows-oriented).

### Scenario 3: Database cluster, p99 < 1ms required
**Answer:** Local NVMe (p50 ~50µs). If disaggregated required: NVMe-oF/RDMA (~70µs). NVMe-oF/TCP (~200µs) borderline for 1ms p99 under load. Not iSCSI (~300µs baseline, more under load).

---

# Day 20: Object Storage — S3 API & Consistency Model

## Learning Objectives
- Understand S3's consistency model (strong since Dec 2020)
- Know multipart upload and when it's required
- Understand object versioning, lifecycle, and metadata architecture
- Read MinIO source for key operations

---

## 1. S3 Consistency Model (Post-2020)

```
Before December 2020: S3 had eventual consistency for some operations
  PUT object → eventual consistency for list-after-write
  DELETE object → eventual consistency

After December 2020: S3 provides strong consistency for all operations
  read-after-write consistency: PUT then GET → see the new object
  list-after-write consistency: PUT then LIST → see the new object
  read-after-delete consistency: DELETE then GET → object not found

Implementation: S3 uses a metadata index with linearizable reads
  (AWS hasn't published implementation details publicly)

Key remaining caveat: S3 is NOT serializable for conditional operations
  PutIfAbsent: no native CAS (compare-and-swap) — not supported
  AWSs workaround: DynamoDB for conditional storage metadata
  Alternative: use S3 object versioning + ETag for optimistic concurrency
```

---

## 2. Multipart Upload

```
Required for objects > 5GB (S3 limit for single PUT)
Recommended for objects > 100MB (better performance, resume on failure)

Protocol:
  1. CreateMultipartUpload → returns UploadId
  2. UploadPart(UploadId, PartNumber, data) for each part
     Parts: 1..10000, each 5MB–5GB
  3. CompleteMultipartUpload(UploadId, {partNumber: ETag} list)
     → Object is atomically committed
  4. OR AbortMultipartUpload → delete all parts

Benefits:
  - Parallel uploads (upload multiple parts simultaneously)
  - Resume on failure (restart only failed parts)
  - Large object support (up to 5TB total)

Cost trap: incomplete multipart uploads consume storage
  Set lifecycle rule to abort incomplete MPUs after N days
```

---

## 3. MinIO Source: Object Write Path

```go
// minio/cmd/erasure-object.go

// PutObject writes an object to an erasure-coded pool
func (er erasureObjects) PutObject(ctx context.Context, bucket, object string,
    r *PutObjReader, opts ObjectOptions) (ObjectInfo, error) {

    // 1. Generate unique upload ID
    uploadID := mustGetUUID()

    // 2. Write data to erasure set shards
    // Each shard goes to a different drive in the erasure set
    for _, disk := range onlineDisks {
        // Write shard to disk concurrently
        go writeDataShard(disk, uploadID, data)
    }

    // 3. Wait for k+m shards to succeed (quorum)
    // MinIO uses RS(k, m) where k+m = erasure set size (default 8+8=16)

    // 4. Write metadata (xl.meta) to all drives
    // xl.meta contains: ETag, size, erasure info, checksums
    writeMetadata(uploadID, objectInfo)

    // 5. Atomic rename: uploadID → object name
    renameData(uploadID, bucket+"/"+object)
}
```

---

## 4. Self-Check

1. S3 provides strong consistency since 2020. Does this mean S3 supports atomic compare-and-swap (put-if-absent)?
2. What is the minimum part size for S3 multipart upload, and why does the last part have a different minimum?
3. A MinIO erasure set has 16 drives (k=8, m=8). How many drives can fail before data is lost?

## 5. Answers

1. No. S3 strong consistency means read-after-write and list-after-write are consistent. It does not provide CAS — there's no API to say "PUT this object only if it doesn't exist." Workarounds: use S3 object versioning with conditional headers (If-None-Match), or use DynamoDB for coordination metadata with S3 for data.
2. Minimum part size: 5MB (except last part, which can be any size ≥ 1 byte). The last part is special because you can't know the final part size in advance. The 5MB minimum for non-last parts prevents extremely fragmented MPUs that would degrade performance and inflate metadata.
3. m=8 drive failures can be tolerated. The RS(8,8) code can reconstruct all k=8 data shards from any 8 of the 16 total shards. Losing 9 or more drives in the same erasure set would result in data loss.

---

# Day 21: Protocol Week Review

## Decision Guide & Scenario

### Quick Protocol Selection

Given any storage workload, select protocol in 5 minutes:

```
Step 1: Block or File?
  Block (raw device): iSCSI, NVMe-oF, FC
  File (POSIX namespace): NFS, SMB, GlusterFS, CephFS
  Object (key-value): S3-compatible

Step 2: If Block — latency requirement?
  < 100µs: Local NVMe or NVMe-oF/RDMA
  100-500µs: NVMe-oF/TCP or iSCSI
  > 500µs acceptable: iSCSI (simpler ops)

Step 3: If Block — existing infrastructure?
  FC switches installed: stick with FC (or add FCoE)
  Standard Ethernet: NVMe-oF/TCP (modern) or iSCSI (mature)
  RDMA-capable NICs: NVMe-oF/RDMA

Step 4: If File — client OS?
  Linux: NFS (native, lower overhead)
  Windows: SMB3 (native, encryption, multichannel)
  Mixed: either (both have cross-platform support)

Step 5: If File — parallel performance needed?
  Yes (HPC, large files): pNFS or Lustre or GPFS
  No: standard NFS or SMB3
```

### Design Scenario: Cloud-Native Storage for 200-Node K8s Cluster

**Brief:** 200 Kubernetes nodes, no local storage. Workloads: stateful databases (PostgreSQL, MySQL), shared config/code (read-many), object storage for application data. Budget: standard 25GbE NICs, no special hardware.

**Answer:**
- **Databases (block):** NVMe-oF/TCP to dedicated storage nodes. 25GbE gives ~3GB/s; NVMe-oF/TCP adds ~200µs latency overhead — acceptable for most databases. No RDMA (no special NICs). StorageClass in K8s backed by NVMe-oF targets with automatic provisioning.
- **Shared config/code (file):** NFSv4 from dedicated NFS servers. Simple, well-supported in K8s (nfs-subdir-external-provisioner). ReadWriteMany access mode — NFS handles concurrent reads. pNFS not needed for small config files.
- **Application data (object):** MinIO cluster with erasure coding. S3-compatible API works natively with most applications. K8s sidecar or operator for lifecycle management. Erasure set sized to match failure domain (rack-level tolerance).

---

## Tomorrow: Day 22 — Ceph RADOS Deep Dive

Week 4 begins: object storage architecture. We read the RADOS paper
and PrimaryLogPG.cc to understand PG state machine, peering, and
exactly what happens when an OSD fails.
