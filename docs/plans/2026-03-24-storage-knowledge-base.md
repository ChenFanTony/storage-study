# Storage Knowledge Base Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the initial curated storage knowledge base structure, templates, and index with monthly update scaffolding.

**Architecture:** A lightweight markdown-first repository. README provides navigation, category pages hold curated entries, and monthly update files capture highlights by area.

**Tech Stack:** Markdown files, git.

---

## Chunk 1: Repository Scaffolding

### Task 1: Initialize README index

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write the failing test**

_N/A (documentation-only change)._

- [ ] **Step 2: Run test to verify it fails**

_N/A._

- [ ] **Step 3: Write minimal implementation**

Create `README.md` with:
- Project purpose
- Scope summary
- Index links to category pages
- Curation criteria and maintenance expectations
- Update cadence
- Link to the most recent monthly update (placeholder if none yet)
- Note: Update the README index in the same change whenever adding a new category page or monthly update

Suggested content:
```markdown
# Storage Study Knowledge Base

Curated summaries and references for Linux storage stack and distributed storage technologies.

## Scope
- Linux kernel storage stack (block layer, device mapper, filesystem internals, io_uring)
- Distributed storage (Ceph, DRBD, DAOS)
- Broader ecosystem (NVMe-oF, SPDK, ext4/xfs/btrfs/bcachefs/zfs/juicefs)
- Tooling ecosystem (fio, blktrace, bpftrace, etc.)

## Categories
- [Kernel storage](docs/categories/kernel-storage.md)
- [Ceph](docs/categories/ceph.md)
- [DRBD](docs/categories/drbd.md)
- [DAOS](docs/categories/daos.md)
- [NVMe-oF](docs/categories/nvme-of.md)
- [SPDK](docs/categories/spdk.md)
- [Filesystems](docs/categories/filesystems.md)
- [Tools ecosystem](docs/categories/tools-ecosystem.md)

## Curation Criteria
- Prefer primary sources (specs, official docs, maintainer posts, upstream repos).
- Avoid marketing-only links.
- Each entry must include at least one authoritative source.

## Maintenance
- Review entries quarterly for staleness.
- Mark deprecated or superseded items with a brief status note.

## Update Cadence
- Publish monthly updates by the 5th of the following month.
- If there are no significant updates, create the file with a brief note.

## Latest Updates
- [2026-03](docs/updates/2026-03.md)
```

Note: DAOS is included because it is explicitly in scope.

- [ ] **Step 4: Run test to verify it passes**

_N/A._


### Task 2: Create category pages with templates

**Files:**
- Create: `docs/categories/kernel-storage.md`
- Create: `docs/categories/ceph.md`
- Create: `docs/categories/drbd.md`
- Create: `docs/categories/daos.md`
- Create: `docs/categories/nvme-of.md`
- Create: `docs/categories/spdk.md`
- Create: `docs/categories/filesystems.md`
- Create: `docs/categories/tools-ecosystem.md`

- [ ] **Step 1: Write the failing test**

_N/A._

- [ ] **Step 2: Run test to verify it fails**

_N/A._

- [ ] **Step 3: Write minimal implementation**

Each category page should include the entry template example, e.g.:
```markdown
### <Topic Title>
**Abstract:** 2–4 sentences.
**Key points:**
- ...
- ...
- ...
**Links:**
- <link title> — <url>
```

Constraints to note in each file (below the template):
- Keep abstracts short and neutral
- 3–7 key points max
- At least one link required (1–5 preferred)
- Links should include a descriptive title; avoid bare URLs

- [ ] **Step 4: Run test to verify it passes**

_N/A._


### Task 3: Create the first monthly update scaffold

**Files:**
- Create: `docs/updates/2026-03.md`

- [ ] **Step 1: Write the failing test**

_N/A._

- [ ] **Step 2: Run test to verify it fails**

_N/A._

- [ ] **Step 3: Write minimal implementation**

Create the monthly template:
```markdown
# 2026-03 Updates

## Highlights
- TBD — <link title> — <url>
- TBD — <link title> — <url>
- TBD — <link title> — <url>

## Kernel
- TBD — <link title> — <url>

## Ceph
- TBD — <link title> — <url>

## DRBD
- TBD — <link title> — <url>

## DAOS
- TBD — <link title> — <url>

## NVMe-oF
- TBD — <link title> — <url>

## SPDK
- TBD — <link title> — <url>

## Filesystems
- TBD — <link title> — <url>

## Tools
- TBD — <link title> — <url>
```

Notes:
- Highlights should have 3–6 bullets.
- Each category should have 1–3 bullets and at least one link.
- Kernel bullets may include block layer, device mapper, and io_uring items.
- Tools include benchmarking, tracing, profiling, and diagnostics.
- If there are no significant updates, create the file with a brief “No significant updates this month.” note.

- [ ] **Step 4: Run test to verify it passes**

_N/A._


## Chunk 2: Ensure README index consistency

### Task 4: Cross-check README links

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Write the failing test**

_N/A._

- [ ] **Step 2: Run test to verify it fails**

_N/A._

- [ ] **Step 3: Write minimal implementation**

Verify README links to all category pages and the current monthly update file. Update if any missing or wrong.

- [ ] **Step 4: Run test to verify it passes**

_N/A._

