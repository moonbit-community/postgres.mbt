# Postgres Client

An asynchronous PostgreSQL client for MoonBit.

`Client` owns one PostgreSQL session. Calls made through clones of the same
client are executed in FIFO order, one complete logical operation at a time.
Use `pgpool` when independent tasks need database concurrency.

## Quick Start

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
    let task = group.spawn(no_wait=true, () => executor.run())
    client.ready()
    let current_user : String = client
      .query_one("select current_user::text as current_user")
      .get_name("current_user")
    ignore(current_user)
    client.close()
    task.wait()
  })
}
```

`Client::create(config)` only allocates state. Spawn the single-use executor and
await `ready()` to observe connection and authentication errors. Any number of
tasks may await the same readiness result. Async database operations also wait
for readiness. Before startup finishes, `parameter()` and `cancel_token()`
raise `ClientError::NotReady`. A repeated `run()` raises
`ClientError::ExecutorAlreadyStarted`. `Client::close()` is asynchronous: it stops
new work, waits for already queued work, sends PostgreSQL `Terminate`, and waits
for the driver to finish.

`Client::abort()` is the hard-stop counterpart. It is synchronous and
idempotent: it marks the runtime unusable immediately and requests driver
cancellation without sending `Terminate`. Active, queued, and later operations
fail with `ClientError::Closed("connection aborted")`. The driver closes the
discarded physical transport as cancellation unwinds.

`Client::is_closed()` reports whether the runtime can still be used, not whether
every teardown callback has already completed. It therefore returns `true`
immediately after `abort()`; `close()` remains the API to await graceful
PostgreSQL shutdown and completed transport cleanup.

`Client::is_transaction_idle()` returns `true` only after successful startup,
while the client remains open, and when the most recent `ReadyForQuery` status
was `I`. It is a snapshot of the last protocol response, not a live server
check. It returns `false` for active (`T`) or failed (`E`) transactions.

## Execution Model

A physical PostgreSQL session has one protocol timeline. The client therefore
holds an operation permit from the beginning to the end of a logical operation:

- prepare, type lookup, execute, and temporary-statement cleanup form one
  operation
- a row, simple-query, or `COPY OUT` stream owns the permit until EOF,
  `finish()`, or a detached background drain completes
- `COPY IN` owns it until `finish()` or `abort()`
- a transaction owns it until `commit()` or `rollback()`

Another call through the same `Client` waits in FIFO order. It is not written to
the server early and responses are never routed between several in-flight
requests. Waiting is cancellation-safe: cancelling a waiter does not consume
the permit or disturb the active operation.

An unfinished stream intentionally blocks later work on that client. Prefer
the callback scopes below: they finish the stream even on early return, error,
or cancellation. Inside a callback, finish the stream before starting another
operation on the same client. Use stream handles only within their scope.

For manually managed streams, call `finish()` when stopping early. `detach()`
transfers draining to the background; calling `finish()` afterwards waits for
that drain to complete.

If the connection closes or is aborted during a detached drain, the drain saves
`ClientError::Closed` for an explicit `finish()` call. Database errors also
remain observable through `finish()`; unexpected protocol failures fail the
executor. If the executor has stopped, `finish()` drains the remaining
responses itself or reports their closure.

## Query APIs

Choose the smallest result shape that matches the query:

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
methods, including transaction, scoped-statement, and portal methods, return
the affected row count as `UInt64` from the command tag. Commands without a
count return zero. Counted tags (`INSERT oid rows` and
`DELETE/UPDATE/MERGE/SELECT/MOVE/FETCH/COPY rows`) require decimal digits within
the `UInt64` range; missing, invalid, or overflowing counts raise
`ClientError::Protocol` after the execution stream has been drained. Portal
`max_rows` remains an `Int` protocol limit.

Rows decode by index or PostgreSQL column name:

```mbt check
///|
async fn _query_example(client : @client.Client) -> Int {
  let input = 41
  let row = client.query_one("select $1::int4 + 1 as value", params=[
    input as &ToSql,
  ])
  row.get_name("value")
}
```

`StringView` query parameters use the same codec as `String`, so a string
slice can be passed without first materializing an owned string.
Ordinary string parameters use text format. The `ltree` extension types
`ltree`, `lquery`, and `ltxtquery` use binary format with a version byte followed
by UTF-8. String decoding supports both text and binary results for these
types; binary decoding validates and removes the version byte.

String parameters must not contain NUL (`U+0000`). Built-in string codecs
raise `ClientError::Encode` before UTF-8 encoding or writing the value,
including `StringView`, `Some` values, string array elements, and the string
extension types above. Only the viewed slice is checked for `StringView`.
The driver also rejects zero bytes (`0x00`) in non-NULL text-format parameter
payloads produced by custom `ToSql` codecs. NULL payloads are ignored, and
binary payloads such as `bytea` may contain zero bytes. Literal `\u0000` text
and JSON escapes are allowed; this check does not validate JSON/JSONB logical
values. Encoding errors may occur after Parse/Describe prepares the statement,
but before any Bind/Execute is submitted. Temporary statements are closed
before the error is returned, so a transaction callback that catches the error
can continue with a valid query.

### Client Encoding

**Dangerous operation: changing `client_encoding` away from UTF-8.** The
client requests `client_encoding=UTF8` at startup and always encodes and
decodes strings as UTF-8. Keep this setting at UTF-8 for the entire connection
lifetime, including when using transactions or pooled sessions. Do not change
it through `SET client_encoding`, `SET NAMES`, `set_config`, or startup options.

The current implementation records server `ParameterStatus` updates but does
not reject an unsupported encoding or adapt its codecs. An encoding mismatch
can cause invalid UTF-8 errors or silently write incorrect text. For example,
with a UTF-8 database and `client_encoding=LATIN1`, a parameter containing `é`
is sent as UTF-8 bytes but interpreted as the two characters `Ã` and `©`.
Reading it back on the same connection can produce `é` again, hiding the
incorrect stored value. Switching parameters or results to binary `text`
format does not bypass PostgreSQL's client encoding conversion.

If the encoding has been changed, discard the affected connection and verify
any affected writes through a separate UTF-8 connection. Restoring UTF-8 does
not repair text already stored incorrectly. Enforcement is tracked in
[TODO.md](../TODO.md). See PostgreSQL's
[client encoding documentation](https://www.postgresql.org/docs/current/multibyte.html#MULTIBYTE-CHARSET).

Inspect result data and metadata through `Row::columns()`, `Row::values()`,
`RowStream::columns()`, `SimpleQueryRow::columns()`, and
`SimpleQueryRow::values()`. These return read-only `ArrayView` values; use
`to_owned()` when an editable copy is needed. `RowStream::columns()` reflects
the latest row description when called, so obtain a new view after advancing
the stream. `SimpleQueryMessage::RowDescription` also carries a read-only
column-label view. `CopyOutStream::formats()` exposes the COPY wire formats in
the same way.

`Statement` and `ScopedStatement` expose `params()` and `columns()` metadata
views; `Portal` exposes `columns()`. Type descriptors expose their
classification through `type_.kind`; enum labels and composite fields are
read-only views. The raw `Bytes` returned by `Row::get_raw()` is unchanged.

`query_typed` supplies PostgreSQL parameter types explicitly. The former
`query_typed_raw` compatibility alias has been removed.

Each scope returns the callback's result. Row, simple-query, and COPY OUT scopes
call `finish()` under cancellation protection after the callback exits. A
successful callback is followed by any cleanup error; when the callback raises
or is cancelled, best-effort cleanup preserves that original cause.

```mbt check
///|
async fn _first_value(client : @client.Client) -> Int? {
  client.with_stream("select generate_series(1, 100) as value", stream => {
    match stream.next() {
      Some(row) => Some(row.get_name("value"))
      None => None
    }
  })
}
```

Returning after one row still drains the remaining results and closes the
temporary statement before the scope returns. If parameter count, type, or
encoding validation fails after preparation, the temporary statement is closed
under the same operation permit before the original error is returned; no
Execute request is submitted.

## Type Descriptors And Custom Arrays

`Type` carries `oid`, `name`, `schema : String?`, and `kind`. Built-ins have
`Some("pg_catalog")`; catalog-resolved types retain their actual schema.
`Type::unknown(oid, name=...)` keeps its existing constructor and has `None`
for its unresolved schema. Codecs can distinguish identically named types
in different schemas:

```mbt check
///|
fn _accept_status(type_ : @client.Type) -> Bool {
  type_.schema == Some("app") && type_.name == "status" && type_.kind is Enum(_)
}
```

`Kind::Array(element)`, `Domain(base)`, and `Range(subtype)` now carry complete
`Type` descriptors. Composite fields expose `field.type_`, including nested
metadata. To migrate code that used their OID payloads, read `element.oid`,
`base.oid`, or `subtype.oid`; replace `field.type_oid` with `field.type_.oid`.
Descriptor fields remain read-only. `Eq` compares the entire structure,
including schema and child descriptors.

The generic `Array[T]` codec uses `Kind::Array` metadata, so implementing only
`ToSql` and `FromSql` for a custom enum also enables `Array[Enum]` and
`Array[Enum?]`. Empty arrays and NULL elements are supported. Obtain the
resolved array descriptor from statement or row metadata when using
`query_typed`. Custom element encoders must write PostgreSQL **binary** element
payloads: an array uses binary format for every element, regardless of the
scalar codec's `format` method. Decoders receive the full element descriptor
and `Binary`; the payload's element OID must match that descriptor. Built-in
string arrays include `ltree[]`, `lquery[]`, and `ltxtquery[]`: their scalar
codecs add and remove the version byte for each non-NULL element. Ordinary
strings and JSON/JSONB retain their existing array handling.

Catalog metadata is resolved recursively and cached per connection.
`clear_type_cache()` forces custom types to be resolved again. A cycle raises
`ClientError::UnsupportedRecursiveType(oid)` for the repeated OID; completed
shared subtypes are reusable, and descriptors under construction are never
cached. This is a local transaction error, so a successfully cleaned-up
operation leaves the connection and transaction usable. If metadata resolution
fails after preparation, the driver closes the undelivered statement before
returning the error; a failed Close aborts the connection and preserves the
original metadata error. Missing types and recoverable catalog database errors
retain the existing `Unknown` fallback.

Domains are not automatically unwrapped by codecs. Generic composite/range
codecs, a public type registry, and multidimensional arrays are not provided.

## Prepared Statements And Portals

Use `with_prepared` to keep a named server-side statement for a callback and
close it on return, error, or cancellation:

```mbt check
///|
async fn _prepared_example(client : @client.Client) -> Int {
  client.with_prepared("select $1::int4 as value", statement => {
    let value = 7
    statement.with_stream(params=[value as &ToSql], stream => {
      let result : Int = stream.next().unwrap().get_name("value")
      result
    })
  })
}
```

`with_prepared_typed` also accepts explicit parameter types. The scoped handle
offers `with_stream` and `execute`, and expires when the callback ends. It waits
for operations already started through that handle, then closes the Statement.
`Client::with_statement_stream` manages only an execution stream and leaves a
manually prepared Statement open. For a manual statement inside a transaction,
use `Transaction::close_statement`: direct `Statement::close` immediately raises
`ClientError::Closed` while a root transaction holds or waits for the client
permit. A named Statement may outlive the transaction, so rollback does not
close it.

Every Statement belongs to its creating connection. Passing it to another
Client or Transaction raises `ClientError::StatementConnectionMismatch` before
waiting or submitting requests, even if the Statement is already closed.
Client copies share this identity; Statements remain reusable across
transactions on that same connection.

`Portal` is the only public portal handle. Create one inside a transaction
with `Transaction::with_portal(statement, params?, callback)` or a
transaction-owned `ScopedStatement::with_portal(params?, callback)`. Both entry
points close the portal on return, error, or cancellation. A client-owned
`ScopedStatement` cannot create portals.

With `with_prepared`, nested callbacks clean up in stream, portal, statement
order:

```mbt check
///|
async fn _portal_example(client : @client.Client) -> Int {
  client.with_transaction(tx => {
    tx.with_prepared("select 7::int4 as value", statement => {
      statement.with_portal((portal : @client.Portal) => {
        portal.with_stream(1, stream => {
          let result : Int = stream.next().unwrap().get_name("value")
          result
        })
      })
    })
  })
}
```

`Portal` owns both its server resource and callback scope. The former scoped
handle has been renamed to `Portal` without a compatibility alias. Portal
creation and cleanup use `with_portal`; `Transaction::bind`, `query_portal`,
`with_portal_stream`, and `close_portal` remain package-internal helpers.
Replace a manual bind/query/close sequence with one `with_portal`
callback and successive `portal.with_stream` calls. Each fetch finishes only
its current stream, so the same portal can resume at the next window. Unread
rows in that window are discarded before the next call. Use `max_rows=0` to
fetch all remaining rows, or inspect `QuerySummary.suspended` to decide whether
to fetch another window:

```mbt check
///|
async fn _portal_pagination(client : @client.Client) -> Array[Int] {
  let statement = client.prepare("select generate_series(1, $1::int4) as value")
  defer @async.protect_from_cancel(() => statement.close())
  client.with_transaction(tx => {
    tx.with_portal(statement, params=[3 as &ToSql], portal => {
      let values : Array[Int] = []
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
closes it separately. The pool's prepared-statement cache is unchanged.

Both scoped handles reject new database operations with `ClientError::Closed`
after their callback ends, wait for calls already started, then close their resource.
Explicit `commit()` or `rollback()` raises `ClientError::Closed` while either
resource scope is active, including while cleanup is waiting for a fetch.

If cancellation arrives while `prepare` is waiting for PostgreSQL, the driver
closes an already created statement before propagating cancellation. A failed
Close aborts that physical connection.

## Transactions

`with_transaction` is the preferred scoped API. When the callback returns
normally, it commits only if the transaction is still open; an explicit
`commit()` or `rollback()` prevents a second completion. When the callback
raises or is cancelled, it rolls back best-effort if the transaction is still
open. Unfinished query streams are detached and drained through protocol
cleanup before commit or rollback. A database error found during that drain
causes rollback and is raised to the caller. An unfinished nested transaction
is recursively rolled back, then the parent rolls back and raises
`ClientError::UnfinishedChildTransaction`. A callback error or cancellation
keeps its original cause while protected cleanup completes:

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
accepts an enum value instead of an SQL string. The former `read_uncommitted()`,
`read_committed()`, `repeatable_read()`, and `serializable()` factory methods have
been removed; use the corresponding enum constructors:

```mbt check
///|
async fn _serializable_transaction(client : @client.Client) -> Unit {
  client.with_transaction(
    _tx => (),
    options=@client.TransactionOptions(
      isolation_level=@client.IsolationLevel::Serializable,
    ),
  )
}
```

Use `transaction()` only when manual `commit()` / `rollback()` control is
required. A transaction reserves the session for its complete lifetime, so
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
`with_transaction` or `with_savepoint` on a transaction to scope nested work:

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

Do not return a stream or nested transaction handle from its callback for later
use: the scope finishes it before returning. Draining can wait for the current
SQL command to finish; it does not impose an implicit timeout.

## COPY And Streams

Prefer `with_copy_in` and `with_copy_out` for bulk transfer. COPY IN requires an
explicit `sink.finish()` inside the callback to commit the COPY. Returning
without finishing, throwing, or being cancelled aborts unfinished COPY input
and waits for cleanup. A completed COPY is not undone by a later callback error.
`finish()` returns the affected row count as `UInt64`. If its command tag has an
invalid or overflowing count, it raises `ClientError::Protocol` after consuming
`ReadyForQuery` and releasing the operation permit; the connection is reusable.

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
ownership or control draining explicitly. Portal streams are available only
inside `Portal::with_stream`:

- `RowStream`, `SimpleQueryStream`, and `CopyOutStream` expose `next`,
  `collect`, `finish`, and `detach` as appropriate.
- `CopyInSink::send` feeds a bounded eight-chunk input queue; `finish` completes
  the copy and `abort` terminates it with an error.
- Dropping a handle is not a lifecycle operation. Explicitly finish, abort, or
  detach it.

The response and COPY input queues are bounded. During COPY IN, the driver stays
the sole protocol reader while one request-local writer emits complete
`CopyData` frames. This lets PostgreSQL report malformed input before
`finish()`. Once an early database error reaches a blocked or later `send`, the
sink drains through `ReadyForQuery`, releases its permit, and raises
`ClientError::Database`; the same connection is then reusable. Bounded queues
keep memory usage predictable and apply backpressure without allowing later
operations to pass the active COPY.

## Async Messages

PostgreSQL notices, notifications, and parameter-status changes are separated
from ordinary query responses:

```mbt check
///|
async fn _read_async_message(client : @client.Client) -> @client.AsyncMessage? {
  client.next_message()
}
```

Use one dedicated consumer for `next_message()`. Notifications arrive while the
connection is idle, without sending another query. It returns `None` after the
driver closes, after buffered messages are read. By default the client retains
at most 256 messages. `Client::create_with_async_message_capacity(config,
capacity)` accepts a positive capacity. When full, the driver discards the
oldest message and increments `Client::dropped_async_messages()` without
waiting for the consumer. Current server parameters remain available through
`Client::parameter(name)`.

## Cancellation

`Client::cancel_token()` creates a best-effort PostgreSQL cancellation token.
Cancellation targets the current backend operation; it does not replace normal
task cancellation or stream cleanup. Call `CancelToken::cancel()` from another
task or a timeout handler to send the request. `process_id()` exposes the backend
process ID for diagnostics; the cancellation key stays inside the token.

Task cancellation still waits for protected protocol work and cleanup to reach
a safe boundary. `execute` drains its results before closing its temporary
statement; `execute_raw` drains results while leaving the caller's statement
open. This can wait for the current SQL command to finish.

The client and transaction stream/COPY scopes keep business callbacks
cancellable, including
waits on user queues or other I/O. Waiting for the client's permit is also
cancellable. Protocol startup is protected until a handle has an owner; cleanup
is protected until `ReadyForQuery` and any temporary-statement Close complete.
Pending cancellation is checked before entering the callback, after it returns,
and after protected cleanup. Scopes also wait for drains already started by
stream or sink methods interrupted inside the callback.

Scopes do not automatically send PostgreSQL `CancelRequest`. Cancellation can
therefore wait for the current SQL request to finish and drain. Use a raw
stream's `detach()` when the caller needs to return before draining completes,
or `Client::abort()` when the physical connection may be discarded.

Pending cancellation is checked before starting a new operation and after its
outermost cancellation protection ends. Transaction callbacks check before
automatic commit, so cancellation received during SQL triggers protected
rollback. If cancellation prevents delivery of a new transaction or savepoint
handle, completed `BEGIN` or `SAVEPOINT` work is rolled back before releasing
ownership. Once `COMMIT` has
been sent, its server result is processed before cancellation propagates.

If cancellation interrupts raw stream creation, the client releases its permit or
hands the created stream to a background drain. An explicit caller protection
defers cancellation to the caller's boundary. Task cancellation does not
automatically send PostgreSQL cancel requests or retry operations.

Use `Client::abort()` when a caller must enforce a hard local deadline and the
physical connection may be discarded. Unlike a PostgreSQL cancel token, abort
does not try to preserve the session, send `Terminate`, or perform a TLS
`close_notify` exchange.

## Configuration And TLS

`Config::Config` accepts the host, optional concrete `hostaddr`, user, database,
password, port, TLS settings, channel-binding policy, application name,
startup options, connect timeout, and TCP keepalive settings.
The `Debug` output for a config shows `<hidden>` in place of a configured
password; a missing password remains `None`.

TLS modes are:

- `SslMode::Disable`: plaintext
- `SslMode::VerifyCa`: TLS with certificate-chain validation
- `SslMode::VerifyFull`: TLS with certificate-chain and endpoint identity
  validation; this is the default

`ssl_root_cert="system"` uses the platform trust store and requires
`VerifyFull`. A custom PEM CA file may be supplied instead. `VerifyFull`
requires an explicit `host` or `hostaddr`.

MD5 password authentication is not supported. Configure PostgreSQL for
`scram-sha-256` or cleartext password authentication over an appropriately
protected connection.

The package supports `native` and classic `wasm`; WasmGC is intentionally not
supported because its socket/TLS transport is unavailable.

## Errors

Client-defined failures use `ClientError`. Important variants include database
errors, authentication/TLS failures, wrong-type decoding, row-count mismatches,
connection closure, and protocol failures. Low-level transport and I/O failures
are not wrapped in `ClientError`; they propagate as their original error values.

A fatal driver error becomes the terminal result for the active request and
requests already accepted by the submission queue. Calls still waiting at the
operation gate have not submitted a request; after the driver stops, they
observe `ClientError::Closed` instead.

`ClientError::Database(err)` and `AsyncMessage::Notice(err)` expose the same
`DatabaseError` fields. All fields except `message` are independently optional;
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
supplied by the server. They count characters, including in Unicode queries;
they are not byte offsets or MoonBit UTF-16 indices. `line` is an optional
`UInt`. Malformed decimal values, overflow, zero positions, and invalid UTF-8
raise `ProtocolError::InvalidInput` in the shared parser.

Previously `severity` could be overwritten by `V` depending on field order.
It now preserves only `S`; use `severity_nonlocalized` for stable severity
matching. `Debug` and `Eq` include every field. Query, transaction, COPY, and
pool operations preserve the same structured fields.

Branch on SQLSTATE and constraint name instead of parsing the message:

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
