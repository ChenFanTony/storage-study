# SPDK NVMe and NVMe-oF

This page maps SPDK's NVMe local access patterns and NVMe-oF transport usage for both target and initiator perspectives.

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
