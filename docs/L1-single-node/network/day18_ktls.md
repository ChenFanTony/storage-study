# Day 18 — TLS in the Kernel: kTLS and NIC TLS Offload
> **Time:** 1–2 hours | **Track:** Linux Networking (Week 3)

---

## 🎯 Goal
Understand how the kernel supports TLS natively via kTLS, how it integrates with the socket and sendfile paths, and how NIC hardware can further offload TLS crypto.

---

## 1. The Traditional TLS Problem

Without kTLS, TLS runs entirely in userspace (OpenSSL, etc.):

```
Application
  └── SSL_write(ssl, data, len)
        └── TLS encrypt (userspace AES, HMAC)
              └── send(fd, ciphertext, ...)
                    └── copy_from_user → sk_buff → NIC
```

**Problems:**
- `sendfile()` can't be used — file data must pass through userspace for encryption
- Each `SSL_write` → `send()` → context switch overhead
- TLS record framing happens in userspace, separate from TCP segmentation

---

## 2. kTLS — Kernel TLS

**Source:** `net/tls/`, `include/net/tls.h`

kTLS moves TLS record layer crypto into the kernel, enabling:
- `sendfile()` with TLS (file data encrypted in-kernel, no userspace copy)
- Zero-copy TLS with `MSG_ZEROCOPY`
- NIC hardware crypto offload

### kTLS architecture
```
Application: SSL_write(ssl, data, len)
  └── OpenSSL detects kTLS mode
        └── send(fd, data, len, 0)   ← plain data, no userspace encrypt!
              └── kernel TLS ULP intercepts
                    └── tls_sw_sendmsg()   (software kTLS)
                          ├── encrypt data (kernel AES-GCM)
                          ├── prepend TLS record header
                          └── tcp_sendmsg() → NIC
```

### ULP — Upper Layer Protocol
```c
/* kTLS registers as a ULP that wraps the TCP socket */
/* net/tls/tls_main.c */
static struct proto tls_prots[TLS_NUM_PROT][TLS_NUM_CONFIG] = {
    [TLS_BASE][TLS_SW] = {
        .sendmsg    = tls_sw_sendmsg,
        .recvmsg    = tls_sw_recvmsg,
        .close      = tls_sk_proto_close,
        /* ... */
    },
};

/* Installing kTLS on a socket: */
setsockopt(fd, SOL_TCP, TCP_ULP, "tls", sizeof("tls"));
/* Then configure keys: */
setsockopt(fd, SOL_TLS, TLS_TX, &crypto_info, sizeof(crypto_info));
setsockopt(fd, SOL_TLS, TLS_RX, &crypto_info, sizeof(crypto_info));
```

---

## 3. kTLS Send Path: `tls_sw_sendmsg()`

**Source:** `net/tls/tls_sw.c`

```c
int tls_sw_sendmsg(struct sock *sk, struct msghdr *msg, size_t size)
{
    struct tls_context *tls_ctx = tls_get_ctx(sk);
    struct tls_sw_context_tx *ctx = tls_sw_ctx_tx(tls_ctx);
    struct aead_request *aead_req;

    /* Allocate plaintext sk_buff */
    skb = tls_alloc_clrtxt_skb(sk, size, sk->sk_allocation);

    /* Copy plaintext from userspace */
    skb_copy_to_page_nocache(sk, &msg->msg_iter, skb, ...);

    /* Encrypt in-place using kernel AEAD (AES-GCM) */
    aead_req = aead_request_alloc(ctx->aead_send, sk->sk_allocation);
    aead_request_set_crypt(aead_req, sg, sg, plaintext_len, iv);
    crypto_aead_encrypt(aead_req);   /* → kernel crypto subsystem */

    /* Prepend TLS record header (5 bytes) */
    /* type(1) | version(2) | length(2) */
    tls_push_record(sk, flags, record_type);

    /* Hand encrypted data to TCP */
    return tls_push_sg(sk, tls_ctx, ...);
}
```

### TLS record structure (inside TCP stream)
```
[type:1][version:2][length:2][encrypted_payload][auth_tag:16]
  ↑ content type: application(23), handshake(22), alert(21)
```

---

## 4. kTLS + sendfile: The Key Win

**Source:** `net/tls/tls_sw.c` (`tls_sw_sendfile`)

```c
/* Application: */
sendfile(sockfd, filefd, &offset, count);
  └── kernel intercepts via ULP splice hook
        └── tls_sw_sendfile()
              ├── splice file pages into TLS plaintext buffer (no copy)
              ├── encrypt in-place using kernel AEAD
              └── push TLS records to TCP

/* Result: file data → kernel encrypt → NIC DMA */
/* Userspace never touches the data! */
```

This is why `nginx` with kTLS can serve HTTPS static files with zero userspace copies.

---

## 5. NIC TLS Offload (TLS_HW)

**Source:** `net/tls/tls_device.c`

Some NICs (Mellanox ConnectX-5+, Intel E810) support TLS offload — the NIC does AES-GCM:

```
CPU: plaintext → TCP stack → NIC TX ring
NIC HW: encrypt → wire
```

```c
/* net/tls/tls_device.c */
/* If NIC supports TLS offload: */
static const struct tlsdev_ops *ops = dev->tlsdev_ops;
if (ops && ops->tls_dev_add) {
    /* Push TLS keys to NIC firmware */
    rc = ops->tls_dev_add(netdev, sk, TLS_OFFLOAD_CTX_DIR_TX,
                          &tls_ctx->crypto_send, start_offload_tcp_sn);
    /* From now: TCP segments automatically encrypted by NIC */
}
```

### Three kTLS modes
```
TLS_SW:    kernel software crypto (AES-NI on x86)
TLS_HW:    NIC hardware crypto offload
TLS_HW_RECORD: NIC does full TLS record layer (rare, requires special NIC)
```

---

## 6. kTLS Receive Path

**Source:** `net/tls/tls_sw.c` (`tls_sw_recvmsg`)

```c
int tls_sw_recvmsg(struct sock *sk, struct msghdr *msg, size_t len, ...)
{
    /* Pull TLS records from sk_receive_queue */
    skb = tls_wait_data(sk, psock, flags, timeo, &err);

    /* Decrypt the record */
    err = decrypt_skb_update(sk, skb, &dest, &chunk, &zc, &async);
    /* → crypto_aead_decrypt() using stored session keys */

    /* Verify authentication tag (GCM authentication) */
    /* If auth fails: return -EBADMSG */

    /* Copy plaintext to userspace */
    skb_copy_datagram_msg(skb, rxm->offset, msg, chunk);
}
```

### kTLS RX with NIC offload
```c
/* NIC decrypts incoming TLS records in hardware */
/* Kernel receives plaintext sk_buff with special metadata */
/* Much simpler kernel path: just copy plaintext to userspace */
```

---

## 7. The Kernel Crypto Subsystem

**Source:** `crypto/`, `include/crypto/`

kTLS uses the kernel's crypto API:

```c
/* Allocating an AEAD cipher (AES-128-GCM) */
struct crypto_aead *aead = crypto_alloc_aead("gcm(aes)", 0, 0);

/* Setting the key */
crypto_aead_setkey(aead, key, keylen);
crypto_aead_setauthsize(aead, TLS_TAG_SIZE);  // 16 bytes

/* Encrypt/decrypt */
struct aead_request *req = aead_request_alloc(aead, GFP_KERNEL);
aead_request_set_crypt(req, src_sg, dst_sg, data_len, iv);
crypto_aead_encrypt(req);   // uses AES-NI hardware instruction if available
```

```bash
# See available crypto algorithms
cat /proc/crypto | grep -A5 "name.*gcm"

# Check if AES-NI is available
grep aes /proc/cpuinfo | head -1
```

---

## 8. Hands-On

### 8a. Check kTLS support
```bash
# Kernel config
grep TLS /boot/config-$(uname -r) 2>/dev/null | grep -v "^#"
# Look for: CONFIG_TLS=y or CONFIG_TLS=m

# Load TLS module if needed
modprobe tls 2>/dev/null
lsmod | grep tls
```

### 8b. Explore kTLS source
```bash
ls ~/linux/net/tls/
# tls_main.c, tls_sw.c, tls_device.c, tls_device_fallback.c

grep -n "tls_sw_sendmsg\|tls_sw_recvmsg\|TCP_ULP" \
    ~/linux/net/tls/tls_sw.c | head -15

grep -n "TCP_ULP\|tls_init" ~/linux/net/tls/tls_main.c | head -10
```

### 8c. Check kernel crypto
```bash
# Available algorithms
cat /proc/crypto | grep -E "^name|^driver" | paste - - | head -20

# AES-NI performance
openssl speed -evp aes-128-gcm 2>/dev/null | tail -5
```

### 8d. nginx kTLS (if nginx installed)
```bash
nginx -v 2>&1 | grep version
# nginx with OpenSSL 3.x supports kTLS automatically
# Check: strace -e trace=setsockopt nginx 2>&1 | grep -i tls
```

---

## 9. Concept Check

1. What is the ULP (Upper Layer Protocol) mechanism in the kernel? How does it intercept `sendmsg()` calls for a TCP socket?
2. How does kTLS enable `sendfile()` with TLS encryption? Why is this impossible with userspace TLS libraries?
3. What are the three kTLS modes? What is offloaded in each?
4. Why must the kernel verify the GCM authentication tag on receive, and what error is returned if verification fails?

---

## 📚 References
- `net/tls/tls_main.c` — ULP registration, socket setup
- `net/tls/tls_sw.c` — software crypto path
- `net/tls/tls_device.c` — NIC offload
- `include/net/tls.h` — data structures
- `crypto/` — kernel crypto API
- Kernel docs: `Documentation/networking/tls.rst`, `Documentation/networking/tls-offload.rst`
