# SPDK Vhost and Virtio

SPDK supports virtualization-oriented datapaths through vhost and virtio integrations.

## Entries

### Virtualized I/O Paths
**Abstract:** Vhost/virtio support bridges SPDK capabilities into VM-oriented deployments, where queue behavior and host/guest configuration affect observed performance. Correct layering and device mapping are critical for stable operation.
**Key points:**
- Understand host/guest boundary responsibilities.
- Queue and CPU placement choices strongly impact outcomes.
- Keep configuration docs close to measured results.
**Links:**
- SPDK vhost Documentation — <url>
- SPDK Virtio Documentation — <url>

## Curation Guidelines
- Keep abstracts short and neutral.
- Keep key points to 3–7 bullets.
- Include at least one authoritative link.
- Use descriptive link titles, not bare URLs.
