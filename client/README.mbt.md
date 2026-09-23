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
| Fetch a portal window | `Transaction::with_portal_stream` |
| Affected row count | `Client::execute` |
| SQL batch without parameters | `Client::batch_execute` |
| Text/simple protocol frames | `Client::with_simple_query` |
| Bulk import/export | `Client::with_copy_in`, `Client::with_copy_out` |

`Client::simple_query`, `Client::query_statement`, and
`Transaction::query_portal` are asynchronous because they must wait for an
operation permit before returning a stream.
MoonBit async calls do not use an `await` keyword.

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

Create and use portals inside an explicit transaction. The former
`Client::bind`, `Client::query_portal`, `Client::with_portal_stream`, and
`Portal::close` methods have been removed. Replace them with `Transaction::bind`,
`Transaction::query_portal` or `Transaction::with_portal_stream`, and
`Transaction::close_portal`. A portal becomes invalid when its enclosing
PostgreSQL transaction ends.
`with_prepared` and its transaction-only `with_portal` method close each
resource in stream, Portal, Statement order:

```mbt check
///|
async fn _portal_example(client : @client.Client) -> Int {
  client.with_transaction(tx => {
    tx.with_prepared("select 7::int4 as value", statement => {
      statement.with_portal(portal => {
        portal.with_stream(1, stream => {
          let result : Int = stream.next().unwrap().get_name("value")
          result
        })
      })
    })
  })
}
```

`Transaction::with_portal(statement, f)` also scopes a manually prepared
Statement's Portal. Both scoped handles expire at callback end. Explicit
`commit()` or `rollback()` raises `ClientError::Closed` while either resource
scope is active. The lower-level `with_portal_stream` finishes only one fetch
window, leaving the Portal and Statement with their caller.

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

Use `transaction()` only when manual `commit()` / `rollback()` control is
required. A transaction reserves the session for its complete lifetime, so
calls queued through the outer `Client` run only after it ends. Nested
transactions use PostgreSQL savepoints and stay inside the same operation.
Manual `commit()` and `rollback()` also finish any open child streams; rollback
recursively rolls back open nested transactions. A manual commit with an open
nested transaction instead rolls it back and raises
`UnfinishedChildTransaction` after rolling back the parent.

Inside a transaction, `with_stream`, `with_statement_stream`, and
`with_portal_stream` scope one execution stream. They discard unread rows and
wait for cleanup when the callback returns, raises, or is cancelled. The latter
two leave the Statement and Portal owned by the caller. Use
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

Do not return a stream or nested transaction handle from its callback for later
use: the scope finishes it before returning. Draining can wait for the current
SQL command to finish; it does not impose an implicit timeout.

## COPY And Streams

Prefer `with_copy_in` and `with_copy_out` for bulk transfer. COPY IN requires an
explicit `sink.finish()` inside the callback to commit the COPY. Returning
without finishing, throwing, or being cancelled aborts unfinished COPY input
and waits for cleanup. A completed COPY is not undone by a later callback error.

```mbt check
///|
async fn _copy_rows(client : @client.Client) -> Int {
  client.with_copy_in("copy events(value) from stdin", sink => {
    sink.send(b"first\nsecond\n")
    sink.finish()
  })
}
```

The raw client APIs (`query`, `query_typed`, `query_statement`, `simple_query`,
`copy_in`, and `copy_out`) remain available when the caller needs to transfer
ownership or control draining explicitly. `Transaction::query_portal` provides
the raw portal stream inside a transaction:

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

Use one dedicated consumer for `next_message()`. It returns `None` after the
driver closes, after buffered messages are read. By default the client retains
at most 256 messages. `Client::create_with_async_message_capacity(config,
capacity)` accepts a positive capacity. When full, the driver discards the
oldest message and increments `Client::dropped_async_messages()` without
waiting for the consumer. Current server parameters remain available through
`Client::parameter(name)`.

## Cancellation

`Client::cancel_token()` creates a best-effort PostgreSQL cancellation token.
Cancellation targets the current backend operation; it does not replace normal
task cancellation or stream cleanup.

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
