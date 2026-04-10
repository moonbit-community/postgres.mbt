# Postgres Client Internals

## Core Design

The package is built around an explicit split between:

- `Client`: cheap handle used by application code to enqueue work
- `Connection`: socket-owning task that performs all PostgreSQL protocol I/O

That split is the main architectural decision in the package.

Consequences:

- every public API eventually becomes a `Request`
- requests are queued in `Shared.requests`
- `Connection::run` is the only task that writes to or reads from the socket
- user-facing streams decode backend messages from per-request response queues

This design keeps the public API simple while still allowing controlled
request pipelining and async side-channel delivery.

## Runtime Flow

Normal request flow:

1. `Client` builds frontend protocol bytes.
2. `Client` wraps those bytes in a `Request`.
3. The request is pushed into `Shared.requests`.
4. `Connection::run` takes requests from the queue and writes them to the wire.
5. Backend messages are read in order.
6. Messages are routed either to:
   - the oldest pending request, or
   - the async-message side channel
7. `RowStream`, `SimpleQueryStream`, or `CopyOutStream` convert those messages
   into user-facing values.

Shutdown flow:

- `Client::close` enqueues a `Terminate` request
- `Connection::run` drains queued requests, closes runtime queues, and closes
  the socket once shutdown is complete

## Important Internal Types

- `Shared`
  All mutable runtime state shared across client handles.
- `Request`
  One queued outbound protocol request plus its response queue.
- `RequestKind`
  Distinguishes normal message traffic, COPY IN, and termination.
- `Stream`
  Abstracts plain TCP versus TLS so later code can ignore transport choice.
- `StreamCleanup`
  Deferred cleanup attached to a `RowStream`, typically for temporary prepared
  statements.

## Stream Lifecycle Rules

The package relies on a strict invariant:

- a request is not finished until PostgreSQL sends `ReadyForQuery`

That means:

- `RowStream`
- `SimpleQueryStream`
- `CopyOutStream`

must either be consumed to `None`, explicitly finished, or explicitly
detached.

Why this matters:

- per-request response queues are bounded
- unfinished streams can apply backpressure to later pipelined requests
- temporary prepared statements are often cleaned up only when the stream
  reaches its terminal state

In short: draining streams is not just a convenience, it is part of correct
protocol progress.

Use the two early-stop APIs like this:

- `finish()`
  Synchronously drain to the terminal `ReadyForQuery` and still surface any
  final database error to the caller.
- `detach()`
  Spawn a background discard drain that keeps protocol progress moving with
  lower client-side decode cost and swallows terminal database errors locally.
  After this call, the stream handle itself should be treated as closed.

## Startup And Authentication

Startup is handled separately from the normal request loop in
`client_startup.mbt`.

Order of operations:

1. open TCP connection
2. negotiate TLS if requested
3. send PostgreSQL startup message
4. complete authentication
5. collect:
   - `process_id`
   - `secret_key`
   - startup `ParameterStatus` values
   - initial transaction status
6. create `Shared`
7. hand control to the normal `Connection::run` loop

Supported authentication paths:

- cleartext password
- MD5 password
- SCRAM-SHA-256

Unsupported startup auth methods are rejected with `ClientError::Authentication`.

## Request Encoding

Frontend message encoding lives in `client_wire.mbt`.

Main helpers:

- `simple_query_bytes`
- `prepare_bytes`
- `execute_statement_bytes`
- `bind_portal_bytes`
- `execute_portal_bytes`
- `close_bytes`
- `terminate_bytes`

Parameter encoding rules:

- each parameter is checked with `param.accepts(type_)` before serialization
- each parameter is serialized into an `EncodedParam`
- `NULL` is represented through `@proto.IsNull`

The pre-check is important because it gives deterministic `WrongType` errors
before user codec code runs.

## Response Decoding

Response queue interpretation is split between:

- stream types in `types_row_stream.mbt`, `types_simple_query.mbt`,
  `types_async_copy.mbt`
- helper functions in `client_responses.mbt`
- backend parsers in `types_backend_parsing.mbt`

Design choices:

- database errors are usually recorded when `ErrorResponse` arrives, then raised
  after the terminal `ReadyForQuery`
- row streams preserve already-resolved type metadata when a later
  `RowDescription` arrives
- `fail_response_stream` closes the queue and re-raises when the stream sees a
  protocol state it cannot recover from

## Type System And Caching

The package separates PostgreSQL metadata from MoonBit codecs.

PostgreSQL-side metadata:

- `Type`
- `Kind`
- `Field`

MoonBit-side codec contracts:

- `ToSql`
- `FromSql`

Type resolution strategy:

- built-in types are available immediately through `builtin_type`
- unknown OIDs are represented as `Type::unknown(...)`
- richer metadata is fetched lazily through catalog queries in
  `client_type_cache.mbt`
- resolved types are stored in `Shared.types`

This is why `parse_columns` can work immediately with OIDs while still allowing
later enrichment into enum/composite/domain/range metadata.

## Async Side Channel

`Connection::run` treats these backend messages as asynchronous:

- `ParameterStatus`
- `NoticeResponse`
- `NotificationResponse`

They are emitted in two ways:

- immediate callback through `on_async`
- buffered delivery through `Shared.async_messages` and
  `Connection::next_message`

This keeps request-specific streams simpler because they only need to reason
about messages that belong to their request.

## Cancellation

Cancellation uses PostgreSQL's separate cancel-request protocol.

`Client::cancel_token` captures:

- host/port config
- backend process ID
- backend secret key

`CancelToken::cancel` then opens a new short-lived TCP connection and sends the
cancel request. It does not reuse the main connection socket.

## Transactions

Top-level transactions use `BEGIN` / `COMMIT` / `ROLLBACK`.

Nested transactions are implemented with savepoints:

- `Transaction::transaction()` creates a savepoint-backed child transaction
- child `commit()` releases the savepoint
- child `rollback()` rolls back to and then releases the savepoint

The `finished` flag on `Transaction` is important. Once a transaction or
savepoint handle has been committed or rolled back, it must not be used again.

## COPY

COPY support is intentionally low-level:

- `copy_out` returns raw `CopyData` chunks
- `copy_in` accepts raw input chunks and finish/abort signals

The package does not try to understand CSV, text, or binary COPY content.
That responsibility stays above the protocol layer.

COPY IN is special in the connection loop because it mixes:

- outbound client-produced `CopyData` / `CopyDone` / `CopyFail`
- inbound backend responses for the same request

That is why `RequestKind::CopyIn` acts as a pipeline barrier.

## File Map

- `types_config.mbt`, `types_errors.mbt`
  Config and public error surface.
- `types_descriptors.mbt`
  PostgreSQL type descriptors and builtin-type helpers.
- `types_traits.mbt`, `types_scalars.mbt`
  Codec traits and built-in primitive codecs.
- `types_rows.mbt`, `types_row_stream.mbt`
  Rows and extended-query streaming.
- `types_simple_query.mbt`
  Simple-query messages and stream.
- `types_async_copy.mbt`
  Async messages and COPY OUT stream.
- `types_backend_parsing.mbt`
  Shared backend parsing helpers.
- `client_runtime.mbt`
  Shared runtime structs and internal handle types.
- `client_connect.mbt`
  Public connect/close/cancel APIs.
- `client_startup.mbt`
  TCP/TLS startup and authentication.
- `client_query.mbt`
  Prepare/query/execute/bind/portal APIs.
- `client_copy.mbt`
  COPY IN/OUT APIs.
- `client_transactions.mbt`
  Transaction and savepoint APIs.
- `client_connection_loop.mbt`
  Socket-owning event loop and message routing.
- `client_wire.mbt`
  Frontend protocol encoding helpers.
- `client_responses.mbt`
  Backend response interpretation helpers.
- `client_type_cache.mbt`
  Lazy catalog-backed type lookup.
- `client_support.mbt`
  Smaller shared runtime helpers.

## Reading Order For New Maintainers

If you are taking over this package, this is a good reading order:

1. [`README.mbt.md`](./README.mbt.md)
2. `client_runtime.mbt`
3. `client_connect.mbt`
4. `client_query.mbt`
5. `client_connection_loop.mbt`
6. `client_startup.mbt`
7. `types_traits.mbt`
8. `types_row_stream.mbt`
9. `client_type_cache.mbt`

That order gets you from public API shape to socket control flow to codec/type
machinery with minimal jumping around.
