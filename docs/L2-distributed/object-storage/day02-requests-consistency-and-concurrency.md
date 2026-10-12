# Day 2: Requests, Consistency, and Concurrency

## Learning objectives

- Understand what Signature Version 4 authenticates.
- Separate single-key atomicity from multi-key transactions.
- Use conditional writes instead of HEAD-then-PUT races.
- Design retries that do not create accidental overwrites or retry storms.

## 1. Request path and SigV4

An S3 request is an authenticated HTTP request:

```text
method + path + query + selected headers + payload hash
                         |
                         v
                  canonical request
                         |
                         v
 credential scope + timestamp + HMAC signing-key derivation
                         |
                         v
               Authorization signature
```

The server reconstructs the canonical request and verifies the signature. A
mismatch can come from wrong credentials, clock skew, a changed header, path
encoding, proxy rewriting, region/service scope, or payload hashing—not only
from a bad password.

Use an SDK or CLI for normal applications. Hand-written signing code is useful
for study but is easy to get subtly wrong.

## 2. Consistency boundaries

Amazon S3 documents strong read-after-write consistency for PUT and DELETE, and
strong results for subsequent GET and LIST operations. Other S3-compatible
systems must be checked against their own documentation and configuration.

Strong single-object consistency means a reader sees an old complete value or
a new complete value, never a partially overwritten object. It does not create
a transaction across several keys:

```text
PUT part-A  succeeds
PUT part-B  succeeds
PUT manifest fails
```

The system may correctly expose A and B even though the logical dataset is not
complete. The application must define the generation commit protocol.

## 3. Conditional writes

For one key, HTTP preconditions provide atomic guards:

| Header | Intent | Typical failure |
|--------|--------|-----------------|
| `If-None-Match: *` | Create only when no current object exists | `412 Precondition Failed` |
| `If-Match: <etag>` | Replace only if the current representation still matches | `412 Precondition Failed` |

A concurrent DELETE can produce a conflict that requires retry. In a
versioned bucket, existence checks apply to the current version; a current
delete marker changes the result.

This removes the classic race:

```text
unsafe:  HEAD says absent -> another writer PUTs -> first writer overwrites it
safe:    PUT with If-None-Match:* -> only one competing write can win
```

Conditional writes are still per-key. Use a consensus store or database when
the invariant spans several independent keys.

## 4. Idempotency and retry ownership

Classify operations before retrying:

- GET and HEAD are naturally repeatable.
- PUT to a content-addressed or immutable key is repeatable if bytes and
  metadata are identical.
- Conditional PUT is safely retried only after interpreting `409` and `412`.
- CompleteMultipartUpload needs the original upload ID and exact part list.
- DELETE in a versioned bucket may create another delete marker rather than
  reproducing the same state.

Bound attempts, add exponential backoff with jitter, and enforce one retry
budget across SDK, sidecar, proxy, and application layers. Nested retries turn
a short failure into an overload storm.

## 5. Lab: race two creators

```bash
printf 'writer-a\n' > /tmp/writer-a.txt
printf 'writer-b\n' > /tmp/writer-b.txt

aws --endpoint-url "$S3_ENDPOINT" s3api put-object \
  --bucket "$LAB_BUCKET" --key locks/job-42 \
  --body /tmp/writer-a.txt --if-none-match '*'

aws --endpoint-url "$S3_ENDPOINT" s3api put-object \
  --bucket "$LAB_BUCKET" --key locks/job-42 \
  --body /tmp/writer-b.txt --if-none-match '*'
```

On an implementation supporting S3 conditional writes, the first request
succeeds and the second should fail rather than overwrite it. Capture the HTTP
status and verify the stored bytes. If the endpoint rejects the option itself,
record that compatibility gap; do not emulate it with HEAD followed by PUT.

## Failure patterns

- Calling S3 "strongly consistent" and assuming multi-object serializability.
- Using LIST to elect a leader or allocate a unique sequence.
- Retrying every 4xx response even when the precondition intentionally failed.
- Letting four software layers each perform five retries.
- Signing a request before a proxy changes the host, path, or signed headers.

## Self-check

1. What data is protected by SigV4?
2. What guarantee is limited to a single key?
3. Why is `If-None-Match: *` safer than HEAD followed by PUT?
4. When should coordination move to etcd or a transactional database?

## References

- [Authenticating S3 requests with Signature Version 4](https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-authenticating-requests.html)
- [Amazon S3 consistency model](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel)
- [Amazon S3 conditional writes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html)
- [Enforcing conditional writes with bucket policy](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes-enforce.html)

---

## Previous / Next

[← Previous: Day 1 — Object model and S3 API: buckets, keys, prefixes, versions, and metadata](day01-object-model-and-s3-api.md) | [Object-storage study index](README.md) | [Next: Day 3 — Multipart, versioning, lifecycle, and Object Lock →](day03-multipart-versioning-lifecycle-lock.md)
