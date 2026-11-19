# Client runtime architecture

For public API usage, see `README.mbt.md`.

## Ownership model

`Client::create(config)` allocates shared queues, built-in type metadata, and a
repeatable readiness result without opening a socket. It returns a cloneable
`Client` and a single-use `ClientExecutor`. The caller spawns `run()` in its task
group. That task connects, authenticates, publishes startup state, and then
runs the socket driver. `Client::ready()` and async database operations wait for
startup. Synchronous access to startup metadata raises `NotReady` until startup
succeeds.
A second `run()` call raises `ExecutorAlreadyStarted`.

Transport ownership stays with connection setup until startup succeeds. TLS
negotiation, authentication, startup-protocol, and connection-timeout failures
close the established transport before publishing the same readiness error to
all waiters. Closing the client before its executor starts prevents the
executor from opening a socket.

The secure `Stream` variant retains both `Tls` and the original `Tcp`. TLS reads
and writes use `Tls`. Teardown calls `Tls::close()` to release TLS state and
then calls `Tcp::close()` to close the transport. Both calls are synchronous,
so teardown can run while the task unwinds after an error or cancellation.
Teardown skips the async TLS shutdown exchange.

Shared state holds the private driver task handle, so `Client::close()` can
cancel it synchronously, including during startup. The executor keeps its task
group local to `run()`. The driver owns socket reads, writes ordinary frontend
messages, and publishes notices, notifications, and parameter-status updates.

Startup and the established driver share `read_backend_message`. It reads
five header bytes, parses `Header`, checks total-length overflow and the
configured body limit, then reads and allocates the body. The reader converts
protocol parser errors to `ClientError::Protocol`. Header rejection triggers
teardown and wakes readiness or request waiters.
The client validates positive resource budgets before transport setup.

SCRAM validates a positive configured iteration budget before connecting and
checks the server's decimal count for overflow and the budget before PBKDF2.
The protocol package shares `HiState` between synchronous `hi`/`update` and
the hidden `begin_update`/`advance_update` helpers. HMAC work starts in the
advance step. While deriving, the final message stays unavailable and the
state rejects updates and authentication finish.
Each advance counts both PBKDF2 and proof HMACs toward its budget. Startup
advances at most 256 per batch and calls cancellable `@async.pause()` after
every batch, including the last before writing the proof. Connection timeout
and cancellation unwind through the transport owner.
Protocol SCRAM errors become `ClientError::Authentication` at the client boundary.

## Single-flight invariant

One PostgreSQL session allows at most one active logical operation. Public
entry points acquire an `OperationGate` permit in FIFO order before submitting
protocol work. Cancellation removes the waiter without handing it the permit.

The permit covers the full logical operation.

- prepare, parameter-type lookup, execution, and cleanup share one context
- a stream retains the context until EOF, finish, or detached drain
- COPY IN retains it through finish or abort
- a transaction retains it through commit or rollback
- nested transactions transfer the same context through savepoint scopes

Catalog queries, temporary-statement cleanup, and other internal phases use the
parent's private `OpContext`. Re-entering a public `Client` method would try
to acquire the permit that the parent already holds.

## Recursive type metadata

`Type` stores the catalog schema (`Some("pg_catalog")` for built-ins, `None`
for unresolved `Type::unknown`). `Kind::Array`, `Domain`, and `Range` carry full
child descriptors. `Field.type_` carries the full composite field type. Fields
and metadata views are read-only. Structural `Eq` includes schema and all
children. Each child descriptor exposes its OID through `oid`.

Each root lookup owns a fresh active-OID map, passed through recursive catalog
lookups. Re-entering an active OID raises `UnsupportedRecursiveType(oid)`.
A `defer` removes the mark on success, error, or cancellation. The connection
caches only completed descriptors, which sibling lookups can reuse.
`clear_type_cache()` resets custom metadata. All catalog queries reuse the
parent's `OpContext`. Missing rows or a database error in the main type lookup
produce an `Unknown` descriptor. A database error from an enum-label or
composite-field lookup produces an empty list. Transport, protocol, decode,
and cycle errors propagate. A cycle is a transaction-local error.

Generic arrays inspect `Kind::Array(element)`.
Compatibility checks and element serialization/deserialization use the complete
child descriptor. Binary decoding checks the payload element OID against it.
Custom scalar encoders must emit binary element payloads regardless of their
standalone format preference. Built-in string and JSON/JSONB arrays support
empty arrays and optional elements. There is no automatic
domain unwrapping, generic composite/range codec, or multidimensional support.

## Driver and queues

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

The ordinary response queue holds eight messages. The one-message reader
handoff keeps socket reads bounded when an active response
consumer stalls. Because execution is single-flight, a later request cannot
bypass that consumer.

COPY IN needs concurrent reads and writes. Its producer queue holds eight
actions. After PostgreSQL enters COPY mode, the driver starts one
request-local writer for data, finish, or
abort actions while its reader task remains the sole backend reader. An early
`ErrorResponse` reaches the sink, and the driver clears and closes the input
queue. The writer stops after its current complete frame. The driver joins that
writer before forwarding the final `ReadyForQuery` or starting another request.
The request cancels and joins its writer on every exit. Unexpected writer
failures propagate to this connection's executor task group, cancelling its
driver and reader and closing active and queued requests. The executor retains
the original cause. The pool isolates physical executor failures from other
sessions.

`CopyInSink::abort` encodes a complete `CopyFail` before marking the sink
finished. `Fail` actions carry validated bytes. A NUL message leaves ownership
and sink state intact so explicit or scoped cleanup can still send a valid abort.

## Error and notice fields

`parse_database_error` handles startup and operation errors, and notices from
the established driver. Startup records parameter status and skips notices.
Pool wrappers propagate the same `ClientError::Database` value. The parser
retains the documented PostgreSQL ErrorResponse and NoticeResponse fields
`S/V/C/M/D/H/s/t/c/d/n/P/p/q/W/F/L/R`. Unknown tags are ignored after UTF-8
validation.

`severity` stores `S` and `severity_nonlocalized` stores `V`, regardless of
field order. Optional fields initialize independently to `None`. Missing
`M` leaves the `"database error"` fallback. Object fields (`schema`, `table`,
`column`, `datatype`, `constraint`) are independent. `Debug` and `Eq` cover all
fields, including object names, context, and source location.

`P/p/L` are parsed as `UInt` using ASCII digits and base 10. Empty input, signs,
separators, non-digits, overflow, and zero `P/p` raise
`ProtocolError::InvalidInput`. `L` may be zero. Positions remain one-based
PostgreSQL character indices into the submitted query (`position`) or `q`
(`internal_position` into `internal_query`), with no byte or UTF-16 conversion.
`W` is retained verbatim as `where_`, including multiline context. Text decode
failures also raise `InvalidInput`.

The driver drains to `ReadyForQuery` after an operation's SQL error before
normal connection reuse. See the public README for
SQLSTATE/constraint matching and the
[protocol field definitions](https://www.postgresql.org/docs/current/protocol-error-fields.html).

## Streams and detach

Row, simple-query, and COPY OUT streams own the operation permit.

- natural EOF releases it
- `finish()` drains to the operation boundary and releases it
- `detach()` queues a drain job on the executor control queue, transferring
  both the response queue and permit
- `finish()` after detach waits for that drain's completion

Cleanup is idempotent. A consumer cancellation must not leak the permit or
allow the next operation to start before PostgreSQL reaches a safe boundary.

Output streams expose an internal `finish_scope` for pgpool. It joins protocol
completion and detached drains, returns the query's `DatabaseError`, and raises
transport, protocol or resource-cleanup failures. Public `next` and `finish`
still raise query SQL errors. `StreamCleanup` records a one-shot `Completion`
for temporary Close, including its failure. The query summary records execution
through ReadyForQuery. Later finishers also join the Close completion, even
if the drain executor tolerated the database exception.

Both normal reads and detached drains accumulate observed `DataRow` counts as
`UInt64` and expose them through `QuerySummary.row_count`. Affected row counts
come from decimal `UInt64` counts in command tags. Invalid or overflowing
counts raise `ClientError::Protocol`. Commands without a count return zero.
COPY IN completion collection returns the raw tag after `ReadyForQuery`.
`CopyInSink::finish` releases its permit before parsing,
so a parse error cannot start a second abandoned drain over a completed queue.

The six `Client::with_*` stream/COPY APIs use `with_scoped_resource`. Readiness
and permit acquisition remain cancellable. Only protocol startup and finalizers
are protected; the business callback runs outside cancellation protection.
Immediately after acquisition, an `errdefer` owns best-effort cleanup. Pending
cancellation is checked before and after the callback and after finalization.
Output scopes finish their streams. COPY IN aborts unless explicitly finished.
COPY IN records any abandoned drain's completion so its scope can also wait for
cleanup triggered by cancellation in `send`, `finish`, or `abort`. Callback
errors survive cleanup errors. `Client::with_statement_stream` and
`Transaction::with_statement_stream` own only an execution stream, leaving the
statement with the caller. `Portal::with_stream` also finishes only its
current fetch stream. The enclosing scope retains the portal.

`read_prepare_response` only reads parameter OIDs and placeholder columns to
successful `ReadyForQuery`. Named prepares and temporary inferred/typed queries
then enter `resolve_prepared_metadata`, which registers statement cleanup before
resolving parameters or columns. Metadata failures close the undelivered
statement under the held permit and preserve the original error. Any Close
failure aborts the connection. Portal column resolution registers its own
cleanup guard.

After metadata succeeds, temporary queries build Close bytes and execution
parameters before submitting Execute. The RowStream constructor then takes
ownership without raising. If encoding or submission fails, a separate Close
path preserves the original error. That path tolerates a synchronized SQL
error from Close and aborts the connection on other failures.

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
it exists, cancellation hands the stream and permit to a detached drain.

Each detached stream holds a completion result that callers can wait for again.
The executor's control worker receives drain jobs independently of the
socket driver, so a full eight-message response queue cannot block scheduling.
`Closed` is saved for `finish()` without failing the executor. Database errors
stay in stream state. Unexpected errors fail the executor. If the control queue
has closed, `finish()` drains the responses itself. When the executor stops,
the control queue supplies a terminal result for jobs still waiting to start.

Once `execute_raw` owns a result stream, its error cleanup drains to
`ReadyForQuery` under
cancellation protection. The outer `execute` then closes its temporary
statement. This order releases bounded response-queue backpressure before
waiting for statement closure. Cleanup errors do not replace the original
error or cancellation. The caller retains its statement after `execute_raw`.
Draining can wait for the SQL command to finish because raw client task
cancellation leaves CancelRequest to the caller.

`Driver::run` uses synchronous, idempotent exit cleanup on normal shutdown,
ordinary errors, and cancellation. It closes the active and queued request
responses, COPY inputs, the submission and notification queues, and the socket,
and marks the runtime closed. Requests receive the driver error on failure and
`ClientError::Closed` on cancellation. The driver's exit defer also wakes
cancellation-protected consumers. The executor publishes its completion after
all local tasks and transport cleanup finish, preserving any earlier failure.

## Scoped statements and portals

`Shared.connection_id` is allocated by a module-level synchronous `UInt64`
counter, independent of wire resource naming. Exhaustion aborts allocation
before wraparound. Client copies, statements and transactions on a connection
share that identity. Public Statement receivers check it before readiness/gate
waits or resource registration, and `OpContext` rechecks before execution,
binding or closing. Foreign handles, including closed ones, raise
`StatementConnectionMismatch` without requests, resource changes or connection
abort. Transaction child-error classification treats this as a local error.
Manual Statements remain reusable across transactions on the same connection.
`ScopedStatement` has a callback-owned lifecycle.

`Portal` is the only public portal handle. It directly owns the transaction,
server name, result columns, closed flag, scope activity flag, and active-call
count. The mutable flags and counter remain shared references so copies of the
handle observe the same lifecycle. The activity flag rejects new calls before
the server resource is closed, while calls already started can finish.
`Transaction::bind`, `query_portal`, `with_portal_stream`, and `close_portal`
are package-internal helpers using the protocol and transaction
gates. `Transaction::bind` builds the handle from the name and resolved columns
returned by `OpContext::bind`; a type-resolution failure closes the bound name
before propagating the error.

Create a `Portal` through `Transaction::with_portal` for an ordinary Statement
or `ScopedStatement::with_portal` for a transaction-owned scoped statement.

Each `Portal::with_stream` drains one fetch to `ReadyForQuery`, under
cancellation protection, before returning. The portal can then fetch another
window. `QuerySummary.suspended` records `PortalSuspended`. `execute` uses the
same path with an unlimited row count. Portal cleanup closes only the portal,
so an ordinary Statement remains reusable across scopes and transactions, and
the pool's prepared-statement cache is unaffected.

On callback exit, the resource scope first rejects new calls, waits for calls
already started through its handle, then closes its resource. Escaped handles
report `Closed` for later database operations. Nested scoped resources clean up
in stream, portal, statement order. Callbacks stay cancellable. Finalizers
run protected and preserve callback errors or cancellation. A portal Close
failure aborts the connection and invalidates its transaction. Cancellation
during Bind closes an undelivered portal before releasing the scope.

`scoped_resources` remains registered through acquisition, the callback, and
finalization. Explicit commit or rollback rejects active resource scopes,
including those in child transactions. Callback transaction completion waits
for these scopes before proceeding with stream and child transaction cleanup.

## Transactions

Beginning a transaction transfers the permit from the Client call into the
`Transaction`. Transaction methods use the same private context. The
transaction releases its permit after commit or rollback completes, or when
it invalidates itself after connection failure.

Calls submitted through another clone of the outer Client queue behind the
transaction. Nested transactions use savepoints and temporarily transfer the
same context to the child transaction.

When a callback raises or is cancelled, the scope attempts to roll back an open
transaction under cancellation protection before releasing its permit.
Each transaction records its current stream or nested transaction before
handing out the handle. Startup first publishes a `Creating` marker, so a
concurrent close waits for creation and cleanup. Closing rejects new scoped
operations, drains a stream or recursively rolls back a nested transaction,
then acquires the scope gate to send its own completion command. Acquiring the
gate before child cleanup would wait on the child's permit and deadlock.
The transaction reports database errors during stream drain after protected
rollback. Protocol or transport failures abort the physical connection if
synchronization cannot be confirmed. Committing with an open nested
transaction causes recursive rollback through the parent.

async 0.22 does not automatically propagate pending cancellation on leaving a
protected block. Client and transaction operation boundaries check before new
work and after the outermost protection ends. Callback transactions also check
before auto-commit. An enclosing caller protection intentionally defers these
checks to its own boundary. Successful `BEGIN` or `SAVEPOINT` followed by
cancellation before handle delivery is rolled back while the original permit
is still held. A `COMMIT` already submitted is drained and recorded according
to its server result before cancellation propagates.

## Async messages

The driver handles these backend messages separately from operation responses.

- `NoticeResponse`
- `NotificationResponse`
- `ParameterStatus`

The reader updates shared parameters on `ParameterStatus` and publishes all
three message types through the Client async-message queue, including while
idle. Use one consumer for `Client::next_message()`. After successful startup,
it returns `None` once the queue closes and buffered messages run out.

Before starting a physical connection, `pgpool` installs the internal async
message handler. With this handler, messages go to the pool's buffer and are
available through `Pool::next_message()`.

## Failure and close

On a fatal socket or protocol error after startup, the driver takes these steps.

1. fails the active request
2. fails accepted but unsent requests
3. lets operation-gate waiters acquire and observe the closed runtime
4. closes the async-message queue

`Client::shutdown()` waits behind earlier FIFO operations and rejects later
work. If startup is pending, it stops startup. On a live connection, it
submits `Terminate` and waits for the driver to exit. Repeated shutdown calls
wait for the same completion. Cancelling a shutdown caller after submission
leaves the `Terminate` request queued for the driver.

`Client::close()` marks the runtime closed immediately, closes the
submission queue without discarding its buffered request records, and cancels
the stored driver task. Driver teardown then fails both the active response
queue and every buffered request queue with the same
`ClientError::Closed("connection aborted")`. The driver needs the buffered
records to notify queued callers. `is_closed()` returns true immediately,
while the driver may still be closing the transport.

## Pool request supervision

The pool installs an internal `RequestControl` while its single-flight gate is
held. Every wire request receives a request record. The driver marks possible
transmission before socket.write; the sole reader saves command tags and protocol
completion before delivering frames to bounded queues. Cancellation prevents
later business sends (including prepare/type-discovery/execution stages).
Cleanup Close requests wait for the control's cancellation fence. CancelToken
waits for EOF on the separate TCP connection so a late cancel packet cannot
reach the next request. The pool also waits for the original request's
protocol cleanup.
The raw client queues operations in FIFO order and supports manual transactions.
Raw COMMIT checks the server tag. ROLLBACK raises CommitRolledBack, and a
missing or unrecognized tag raises CommitOutcomeUnknown. An explicit
PostgreSQL error propagates unchanged. Pooled completion uses
reader observations to preserve a known COMMIT even if ReadyForQuery is lost.
