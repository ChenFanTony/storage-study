# DAOS · Distributed Object Storage

DAOS is a distributed storage system with a native object model. Its servers
combine placement, transactions, and versioned storage with local NVMe I/O.
Start with the [DAOS architecture deep reference](../L2-distributed/systems/daos-architect-reference.md)
for the pool/container model, data path, failure handling, and access methods.

## Study connections

- [L1 SPDK](../L1-single-node/spdk/study-index.md): the user-space NVMe I/O
  framework used in the local server path.
- [L2 placement and erasure coding](../L2-distributed/data-placement/m2-day08-14-erasure-placement.md):
  the general ideas behind redundancy and recovery across targets.
- [L3 AI storage](../L3-ai-storage/README.md): dataset, checkpoint, and
  memory-tier workloads that motivate distributed storage design.

For product details and current behavior, consult the
[DAOS documentation](https://docs.daos.io/).
