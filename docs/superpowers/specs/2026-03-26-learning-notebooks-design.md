# Storage Study Learning Notebooks — Design

**Date:** 2026-03-26
**Project:** storage-study

## Goal
Add a lightweight learning-notebook layer to the existing storage knowledge base so you can capture concise notes by topic and expand into deep dives only when requested.

## Context
The repository already includes:
- `docs/categories/` for curated entries
- `docs/updates/` for monthly updates
- `README.md` as the main index (planned)

This design adds a notebooks area without changing the existing category/update structure.

## Proposed Structure
```
README.md
docs/
  categories/
  updates/
  notebooks/
    index.md
    template.md
    topics/
      <topic>.md
```

### Notebooks Index
`docs/notebooks/index.md` will list notebooks and their status (e.g., draft/active), grouped by domain (Kernel, Ceph, NVMe-oF, Filesystems, Tools, etc.).

### Notebook Template
`docs/notebooks/template.md` defines a standard layout for all topics:
- **Overview** (2–4 sentences)
- **Key Concepts**
- **Terminology**
- **References** (authoritative links)
- **Open Questions**
- **Deep Dive (optional, by request)** — labs, commands, benchmarks, configs, traces

### Topic Notebooks
Each notebook lives in `docs/notebooks/topics/` and follows the template. By default, notebooks stay concise. Deep Dive sections are added only when requested.

## README Integration
Update `README.md` to include:
- A link to the notebooks index
- A short note that notebooks are concise by default, with deep dives on request

## Workflow
1) Add new curated items to category pages.
2) Publish monthly updates in `docs/updates/`.
3) For any topic you want to learn, create a notebook in `docs/notebooks/topics/` using the template.
4) When you request deeper exploration, append a **Deep Dive** section to that notebook.

## Out of Scope
- Automated data ingestion
- Mandatory labs for every notebook
- Complex tagging systems or search tooling

## Success Criteria
- A consistent, low-friction notebook format for learning topics
- Easy expansion into deep dives when requested
- Clear navigation from README to notebook index
