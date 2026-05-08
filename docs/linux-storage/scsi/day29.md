# Day 29 — SCSI sense data generation

**Week 4**: Advanced Topics  
**Time**: 1–2 hours  
**Reference**: `drivers/scsi/scsi_common.c`, `drivers/target/target_core_transport.c`, `drivers/target/target_core_alua.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

When a SCSI command completes with CHECK CONDITION (status 0x02), sense data accompanies the
status to explain what went wrong. Sense is the structured error format defined in SPC-4 §4.5.
Both initiator and target use the same `scsi_build_sense()` helper to compose it. The mapping
from internal error reasons (`TCM_*` on target, sense_key on initiator) to the on-the-wire
sense bytes is one of those tables you reference frequently when reading logs or debugging.

---

## Sense format — fixed (response code 0x70/0x71)

```
Byte   Field                                         Notes
─────  ─────                                         ─────
 0     Response code (0x70 current, 0x71 deferred)
 1     Reserved (0x00)
 2     Sense Key (4 bits) + ILI/EOM/FILEMARK flags
       Sense keys (low 4 bits of byte 2):
         0x0 NO SENSE
         0x1 RECOVERED ERROR
         0x2 NOT READY
         0x3 MEDIUM ERROR
         0x4 HARDWARE ERROR
         0x5 ILLEGAL REQUEST
         0x6 UNIT ATTENTION
         0x7 DATA PROTECT
         0x9 VENDOR SPECIFIC
         0xA COPY ABORTED
         0xB ABORTED COMMAND
         0xD VOLUME OVERFLOW
         0xE MISCOMPARE
 3-6   Information (4 bytes — usually 0 except for medium errors with LBA)
 7     Additional Sense Length (typically 0x0a → total 18 bytes)
 8-11  Command-Specific Information
 12    ASC  — Additional Sense Code
 13    ASCQ — Additional Sense Code Qualifier
 14    Field Replaceable Unit Code
 15    SKSV (1 bit) + Sense-Key-Specific (3 bytes) — for ILLEGAL REQUEST,
       points to the bad CDB byte/bit
 16    SKS continued
 17    SKS continued
```

So a fixed-format response is typically 18 bytes total. `additional_sense_length = 10` means
"10 more bytes after byte 7" which gives 18 total.

---

## Sense format — descriptor (response code 0x72/0x73)

```
Byte   Field
─────  ─────
 0     Response code (0x72 current, 0x73 deferred)
 1     Sense Key (low 4 bits)
 2     ASC
 3     ASCQ
 4-6   Reserved
 7     Additional Sense Length (variable)
 8+    Sequence of sense data descriptors:
         each descriptor: type (1 byte) + length (1 byte) + payload
         types: 0x00 Information, 0x01 CSI, 0x02 Sense-Key-Specific,
                0x03 FRU, 0x04 Stream Commands, 0x05 Block Commands,
                0x06 OSD Object ID, 0x09 ATA Status, 0x0A Another Progress, ...
```

Descriptor format is more flexible — you can include only the descriptors that apply,
extending sense without bloat. Used for I/T-nexus loss reporting, ATA passthrough sense, and
other modern features.

---

## scsi_build_sense — `drivers/scsi/scsi_common.c`

The helper used by both initiator and target. Produces fixed-format by default:

```c
/* Simplified — see drivers/scsi/scsi_common.c. */
void scsi_build_sense(struct scsi_cmnd *scmd, int desc, u8 key, u8 asc, u8 ascq)
{
    struct scsi_sense_hdr sshdr = {
        .response_code  = desc ? 0x72 : 0x70,
        .sense_key      = key,
        .asc            = asc,
        .ascq           = ascq,
    };

    if (desc) {
        scsi_build_sense_descriptor(scmd, &sshdr);
    } else {
        scsi_build_sense_fixed(scmd, &sshdr);
    }
}

static void scsi_build_sense_fixed(struct scsi_cmnd *scmd,
                                     struct scsi_sense_hdr *sshdr)
{
    unsigned char *buf = scmd->sense_buffer;

    memset(buf, 0, SCSI_SENSE_BUFFERSIZE);

    buf[0] = sshdr->response_code;          /* 0x70 fixed-current */
    buf[2] = sshdr->sense_key;
    buf[7] = 0x0a;                          /* additional length = 10 */
    buf[12] = sshdr->asc;
    buf[13] = sshdr->ascq;

    scmd->sense_len = SCSI_SENSE_BUFFERSIZE;  /* will be capped to actual */
}
```

`SCSI_SENSE_BUFFERSIZE` = 96 bytes in modern kernels (up from 32 historically). The actual sense
length is in the buffer itself (`buf[7]+8` for fixed) or in `scmd->sense_len`.

---

## TCM_* sense reason → ASC/ASCQ table — `drivers/target/target_core_transport.c`

LIO uses a table to map internal error reasons to wire sense:

```c
/* Simplified — see drivers/target/target_core_transport.c. */
static const struct sense_info sense_info_table[] = {
    [TCM_NO_SENSE] = {
        .key = NOT_READY,
    },
    [TCM_NON_EXISTENT_LUN] = {
        .key = ILLEGAL_REQUEST,
        .asc = 0x25,                /* LOGICAL UNIT NOT SUPPORTED */
    },
    [TCM_UNSUPPORTED_SCSI_OPCODE] = {
        .key = ILLEGAL_REQUEST,
        .asc = 0x20,                /* INVALID COMMAND OPERATION CODE */
    },
    [TCM_INVALID_CDB_FIELD] = {
        .key = ILLEGAL_REQUEST,
        .asc = 0x24,                /* INVALID FIELD IN CDB */
    },
    [TCM_INVALID_PARAMETER_LIST] = {
        .key = ILLEGAL_REQUEST,
        .asc = 0x26,                /* INVALID FIELD IN PARAMETER LIST */
    },
    [TCM_LBA_OUT_OF_RANGE] = {
        .key = ILLEGAL_REQUEST,
        .asc = 0x21,                /* LBA OUT OF RANGE */
    },
    [TCM_LOGICAL_UNIT_COMMUNICATION_FAILURE] = {
        .key = HARDWARE_ERROR,
        .asc = 0x08,                /* LOGICAL UNIT COMMUNICATION FAILURE */
    },
    [TCM_SERVICE_CRC_ERROR] = {
        .key = ABORTED_COMMAND,
        .asc = 0x47,                /* SCSI PARITY ERROR */
        .ascq = 0x05,
    },
    [TCM_CHECK_CONDITION_NOT_READY] = {
        .key = NOT_READY,
    },
    [TCM_RESERVATION_CONFLICT] = {
        /*
         * RESERVATION CONFLICT is a status (0x18), not a sense.
         * No CHECK CONDITION, no sense data — the status byte alone
         * conveys it. SAM-5 permits sense to be attached but LIO does
         * not, and most targets follow this convention.
         */
        .key = 0,
    },
    [TCM_ALUA_TG_PT_STANDBY] = {
        .key = NOT_READY,
        .asc = 0x04,                /* LOGICAL UNIT NOT ACCESSIBLE */
        .ascq = 0x0b,               /* TARGET PORT IN STANDBY STATE */
    },
    [TCM_ALUA_TG_PT_UNAVAILABLE] = {
        .key = NOT_READY,
        .asc = 0x04,
        .ascq = 0x0c,               /* TARGET PORT IN UNAVAILABLE STATE */
    },
    [TCM_ALUA_STATE_TRANSITION] = {
        .key = NOT_READY,
        .asc = 0x04,
        .ascq = 0x0a,               /* ASYMMETRIC ACCESS STATE TRANSITION */
    },
    [TCM_ALUA_OFFLINE] = {
        .key = NOT_READY,
        .asc = 0x04,
        .ascq = 0x12,               /* LOGICAL UNIT NOT ACCESSIBLE / OFFLINE */
    },
    /* ... many more entries ... */
};
```

The mapping is consulted in `transport_send_check_condition_and_sense()` (day 17):

```c
sense_reason_t reason = cmd->scsi_sense_reason;
const struct sense_info *info = &sense_info_table[reason];

if (info->key) {
    scsi_build_sense(scmd, /* desc = */ 0,
                       info->key, info->asc, info->ascq);
}
/* if info->key == 0 (e.g. RESERVATION_CONFLICT): no sense built */
```

---

## Common ASC/ASCQ codes

| ASC | ASCQ | Meaning | Disposition |
|---|---|---|---|
| 0x00 | 0x00 | NO ADDITIONAL SENSE INFORMATION | (none) |
| 0x04 | 0x01 | LU NOT READY, BECOMING READY | retry |
| 0x04 | 0x02 | LU NOT READY, INITIALIZING COMMAND REQUIRED | retry |
| 0x04 | 0x0A | ASYMMETRIC ACCESS STATE TRANSITION | retry (ALUA) |
| 0x04 | 0x0B | TARGET PORT IN STANDBY STATE | retry (ALUA) |
| 0x04 | 0x0C | TARGET PORT IN UNAVAILABLE STATE | retry (ALUA) |
| 0x04 | 0x12 | LOGICAL UNIT NOT ACCESSIBLE / OFFLINE | permanent |
| 0x08 | 0x00 | LOGICAL UNIT COMMUNICATION FAILURE | retry/EH |
| 0x11 | 0x00 | UNRECOVERED READ ERROR | permanent (medium) |
| 0x1A | 0x00 | PARAMETER LIST LENGTH ERROR | permanent |
| 0x20 | 0x00 | INVALID COMMAND OPERATION CODE | permanent |
| 0x21 | 0x00 | LBA OUT OF RANGE | permanent |
| 0x24 | 0x00 | INVALID FIELD IN CDB | permanent |
| 0x25 | 0x00 | LOGICAL UNIT NOT SUPPORTED | permanent |
| 0x26 | 0x00 | INVALID FIELD IN PARAMETER LIST | permanent |
| 0x29 | 0x00 | POWER ON, RESET, OR BUS DEVICE RESET | UA — retry once |
| 0x2A | 0x03 | RESERVATIONS PREEMPTED | UA — retry once |
| 0x2A | 0x06 | ASYMMETRIC ACCESS STATE CHANGED | UA — retry once |
| 0x2A | 0x09 | CAPACITY DATA HAS CHANGED | UA — retry once |
| 0x47 | 0x05 | SCSI PARITY ERROR | retry/EH |

| Status byte | Meaning | Sense? |
|---|---|---|
| 0x00 GOOD | normal | no |
| 0x02 CHECK CONDITION | error reported via sense | yes |
| 0x08 BUSY | temporarily unavailable | no |
| 0x18 RESERVATION CONFLICT | another initiator holds | not from LIO (SAM-5 permits but rare in practice) |
| 0x28 TASK SET FULL | queue depth exceeded | no |
| 0x40 TASK ABORTED | aborted by TMF (TAS bit set elsewhere) | no |

---

## Unit Attention queueing — `drivers/target/target_core_ua.c`

Unit Attention is a sticky condition — sense returned on the *next* command from this initiator,
regardless of the command itself:

```c
/* Simplified — see drivers/target/target_core_ua.c. */
int core_scsi3_ua_allocate(struct se_node_acl *nacl, u32 unpacked_lun,
                            u8 asc, u8 ascq)
{
    struct se_dev_entry *deve;
    struct se_ua *ua, *ua_p;

    rcu_read_lock();
    deve = target_nacl_find_deve(nacl, unpacked_lun);
    if (!deve) {
        rcu_read_unlock();
        return -EINVAL;
    }

    ua = kmem_cache_zalloc(se_ua_cache, GFP_ATOMIC);
    if (!ua) {
        rcu_read_unlock();
        return -ENOMEM;
    }

    ua->ua_asc  = asc;
    ua->ua_ascq = ascq;

    spin_lock(&deve->ua_lock);
    list_add_tail(&ua->ua_nacl_list, &deve->ua_list);
    atomic_inc(&deve->ua_count);
    spin_unlock(&deve->ua_lock);

    rcu_read_unlock();
    return 0;
}
```

Use cases for UA:
- Reservations preempted (PR PREEMPT day 20): queue 06h/2Ah/03h on each preempted initiator's
  nacl.
- ALUA state changed (day 23): queue 06h/2Ah/06h on every initiator using the affected group.
- LUN reset (day 22): queue 06h/29h/00h on every initiator nexus to the LUN.
- Capacity changed: queue 06h/2Ah/09h on every initiator.

When the next command from that initiator hits `target_setup_cmd_from_cdb()`, the UA is
delivered via CHECK CONDITION before any other check. Initiator's `scsi_check_sense()` (day 5)
sees UNIT_ATTENTION → NEEDS_RETRY → blk-mq retries once.

---

## Sense in iSCSI Response PDU

The data segment of the SCSI Response PDU carries sense:

```
PDU layout:
  [BHS — 48 bytes, opcode=0x21]
  [optional AHS]
  [optional HeaderDigest 4 bytes]
  [data segment]
    [2-byte sense length, big-endian]
    [sense data — typically 18 bytes for fixed format]
    [pad to 4-byte boundary]
  [optional DataDigest 4 bytes]
```

`DataSegmentLength` in the BHS is `sense_len + 2` (the 2 bytes of the length field plus the
sense itself). PDU length is rounded up to 4-byte boundary as required by RFC 7143 §10.2.

---

## Initiator parsing — `scsi_normalize_sense`

When the initiator's `iscsi_scsi_cmd_rsp()` (day 11) copies sense to `scmd->sense_buffer`, the
SCSI mid-layer's `scsi_normalize_sense()` parses it back into a structured form:

```c
/* Simplified — see drivers/scsi/scsi_common.c. */
bool scsi_normalize_sense(const u8 *sense_buffer, int sb_len,
                            struct scsi_sense_hdr *sshdr)
{
    memset(sshdr, 0, sizeof(*sshdr));

    if (!sense_buffer || !sb_len)
        return false;

    sshdr->response_code = (sense_buffer[0] & 0x7f);

    if (!scsi_sense_valid(sshdr))
        return false;

    if (sshdr->response_code >= 0x72) {
        /* descriptor format */
        if (sb_len > 1)
            sshdr->sense_key = sense_buffer[1] & 0xf;
        if (sb_len > 2)
            sshdr->asc       = sense_buffer[2];
        if (sb_len > 3)
            sshdr->ascq      = sense_buffer[3];
        if (sb_len > 7)
            sshdr->additional_length = sense_buffer[7];
    } else {
        /* fixed format */
        if (sb_len > 2)
            sshdr->sense_key = sense_buffer[2] & 0xf;
        if (sb_len > 12)
            sshdr->asc       = sense_buffer[12];
        if (sb_len > 13)
            sshdr->ascq      = sense_buffer[13];
        if (sb_len > 7)
            sshdr->additional_length = sense_buffer[7];
    }

    return true;
}
```

This is what `scsi_check_sense()` (day 5) calls to extract sense_key/asc/ascq for disposition
decisions.

---

## Worked example: PR PREEMPT preempts node A

```
Time   Surviving node B                     Target                            Fenced node A
─────  ──────────────────                  ──────                            ──────────────
T0     PR PREEMPT (sa=0x04, key=A)
       SCSI: opcode=0x5F
       parameter list: A's key
       ─────────────────→
T1                                          core_scsi3_emulate_pro_preempt
T2                                          remove A's t10_pr_registration
T3                                          core_scsi3_ua_allocate(A's nacl,
                                              ASC=0x2A, ASCQ=0x03)
T4                                          dev_pr_res_holder = B's reg
T5                                          generation++
T6                                          ←─────────── status GOOD ─────
T7     PR PREEMPT returns 0
T8                                                                          new I/O attempt:
                                                                            WRITE(10) sent
T9                                          target_setup_cmd_from_cdb
T10                                         deve->ua_list non-empty
T11                                         build CHECK CONDITION sense:
                                              key=06h UNIT ATTENTION
                                              ASC=2Ah, ASCQ=03h
                                              (RESERVATIONS PREEMPTED)
T12                                         ──── status 0x02 + sense ────→
T13                                                                          scsi_check_sense:
                                                                            UNIT_ATTENTION
                                                                            → NEEDS_RETRY
T14                                                                          (UA consumed,
                                                                            blk-mq retries)
T15                                                                          retry: WRITE(10)
T16                                         target_check_reservation
T17                                         A is no longer registered
T18                                         build status 0x18
                                              RESERVATION CONFLICT
                                              (no sense)
T19                                         ─── status 0x18 ────────────→
T20                                                                          scmd->result =
                                                                            DID_OK | 0x18
                                                                            BLK_STS_RESV_CONFLICT
                                                                            blk_path_error=false
                                                                            application: -EIO
```

The UA at T13 is the "you've been preempted, please notice" signal. The conflict at T20 is the
ongoing fence — every subsequent I/O returns it.

---

## Key takeaways

- Sense data uses fixed (response code 0x70/0x71) or descriptor (0x72/0x73) format.
  `scsi_build_sense()` in `drivers/scsi/scsi_common.c` is shared between initiator and target.
- Fixed format is typically 18 bytes; `additional_sense_length = 0x0a` indicates 10 more
  bytes after byte 7.
- Target's `sense_info_table` (in `target_core_transport.c`) maps `TCM_*` reason codes to
  sense_key/ASC/ASCQ.
- `RESERVATION CONFLICT` (0x18) does not get sense data attached by LIO; SAM-5 permits sense
  on any status but in practice LIO and most targets convey the meaning via the status byte
  alone.
- ALUA states map to NOT_READY (0x02) with ASC=0x04 and various ASCQ values (0x0a/0x0b/0x0c
  for transition/standby/unavailable, 0x12 for offline).
- Unit Attention is sticky — queued via `core_scsi3_ua_allocate()` per nexus, delivered on the
  next command. Common UAs: 0x29/0x00 (reset), 0x2A/0x03 (PR preempted), 0x2A/0x06 (ALUA
  state change).
- iSCSI Response PDU carries sense in the data segment: 2-byte length + sense + 4-byte pad.
- `scsi_normalize_sense()` parses raw bytes back into `scsi_sense_hdr` for the initiator's
  disposition logic.

---

## Note on sensitive content

Sense codes are the diagnostic vocabulary for SCSI errors; understanding them is essential for
debugging storage failures.

---

## Previous / Next

[Day 28 — ERL1 and ERL2 error recovery](day28.md) | [Day 30 — Cold re-read self test](day30.md)
