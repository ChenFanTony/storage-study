# SPDK bdev Framework

The bdev framework is SPDK's block abstraction layer used to compose storage backends and services in a consistent way.

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
