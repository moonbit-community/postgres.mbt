# Client Runtime Architecture

This document describes the invariants behind the `client` package. Public
usage belongs in `README.mbt.md`.

## Ownership Model

`Client` is the only public connection handle. `connect(config, group)`:

1. performs PostgreSQL startup and authentication
2. creates shared queues and session state
3. spawns the socket-owning driver in the supplied task group
4. returns a cloneable `Client`

Transport ownership stays with connection setup until startup and driver spawn
both succeed. Any TLS negotiation, authentication, startup-protocol, spawn, or
connection-timeout failure closes the established transport before propagating
the error.

The secure `Stream` variant retains both `Tls` and the original `Tcp`. TLS reads
and writes use `Tls`, but teardown calls `Tls::close()` first and then
`Tcp::close()`: the TLS API releases protocol resources without closing its
underlying transport. Teardown intentionally does not call the asynchronous TLS
shutdown exchange, so cancellation and error unwinding can always release the
transport synchronously.

The driver is private and its task handle is stored in shared state so
`Client::abort()` can request cancellation synchronously. The driver owns all
socket reads, writes ordinary frontend messages, and publishes notices,
notifications, and parameter-status updates. Closing the task group cannot
leave an orphan driver.

## Single-Flight Invariant

One PostgreSQL session has exactly one active logical operation. Public
entrypoints acquire an `OperationGate` permit in FIFO order before submitting
protocol work. Cancellation while waiting removes that waiter without
transferring ownership incorrectly.

The permit covers the full logical operation, not one frontend message:

- prepare, parameter-type lookup, execution, and cleanup share one context
- a stream retains the context until EOF, finish, or detached drain
- COPY IN retains it through finish or abort
- a transaction retains it through commit or rollback
- nested transactions transfer the same context through savepoint scopes

Internal phases receive a private `OpContext` and call its internal methods.
They must never re-enter a public `Client` method and reacquire the gate. This
is especially important for catalog queries issued by type resolution and for
temporary prepared-statement cleanup.

## Driver And Queues

The driver processes one `Request` at a time:

1. receive the next accepted operation request
2. write its frontend bytes
3. route every ordinary response to that request's bounded response queue
4. continue until `ReadyForQuery` or the request's protocol-specific terminal
   state
5. move to the next request

There is no pending-request list, opportunistic pipeline decision, or
oldest-request response routing.

Each request response queue remains bounded (currently eight messages).
Backpressure therefore stops socket reads for the active request rather than
growing memory without limit. Because execution is single-flight, a stalled
consumer cannot be bypassed by a later request.

COPY IN is the protocol exception that requires bidirectional coordination.
Its producer queue is bounded to eight actions. After PostgreSQL enters COPY
mode, the driver starts exactly one request-local writer for data, finish, or
abort actions while the driver itself remains the sole backend reader. An early
`ErrorResponse` is forwarded to the sink, the input queue is cleared and closed,
and the writer stops after its current complete frame. The driver joins that
writer before forwarding the final `ReadyForQuery` or starting another request.
It is still one logical operation.

## Streams And Detach

Row, simple-query, and COPY OUT streams own the operation permit.

- natural EOF releases it
- `finish()` drains to the operation boundary and releases it
- `detach()` transfers both the queue and permit to a driver-managed background
  drain
- `finish()` after detach waits for that drain's completion

Cleanup is idempotent. A consumer cancellation must not leak the permit or
allow the next operation to start before PostgreSQL reaches a safe boundary.

## Transactions

Beginning a transaction transfers the permit from the Client call into the
`Transaction`. Transaction methods use the same private context. The permit is
released only after commit or rollback reaches `ReadyForQuery`.

Calls submitted through another clone of the outer Client queue behind the
transaction. Nested transactions use savepoints and temporarily transfer the
same context to the child transaction.

## Async Messages

Out-of-band backend messages never enter an operation response queue:

- `NoticeResponse`
- `NotificationResponse`
- `ParameterStatus`

They update shared state and are published through the Client async-message
queue. `Client::next_message()` has one-consumer semantics and returns `None`
when the driver terminates.

## Failure And Close

A fatal socket/protocol error is terminal shared state. The driver:

1. fails the active request
2. fails accepted but unsent requests
3. lets operation-gate waiters acquire and observe the closed runtime
4. closes the async-message queue

`Client::close()` seals the gate against new work, waits behind already
accepted FIFO operations, submits `Terminate`, and waits for driver exit.
Repeated close calls wait for the same result. Cancelling one close caller does
not undo a close that has already started.

`Client::abort()` instead marks the runtime closed immediately, closes the
submission queue without discarding its buffered request records, and cancels
the stored driver task. Driver teardown then fails both the active response
queue and every buffered request queue with the same
`ClientError::Closed("connection aborted")`. Keeping the request records until
that teardown is essential: clearing the submission queue directly would leave
queued callers without a terminal notification. `is_closed()` consequently
describes runtime usability: it is already true while cancellation unwinds and
the driver performs the final physical transport close.

These convergence rules are required so `pgpool` can determine whether a
physical connection is safe to recycle.
