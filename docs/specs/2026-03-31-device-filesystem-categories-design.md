# Device & Filesystem Categories — Design

**Date:** 2026-03-31
**Project:** storage-study

## Goal

Expand the storage knowledge base by adding per-device-kind and per-filesystem category pages, keeping existing roll-up pages as index pages, and switching the update cadence from monthly to weekly.

## Scope

- Add a `docs/categories/devices/` subtree with one page per device kind
- Add a `docs/categories/filesystems/` subtree with one page per filesystem
- Convert `docs/categories/filesystems.md` into an index page
- Add `docs/categories/devices.md` as a new index page
- Replace monthly updates with weekly `docs/updates/YYYY-WW.md` files (first week anchored to 2026-03-31)
- Update README to link to new indexes and weekly updates

## Architecture & Structure

### Repository layout (additions)

```
docs/
  categories/
    devices.md                  (new index page)
    devices/
      hdd.md
      ssd-sata.md
      nvme-ssd.md
      pmem.md
      nvme-of.md
    filesystems.md              (converted to index page)
    filesystems/
      ext4.md
      xfs.md
      btrfs.md
      zfs.md
      bcachefs.md
      juicefs.md
  updates/
    2026-W14.md                 (first weekly update, week of 2026-03-31)
```

### Index page format

Each index page (`devices.md`, `filesystems.md`) contains:

```
# <Category> Index

Brief one-paragraph overview.

## Pages

| Page | Description |
|------|-------------|
| [<Name>](./<dir>/<file>.md) | One-line description |
...

## Entry Template

### <Topic Title>
**Abstract:** 2–4 sentences.
**Key points:**
- ...
**Links:**
- <link title> — <url>
```

### Per-category page format

Same entry template as the rest of the knowledge base:

```
# <Device / Filesystem Name>

Brief one-paragraph overview.

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

## Weekly Updates

- Replace monthly `docs/updates/YYYY-MM.md` with weekly `docs/updates/YYYY-Www.md` (ISO week notation).
- First file: `docs/updates/2026-W14.md` (week of 2026-03-31).
- Published every Tuesday (day of week of 2026-03-31).
- Weekly file template:

```markdown
# YYYY-Www Updates

## Highlights
- ...

## Kernel Storage
- ...

## Ceph
- ...

## Filesystems
- ...

## Devices
- ...

## Tools
- ...

## References
- ...
```

- If no significant updates: create the file with a brief "No significant updates this week" note.

## Verification

- Documentation-only changes; verify by manual scan of README and index pages.
- Ensure every new page contains the standard entry template + guidelines section.
- Ensure all links in index pages resolve correctly.

## Draft Page List

### Device kinds
| File | Description |
|------|-------------|
| `devices/hdd.md` | Hard Disk Drive — rotating magnetic storage |
| `devices/ssd-sata.md` | SATA SSD — flash storage over SATA interface |
| `devices/nvme-ssd.md` | NVMe SSD — flash storage over PCIe/NVMe interface |
| `devices/pmem.md` | Persistent Memory (PMEM/NVDIMM) — byte-addressable non-volatile memory |
| `devices/nvme-of.md` | NVMe-oF — NVMe over Fabrics (transport category, device-adjacent) |

### Filesystems
| File | Description |
|------|-------------|
| `filesystems/ext4.md` | ext4 — mature Linux journaling filesystem |
| `filesystems/xfs.md` | XFS — high-performance journaling filesystem |
| `filesystems/btrfs.md` | Btrfs — copy-on-write filesystem with snapshots and RAID |
| `filesystems/zfs.md` | ZFS — combined filesystem and volume manager |
| `filesystems/bcachefs.md` | Bcachefs — next-generation Linux filesystem with caching |
| `filesystems/juicefs.md` | JuiceFS — cloud-native distributed filesystem |
