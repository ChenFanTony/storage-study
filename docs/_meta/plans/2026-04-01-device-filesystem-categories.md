# Device & Filesystem Categories Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-device and per-filesystem category pages, keep roll-up index pages, and switch update cadence from monthly to weekly.

**Architecture:** Keep the repository markdown-first and simple: README is the root index, roll-up category pages are navigational indexes, and leaf pages hold curation entries using a shared template. Weekly updates move to ISO week filenames and become the single cadence source.

**Tech Stack:** Markdown files, git.

---

## File Structure Map

### Create
- `README.md`
- `docs/categories/devices.md`
- `docs/categories/devices/hdd.md`
- `docs/categories/devices/ssd-sata.md`
- `docs/categories/devices/nvme-ssd.md`
- `docs/categories/devices/pmem.md`
- `docs/categories/devices/nvme-of.md`
- `docs/categories/filesystems.md`
- `docs/categories/filesystems/ext4.md`
- `docs/categories/filesystems/xfs.md`
- `docs/categories/filesystems/btrfs.md`
- `docs/categories/filesystems/zfs.md`
- `docs/categories/filesystems/bcachefs.md`
- `docs/categories/filesystems/juicefs.md`
- `docs/updates/2026-W14.md`

### Responsibility boundaries
- `README.md`: top-level project overview, category index, latest weekly update link.
- `docs/categories/devices.md`: devices roll-up index linking to leaf device pages.
- `docs/categories/filesystems.md`: filesystems roll-up index linking to leaf filesystem pages.
- Leaf pages under `docs/categories/devices/` and `docs/categories/filesystems/`: curated entries for each specific device/filesystem.
- `docs/updates/2026-W14.md`: first weekly update scaffold and weekly section structure.

---

### Task 1: Create README root index for weekly workflow

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write the README content**

Create `README.md` with exactly:

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
- [Devices](docs/categories/devices.md)
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
- Publish weekly updates every Tuesday.
- If there are no significant updates, create the file with "No significant updates this week."

## Latest Updates
- [2026-W14](docs/updates/2026-W14.md)
```

- [ ] **Step 2: Verify README exists and is non-empty**

Run: `test -s README.md && echo "README OK"`
Expected: `README OK`

- [ ] **Step 3: Commit Task 1**

Run:
```bash
git add README.md
git commit -m "docs: add README index for weekly storage categories"
```

---

### Task 2: Add devices roll-up index page

**Files:**
- Create: `docs/categories/devices.md`

- [ ] **Step 1: Write devices index page**

Create `docs/categories/devices.md` with exactly:

```markdown
# Devices Index

Device-kind navigation for storage hardware and transport-oriented device-adjacent topics.

## Pages

| Page | Description |
|------|-------------|
| [HDD](./devices/hdd.md) | Hard Disk Drive — rotating magnetic storage |
| [SSD (SATA)](./devices/ssd-sata.md) | SATA SSD — flash storage over SATA interface |
| [NVMe SSD](./devices/nvme-ssd.md) | NVMe SSD — flash storage over PCIe/NVMe interface |
| [PMEM](./devices/pmem.md) | Persistent Memory (PMEM/NVDIMM) |
| [NVMe-oF](./devices/nvme-of.md) | NVMe over Fabrics (transport category) |

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
```

- [ ] **Step 2: Verify all five links are present**

Run: `grep -c "./devices/" docs/categories/devices.md`
Expected: `5`

- [ ] **Step 3: Commit Task 2**

Run:
```bash
git add docs/categories/devices.md
git commit -m "docs: add devices index page"
```

---

### Task 3: Add per-device leaf pages

**Files:**
- Create: `docs/categories/devices/hdd.md`
- Create: `docs/categories/devices/ssd-sata.md`
- Create: `docs/categories/devices/nvme-ssd.md`
- Create: `docs/categories/devices/pmem.md`
- Create: `docs/categories/devices/nvme-of.md`

- [ ] **Step 1: Write `hdd.md`**

```markdown
# HDD

Hard Disk Drives are rotating-media block devices with strong capacity-per-dollar and well-understood performance behavior.

## Entries

### <Topic Title>
**Abstract:** 2–4 sentences.
**Key points:**
- ...
- ...
- ...
**Links:**
- <link title> — <url>
```

- [ ] **Step 2: Write `ssd-sata.md`**

```markdown
# SSD (SATA)

SATA SSDs provide flash-based storage through the SATA protocol and are common in mixed legacy/new deployments.

## Entries

### <Topic Title>
**Abstract:** 2–4 sentences.
**Key points:**
- ...
- ...
- ...
**Links:**
- <link title> — <url>
```

- [ ] **Step 3: Write `nvme-ssd.md`**

```markdown
# NVMe SSD

NVMe SSDs use PCIe and the NVMe protocol to deliver high parallelism and low latency for modern workloads.

## Entries

### <Topic Title>
**Abstract:** 2–4 sentences.
**Key points:**
- ...
- ...
- ...
**Links:**
- <link title> — <url>
```

- [ ] **Step 4: Write `pmem.md`**

```markdown
# PMEM

Persistent memory provides byte-addressable non-volatile media with access semantics between DRAM and block devices.

## Entries

### <Topic Title>
**Abstract:** 2–4 sentences.
**Key points:**
- ...
- ...
- ...
**Links:**
- <link title> — <url>
```

- [ ] **Step 5: Write `nvme-of.md`**

```markdown
# NVMe-oF

NVMe over Fabrics extends NVMe access across network fabrics and is treated here as a device-adjacent transport category.

## Entries

### <Topic Title>
**Abstract:** 2–4 sentences.
**Key points:**
- ...
- ...
- ...
**Links:**
- <link title> — <url>
```

- [ ] **Step 6: Verify all five files exist**

Run:
```bash
for f in docs/categories/devices/hdd.md docs/categories/devices/ssd-sata.md docs/categories/devices/nvme-ssd.md docs/categories/devices/pmem.md docs/categories/devices/nvme-of.md; do test -s "$f" || exit 1; done; echo "DEVICE PAGES OK"
```
Expected: `DEVICE PAGES OK`

- [ ] **Step 7: Commit Task 3**

Run:
```bash
git add docs/categories/devices/*.md
git commit -m "docs: add per-device category pages"
```

---

### Task 4: Convert filesystems roll-up to index page

**Files:**
- Create or overwrite: `docs/categories/filesystems.md`

- [ ] **Step 1: Write filesystems index page**

Set `docs/categories/filesystems.md` to exactly:

```markdown
# Filesystems Index

Filesystem navigation page linking to per-filesystem category pages.

## Pages

| Page | Description |
|------|-------------|
| [ext4](./filesystems/ext4.md) | Mature Linux journaling filesystem |
| [XFS](./filesystems/xfs.md) | High-performance journaling filesystem |
| [Btrfs](./filesystems/btrfs.md) | Copy-on-write filesystem with snapshots |
| [ZFS](./filesystems/zfs.md) | Filesystem and volume manager |
| [Bcachefs](./filesystems/bcachefs.md) | Next-generation Linux filesystem |
| [JuiceFS](./filesystems/juicefs.md) | Cloud-native distributed filesystem |

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
```

- [ ] **Step 2: Verify all six links are present**

Run: `grep -c "./filesystems/" docs/categories/filesystems.md`
Expected: `6`

- [ ] **Step 3: Commit Task 4**

Run:
```bash
git add docs/categories/filesystems.md
git commit -m "docs: convert filesystems page to index format"
```

---

### Task 5: Add per-filesystem leaf pages

**Files:**
- Create: `docs/categories/filesystems/ext4.md`
- Create: `docs/categories/filesystems/xfs.md`
- Create: `docs/categories/filesystems/btrfs.md`
- Create: `docs/categories/filesystems/zfs.md`
- Create: `docs/categories/filesystems/bcachefs.md`
- Create: `docs/categories/filesystems/juicefs.md`

- [ ] **Step 1: Write six files with consistent template**

Create each file with this exact structure (replace title and intro sentence per filesystem):

```markdown
# <Filesystem Name>

<One paragraph overview sentence for this filesystem.>

## Entries

### <Topic Title>
**Abstract:** 2–4 sentences.
**Key points:**
- ...
- ...
- ...
**Links:**
- <link title> — <url>
```

Use these titles and opening lines:
- `ext4.md` → `# ext4` / `ext4 is a mature Linux journaling filesystem widely used for general-purpose workloads.`
- `xfs.md` → `# XFS` / `XFS is a high-performance journaling filesystem optimized for scale and parallel I/O.`
- `btrfs.md` → `# Btrfs` / `Btrfs is a copy-on-write filesystem with integrated snapshotting and volume-management features.`
- `zfs.md` → `# ZFS` / `ZFS combines filesystem and volume management with strong data-integrity features.`
- `bcachefs.md` → `# Bcachefs` / `Bcachefs is a modern Linux filesystem designed for performance, checksumming, and flexible storage layouts.`
- `juicefs.md` → `# JuiceFS` / `JuiceFS is a cloud-native distributed filesystem with object-storage-backed architecture.`

- [ ] **Step 2: Verify all six files exist**

Run:
```bash
for f in docs/categories/filesystems/ext4.md docs/categories/filesystems/xfs.md docs/categories/filesystems/btrfs.md docs/categories/filesystems/zfs.md docs/categories/filesystems/bcachefs.md docs/categories/filesystems/juicefs.md; do test -s "$f" || exit 1; done; echo "FILESYSTEM PAGES OK"
```
Expected: `FILESYSTEM PAGES OK`

- [ ] **Step 3: Commit Task 5**

Run:
```bash
git add docs/categories/filesystems/*.md
git commit -m "docs: add per-filesystem category pages"
```

---

### Task 6: Add first weekly update scaffold

**Files:**
- Create: `docs/updates/2026-W14.md`

- [ ] **Step 1: Write weekly update scaffold**

Create `docs/updates/2026-W14.md` with exactly:

```markdown
# 2026-W14 Updates

## Highlights
- No significant updates this week.

## Kernel Storage
- No significant updates this week.

## Ceph
- No significant updates this week.

## Filesystems
- No significant updates this week.

## Devices
- No significant updates this week.

## Tools
- No significant updates this week.

## References
- (Add authoritative links when updates are available.)
```

- [ ] **Step 2: Verify weekly file naming pattern**

Run: `test -f docs/updates/2026-W14.md && echo "WEEKLY FILE OK"`
Expected: `WEEKLY FILE OK`

- [ ] **Step 3: Commit Task 6**

Run:
```bash
git add docs/updates/2026-W14.md
git commit -m "docs: add first weekly updates scaffold"
```

---

### Task 7: Final consistency check across README and index pages

**Files:**
- Modify if needed: `README.md`
- Modify if needed: `docs/categories/devices.md`
- Modify if needed: `docs/categories/filesystems.md`

- [ ] **Step 1: Verify key links resolve by file existence**

Run:
```bash
for f in docs/categories/devices.md docs/categories/filesystems.md docs/categories/devices/hdd.md docs/categories/devices/ssd-sata.md docs/categories/devices/nvme-ssd.md docs/categories/devices/pmem.md docs/categories/devices/nvme-of.md docs/categories/filesystems/ext4.md docs/categories/filesystems/xfs.md docs/categories/filesystems/btrfs.md docs/categories/filesystems/zfs.md docs/categories/filesystems/bcachefs.md docs/categories/filesystems/juicefs.md docs/updates/2026-W14.md; do test -f "$f" || exit 1; done; echo "LINK TARGET FILES OK"
```
Expected: `LINK TARGET FILES OK`

- [ ] **Step 2: Check git diff is docs-only**

Run: `git diff --name-only`
Expected: only `README.md` and files under `docs/categories/` and `docs/updates/`.

- [ ] **Step 3: Final commit for any consistency fixes**

Run:
```bash
git add README.md docs/categories/*.md docs/categories/devices/*.md docs/categories/filesystems/*.md docs/updates/2026-W14.md
git commit -m "docs: finalize device and filesystem category indexes"
```

---

## Spec Coverage Check

- Per-device pages: covered by Task 3.
- Per-filesystem pages: covered by Task 5.
- Keep roll-ups as index pages: covered by Tasks 2 and 4.
- Weekly updates (`YYYY-Www`): covered by Task 6.
- README links to new indexes + latest weekly update: covered by Task 1 and verified in Task 7.

## Placeholder/Consistency Check

- No `TODO`/`TBD` implementation instructions in plan steps.
- File paths are explicit and consistent with the approved spec.
- Weekly cadence and first anchor week (`2026-W14`) are consistent across tasks.
