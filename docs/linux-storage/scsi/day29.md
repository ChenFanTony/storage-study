# Day 29 — SCSI sense data generation

**Week 4**: Deep Cuts — TMF, ALUA, configfs, NVMe-oF, Sense Data
**Time**: 1–2 hours
**Reference**: `drivers/target/target_core_transport.c`, `include/target/target_core_base.h`, `drivers/scsi/scsi_lib.c`

---

## Overview

Sense data is the SCSI mechanism by which a target communicates detailed error information back
to an initiator. Every `CHECK CONDITION` response carries sense data. Understanding how sense
data is constructed on the target side and parsed on the initiator side closes the loop between
`TCM_*` reason codes (target) and the `NOT READY`, `ILLEGAL REQUEST`, `RESERVATION CONFLICT`
decisions in `scsi_decide_disposition()` (day 5). This day also covers the exact wire format so
you can read a Wireshark capture and know exactly what every byte means.

---

## SCSI sense data format — Fixed Format (most common)

```
Byte  0: Response Code (0x70 = current error, fixed format)
          0x71 = deferred error, fixed format
          0x72 = current error, descriptor format
          0x73 = deferred error, descriptor format
Byte  1: VALID bit (bit 7) + Obsolete (bits 6:0)
Byte  2: Sense Key (bits 3:0)
          0x0 = NO SENSE
          0x1 = RECOVERED ERROR
          0x2 = NOT READY
          0x3 = MEDIUM ERROR
          0x4 = HARDWARE ERROR
          0x5 = ILLEGAL REQUEST
          0x6 = UNIT ATTENTION
          0x7 = DATA PROTECT
          0x8 = BLANK CHECK
          0xb = ABORTED COMMAND
          0xe = MISCOMPARE
Bytes 3-6: Information (LBA of failed block for medium errors)
Byte  7: Additional Sense Length (N-7, where N = total sense length)
Bytes 8-11: Command-Specific Information
Byte 12: Additional Sense Code (ASC)
Byte 13: Additional Sense Code Qualifier (ASCQ)
Bytes 14-N: Additional sense bytes (FRU code, field pointers, etc.)

Minimum useful sense data: 18 bytes (response code + sense key + ASC + ASCQ)
SCSI_SENSE_BUFFERSIZE = 96 bytes (enough for any standard response)
```

---

## TCM_* sense reason codes — `include/target/target_core_base.h`

```c
/*
 * TCM sense reason codes — internal to target_core.
 * Mapped to SCSI sense key/ASC/ASCQ by transport_generic_request_failure().
 */
typedef unsigned int sense_reason_t;

#define TCM_NO_SENSE                          0x00
#define TCM_NON_EXISTENT_LUN                  0x01
/* → ILLEGAL REQUEST, ASC=0x25, ASCQ=0x00 (LU NOT SUPPORTED) */

#define TCM_UNSUPPORTED_SCSI_OPCODE           0x02
/* → ILLEGAL REQUEST, ASC=0x20, ASCQ=0x00 (INVALID COMMAND OPERATION CODE) */

#define TCM_SECTOR_COUNT_TOO_MANY             0x03
/* → ILLEGAL REQUEST, ASC=0x24, ASCQ=0x00 (INVALID FIELD IN CDB) */

#define TCM_LOGICAL_BLOCK_ADDRESS_OUT_OF_RANGE 0x04
/* → ILLEGAL REQUEST, ASC=0x21, ASCQ=0x00 (LBA OUT OF RANGE) */

#define TCM_INCORRECT_AMOUNT_OF_DATA          0x05
/* → ABORTED COMMAND, ASC=0x0c, ASCQ=0x0d (INCOMPLETE DATA RECEIVED) */

#define TCM_UNEXPECTED_UNSOLICITED_DATA       0x06
/* → ABORTED COMMAND, ASC=0x0c, ASCQ=0x0c (WRITE ERROR) */

#define TCM_SERVICE_CRC_ERROR                 0x07
/* → ABORTED COMMAND, ASC=0x47, ASCQ=0x00 (DATA PHASE ERROR) */

#define TCM_SNACK_REJECTED                    0x08
/* → ABORTED COMMAND, ASC=0x11, ASCQ=0x00 (UNRECOVERED READ ERROR) */

#define TCM_WRITE_PROTECTED                   0x09
/* → DATA PROTECT, ASC=0x27, ASCQ=0x00 (WRITE PROTECTED) */

#define TCM_CHECK_CONDITION_ABORT_CMD         0x0a
/* → ABORTED COMMAND, no specific ASC */

#define TCM_CHECK_CONDITION_UNIT_ATTENTION    0x0b
/* → UNIT ATTENTION, ASC and ASCQ set by UA allocator */

#define TCM_CHECK_CONDITION_NOT_READY         0x0c
/* → NOT READY, ASC=0x04, ASCQ=0x01 (BECOMING READY) */

#define TCM_LOGICAL_UNIT_COMMUNICATION_FAILURE 0x0d
/* → HARDWARE ERROR, ASC=0x08, ASCQ=0x00 (LU COMMUNICATION FAILURE) */

#define TCM_UNKNOWN_MODE_PAGE                 0x0e
/* → ILLEGAL REQUEST, ASC=0x24, ASCQ=0x00 */

#define TCM_RESERVATION_CONFLICT              0x1c
/*
 * RESERVATION CONFLICT is NOT a CHECK CONDITION.
 * Status byte = 0x18. No sense data. No sense key.
 * transport_generic_request_failure() does NOT write sense buffer.
 * The iSCSI Response PDU DataSegmentLength = 0.
 */

#define TCM_INVALID_CDB_FIELD                 0x1e
/* → ILLEGAL REQUEST, ASC=0x24, ASCQ=0x00 (INVALID FIELD IN CDB) */

#define TCM_INVALID_PARAMETER_LIST            0x1f
/* → ILLEGAL REQUEST, ASC=0x26, ASCQ=0x00 (INVALID FIELD IN PARAMETER LIST) */

#define TCM_PARAMETER_LIST_LENGTH_ERROR       0x20
/* → ILLEGAL REQUEST, ASC=0x1a, ASCQ=0x00 (PARAMETER LIST LENGTH ERROR) */

#define TCM_ALUA_TG_PT_STANDBY                0x21
/* → NOT READY, ASC=0x04, ASCQ=0x0B (TARGET PORT IN STANDBY STATE) */

#define TCM_ALUA_TG_PT_UNAVAILABLE            0x22
/* → NOT READY, ASC=0x04, ASCQ=0x0C (TARGET PORT IN UNAVAILABLE STATE) */

#define TCM_MISCOMPARE_VERIFY                 0x23
/* → MISCOMPARE, ASC=0x1d, ASCQ=0x00 (MISCOMPARE DURING VERIFY) */
```

---

## transport_generic_request_failure — sense construction

```c
void transport_generic_request_failure(struct se_cmd *cmd,
                                        sense_reason_t reason)
{
    int ret = 0;

    pr_debug("transport_generic_request_failure: se_cmd=%p, reason=%d\n",
             cmd, reason);

    /*
     * Build sense data based on reason code.
     * scsi_build_sense() writes the 18-byte fixed-format sense buffer.
     */
    switch (reason) {
    case TCM_NON_EXISTENT_LUN:
        scsi_build_sense_hdr(cmd->sense_buffer, &hdr);
        /* ILLEGAL REQUEST / LU NOT SUPPORTED */
        hdr.sense_key = ILLEGAL_REQUEST;
        hdr.asc       = 0x25;
        hdr.ascq      = 0x00;
        scsi_build_sense(cmd->sense_buffer, 0,
                         ILLEGAL_REQUEST, 0x25, 0x00);
        break;

    case TCM_UNSUPPORTED_SCSI_OPCODE:
        /* ILLEGAL REQUEST / INVALID COMMAND OPERATION CODE */
        scsi_build_sense(cmd->sense_buffer, 0,
                         ILLEGAL_REQUEST, 0x20, 0x00);
        break;

    case TCM_LOGICAL_BLOCK_ADDRESS_OUT_OF_RANGE:
        /* ILLEGAL REQUEST / LBA OUT OF RANGE */
        scsi_build_sense(cmd->sense_buffer, 0,
                         ILLEGAL_REQUEST, 0x21, 0x00);
        break;

    case TCM_WRITE_PROTECTED:
        /* DATA PROTECT / WRITE PROTECTED */
        scsi_build_sense(cmd->sense_buffer, 0,
                         DATA_PROTECT, 0x27, 0x00);
        break;

    case TCM_CHECK_CONDITION_UNIT_ATTENTION:
        /* sense data already set by core_scsi3_ua_allocate() */
        break;

    case TCM_CHECK_CONDITION_NOT_READY:
        /* NOT READY / LOGICAL UNIT IS IN PROCESS OF BECOMING READY */
        scsi_build_sense(cmd->sense_buffer, 0,
                         NOT_READY, 0x04, 0x01);
        break;

    case TCM_LOGICAL_UNIT_COMMUNICATION_FAILURE:
        /* HARDWARE ERROR / LU COMMUNICATION FAILURE */
        scsi_build_sense(cmd->sense_buffer, 0,
                         HARDWARE_ERROR, 0x08, 0x00);
        break;

    case TCM_ALUA_TG_PT_STANDBY:
        /* NOT READY / TARGET PORT IN STANDBY STATE */
        scsi_build_sense(cmd->sense_buffer, 0,
                         NOT_READY, 0x04, 0x0B);
        break;

    case TCM_ALUA_TG_PT_UNAVAILABLE:
        /* NOT READY / TARGET PORT IN UNAVAILABLE STATE */
        scsi_build_sense(cmd->sense_buffer, 0,
                         NOT_READY, 0x04, 0x0C);
        break;

    case TCM_RESERVATION_CONFLICT:
        /*
         * RESERVATION CONFLICT: status=0x18, NO SENSE DATA.
         * Set scsi_status directly — no sense buffer construction.
         * DataSegmentLength in the Response PDU will be 0.
         */
        cmd->scsi_status     = SAM_STAT_RESERVATION_CONFLICT;
        cmd->scsi_sense_reason = TCM_RESERVATION_CONFLICT;
        goto queue_full_retry;

    default:
        pr_err("Unknown sense reason: %d, using ABORTED COMMAND\n", reason);
        scsi_build_sense(cmd->sense_buffer, 0,
                         ABORTED_COMMAND, 0x00, 0x00);
        break;
    }

    cmd->scsi_status     = SAM_STAT_CHECK_CONDITION;
    cmd->scsi_sense_length = SCSI_SENSE_BUFFERSIZE;

queue_full_retry:
    target_complete_cmd(cmd, cmd->scsi_status);
}
EXPORT_SYMBOL(transport_generic_request_failure);
```

---

## scsi_build_sense — `drivers/scsi/scsi_lib.c`

```c
/*
 * Build an 18-byte fixed-format sense buffer.
 * Used by both initiator (scsi_build_sense in scsi_lib.c) and
 * target (same function, shared via include/scsi/scsi_eh.h).
 */
void scsi_build_sense(unsigned char *buf, int desc,
                       u8 key, u8 asc, u8 ascq)
{
    memset(buf, 0, SCSI_SENSE_BUFFERSIZE);

    if (desc) {
        /* descriptor format (0x72) */
        buf[0] = 0x72;
        buf[1] = key;
        buf[2] = asc;
        buf[3] = ascq;
        buf[7] = 0;      /* additional sense length = 0 (no descriptors) */
    } else {
        /* fixed format (0x70) — most common */
        buf[0] = 0x70;   /* response code: current error, fixed format */
        buf[2] = key;    /* sense key */
        buf[7] = 0x0a;   /* additional sense length = 10 (total=18) */
        buf[12] = asc;   /* additional sense code */
        buf[13] = ascq;  /* additional sense code qualifier */
    }
}
EXPORT_SYMBOL(scsi_build_sense);
```

The 18-byte fixed-format layout:
```
buf[0]  = 0x70  (response code: current error, fixed format)
buf[1]  = 0x00  (obsolete)
buf[2]  = key   (sense key: NOT_READY=0x02, ILLEGAL_REQUEST=0x05, etc.)
buf[3]  = 0x00  (information MSB — not used for most errors)
buf[4]  = 0x00  (information)
buf[5]  = 0x00  (information)
buf[6]  = 0x00  (information LSB)
buf[7]  = 0x0a  (additional sense length: 10 more bytes follow = total 18)
buf[8]  = 0x00  (command-specific info)
buf[9]  = 0x00
buf[10] = 0x00
buf[11] = 0x00
buf[12] = asc   (additional sense code)
buf[13] = ascq  (additional sense code qualifier)
buf[14] = 0x00  (FRU code)
buf[15] = 0x00  (sense key specific: SKSV bit, etc.)
buf[16] = 0x00
buf[17] = 0x00
```

---

## How sense data travels in the iSCSI Response PDU

```c
/* in iscsit_send_response() (day 19): */
if (hdr->cmd_status == SAM_STAT_CHECK_CONDITION) {
    /*
     * Sense data is carried in the Response PDU data segment.
     * Format in wire bytes:
     *   [byte 0-1]: sense data length (big-endian u16)
     *   [byte 2-N]: the sense buffer itself
     *
     * DataSegmentLength in BHS = 2 + sense_length
     * Padded to 4-byte boundary.
     *
     * Example for NOT READY (04/01):
     *   DataSegmentLength = 0x0014 (20 bytes = 2 + 18)
     *   Data segment:
     *     0x00 0x12       <- sense length = 18 (0x12)
     *     0x70 0x00 0x02 0x00 0x00 0x00 0x00 0x0a
     *     0x00 0x00 0x00 0x00 0x04 0x01 0x00 0x00
     *     0x00 0x00       <- 18 bytes total sense
     */
    u32 sense_length = cmd->se_cmd.scsi_sense_length;
    put_unaligned_be16(sense_length, iov[0].iov_base);
    /* ... send 2 + sense_length bytes ... */
}
```

For `RESERVATION CONFLICT`:
```
cmd_status = 0x18
DataSegmentLength = 0x000000 (no sense data in data segment)
No data segment transmitted
```

---

## scsi_normalize_sense — parsing on the initiator side

```c
/* drivers/scsi/scsi_lib.c — called by scsi_check_sense() (day 5) */
bool scsi_command_normalize_sense(const struct scsi_cmnd *cmd,
                                   struct scsi_sense_hdr *sshdr)
{
    return scsi_normalize_sense(cmd->sense_buffer,
                                SCSI_SENSE_BUFFERSIZE, sshdr);
}

bool scsi_normalize_sense(const u8 *sense_buffer, int sb_len,
                           struct scsi_sense_hdr *sshdr)
{
    if (!sense_buffer || !sb_len)
        return false;

    memset(sshdr, 0, sizeof(struct scsi_sense_hdr));

    sshdr->response_code = (sense_buffer[0] & 0x7f);

    if (!scsi_sense_valid(sshdr))
        return false;  /* not a valid sense response */

    if (sshdr->response_code >= 0x72) {
        /* descriptor format (0x72 or 0x73) */
        if (sb_len > 1)
            sshdr->sense_key = (sense_buffer[1] & 0x0f);
        if (sb_len > 2)
            sshdr->asc = sense_buffer[2];
        if (sb_len > 3)
            sshdr->ascq = sense_buffer[3];
        if (sb_len > 7)
            sshdr->additional_length = sense_buffer[7];
    } else {
        /* fixed format (0x70 or 0x71) */
        if (sb_len > 2)
            sshdr->sense_key = (sense_buffer[2] & 0x0f);
        if (sb_len > 7)
            sshdr->additional_length = sense_buffer[7];
        if (sb_len > 12)
            sshdr->asc = sense_buffer[12];
        if (sb_len > 13)
            sshdr->ascq = sense_buffer[13];
    }

    return true;
}
EXPORT_SYMBOL(scsi_normalize_sense);
```

`scsi_sense_hdr` after parsing:
```c
struct scsi_sense_hdr {
    u8 response_code;   /* 0x70 or 0x72 */
    u8 sense_key;       /* NOT_READY, ILLEGAL_REQUEST, etc. */
    u8 asc;             /* additional sense code */
    u8 ascq;            /* additional sense code qualifier */
    u8 additional_length; /* bytes after byte 7 in fixed format */
};
```

---

## Key ASC/ASCQ values and their scsi_check_sense() disposition

| Sense Key | ASC | ASCQ | Meaning | disposition() result |
|---|---|---|---|---|
| `NOT_READY` (0x02) | 0x04 | 0x01 | Becoming ready | `NEEDS_RETRY` |
| `NOT_READY` (0x02) | 0x04 | 0x02 | Initializing cmd required | `FAILED` → EH |
| `NOT_READY` (0x02) | 0x04 | 0x0B | Target port in standby | `NEEDS_RETRY` |
| `NOT_READY` (0x02) | 0x04 | 0x0C | Target port unavailable | `NEEDS_RETRY` |
| `UNIT_ATTENTION` (0x06) | 0x29 | 0x00 | Power on/reset | `NEEDS_RETRY` |
| `UNIT_ATTENTION` (0x06) | 0x2A | 0x06 | ALUA state changed | `NEEDS_RETRY` |
| `ILLEGAL_REQUEST` (0x05) | 0x20 | 0x00 | Invalid opcode | `SUCCESS` (permanent) |
| `ILLEGAL_REQUEST` (0x05) | 0x25 | 0x00 | LU not supported | `SUCCESS` (permanent) |
| `HARDWARE_ERROR` (0x04) | 0x08 | 0x00 | LU comm failure | `FAILED` → EH |
| `DATA_PROTECT` (0x07) | 0x27 | 0x00 | Write protected | `SUCCESS` (permanent) |
| Status 0x18 (no sense) | — | — | Reservation conflict | `SUCCESS` (no retry) |

---

## Unit Attention — the broadcast mechanism

```c
/*
 * core_scsi3_ua_allocate() — allocate a Unit Attention for all sessions.
 * Called after: LUN RESET, ALUA state change, mode page change, etc.
 *
 * Each session gets a separate UA entry. The first command from each
 * session after the UA is allocated gets CHECK CONDITION / UNIT ATTENTION.
 * The UA is then cleared for that session (single consumption model).
 */
void core_scsi3_ua_allocate(struct se_device *dev,
                              struct se_session *except_sess,
                              u8 asc, u8 ascq)
{
    struct se_node_acl *acl;
    struct se_session *sess;

    rcu_read_lock();
    list_for_each_entry_rcu(acl, &dev->dev_t10_alua.alua_tg_pt_list, list) {
        spin_lock(&acl->acl_sess_lock);
        list_for_each_entry(sess, &acl->acl_sess_list, sess_list) {
            if (sess == except_sess)
                continue;  /* don't notify the session that caused the change */

            /*
             * Add UA to this session's queue.
             * The next command from this session will get CHECK CONDITION.
             * core_scsi3_ua_check() dequeues one UA per command.
             */
            core_scsi3_ua_queue(sess, asc, ascq);
        }
        spin_unlock(&acl->acl_sess_lock);
    }
    rcu_read_unlock();
}

/*
 * core_scsi3_ua_check() — called from target_submit_cmd() before
 * any other check. If there is a pending UA for this session, return it.
 */
sense_reason_t core_scsi3_ua_check(struct se_cmd *cmd)
{
    struct se_session *sess = cmd->se_sess;
    struct scsi_ua *ua;

    spin_lock(&sess->ua_lock);
    ua = list_first_entry_or_null(&sess->ua_list, struct scsi_ua, list);
    if (!ua) {
        spin_unlock(&sess->ua_lock);
        return TCM_NO_SENSE;  /* no pending UA */
    }
    list_del(&ua->list);
    spin_unlock(&sess->ua_lock);

    /*
     * Build UNIT ATTENTION sense data with ua->asc and ua->ascq.
     * This becomes the response for the NEXT command from this session.
     *
     * Exception: some commands consume the UA (INQUIRY, REQUEST SENSE)
     * while others still get the UA.
     */
    cmd->scsi_asc  = ua->asc;
    cmd->scsi_ascq = ua->ascq;
    kfree(ua);

    return TCM_CHECK_CONDITION_UNIT_ATTENTION;
}
```

---

## Key takeaways

- SCSI fixed-format sense: `buf[0]=0x70`, `buf[2]=sense_key`, `buf[7]=0x0a`, `buf[12]=asc`,
  `buf[13]=ascq`. Minimum 18 bytes. `SCSI_SENSE_BUFFERSIZE = 96` bytes in the kernel.
- `TCM_*` reason codes map to `(sense_key, asc, ascq)` triples in
  `transport_generic_request_failure()`. Know the key mappings: NOT_READY/0x04/0x01 →
  `NEEDS_RETRY`; NOT_READY/0x04/0x0B (ALUA Standby) → `NEEDS_RETRY`; HARDWARE_ERROR/0x08/0x00
  → `FAILED` → EH.
- `RESERVATION CONFLICT` (0x18) is NOT a CHECK CONDITION — status byte is 0x18, no sense data,
  DataSegmentLength = 0 in the iSCSI Response PDU.
- In the iSCSI Response PDU: sense data is prefixed by a 2-byte BE length field. Total data
  segment = 2 + sense_length bytes, padded to 4-byte boundary.
- `scsi_normalize_sense()` on the initiator parses the sense buffer into `scsi_sense_hdr`
  (response_code, sense_key, asc, ascq) — used by `scsi_check_sense()` to decide disposition.
- Unit Attention is a per-session broadcast: `core_scsi3_ua_allocate()` adds a UA entry for
  every session except the one that caused the change. Each session's next command returns UA.
  `core_scsi3_ua_check()` is called at the start of `target_submit_cmd()`.

---

## Previous / Next

[Day 28 — ERL1 and ERL2 error recovery](day28.md) | [Day 30 — Cold re-read day](day30.md)
