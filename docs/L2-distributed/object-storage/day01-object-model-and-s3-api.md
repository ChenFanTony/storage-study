# Day 1: Object Model and S3 API

## Learning objectives

- Distinguish object, block, and file semantics.
- Understand buckets, keys, prefixes, versions, and object metadata.
- Know what PUT, GET, HEAD, LIST, COPY, and DELETE actually operate on.
- Avoid treating an S3 namespace like a POSIX directory tree.

## 1. The object is the unit of storage

An object store exposes a logical record:

```text
(bucket, key, optional version)
        |
        +-- payload bytes
        +-- system metadata
        +-- user metadata
        `-- tags, retention, and access-control state
```

The key is an opaque byte/string name within a bucket. A key such as
`datasets/v3/shard-0042.tar` looks hierarchical, but `/` is normally just a
character. Clients create the directory illusion by asking LIST to group keys
by a prefix and delimiter.

This produces a different contract from a filesystem:

| Operation | Filesystem | Object storage |
|-----------|------------|----------------|
| Address | Path resolved through directories | Bucket plus complete key |
| Update | Often supports offset writes | Normally replace the whole object |
| Rename | Metadata operation, sometimes atomic | Usually COPY then DELETE |
| Directory | Persistent namespace object | Usually a derived LIST view |
| Random read | `pread()` at byte offset | HTTP range GET |
| Multi-item transaction | Sometimes available locally | Usually not available |

Do not build correctness around directory rename, inode identity, hard links,
or advisory locks unless a specific object service explicitly adds them.

## 2. Core request surface

```text
PUT object    publish or replace one key
GET object    return payload and response metadata
HEAD object   return metadata without the payload
DELETE object remove a key or create a delete marker when versioning applies
LIST objects  scan the bucket index by prefix, with pagination
COPY object   create a destination object from a source object
```

A successful PUT publishes one object. It does not atomically publish all keys
under a prefix. A dataset or checkpoint made from many objects therefore needs
an application-level manifest or final commit marker.

HEAD is useful for existence, size, version, checksum, and cache validation,
but repeated HEAD-before-GET doubles request pressure and can create a
time-of-check/time-of-use race. Prefer a conditional request when correctness
depends on the state not changing.

## 3. Metadata, ETags, and checksums

System metadata commonly includes content length, content type, last-modified
time, storage class, version ID, and integrity fields. User metadata is small
key/value state carried with the object. Tags are separately addressable policy
metadata in many S3 implementations.

An ETag identifies a representation for HTTP cache and conditional-request
purposes. Do not universally treat it as the MD5 checksum of the payload:
multipart upload, encryption, and implementation details can produce a value
that is not a plain payload MD5. Store or request an explicit checksum when
end-to-end integrity matters.

## 4. LIST is a metadata query

LIST does not scan object payload. It queries an index:

```text
prefix + continuation token + page size
                  |
                  v
        ordered or partitioned metadata index
                  |
                  v
       page of keys + next continuation token
```

Always consume every page. Never assume one response is the complete bucket.
Avoid putting LIST in a per-batch AI training hot path; distribute a manifest
of known shard keys instead.

## 5. Lab: inspect the model

```bash
printf 'object-storage-study\n' > /tmp/object-study.txt

aws --endpoint-url "$S3_ENDPOINT" s3api create-bucket \
  --bucket "$LAB_BUCKET"

aws --endpoint-url "$S3_ENDPOINT" s3api put-object \
  --bucket "$LAB_BUCKET" \
  --key datasets/v1/shard-0000.txt \
  --body /tmp/object-study.txt \
  --metadata owner=storage-team,format=text

aws --endpoint-url "$S3_ENDPOINT" s3api head-object \
  --bucket "$LAB_BUCKET" \
  --key datasets/v1/shard-0000.txt

aws --endpoint-url "$S3_ENDPOINT" s3api list-objects-v2 \
  --bucket "$LAB_BUCKET" \
  --prefix datasets/v1/ \
  --max-keys 1
```

Record the returned ETag, size, metadata, and continuation fields. Then upload
another key containing `/` and confirm that no directory-creation request was
needed.

## Failure patterns

- A client assumes LIST returns every key in one response.
- A workflow treats a prefix rename as atomic publication.
- A data verifier compares a multipart ETag with a local MD5.
- Millions of tiny objects overwhelm request and metadata capacity long before
  raw disk capacity is exhausted.
- A cleanup job deletes by prefix without first freezing or versioning the
  namespace.

## Self-check

1. Why is `a/b/c` not necessarily a directory hierarchy?
2. What is the difference between HEAD and GET?
3. Why can an ETag be unsafe as a universal payload checksum?
4. How would you publish a dataset containing 10,000 objects?

## References

- [Amazon S3 overview and consistency model](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html)
- [ListObjectsV2 API](https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html)
- [Checking object integrity](https://docs.aws.amazon.com/AmazonS3/latest/userguide/checking-object-integrity.html)
- [Ceph RGW S3 API](https://docs.ceph.com/en/latest/radosgw/s3/)

---

## Next

[Object-storage study index](README.md) | [Next: Day 2 — Requests and concurrency: SigV4, consistency, conditional writes, and retries →](day02-requests-consistency-and-concurrency.md)
