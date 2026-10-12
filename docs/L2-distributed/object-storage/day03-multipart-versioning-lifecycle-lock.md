# Day 3: Multipart Upload, Versioning, Lifecycle, and Object Lock

## Learning objectives

- Follow multipart upload from initiation to publication.
- Distinguish an ETag from an explicit checksum.
- Explain versions and delete markers.
- Separate lifecycle cleanup, retention, and backup.

## 1. Multipart upload is a publication protocol

```text
CreateMultipartUpload -> upload ID
       |
       +-- UploadPart 1 -> ETag/checksum
       +-- UploadPart 2 -> ETag/checksum
       `-- UploadPart N -> ETag/checksum
       |
CompleteMultipartUpload(part number + ETag list)
       |
       `-- one visible object
```

Parts may be uploaded independently and retried. The completed object is built
in ascending part-number order, not upload-completion order. Maintain the exact
part-number/ETag list in durable client state.

For Amazon S3 general-purpose buckets, multipart upload supports up to 10,000
parts. Non-final parts have a minimum size, and the object-size and part-size
limits must be checked before choosing a chunk size. Use the service's current
limits rather than copying constants into an application forever.

Incomplete uploads retain parts and consume capacity until explicitly aborted
or removed by lifecycle policy. Completion publishes one key; it does not
commit other keys in the same checkpoint or dataset.

## 2. Integrity

A multipart ETag is not guaranteed to equal the MD5 of the assembled payload.
Use supported checksum headers and verify the stored full-object checksum when
integrity is part of the contract.

A robust uploader records:

```text
key, upload ID, part number, byte range, part ETag,
part checksum, full-object checksum, expected object size
```

The reader validates size and an explicit checksum from a trusted manifest.
Transport TLS protects bytes in transit but does not replace end-to-end
integrity verification.

## 3. Versioning and delete markers

With versioning enabled, writes create distinct versions. A normal DELETE
usually creates a delete marker that becomes current; older data versions
remain addressable by version ID.

```text
key K:
  V3 delete marker  <- current: ordinary GET behaves as deleted
  V2 payload
  V1 payload
```

Recovery means removing the delete marker or selecting a previous version.
Capacity planning must include noncurrent versions and delete markers.
Suspending versioning does not automatically remove existing versions.

## 4. Lifecycle is asynchronous policy

Lifecycle rules can expire current or noncurrent versions, transition objects,
and abort incomplete multipart uploads. They are background policy, not an
immediate transaction boundary. Never require an object to disappear at an
exact second for application correctness.

Test overlapping rules and exclusions on a disposable prefix. A broad
expiration rule plus versioning can quietly turn recoverable history into
permanent deletion.

## 5. Object Lock

Object Lock adds write-once-read-many retention to object versions:

- governance mode can be bypassed only by principals with the relevant
  permission;
- compliance mode prevents deletion or shortening retention during the
  retention period;
- legal hold is independent of a time-based retain-until date.

Retention is not a replacement for access control, replication, or backup.
Administrators must test clock, identity, KMS, and recovery dependencies.

## 6. Lab: version and delete one key

```bash
aws --endpoint-url "$S3_ENDPOINT" s3api put-bucket-versioning \
  --bucket "$LAB_BUCKET" \
  --versioning-configuration Status=Enabled

printf 'generation-1\n' > /tmp/generation.txt
aws --endpoint-url "$S3_ENDPOINT" s3api put-object \
  --bucket "$LAB_BUCKET" --key versions/demo \
  --body /tmp/generation.txt

printf 'generation-2\n' > /tmp/generation.txt
aws --endpoint-url "$S3_ENDPOINT" s3api put-object \
  --bucket "$LAB_BUCKET" --key versions/demo \
  --body /tmp/generation.txt

aws --endpoint-url "$S3_ENDPOINT" s3api delete-object \
  --bucket "$LAB_BUCKET" --key versions/demo

aws --endpoint-url "$S3_ENDPOINT" s3api list-object-versions \
  --bucket "$LAB_BUCKET" --prefix versions/demo
```

Identify the two data versions and delete marker. Restore by explicitly
selecting a version or removing the marker. Do not run this lab in a shared
bucket.

## Failure patterns

- Completing with the wrong part/ETag list.
- Treating the multipart ETag as a payload MD5.
- Accumulating abandoned uploads without lifecycle cleanup.
- Enabling versioning without budgeting for old versions.
- Treating versioning as an offline, independently protected backup.
- Applying compliance retention before testing the operational process.

## Self-check

1. When does a multipart object become visible?
2. Why must the client persist the part list?
3. What does DELETE do in a versioned bucket?
4. How do lifecycle, versioning, and Object Lock solve different problems?

## References

- [Amazon S3 multipart upload](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html)
- [Amazon S3 multipart limits](https://docs.aws.amazon.com/AmazonS3/latest/userguide/qfacts.html)
- [Amazon S3 Versioning](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html)
- [Amazon S3 lifecycle management](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html)
- [Amazon S3 Object Lock](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html)

---

## Previous / Next

[← Previous: Day 2 — Requests and concurrency: SigV4, consistency, conditional writes, and retries](day02-requests-consistency-and-concurrency.md) | [Object-storage study index](README.md) | [Next: Day 4 — Metadata indexes and small objects: sharding, LIST fan-out, and hotspots →](day04-metadata-indexes-and-small-objects.md)
