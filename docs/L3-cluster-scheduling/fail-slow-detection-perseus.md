# Fail-Slow Disk Detection — Perseus (FAST '23 Best Paper)

**Paper:** Perseus: A Fail-Slow Detection Framework for Cloud Storage Systems
**Authors:** Ruiming Lu (Shanghai Jiao Tong University), Erci Xu et al. (Alibaba)
**Venue:** USENIX FAST 2023 — Best Paper Award
**Related:** L3 fleet management, L2-distributed/systems/Ceph, architecture/reliability/

---

## What Is Fail-Slow?

A storage device that is **still responding** but with **degraded throughput or elevated latency** — not dead, not throwing errors, just slow.

```
Normal disk:    read latency = 200µs at 200 MB/s throughput  ✓
Failed disk:    read latency = 0µs    (dead, easy to detect)  ✓
Fail-slow disk: read latency = 800µs at 200 MB/s throughput  ← hard
```

**Why it matters more than hard failures:**
- Hard failures are instantly detected (device gone, I/O returns error)
- Fail-slow is invisible to standard health checks — SMART is green, device responds
- One fail-slow disk in a RAID group or erasure-coded stripe degrades **all** reads that touch it
- In a distributed system, one fail-slow OSD/node drags tail latency for every request that lands on it
- The slower the disk, the longer it holds locks, the more it serializes the cluster

**Tail latency amplification formula:**
If a request touches N drives and one is fail-slow with slowdown factor S:
```
P(hitting fail-slow) ≈ 1 - (1 - 1/N_total)^k  where k = drives per request
```
At scale (248K drives, 10 per erasure stripe), nearly every request eventually hits a fail-slow drive. The tail latency is owned by the slowest drive in the stripe.

---

## Why Existing Detection Approaches Fail

### Approach 1: Fixed SLO Threshold

```
if latency > 500µs: flag as fail-slow
```

**Problem**: Load-induced latency spikes. Under high throughput, healthy disks naturally have higher latency (queueing theory). A busy healthy disk hits 600µs and gets flagged. A lazy fail-slow disk at 300µs (light load, but 3× slower than expected for that load) gets missed.

Result: **high false positives on healthy drives, false negatives on lightly-loaded fail-slow drives**.

### Approach 2: Peer Evaluation (compare drives on the same machine)

Compare drive A's latency to drives B, C, D on the same machine. If A is 3× slower than peers, flag it.

**Problem**: Requires per-cluster tuning of the comparison ratio. What's "normal divergence" on a machine with mixed HDD/SSD? Requires workload knowledge the cloud provider doesn't have. Breaks when multiple drives degrade together.

### Approach 3: IASO-style (timeout + workload model)

Detect when drive response time exceeds a workload-derived timeout. Requires per-application integration and workload visibility.

**Problem**: Cloud providers cannot instrument customer applications. Not general across workloads.

---

## Perseus: Core Insight

**The latency-throughput relationship is the key signal.**

At any throughput level, a healthy drive has an *expected* latency. High throughput → higher latency (natural queueing + batching effects). A fail-slow drive has latency **above the expected band for its current throughput**.

```
Expected latency at throughput T = f(T)   (learned from history)
Slowdown ratio = actual latency / upper_bound_expected_latency

Slowdown ratio > 1.0  →  drive is slower than expected for this load
```

This decouples detection from absolute thresholds and from peer comparison — it's self-referential per drive.

---

## Detection Algorithm: Four Steps

### Step 1 — Collect LvT (Latency vs Throughput) Data

Per-drive daemon records:
- Average latency (µs)
- Throughput (MB/s)
- Sampled every **15 seconds** (4 entries/minute, 720 entries/drive/day)

Build a scatter plot of (throughput, latency) pairs for each drive over a rolling window. This is the raw LvT distribution.

### Step 2 — Outlier Removal

The LvT scatter plot has noise: I/O bursts, GC pauses, brief contention. These look like fail-slow but are transient.

Perseus applies two algorithms in combination:
- **DBSCAN** (Density-Based Spatial Clustering): removes sparse/isolated points — captures transient anomalies that don't recur
- **PCA (Principal Component Analysis)**: removes points far from the principal axis of the distribution — captures systematic outliers

Why both? DBSCAN handles non-convex shapes; PCA handles elongated distributions (which LvT data typically forms). Together they clean the regression input without requiring label knowledge.

### Step 3 — Polynomial Regression → Expected Latency Curve

On the cleaned LvT points, fit a **polynomial regression**:

```
expected_latency = a₀ + a₁·T + a₂·T² + ...
```

This produces a curve `f(T)`. Perseus computes an **upper bound** of `f(T)` (e.g., using confidence interval or percentile of residuals) — this is the "normal ceiling" for latency at each throughput level.

**Why polynomial not linear?** The latency-throughput relationship is non-linear: drives have low latency at low throughput, then rise sharply as queue depth builds. A linear model underfits.

**Why per-drive, not per-cluster?** Different drives (NVMe vs HDD, different wear levels, different controller firmware) have different natural LvT curves. A cluster-wide model misclassifies normal hardware variation as fail-slow.

### Step 4 — Slowdown Ratio + Scoreboard

For each new (throughput, latency) sample from a drive:
```
slowdown_ratio = actual_latency / upper_bound_expected_latency(throughput)

slowdown_ratio > 1.0  →  drive is above its expected ceiling
```

A single spike (slowdown_ratio > 1.0 for one sample) is noise. Perseus scans the **time series of slowdown ratios** and uses a **scoreboard mechanism**:
- Score accumulates when slowdown_ratio > threshold
- Score decays when drive is healthy
- Drive flagged as fail-slow when score exceeds a severity threshold

This captures **sustained** degradation (fail-slow) vs **transient** spikes (GC pause, burst).

---

## Architecture

```
Per-machine daemon
  ├── Collect: (latency, throughput) per drive every 15s
  └── Send to → Perseus Detection Service

Perseus Detection Service (per cluster)
  ├── For each drive:
  │   ├── Step 1: DBSCAN + PCA outlier removal on LvT window
  │   ├── Step 2: Polynomial regression → f(T) + upper bound
  │   ├── Step 3: Compute slowdown_ratio per sample
  │   └── Step 4: Scoreboard → event if score > threshold
  └── Output: list of fail-slow drives + severity + duration
```

**Key design properties:**
- **Non-intrusive**: no application instrumentation needed, only OS-level metrics
- **Fine-grained**: detects at drive granularity, not node granularity
- **General**: works for NVMe SSD and HDD in the same framework
- **Adaptive**: threshold is derived per-drive from its own history, not cluster-wide fixed values

---

## Production Results (Alibaba, 10 months)

| Metric | Value |
|--------|-------|
| Drives monitored | 248,000 |
| Monitoring period | 10 months |
| Fail-slow cases found | **304** |
| Dataset: verified fail-slow drives | 315 |
| Dataset: normal drives | 41,000 |
| Clusters | 25 (30–663 hosts each) |

**Tail latency improvement after isolating detected fail-slow drives:**

| Percentile | Reduction |
|-----------|-----------|
| p95 | 30.67% (±10.96%) |
| p99 | 46.39% (±14.84%) |
| **p99.99** | **48.05% (±15.53%)** |

**The p99.99 impact is the key number.** Fail-slow drives have outsized influence on extreme tail latency. 304 drives out of 248K (0.12%) caused 48% of the p99.99 tail.

---

## Root Cause Taxonomy

Perseus performed root cause analysis on the 315 verified fail-slow cases:

**Software-induced (majority):**
- OS scheduling bug: multiple drives sharing a single management/dispatch thread
  → Drive A's I/O blocks Drive B's I/O completion → both appear slow intermittently
- Firmware-level priority inversion
- Driver contention under concurrent I/O

**Hardware defects:**
- NAND wear reaching threshold causing retries → elevated latency on specific LBAs
- Controller thermal throttling
- Degraded SAS/SATA interface signal integrity

**Environmental factors:**
- Vibration causing HDD head seek retries
- Temperature extremes causing NAND program/erase latency increase

**Key takeaway**: most fail-slow cases were **software-induced**, not hardware failure. This means firmware updates and OS patches can fix them — but only if you detect them first.

---

## Why Fixed Thresholds Can't Work: The Core Tradeoff

```
High threshold (e.g., >2ms always flagged):
  → Misses fail-slow disks under light load (200µs → 600µs = 3× slower, still below 2ms)
  → False negatives at low utilization

Low threshold (e.g., >300µs flagged):
  → Flags every busy healthy disk
  → High false positive rate under load
  → On-call engineers stop trusting alerts (alert fatigue)
```

The LvT regression model solves this because the threshold is **load-relative**: the same drive can be healthy at 400µs under 500 MB/s and fail-slow at 400µs under 100 MB/s. The model encodes this distinction.

---

## Architect-Level Implications

### 1. Design your health checks around relative latency, not absolute latency

Absolute latency SLOs are insufficient for heterogeneous, variable-load storage systems. The correct signal is **latency relative to current throughput** — the LvT deviation.

For your monitoring stack: track (latency, throughput) pairs per drive, not just latency. Alert on LvT deviation, not on latency > threshold.

### 2. Tail latency in distributed systems is owned by fail-slow drives

In any erasure-coded or replicated system, one fail-slow drive in a stripe/replica set makes every request that touches it slow. At scale, the expected number of requests hitting at least one fail-slow drive approaches 100%. **Fail-slow detection is more important than hard failure detection for tail latency.**

### 3. 0.12% of drives causing 48% of p99.99 tail latency

This is the practical significance. You don't need many fail-slow drives to destroy your tail SLO. At 248K drives, 304 sick drives (0.12%) produced nearly half the extreme tail latency. At 10K drives: ~12 fail-slow drives can own your tail.

### 4. Aggregation granularity matters: per-drive, not per-node

Aggregating to node-level latency masks individual drive failure. A node with 24 drives where 1 is fail-slow looks healthy at the node level (23 good drives dilute the bad one). Perseus works at drive granularity — this is the correct abstraction for detection.

### 5. Scoreboard / sustained-event design for production alerting

Single sample anomalies → noise. Sustained anomalies → real failure. Use a decaying score mechanism instead of per-sample alerts. This is directly applicable to any anomaly detection in your monitoring stack: accumulate evidence, decay on recovery, alert on sustained threshold breach.

### 6. Proactive isolation over reactive repair

Perseus detected fail-slow drives before they caused user-visible SLO violations. The correct response: **proactively mark the drive as degraded and let the distributed system route around it** (Ceph mark-out, RAID degraded mode, NVMe-oF path failover). Don't wait for customers to report slowness.

---

## Limitations and Open Problems

| Limitation | Implication |
|------------|-------------|
| Correlated failure blind spot | If all drives on a node degrade together (firmware bug on same batch), drive-level relative model sees no anomaly — node-level comparison needed |
| Requires historical baseline | New drives (first few days) have insufficient LvT history for regression |
| Software root causes need human investigation | Detection tells you *which* drive, not *why* — still need manual RCA for novel failure modes |
| No prediction (reactive, not proactive) | Detects current fail-slow; does not forecast future failure (different problem: predictive failure analysis) |

---

## Connections to Other Topics in This Curriculum

| Topic | Connection |
|-------|-----------|
| **Gray failure** (architecture/reliability) | Fail-slow is the canonical storage gray failure — not dead, not healthy, just degraded |
| **Tail latency & hedged requests** (L3 planned) | Hedged requests are a mitigation; Perseus detection + isolation is the fix |
| **Ceph OSD mark-out** (L2-distributed/systems) | The remediation action after detection: `ceph osd out <id>` — let cluster rebalance |
| **mClock QoS scheduler** (L3 planned) | Fail-slow drives distort mClock's weight model; detection must precede scheduler tuning |
| **blk-mq queue depth** (L1-single-node/kernel-io) | High queue depth amplifies fail-slow impact: more in-flight I/Os waiting behind slow drive |
| **SLO design** (architecture/reliability) | Perseus's p99.99 result shows SLO monitoring granularity matters: node-level SLO hides drive-level fail-slow |

---

## Summary: What to Remember

1. **Fail-slow** = device responds but slower than expected for current load. Harder to detect than hard failure. More damaging to tail latency.

2. **The signal**: latency relative to throughput (LvT deviation), not absolute latency.

3. **Perseus algorithm**: DBSCAN+PCA outlier removal → polynomial regression per drive → slowdown ratio → scoreboard for sustained events.

4. **Production scale**: 248K drives, 10 months, 304 cases found (0.12% of fleet), causing 48% of p99.99 tail latency.

5. **Root causes**: mostly software (scheduling bugs, driver contention), not hardware — fixable if detected.

6. **Architect action**: design monitoring at drive granularity with relative (LvT) metrics, not node-level absolute thresholds. Proactively isolate detected fail-slow drives.

---

## References

- [Perseus USENIX FAST 2023 presentation page](https://www.usenix.org/conference/fast23/presentation/lu)
- [Micah Lerner's paper review](https://www.micahlerner.com/2023/04/16/perseus-a-fail-slow-detection-framework-for-cloud-storage-systems.html)
- [ACM DL entry](https://dl.acm.org/doi/10.5555/3585938.3585942)
- [FSA Benchmark reproduction study (arXiv 2501.14739)](https://arxiv.org/html/2501.14739)
- Perseus public dataset: Alibaba PERCY dataset, 300K+ devices, ~100B entries since Oct 2021
