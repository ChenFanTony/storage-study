# Day 17: dm-crypt & dm-verity

## Learning Objectives
- Understand dm-crypt's per-bio encryption model
- Learn dm-verity's Merkle-tree integrity verification
- Set up a LUKS volume with `cryptsetup` and measure overhead
- Understand where these targets fit in the storage stack

---

## 1. dm-crypt: Block-Level Encryption

### Purpose

dm-crypt provides transparent encryption of block devices. It is the kernel backend for LUKS (Linux Unified Key Setup) and plain dm-crypt volumes.

Use cases:
- Full disk encryption (FDE)
- Encrypted partitions/volumes
- Encrypted swap

### Architecture

```text
┌────────────────────────────────────┐
│  dm-crypt device (/dev/dm-X)       │  ← cleartext I/O
│    cipher: aes-xts-plain64         │
│    key: derived from passphrase    │
└──────────────┬─────────────────────┘
               | encrypt on write
               | decrypt on read
               v
┌────────────────────────────────────┐
│  underlying device (/dev/sda2)     │  ← ciphertext on disk
└────────────────────────────────────┘
```

### Bio handling in dm-crypt

Source: `drivers/md/dm-crypt.c`

```text
bio arrives at dm-crypt device
    |
    v
crypt_map(bio)
    |
    v
clone bio, allocate crypto context
    |
    v
WRITE path:
    encrypt data pages in-place or via bounce buffer
    -> submit encrypted bio to underlying device
    -> DM_MAPIO_SUBMITTED

READ path:
    remap bio to underlying device
    -> DM_MAPIO_REMAPPED
    -> on completion (crypt_endio):
       decrypt data pages
       -> complete original bio
```

Key details:
- Encryption is per-sector, using sector number as IV (initialization vector)
- Write encryption happens before submission (synchronous or workqueue)
- Read decryption happens in completion callback
- Crypto operations use kernel crypto API (`skcipher`)

### Encryption modes

Common cipher specifications:
- `aes-xts-plain64` — standard for disk encryption, XTS mode with 64-bit sector IV
- `aes-cbc-essiv:sha256` — older CBC mode with ESSIV to prevent watermarking

XTS is preferred because it handles sector-level encryption without inter-sector dependencies.

---

## 2. dm-verity: Integrity Verification

### Purpose

dm-verity provides read-only integrity checking using a pre-computed Merkle (hash) tree. It is used to verify that a block device has not been tampered with.

Use cases:
- Android verified boot
- ChromeOS rootfs verification
- Read-only system partition integrity

### Architecture

```text
┌────────────────────────────────────┐
│  dm-verity device                  │  ← verified reads
│    root hash: known-good hash      │
└──────────────┬─────────────────────┘
               |
               v
┌────────────────────────────────────┐
│  data device                       │  ← actual data blocks
│  hash device                       │  ← Merkle tree blocks
└────────────────────────────────────┘
```

### Merkle tree structure

```text
           root hash (known at boot)
              /        \
         hash[0]      hash[1]
         /    \       /    \
      h[0,0] h[0,1] h[1,0] h[1,1]    ← leaf hashes
        |      |      |      |
      blk0   blk1   blk2   blk3      ← data blocks
```

Each leaf hash covers one data block. Parent nodes hash their children. The root hash is the trust anchor.

### Bio handling in dm-verity

Source: `drivers/md/dm-verity-target.c`

```text
READ bio arrives at dm-verity device
    |
    v
verity_map(bio)
    |
    v
remap bio to data device
    -> DM_MAPIO_REMAPPED
    -> on completion (verity_end_io):
       for each data block in the bio:
         compute hash of data block
         walk Merkle tree up to root
         compare against expected hashes
         if mismatch → return I/O error
         if match → complete normally
```

Key details:
- Read-only target (writes are rejected)
- Hash tree is pre-computed offline
- Verification happens in completion path
- Failed verification returns `-EIO`
- Optional FEC (Forward Error Correction) for recovery

---

## 3. LUKS: The Userspace Layer for dm-crypt

LUKS provides:
- Standardized on-disk header format
- Key management (multiple key slots)
- Passphrase → key derivation (PBKDF2/Argon2)

```text
┌──────────────────────────┐
│  LUKS header             │  ← key slots, cipher config
│  (first ~2MB of device)  │
├──────────────────────────┤
│  encrypted data          │  ← dm-crypt maps this region
│  (rest of device)        │
└──────────────────────────┘
```

---

## 4. Hands-On Exercises

### Exercise 1: Create a LUKS volume

```bash
# Create a backing file
dd if=/dev/zero of=/tmp/crypt-backing bs=1M count=200

# Set up loop device
sudo losetup /dev/loop1 /tmp/crypt-backing

# Format as LUKS
sudo cryptsetup luksFormat /dev/loop1
# (type YES, enter passphrase)

# Open (maps to /dev/mapper/test-crypt)
sudo cryptsetup open /dev/loop1 test-crypt

# Verify DM mapping
sudo dmsetup table test-crypt
lsblk
```

### Exercise 2: Use the encrypted volume

```bash
# Create filesystem and mount
sudo mkfs.ext4 /dev/mapper/test-crypt
sudo mkdir -p /mnt/crypt-test
sudo mount /dev/mapper/test-crypt /mnt/crypt-test

# Write data
sudo dd if=/dev/urandom of=/mnt/crypt-test/testfile bs=1M count=10
md5sum /mnt/crypt-test/testfile
```

### Exercise 3: Measure encryption overhead

```bash
# Direct I/O benchmark on encrypted device
sudo fio --name=crypt-test --filename=/dev/mapper/test-crypt \
    --rw=randread --bs=4k --direct=1 --numjobs=1 \
    --runtime=10 --time_based --size=100M

# Compare with raw device
sudo fio --name=raw-test --filename=/dev/loop1 \
    --rw=randread --bs=4k --direct=1 --numjobs=1 \
    --runtime=10 --time_based --size=100M --offset=2M
```

### Exercise 4: Inspect LUKS header

```bash
sudo cryptsetup luksDump /dev/loop1
```

### Exercise 5: Cleanup

```bash
sudo umount /mnt/crypt-test
sudo cryptsetup close test-crypt
sudo losetup -d /dev/loop1
rm /tmp/crypt-backing
```

### Exercise 6: Source navigation

```bash
grep -rn "crypt_map\|crypt_endio\|crypt_convert" drivers/md/dm-crypt.c | head -20
grep -rn "verity_map\|verity_end_io\|verity_hash" drivers/md/dm-verity-target.c | head -20
```

---

## 5. Source Navigation Checklist

Primary:
- `drivers/md/dm-crypt.c` — crypt target, bio encrypt/decrypt
- `drivers/md/dm-verity-target.c` — verity target, hash verification
- `drivers/md/dm-verity.h` — verity data structures

Supporting:
- `include/linux/device-mapper.h` — target_type interface
- `crypto/` — kernel crypto API used by dm-crypt

---

## 6. dm-crypt vs dm-verity Comparison

| Aspect | dm-crypt | dm-verity |
|--------|----------|----------|
| Purpose | Confidentiality | Integrity |
| Direction | Read + Write | Read-only |
| Transform | Encrypt/decrypt per sector | Hash verify per block |
| Trust anchor | Encryption key | Root hash |
| Performance | CPU cost per I/O | Hash computation per read |
| Typical use | LUKS FDE, encrypted volumes | Verified boot, immutable rootfs |

---

## 7. Common Pitfalls

1. Performance impact underestimation
   - dm-crypt adds CPU overhead per I/O; AES-NI hardware acceleration is important
   - Without hardware crypto, high-throughput workloads see significant degradation

2. Key management errors
   - Lost LUKS passphrase/key = permanent data loss (by design)
   - Always back up LUKS headers

3. dm-verity is read-only
   - Cannot use dm-verity on writable volumes
   - Any modification to data or hash device breaks verification

4. IV mode matters
   - Using weak IV modes (e.g., plain CBC without ESSIV) can leak data patterns
   - Always prefer XTS or ESSIV modes

---

## 8. Self-Check Questions

1. At what point does dm-crypt encrypt data for a write bio?
2. At what point does dm-crypt decrypt data for a read bio?
3. What is the trust anchor for dm-verity?
4. Why is dm-verity read-only?
5. What happens if dm-verity detects a hash mismatch?

## 9. Self-Check Answers

1. Before submission to the underlying device — the bio data is encrypted, then the encrypted bio is submitted.
2. In the completion callback (`crypt_endio`) — after encrypted data is read from disk, it is decrypted before returning to the caller.
3. The root hash of the Merkle tree, which is known and trusted at setup time.
4. Because the hash tree is pre-computed. Any write would invalidate the hashes, making verification impossible without recomputing the entire tree.
5. The I/O returns an error (`-EIO`), indicating data corruption or tampering.

---

## 10. Tomorrow's Preview: Day 18 — md/RAID

Next we study the MD (Multiple Devices) subsystem:
- md personalities (RAID-0, 1, 5, 6, 10)
- `mdadm` for RAID creation and management
- Rebuild/resync and bitmap journaling concepts.
