# Storage Knowledge Base — Design

**Date:** 2026-03-24
**Project:** storage-study

## Goal
Create a curated, navigable knowledge base for modern storage technologies with short abstracts, key points, and links, plus a monthly “latest updates” log.

## Scope
- Linux kernel storage stack (block layer, device mapper, filesystem internals, io_uring)
- Distributed storage (Ceph, DRBD)
- Broader ecosystem (NVMe-oF, SPDK, filesystems like ext4/xfs/btrfs/bcachefs/zfs)
- Tooling ecosystem (fio, blktrace, bpftrace, etc.)

## Architecture & Structure

### Repository layout
- `README.md` — project overview and index
- `docs/categories/` — category pages:
  - `kernel-storage.md`
  - `ceph.md`
  - `drbd.md`
  - `nvme-of.md`
  - `spdk.md`
  - `filesystems.md`
  - `tools-ecosystem.md`
- `docs/updates/` — monthly logs (e.g., `2026-03.md`)

### Category entry format
Each category page uses a consistent entry template:

```
### <Topic Title>
**Abstract:** 2–4 sentences.
**Key points:**
- ...
- ...
- ...
**Links:**
- <link title> — <url>
- ...
```

Guidelines:
- Keep abstracts short and neutral.
- 3–7 key points max.
- Links should include a descriptive title; avoid bare URLs.

## Latest Updates (Monthly)

Monthly file `docs/updates/YYYY-MM.md`:

```
# YYYY-MM Updates

## Highlights
- ...

## Kernel
- ...

## Ceph
- ...

## DRBD
- ...

## NVMe-oF
- ...

## SPDK
- ...

## Filesystems
- ...

## Tools
- ...
```

- Highlights: 3–6 bullets
- Each category: 1–3 short bullets + link

## Workflow
- Add new curated items to the relevant category page.
- Monthly: create `docs/updates/YYYY-MM.md`, add highlights + category bullets.
- README links to all category pages and the most recent update.
- Updates are manual curation (no automation in-repo).

## Out of Scope
- Automated scraping or RSS ingestion
- Full-text indexing or search
- Personalized recommendations

## Success Criteria
- Easy navigation by domain
- Consistent short-form summaries
- Clear monthly update log for “what’s new”
