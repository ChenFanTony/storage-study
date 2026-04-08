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
