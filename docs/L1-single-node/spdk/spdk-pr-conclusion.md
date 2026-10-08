# SPDK NVMf Persistent Reservations Conclusion

## 1. PR scope in SPDK

- SPDK NVMf Persistent Reservation state is scoped to `struct spdk_nvmf_ns`, not to the backing `spdk_bdev`.
- The live PR state is stored in the namespace object: registrants, holder, reservation key, reservation type, PTPL state.
- `lib/nvmf/ctrlr.c` does not own PR state. It only checks reservation conflicts against cached namespace reservation info and forwards PR commands.
- `lib/nvmf/subsystem.c` owns the PR implementation and serializes reservation updates per namespace.

## 2. Same backing device in two subsystems

- In current SPDK, the same exact `spdk_bdev` normally cannot be added to two NVMf subsystems at the same time.
- `spdk_nvmf_subsystem_add_ns_ext()` claims the bdev, and that claim is exclusive.
- Therefore, the configuration "same exact bdev exported by two subsystems in one SPDK target" is rejected before PR sharing becomes relevant.

## 3. If two namespace objects somehow map to the same media

- PR state would still not be shared automatically.
- PR is namespace-object scoped, so subsystem A / ns A and subsystem B / ns B would have separate reservation state.
- A reservation on one would not protect I/O through the other.

## 4. Normal shared-volume model in SPDK

- For one SPDK target and multiple hosts, the correct model is:
  - one subsystem
  - one namespace
  - multiple hosts connect to that same subsystem / NSID
- In that model, both hosts operate on the same `spdk_nvmf_ns`, so PR works across those hosts.

## 5. Different hosts seeing different namespaces under one subsystem

- SPDK supports per-namespace host visibility inside one subsystem.
- To use that, create the namespace with `no_auto_visible=true`.
- Then use `nvmf_ns_add_host` / `nvmf_ns_remove_host` to control which host can see which NSID.
- This lets:
  - host A see `ns1`
  - host B see `ns2`
  - both hosts still connect to the same subsystem NQN

## 6. Important PR implication

- PR only applies among hosts sharing the same namespace.
- If host A and host B do not both see the same NSID, they are not in the same PR domain for that storage.

## 7. Short truth statement

- One SPDK target, two hosts, one subsystem, same NSID: supported, and PR works across the two hosts.
- One SPDK target, same exact bdev in two subsystems: normally not allowed.
- Two different namespace objects backed by the same media: PR state is not globally shared by SPDK.
- Per-host namespace visibility inside one subsystem: supported with `no_auto_visible=true` plus namespace host ACLs.

## 8. Linux nvmet conclusion

- Linux `nvmet` PR support is namespace-scoped, but host access control is subsystem-scoped.
- In upstream `nvmet`, a subsystem has `namespaces` and `allowed_hosts`, but there is no namespace-level `allowed_hosts`.
- Namespace attributes include `resv_enable`, but not per-namespace host ACLs.
- Therefore, if host A and host B are both allowed to connect to one subsystem, they can see all enabled namespaces in that subsystem.
- Linux `nvmet` does not currently provide SPDK-style "NS1 visible only to host A, NS2 visible only to host B" inside one subsystem.

## 9. What would be needed in Linux to match SPDK behavior

- If the goal is only PR on one shared namespace across multiple hosts, Linux already supports that with one subsystem and one shared namespace.
- If the goal is selective namespace exposure inside one subsystem, Linux would need namespace-level host visibility / ACL support.
- Without that, the practical Linux workaround is to split namespaces across different subsystems / NQNs.

## 10. Upstream discussion status checked on 2026-04-08

- Public upstream discussion clearly existed for adding `nvmet` PR support in 2024, and that work landed.
- Follow-on PR-related work also existed, including host identifier support required by reservations.
- I did not find a public upstream RFC or patch series specifically adding per-namespace host visibility / namespace ACLs to `nvmet`.
- This means PR support was in progress and then upstreamed, but the SPDK-style namespace host-visibility feature does not appear to be in progress publicly, based on the threads and current upstream source checked on 2026-04-08.
