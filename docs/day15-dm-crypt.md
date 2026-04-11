# Day 15: dm-crypt — Per-Bio Encryption & Performance Architecture

## Learning Objectives
- Understand dm-crypt's per-bio encryption model at source level
- Know the IV (initialization vector) modes and their security/performance tradeoffs
- Measure encryption overhead at different queue depths
- Know when hardware inline encryption (blk-crypto) changes the picture
- Be able to specify encryption architecture in a design review

---

## 1. dm-crypt in the Stack

```
Application write
  → VFS → filesystem → block layer
    → dm-crypt target
        → encrypt bio data (in-place or new pages)
        → resubmit encrypted bio to underlying device
          → NVMe / HDD
```

dm-crypt sits as a device mapper target. Every bio passing through gets
encrypted (writes) or decrypted (reads) before being passed down or up.

```c
// drivers/md/dm-crypt.c — the core structure

struct crypt_config {
    struct dm_dev       *dev;           // underlying block device
    sector_t            start;          // offset on underlying device

    struct crypto_skcipher *tfm[];      // array of cipher transform handles
                                        // one per CPU (avoid lock contention)

    char                *cipher_string; // e.g. "aes-xts-plain64"
    struct crypt_iv_operations *iv_gen_ops; // IV generation method

    unsigned int        key_size;
    u8                  *key;

    mempool_t           req_pool;       // pre-allocated crypto request pool
    mempool_t           page_pool;      // pre-allocated page pool for bounce buffers
    // ...
};
```

Key design: **one cipher transform handle per CPU** — this is how dm-crypt
avoids per-request lock contention on the crypto hardware or software path.

---

## 2. The Per-Bio Encryption Path

### Write path (encrypt before writing to disk)

```c
// dm-crypt.c: crypt_map() — called for every bio

crypt_map(struct dm_target *ti, struct bio *bio):
    io = crypt_io_alloc(cc, bio, ...);

    if (bio_data_dir(bio) == WRITE):
        kcryptd_queue_crypt(io);
        // → worker thread: kcryptd_crypt_write_io_submit()
        //   → crypt_convert() — encrypt each bio_vec segment
        //     → for each sector:
        //       1. generate IV for this sector
        //       2. skcipher_request_set_crypt(req, src, dst, len, iv)
        //       3. crypto_skcipher_encrypt(req)
        //     → encrypted data written to cloned bio
        //   → submit cloned bio to underlying device

    if (bio_data_dir(bio) == READ):
        // submit read to underlying device first
        // on completion: decrypt in kcryptd_crypt_read_done()
```

**Bounce buffers:** dm-crypt typically allocates new pages for encrypted data
rather than encrypting in-place. This means every I/O involves:
- Allocate page(s) for encrypted/decrypted copy
- Crypto operation
- Free original page(s)

This is why dm-crypt has measurable memory allocation overhead at high IOPS.

---

## 3. IV Modes — Security vs Performance

The IV (Initialization Vector) ensures that identical plaintext blocks
encrypt to different ciphertexts. The IV mode is the most security-critical
design decision in full-disk encryption.

### `plain` / `plain64`
```
IV = sector_number (32-bit / 64-bit)
Performance: best (trivial computation)
Security: vulnerable to watermarking attacks if attacker knows plaintext
Use: legacy, avoid for new deployments
```

### `essiv`
```
IV = encrypt(sector_number, hash(key))
Performance: one extra block cipher per IV (small overhead)
Security: protects against watermarking; sector numbers are not predictable
Use: was the recommended default; now superseded by xts mode
```

### `xts` (XEX-based tweaked-codebook mode with ciphertext stealing)
```
Mode: XTS-AES (aes-xts-plain64)
IV: sector number used directly as "tweak" — XTS handles this internally
Performance: ~same as plain64 but mode provides stronger security
Security: current standard for disk encryption
          resistant to chosen-plaintext attacks
          does NOT provide authentication (no integrity check)
Use: recommended default for all new deployments
```

### `adiantum`
```
Mode: ChaCha12 + Poly1305-based (ARM-optimized)
Performance: significantly faster than AES on systems WITHOUT AES-NI
Security: strong, but not FIPS-approved
Use: embedded/ARM systems without hardware AES acceleration
```

```bash
# Check what cipher your LUKS volume uses
cryptsetup luksDump /dev/nvme0n1 | grep -E "Cipher|Mode|Hash"

# Benchmark cipher performance
cryptsetup benchmark
# Shows: cipher, key size, encryption speed (MB/s), decryption speed (MB/s)
# On AES-NI capable hardware: AES-XTS typically 2-10 GB/s
# Without AES-NI: 200-500 MB/s
```

---

## 4. Performance Impact: Queue Depth Is Critical

dm-crypt's crypto operations happen in worker threads (`kcryptd`). At low
queue depth, the crypto threads are the bottleneck. At high queue depth,
the underlying device becomes the bottleneck.

```
Queue depth = 1:
  Request arrives → crypto thread encrypts → submits to NVMe
  → crypto thread idle while NVMe processes
  → next request
  CPU utilization: low; throughput: limited by crypto thread latency

Queue depth = 32:
  32 requests arrive → 32 concurrent crypto operations (one per CPU if enough CPUs)
  → all submitted to NVMe simultaneously
  → NVMe saturated; crypto threads stay busy
  CPU utilization: high; throughput: near-device maximum
```

```bash
# Measure dm-crypt overhead at various queue depths
LUKS_DEV=/dev/mapper/crypted

for depth in 1 4 16 32 64; do
    echo "=== iodepth=$depth ==="
    fio --name=crypt-test-${depth} \
        --filename=${LUKS_DEV} \
        --rw=randread \
        --bs=4k \
        --ioengine=libaio \
        --iodepth=${depth} \
        --time_based --runtime=15 \
        --output-format=terse | grep -oP 'iops=\K[0-9]+'
done

# Compare against raw device (no encryption)
for depth in 1 4 16 32 64; do
    echo "=== raw iodepth=$depth ==="
    fio --name=raw-${depth} \
        --filename=/dev/nvme0n1 \
        --rw=randread \
        --bs=4k \
        --ioengine=libaio \
        --iodepth=${depth} \
        --time_based --runtime=15 \
        --output-format=terse | grep -oP 'iops=\K[0-9]+'
done
# Overhead = (raw_iops - crypt_iops) / raw_iops × 100%
# Expected: <5% at depth 32+ with AES-NI; 20-40% at depth 1
```

---

## 5. Hardware Inline Encryption: blk-crypto

blk-crypto (kernel 5.8+) moves encryption out of dm-crypt and into the
block layer, using hardware engines in modern NVMe controllers and eMMC.

```
dm-crypt path (software):
  bio data → CPU encrypts → encrypted bio → NVMe controller → NAND

blk-crypto path (hardware inline):
  bio data → NVMe controller → encrypts during DMA → NAND
  (CPU does zero crypto work)
```

```c
// block/blk-crypto.c

// bio gets an encryption context attached:
struct bio_crypt_ctx {
    const struct blk_crypto_key *bc_key;
    u64                          bc_dun[BLK_CRYPTO_DUN_ARRAY_SIZE]; // IV/DUN
};

// blk-crypto checks if hw supports the key/algorithm:
// If yes → hardware does encryption during DMA
// If no  → blk-crypto-fallback: software encrypt same as dm-crypt
```

```bash
# Check if your NVMe supports inline encryption
cat /sys/block/nvme0n1/queue/crypto/max_dun_bits 2>/dev/null
# If file exists and non-zero → hardware inline encryption supported

# fscrypt uses blk-crypto for per-file encryption (Android, ChromeOS)
# For full-disk encryption with inline crypto: use fscrypt or blk-crypto directly
# dm-crypt does NOT automatically use blk-crypto hardware (as of kernel 6.x)
```

---

## 6. dm-crypt + dm-cache: Stack Ordering Matters

Two valid orderings, very different behavior:

### Option A: dm-crypt below dm-cache (encrypt at rest)
```
filesystem → dm-cache (plaintext cache) → dm-crypt → NVMe/HDD
```
- SSD cache stores **plaintext** data — if SSD is stolen, data exposed
- Encryption happens at the physical device boundary
- Cache performance unaffected by encryption (plaintext in SSD)
- **Not encrypt-at-rest for cache device**

### Option B: dm-crypt above dm-cache (cache encrypted data)
```
filesystem → dm-crypt → dm-cache (encrypted cache) → NVMe/HDD
```
- SSD cache stores **ciphertext** — both SSD and HDD are encrypted at rest
- Every cache hit still requires decryption (CPU cost on read)
- Every cache write requires encryption (CPU cost on write)
- Correct for full encrypt-at-rest security model

```bash
# Verify your stack ordering
dmsetup deps /dev/mapper/your_device
# Shows what each dm device depends on
# Trace from top to bottom to see the ordering
```

**Architect recommendation:** Option B is almost always correct for security.
Option A is only acceptable if the SSD cache device is physically secured
(encrypted at hardware level or in a tamper-evident enclosure).

---

## 7. LUKS2 vs LUKS1: Architect Differences

```bash
# LUKS2 (recommended for new deployments)
cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \          # 512 bits = 2×256-bit XTS keys
    --hash sha256 \
    --pbkdf argon2id \        # memory-hard KDF (resistant to GPU cracking)
    /dev/nvme0n1

# Key LUKS2 improvements over LUKS1:
# - Argon2id PBKDF (LUKS1 uses PBKDF2 — weaker against GPU attacks)
# - JSON metadata header (more robust, supports more keyslots)
# - Integrity support (with --integrity option: adds per-sector auth tags)
# - Header backup areas (more resilient to partial corruption)

# LUKS2 with integrity (encrypt + authenticate — protects against bit-flip attacks)
cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 \
    --integrity hmac-sha256 \   # adds 32-byte integrity tag per sector
    /dev/nvme0n1
# Note: integrity reduces usable capacity by ~1.6% and adds overhead
```

---

## 8. Hands-On: Measure Encryption Overhead

```bash
# Setup LUKS2 on a test device or file
dd if=/dev/zero of=/tmp/crypt-test.img bs=1M count=4096
LOOP=$(losetup --find --show /tmp/crypt-test.img)

cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 \
    --batch-mode --key-file /dev/urandom \
    $LOOP

cryptsetup open $LOOP crypttest --key-file /dev/urandom

# Benchmark: raw vs encrypted
echo "=== Raw loopback ==="
fio --name=raw --filename=$LOOP \
    --rw=randwrite --bs=4k --ioengine=libaio --iodepth=32 \
    --time_based --runtime=20 --output-format=terse \
    | awk -F';' '{print "write IOPS:", $49, "read IOPS:", $8}'

echo "=== Encrypted (dm-crypt) ==="
fio --name=enc --filename=/dev/mapper/crypttest \
    --rw=randwrite --bs=4k --ioengine=libaio --iodepth=32 \
    --time_based --runtime=20 --output-format=terse \
    | awk -F';' '{print "write IOPS:", $49, "read IOPS:", $8}'

# Check CPU usage during encrypted I/O
iostat -x 1 5 &
fio --name=enc-cpu --filename=/dev/mapper/crypttest \
    --rw=randread --bs=4k --ioengine=libaio --iodepth=32 \
    --time_based --runtime=10

# Cleanup
cryptsetup close crypttest
losetup -d $LOOP
```

---

## 9. Self-Check Questions

1. Why does dm-crypt allocate one cipher transform handle per CPU?
2. What is the security weakness of the `plain` IV mode compared to `xts`?
3. At queue depth 1 vs queue depth 32, what changes about dm-crypt's performance bottleneck?
4. In a stack with both dm-cache and dm-crypt, which ordering encrypts the SSD cache data at rest?
5. What does blk-crypto hardware inline encryption change vs dm-crypt software encryption?
6. LUKS2 with `--integrity hmac-sha256` adds what security property that plain XTS does not have?

## 10. Answers

1. Crypto operations are not thread-safe on a single transform handle. Per-CPU handles eliminate locking — each CPU encrypts its own requests without contention.
2. `plain` uses the sector number directly as IV. An attacker who knows two plaintexts that differ by exactly one block can detect the pattern in ciphertexts — watermarking attack. XTS mode uses the sector number as a tweak value processed through a second AES operation, eliminating this vulnerability.
3. At depth 1: crypto thread is the bottleneck — request waits for encrypt, then submits, then idles while device processes. At depth 32: 32 crypto operations run in parallel (across CPUs), device is kept saturated. The bottleneck shifts from crypto CPU to device throughput.
4. Option B: `filesystem → dm-crypt → dm-cache → device`. dm-cache stores ciphertext, so both SSD and HDD are encrypted at rest.
5. Hardware inline encryption offloads crypto from CPU to NVMe controller — done during DMA. CPU overhead drops to near zero. dm-crypt still uses CPU even with AES-NI.
6. Authentication/integrity: each sector has an HMAC tag. Bit-flip attacks (flipping encrypted bits to corrupt decrypted data in a controlled way) are detected and rejected. Plain XTS provides confidentiality only — an attacker can flip bits in ciphertext and corrupt plaintext in predictable ways without detection.

---

## Tomorrow: Day 16 — md/RAID: Resync, Bitmap Journal & Failure Recovery

We go deep on RAID-5's partial-stripe write problem, write-intent bitmap
impact on resync time, and md's personality model at source level.
