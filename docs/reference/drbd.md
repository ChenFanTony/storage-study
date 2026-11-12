# DRBD · Replicated Block Devices

DRBD presents a block device whose writes are replicated between hosts. It is
useful for high availability of a volume used by an application or filesystem.
This is an L2 topic: one host still has a normal local block and filesystem
stack, while DRBD adds a replication layer across hosts.

```text
application → filesystem → /dev/drbdX → local backing device
                                  └──→ network → peer backing device
```

## Study order

1. **Resource, volume, and role.** A resource groups replicated volumes. A
   Primary permits application writes; a Secondary receives replication.
2. **Write acknowledgement.** Protocol A acknowledges after the local write
   and network send-buffer handoff; B waits for the peer to receive the data;
   C waits for the peer's disk write confirmation. Read the exact durability
   contract before choosing a mode.
3. **Failure and recovery.** Follow connection loss, promotion, resynchronization,
   and split brain. Two disconnected writable copies can diverge.
4. **Quorum or fencing.** A production failover design needs a way to prevent
   unsafe concurrent writers. DRBD quorum is configurable and is not enabled
   by default in the DRBD 9 guide.
5. **Application consistency.** A replicated block device does not coordinate
   filesystem mounts or database transactions. Study how the cluster manager
   promotes the volume and starts the application on the correct host.

## Where it fits

| Related topic | Connection |
|---|---|
| [L1 Device Mapper](../L1-single-node/device-mapper/README.md) | Local block-device mapping and snapshots; a different problem from cross-host replication |
| [L2 consensus](../L2-distributed/consensus/m2-day01-distributed-concepts.md) | Failure models and quorum vocabulary; DRBD data replication is not a Raft log |
| [L3 cluster operations](../L3-cluster-scheduling/README.md) | Promotion, fencing, monitoring, and recovery at fleet level |

## Primary references

- [LINBIT DRBD 9 User Guide](https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/): concepts, replication modes, split brain, quorum, and operations.
- [LINBIT `drbdadm` manual](https://linbit.com/man/v9/?linbitman=drbdadm.8.html): administrative commands.
