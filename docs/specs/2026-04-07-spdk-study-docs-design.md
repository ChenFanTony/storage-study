# SPDK Study Docs Expansion — Design

**Date:** 2026-04-07
**Project:** storage-study

## Goal

Add a dedicated SPDK study documentation structure with an index, curated topic subpages, and a guided learning path, while integrating a dedicated SPDK section into the weekly update cadence.

## Scope

- Add `docs/categories/spdk.md` as an SPDK roll-up index page.
- Add `docs/categories/spdk/` with study-focused subpages.
- Add `docs/categories/spdk/learning-path.md` with beginner → advanced progression.
- Keep existing short-form entry style (abstract, key points, links).
- Include official SPDK sources first, plus vetted high-quality third-party tutorials.
- Add a dedicated `## SPDK` section to weekly updates.

## Proposed SPDK Documentation Structure

### Top-level index
- `docs/categories/spdk.md`

### Study subpages
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

## Page Responsibilities

- `spdk.md`: navigation hub for all SPDK study pages, with one-line descriptions per page and a pointer to weekly SPDK updates.
- `learning-path.md`: recommended study order and milestone outcomes.
- Topic pages: concise reference + study notes for one SPDK area each.

## Content Format

Each SPDK topic page follows the existing project conventions:

```
# <Page Title>

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

## Curation Guidelines
- Keep abstracts short and neutral.
- Keep key points to 3–7 bullets.
- Include at least one authoritative link.
- Use descriptive link titles, not bare URLs.
```

## Source Policy

- Prioritize official SPDK sources:
  - SPDK official documentation
  - SPDK GitHub repository and maintainers’ docs/issues/PR notes where relevant
- Include third-party tutorials only when they are:
  - technically accurate,
  - current enough for study use,
  - clearly additive beyond official docs.
- Label links by source type in prose where helpful (e.g., Official, Community).

## Learning Path (Study-Focused)

Recommended progression in `learning-path.md`:

1. Overview
2. Build & Environment
3. bdev Framework
4. NVMe and NVMe-oF
5. RPC and Tooling
6. Performance and Benchmarking
7. Vhost/Virtio + Integration Patterns
8. Troubleshooting and next steps

## Weekly Updates Integration

Weekly update template uses `YYYY-Www` and includes a dedicated SPDK section:

```markdown
# YYYY-Www Updates

## Highlights
- ...

## Kernel Storage
- ...

## Ceph
- ...

## SPDK
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

Rules:
- Add 1–3 concise SPDK bullets each week when relevant.
- If no significant SPDK updates: `- No significant updates this week.`

## Workflow

- Add and curate SPDK content in the relevant topic subpage.
- Keep `spdk.md` index links synchronized with actual files.
- Keep `learning-path.md` aligned with current page set and learning sequence.
- Update README category index in the same change when SPDK navigation changes.

## Verification

- All listed SPDK subpages exist and are linked from `docs/categories/spdk.md`.
- `learning-path.md` includes full beginner → advanced order.
- Weekly update template includes a dedicated `## SPDK` section.
- Links are present, descriptive, and include official + vetted community references.

## Out of Scope

- Automated scraping or feed ingestion.
- Full tutorial prose for every SPDK API surface.
- Replacing existing non-SPDK category structures.

## Success Criteria

- SPDK study content is easy to navigate from one index page.
- Learners can follow a clear ordered path from basics to advanced topics.
- Weekly updates consistently surface SPDK changes in a dedicated section.
- Each topic page stays concise, structured, and link-backed.
