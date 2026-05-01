# Day 27 — iSCSI login sequence

**Week 4**: Deep Cuts — TMF, ALUA, configfs, NVMe-oF, Sense Data
**Time**: 1–2 hours
**Reference**: `drivers/target/iscsi/iscsi_target_login.c`, `drivers/target/iscsi/iscsi_target_parameters.c`

---

## Overview

The iSCSI Login Phase is a multi-stage negotiation that establishes session and connection
parameters before any SCSI commands flow. On the target side it runs in a dedicated login thread.
Understanding the login sequence is critical for two reasons: (1) session parameters negotiated
here directly control the five write data-flow paths (day 18), and (2) login rejection is the
mechanism that prevents a fenced initiator from reconnecting.

---

## Login phases

```
iSCSI Login Phase (RFC 7143 section 5):

1. SecurityNegotiation    (optional if authentication enabled)
   Text key-value pairs: AuthMethod=CHAP/None, CHAP_A=5, etc.

2. LoginOperationalNegotiation
   Text key-value pairs negotiating all session/connection parameters:
     InitiatorName=<IQN>         (required)
     InitiatorAlias=<string>     (optional)
     TargetName=<IQN>            (required)
     SessionType=Normal          (or Discovery)
     MaxConnections=1
     InitialR2T=Yes/No           ← controls write data paths
     ImmediateData=Yes/No        ← controls write data paths
     MaxRecvDataSegmentLength=N
     FirstBurstLength=N
     MaxBurstLength=N
     MaxOutstandingR2T=N
     DataPDUInOrder=Yes/No
     DataSequenceInOrder=Yes/No
     ErrorRecoveryLevel=0/1/2
     HeaderDigest=None/CRC32C
     DataDigest=None/CRC32C

3. FullFeaturePhase       (login complete)
   SCSI commands flow.
```

Login PDUs use opcode `0x03` (Login Request) and `0x23` (Login Response).

---

## iscsi_target_login_thread — `drivers/target/iscsi/iscsi_target_login.c`

```c
static int iscsi_target_login_thread(void *arg)
{
    struct iscsi_np *np = arg;   /* network portal (IP:port listener) */
    int ret;

    allow_signal(SIGINT);

    while (!kthread_should_stop()) {
        /*
         * Accept new TCP connection on the portal socket.
         * This is a blocking accept() call.
         */
        ret = iscsi_target_accept_np(np, current);
        if (ret == -EINTR)
            break;
        if (ret < 0)
            continue;

        /*
         * Handle the login for the new connection.
         * Spawns a per-connection login handler.
         */
        ret = iscsi_target_do_login_rx(np, &np->np_login_timer);
        if (ret < 0)
            iscsit_close_connection(np->np_connection);
    }

    return 0;
}
```

---

## iscsit_process_login — the core login handler

```c
static int iscsit_process_login(struct iscsi_conn *conn,
                                 struct iscsi_login *login)
{
    struct iscsi_login_req *login_req;
    struct iscsi_login_rsp *login_rsp;
    int err;
    u8 login_rsp_status = ISCSI_STATUS_CLS_SUCCESS;

    login_req = (struct iscsi_login_req *)login->req;
    login_rsp = (struct iscsi_login_rsp *)login->rsp;

    /*
     * Stage dispatch — process each login stage.
     */
    switch (ISCSI_LOGIN_CURRENT_STAGE(login_req->flags)) {
    case ISCSI_SECURITY_NEGOTIATION_STAGE:
        err = iscsi_target_do_authentication(conn, login);
        if (err < 0)
            return err;
        break;

    case ISCSI_OP_PARMS_NEGOTIATION_STAGE:
        /*
         * Process operational parameters.
         * iscsit_login_rx_data_from_ini() reads key=value pairs.
         * iscsit_login_set_conn_values() applies them.
         */
        err = iscsi_target_handle_csg_one(conn, login);
        if (err < 0)
            return err;

        if (ISCSI_LOGIN_NEXT_STAGE(login_req->flags) ==
            ISCSI_FULL_FEATURE_PHASE) {
            /*
             * Login complete. Transition to FullFeaturePhase.
             * This is where we check if the initiator is allowed.
             */
            err = iscsi_target_do_tx_login_rsp(conn, login,
                ISCSI_STATUS_CLS_SUCCESS);

            /* Start the RX/TX kthreads for the connection */
            iscsit_start_kthreads(conn);
        }
        break;
    }

    return 0;
}
```

---

## ACL check during login — the fencing gate

```c
/* in iscsi_target_login.c — called during OPERATIONAL_NEGOTIATION stage */
static int iscsi_login_negotiate_tpg_params(struct iscsi_conn *conn,
                                             struct iscsi_login *login)
{
    struct iscsi_tpg_np *tpg_np = conn->tpg_np;
    struct iscsi_portal_group *tpg = tpg_np->tpg;
    struct se_node_acl *se_nacl;
    char *initiatorname = login->req_buf; /* parsed from InitiatorName= key */

    /*
     * Check if this initiator is allowed to access this target.
     * core_tpg_check_initiator_node_acl() searches tpg->acl_node_list
     * for a matching IQN.
     *
     * If ACL was removed (fencing): returns NULL.
     */
    se_nacl = core_tpg_check_initiator_node_acl(
        &tpg->tpg_se_tpg, initiatorname);

    if (!se_nacl) {
        /*
         * Initiator not found in ACL list.
         * If generate_node_acl=1 (dynamic ACLs): create ACL dynamically.
         * If generate_node_acl=0 (static ACLs, default): REJECT.
         */
        if (!tpg->tpg_attrib.generate_node_acl) {
            /*
             * Send Login Response with failure status.
             * Status-Class: 0x02 (Initiator Error)
             * Status-Detail: 0x01 (Initiator Not Authorized / Not Found)
             *
             * On initiator: iscsi_login_failed() -> iscsi_conn_failure().
             * Reconnect attempt fails. replacement_timeout counts down.
             * After timeout: DID_TRANSPORT_FAILFAST -> dm-multipath fail_path().
             */
            iscsi_target_do_tx_login_rsp(conn, login,
                ISCSI_STATUS_CLS_INITIATOR_ERR);
            return -EPERM;
        }

        /* dynamic ACL: create and allow */
        se_nacl = core_tpg_get_initiator_node_acl_dynamic(
            &tpg->tpg_se_tpg, initiatorname);
    }

    conn->sess->se_sess->se_node_acl = se_nacl;
    return 0;
}
```

---

## Parameter negotiation — `drivers/target/iscsi/iscsi_target_parameters.c`

```c
/*
 * iscsit_check_login_param() is called for each key=value pair
 * received in Login PDU data segments.
 *
 * The negotiation follows RFC 7143 section 11 rules:
 *   - Initiator proposes a value
 *   - Target accepts, proposes a different value, or rejects
 *   - Final value = min of initiator and target for numeric params
 *   - For boolean params: AND logic (Yes wins only if both agree)
 */
static int iscsit_check_login_param(struct iscsi_conn *conn,
                                     struct iscsi_param *param,
                                     char *value)
{
    char *proposer = PTYPE_PROPOSER;

    /*
     * Apply negotiation rules based on parameter type.
     * Example: MaxRecvDataSegmentLength
     *   Type: TYPERANGE (numeric range)
     *   Rule: take minimum of offered and proposed
     */
    switch (param->set_param) {
    case SET_PARAM_MRDSL:
        /* MaxRecvDataSegmentLength — our receive limit */
        return iscsit_check_param_mrdsl(conn, param, value);

    case SET_PARAM_INITIAL_R2T:
        /*
         * InitialR2T: Yes or No.
         * LIO default: Yes (solicited data only).
         * If initiator proposes No and target accepts No:
         *   unsolicited Data-Out PDUs allowed (path D in day 18).
         * If either says Yes: InitialR2T=Yes (path E).
         *
         * In practice: set InitialR2T=No + ImmediateData=Yes for best
         * write performance (single RTT for small writes).
         */
        if (!strcmp(value, YES) && !strcmp(param->value, YES))
            /* both say Yes: agreed */
            return 0;
        if (!strcmp(value, NO)) {
            /* initiator wants No: accept if we allow it */
            if (tpg_ops->allow_initial_r2t_no)
                strncpy(param->value, NO, sizeof(param->value));
        }
        return 0;

    case SET_PARAM_IMMEDIATE_DATA:
        /*
         * ImmediateData: Yes or No.
         * LIO default: Yes.
         * If both agree Yes: immediate data in Command PDU allowed (paths B/C).
         * If either says No: ImmediateData=No (paths D/E only).
         */
        if (!strcmp(value, NO))
            strncpy(param->value, NO, sizeof(param->value));
        return 0;
    }
    return 0;
}
```

---

## Where negotiated parameters are stored

```c
/*
 * After login completes, negotiated values are stored in:
 *   conn->conn_ops  (struct iscsi_conn_ops)  — connection-level params
 *   sess->sess_ops  (struct iscsi_sess_ops)  — session-level params
 *
 * conn->conn_ops->MaxRecvDataSegmentLength = negotiated value
 * sess->sess_ops->InitialR2T = negotiated value (Yes/No as bool)
 * sess->sess_ops->ImmediateData = negotiated value
 * sess->sess_ops->FirstBurstLength = negotiated value
 * sess->sess_ops->MaxBurstLength = negotiated value
 *
 * These are READ by:
 *   iscsit_process_scsi_cmd() — to determine write data-flow path (day 18)
 *   iscsit_handle_immediate_data() — to know expected immediate data size
 *   iscsit_request_r2t() — to know FirstBurstLength for R2T size
 *
 * And on the initiator side:
 *   iscsi_prep_scsi_cmd_pdu() — reads session->imm_data_en, first_burst etc.
 *     to set flags in the Command PDU BHS (day 9).
 */
```

---

## Login Response PDU format

```
iSCSI Login Response PDU (48-byte BHS):

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|0|  0x23       |T|C|0|0| CSG |  NSG  | Version-max| Version-min|
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| TotalAHSLen   |               DataSegmentLength               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         ISID (6 bytes)                        |
+               +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|               |                    TSIH                       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           ITT                                 |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Reserved                              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          StatSN                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         ExpCmdSN                              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         MaxCmdSN                              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| Status-Class  | Status-Detail |          Reserved             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          Reserved                             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

Key fields for fencing:
  Status-Class = 0x00 (Success) or 0x02 (Initiator Error)
  Status-Detail = 0x01 (Not Authorized / Not Found) when ACL missing

T-bit (Transit): set when login is transitioning to next stage
C-bit (Continue): set when more Login PDUs follow in this stage
CSG (Current Stage): 0=SecurityNeg, 1=OpParms, 3=FullFeature
NSG (Next Stage): target of T-bit transition
```

---

## ErrorRecoveryLevel negotiation

```c
/*
 * ErrorRecoveryLevel (ERL) controls what happens on PDU loss:
 *
 * ERL=0 (default, most common):
 *   Connection-level recovery only.
 *   On any error: drop connection, reconnect, restart commands.
 *   Simplest. CmdSN ordering reset on reconnect.
 *
 * ERL=1:
 *   Digest error recovery.
 *   On HeaderDigest mismatch: request retransmit via SNACK.
 *   On DataDigest mismatch: re-request Data-Out.
 *   Connection stays up. Adds SNACK handling complexity.
 *
 * ERL=2 (rarely implemented):
 *   Session-level recovery.
 *   TASK_REASSIGN TMF: move in-flight commands to new connection.
 *   ICF_GOT_LAST_DATAOUT checked to decide if Data-Out restart needed.
 *   Almost never used in practice.
 *
 * For fencing: ERL=0 is the relevant case.
 * On ERL=0, connection drop -> all commands on that connection are
 * lost (no retransmit). iscsit_release_commands_from_conn() handles
 * this by setting CMD_T_ABORTED on all affected commands.
 */
```

---

## Key takeaways

- Login is a multi-stage negotiation: SecurityNegotiation → OperationalNegotiation → FullFeature.
- `core_tpg_check_initiator_node_acl()` is called during OperationalNegotiation — the fencing
  gate. If ACL was removed, returns NULL → Login Response with Status-Class=0x02 (Initiator Error).
- On the initiator side, login rejection calls `iscsi_login_failed()` → `iscsi_conn_failure()` →
  `replacement_timeout` countdown → `RECOVERY_FAILED` → `DID_TRANSPORT_FAILFAST` → `fail_path()`.
- Negotiated parameters are stored in `conn->conn_ops` and `sess->sess_ops`. They control write
  data-flow paths: `InitialR2T`, `ImmediateData`, `FirstBurstLength`, `MaxBurstLength`.
- The same parameters on the initiator side are stored in `iscsi_session->initial_r2t_en`,
  `imm_data_en`, `first_burst`, `max_burst` — read by `iscsi_prep_scsi_cmd_pdu()` (day 9).
- `ErrorRecoveryLevel=0` (default): connection drop → restart all commands. ERL=1/2 add digest
  and session recovery but are rarely used in production.
- `generate_node_acl=0` (static ACLs, default) means login rejection is clean and deterministic.
  `generate_node_acl=1` (dynamic ACLs) bypasses the ACL check — must be disabled for fencing.

---

## Previous / Next

[Day 26 — NVMe-oF target fabric](day26.md) | [Day 28 — ERL1 and ERL2 error recovery](day28.md)
