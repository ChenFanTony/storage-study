# Day 22: Deep Read — lib/nvmf/tcp.c

## What this day covers

The TCP transport layer: how connections are accepted, how queue pairs are managed,
how requests are received, and how completions are sent back to the host.

This is the entry point for everything you traced in Week 2. Now you read what is
actually behind that entry point.

---

## Why read the transport layer

Everything above the transport layer (ctrlr.c, subsystem.c, bdev) is transport-agnostic.
The transport is where:

- TCP connections become NVMf queue pairs
- raw bytes become `spdk_nvmf_request` objects
- completed requests become TCP frames sent back to the host

Understanding the transport layer tells you:

- where the first thread assignment happens (which QP goes to which poll group thread)
- how buffer management works (in-capsule data vs out-of-capsule DMA)
- where to look when debugging connection issues or incomplete I/O

---

## File organization

`lib/nvmf/tcp.c` is organized around these object types:

- `spdk_nvmf_tcp_transport`: one per target, holds global TCP state
- `spdk_nvmf_tcp_poll_group`: one per poll group thread, holds all QPs on that thread
- `spdk_nvmf_tcp_qpair`: one per TCP connection / NVMf queue pair
- `spdk_nvmf_tcp_req`: one per in-flight request, wraps `spdk_nvmf_request`

```bash
grep -n "^struct spdk_nvmf_tcp" $SPDK_DIR/lib/nvmf/tcp.c
```

---

## Area 1: Connection accept path

### Entry point

```c
static int nvmf_tcp_accept(struct spdk_nvmf_transport *transport)
```

This is a poller registered on the accept thread. It calls `accept()` on the listening
socket and creates a new `spdk_nvmf_tcp_qpair` for each incoming connection.

What to look for:

1. where is the new QP assigned to a poll group? (load balancing across threads)
2. what function moves the QP from accept thread to its poll group thread?
3. is the assignment synchronous or via message?

The assignment uses `spdk_nvmf_tgt_new_qpair` which sends the QP to the appropriate
poll group thread. This is the first cross-thread message in the connection lifecycle.

---

## Area 2: Queue pair poll

### Entry point

```c
static int nvmf_tcp_poll_group_poll(struct spdk_nvmf_poll_group *group)
```

This is registered as a poller (period=0) on the poll group thread. It is called every
reactor iteration.

What it does:

```
for each qpair in the poll group:
    nvmf_tcp_qpair_process_pending(tqpair)
    nvmf_tcp_qpair_process_completions(tqpair)
```

What to look for:

1. how does it handle receive data? (read from socket, parse PDU headers)
2. how does it detect a complete PDU (full header + data)?
3. where does it call `spdk_nvmf_request_exec` to hand off to ctrlr.c?

---

## Area 3: PDU receive and request building

NVMf TCP uses a PDU (Protocol Data Unit) framing layer on top of TCP.

Each NVMe command arrives as:
1. a Common Header (8 bytes) — identifies PDU type and length
2. a PDU-specific header (varies by type) — contains the NVMe SQE
3. optional data (for writes: the write data)

What to look for:

1. the state machine in `nvmf_tcp_qpair_process_pending` — what states does a QP go
   through while receiving a PDU? (e.g., `NVMF_TCP_PDU_RECV_STATE_AWAIT_HDR`,
   `NVMF_TCP_PDU_RECV_STATE_AWAIT_DATA`)
2. where is the `spdk_nvmf_request` populated from the SQE in the PDU header?
3. where is `spdk_nvmf_request_exec` called?

---

## Area 4: In-capsule vs out-of-capsule data

NVMf TCP supports two data transfer modes for write commands:

- **In-capsule**: small write data is included directly in the command PDU.
  No extra round trip needed.
- **Out-of-capsule (C2H/H2C)**: large write data is transferred separately.
  Host sends data after receiving a R2T (Ready to Transfer) from the target.

What to look for:

1. where does the code check whether write data fits in-capsule?
   (compare `data_length` to `in_capsule_data_size` from transport config)
2. where is R2T sent for out-of-capsule writes?
3. for reads: where is data sent back as a Data Response PDU?

This is where the `-c 8192` parameter from `nvmf_create_transport` matters —
it sets the in-capsule data size threshold.

---

## Area 5: Completion and response send

```c
static void nvmf_tcp_req_complete(struct spdk_nvmf_request *req)
```

This is called by `spdk_nvmf_request_complete` to hand the completed request back to
the transport.

What to look for:

1. how is the NVMe CQE packed into a TCP PDU?
2. is the send synchronous (write to socket) or buffered?
3. where are send buffers released after the CQE is sent?

---

## Area 6: Disconnect and cleanup

```c
static void nvmf_tcp_qpair_destroy(struct spdk_nvmf_tcp_qpair *tqpair)
```

What to look for:

1. how is the socket closed?
2. are in-flight requests aborted or allowed to complete?
3. is the QP removal from the poll group synchronous?

---

## Key structs to understand

### spdk_nvmf_tcp_qpair

```bash
grep -A 30 "struct spdk_nvmf_tcp_qpair {" $SPDK_DIR/lib/nvmf/tcp.c
```

Fields to find:

- the underlying socket fd or SPDK sock handle
- the PDU receive state machine state
- the list of in-flight requests
- the poll group this QP belongs to
- the send queue

### spdk_nvmf_tcp_req

```bash
grep -A 20 "struct spdk_nvmf_tcp_req {" $SPDK_DIR/lib/nvmf/tcp.c
```

Fields to find:

- the embedded `spdk_nvmf_request`
- the PDU used for this request
- the data buffer
- the state (receiving, executing, completing, sending response)

---

## What to write in your notes

After reading, record:

### Connection lifecycle
- accept poller location
- how new QP is assigned to poll group thread (function name)
- first function that runs on the poll group thread for a new connection

### Request receive
- PDU receive state machine: list the states in order
- where `spdk_nvmf_request_exec` is called
- in-capsule threshold check location

### Completion send
- function name for sending CQE back to host
- whether send is synchronous or buffered

### Buffer management
- where buffers are allocated for in-capsule data
- where they are freed after request completion

---

## What matters most after Day 22

1. The transport layer is a PDU state machine on top of TCP sockets.
2. Each QP has its own receive state machine — there is no shared receive path.
3. In-capsule vs out-of-capsule determines whether write data needs an extra round trip.
4. The accept thread and the poll group thread are different — new QPs cross from one
   to the other via a message.
5. All send and receive for a QP happens on one poll group thread — no locking needed.

---

## Suggested next step

Day 23: logging and debugging. Now that you know the code, learn to make it talk —
enable debug logs, attach gdb, and trace a live request through the functions you read.
