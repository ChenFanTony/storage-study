# SPDK Overview

SPDK is a user-space, polled-mode storage framework designed to reduce latency and increase throughput by minimizing kernel transitions and lock contention.

## Entries

### Architecture Model
**Abstract:** SPDK runs critical datapath logic in user space and relies on polling to avoid interrupt overhead in performance-sensitive paths. It is commonly paired with DPDK and hugepages for memory and device access behavior.
**Key points:**
- User-space design targets predictable low-latency I/O paths.
- Polling favors throughput/latency at the cost of dedicated CPU usage.
- SPDK components are modular and service-oriented.
**Links:**
- SPDK Documentation — <url>
- SPDK GitHub Repository — <url>

## Curation Guidelines
- Keep abstracts short and neutral.
- Keep key points to 3–7 bullets.
- Include at least one authoritative link.
- Use descriptive link titles, not bare URLs.
