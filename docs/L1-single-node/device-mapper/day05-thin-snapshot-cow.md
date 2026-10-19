# Day 5: Thin Snapshot Copy-on-Write Mechanics

## Learning objectives

- Follow `create_snap` and the first write after snapshot creation.
- Explain sharing without a full data copy.
- Understand recursive snapshots and independent device lifetime.
- Create crash-, filesystem-, or application-consistent snapshots deliberately.

## 1. Snapshot creation

At the raw dm layer, userspace creates a snapshot device ID from an origin ID:

```text
suspend active origin
message pool: create_snap <new-id> <origin-id>
resume origin
```

Suspending an active origin during creation is required by the kernel
documentation to avoid corruption; the target does not enforce this for you.
LVM coordinates device activation, but the application/filesystem still owns
higher-level consistency.

Snapshot creation commits new metadata roots and device details. It does not
copy all mapped data.

## 2. Shared mappings

Initial state:

```text
origin L0 -> P10
origin L1 -> P11
```

After snapshot:

```text
origin L0 -> P10      snapshot L0 -> P10
origin L1 -> P11      snapshot L1 -> P11
```

Origin writes L0:

```text
allocate P12
write new origin data to P12
publish origin L0 -> P12
snapshot L0 remains -> P10
free P10 only when no thin device references it
```

Snapshot writes L1 work symmetrically: it receives a new block while the origin
keeps P11. The terms "origin" and "snapshot" describe creation history, not a
permanent parent/child I/O dependency.

## 3. Recursive snapshots

A thin snapshot can itself be snapshotted. The implementation uses one mapping
design rather than walking an exception-store chain for every lookup, so
lookup cost does not inherently grow as O(snapshot depth).

That does not make deep trees free. Many diverging devices increase mapping
updates, metadata usage, retained data, fragmentation, operational inventory,
and restore testing.

Deleting a device drops its mappings; physical blocks are reclaimed only when
no remaining device references them.

## 4. Crash consistency

A block snapshot can capture a recoverable crash point if I/O is coordinated.
A filesystem journal may replay on mount. That does not guarantee the
application's logical invariant.

Recommended ordering:

```text
application flush/quiesce
  -> filesystem sync and freeze
     -> create thin snapshot while origin is safely suspended
     -> resume origin
  -> thaw filesystem
application resumes
```

For a database, use its backup/snapshot API. For a VM, coordinate guest
filesystem/application state through the hypervisor or guest agent.

Freezing too long can cause request timeouts. Put an upper bound and guaranteed
thaw path around automation.

## 5. Snapshot is not backup

Origin and snapshots share:

- pool data media;
- pool metadata;
- controller and host;
- pool exhaustion and corruption failure domains.

A snapshot protects against selected logical changes, not pool loss. Export
important generations to independent storage and test restoring them.

## 6. External origin

A thin LV may fall through to an external read-only origin for unmapped blocks.
Every descendant must use the same external origin parameter. The external
device must never change while referenced.

This is useful for many writable thin instances based on one immutable image,
but availability and integrity of that base remain runtime dependencies.

## Lab: reason about block ownership

Start with an origin containing four mapped chunks, snapshot it, then write one
different chunk in each device. Draw mappings and answer:

- how many physical blocks are unique?
- how many remain shared?
- which blocks become free if the origin is deleted?
- which remain required by the snapshot?

Verify on a disposable pool with `thin_dump` only through a reserved live
metadata snapshot or while the pool is inactive.

## Failure patterns

- Creating a raw snapshot of an active origin without suspend.
- Calling a crash-consistent database snapshot application-consistent.
- Assuming snapshots reserve data space for future divergence.
- Deleting an origin and expecting all its blocks to be freed.
- Maintaining deep snapshot trees without metadata/capacity monitoring.
- Treating snapshots sharing one pool as disaster-recovery copies.

## Self-check

1. What is physically copied at thin snapshot creation?
2. What happens when the origin overwrites a shared chunk?
3. Why can either device be active independently afterward?
4. Which steps make a database snapshot application-consistent?

## References

- [Kernel dm-thin internal snapshots](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/thin-provisioning.html#internal-snapshots)
- [Kernel dm-thin external snapshots](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/thin-provisioning.html#external-snapshots)
- [LVM thin snapshots](https://man7.org/linux/man-pages/man7/lvmthin.7.html)

---

## Previous / Next

[← Previous: Day 4 — Thin-pool architecture: data, metadata, mappings, space maps, and chunks](day04-thin-pool-architecture.md) | [Device Mapper study index](README.md) | [Next: Day 6 — LVM thin-snapshot lab: create, diverge, inspect, and remove thin volumes →](day06-lvm-thin-snapshot-lab.md)
