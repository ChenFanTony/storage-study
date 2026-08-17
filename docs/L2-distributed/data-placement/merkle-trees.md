# Merkle Trees for Storage Systems

A Merkle tree, or hash tree, summarizes a dataset in one cryptographic root
hash. Storage systems use it to compare replicas, locate divergent regions,
verify blocks, and repair only the data that differs.

## 1. Structure

For four data blocks, hash each block to create the leaves, then repeatedly
hash pairs of child hashes:

```text
                         Root
                    H(H01 || H23)
                     /          \
             H01 = H(H0 || H1)  H23 = H(H2 || H3)
                  /      \          /      \
              H0=H(D0) H1=H(D1) H2=H(D2) H3=H(D3)
                  |       |       |       |
                 D0      D1      D2      D3
```

`H()` is a cryptographic hash such as SHA-256, and `||` means concatenation.
The construction must define unambiguous encoding, child order, leaf size,
and handling of an odd number of nodes.

Changing one byte in `D2` changes `H2`, then `H23`, then the root. Equal roots
therefore provide strong evidence that two trees built with identical rules
represent identical data.

## 2. Replica Comparison and Repair

Suppose replicas A and B each store one terabyte:

1. Compare their root hashes.
2. If the roots match, no subtree comparison is needed.
3. If they differ, compare the root's child hashes.
4. Descend only through children whose hashes differ.
5. At the leaves, identify the precise blocks or ranges to verify and repair.
6. Copy a known-good block, recompute its path, and confirm the roots converge.

```text
Replica A root != Replica B root
          |
          +-- left subtree hashes equal  → skip it
          |
          +-- right subtree hashes differ
                    |
                    +-- D2 differs → validate and repair D2
                    +-- D3 equal   → skip D3
```

This is commonly called anti-entropy: replicas exchange compact summaries and
synchronize divergent ranges without transferring the complete dataset.

## 3. Inclusion Proof

A Merkle proof verifies one leaf without sending the entire tree. To prove
that `D2` belongs to the root above, send:

- `D2` or its leaf hash `H2`
- sibling `H3`
- sibling subtree `H01`

The verifier calculates:

```text
H2  = H(D2)
H23 = H(H2 || H3)
root = H(H01 || H23)
```

The proof is accepted only if the reconstructed root equals an independently
trusted root. A balanced binary tree with `n` leaves needs approximately
`log2(n)` sibling hashes for one proof.

## 4. Complexity

| Operation | Cost for a balanced binary tree |
| --- | --- |
| Build from all data | `O(n)` leaf/internal hashes |
| Compare equal replicas | `O(1)` root comparison |
| Locate one differing leaf | `O(log n)` hash comparisons after construction |
| Verify one inclusion proof | `O(log n)` hashes and proof space |
| Update one leaf eagerly | `O(log n)` ancestor hashes |

The `O(log n)` mismatch claim assumes both trees and their internal hashes
already exist. Building or fully refreshing a tree is still `O(n)`, and many
differences can require visiting a large fraction of it.

## 5. Storage-System Design Choices

### Leaf granularity

- Small leaves localize corruption and reduce repair traffic.
- Large leaves reduce tree metadata and hash-maintenance work.
- Range-based leaves must have stable boundaries; otherwise one insertion can
  shift later boundaries and change most of the tree.

### Tree ownership and freshness

The system must define when hashes become durable and which data version they
describe. Comparing roots from different snapshots can report divergence even
when both replicas are correct. Common choices include immutable objects,
versioned partitions, or a tree tied to a checkpoint/epoch.

### Hash storage

Internal hashes can be persisted, cached and rebuilt, or calculated lazily.
Persisting speeds comparison but adds write amplification and crash-consistency
requirements. Lazy calculation reduces write cost but makes scrub expensive.

### Fan-out

Binary trees minimize children per node and give simple proofs. Higher fan-out
reduces height but requires more sibling hashes at each level. Storage systems
often align fan-out and leaves with natural partitions, objects, or ranges.

## 6. Security and Reliability Boundaries

A Merkle tree provides integrity evidence; it does not itself provide:

- replication, erasure coding, or a known-good repair source;
- encryption or access control;
- automatic repair or a decision about which replica is authoritative;
- freshness, unless the root is bound to a version or epoch;
- protection if an attacker can replace both the data and the trusted root;
- immunity to hash collisions—the design relies on collision resistance.

For adversarial verification, authenticate the root with a signature, trusted
checkpoint, consensus record, or another protected metadata channel. For
accidental corruption, independent replica roots and checksummed blocks may be
sufficient when the repair authority is otherwise known.

## 7. Merkle Tree vs Related Mechanisms

| Mechanism | Main purpose |
| --- | --- |
| Per-block checksum | Detect corruption in a known block |
| Merkle tree | Summarize many checksums and locate mismatched ranges |
| Replication | Provide another copy for availability and repair |
| Erasure coding | Reconstruct lost data with lower redundancy overhead |
| Consensus | Agree on authoritative state/order among nodes |

These mechanisms complement one another. A system may use checksums to detect
a bad block, a Merkle tree to locate replica divergence, and replication or
erasure coding to reconstruct the correct bytes.

## 8. Self-Check

1. If two roots differ, does that identify which replica is correct?
2. Why is locating one mismatch `O(log n)` only after tree construction?
3. What hashes are required to prove inclusion of one leaf?
4. Why must roots be associated with the same version or snapshot?
5. What must be trusted when a Merkle proof is used against an attacker?

## 9. References

- [Amazon Dynamo paper](https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf) — uses Merkle trees for replica anti-entropy.
- [RFC 9162: Certificate Transparency Version 2.0](https://www.rfc-editor.org/rfc/rfc9162.html) — specifies Merkle tree hashing, inclusion proofs, and consistency proofs.
- [Ralph Merkle, “A Digital Signature Based on a Conventional Encryption Function”](https://doi.org/10.1007/3-540-48184-2_32) — foundational Merkle-tree work.
