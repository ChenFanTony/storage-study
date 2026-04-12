# Month 3 Week 3: Reliability Engineering (Days 15–21)

---

# Day 15: Chaos Engineering for Storage — Methodology

## Learning Objectives
- Understand chaos engineering's hypothesis-driven methodology
- Design storage-specific chaos experiments
- Understand blast radius analysis and how to contain failures
- Know the difference between chaos testing and fault injection testing

---

## 1. Chaos Engineering Fundamentals

```
Chaos engineering: deliberately inject failures into production (or staging)
to discover weaknesses before they manifest as unplanned outages.

Key distinction:
  Fault injection testing: test specific failure scenarios in isolation
  Chaos engineering: test system behavior under realistic failure conditions
    → Often discovers emergent failures not anticipated by fault models

Principles (from Netflix's Chaos Engineering manifesto):
  1. Build a hypothesis around steady-state behavior
     "The system processes 10K writes/sec with p99 < 5ms during this experiment"
  
  2. Vary real-world events
     Not: "simulate a disk failure"
     Rather: "simulate what actually happens when a disk fails" (SMART errors, latency spike before failure, etc.)
  
  3. Run experiments in production
     Staging doesn't have real load, real data, real dependencies
     Production chaos: run at low blast radius first, expand gradually
  
  4. Automate experiments to run continuously
     Not: one-time test → forget
     Rather: regular automated experiments → detect regressions
  
  5. Minimize blast radius
     Start with small scope → validate hypothesis → expand scope
```

---

## 2. Hypothesis-Driven Storage Chaos Design

```
Good chaos hypothesis structure:
  "When [condition/failure], the system will [expected behavior],
   as measured by [specific metric], and [customer impact] will be [bounded]."

Example hypotheses:

H1: "When one OSD in a 3-replica Ceph pool fails,
     write throughput will remain above 80% of baseline,
     as measured by writes/sec to the pool,
     and no write will be lost (verified by checksum)."

H2: "When a thin pool reaches 90% utilization,
     the monitoring system will alert within 60 seconds,
     as measured by alert delivery time,
     and no new volumes will be provisioned (preventing pool exhaustion)."

H3: "When a primary NVMe has 50ms latency injected,
     the bcache hit rate will remain above 90%,
     as measured by bcache stats,
     and application p99 will stay below 200ms (served from cache)."

H4: "When the metadata server of CephFS is restarted,
     client reconnection will complete within 30 seconds,
     as measured by client request latency,
     and no in-flight write will be lost."

Bad hypothesis (too vague):
  "The system will handle disk failures."
  → No measurable outcome, no time bound, no customer impact defined
```

---

## 3. Storage-Specific Chaos Experiments

```
Category 1: Hardware failure simulation

Experiment: Single drive failure
  Method: echo offline > /sys/block/sda/device/state (SCSI)
          OR: mdadm --fail /dev/md0 /dev/sdb
  Measure: RAID rebuild time, I/O latency during rebuild, error rates
  Blast radius: one drive, affects one RAID set (not entire cluster)

Experiment: Network partition (storage node isolated)
  Method: iptables -I INPUT -s storage_node_ip -j DROP
  Measure: time to detect failure, time for clients to reconnect, data integrity
  Restore: iptables -D INPUT (verify self-healing works)

Experiment: Slow drive (gray failure)
  Method: tc qdisc add dev eth0 root netem delay 100ms (network)
          OR: dm-flakey with latency injection (block device)
  Measure: p99 latency impact, whether slow drive causes cascading effects

Category 2: Software failure simulation

Experiment: OSD process killed (Ceph)
  Method: kill -9 $(pgrep ceph-osd | head -1)
  Measure: PG peering time, client impact duration, auto-restart time
  Hypothesis: "Client sees <30s elevated latency, system self-heals"

Experiment: Metadata server restart (CephFS)
  Method: systemctl restart ceph-mds@mds.service
  Measure: MDS recovery time, client reconnect time, open file handle behavior

Experiment: etcd leader election (distributed coordination)
  Method: Kill etcd leader process
  Measure: election time (<300ms), in-flight write disposition, client reconnect

Category 3: Resource exhaustion

Experiment: Thin pool approaching exhaustion
  Method: fio --filename=/dev/mapper/thin_vol --rw=write --size=95% (fill to 95%)
  Measure: alert timing, automatic reclamation trigger, what happens at 100%

Experiment: MemTable flooding (RocksDB/LSM-tree)
  Method: generate writes faster than compaction can keep up
  Measure: write stall onset, write stop onset, recovery time after load reduction
```

---

## 4. Blast Radius Analysis

```
Blast radius: scope of potential impact from a chaos experiment

Dimensions:
  - Users affected: 0, subset, all
  - Data at risk: none, degraded durability, potential loss
  - Services affected: one component, one service, multiple services
  - Duration: seconds, minutes, hours

Blast radius containment strategies:
  1. Start with non-production (staging, dev)
     Validate experiment is safe before running in production

  2. Scope by percentage (1%, 5%, 10%, 50%, 100%)
     Netflix: run experiments on 1% of traffic initially
     Storage: experiment on 1 of 100 OSDs, then 5, then more

  3. Time-limited experiments
     Run for 5 minutes → revert → measure → run for 30 minutes

  4. Automatic abort conditions (circuit breaker)
     "If customer error rate > 1%, abort experiment automatically"
     "If data loss detected, stop immediately and alert"

  5. Observability before experimentation
     Can you MEASURE the blast radius in real time?
     If you can't measure, don't experiment

Blast radius matrix for storage experiments:
  Experiment                     Users Affected  Data Risk  Auto-Revert?
  ──────────────────────────────────────────────────────────────────────
  Kill 1 OSD (3-replica)         None (degraded) Low        Yes (restart OSD)
  Partition storage node         All on that node Medium     Yes (remove iptables)
  Fill thin pool to 95%          None (until 100%)High       Yes (delete test data)
  Inject drive latency 50ms      Latency impact   None      Yes (remove tc rule)
  Kill etcd leader               Brief unavailable None      Yes (etcd auto-heals)
```

---

## 5. Game Days

```
Game day: scheduled, announced chaos experiment with full team observing

Game day structure:
  1. Pre-game (1 week before):
     - Define hypothesis and success criteria
     - Identify observers (on-call, product, exec)
     - Prepare rollback procedure
     - Verify monitoring coverage

  2. Game day (2-4 hours):
     - Brief all participants (5 min)
     - Inject failure
     - Observe and record: what alerted? how quickly? what degraded?
     - Validate or falsify hypothesis
     - Rollback and verify recovery

  3. Post-game (within 1 week):
     - Document findings
     - File bugs for gaps discovered
     - Update runbooks with lessons learned
     - Schedule follow-up experiment if needed

Storage game day examples:
  "Primary database OSD failure" game day:
    Hypothesis: "DBA can recover from OSD failure in <30min using runbook"
    Inject: mdadm --fail on one OSD
    Measure: DBA's actual recovery time vs runbook estimate
    Often finds: runbook is outdated, monitoring alerts go to wrong team, etc.
```

---

## 6. Self-Check

1. What distinguishes chaos engineering from traditional fault injection testing?
2. A chaos hypothesis says "the system will handle failures." What is wrong with this?
3. You want to test thin pool exhaustion. What automatic abort condition would you set?
4. Why does Netflix run chaos experiments in production rather than staging?

## 7. Answers

1. Fault injection testing: inject a specific, known failure and verify the system handles it as designed. Chaos engineering: inject failures to discover unknown weaknesses and emergent behaviors. Chaos engineering often runs in production at low blast radius, continuously, and automates experiments — not one-time test runs. The key difference: chaos engineering expects to be surprised; fault injection testing verifies expected behavior.
2. No measurable outcome, no time bound, no definition of "handle," no customer impact bound. A good hypothesis specifies: exact conditions, measurable metric, time bound, and customer impact limit. "Handle" is unmeasurable. "Within 60 seconds, write throughput remains above 80% of baseline as measured by monitoring" is a hypothesis.
3. Abort condition: "If any thin volume returns I/O error to application (monitored via error logs), immediately stop filling and delete test data." Also: "If pool exceeds 95% utilization, stop." Having a monitoring check every 30 seconds during the experiment that triggers automatic cleanup prevents the experiment from crossing into actual production impact.
4. Staging lacks: real production load (different latency distribution, different hot data patterns), real dependencies (staging often mocks external services), real scale (staging may be 10% of production capacity), and real failure modes (production has years of accumulated configuration drift, different hardware generations, different network paths). A failure that manifests in production under real load often wouldn't appear in staging under synthetic load.

---

# Day 16: Fault Injection — Tools & Techniques

## Learning Objectives
- Know which fault injection tool to use at each storage layer
- Set up dm-flakey for block-device-level error injection
- Design a comprehensive fault injection test suite
- Understand the difference between error types (silence, corruption, latency, crash)

---

## 1. Fault Injection Tools by Layer

```
Application layer:
  libfiu: POSIX API injection (inject errors into open/read/write/close)
  failpoints (Go): conditional error injection in Go code
  Jepsen: distributed system fault injection framework

Block device layer:
  dm-flakey: inject I/O errors on a block device
  dm-delay: inject latency on a block device
  scsi_debug: software SCSI device with configurable error injection

Network layer:
  tc netem: inject latency, packet loss, corruption, reordering
  iptables: drop connections, block specific ports
  toxiproxy: TCP proxy with configurable failure modes

Filesystem layer:
  fault_inject kernel framework: /sys/kernel/debug/fail_*
  Example: inject -ENOMEM into kmalloc (triggers OOM paths)

Hardware simulation:
  null_blk: configurable block device (latency, error rate)
  scsi_debug: SCSI device with configurable failure modes
```

---

## 2. dm-flakey: Block Device Error Injection

```
dm-flakey: device mapper target that periodically fails I/O operations

Setup:
  # Create a target device to inject errors into
  DEV=/dev/nvme0n1
  SIZE=$(blockdev --getsz $DEV)
  
  # dm-flakey table format:
  # start length flakey dev offset up_interval down_interval [features]
  
  # Fail for 5 seconds every 30 seconds:
  echo "0 $SIZE flakey $DEV 0 25 5" | dmsetup create flakey_dev
  # up_interval=25s (working), down_interval=5s (failing)
  
  # Verify: mount a filesystem on /dev/mapper/flakey_dev
  mkfs.ext4 /dev/mapper/flakey_dev
  mount /dev/mapper/flakey_dev /mnt/flakey_test
  
  # Run workload — every 30s, 5s of failures
  fio --filename=/mnt/flakey_test/test --rw=randwrite --bs=4k \
      --ioengine=libaio --iodepth=32 --size=1G --time_based --runtime=120

dm-flakey features:
  error_reads: return -EIO for read operations during down period
  error_writes: return -EIO for write operations during down period  
  drop_writes: silently discard writes (no error, data not written)
    → Simulates silent data loss / power failure
  corrupt_bio_byte: flip a bit in I/O data (silent corruption)

Testing with drop_writes (power loss simulation):
  echo "0 $SIZE flakey $DEV 0 10 2 1 drop_writes" | dmsetup create flakey_drop
  # 2 seconds of drop_writes every 12 seconds
  # Test: does filesystem detect/recover from dropped writes?
  # Test: does WAL-based database detect missing writes on restart?
```

---

## 3. tc netem: Network Fault Injection

```bash
# Add latency to storage network traffic
tc qdisc add dev eth0 root netem delay 100ms

# Add latency with jitter (more realistic)
tc qdisc add dev eth0 root netem delay 100ms 20ms distribution normal

# Add packet loss (1%)
tc qdisc add dev eth0 root netem loss 1%

# Add packet corruption (0.1%)
tc qdisc add dev eth0 root netem corrupt 0.1%

# Combine: 50ms latency + 0.5% loss (realistic WAN conditions)
tc qdisc add dev eth0 root netem delay 50ms loss 0.5%

# Apply to specific traffic only (NVMe-oF port 4420)
tc qdisc add dev eth0 root handle 1: prio
tc filter add dev eth0 protocol ip parent 1:0 prio 1 u32 \
    match ip dport 4420 0xffff flowid 1:1
tc qdisc add dev eth0 parent 1:1 handle 10: netem delay 50ms loss 0.5%

# Remove
tc qdisc del dev eth0 root

# Measure impact on NVMe-oF latency
fio --name=nvmeof-degraded --filename=/dev/nvme1n1 \
    --rw=randread --bs=4k --ioengine=libaio --iodepth=32 --runtime=30 \
    --percentile_list=50,99,99.9
```

---

## 4. Fault Injection Test Suite Design

```
Comprehensive fault injection test suite for a storage system:

Level 1: Component isolation tests
  T1.1: Single OSD failure → verify data remains accessible (3-replica pool)
  T1.2: Single drive I/O error → verify filesystem/RAID handles gracefully
  T1.3: Network packet loss 1% → verify NVMe-oF reconnect handles gracefully
  T1.4: Metadata server restart → verify client reconnect completes

Level 2: Concurrent failure tests
  T2.1: Two OSDs fail simultaneously → verify cluster detects correct quorum loss
  T2.2: Drive failure + high load → verify rebuild doesn't stall with 10% spare I/O
  T2.3: Network partition + write in-flight → verify exactly-once write semantics

Level 3: Slow failure (gray failure) tests
  T3.1: Drive latency 100ms (not failed) → verify application SLO not breached
  T3.2: Drive latency increasing over 1 hour → verify detection and eviction
  T3.3: OSD "alive but wrong" (returns old data) → verify Ceph scrub detects

Level 4: Recovery tests
  T4.1: Full cluster restart → verify recovery time within SLO
  T4.2: Metadata corruption → verify thin_check detects, thin_repair recovers
  T4.3: Partial write during power loss → verify filesystem consistency (fsck clean)

Level 5: Cascade tests
  T5.1: Drive failure triggers rebuild → rebuild I/O causes second drive to fail
         → verify RAID-6 handles double failure correctly
  T5.2: High load → GC pressure → latency spike → client timeout → retry storm
         → verify system reaches stable state (not cascading)

Pass/fail criteria:
  Each test has: expected behavior, measurable metric, and time bound
  Auto-report: test duration, recovery time, any data integrity violations
  Alert if: data integrity violation (immediate escalation) or recovery > SLO
```

---

## 5. Self-Check

1. dm-flakey's `drop_writes` feature silently discards writes without returning an error. What storage failure scenario does this simulate?
2. Why is it important to test with silent corruption (`corrupt_bio_byte`) in addition to visible errors?
3. A fault injection test passes in isolation but fails when combined with high background load. What does this reveal?
4. What is the difference between testing "OSD process kill" vs "OSD network partition" for a Ceph cluster?

## 7. Answers

1. Power loss mid-write, or a malfunctioning drive that acknowledges writes without actually writing them ("lying drive"). Silent discard simulates: (a) power cut before drive NAND program completes, (b) buggy drive firmware that returns success without persistence. Applications relying on write success = persistence are vulnerable. Correct behavior: either WAL detects missing writes on replay, or application uses fsync + verify.
2. Many storage bugs only manifest as silent corruption — the system returns "success" and no error is visible, but data is quietly wrong. A system that handles `-EIO` perfectly may still serve corrupt data to applications. Silent corruption tests verify checksums, comparisons, and integrity checking are functioning. These are the most dangerous failure modes because they can persist undetected for months.
3. The system has a load-dependent failure mode — a resource contention issue that only appears under combined stress. Common examples: (a) background fault recovery I/O competes with foreground I/O, reducing headroom → retry storm; (b) recovery path has a lock that's uncontested in isolation but contested under load; (c) monitoring/alerting system becomes slow under load and misses the fault. Real production failures often occur at the intersection of multiple stressors — this test found a realistic failure mode.
4. "OSD process kill" vs "OSD network partition": Kill: OSD process terminates cleanly, OS sends TCP RST/FIN, other nodes detect failure within seconds via connection reset. Network partition: OSD is still running, heartbeats time out, detection takes 10-30s (based on heartbeat interval). The OSD may still accept writes from clients it can reach. Kill tests fast failure detection. Partition tests: split-brain prevention, slow failure detection, and potentially a gray failure scenario where the partitioned OSD serves stale reads to clients that can still reach it.

---

# Day 17: Gray Failure Detection

## Learning Objectives
- Understand the gray failure taxonomy (slow, intermittent, partial)
- Know detection strategies at different layers
- Design a gray failure detection system for storage
- Understand the "Fail-Slow at Scale" findings from FAST 2018

---

## 1. Gray Failure Taxonomy

```
Hard failure: component completely dead
  - Drive returns -EIO on every read
  - Network link down (no packets)
  - Server process crashed
  Detection: immediate (error signals propagate)
  Impact: clear, bounded — RAID/replication handles

Gray failure: component degraded but not dead
  - Drive returns correct data but with 500ms latency (normally 100µs)
  - Network link drops 0.1% of packets (TCP retransmits, latency increases)
  - Server process running but only handling 10% of requests (others queue)
  Detection: difficult (no clear error signal)
  Impact: often worse than hard failure — affects all users subtly

Types of gray failures:
  1. Fail-slow: correct results but much higher latency
     Example: drive with growing bad sector map → ECC retries → 5-10× slower
     
  2. Intermittent: works correctly most of the time, fails occasionally
     Example: NIC that drops packets under high load
     
  3. Partial: subset of operations fail, others succeed
     Example: drive that can read but can't write to one zone
     
  4. Wrong: returns incorrect data (silent corruption)
     Example: drive with SCSI-level bug returning wrong LBA data
```

---

## 2. Fail-Slow: The FAST 2018 Findings

```
"Fail-Slow at Scale" (Gunawi et al., FAST 2018):
  Studied 136 fail-slow incidents from public postmortems + operator reports

Key findings:

  1. Fail-slow is common (not rare):
     100+ reported incidents in major cloud providers
     Many attributed to: aging hardware, firmware bugs, config drift

  2. Detection is slow (median 1-3 days):
     Hard failures: detected in seconds-minutes
     Gray failures: often noticed when users complain (days later)
     
  3. Impact is severe:
     Gray failures often MORE impactful than hard failures
     Hard failure → system reroutes immediately
     Gray failure → system sends requests to slow component → tail latency explodes

  4. Common causes:
     Aging drives (nearing TBW limit) → increasing ECC retries → slow reads
     Overheating → throttling → slower performance
     Firmware bugs triggered by specific load patterns
     Network congestion at specific times

  5. Cascading effects:
     One slow node → tail latency → client timeouts → retries → more load → worse
```

---

## 3. Detection Strategies

```
Strategy 1: Latency-based detection (most effective for storage)
  Measure: per-device I/O latency continuously
  Threshold: alert if p99 latency > N× baseline for sustained period
  
  Implementation:
    # Per-device latency tracking with bpftrace
    bpftrace -e '
    tracepoint:block:block_rq_issue { @s[args.dev, args.sector] = nsecs; }
    tracepoint:block:block_rq_complete {
        $k = (args.dev, args.sector);
        if (@s[$k]) {
            @p99[args.dev] = hist((nsecs - @s[$k]) / 1000);
            delete(@s[$k]);
        }
    }
    interval:s:60 { print(@p99); clear(@p99); }'
    
    # Alert if: p99_current > 3× p99_baseline for 5 consecutive minutes
    
  Challenge: what is "baseline"? Must track rolling baseline, not fixed threshold
    Rolling baseline: median of last N hours
    Alert: current p99 > 3× rolling_p99_baseline

Strategy 2: Comparison-based detection (RAID/replication context)
  In a replica group, compare response times across replicas:
    Primary: 1ms response
    Replica 1: 1.1ms response
    Replica 2: 300ms response ← gray failure candidate
  
  Alert: replica latency deviation > N× median replica latency
  
  This is how: Ceph detects slow OSDs (osd_op_complaint_time threshold)
    ceph config set osd osd_op_complaint_time 30  # alert if op takes > 30s

Strategy 3: Hedged requests (latency hiding)
  Send same request to multiple replicas
  Use whichever responds first
  Track: if one replica consistently loses the race → it's slow
  
  Cost: 2× read I/O (or: send hedge only if primary is slow after timeout)
  Used by: Bigtable, Dynamo for read tail latency reduction
  
  Hedged request implementation:
    Send request to primary
    If no response in 95th percentile latency → also send to replica
    Use first response, cancel second
    Log: which replica won each race → detect consistently slow replicas

Strategy 4: Watchdog scrubbing
  Periodically write known data, read back, measure latency + verify correctness
  Detects: slow reads, slow writes, silent corruption
  Implementation: independent watchdog process, not in I/O path
  
  Alert triggers:
    Read latency > 2× write latency (asymmetric degradation)
    Read value ≠ written value (silent corruption)
    Watchdog times out (complete failure)
```

---

## 4. Gray Failure Detection System Design

```
Production gray failure detection architecture:

Metrics collection (every 10 seconds):
  Per-device: p50, p95, p99, p99.9 I/O latency
  Per-device: error count, retry count, ECC correction count
  Per-node: CPU utilization, temperature, network throughput
  Per-service: request latency, timeout rate, error rate

Baseline tracking (rolling window):
  Rolling 7-day baseline per device/time-of-day (avoid alerting on known patterns)
  Example: disk latency is 20% higher during nightly backup → normalize for this

Alert conditions:
  Level 1 (warning): p99 > 2× baseline for 5 min
  Level 2 (critical): p99 > 5× baseline for 2 min
  Level 3 (emergency): p99 > 10× baseline for 30 sec, or any corruption detected

Automated remediation:
  Level 1: increase monitoring frequency (30s → 5s)
  Level 2: remove slow component from load balancer (hedged requests to others)
  Level 3: remove from cluster immediately, page on-call engineer

Correlation engine:
  Do multiple devices show latency increase simultaneously?
    → Network or shared infrastructure issue (not individual device)
  Is only one device slow while others are normal?
    → Individual device gray failure → replace it
```

---

## 5. Self-Check

1. Why is a gray failure (fail-slow) often more impactful than a hard failure?
2. Hedged requests detect slow replicas as a side effect. How?
3. A storage drive's p99 latency is 500µs (baseline 100µs). What is your detection threshold and why?
4. Why should gray failure detection use a rolling baseline rather than a fixed threshold?

## 7. Answers

1. Hard failure: system detects immediately (connection reset, -EIO), removes failed component from rotation, traffic reroutes to healthy replicas — impact is brief. Gray failure: system sends requests to slow component as if it's healthy (no error signal). Every request to that component is slow. With 3 replicas and "fastest wins" reads: one slow replica adds no latency. But for writes requiring all replicas: write latency = max(replica latencies) → slow replica is always the bottleneck. For quorum-based systems: slow replicas hold up every operation until they respond.
2. Each request records: which replica responded first. Over many requests, a slow replica consistently loses the race (other replicas respond faster). Monitoring the "win rate" per replica: if replica R wins only 5% of races (vs expected 33% for 3 replicas), R is likely slow. This requires no explicit latency measurement — the race outcome is the signal.
3. Alert threshold: p99 > 3× baseline = 300µs, sustained for 5 minutes. Reasoning: 5× would be 500µs (current level, already elevated). 3× catches degradation before it becomes 5×. 2× might be too sensitive (normal variance). 5 minutes prevents transient spikes from triggering false alerts. A 5× sustained threshold (500µs for 5 min) would trigger an emergency response.
4. Fixed threshold: doesn't account for normal variation. A backup that runs every night causes legitimate p99 elevation — a fixed threshold would alert every night. Rolling baseline: tracks the system's "normal" at each time of day and day of week. Alerts only when current behavior deviates from what's normal for this time. Reduces false positives, catches genuine anomalies.

---

# Day 18: SLO Design for Storage

## Learning Objectives
- Understand the distinction between availability, reliability, and durability
- Know how to choose the right percentile for storage SLOs
- Calculate error budgets and burn rates
- Design a cascading SLO structure (storage → service → user-facing)

---

## 1. Storage SLO Terminology

```
Availability: fraction of time service is up and handling requests
  Formula: availability = uptime / (uptime + downtime)
  Typical: 99.9% (8.7h downtime/yr), 99.99% (52min), 99.999% (5.3min)
  
  Storage availability: can clients read/write?
  Not the same as: data intact (data could be there but service is down)

Reliability: probability of returning correct result per request
  Formula: reliability = correct_responses / total_requests
  Typical: 99.99%+ (less than 1 error per 10,000 requests)
  
  Storage reliability: reads return correct data, writes are persisted

Durability: probability of data surviving over time
  Formula: 1 - P(data_loss_in_N_years)
  Typical: 99.999999999% (11 nines) = ~1 object lost per billion per 10 years
  
  Storage durability: data not lost due to hardware failures
  Much harder to measure (rare events, long time horizon)
  Calculated from: MTTF per drive × RAID/replication protection level

The three are related but independent:
  High availability + low durability: system is up but data is silently corrupted
  High durability + low availability: data is safe but service is often down
  High reliability + low durability: results are correct but data can be lost
```

---

## 2. Choosing the Right Percentile

```
The percentile debate:
  Average latency: hides tail, useless for SLO
  p99: the 99th percentile user experience — good starting point
  p99.9: the worst 0.1% — appropriate for latency-critical applications
  p99.99: the worst 0.01% — almost always infrastructure noise (GC, OS jitter)

Rules for choosing percentile:

Rule 1: SLO percentile must be > request rate × measurement window
  Example: 1000 requests/second, 1-minute window = 60,000 requests
  p99.99 = 6 requests per minute — measurement is noisy (too few samples)
  p99 = 600 requests per minute — statistically meaningful

Rule 2: Match percentile to user experience
  p50 (median): "most users" — ignore, masks tail
  p99: "1 in 100 users has bad experience" — good for storage API
  p99.9: "1 in 1000" — good for databases used by financial applications
  p99.99: "1 in 10,000" — good for low-latency trading, rarely achievable in practice

Rule 3: Percentile must be measurable in practice
  p99.9 requires 1000 samples to be statistically meaningful
  p99.99 requires 10,000 samples
  Short measurement windows + low traffic = use lower percentile

Storage SLO example:
  Object storage (S3-like): p99 < 100ms read, p99 < 200ms write
  Block storage (EBS-like): p99 < 1ms read, p99 < 1ms write
  Database storage: p99.9 < 2ms read, p99.9 < 5ms write
  Backup storage: p95 < 60min backup completion (different metric)
```

---

## 3. Error Budget Calculation

```
Error budget: amount of downtime/errors "allowed" per SLO period

Calculation:
  SLO: 99.9% availability per month
  Month: 30 days × 24h × 60min = 43,200 minutes
  Error budget: (1 - 0.999) × 43,200 = 43.2 minutes per month
  
  If 44 minutes of downtime occurs: SLO violated, error budget exhausted

Error budget burning:
  Burn rate: how fast error budget is being consumed
  Burn rate = 1.0 = consuming budget at exactly sustainable rate
  Burn rate = 10 = consuming 10× faster than sustainable
  
  Alert strategy:
    Fast burn alert (immediate): burn rate > 14.4 for 5 minutes
      (14.4× = would exhaust monthly budget in 2 hours)
    Slow burn alert (predictive): burn rate > 3 for 1 hour
      (3× = would exhaust monthly budget in 10 days)

SLO violation = team must post-mortem + review why budget was consumed
Error budget healthy = team can deploy features, take risks

Cascading SLO design:
  Storage layer SLO must be tighter than the service using it:
  
  User-facing service SLO: p99 < 200ms (99.9% availability)
  API layer SLO: p99 < 100ms (99.95% availability)
  Database SLO: p99 < 20ms (99.99% availability)
  Storage SLO: p99 < 5ms (99.99% availability)
  
  If storage p99 is 5ms, database p99 can't be 20ms unless other operations
  are fast (query execution + network + other storage ops)
  Rule: storage SLO latency × fan-out should leave headroom for service SLO
```

---

## 4. Designing a Storage SLO Framework

```
Complete SLO framework for a storage service:

SLO 1: Availability
  "99.99% of storage API requests return a response (success or error) within 30 seconds"
  Measurement: (non-timeout responses) / total_requests
  Window: 30-day rolling
  Error budget: 4.38 minutes/month

SLO 2: Write Durability  
  "Data written successfully (fsync acknowledged) will survive any single-device failure"
  Measurement: recovery tests (weekly: kill one OSD, verify data intact)
  Cannot measure directly (rare events) — verify protection level is in place

SLO 3: Read Latency
  "p99 read latency < 5ms, measured over 1-minute windows, 99.9% of the time"
  Measurement: per-request latency at storage API layer
  Error budget: 0.1% of minutes may have p99 > 5ms = 4.32 min/month

SLO 4: Write Latency
  "p99 write latency < 10ms (including fsync), measured over 1-minute windows, 99.9% of the time"

SLO 5: Data Integrity
  "Zero silent data corruption (verified by weekly scrub + per-read checksums)"
  Measurement: scrub error rate, application checksum mismatch rate
  Error budget: 0 (any corruption is an SLO violation requiring immediate response)

Monitoring implementation:
  Prometheus + Grafana for real-time SLO tracking
  SLO burn rate alerts in PagerDuty
  Monthly SLO review: did we meet? what consumed budget?
```

---

# Days 19-21: Runbooks, Post-Incident Analysis & Week Review

---

## Day 19: Runbook Design — Storage Incident Response

```
Good runbook properties:
  Executable by on-call engineer without deep storage expertise
  Unambiguous: one correct action per step
  Tested: validated by someone other than the author
  Linked: connects to relevant monitoring, logs, escalation
  Maintained: updated after every incident where runbook was used (and found wrong)

Runbook template:
  Title: [Incident type]
  Trigger: [When to use this runbook]
  Impact: [Who is affected, what they experience]
  Symptoms: [What monitoring alerts fired, what you see in logs]
  Steps:
    1. [Action] → [Expected result] → [If unexpected: see Step X or escalate]
    2. ...
  Escalation: [When to escalate, who to call]
  Resolution: [How to confirm incident is resolved]
  Post-incident: [Link to post-mortem template]
```

### Sample Runbook: NVMe Drive Failure in RAID Array

```
Title: Single NVMe Drive Failure in md RAID-6 Array
Trigger: Alert "md_array_degraded" fires for /dev/md0
Impact: Array degraded (reduced redundancy), performance reduced during rebuild
         Users: no data loss or access interruption expected
Symptoms:
  - Alert: "md_array_degraded: /dev/md0 has 1 failed device"
  - dmesg: "nvme0n1: I/O error" or "md: disk failure"
  - /proc/mdstat shows "(F)" next to failed device

Steps:
  1. Confirm which device failed:
     cat /proc/mdstat | grep -A5 "md0"
     mdadm --detail /dev/md0 | grep -E "Failed|State"
     Expected: one device in "faulty" state
     
  2. Verify data integrity (critical step):
     md5sum /path/to/validation/file  (compare to stored checksum)
     Expected: checksum matches → data intact
     If mismatch: STOP, escalate to storage-oncall immediately
  
  3. Identify physical drive:
     ls -la /dev/disk/by-id/ | grep $(basename $failed_dev)
     Note drive serial number for physical identification
  
  4. Remove failed drive from array (safe — RAID-6 tolerates 2 failures):
     mdadm /dev/md0 --fail $failed_dev
     mdadm /dev/md0 --remove $failed_dev
     Expected: /proc/mdstat shows one fewer active device
  
  5. Create ticket for drive replacement (hardware team)
     Priority: High (within 4 hours — second failure = data loss risk)
     Include: hostname, drive serial, bay number, ticket #
  
  6. After replacement, add new drive:
     mdadm /dev/md0 --add /dev/new_drive
     Expected: /proc/mdstat shows rebuild starting
     Monitor: watch -n5 cat /proc/mdstat (rebuild progress)
  
  7. Monitor rebuild to completion:
     Typical rebuild time: [8TB drive at 150MB/s = ~15 hours]
     Alert if rebuild speed < 10MB/s (indicates second drive stress)
  
Escalation:
  If STEP 2 shows data mismatch → page storage-lead immediately
  If STEP 4 fails → page storage-lead immediately
  If two drives fail simultaneously → CRITICAL, page all storage team
  
Resolution:
  /proc/mdstat shows [UU] (all devices active) with no "(F)"
  mdadm --detail shows "State: clean"
  
Post-incident: file post-mortem if rebuild took >24h or data integrity check failed
```

---

## Day 20: Post-Incident Analysis — Storage Failure Taxonomy

```
Storage failure taxonomy (for consistent post-mortem categorization):

Category 1: Hardware Failures
  1.1 Drive failure (hard): sudden complete failure
  1.2 Drive failure (soft/gray): degraded performance before failure
  1.3 Controller failure: RAID controller, HBA, NIC failure
  1.4 Power supply: PSU failure, UPS failure, power quality
  1.5 Connectivity: cable, backplane, switch port failure

Category 2: Software Failures
  2.1 Filesystem corruption: journal error, metadata inconsistency
  2.2 Storage driver bug: kernel panic, data corruption in driver
  2.3 Application storage bug: incorrect fsync usage, data corruption
  2.4 Configuration error: wrong mount options, wrong RAID level
  2.5 Upgrade failure: firmware/kernel update breaks storage

Category 3: Operational Failures
  3.1 Capacity exhaustion: pool full, filesystem full, inode exhaustion
  3.2 Backup failure: backup not running, backup corrupt
  3.3 Runbook failure: wrong procedure followed, runbook outdated
  3.4 Monitoring failure: alert not configured, alert went to wrong team
  3.5 Human error: wrong device formatted, accidental deletion

Category 4: Cascading/Systemic Failures
  4.1 Thundering herd: recovery I/O overwhelms surviving hardware
  4.2 Correlated failure: power domain, RAID controller, same drive batch
  4.3 GC pressure cascade: GC stall → latency spike → timeout storm → more load
  4.4 Split-brain: storage nodes disagree on data state

Post-mortem template for storage incidents:
  Impact: duration, users affected, data loss (Y/N, amount)
  Timeline: when detected, when mitigated, when resolved
  Root cause: taxonomy category + specific cause
  Contributing factors: what allowed this to happen
  Detection: how we found out (monitoring? user report? how long before detection?)
  Response: were runbooks followed? did they work?
  Action items: what we're doing to prevent recurrence
```

---

## Day 21: Week 3 Review — Reliability Architecture

## Design Scenario: Diagnosing Storage Latency Spikes

**Brief:** A distributed object store is reporting p99 write latency of 2-8 seconds (normal: 50ms). This happens 2-3 times per day for 10-20 minutes. No alerts fired until users complained.

**Investigation methodology using Week 3 tools:**

**Step 1: Characterize the failure (Day 17 — gray failure detection)**
- Is it all writes or specific shard/OSD? → RAID/replication scope
- Is it latency spike or error rate increase? → fail-slow not hard failure
- Does it correlate with time of day? → might be scheduled job
- Collect: per-OSD latency during next occurrence via bpftrace

**Step 2: Hypothesis (Day 15 — chaos engineering mindset)**
- H1: GC pressure from compaction (LSM-tree) → stalls write path
- H2: Thin pool approaching threshold → metadata operations slow
- H3: One OSD is fail-slow, pulling up p99 for writes touching it
- H4: Network congestion at specific times → NVMe-oF latency spikes

**Step 3: Fault injection to reproduce (Day 16)**
- Test H1: inject RocksDB write stall via `db.PauseBackgroundWork()` → does application see same pattern?
- Test H3: inject 100ms latency via dm-delay on one OSD → does p99 match observed?

**Step 4: Detection gap (Day 18 — SLO design)**
- Why didn't monitoring alert? Review SLO: was threshold too loose?
- Add: per-OSD latency p99 tracking with 3× rolling baseline alert
- Add: write stall counter monitoring from RocksDB statistics

**Step 5: Runbook (Day 19)**
- Document: "Elevated write latency" runbook with per-OSD diagnostics
- Include: how to identify which OSD is slow, how to remove from write path

**Architectural fix (after root cause confirmed):**
If GC pressure: tune compaction concurrency, add write throttling before stall
If fail-slow OSD: implement hedged writes, automatic slow-OSD eviction
If thin pool: add pool utilization monitoring with 80% alert threshold

---

## Tomorrow: Day 22 — Tiered Storage Automation: Heat Tracking

Week 4 begins: advanced architecture topics. We design automated
tiering policies — heat tracking models, promotion/demotion rules,
and hysteresis to prevent data oscillating between tiers.
