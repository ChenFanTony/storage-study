# Storage Knowledge Base — Design

**Date:** 2026-03-24
**Project:** storage-study

## Goal
Create a curated, navigable knowledge base for modern storage technologies with short abstracts, key points, and links, plus a monthly “latest updates” log.

## Scope
- Linux kernel storage stack (block layer, device mapper, filesystem internals, io_uring)
- Distributed storage (Ceph, DRBD, DAOS)
- Broader ecosystem (NVMe-oF, SPDK, filesystems like ext4/xfs/btrfs/bcachefs/zfs/juicefs)
- Tooling ecosystem (fio, blktrace, bpftrace, etc.)

## Architecture & Structure

### Repository layout
- `README.md` — project overview and index
- `docs/categories/` — category pages:
  - `kernel-storage.md`
  - `ceph.md`
  - `drbd.md`
  - `daos.md`
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
- At least one link required (1–5 preferred).
- Links should include a descriptive title; avoid bare URLs.

## Latest Updates (Monthly)

**Update cadence:** Publish by the 5th of the following month. If there are no significant updates, create the file with a brief “No significant updates this month” note.

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

## DAOS
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
- Kernel bullets may include block layer, device mapper, and io_uring items.
- Tools include benchmarking, tracing, profiling, and diagnostics.

## Workflow
- Add new curated items to the relevant category page.
- Monthly: create `docs/updates/YYYY-MM.md`, add highlights + category bullets.
- README links to all category pages and the most recent update.
- When adding a new category page or monthly update, update the README index in the same change.
- Updates are manual curation (no automation in-repo).

## Curation Criteria
- Prefer primary sources (specs, official docs, maintainer posts, upstream repos).
- Avoid marketing-only links.
- Each entry must include at least one authoritative source.

## Maintenance
- Review entries quarterly for staleness.
- Mark deprecated or superseded items with a brief status note.

## Out of Scope
- Automated scraping or RSS ingestion
- Full-text indexing or search
- Personalized recommendations

## Success Criteria
- Easy navigation by domain
- Every entry includes a short abstract (2–4 sentences), 3–7 key points, and at least one link
- Consistent short-form summaries
- Clear monthly update log for “what’s new”
