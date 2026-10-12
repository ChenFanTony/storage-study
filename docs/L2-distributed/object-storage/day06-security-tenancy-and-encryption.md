# Day 6: Security, Tenancy, and Encryption

## Learning objectives

- Separate authentication, authorization, encryption, retention, and audit.
- Apply least privilege to bucket and object operations.
- Understand presigned URLs and server-side encryption choices.
- Design tenant isolation, quota, and abuse controls.

## 1. Security layers

```text
TLS -> authenticate request -> authorize action/resource
    -> enforce retention and policy conditions
    -> encrypt/store data -> emit audit record
```

Each layer answers a different question:

| Layer | Question |
|-------|----------|
| TLS | Is the network channel confidential and authenticated? |
| SigV4/identity | Who signed the request? |
| IAM or bucket policy | May this principal perform this action on this resource? |
| Encryption at rest | Which key protects stored bytes? |
| Object Lock | May an otherwise authorized deletion occur now? |
| Audit | Can operators reconstruct who did what? |

Encryption does not grant or deny access. Object Lock does not authenticate a
caller. Audit does not prevent a destructive request.

## 2. Least privilege

Bucket actions and object actions use different resources. A principal may
need LIST on the bucket ARN but GET on `bucket/prefix/*`. Start with the minimum
operation and prefix, then add conditions for TLS, source network, tags,
encryption headers, or required conditional writes.

Avoid long-lived administrator access keys in training jobs. Prefer workload
identity or short-lived credentials. Separate data-reader, data-writer,
lifecycle-operator, replication, and break-glass roles.

A deny guardrail is useful for invariants such as:

- reject plaintext transport;
- reject unencrypted PUT;
- prevent writes outside a workload prefix;
- require `If-None-Match` for immutable publication;
- prevent retention bypass except by a controlled role.

## 3. Presigned URLs

A presigned URL delegates a specific request until expiration. Treat it as a
bearer credential: anyone who receives the URL can use the granted operation
within its constraints.

Keep lifetime short, restrict method and key, avoid logging query strings, and
assume chat systems, browser history, proxy logs, and metrics can leak URLs.
Revocation may require disabling the signing credential or adding a policy
deny, depending on the service.

## 4. Encryption choices

Common server-side models are:

- service-managed key: simplest operations;
- KMS-managed key: centralized key policy, audit, and rotation;
- customer-provided key: client supplies key material per request.

KMS availability and quota become part of the data path. Multipart upload may
need KMS permissions at initiation, part processing, completion, and readback.
A ciphertext copy without key-policy recovery is not a usable backup.

Client-side encryption hides plaintext from the object service but moves key
management, metadata format, range-read alignment, and rotation to the client.

## 5. Multi-tenancy and abuse controls

Buckets are useful isolation and lifecycle boundaries, but not automatically
hard tenant boundaries. Evaluate:

- identity and policy separation;
- encryption keys;
- metadata/index and gateway resource sharing;
- per-tenant quota and rate limiting;
- noisy-neighbor effects during LIST, ingest, and repair;
- audit-log separation;
- deletion and retention authority.

Rate limits should distinguish request count, bytes, operation type, and
concurrency. One huge GET and 100,000 tiny HEAD requests stress different
resources.

## 6. Lab: test a prefix-scoped identity

Create a disposable identity whose policy allows:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::object-study"],
      "Condition": {
        "StringLike": {"s3:prefix": ["team-a/*"]}
      }
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": ["arn:aws:s3:::object-study/team-a/*"]
    }
  ]
}
```

Verify allowed PUT/GET under `team-a/`, denied access under `team-b/`, denied
bucket deletion, and an audit record for both success and denial. Adapt policy
syntax to the tested S3-compatible implementation.

Never place real credentials in a study document, command history, or Git
repository.

## Failure patterns

- Giving every workload a shared administrator key.
- Allowing LIST on all tenants because a client only needs one prefix.
- Logging presigned URLs.
- Enabling KMS encryption without testing key outage and disaster recovery.
- Sharing one unlimited gateway pool across mutually untrusted tenants.
- Treating versioning or retention as a substitute for independent backup.

## Self-check

1. Why are authentication and authorization separate?
2. What makes a presigned URL sensitive?
3. How can KMS throttle object I/O?
4. Which boundaries are needed for a hostile tenant rather than a friendly team?

## References

- [How Amazon S3 works with IAM](https://docs.aws.amazon.com/AmazonS3/latest/userguide/security_iam_service-with-iam.html)
- [S3 API operations and required permissions](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-with-s3-policy-actions.html)
- [Amazon S3 presigned URLs](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html)
- [Amazon S3 server-side encryption](https://docs.aws.amazon.com/AmazonS3/latest/userguide/serv-side-encryption.html)
- [Ceph RGW authentication](https://docs.ceph.com/en/latest/radosgw/s3/authentication/)

---

## Previous / Next

[← Previous: Day 5 — Durability and repair: replication, erasure coding, placement, scrub, and healing](day05-durability-placement-and-repair.md) | [Object-storage study index](README.md) | [Next: Day 7 — Ceph RGW, MinIO, and SeaweedFS architecture comparison →](day07-ceph-minio-seaweedfs.md)
