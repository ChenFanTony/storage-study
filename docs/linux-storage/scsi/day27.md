# Day 27 — iSCSI login sequence

**Week 4**: Advanced Topics  
**Time**: 1–2 hours  
**Reference**: `drivers/target/iscsi/iscsi_target_login.c`, `drivers/target/iscsi/iscsi_target_nego.c`
**Targets**: Linux mainline, mid-2025. Code shown is illustrative pseudocode unless explicitly noted.

---

## Overview

The iSCSI Login Phase (RFC 7143 §6) is the most complex part of the protocol. It establishes
session identity, negotiates parameters (HeaderDigest, DataDigest, MaxRecvDataSegmentLength,
InitialR2T, ImmediateData, MaxBurstLength, etc.), authenticates the initiator (CHAP or none),
and assigns the session age. Login is also where ACL enforcement happens — a fenced initiator's
attempts are rejected here, which is why ACL-based fencing works.

---

## Login Phase overview

```
Initiator                                  Target
─────────                                  ──────
TCP SYN → SYN/ACK → ACK
    │
    │  Login Request (T=0, C=0)
    │  ----------------------------→
    │  opcode = 0x03
    │  CSG=0, NSG=0 (SecurityNegotiation)
    │  ISID, TSIH=0 (new session)
    │  CmdSN=0, ExpStatSN=0
    │  text params: InitiatorName=, TargetName=, AuthMethod=
    │
    │                              Login Response (T=0)
    │  ←----------------------------
    │  status_class=0, status_detail=0 (success)
    │  TSIH assigned
    │  text params: AuthMethod=CHAP (or None)
    │
    │  Login Request (CHAP_A, CHAP_I, CHAP_C exchange, multiple PDUs)
    │  ←--------- CHAP challenge -----
    │  ----------- CHAP response ---→
    │  ←--------- success ------------
    │
    │  Login Request (T=1, C=0)
    │  ----------------------------→
    │  CSG=1, NSG=3 (move to FullFeaturePhase)
    │  text params: HeaderDigest=, DataDigest=, MaxRecvDataSegmentLength=,
    │               InitialR2T=, ImmediateData=, ...
    │
    │                              Login Response (T=1, NSG=3)
    │  ←----------------------------
    │  status_class=0 (success)
    │  text params: negotiated values
    │
[FullFeaturePhase begins — SCSI commands now allowed]
```

CSG = Current Stage, NSG = Next Stage. Stages:
- 0 = SecurityNegotiation
- 1 = LoginOperationalNegotiation
- 3 = FullFeaturePhase

---

## Login PDU structure

Login Request BHS (48 bytes):

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|.|I|  Op(0x03) |T|C|. |CSG|NSG|  Ver Max  |  Ver Min            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|TotalAHSLength |       DataSegmentLength (3 bytes BE)           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
+                          ISID (6 bytes)                       +
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|              ISID (cont)             |          TSIH          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        ITT                                    |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|         CID            |                Reserved              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          CmdSN                                |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          ExpStatSN                            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          Reserved                             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

Key bits:
- `T` (Transit, bit 1 of byte 1): 1 = move to NSG; 0 = stay in CSG
- `C` (Continue, bit 2): 1 = more PDUs in this stage; 0 = this is the last in stage
- `I` (Immediate, bit 6 of byte 0): 1 (always for Login)

The data segment carries text-format key=value pairs:

```
InitiatorName=iqn.2025-01.com.example:host-a\0
TargetName=iqn.2025-01.com.example:tgt0\0
HeaderDigest=None\0
DataDigest=None\0
DefaultTime2Wait=0\0
DefaultTime2Retain=0\0
MaxConnections=1\0
MaxBurstLength=262144\0
FirstBurstLength=65536\0
MaxRecvDataSegmentLength=65536\0
InitialR2T=Yes\0
ImmediateData=Yes\0
ErrorRecoveryLevel=0\0
```

---

## Login thread on the target — `drivers/target/iscsi/iscsi_target_login.c`

```c
/* Simplified — see drivers/target/iscsi/iscsi_target_login.c. */
int iscsi_target_login_thread(void *arg)
{
    struct iscsi_np *np = arg;          /* network portal */
    struct iscsit_conn *conn;
    struct sockaddr_storage sock_in;
    int rc;

    while (!kthread_should_stop()) {
        /* accept incoming TCP connection */
        rc = iscsit_accept_np(np, &sock_in);
        if (rc < 0)
            break;

        /* allocate connection state */
        conn = iscsit_alloc_conn(np);
        if (!conn) {
            /* close the new socket */
            continue;
        }

        /*
         * Drive the per-connection login state machine.
         * iscsi_target_start_negotiation() runs the multi-PDU exchange.
         */
        rc = iscsi_target_start_negotiation(conn);
        if (rc < 0) {
            iscsit_free_conn(conn);
            continue;
        }

        /*
         * Login complete. Spawn dedicated RX/TX kthreads for this
         * connection; the login thread loops back to accept the next.
         */
        rc = iscsit_post_login_handler(np, conn, ... );
        if (rc < 0)
            iscsit_free_conn(conn);
    }

    return 0;
}
```

Each network portal (np) has its own login thread. Multiple portals → multiple login threads
running in parallel. After login completes, RX/TX threads are spawned and the login thread is
done with this connection — back to accepting more.

---

## Negotiation — multiple PDU exchange

```c
/* Simplified. */
static int iscsi_target_do_login(struct iscsit_conn *conn,
                                   struct iscsi_login *login)
{
    int pdu_count = 0;
    struct iscsi_login_req *login_req;

    while (!login->login_complete) {
        /*
         * Receive a Login Request PDU.
         */
        if (iscsi_target_do_login_rx(conn, login) < 0)
            return -1;

        login_req = (struct iscsi_login_req *)login->req;

        /*
         * Determine current/next stage from PDU flags.
         */
        if (login_req->flags & ISCSI_FLAG_LOGIN_TRANSIT) {
            switch (login_req->flags & ISCSI_FLAG_LOGIN_NEXT_STAGE_MASK) {
            case ISCSI_NSG_OP_NEG:
                /* moving from SecurityNegotiation → OpNegotiation */
                break;
            case ISCSI_NSG_FULL_FEATURE:
                /* moving to FullFeaturePhase — last response sent */
                login->login_complete = 1;
                break;
            }
        }

        /*
         * Process the request — parse text, do auth, build response.
         */
        switch (current_stage) {
        case ISCSI_INITIAL_LOGIN_STAGE:
        case ISCSI_SECURITY_NEGOTIATION_STAGE:
            iscsi_handle_login_security_negotiation(conn, login);
            break;

        case ISCSI_OP_PARMS_NEGOTIATION_STAGE:
            iscsi_handle_login_op_params(conn, login);
            break;
        }

        /*
         * Send Login Response PDU.
         */
        if (iscsi_target_do_tx_login_rsp(conn, login) < 0)
            return -1;

        if (++pdu_count > MAX_LOGIN_PDU_COUNT)
            return -1;  /* defense against runaway negotiation */
    }

    return 0;
}
```

The exact number of PDUs in a login varies. Minimum:
- No auth: 1 request + 1 response (T=1, NSG=3 in both, single PDU each direction).
- CHAP auth: 4–6 request/response pairs (challenge, response, success, then op-params).

---

## ACL enforcement — the fencing hook

After parsing the InitiatorName from the Login Request, the target consults the TPG's ACL list:

```c
/* Simplified — see drivers/target/iscsi/iscsi_target_login.c. */
static int iscsi_target_locate_portal(struct iscsi_np *np,
                                         struct iscsit_conn *conn,
                                         struct iscsi_login *login)
{
    char *initiator_name = login->initiator_name;
    char *target_name = login->target_name;
    struct iscsi_tiqn *tiqn;
    struct iscsi_portal_group *tpg;
    struct se_node_acl *se_nacl;
    int ret;

    /*
     * Find the target IQN configured.
     */
    tiqn = iscsit_get_tiqn_for_login(target_name);
    if (!tiqn) {
        login->error_class = ISCSI_STATUS_CLS_INITIATOR_ERR;
        login->error_detail = ISCSI_LOGIN_STATUS_TGT_NOT_FOUND;
        return -1;
    }

    /*
     * Find the appropriate TPG for this initiator.
     * iscsit_get_tpg_from_np() walks the TPG list and may match
     * by portal/IQN config.
     */
    tpg = iscsit_get_tpg_from_np(tiqn, np, ...);
    if (!tpg) {
        login->error_class = ISCSI_STATUS_CLS_INITIATOR_ERR;
        login->error_detail = ISCSI_LOGIN_STATUS_TGT_NOT_FOUND;
        return -1;
    }

    if (!atomic_read(&tpg->tpg_state) == TPG_STATE_ACTIVE) {
        /* TPG is disabled (echo 0 > enable) */
        login->error_class = ISCSI_STATUS_CLS_INITIATOR_ERR;
        login->error_detail = ISCSI_LOGIN_STATUS_SVC_UNAVAILABLE;
        return -1;
    }

    /*
     * *** THE FENCING HOOK ***
     *
     * core_tpg_check_initiator_node_acl() is defined in
     * drivers/target/target_core_tpg.c. It searches the TPG's ACL list
     * for this initiator IQN and either returns the existing ACL or
     * (if generate_node_acls=1) creates a placeholder.
     *
     * For static ACL mode (generate_node_acls=0), removed initiators
     * land here with no match → return error.
     */
    se_nacl = core_tpg_check_initiator_node_acl(&tpg->tpg_se_tpg,
                                                  initiator_name);
    if (!se_nacl) {
        login->error_class = ISCSI_STATUS_CLS_INITIATOR_ERR;
        /* "Not Authorized" / "Initiator Not Found" */
        login->error_detail = ISCSI_LOGIN_STATUS_TGT_FORBIDDEN;
        return -1;
    }

    /*
     * If the ACL has CHAP credentials configured, set up the auth
     * exchange to use them.
     */
    iscsit_set_login_acl(conn, se_nacl);
    return 0;
}
```

When an ACL is removed via `rmdir` (day 24), `core_tpg_check_initiator_node_acl()` returns NULL
for subsequent login attempts. The login thread sends a Login Response with:
- `status_class = 0x02` (Initiator Error)
- `status_detail = 0x03` (Not Authorized) — though specific codes vary; verify against
  `include/scsi/iscsi_proto.h`

The initiator's `iscsid` sees the rejection, logs it, and (per `node.session.timeo.replacement_timeout`)
keeps retrying. Each retry hits the same rejection. After `replacement_timeout` expires, the
initiator declares `RECOVERY_FAILED` and dm-multipath fails the path (day 12).

---

## Login Response status codes

```c
/* status_class values — see include/scsi/iscsi_proto.h */
#define ISCSI_STATUS_CLS_SUCCESS              0x00
#define ISCSI_STATUS_CLS_REDIRECT             0x01  /* try a different portal */
#define ISCSI_STATUS_CLS_INITIATOR_ERR        0x02  /* most fencing rejections */
#define ISCSI_STATUS_CLS_TARGET_ERR           0x03  /* target-side problem */

/* status_detail values for INITIATOR_ERR */
#define ISCSI_LOGIN_STATUS_INIT_ERR           0x00
#define ISCSI_LOGIN_STATUS_AUTH_FAILED        0x01
#define ISCSI_LOGIN_STATUS_TGT_FORBIDDEN      0x02  /* not in ACL */
#define ISCSI_LOGIN_STATUS_TGT_NOT_FOUND      0x03
#define ISCSI_LOGIN_STATUS_TGT_REMOVED        0x04
#define ISCSI_LOGIN_STATUS_NO_VERSION         0x05
/* ... others — verify against your kernel's iscsi_proto.h */
```

The exact code returned for ACL rejection varies by kernel version; the initiator-visible
behavior is the same: login fails, retry continues, eventually `replacement_timeout` expires.

---

## ErrorRecoveryLevel negotiation

ErrorRecoveryLevel (ERL) determines how much error recovery the protocol will support:

- **ERL=0**: session-level recovery only. On any fatal error, drop the session and reconnect.
  This is the default and the only level all initiators reliably support.
- **ERL=1**: Within-Connection recovery. Allows SNACK-based PDU recovery if HeaderDigest or
  DataDigest detects corruption. Requires both sides to support digest-driven recovery.
- **ERL=2**: Connection recovery. Allows a connection to be re-established within an active
  session without losing in-flight commands. Requires task-recovery state machinery on both
  sides.

In practice, **ERL=0 is what gets used everywhere** for production. The initiator and LIO target
both negotiate down to the lowest common value, and most setups don't bother enabling ERL > 0.

Mike Christie's 2017 patch series substantially simplified the libiscsi initiator by removing
unused ERL > 0 code paths. LIO target retains partial ERL=2 support but it is rarely exercised.

For fencing analysis, ERL=0 is the correct mental model — sessions just drop and recover, no
fancy mid-session recovery to reason about.

---

## Negotiation outcome — what each side advertises

```c
/* Negotiation rules per RFC 7143 §13 — examples */
struct iscsi_param_neg {
    /* HeaderDigest / DataDigest */
    /* "Supported" types: list intersection. Result is one of the values
     * present on both sides; "None" if the sets don't overlap. */

    /* MaxRecvDataSegmentLength */
    /* Each side declares its own — different values per direction.
     * No negotiation per se; both sides honor the other's value. */

    /* MaxBurstLength, FirstBurstLength */
    /* Minimum: result = min(initiator's value, target's value). */

    /* InitialR2T, ImmediateData */
    /* Boolean AND for safer behavior:
     * InitialR2T=No only if BOTH sides offered No.
     * ImmediateData=Yes only if BOTH sides agreed Yes. */
};
```

The negotiation outcome shapes the write path (day 18) — Path B/C/D/E selection depends on the
final InitialR2T and ImmediateData values.

---

## Concurrent login attempts

Multiple initiators logging in simultaneously to the same TPG: each gets its own
`iscsit_conn`, ACL lookup, parameter negotiation. The login thread serializes accept() but
the per-connection state machines run concurrently in their own contexts.

For fencing scripts: there is a small race window where a login is in progress at the moment
`rmdir` of the ACL is called. The login could complete (find the ACL) just before `rmdir`
deletes it. Mitigations:
- Disable the TPG (`echo 0 > .../tpgt_1/enable` with force) before rmdir — stops new logins.
- Delete ACL → kill any new sessions immediately via `iscsit_close_session()` on detect.

In practice, because `replacement_timeout` is 120s by default and the cluster orchestrator
drives fencing, the small race window is acceptable — within seconds the situation
reconverges.

---

## Key takeaways

- iSCSI Login Phase has up to 3 stages: SecurityNegotiation → LoginOperationalNegotiation →
  FullFeaturePhase.
- T-bit drives stage transitions; C-bit means "more PDUs coming in this stage".
- The login state machine in the kernel is `iscsi_target_login_thread` per network portal.
- ACL enforcement happens via `core_tpg_check_initiator_node_acl()` (defined in
  `drivers/target/target_core_tpg.c`) — searches TPG's ACL list for the InitiatorName.
- For fencing, `generate_node_acls=0` (static mode) is required — otherwise removed initiators
  re-create their ACL on next login.
- Login rejection: `status_class=0x02` (Initiator Error), `status_detail` indicates the reason
  (e.g., 0x02 forbidden, 0x03 not found). Specific codes vary by kernel version.
- ErrorRecoveryLevel is almost always 0 in production. Mike Christie's 2017 cleanup removed
  unused ERL>0 code paths from libiscsi initiator.
- Parameter negotiation rules: digest "Supported" intersection, lengths min(), bools AND for
  safer values.
- Race window: in-flight login at moment of `rmdir`. Disable TPG first to close.

---

## Previous / Next

[Day 26 — NVMe-oF target fabric comparison](day26.md) | [Day 28 — ERL1 and ERL2 error recovery](day28.md)
