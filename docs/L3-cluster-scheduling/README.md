# L3: Cluster Scheduling & Fleet Operations

**Status:** Planned — next study track
**Prerequisite:** L1 (single-node internals) + L2 (distributed algorithms & systems)
**Goal:** Operate, schedule, and manage a storage cluster at fleet scale — the layer between distributed algorithms and production reality

---

## What This Track Covers

L1 teaches how one machine's I/O stack works.
L2 teaches how consensus and data placement algorithms work.
L3 is the operational layer: **how do you run 500 storage nodes as a coherent system?**

---

## Planned Curriculum (30 days)

### Week 1: Cluster I/O Scheduling & QoS

| Day | Topic | Key question |
|-----|-------|-------------|
| 1 | Distributed I/O throttling | How does Ceph enforce per-tenant IOPS limits across 100 OSDs simultaneously? |
| 2 | mClock & weighted fair queueing | How does mClock give QoS guarantees across a cluster? |
| 3 | Token bucket propagation across nodes | How do you enforce a cluster-wide quota without a central bottleneck? |
| 4 | Tail latency detection at scale | How do you detect and react to p99 outliers across 500 nodes? |
| 5 | Backpressure & admission control | When and how to shed load before a cluster saturates |
| 6 | Multi-tenant namespace isolation | Per-tenant IOPS/bandwidth isolation at the cluster level |
| 7 | Week 1 review: cluster QoS design | Design a QoS policy for a 100-tenant storage cluster |

### Week 2: Data Placement & Topology

| Day | Topic | Key question |
|-----|-------|-------------|
| 8 | Rack-aware / AZ-aware CRUSH rules | How to design CRUSH rules for failure domain isolation |
| 9 | Topology-driven scheduling | How Kubernetes storage-aware scheduling places pods near data |
| 10 | Rebalancing on node add/remove | How to minimize data movement when cluster topology changes |
| 11 | Hotspot detection & rebalancing | How to detect and fix hot OSDs / hot shards at runtime |
| 12 | Weighted placement & heterogeneous hardware | How to mix NVMe and HDD nodes in one cluster correctly |
| 13 | Placement policy testing & simulation | How to validate CRUSH rules before production |
| 14 | Week 2 review: placement architecture | Design placement policy for a multi-AZ storage cluster |

### Week 3: Fleet Operations

| Day | Topic | Key question |
|-----|-------|-------------|
| 15 | Rolling upgrades across a storage fleet | How to upgrade 500 Ceph OSDs without downtime |
| 16 | Health monitoring at fleet scale | Which Prometheus metrics matter for a 1000-node cluster |
| 17 | Automated failure response | How to automate OSD replacement, mark-out, reweight |
| 18 | Geo-replication: active-active | Consistency models and conflict resolution across DCs |
| 19 | Geo-replication: active-passive & async | RPO/RTO tradeoffs for async replication |
| 20 | Disaster recovery orchestration | How to execute a DC failover for a storage cluster |
| 21 | Week 3 review: fleet operations runbook | Design a geo-replication architecture for a SaaS product |

### Week 4: Kubernetes & Cloud Integration

| Day | Topic | Key question |
|-----|-------|-------------|
| 22 | CSI driver architecture | How Kubernetes volumes map to storage cluster operations |
| 23 | Storage class design | How to expose tiering, QoS, and encryption via StorageClass |
| 24 | Dynamic provisioning at scale | How volume creation scales to 10K pods |
| 25 | Volume snapshot & backup orchestration | How VolumeSnapshot integrates with storage cluster snapshots |
| 26 | Object storage at cluster scale | How S3-compatible clusters handle multi-tenant namespace isolation |
| 27 | Cluster capacity planning | 3-year growth model, failure domain headroom, hardware lead time |
| 28 | Cost optimization at fleet scale | Tiering policy across cloud + on-prem; egress cost modeling |
| 29 | Full cluster design lab | End-to-end: design a 500-node storage cluster for a SaaS platform |
| 30 | Final review & L4 roadmap | Synthesis: from kernel internals to fleet operations |

---

## Key References (to collect)

- Ceph mClock scheduler documentation and source (`src/osd/scheduler/`)
- "CRUSH: Controlled, Scalable, Decentralized Placement" (Weil et al., SC 2006)
- Kubernetes CSI specification — kubernetes-csi.github.io
- "Large-scale cluster management at Google with Borg" (EUROSYS 2015)
- Ceph Operations Guide — docs.ceph.com
- "Tail at Scale" (Dean & Barroso, CACM 2013) — latency outlier management
