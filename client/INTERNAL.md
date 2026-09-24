# Client Runtime Architecture

This document describes the invariants behind the `client` package. Public
usage belongs in `README.mbt.md`.

## Ownership Model

`Client::create(config)` allocates shared queues, built-in type metadata, and a
repeatable readiness result without opening a socket. It returns a cloneable
`Client` and a single-use `ClientExecutor`. The caller spawns `run()` in its task
group. That task connects, authenticates, publishes startup state, and then
runs the socket driver. `Client::ready()` and async database operations wait for
startup; synchronous startup metadata access raises `NotReady` until it succeeds.
A second `run()` call raises `ExecutorAlreadyStarted`.

Transport ownership stays with connection setup until startup succeeds. TLS
negotiation, authentication, startup-protocol, and connection-timeout failures
close the established transport before publishing the same readiness error to
all waiters. Closing or aborting before the executor starts opens no socket.

The secure `Stream` variant retains both `Tls` and the original `Tcp`. TLS reads
and writes use `Tls`, but teardown calls `Tls::close()` first and then
`Tcp::close()`: the TLS API releases protocol resources without closing its
underlying transport. Teardown intentionally does not call the asynchronous TLS
shutdown exchange, so cancellation and error unwinding can always release the
transport synchronously.

The driver is private. Its task handle is the only background task handle
stored in shared state, so `Client::abort()` can request cancellation
synchronously, including during startup. The executor keeps its task group
local to `run()`. The driver owns all socket reads, writes ordinary frontend
messages, and publishes notices, notifications, and parameter-status updates.

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

The driver keeps one reader task on the socket for the entire established
connection, including idle periods. It routes notices, notifications, and
parameter updates immediately. Ordinary backend responses pass through a
one-message queue to the request loop, which processes one `Request` at a time:

1. receive and retain the next accepted operation request
2. write its frontend bytes
3. route every ordinary response to that request's bounded response queue
4. continue until `ReadyForQuery` or the request's protocol-specific terminal
   state
5. move to the next request

There is no pending-request list, opportunistic pipeline decision, or
oldest-request response routing.

Each request response queue remains bounded (currently eight messages). The
one-message reader handoff keeps socket reads bounded when an active response
consumer stalls. Because execution is single-flight, a later request cannot
bypass that consumer.

COPY IN is the protocol exception that requires bidirectional coordination.
Its producer queue is bounded to eight actions. After PostgreSQL enters COPY
mode, the driver starts exactly one request-local writer for data, finish, or
abort actions while its reader task remains the sole backend reader. An early
`ErrorResponse` is forwarded to the sink, the input queue is cleared and closed,
and the writer stops after its current complete frame. The driver joins that
writer before forwarding the final `ReadyForQuery` or starting another request.
It is still one logical operation.

## Streams And Detach

Row, simple-query, and COPY OUT streams own the operation permit.

- natural EOF releases it
- `finish()` drains to the operation boundary and releases it
- `detach()` queues a drain job on the executor control queue, transferring
  both the response queue and permit
- `finish()` after detach waits for that drain's completion

Cleanup is idempotent. A consumer cancellation must not leak the permit or
allow the next operation to start before PostgreSQL reaches a safe boundary.

The six `Client::with_*` stream/COPY APIs use `with_scoped_resource`. Readiness
and permit acquisition remain cancellable. Only protocol startup and finalizers
are protected; the business callback runs outside cancellation protection.
Immediately after acquisition, an `errdefer` owns best-effort cleanup. Pending
cancellation is checked before and after the callback and after finalization.
Output scopes finish their streams; COPY IN aborts unless explicitly finished.
COPY IN records any abandoned drain's completion so its scope can also wait for
cleanup triggered by cancellation in `send`, `finish`, or `abort`. Callback
errors survive cleanup errors. The client Statement scope and transaction Portal
scope own only execution streams, never the parent handles.

Temporary inferred/typed queries install statement cleanup immediately after
`read_prepare_response` succeeds. Close bytes and execution parameters are built
before submitting Execute; the non-failing RowStream constructor then takes
ownership. Encoding/submission failures close under the existing permit and
preserve the original error.

Named `prepare` methods use a separate handoff path. The owner keeps its client
or transaction permit and `OpContext` while a protected prepare finishes and
checks pending cancellation. If cancellation is pending, it sends Close under
protection and waits for `ReadyForQuery` before propagating cancellation. Any
Close failure aborts the physical connection; cancellation remains the caller's
error.

Raw stream factories check pending cancellation after acquiring their permit and
before starting protocol work. Factories that protect an asynchronous prepare
or COPY startup check again after leaving protection, inside the same `errdefer`
scope. Before a stream exists, that scope releases the permit on failure. Once
it exists, cancellation hands the stream and permit to a detached drain instead
of returning an unowned handle or releasing the connection prematurely.

Each detached stream holds a repeatable completion result rather than a task
handle. The executor's control worker receives drain jobs independently of the
socket driver, so a full eight-message response queue cannot block scheduling.
`Closed` is saved for `finish()` without failing the executor. Database errors
stay in stream state; unexpected errors fail the executor. If the control queue
has closed, `finish()` drains synchronously to obtain a terminal result. The
control queue completes jobs that were queued but never started when the
executor stops, so `finish()` cannot wait forever for an abandoned drain.

MoonBit task cancellation has separate lifecycle rules. Once `execute_raw`
owns a result stream, its error cleanup drains to `ReadyForQuery` under
cancellation protection. The outer `execute` then closes its temporary
statement. This order releases bounded response-queue backpressure before
waiting for statement closure. Cleanup errors do not replace the original
error or cancellation, and `execute_raw` never closes a caller-owned statement.
Draining can wait for the SQL command to finish; task cancellation alone does
not ask PostgreSQL to interrupt it.

`Driver::run` uses synchronous, idempotent exit cleanup on normal shutdown,
ordinary errors, and cancellation. It closes the active and queued request
responses, COPY inputs, the submission and notification queues, and the socket,
and marks the runtime closed. Ordinary driver errors reach waiting requests;
cancellation gives them `ClientError::Closed` while preserving the driver's
cancellation. The driver's exit defer wakes even cancellation-protected consumers. The
executor then publishes its repeatable completion result after all local tasks
and transport cleanup finish, without overwriting an earlier failure.

## Transactions

Beginning a transaction transfers the permit from the Client call into the
`Transaction`. Transaction methods use the same private context. The permit is
released only after commit or rollback reaches `ReadyForQuery`.

Calls submitted through another clone of the outer Client queue behind the
transaction. Nested transactions use savepoints and temporarily transfer the
same context to the child transaction.

Callback transactions roll back on errors and task cancellation. Rollback is
protected from cancellation and finishes before releasing the owning permit.
Each transaction records its current stream or nested transaction before
handing out the handle. Startup first publishes a `Creating` marker, so a
concurrent close waits for creation and cleanup. Closing rejects new scoped
operations, drains a stream or recursively rolls back a nested transaction,
then acquires the scope gate to send its own completion command. Acquiring the
gate before child cleanup would wait on the child's permit and deadlock.
Database errors during stream drain are reported after a protected rollback;
protocol or transport failures abort the physical connection when synchronization
cannot be confirmed. An open nested transaction on commit is a usage error and
causes recursive rollback through the parent.

async 0.22 does not automatically propagate pending cancellation on leaving a
protected block. Client and transaction operation boundaries check before new
work and after the outermost protection ends. Callback transactions also check
before auto-commit. An enclosing caller protection intentionally defers these
checks to its own boundary. Successful `BEGIN` or `SAVEPOINT` followed by
cancellation before handle delivery is rolled back while the original permit
is still held. A `COMMIT` already submitted is drained and recorded according
to its server result before cancellation propagates.

## Async Messages

Out-of-band backend messages never enter an operation response queue:

- `NoticeResponse`
- `NotificationResponse`
- `ParameterStatus`

They update shared state and are published through the Client async-message
queue. `Client::next_message()` has one-consumer semantics and returns `None`
when the driver terminates. The reader continues delivering these messages
without a query in flight.

Before starting a physical connection, `pgpool` installs the internal async
message handler. That handler forwards messages to the pool's buffer instead
of the Client queue, so the pool consumes them through `Pool::next_message()`.

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
