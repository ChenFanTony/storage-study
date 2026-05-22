# Day 15: dm-crypt — IV Modes, Queue Depth, and Performance Overhead

## Learning Objectives
- Understand dm-crypt's architecture and where in the stack encryption happens
- Know the IV modes (`plain64`, `essiv`, `random`) and their security/performance trade-offs
- Understand why dm-crypt's internal workqueues hurt fast SSDs, and how to bypass them
- Measure the actual overhead of encryption at different queue depths and block sizes
- Know the architect-level recommendations for production deployments

---

## 1. Where dm-crypt Sits in the Stack

```
        Filesystem (ext4 / XFS / ...)
              │
              ▼ submit_bio()
        ┌─────────────────────────────────┐
        │   dm-crypt (device-mapper)      │
        │   - intercepts bio              │
        │   - per-sector IV generation    │
        │   - calls kernel crypto API     │
        │   - clones bio with ciphertext  │
        └────────────────┬────────────────┘
                         │
                         ▼
              Underlying block device (SSD/HDD/RAID)
```

dm-crypt is **synchronous from the filesystem's view**: a write returns only
after encryption + underlying device write completes. But internally, dm-crypt
has historically used kernel workqueues (`kcryptd`) to offload the actual
encryption work — which adds latency on fast devices. That's the central
performance story today.

---

## 2. Cipher Specification Format

```
cipher-chainmode-ivmode[:ivopts]
```

Common combinations (from kernel docs):
- `aes-xts-plain64` — current default; **XTS mode with plain64 IV**
- `aes-cbc-essiv:sha256` — older default; CBC mode with ESSIV
- `aes-cbc-plain64` — INSECURE for disk encryption; vulnerable to watermarking
- `capi:gcm(aes)-random` — authenticated mode (AEAD); higher cost, integrity

Verify with `cryptsetup luksDump <device>` or `dmsetup table <name>`:
```bash
dmsetup table cryptroot | head -1
# 0 1953125000 crypt aes-xts-plain64 :64:logon:cryptsetup:... 0 8:1 4096 ...
#                    ^^^^^^^^^^^^^^^ cipher-mode-iv
```

---

## 3. IV Modes — What They Are and Why It Matters

The IV (initialization vector) prevents two encryptions of the same plaintext
from producing the same ciphertext. For disk encryption, each sector needs a
unique IV that the kernel can recompute on read.

### plain64
- IV is just the sector number (64-bit). Cheap to compute.
- **Required for XTS** — XTS uses the IV as a "tweak"; the security
  proof relies on tweaks being unique but not secret. Using sector number
  directly is fine in XTS.
- **NOT acceptable for CBC** — predictable IVs in CBC enable watermarking
  attacks (an attacker who knows the plaintext can detect when specific
  files appear on disk).

### essiv:hash
- IV is computed by encrypting the sector number with a hash of the master key.
- Adds one extra encryption per sector (modest cost).
- Used historically with CBC to make the IV unpredictable to attackers.
- `aes-cbc-essiv:sha256` is the canonical "secure CBC" combination.

### random
- IV is a fresh random number per sector, stored alongside the ciphertext.
- Used by AEAD modes (`gcm`, `chacha20-poly1305`) because GCM is catastrophically
  broken under IV reuse.
- Requires extra space on disk per sector for the IV + auth tag — only viable
  with the integrity-aware on-disk format.

### Architect's rule
- **Use `aes-xts-plain64` for everything new.** This is what cryptsetup defaults
  to and what every modern Linux distro uses. XTS is hardware-accelerated via
  AES-NI and gives the best performance.
- If you see `aes-cbc-essiv:sha256` in old systems, that was the previous
  default. Don't change a working system without reason.
- If integrity matters (you want to detect tampering, not just secrecy),
  use an AEAD mode like `capi:gcm(aes)-random` and accept the overhead.

---

## 4. The Cloudflare Discovery: dm-crypt's Internal Queues Hurt Fast SSDs

This is the single most important production knob to know.

```
Default dm-crypt I/O path:
  bio in → kcryptd workqueue → encrypt → submit to disk
  disk completion → kcryptd_io workqueue → decrypt → return to caller

Each workqueue hop = a context switch + cache miss + scheduler latency.
On a 7200rpm HDD: invisible (disk is the bottleneck anyway).
On a fast NVMe: visible — kcryptd becomes a serialization point.
```

Cloudflare's investigation (Speeding up Linux disk encryption, 2020) added
two flags that let dm-crypt bypass these workqueues:

- `no_read_workqueue` — encrypt/decrypt the read path inline in the bio
  completion context.
- `no_write_workqueue` — submit the encrypted write directly to the underlying
  device from the submitter's context (no kcryptd hop).

Both can be set persistently in the LUKS2 header so they apply at every boot:

```bash
# One-time set, persisted in LUKS2 metadata
cryptsetup --perf-no_read_workqueue --perf-no_write_workqueue \
           --persistent refresh <crypt_name>

# Verify they're set
cryptsetup luksDump /dev/nvme0n1p3 | grep -i flags
# Flags:       no-read-workqueue no-write-workqueue

# Verify on the active device
dmsetup table cryptroot | grep -o "no_[rw]*_workqueue"
```

### When this helps vs hurts

| Backing device | Workload | Effect |
|----------------|----------|--------|
| Fast NVMe | Sequential, small block (4K) | **Big speedup** (often 2–5×) |
| Fast NVMe | High queue depth, parallel | Helps modestly; thread sharing matters |
| SATA SSD | Mixed | Helps moderately |
| HDD | Anything | Negligible (disk dominates) |
| Heavy CPU contention | Anything | Can hurt — workqueue let crypto run on free CPUs |

The flags trade workqueue offload for inline execution. On a CPU-saturated
system, inline encryption blocks the submitting thread. Measure before
making it persistent on a multi-tenant box.

---

## 5. Sector Size: Another Major Knob

dm-crypt's default sector size is 512 bytes — even when the device and
filesystem use 4096. This means:
- Every 4K filesystem block triggers 8 separate IV computations + 8 crypto API calls.
- Per-bio overhead dominates the actual crypto cost on fast hardware.

Setting the dm-crypt sector size to 4096 collapses this to 1 IV + 1 crypto
call per filesystem block.

```bash
# Must be set at LUKS format time (not retroactively changeable)
cryptsetup luksFormat --sector-size=4096 /dev/nvme0n1p3
```

Verify:
```bash
cryptsetup luksDump /dev/nvme0n1p3 | grep -i sector
# sector: 4096 [bytes]
```

Reported gains on NVMe: 50–100% on small-block sequential workloads.

---

## 6. AES-NI and Hardware Acceleration

Modern x86 CPUs accelerate AES via the AES-NI instruction set. Verify:

```bash
# CPU has AES-NI?
grep -m1 -o 'aes' /proc/cpuinfo

# Kernel using accelerated AES module?
grep -m1 'name\s*: aes' /proc/crypto -A2
# Look for "module" referencing aesni_intel or similar

# Benchmark crypto modes
cryptsetup benchmark
# Shows MB/s for aes-cbc, aes-xts at 128- and 256-bit keys
```

If `cryptsetup benchmark` reports ~2GB/s or more for AES-XTS on a modern CPU,
AES-NI is active. Without it, expect roughly 5–10× slower throughput and
much higher CPU load — non-AES-NI is rarely viable for fast storage.

ARM has equivalents (`aes`, `pmull` features in `/proc/cpuinfo`).

---

## 7. Hands-On: Measure the Real Overhead

```bash
# Setup: take any NVMe partition, encrypt it, benchmark both ways.
RAW=/dev/nvme0n1p3
NAME=test_crypt

cryptsetup luksFormat --type luks2 --sector-size=4096 $RAW
cryptsetup open $RAW $NAME
# /dev/mapper/$NAME is now usable

# Baseline: raw device random 4K reads
fio --name=raw --filename=$RAW --rw=randread --bs=4k \
    --ioengine=libaio --iodepth=32 --time_based --runtime=30 \
    --percentile_list=50,99 --output-format=terse | grep -E 'iops|lat'

# Encrypted, default settings
fio --name=def --filename=/dev/mapper/$NAME --rw=randread --bs=4k \
    --ioengine=libaio --iodepth=32 --time_based --runtime=30 \
    --percentile_list=50,99 --output-format=terse | grep -E 'iops|lat'

# Enable workqueue bypass and refresh the active mapping
cryptsetup --perf-no_read_workqueue --perf-no_write_workqueue \
           refresh $NAME

# Same fio run again — compare
fio --name=opt --filename=/dev/mapper/$NAME --rw=randread --bs=4k \
    --ioengine=libaio --iodepth=32 --time_based --runtime=30 \
    --percentile_list=50,99 --output-format=terse | grep -E 'iops|lat'

# Cleanup
cryptsetup close $NAME
```

What you're looking for:
- IOPS difference between raw and encrypted (with workqueues): the cost of dm-crypt.
- IOPS difference between default and bypassed workqueues: how much the
  workqueue overhead specifically costs you.
- p99 latency comparison: workqueue path typically adds 20–100µs of tail.

---

## 8. Discard / TRIM Through dm-crypt

By default dm-crypt **swallows discards** — the underlying SSD never sees TRIM.
This is for plausible-deniability reasons (TRIM patterns reveal which blocks
contain data), but for typical full-disk encryption it just means your SSD's
internal GC gets worse over time.

```bash
# Enable discard passdown at open time (one-shot)
cryptsetup --allow-discards open $RAW $NAME

# Or persistently
cryptsetup --allow-discards --persistent refresh $NAME

# Verify
dmsetup table $NAME | grep -o allow_discards
```

**Security note:** an attacker with offline disk access can see which sectors
are unmapped vs encrypted. For most production use cases this is acceptable;
for plausible-deniability scenarios it isn't.

---

## 9. CPU Affinity: `same_cpu_crypt` and `submit_from_crypt_cpus`

Two more optional dm-crypt features worth knowing:

- `same_cpu_crypt` — perform the encryption on the same CPU that submitted
  the bio. Improves cache locality but loses the ability to parallelize
  encryption across CPUs for a single submitter.
- `submit_from_crypt_cpus` — submit the resulting encrypted bio from the
  CPU that did the encryption (rather than the original submitter). Pairs
  well with `same_cpu_crypt`.

These matter on multi-socket NUMA boxes where bouncing bios across sockets
adds latency. On a typical single-socket NVMe server they make little
difference; measure before setting.

---

## 10. Architect's Decision Matrix

| Scenario | Cipher | Sector | Flags | Reasoning |
|----------|--------|--------|-------|-----------|
| New NVMe-backed system | `aes-xts-plain64` | 4096 | `no_*_workqueue`, `allow_discards` | Modern default, big perf gains |
| SATA SSD | `aes-xts-plain64` | 4096 | `allow_discards` (workqueue optional) | Crypto isn't bottleneck; workqueue helps less |
| HDD | `aes-xts-plain64` | 512 or 4096 | none needed | Disk dominates; tuning negligible |
| Integrity required | `capi:gcm(aes)-random` + dm-integrity | n/a | n/a | Cost is real; only when threat model demands |
| Legacy system | `aes-cbc-essiv:sha256` | 512 | leave alone | Don't break what works without reason |

---

## 11. Source Reading Checklist

```
drivers/md/dm-crypt.c          # the whole target
  crypt_map()                  # bio entry point
  kcryptd_io()                 # workqueue handlers
  crypt_convert()              # actual encryption loop
  crypt_iv_*_gen()             # IV generators (one per mode)
```

The IV generator functions (`crypt_iv_plain64_gen`, `crypt_iv_essiv_gen`,
`crypt_iv_random_gen`) are short and worth reading to internalize what each
IV mode actually computes.

---

## 12. Self-Check Questions

1. Why is `aes-cbc-plain64` insecure for disk encryption while `aes-xts-plain64` is fine?
2. What do `no_read_workqueue` and `no_write_workqueue` do, and on what hardware do they help most?
3. Why does setting dm-crypt sector size to 4096 (vs 512) typically improve performance on NVMe?
4. A customer reports 1GB/s throughput on a raw NVMe but only 200MB/s with dm-crypt. AES-NI is enabled. What's the most likely cause and what would you try first?
5. Why is enabling `allow_discards` a security/performance trade-off?
6. When would you NOT enable the workqueue-bypass flags?

## 13. Answers

1. CBC with predictable IVs (the sector number) lets an attacker compare ciphertext patterns across devices and detect known plaintext files — the watermarking attack. XTS uses the IV as a "tweak" in a different way; its security proof allows public, sector-number-derived tweaks.
2. They make dm-crypt do encryption/decryption inline in the submitter's context instead of bouncing through the `kcryptd`/`kcryptd_io` workqueues. Each workqueue hop adds context-switch and scheduler latency that becomes visible on fast SSDs (NVMe especially) where the underlying I/O is already in the tens-of-microseconds range. On HDDs the workqueue overhead is invisible.
3. With 512-byte sectors, each 4K filesystem block becomes 8 separate IV computations + 8 crypto API calls + 8 bio splits, multiplying the per-operation overhead. 4K sector size collapses this to one operation per filesystem block.
4. Most likely the default workqueue path is the bottleneck. Try `cryptsetup --perf-no_read_workqueue --perf-no_write_workqueue refresh`. Also check the LUKS sector size with `cryptsetup luksDump` — if it's 512, you'd need to re-format with `--sector-size=4096` to fix it (data loss; back up first).
5. Discard reveals which blocks are unmapped/empty on the underlying device. An attacker with offline access can see your filesystem's allocation pattern (rough file sizes, free space). In exchange, the SSD's internal GC works correctly and write performance doesn't degrade over time. For typical FDE this trade is fine; for plausible-deniability scenarios it isn't.
6. On a CPU-saturated, multi-tenant box, the workqueues let crypto run on otherwise-idle CPUs. Inline execution blocks the submitting thread. If your bottleneck is CPU rather than I/O latency, the bypass flags can hurt. Measure both ways under realistic load.

---

## Tomorrow: Day 16 — md/RAID: Partial-Stripe Writes and Resync

We go deep on the RAID-5/6 small-write problem, why write-intent bitmaps
matter for resync time, and how md's stripe cache interacts with the
block layer's plug mechanism.
