# Postgres client

An asynchronous PostgreSQL client for MoonBit.

`Client` owns one PostgreSQL session. Calls through copies of the same client
run in FIFO order, one logical operation at a time. Use `pgpool` to run
operations concurrently across sessions.

## Quick start

```mbt check
///|
async fn _quick_start() -> Unit {
  @async.with_task_group(group => {
    let config = @client.Config::Config(
      "localhost",
      user="postgres",
      database="app",
      password="secret",
      port=5432,
      ssl_mode=Disable,
      application_name="my-service",
    )
    let (client, executor) = @client.Client::create(config)
    defer client.close()
    let task = group.spawn(no_wait=true, () => executor.run())
    client.ready()
    let current_user : String = client
      .query_one("select current_user::text as current_user")
      .get_name("current_user")
    ignore(current_user)
    client.shutdown()
    task.wait()
  })
}
```

`Client::create(config)` allocates state without opening a connection. Spawn
the single-use executor, then call `ready()` to wait for connection and
authentication. All waiters see the same startup result, and async database
operations also wait for it. Until startup succeeds, `parameter()` and
`cancel_token()` raise `ClientError::NotReady`. Running `run()` again raises
`ClientError::ExecutorAlreadyStarted`.

On a live connection, `Client::shutdown()` waits for earlier work in the FIFO
gate, rejects later work, sends PostgreSQL `Terminate`, and waits for the
driver to finish. If startup is pending, shutdown stops it.

`Client::close()` is synchronous and idempotent. Use `defer client.close()` to
request driver cancellation on scope exit. The call marks the runtime unusable
immediately. Active, queued, and later operations fail with
`ClientError::Closed("connection aborted")`. The driver closes the physical
transport as cancellation unwinds.

`Client::is_closed()` returns `true` as soon as `close()` marks the runtime
closed. The driver may still be closing the transport.

`Client::is_transaction_idle()` returns `true` only after successful startup,
while the client remains open, and when the most recent `ReadyForQuery` status
was `I`. The method uses the stored protocol status and returns `false` for
active (`T`) or failed (`E`) transactions.

## Execution model

The client holds an operation permit until the logical operation finishes.

- prepare, type lookup, execute, and temporary-statement cleanup form one
  operation
- a row, simple-query, or `COPY OUT` stream owns the permit until EOF,
  `finish()`, or a detached background drain completes
- `COPY IN` owns it until `finish()` or `abort()`
- a transaction owns it until `commit()` or `rollback()`

Calls to the same `Client` wait in FIFO order. The driver sends and drains one
request at a time. Cancelling a waiter leaves the active operation's permit
in place.

An unfinished stream blocks later work on that client. Callback scopes finish
streams on early return, error, or cancellation. Inside a callback, finish the
stream before starting another operation on the same client, and use the
handle within its scope.

For manually managed streams, call `finish()` when stopping early. `detach()`
transfers draining to the background. Calling `finish()` afterwards waits for
that drain to complete.

If the connection closes or is aborted during a detached drain, the drain saves
`ClientError::Closed` for an explicit `finish()` call. Database errors also
remain observable through `finish()`. Unexpected protocol failures fail the
executor. If the control queue has closed, `finish()` drains the remaining
responses itself or reports their closure.

## Query APIs

| Need | API |
| --- | --- |
| Exactly one row | `Client::query_one` |
| Zero or one row | `Client::query_opt` |
| Collect every row | `Client::with_stream(sql, stream => stream.collect())` |
| Incremental rows | `Client::with_stream` |
| Explicit parameter types | `Client::with_typed_stream` |
| Execute a prepared statement | `Client::with_statement_stream` |
| Fetch a portal window | `Portal::with_stream` |
| Affected row count | `Client::execute` |
| SQL batch without parameters | `Client::batch_execute` |
| Text/simple protocol frames | `Client::with_simple_query` |
| Bulk import/export | `Client::with_copy_in`, `Client::with_copy_out` |

`Client::simple_query` and `Client::query_statement` are asynchronous because
they must wait for an operation permit before returning a stream.
MoonBit async calls do not use an `await` keyword.

`QuerySummary.row_count` is a `UInt64` count of observed `DataRow` messages,
including rows discarded during cleanup. All `execute` and `execute_raw`
methods return the affected row count as `UInt64` from the command tag, including
those on transactions, scoped statements, and portals. Commands without a
count return zero. Counted tags (`INSERT oid rows` and
`DELETE/UPDATE/MERGE/SELECT/MOVE/FETCH/COPY rows`) require decimal digits within
the `UInt64` range. Missing, invalid, or overflowing counts raise
`ClientError::Protocol` after the execution stream has been drained. Portal
`max_rows` is an `Int32` protocol limit.

Decode rows by index or PostgreSQL column name.

```mbt check
///|
async fn _query_example(client : @client.Client) -> Int32 {
  let input = 41
  let row = client.query_one("select $1::int4 + 1 as value", params=[
    input as &ToSql,
  ])
  row.get_name("value")
}
```

`StringView` query parameters use the `String` codec and accept a slice
without an owned copy.
Ordinary string parameters use text format. The `ltree` extension types
`ltree`, `lquery`, and `ltxtquery` use binary format with a version byte followed
by UTF-8. Both text and binary results decode to strings. The binary decoder
validates and removes the version byte.

String parameters must not contain NUL (`U+0000`). Built-in string codecs
raise `ClientError::Encode` before UTF-8 encoding or writing the value,
including `StringView`, `Some` values, string array elements, and the string
extension types above. Only the viewed slice is checked for `StringView`.
The client also rejects zero bytes (`0x00`) in non-NULL text-format parameter
payloads produced by custom `ToSql` codecs. NULL payloads are ignored, and
binary payloads such as `bytea` may contain zero bytes. Literal `\u0000` text
and JSON escapes are allowed; this check does not validate JSON/JSONB logical
values. Encoding errors can occur after Parse/Describe and before Bind/Execute.
The client attempts to close the temporary statement before returning the
original error. A Close error that leaves protocol synchronization uncertain
also closes the connection. After successful cleanup, a transaction callback
can catch the encoding error and continue.

### Client encoding

Keep `client_encoding` at UTF-8 for the lifetime of a connection, including
transactions and pooled sessions. The client requests `client_encoding=UTF8`
at startup and always encodes and decodes strings as UTF-8. Leave the encoding
at UTF-8 in `SET client_encoding`, `SET NAMES`, `set_config`, and startup options.

The client records server `ParameterStatus` updates and continues to use its
UTF-8 codecs. A mismatch can cause invalid UTF-8 errors or silently corrupt
stored text. With a UTF-8 database and `client_encoding=LATIN1`, the server
interprets the UTF-8 bytes for `é` as two characters, `Ã` and `©`.
Reading it back on the same connection can produce `é` again, hiding the
incorrect stored value. Switching parameters or results to binary `text`
format does not bypass PostgreSQL's client encoding conversion.

If the encoding has been changed, discard the affected connection and verify
any affected writes through a separate UTF-8 connection. Restoring UTF-8 does
not repair text already stored incorrectly. Enforcement is tracked in
[TODO.md](../TODO.md). See PostgreSQL's
[client encoding documentation](https://www.postgresql.org/docs/current/multibyte.html#MULTIBYTE-CHARSET).

### Row and statement metadata

Inspect result data and metadata through `Row::columns()`, `Row::values()`,
`RowStream::columns()`, `SimpleQueryRow::columns()`, and
`SimpleQueryRow::values()`. These return read-only `ArrayView` values. Use
`to_owned()` when an editable copy is needed. `RowStream::columns()` reflects
the latest row description when called, so obtain a new view after advancing
the stream. `SimpleQueryMessage::RowDescription` also carries a read-only
column-label view. `CopyOutStream::formats()` exposes the COPY wire formats in
the same way.

`Statement` and `ScopedStatement` expose `params()` and `columns()` metadata
views. `Portal` exposes `columns()`. Type descriptors expose their
classification through `type_.kind`. Enum labels and composite fields are
read-only views. `Row::get_raw()` returns the raw value as `Bytes?`.

### Scoped streams

Each scope returns the callback's result. Row, simple-query, and COPY OUT scopes
call `finish()` under cancellation protection after the callback exits. After
a successful callback, cancellation during cleanup takes precedence over any
cleanup error. If the callback raises or is cancelled, cleanup preserves the
original cause.

```mbt check
///|
async fn _first_value(client : @client.Client) -> Int32? {
  client.with_stream("select generate_series(1, 100) as value", stream => {
    match stream.next() {
      Some(row) => Some(row.get_name("value"))
      None => None
    }
  })
}
```

The scope drains unread rows and closes the temporary statement before
returning. If parameter count, type, or encoding validation fails after
preparation, the client closes the statement under the same permit before
returning the original error. It never submits Execute in this case.

Stream SQL errors are reported after `ReadyForQuery` and deferred cleanup.
After `detach()`, `finish()` waits for the background drain and reports the same
query or cleanup failure. Temporary-statement Close results are retained across
repeated calls to `finish()`, including failed Close attempts.

## Type descriptors and custom arrays

`Type` carries `oid`, `name`, `schema : String?`, and `kind`. Built-ins have
`Some("pg_catalog")`. Catalog-resolved types carry their actual schema.
`Type::unknown(oid, name=...)` has `None` for its unresolved schema. Codecs can
distinguish identically named types in different schemas.

```mbt check
///|
fn _accept_status(type_ : @client.Type) -> Bool {
  type_.schema == Some("app") && type_.name == "status" && type_.kind is Enum(_)
}
```

`Kind::Array(element)`, `Domain(base)`, and `Range(subtype)` carry complete
`Type` descriptors. Composite fields expose `field.type_`, including nested
metadata. Read `element.oid`, `base.oid`, `subtype.oid`, or `field.type_.oid`
for the corresponding OID. Descriptor fields are read-only. `Eq` compares the
entire structure, including schema and child descriptors.

The generic `Array[T]` codec uses `Kind::Array` metadata, so implementing only
`ToSql` and `FromSql` for a custom enum also enables `Array[Enum]` and
`Array[Enum?]`. Empty arrays and NULL elements are supported. Obtain the
resolved array descriptor from statement or row metadata when using
`query_typed` to supply parameter types explicitly. Custom element encoders
must write PostgreSQL binary payloads for array elements, regardless of the
scalar codec's `format` method. Decoders receive the full element descriptor
and `Binary`, and check that the payload's element OID matches the descriptor.
For `ltree[]`, `lquery[]`, and `ltxtquery[]`, the scalar codecs add and remove
the version byte for each non-NULL element. Ordinary strings and JSON/JSONB
also support arrays.

Catalog metadata is resolved recursively and cached per connection.
`clear_type_cache()` forces custom types to be resolved again. A cycle raises
`ClientError::UnsupportedRecursiveType(oid)` for the repeated OID. The client
caches only completed descriptors, which sibling lookups can reuse. A cycle
is a local transaction error. If metadata resolution fails after preparation,
the driver closes the undelivered statement before returning the original error.
A failed Close aborts the connection. The main type lookup falls back to
`Unknown` on missing rows or a PostgreSQL database error. A database error
from the enum-label or composite-field lookup yields an empty list instead.

Domains are not automatically unwrapped by codecs. Generic composite/range
codecs, a public type registry, and multidimensional arrays are not provided.

## Prepared statements and portals

Use `with_prepared` to keep a named server-side statement for a callback and
close it on return, error, or cancellation.

```mbt check
///|
async fn _prepared_example(client : @client.Client) -> Int32 {
  client.with_prepared("select $1::int4 as value", statement => {
    let value = 7
    statement.with_stream(params=[value as &ToSql], stream => {
      let result : Int32 = stream.next().unwrap().get_name("value")
      result
    })
  })
}
```

`with_prepared_typed` also accepts explicit parameter types. The scoped handle
offers `with_stream` and `execute`. At callback exit, the scope expires the
handle, waits for operations already started, and closes the Statement.
`Client::with_statement_stream` manages only an execution stream and leaves a
manually prepared Statement open. For a manual statement inside a transaction,
use `Transaction::close_statement`. Direct `Statement::close` immediately raises
`ClientError::Closed` while a root transaction holds or waits for the client
permit. A named Statement may outlive the transaction, so rollback does not
close it.

Every Statement belongs to its creating connection. Passing it to another
Client or Transaction raises `ClientError::StatementConnectionMismatch` before
waiting or submitting requests, even if the Statement is already closed.
Client copies share this identity. Statements remain reusable across
transactions on the same connection.

`Portal` is the only public portal handle. Create one inside a transaction
with `Transaction::with_portal(statement, params?, callback)` or a
transaction-owned `ScopedStatement::with_portal(params?, callback)`. Both entry
points close the portal on return, error, or cancellation. A client-owned
`ScopedStatement` cannot create portals.

With `with_prepared`, nested callbacks close the stream first, then the portal,
then the statement.

```mbt check
///|
async fn _portal_example(client : @client.Client) -> Int32 {
  client.with_transaction(tx => {
    tx.with_prepared("select 7::int4 as value", statement => {
      statement.with_portal((portal : @client.Portal) => {
        portal.with_stream(1, stream => {
          let result : Int32 = stream.next().unwrap().get_name("value")
          result
        })
      })
    })
  })
}
```

Fetch successive windows with `portal.with_stream` inside a single
`with_portal` callback. Each fetch drains unread rows in its window before
returning. Use `max_rows=0` to fetch all remaining rows, or inspect
`QuerySummary.suspended` to decide whether to fetch another window.

```mbt check
///|
async fn _portal_pagination(client : @client.Client) -> Array[Int32] {
  let statement = client.prepare("select generate_series(1, $1::int4) as value")
  defer @async.protect_from_cancel(() => statement.close())
  client.with_transaction(tx => {
    tx.with_portal(statement, params=[3 as &ToSql], portal => {
      let values : Array[Int32] = []
      for ;; {
        let summary = portal.with_stream(2, stream => {
          for row in stream.collect() {
            values.push(row.get_name("value"))
          }
          stream.finish()
        })
        if !summary.suspended {
          break values
        }
      }
    })
  })
}
```

`Portal::execute()` consumes the portal to completion and returns the
affected row count. `Transaction::with_portal` leaves its ordinary `Statement`
open; the caller can reuse it after the portal scope or transaction ends and
closes it separately.

An expired statement or portal handle raises `ClientError::Closed` on new
database operations. Explicit `commit()` or `rollback()` raises the same
error while either resource scope is active, including while cleanup waits
for a fetch.

If cancellation arrives while `prepare` is waiting for PostgreSQL, the driver
closes an already created statement before propagating cancellation. A failed
Close aborts that physical connection.

## Transactions

`with_transaction` commits a still-open transaction when the callback returns.
An explicit `commit()` or `rollback()` completes it early. On a callback error
or cancellation, the scope attempts rollback and preserves the original cause.
Before commit or rollback, it drains any unfinished query stream. A database
error during the drain causes rollback and reaches the caller. If a nested
transaction is still open at commit, the scope rolls back the child and parent,
then raises `ClientError::UnfinishedChildTransaction`.

```mbt check
///|
async fn _transaction_example(client : @client.Client) -> Unit {
  client.with_transaction(tx => {
    ignore(tx.execute("update accounts set active = true"))
    ()
  })
}
```

Set an isolation level directly with `@client.IsolationLevel::ReadUncommitted`,
`ReadCommitted`, `RepeatableRead`, or `Serializable`. `TransactionOptions`
accepts the enum value through its `isolation_level` option.

```mbt check
///|
async fn _serializable_transaction(client : @client.Client) -> Unit {
  client.with_transaction(
    _tx => (),
    options=TransactionOptions(isolation_level=Serializable),
  )
}
```

Use `transaction()` to control `commit()` and `rollback()` manually.
A transaction reserves the session until it ends, so
calls queued through the outer `Client` run only after it ends. Nested
transactions use PostgreSQL savepoints and stay inside the same operation.
Manual `commit()` and `rollback()` also finish any open child streams; rollback
recursively rolls back open nested transactions. A manual commit with an open
nested transaction instead rolls it back and raises
`UnfinishedChildTransaction` after rolling back the parent.

Inside a transaction, `with_stream` and `with_statement_stream` scope one
execution stream. They discard unread rows and wait for cleanup when the
callback returns, raises, or is cancelled. `with_statement_stream` leaves the
Statement open. `Portal::with_stream` likewise finishes one fetch, with
the portal retained until its enclosing `with_portal` callback ends. Use
`with_transaction` or `with_savepoint` on a transaction to scope nested work.

```mbt check
///|
async fn _nested_transaction_example(client : @client.Client) -> Unit {
  client.with_transaction(tx => {
    tx.with_savepoint("optional_work", child => {
      child.with_stream("select 1", stream => ignore(stream.next()))
    })
  })
}
```

Named savepoints are quoted PostgreSQL identifiers. Quoting preserves case and
supports spaces, double quotes, semicolons, and Unicode characters.
Empty names and names containing NUL raise `ClientError::InvalidSavepointName`
before SQL is sent; the parent transaction remains usable.

Use streams and nested transaction handles inside their callbacks. The scope
finishes them before returning. Draining can wait for the current SQL command
to finish without a built-in timeout.

## COPY and streams

Use `with_copy_in` and `with_copy_out` for bulk transfer. Call `sink.finish()`
inside the callback to complete COPY IN and get the affected row count as
`UInt64`. The scope aborts unfinished input on return, error, or cancellation
and waits for cleanup. Once COPY finishes, a callback error does not undo it.
Any enclosing SQL transaction still controls commit and rollback. If the COPY
command tag contains an invalid or overflowing count, `finish()` raises
`ClientError::Protocol` after consuming `ReadyForQuery` and releasing the
operation permit, leaving the connection usable.

```mbt check
///|
async fn _copy_rows(client : @client.Client) -> UInt64 {
  client.with_copy_in("copy events(value) from stdin", sink => {
    sink.send(b"first\nsecond\n")
    sink.finish()
  })
}
```

The raw client APIs (`query`, `query_typed`, `query_statement`, `simple_query`,
`copy_in`, and `copy_out`) remain available when the caller needs to transfer
ownership or control draining explicitly. Fetch portal streams inside
`Portal::with_stream`.

- `RowStream`, `SimpleQueryStream`, and `CopyOutStream` expose `next`,
  `collect`, `finish`, and `detach` as appropriate.
- `CopyInSink::send` feeds a bounded eight-action input queue. `finish` completes
  the copy and `abort` terminates it with an error.
- Finish, abort, or detach raw handles explicitly before dropping them.

During COPY IN, the driver stays
the sole protocol reader while one request-local writer emits complete
`CopyData` frames. This lets PostgreSQL report malformed input before
`finish()`. Once an early database error reaches a blocked or later `send`, the
sink drains through `ReadyForQuery`, releases its permit, and raises
`ClientError::Database`. This leaves the connection reusable, subject to any
enclosing transaction's state. The bounded queues apply backpressure while
the active COPY holds the operation permit.

## Async messages

`next_message()` receives PostgreSQL notices, notifications, and
parameter-status changes.

```mbt check
///|
async fn _read_async_message(client : @client.Client) -> @client.AsyncMessage? {
  client.next_message()
}
```

Use one dedicated consumer for `next_message()`. The client skips startup
notices. Once connected, it receives notifications even while idle.
`next_message()` waits for startup and can raise the startup error. After
successful startup, it returns `None` once the driver closes and buffered
messages run out. By default the client retains at most 256 messages.
`Client::create_with_async_message_capacity(config,
capacity)` accepts a positive capacity. When full, the driver discards the
oldest message and increments `Client::dropped_async_messages()` without
waiting for the consumer. Current server parameters remain available through
`Client::parameter(name)`.

## Cancellation

`Client::cancel_token()` creates a token for the current backend operation.
Call `CancelToken::cancel()` from another task or timeout handler to send a
best-effort PostgreSQL cancellation request, then finish the original response.
`process_id()` exposes the backend process ID for diagnostics. The token keeps
the cancellation key private.

Task cancellation still waits for protected protocol work and cleanup to reach
a safe boundary. `execute` drains its results before closing its temporary
statement. `execute_raw` drains results while leaving the caller's statement
open. This can wait for the current SQL command to finish.

Stream and COPY callbacks remain cancellable, including waits on user queues
or other I/O. Waiting for the client's permit is also cancellable. The scope
protects protocol startup until a handle has an owner, and protects cleanup
until `ReadyForQuery` and any temporary-statement Close complete. It checks for
cancellation around the callback and after cleanup, and joins any drains
started by interrupted stream or sink methods.

Raw client scopes leave PostgreSQL `CancelRequest` to the caller. Task
cancellation can therefore wait for the current SQL request to finish and
drain. Use a raw stream's `detach()` to return before draining completes.

Pending cancellation is checked before starting a new operation and after its
outermost cancellation protection ends. Transaction callbacks check before
automatic commit, so cancellation received during SQL triggers protected
rollback. If cancellation prevents delivery of a new transaction or savepoint
handle, completed `BEGIN` or `SAVEPOINT` work is rolled back before releasing
ownership. Once the client sends `COMMIT`, it processes the server result
before propagating cancellation.

If cancellation interrupts raw stream creation, the client releases its permit or
hands the created stream to a background drain. An explicit caller protection
defers cancellation to the caller's boundary. Task cancellation does not
retry operations.

Use `Client::close()` when a caller must enforce a hard local deadline and the
physical connection may be discarded. The close cancels the driver and
discards the session without sending `Terminate` or TLS `close_notify`.

`CopyInSink::abort(message=...)` validates the message before changing the
sink. A NUL character raises `ProtocolError::InvalidInput`. The sink remains
usable for sends, a valid abort, or automatic scope cleanup. Unexpected COPY
writer failures close the physical connection and wake pending operations.
`ClientExecutor::run` reports the original failure. PostgreSQL SQL errors still
drain through `ReadyForQuery` so a synchronized connection can be reused.

## Configuration and TLS

`Config::Config` accepts the host, optional concrete `hostaddr`, user, database,
password, port, TLS settings, channel-binding policy, application name,
startup options, connect timeout, and TCP keepalive settings.
The `Debug` output for a config shows `<hidden>` in place of a configured
password. A missing password remains `None`.

`max_backend_message_body_bytes` defaults to `67_108_864` (64 MiB) and counts
only one backend frame's body, excluding its tag and four-byte length word.
It must be in `1..=2_147_483_642`. To accept larger rows or COPY chunks, pass
a larger limit to `Config::Config`. The constructor accepts the value without
validation. `ready()` reports `ClientError::InvalidConfig` before connecting
when the limit is invalid.
Both startup and ordinary reads reject malformed or oversized headers with
`ClientError::Protocol`, close the connection, and wake pending requests
without reading the rejected body. Accumulated result sets can exceed this
limit.

`scram_max_iterations` defaults to `100_000` and must be in
`1..=2_147_483_647`. For a server configured with more iterations, explicitly
pass a higher value to `Config::Config`.
Invalid configuration fails `ready()` with `ClientError::InvalidConfig` before
connecting. Invalid or excessive server iteration counts raise
`ClientError::Authentication` before derivation begins. Derivation yields after
every batch of at most 256 HMACs, including the final batch before sending the
proof. Cancellation and `connect_timeout_ms` cover this computation, and other
connections on the event loop can continue working.

| TLS mode | Connection |
| --- | --- |
| `SslMode::Disable` | Plaintext |
| `SslMode::VerifyCa` | TLS with certificate-chain validation |
| `SslMode::VerifyFull` (default) | TLS with certificate-chain and endpoint identity validation |

With TLS enabled, the client uses the platform trust store by default. You can
supply a custom PEM CA file. Setting `ssl_root_cert="system"` explicitly
requires `VerifyFull`, which also requires an explicit `host` or `hostaddr`.

MD5 password authentication is not supported. Configure PostgreSQL for
`scram-sha-256` or cleartext password authentication over an appropriately
protected connection.

The package supports `native` and classic `wasm`. WasmGC lacks the required
socket and TLS transport.

## Errors

Client-defined failures use `ClientError`. Variants include database
errors, authentication/TLS failures, wrong-type decoding, row-count mismatches,
connection closure, and protocol failures. Ordinary transport and I/O errors
propagate as their original values. TLS negotiation and errors from the TLS
handshake can raise `ClientError::Ssl`.

A fatal driver error becomes the terminal result for the active request and
requests already accepted by the submission queue. Calls still waiting at the
operation gate have yet to submit a request. After the driver stops, they
observe `ClientError::Closed` instead.

`ClientError::Database(err)` and `AsyncMessage::Notice(err)` expose the same
`DatabaseError` fields. All fields except `message` are independently optional.
absent values are `None`, and an absent message defaults to `"database error"`.
Object fields need not appear together or refer to objects that currently exist.

| Fields | Meaning |
| --- | --- |
| `severity`, `severity_nonlocalized` | Localizable severity from `S`, nonlocalized severity from `V` |
| `code`, `message`, `detail`, `hint` | SQLSTATE, primary message, extra detail, suggested action |
| `schema`, `table`, `column`, `datatype`, `constraint` | Associated object names; `constraint` can also name an index |
| `position`, `internal_position` | One-based character indices into the submitted query and `internal_query` |
| `internal_query`, `where_` | Internally generated SQL and error context (possibly multiline) |
| `file`, `line`, `routine` | Server source location |

`position` and `internal_position` are positive `UInt` values, preserved as
supplied by the server. They count PostgreSQL characters, including in Unicode
queries. `line` is an optional `UInt`. Malformed decimal values, overflow,
zero positions, and invalid UTF-8 raise `ProtocolError::InvalidInput` in the
shared parser.

`severity` stores `S`. Use `severity_nonlocalized` for stable severity
matching. `Debug` and `Eq` include every field. Query, transaction, COPY, and
pool operations preserve the same structured fields.

Use SQLSTATE and constraint name to identify a database error.

```mbt check
///|
fn _is_email_conflict(error : Error) -> Bool {
  match error {
    @client.ClientError::Database(err) =>
      err.code == Some("23505") && err.constraint == Some("accounts_email_key")
    _ => false
  }
}
```

The field meanings follow the
[PostgreSQL error and notice protocol](https://www.postgresql.org/docs/current/protocol-error-fields.html).

`CancelToken::cancel()` waits for EOF on the separate cancellation connection.
Finish the original response to learn how SQL ended. The pool performs both
waits under a finite cleanup budget. A raw `Transaction::commit()` raises
`ClientError::CommitRolledBack` for a ROLLBACK tag and
`ClientError::CommitOutcomeUnknown` for a missing or unrecognized completion
tag. It propagates explicit database errors.
