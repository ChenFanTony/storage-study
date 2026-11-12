# L1 · Single-Node Storage

Understand the I/O path within one host, from an application request to a
device completion. Start with kernel I/O, then choose the subsystem you need.

| Step | Study track | Why it belongs here |
|---|---|---|
| 1 | [Kernel I/O](kernel-io/day01-storage-stack-gap-fill.md) | Block layer, NVMe, io_uring, and the end-to-end I/O path |
| 2 | [Memory and page cache](memory/day01-physical-memory-model.md) | Caching, writeback, and memory pressure affect storage latency |
| 3 | [Device Mapper and dm-thin](device-mapper/README.md) | Virtual block devices, thin pools, and snapshots |
| 4 | [Filesystems](filesystems/filesystem-comparison-ext4-xfs-btrfs.md) | File semantics and on-disk structures above the block layer |
| 5 | [SCSI](scsi/day01.md) | Command lifecycle, transports, error handling, and multipath |
| 6 | [Networking](network/day01_network_overview.md) | The local network stack used by network storage |

## Focus tracks

- [SPDK 30-day study](spdk/study-index.md): user-space reactors, polling,
  bdev, and NVMe-oF target internals. Start after the basic block/NVMe path.
- [Storage tiering](storage-tiering/day08-bcache-gc-ssd-wear.md): bcache,
  dm-cache, encryption, and RAID. Read the [Device Mapper track](device-mapper/README.md)
  first if thin-pool snapshots are your focus.

SPDK runs on a node even when it is used as part of a distributed system such
as DAOS. After the local path is clear, continue with
[L2 · Distributed Storage](../L2-distributed/README.md).
