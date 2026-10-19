# Kernel Storage

## Device Mapper

**Abstract:** Device Mapper maps virtual block-device sector ranges through
target-specific tables. The dedicated study track covers the core I/O path and
then follows dm-thin snapshots from shared mappings through exhaustion,
monitoring, and metadata recovery.

**Key points:**

- Distinguish the dm kernel mechanism from LVM userspace management.
- Distinguish classic dm-snapshot exception stores from dm-thin shared blocks.
- Treat thin-pool data and metadata capacity as separate failure boundaries.
- Quiesce upper layers for consistent snapshots and validate them by restore.

**Links:**

- [Device Mapper ten-day learning path](../L1-single-node/device-mapper/README.md)
- [Kernel Device Mapper documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/index.html)
- [Kernel thin-provisioning documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/thin-provisioning.html)

---

### <Topic Title>
**Abstract:** 2–4 sentences.
**Key points:**
- ...
- ...
- ...
**Links:**
- <link title> — <url>
