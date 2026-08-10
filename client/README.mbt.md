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
    let config = Config::new(
      "localhost",
      user="postgres",
      database="app",
      password="secret",
      port=5432,
      ssl_mode=Disable,
      application_name="my-service",
    )
    let client = connect(config, group)
    let current_user : String = client
      .query_one("select current_user::text as current_user")
      .get_name("current_user")
    ignore(current_user)
    client.close()
  })
}
```

`connect(config, group)` opens the session and starts its socket driver in the
provided task group. There is no separate `Connection` handle and callers do
not start a driver task themselves. `Client::close()` is asynchronous: it stops
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

An unfinished stream intentionally blocks later work on that client. Call
`finish()` when stopping early. `detach()` transfers draining to the background;
calling `finish()` afterwards waits for that drain to complete.

## Query APIs

Choose the smallest result shape that matches the query:

| Need | API |
| --- | --- |
| Exactly one row | `Client::query_one` |
| Zero or one row | `Client::query_opt` |
| Collect every row | `Client::query(...).collect()` |
| Incremental rows | `Client::query` |
| Affected row count | `Client::execute` |
| SQL batch without parameters | `Client::batch_execute` |
| Text/simple protocol frames | `Client::simple_query` |
| Bulk import/export | `Client::copy_in`, `Client::copy_out` |

`simple_query`, `query_statement`, and `query_portal` are asynchronous because
they must wait for the session's operation permit before returning a stream.
MoonBit async calls do not use an `await` keyword.

Rows decode by index or PostgreSQL column name:

```mbt check
///|
async fn _query_example(client : Client) -> Int {
  let input = 41
  let row = client.query_one("select $1::int4 + 1 as value", params=[
    input as &ToSql,
  ])
  row.get_name("value")
}
```

`query_typed` supplies PostgreSQL parameter types explicitly. The former
`query_typed_raw` compatibility alias has been removed.

## Prepared Statements And Portals

Use `prepare` when a named server-side statement should be reused:

```mbt check
///|
async fn _prepared_example(client : Client) -> Int {
  let statement = client.prepare("select $1::int4 as value")
  let value = 7
  let stream = client.query_statement(statement, params=[value as &ToSql])
  let rows = stream.collect()
  statement.close()
  rows[0].get_name("value")
}
```

`bind` and `query_portal` expose explicit fetch windows for advanced consumers.
As with every stream, finish or drain the portal stream before issuing unrelated
work on the same client.

When a statement or portal is owned by an active transaction, close it through
`Transaction::close_statement` or `Transaction::close_portal`. Calling the raw
handle's `close` method would try to reacquire the outer client's permit.

## Transactions

`with_transaction` is the preferred scoped API. It commits when the callback
returns and rolls back best-effort when the callback raises:

```mbt check
///|
async fn _transaction_example(client : Client) -> Unit {
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

## COPY And Streams

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
async fn _read_async_message(client : Client) -> AsyncMessage? {
  client.next_message()
}
```

Use one dedicated consumer for `next_message()`. It returns `None` after the
driver closes. Current server parameters are available through
`Client::parameter(name)`.

## Cancellation

`Client::cancel_token()` creates a best-effort PostgreSQL cancellation token.
Cancellation targets the current backend operation; it does not replace normal
task cancellation or stream cleanup.

Use `Client::abort()` when a caller must enforce a hard local deadline and the
physical connection may be discarded. Unlike a PostgreSQL cancel token, abort
does not try to preserve the session, send `Terminate`, or perform a TLS
`close_notify` exchange.

## Configuration And TLS

`Config::new` accepts the host, optional concrete `hostaddr`, user, database,
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

Operations raise `ClientError`. Important variants include database errors,
authentication/TLS failures, wrong-type decoding, row-count mismatches,
connection closure, and protocol/I/O failures. A fatal driver error becomes the
terminal result for the active request and all queued waiters.
