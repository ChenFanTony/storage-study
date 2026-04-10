# Day 28: Inline Encryption (blk-crypto)

## Learning Objectives
- Understand Linux block-layer inline encryption architecture
- Learn how `blk-crypto` connects filesystem crypto to storage hardware
- Distinguish hardware inline encryption from software fallback
- Inspect kernel interfaces and practical capability checks

---

## 1. What Inline Encryption Means

Inline encryption means data encryption/decryption happens in or near the storage path (often controller hardware) rather than only in CPU software transforms.

In Linux, block-layer support is provided by `blk-crypto`.

High-level goals:
- reduce CPU overhead for encrypted I/O
- keep encryption integrated with normal block request flow
- provide consistent abstraction for filesystems like fscrypt users

---

## 2. Architecture Overview

Conceptual stack:

```text
Application
   -> Filesystem (e.g., fscrypt-managed file keys/policies)
      -> blk-crypto keyslot/programming abstraction
         -> block request with crypto context
            -> storage driver/hardware inline engine
               OR software fallback path
```

Key idea: filesystem provides encryption context; block layer carries it with requests; device path executes or fallback handles it.

---

## 3. Hardware vs Software Paths

### Hardware inline path
- device advertises supported algorithms/modes/key sizes/data units
- blk-crypto programs keyslots and tags I/O requests with crypto context
- encryption/decryption offloaded to hardware path

### Software fallback path
- used when hardware lacks required capability or configuration
- preserves correctness and compatibility
- may consume more CPU than hardware offload

---

## 4. Why This Matters for Performance

Benefits when hardware offload is available:
- lower per-I/O CPU cost
- better scalability in high-throughput encrypted workloads

But performance still depends on:
- request size and concurrency
- crypto mode and key setup behavior
- storage/controller implementation quality

Always measure on target hardware.

---

## 5. Core Kernel Areas

From study plan:
- `block/blk-crypto.c`
- `block/blk-crypto-profile.c`

Supporting areas often involved:
- filesystem crypto integration (e.g., fscrypt paths)
- storage driver capability advertisement and request handling

---

## 6. Practical Capability Inspection

What to check in a lab system:
- whether storage device/driver exposes inline crypto capabilities
- whether filesystem + policy configuration uses block encryption context
- fallback behavior when requested mode unsupported

Tooling can vary by distro/kernel/device. Focus first on kernel logs, sysfs, and source-level capability definitions.

---

## 7. Hands-On Exercises

### Exercise 1: Source walkthrough
```bash
grep -rn "blk_crypto" block/blk-crypto.c block/blk-crypto-profile.c | head -60
```

### Exercise 2: Explore related symbols
```bash
grep -rn "keyslot\|crypto profile\|fallback" block/ fs/ include/linux/ | head -80
```

### Exercise 3: Inspect block queue/sysfs for crypto-relevant cues
```bash
ls /sys/block
# then inspect target device queue directories for available attributes
ls /sys/block/<dev>/queue
```

### Exercise 4: Review kernel config for relevant options
```bash
# distro-dependent; examples
zcat /proc/config.gz | grep -Ei "BLK_CRYPTO|FS_ENCRYPTION|FSCRYPT" || true
```

### Exercise 5: Check dmesg for inline crypto/fallback hints
```bash
dmesg | grep -Ei "blk-crypto|inline crypto|fscrypt|keyslot|fallback"
```

### Exercise 6: Read fscrypt + blk layer relationship in source/docs
```bash
grep -rn "fscrypt\|inline encryption" Documentation fs block include/linux | head -80
```

---

## 8. Source Navigation Checklist

Primary:
- `block/blk-crypto.c`
- `block/blk-crypto-profile.c`

Supporting:
- `include/linux/blk-crypto.h`
- filesystem encryption integration paths (`fs/` with fscrypt references)

---

## 9. Common Pitfalls

1. Assuming inline encryption is always hardware-offloaded
   - software fallback may be active

2. Treating encrypted-I/O performance deltas as crypto-only effects
   - queueing, scheduler, and media behavior also matter

3. Ignoring mode/algorithm compatibility
   - unsupported combinations can force fallback

4. Benchmarking without confirming active path
   - always verify whether hardware or fallback path is used

---

## 10. Self-Check Questions

1. What is blk-crypto’s primary role?
2. What happens when hardware inline capability is insufficient?
3. Why can inline encryption improve performance on some systems?
4. Which two source files are core for today’s topic?
5. Why must you verify active path before performance conclusions?

## 11. Self-Check Answers

1. It provides block-layer abstraction for carrying and executing encryption context with I/O requests.
2. Linux can use a software fallback path to preserve correctness.
3. It can reduce CPU overhead by offloading crypto operations to storage/controller hardware.
4. `block/blk-crypto.c` and `block/blk-crypto-profile.c`.
5. Because hardware offload and software fallback have different overhead profiles.

---

## 12. Tomorrow’s Preview: Day 29 — Performance Tuning Lab

Next we integrate the full stack:
- scheduler, queue depth, readahead, mount options, cgroup controls
- define baseline and tuning loops
- demonstrate measurable improvement with evidence.
