# SPDK Study Docs Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a study-focused SPDK documentation subtree with index + learning path + topic pages, and add a dedicated SPDK section to weekly updates.

**Architecture:** Keep the docs markdown-first and consistent with current storage-study patterns: one roll-up index (`spdk.md`) links to focused subpages in `docs/categories/spdk/`. Weekly updates remain in `docs/updates/YYYY-Www.md`, with an explicit `## SPDK` section added to the current weekly file and future template shape preserved in content conventions.

**Tech Stack:** Markdown files, git.

---

## File Structure Map

### Create
- `docs/categories/spdk.md`
- `docs/categories/spdk/learning-path.md`
- `docs/categories/spdk/overview.md`
- `docs/categories/spdk/build-and-env.md`
- `docs/categories/spdk/bdev-framework.md`
- `docs/categories/spdk/nvme-and-nvme-of.md`
- `docs/categories/spdk/blobfs-and-accel.md`
- `docs/categories/spdk/vhost-and-virtio.md`
- `docs/categories/spdk/rpc-and-tooling.md`
- `docs/categories/spdk/perf-and-benchmarking.md`
- `docs/categories/spdk/integration-patterns.md`
- `docs/categories/spdk/troubleshooting.md`

### Modify
- `README.md` (if missing or stale category links)
- `docs/updates/2026-W14.md` (add dedicated `## SPDK` section)

### Responsibility boundaries
- `docs/categories/spdk.md`: navigation hub, one-line page descriptions, pointer to weekly SPDK updates.
- `docs/categories/spdk/learning-path.md`: ordered path from beginner to advanced.
- Topic pages under `docs/categories/spdk/`: concise study units by subsystem/topic.
- `docs/updates/2026-W14.md`: explicit weekly SPDK tracking section.

---

### Task 1: Create SPDK index page

**Files:**
- Create: `docs/categories/spdk.md`

- [ ] **Step 1: Write the SPDK index page**

Create `docs/categories/spdk.md` with exactly:

```markdown
# SPDK Index

Study-focused navigation for SPDK (Storage Performance Development Kit), including learning flow and core subsystem topics.

## Pages

| Page | Description |
|------|-------------|
| [Learning Path](./spdk/learning-path.md) | Recommended beginner → advanced study sequence |
| [Overview](./spdk/overview.md) | What SPDK is, where it fits, and core architecture |
| [Build and Environment](./spdk/build-and-env.md) | Build prerequisites, setup, and runtime basics |
| [bdev Framework](./spdk/bdev-framework.md) | Block device abstraction and module model |
| [NVMe and NVMe-oF](./spdk/nvme-and-nvme-of.md) | Local and fabric NVMe paths in SPDK |
| [BlobFS and Accel](./spdk/blobfs-and-accel.md) | Blobstore/BlobFS and acceleration framework concepts |
| [Vhost and Virtio](./spdk/vhost-and-virtio.md) | Virtualization-facing data paths and usage patterns |
| [RPC and Tooling](./spdk/rpc-and-tooling.md) | JSON-RPC workflow, scripts, and admin tooling |
| [Performance and Benchmarking](./spdk/perf-and-benchmarking.md) | Measuring and tuning SPDK performance |
| [Integration Patterns](./spdk/integration-patterns.md) | Practical integration approaches with other stacks |
| [Troubleshooting](./spdk/troubleshooting.md) | Common failure modes and debugging checklist |

## Latest SPDK Weekly Notes
- See the SPDK section in [2026-W14 updates](../updates/2026-W14.md).

## Entry Template

### <Topic Title>
**Abstract:** 2–4 sentences.
**Key points:**
- ...
- ...
- ...
**Links:**
- <link title> — <url>

## Curation Guidelines
- Keep abstracts short and neutral.
- Keep key points to 3–7 bullets.
- Include at least one authoritative link.
- Use descriptive link titles, not bare URLs.
- Prefer official SPDK sources first; include high-quality community tutorials when clearly useful.
```

- [ ] **Step 2: Verify index links count**

Run: `grep -c "./spdk/" docs/categories/spdk.md`
Expected: `11`

- [ ] **Step 3: Commit Task 1**

Run:
```bash
git add docs/categories/spdk.md
git commit -m "docs: add SPDK index page"
```

---

### Task 2: Create learning path page

**Files:**
- Create: `docs/categories/spdk/learning-path.md`

- [ ] **Step 1: Write learning path content**

Create `docs/categories/spdk/learning-path.md` with exactly:

```markdown
# SPDK Learning Path

A study-oriented sequence for learning SPDK from fundamentals to practical integration.

## Sequence

1. [Overview](./overview.md)
2. [Build and Environment](./build-and-env.md)
3. [bdev Framework](./bdev-framework.md)
4. [NVMe and NVMe-oF](./nvme-and-nvme-of.md)
5. [RPC and Tooling](./rpc-and-tooling.md)
6. [Performance and Benchmarking](./perf-and-benchmarking.md)
7. [Vhost and Virtio](./vhost-and-virtio.md)
8. [Integration Patterns](./integration-patterns.md)
9. [BlobFS and Accel](./blobfs-and-accel.md)
10. [Troubleshooting](./troubleshooting.md)

## Milestones
- Understand SPDK’s user-space, polled-mode design and where it fits.
- Build and run core examples and RPC workflows.
- Explain bdev and NVMe/NVMe-oF data paths.
- Perform basic performance measurements and interpret results.
- Diagnose common setup and runtime issues.

## Study Notes Format

### <Session Topic>
**Goal:** 1 sentence.
**What to read:**
- ...
**Hands-on check:**
- ...
**Questions to answer:**
- ...
```

- [ ] **Step 2: Verify all sequence links exist in page**

Run: `grep -c "](./" docs/categories/spdk/learning-path.md`
Expected: `10`

- [ ] **Step 3: Commit Task 2**

Run:
```bash
git add docs/categories/spdk/learning-path.md
git commit -m "docs: add SPDK learning path"
```

---

### Task 3: Create SPDK topic pages (set A)

**Files:**
- Create: `docs/categories/spdk/overview.md`
- Create: `docs/categories/spdk/build-and-env.md`
- Create: `docs/categories/spdk/bdev-framework.md`
- Create: `docs/categories/spdk/nvme-and-nvme-of.md`
- Create: `docs/categories/spdk/rpc-and-tooling.md`

- [ ] **Step 1: Write `overview.md`**

```markdown
# SPDK Overview

SPDK is a user-space, polled-mode storage framework designed to reduce latency and increase throughput by minimizing kernel transitions and lock contention.

## Entries

### Architecture Model
**Abstract:** SPDK runs critical datapath logic in user space and relies on polling to avoid interrupt overhead in performance-sensitive paths. It is commonly paired with DPDK and hugepages for memory and device access behavior.
**Key points:**
- User-space design targets predictable low-latency I/O paths.
- Polling favors throughput/latency at the cost of dedicated CPU usage.
- SPDK components are modular and service-oriented.
**Links:**
- SPDK Documentation — <url>
- SPDK GitHub Repository — <url>

## Curation Guidelines
- Keep abstracts short and neutral.
- Keep key points to 3–7 bullets.
- Include at least one authoritative link.
- Use descriptive link titles, not bare URLs.
```

- [ ] **Step 2: Write `build-and-env.md`**

```markdown
# SPDK Build and Environment

This page covers build prerequisites, environment setup, and first-run considerations for SPDK study and experimentation.

## Entries

### Build and Setup Basics
**Abstract:** Building SPDK typically requires a Linux toolchain plus dependencies used by DPDK and optional SPDK subsystems. Runtime setup often includes hugepages, PCI binding choices, and permissions handling.
**Key points:**
- Confirm compiler and dependency requirements before build.
- Validate hugepage setup before launching target processes.
- Document local environment assumptions for repeatable study sessions.
**Links:**
- SPDK Getting Started Guide — <url>
- High-Quality Community Build Walkthrough — <url>

## Curation Guidelines
- Keep abstracts short and neutral.
- Keep key points to 3–7 bullets.
- Include at least one authoritative link.
- Use descriptive link titles, not bare URLs.
```

- [ ] **Step 3: Write `bdev-framework.md`**

```markdown
# SPDK bdev Framework

The bdev framework is SPDK’s block abstraction layer used to compose storage backends and services in a consistent way.

## Entries

### bdev Abstraction and Modules
**Abstract:** bdev provides a common API across multiple underlying storage implementations while preserving high-performance semantics. Modules can be stacked or combined to create richer virtual block devices.
**Key points:**
- bdev standardizes block operations across backends.
- Layered modules enable composition without rewriting consumers.
- Understanding module boundaries is key for troubleshooting and performance.
**Links:**
- SPDK bdev Docs — <url>
- SPDK bdev Source (GitHub) — <url>

## Curation Guidelines
- Keep abstracts short and neutral.
- Keep key points to 3–7 bullets.
- Include at least one authoritative link.
- Use descriptive link titles, not bare URLs.
```

- [ ] **Step 4: Write `nvme-and-nvme-of.md`**

```markdown
# SPDK NVMe and NVMe-oF

This page maps SPDK’s NVMe local access patterns and NVMe-oF transport usage for both target and initiator perspectives.

## Entries

### NVMe Datapath Concepts
**Abstract:** SPDK provides NVMe userspace drivers and framework integration for low-overhead command submission/completion. NVMe-oF extends these patterns across network fabrics while preserving NVMe command semantics.
**Key points:**
- Local NVMe and NVMe-oF share conceptual command flow roots.
- Transport configuration has direct performance and operability impact.
- Queue and polling behavior should be studied alongside workload shape.
**Links:**
- SPDK NVMe Documentation — <url>
- SPDK NVMe-oF Documentation — <url>

## Curation Guidelines
- Keep abstracts short and neutral.
- Keep key points to 3–7 bullets.
- Include at least one authoritative link.
- Use descriptive link titles, not bare URLs.
```

- [ ] **Step 5: Write `rpc-and-tooling.md`**

```markdown
# SPDK RPC and Tooling

SPDK control-plane operations are commonly driven through JSON-RPC, supporting scripted workflows and repeatable configuration.

## Entries

### RPC Workflow Fundamentals
**Abstract:** RPC endpoints expose subsystem lifecycle and runtime operations, making SPDK behavior scriptable for study and automation. Clear command sequencing is essential to avoid inconsistent target state.
**Key points:**
- JSON-RPC is central to SPDK operational workflows.
- Script-first operation improves reproducibility in labs.
- Validate RPC responses as part of troubleshooting discipline.
**Links:**
- SPDK RPC Documentation — <url>
- SPDK `scripts/rpc.py` Reference — <url>

## Curation Guidelines
- Keep abstracts short and neutral.
- Keep key points to 3–7 bullets.
- Include at least one authoritative link.
- Use descriptive link titles, not bare URLs.
```

- [ ] **Step 6: Verify set A files exist and are non-empty**

Run:
```bash
for f in docs/categories/spdk/overview.md docs/categories/spdk/build-and-env.md docs/categories/spdk/bdev-framework.md docs/categories/spdk/nvme-and-nvme-of.md docs/categories/spdk/rpc-and-tooling.md; do test -s "$f" || exit 1; done; echo "SPDK SET A OK"
```
Expected: `SPDK SET A OK`

- [ ] **Step 7: Commit Task 3**

Run:
```bash
git add docs/categories/spdk/overview.md docs/categories/spdk/build-and-env.md docs/categories/spdk/bdev-framework.md docs/categories/spdk/nvme-and-nvme-of.md docs/categories/spdk/rpc-and-tooling.md
git commit -m "docs: add core SPDK study topic pages"
```

---

### Task 4: Create SPDK topic pages (set B)

**Files:**
- Create: `docs/categories/spdk/perf-and-benchmarking.md`
- Create: `docs/categories/spdk/vhost-and-virtio.md`
- Create: `docs/categories/spdk/integration-patterns.md`
- Create: `docs/categories/spdk/blobfs-and-accel.md`
- Create: `docs/categories/spdk/troubleshooting.md`

- [ ] **Step 1: Write `perf-and-benchmarking.md`**

```markdown
# SPDK Performance and Benchmarking

This page focuses on measuring SPDK behavior and interpreting throughput/latency trade-offs under realistic test conditions.

## Entries

### Benchmarking Discipline
**Abstract:** Performance testing in SPDK requires controlling workload shape, queue depth, CPU pinning, and transport/device configuration. Results should be interpreted with both averages and tail-latency in mind.
**Key points:**
- Keep benchmark configurations explicit and repeatable.
- Correlate tuning changes with measurable deltas.
- Avoid comparing results across mismatched environments.
**Links:**
- SPDK Performance Reports/Guides — <url>
- High-Quality Community Benchmarking Tutorial — <url>

## Curation Guidelines
- Keep abstracts short and neutral.
- Keep key points to 3–7 bullets.
- Include at least one authoritative link.
- Use descriptive link titles, not bare URLs.
```

- [ ] **Step 2: Write `vhost-and-virtio.md`**

```markdown
# SPDK Vhost and Virtio

SPDK supports virtualization-oriented datapaths through vhost and virtio integrations.

## Entries

### Virtualized I/O Paths
**Abstract:** Vhost/virtio support bridges SPDK capabilities into VM-oriented deployments, where queue behavior and host/guest configuration affect observed performance. Correct layering and device mapping are critical for stable operation.
**Key points:**
- Understand host/guest boundary responsibilities.
- Queue and CPU placement choices strongly impact outcomes.
- Keep configuration docs close to measured results.
**Links:**
- SPDK vhost Documentation — <url>
- SPDK Virtio Documentation — <url>

## Curation Guidelines
- Keep abstracts short and neutral.
- Keep key points to 3–7 bullets.
- Include at least one authoritative link.
- Use descriptive link titles, not bare URLs.
```

- [ ] **Step 3: Write `integration-patterns.md`**

```markdown
# SPDK Integration Patterns

This page summarizes practical ways to integrate SPDK with broader storage stacks and operational tooling.

## Entries

### Integration Decision Patterns
**Abstract:** Integration choices should be guided by latency goals, operational complexity tolerance, and deployment environment constraints. Narrow, well-scoped adoption often reduces risk during early stages.
**Key points:**
- Start with clear performance/operability goals.
- Keep interfaces and ownership boundaries explicit.
- Prefer incremental rollout over broad initial replacement.
**Links:**
- SPDK Integration Examples — <url>
- High-Quality Community Integration Case Study — <url>

## Curation Guidelines
- Keep abstracts short and neutral.
- Keep key points to 3–7 bullets.
- Include at least one authoritative link.
- Use descriptive link titles, not bare URLs.
```

- [ ] **Step 4: Write `blobfs-and-accel.md`**

```markdown
# SPDK BlobFS and Accel

Blobstore/BlobFS and acceleration framework features extend SPDK use cases beyond basic block transport.

## Entries

### Blobstore and Acceleration Concepts
**Abstract:** Blobstore-based abstractions and acceleration modules can help compose higher-level services in SPDK ecosystems. Study should focus on where these abstractions fit and what trade-offs they introduce.
**Key points:**
- Understand when blob-level abstractions are preferable.
- Acceleration features should be evaluated with real workload goals.
- Keep subsystem-level assumptions explicit in notes.
**Links:**
- SPDK BlobFS/Blobstore Documentation — <url>
- SPDK Accel Framework Documentation — <url>

## Curation Guidelines
- Keep abstracts short and neutral.
- Keep key points to 3–7 bullets.
- Include at least one authoritative link.
- Use descriptive link titles, not bare URLs.
```

- [ ] **Step 5: Write `troubleshooting.md`**

```markdown
# SPDK Troubleshooting

A concise checklist of common setup, runtime, and performance debugging patterns for SPDK study sessions.

## Entries

### Troubleshooting Checklist
**Abstract:** Effective SPDK troubleshooting combines environment validation, RPC state inspection, and targeted datapath checks. Capturing failure signatures and fixes improves repeatability across study sessions.
**Key points:**
- Check prerequisites and environment assumptions first.
- Use RPC and logs to narrow failing subsystem boundaries.
- Record root cause and fix patterns for future reuse.
**Links:**
- SPDK Troubleshooting/Debug Docs — <url>
- High-Quality Community Troubleshooting Guide — <url>

## Curation Guidelines
- Keep abstracts short and neutral.
- Keep key points to 3–7 bullets.
- Include at least one authoritative link.
- Use descriptive link titles, not bare URLs.
```

- [ ] **Step 6: Verify set B files exist and are non-empty**

Run:
```bash
for f in docs/categories/spdk/perf-and-benchmarking.md docs/categories/spdk/vhost-and-virtio.md docs/categories/spdk/integration-patterns.md docs/categories/spdk/blobfs-and-accel.md docs/categories/spdk/troubleshooting.md; do test -s "$f" || exit 1; done; echo "SPDK SET B OK"
```
Expected: `SPDK SET B OK`

- [ ] **Step 7: Commit Task 4**

Run:
```bash
git add docs/categories/spdk/perf-and-benchmarking.md docs/categories/spdk/vhost-and-virtio.md docs/categories/spdk/integration-patterns.md docs/categories/spdk/blobfs-and-accel.md docs/categories/spdk/troubleshooting.md
git commit -m "docs: add advanced SPDK study topic pages"
```

---

### Task 5: Add dedicated SPDK weekly section

**Files:**
- Modify: `docs/updates/2026-W14.md`

- [ ] **Step 1: Update weekly file with SPDK section**

Ensure `docs/updates/2026-W14.md` contains:

```markdown
## SPDK
- No significant updates this week.
```

Place it after `## Ceph` and before `## Filesystems`.

- [ ] **Step 2: Verify exactly one SPDK heading exists**

Run: `grep -c "^## SPDK$" docs/updates/2026-W14.md`
Expected: `1`

- [ ] **Step 3: Commit Task 5**

Run:
```bash
git add docs/updates/2026-W14.md
git commit -m "docs: add SPDK section to weekly updates"
```

---

### Task 6: README alignment and final consistency pass

**Files:**
- Modify if needed: `README.md`
- Verify: `docs/categories/spdk.md`
- Verify: `docs/categories/spdk/*.md`
- Verify: `docs/updates/2026-W14.md`

- [ ] **Step 1: Ensure README has SPDK category link**

If `README.md` exists, ensure it includes:

```markdown
- [SPDK](docs/categories/spdk.md)
```

If `README.md` does not exist in this branch yet, skip edit and report as pre-existing repository baseline gap.

- [ ] **Step 2: Verify all SPDK page link targets exist**

Run:
```bash
for f in docs/categories/spdk.md docs/categories/spdk/learning-path.md docs/categories/spdk/overview.md docs/categories/spdk/build-and-env.md docs/categories/spdk/bdev-framework.md docs/categories/spdk/nvme-and-nvme-of.md docs/categories/spdk/blobfs-and-accel.md docs/categories/spdk/vhost-and-virtio.md docs/categories/spdk/rpc-and-tooling.md docs/categories/spdk/perf-and-benchmarking.md docs/categories/spdk/integration-patterns.md docs/categories/spdk/troubleshooting.md docs/updates/2026-W14.md; do test -f "$f" || exit 1; done; echo "SPDK DOC LINKS OK"
```
Expected: `SPDK DOC LINKS OK`

- [ ] **Step 3: Verify quality constraints quickly**

Run:
```bash
grep -R "## Curation Guidelines" docs/categories/spdk | wc -l
```
Expected: `10` (all topic pages except `learning-path.md` include curation guidelines).

- [ ] **Step 4: Commit Task 6 (if any changes were made in this task)**

Run (only when Step 1 changed files):
```bash
git add README.md
git commit -m "docs: align README with SPDK study index"
```

If no file changed in Task 6, skip commit and report cleanly.

---

## Spec Coverage Check

- SPDK index + multiple subpages: Tasks 1, 3, 4.
- Study-focused depth with learning path: Task 2 plus topic pages in Tasks 3/4.
- Dedicated SPDK weekly section: Task 5.
- Include official and high-quality third-party sources policy: reflected in page template/guidelines in Tasks 1, 3, 4.
- Keep concise template style: all topic page templates enforce abstract/key-points/links + curation guidance.

## Placeholder/Consistency Check

- No `TBD`/`TODO` execution instructions in plan steps.
- All file paths are explicit and consistent.
- Expected verification outputs are concrete.
- Commit cadence provided after each logical task.
