# Postgres Client

An async PostgreSQL client for MoonBit.

If you want to start using this package quickly, the core flow is:

1. build a `Config`
2. call `connect`
3. start `connection.run()` in a background task
4. use `client.query`, `client.query_one`, `client.execute`, or `client.transaction`
5. call `client.close()` when finished

## Quick Start

This is the smallest complete usage pattern:

```mbt check
///|
async fn _quick_start() -> Unit {
  @async.with_task_group(group => {
    let config = @client.Config::new(
      "localhost",
      user="postgres",
      database="app",
      password="secret",
      port=5432,
      ssl_mode=@client.SslMode::VerifyFull,
      application_name="my-service",
    )
    let (client, connection) = @client.connect(config)
    group.spawn_bg(() => connection.run())

    let current_user : String = client
      .query_one("select current_user::text as current_user")
      .get_name("current_user")
    ignore(current_user)

    client.close()
  })
}
```

The line `group.spawn_bg(() => connection.run())` is mandatory in normal use.
`Client` only enqueues work. `Connection::run` is the task that actually keeps
the socket moving, reads PostgreSQL messages, and delivers responses back to
query streams.

## Choose The Right API

These are the main entry points and the situations they are designed for:

| Need | API | Use it when |
| --- | --- | --- |
| Exactly one row | `Client::query_one` | A lookup must succeed once and only once, such as fetching by primary key or reading one aggregate row |
| Zero or one row | `Client::query_opt` | The row may be absent, such as optional profile/settings records |
| Many rows or incremental consumption | `Client::query` | You want a `RowStream` and may stop early or process rows as they arrive |
| Affected row count | `Client::execute` | `insert`, `update`, `delete`, or other parameterized commands where row data is not needed |
| Raw SQL batch with no parameters | `Client::batch_execute` | Schema setup, `BEGIN` / `COMMIT`, temp tables, session settings, or other statement batches |
| Reuse SQL many times | `Client::prepare` + `Client::query_statement` / `Client::execute_raw` | The same SQL text is executed repeatedly and you want PostgreSQL to keep a named prepared statement |
| Fetch rows in chunks | `Client::bind` + `Client::query_portal` | Large result sets where you want explicit fetch windows instead of collecting everything |
| Multiple statements with atomicity | `Client::transaction` or `Client::build_transaction` | Business logic must commit or roll back as one unit |
| PostgreSQL simple protocol | `Client::simple_query` | Multiple statements in one SQL string, or direct access to text-format frames |
| Bulk import / export | `Client::copy_in` / `Client::copy_out` | High-volume streaming I/O with PostgreSQL `COPY` |

## Connection Config And Lifecycle

Create a config with `Config::new`:

```mbt check
///|
fn _config_example() -> @client.Config {
  @client.Config::new(
    "localhost",
    user="postgres",
    database="app",
    password="secret",
    port=5432,
    ssl_mode=@client.SslMode::VerifyFull,
    application_name="my-service",
  )
}
```

`Config` stores:

- `host`: PostgreSQL host name or IP
- `hostaddr`: optional concrete socket address when TCP routing should differ from certificate identity
- `port`: PostgreSQL port, default `5432`
- `user`: login role
- `database`: database name, default is the same as `user`
- `password`: optional password
- `ssl_mode`: `SslMode::Disable`, `SslMode::VerifyCa`, or `SslMode::VerifyFull`
- `ssl_root_cert`: custom CA file, or `"system"` for the platform trust store
- `channel_binding`: SCRAM channel-binding policy for SCRAM authentication
- `application_name`: value visible in PostgreSQL session metadata
- `options`: optional PostgreSQL startup `options` string
- `connect_timeout_ms`: optional end-to-end connect timeout
- `keepalives`, `keepalives_idle_s`: TCP keepalive settings

Use the `SslMode` constructors directly:

- `SslMode::Disable`: never attempt TLS
- `SslMode::VerifyCa`: require TLS and verify the certificate chain, but not the hostname or IP
- `SslMode::VerifyFull`: require TLS, verify the certificate chain, and verify the hostname or IP

## TLS Configuration

The client now keeps only three TLS modes:

- `Disable`: explicit plaintext. No encryption, no certificate validation, no server identity check.
- `VerifyCa`: TLS is mandatory. Certificate-chain validation is required, but hostname or IP validation is skipped.
- `VerifyFull`: TLS is mandatory. Certificate-chain validation and hostname or IP validation are both required.

The removed `prefer` and `require` modes were easy to misread as "safe enough"
while still leaving room for confusing downgrade and identity-checking behavior.
The current surface keeps plaintext opt-in and makes the verification model
visible in the API.

Threat-model difference:

- `VerifyCa` protects against an untrusted or forged certificate chain, but it
  still accepts any certificate from a trusted CA, even if it was issued for a
  different hostname.
- `VerifyFull` adds endpoint identity checking, so the certificate must match
  the requested hostname or IP address. This is the default and recommended
  mode.

`sslrootcert=system` follows libpq's stricter system-trust-store behavior in
this package: it selects the platform trust store and requires
`ssl_mode = SslMode::VerifyFull`. We reject weaker modes instead of silently
accepting a configuration that looks stronger than it is.

Additional TLS fields:

- `ssl_root_cert`: custom CA file, or `"system"` for the platform trust store

Default behavior:

- `VerifyFull` requires an explicit `host` or `hostaddr`. If both are absent,
  the connection fails before the TLS handshake starts.

Windows notes:

- `Disable`, `VerifyCa`, and `VerifyFull` still work.
- `sslrootcert` with a custom file is rejected explicitly on the Schannel path.
- The package reports these cases as unsupported instead of silently ignoring
  them.

External references:

- Aembit, "The Strange World of Postgres TLS":
  <https://aembit.io/blog/the-strange-world-of-postgres-tls>
- PostgreSQL `sslmode`:
  <https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNECT-SSLMODE>
- PostgreSQL certificate verification semantics:
  <https://www.postgresql.org/docs/current/libpq-ssl.html#LIBQ-SSL-CERTIFICATES>
- PostgreSQL TLS protection matrix:
  <https://www.postgresql.org/docs/current/libpq-ssl.html#LIBPQ-SSL-PROTECTION>
- PostgreSQL `sslrootcert`:
  <https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNECT-SSLROOTCERT>

Currently unsupported libpq TLS parameters:

- `sslcert`:
  <https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNECT-SSLCERT>
- `sslkey`:
  <https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNECT-SSLKEY>
- `sslpassword`:
  <https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNECT-SSLPASSWORD>
- `sslcrl`:
  <https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNECT-SSLCRL>
- `sslcrldir`:
  <https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNECT-SSLCRLDIR>
- `sslsni`:
  <https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNECT-SSLSNI>
- `ssl_min_protocol_version`:
  <https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNECT-SSL-MIN-PROTOCOL-VERSION>
- `ssl_max_protocol_version`:
  <https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNECT-SSL-MAX-PROTOCOL-VERSION>
- `sslnegotiation`:
  <https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNECT-SSLNEGOTIATION>
- `sslcertmode`:
  <https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNECT-SSLCERTMODE>
- `sslkeylogfile`:
  <https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNECT-SSLKEYLOGFILE>
- `sslcompression`:
  <https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNECT-SSLCOMPRESSION>

## TLS Migration

- Replace `prefer` with `verify_full` when you want authenticated TLS, or with
  `disable` when plaintext is intentional.
- Replace `require` with `verify_full` when the server certificate should match
  the target hostname or IP. Use `verify_ca` only when hostname validation is
  intentionally not part of the deployment model.
- URL configuration now accepts only `disable`, `verify-ca`, and
  `verify-full`.
- `VerifyFull` now requires an explicit `host` or `hostaddr`. Old code paths
  that relied on an implicit local default host become configuration errors.

Examples:

```mbt check
///|
fn _tls_examples() -> (@client.Config, @client.Config) {
  let direct = @client.Config::new(
    "db.example",
    user="postgres",
    database="app",
    password="secret",
    ssl_mode=@client.SslMode::VerifyFull,
    application_name="my-service",
  )
  let routed = @client.Config::new(
    "db.example",
    hostaddr="10.0.0.15",
    user="postgres",
    database="app",
    password="secret",
    ssl_mode=@client.SslMode::VerifyFull,
    ssl_root_cert="/etc/postgres/root.crt",
    application_name="my-service",
  )
  (direct, routed)
}
```

## SCRAM Channel Binding

`channel_binding` controls SCRAM behavior only. It does not enable TLS on its
own, and it does not change non-SCRAM authentication methods.

MD5 password authentication is deprecated by PostgreSQL and is not supported by
this client. If the server requests `AuthenticationMD5Password`, `connect`
fails during startup with `ClientError::Authentication`.

This is not the same setting as TLS `sslmode`. The repository still does not
support the removed libpq-style TLS aliases `sslmode=prefer` and
`sslmode=require`. The `Prefer` and `Require` here belong only to SCRAM channel
binding.

- `ChannelBinding::Disable`: always use plain `SCRAM-SHA-256`
- `ChannelBinding::Prefer`: use `SCRAM-SHA-256-PLUS` when TLS exposes a binding
  PostgreSQL can use, otherwise fall back to plain `SCRAM-SHA-256`
- `ChannelBinding::Require`: fail unless `SCRAM-SHA-256-PLUS` is available

Use `Prefer` when you want stronger SCRAM when the deployment supports it but
do not want to reject older servers yet. Use `Require` when the deployment is
already standardized on TLS plus SCRAM channel binding and a silent fallback
would be the wrong outcome.

```mbt check
///|
fn _channel_binding_example() -> @client.Config {
  @client.Config::new(
    "db.example",
    user="postgres",
    database="app",
    password="secret",
    ssl_mode=@client.SslMode::VerifyFull,
    channel_binding=@client.ChannelBinding::Prefer,
    application_name="my-service",
  )
}
```

The pool package accepts the same setting through declarative config and through
URL parsing via the separate parameter `channel_binding=disable|prefer|require`.

Connection lifecycle APIs:

- `connect(config) -> (Client, Connection)`: open the PostgreSQL session and return the two cooperating handles
- `Connection::run(on_async?)`: own the socket, execute queued requests, and optionally forward notices / notifications / parameter updates to a callback
- `Client::close()`: request a graceful shutdown, but do not wait for the socket to close
- `Client::is_closed()`: tell whether the shared runtime is already closed
- `Client::check_connection()`: send a cheap round trip and fail if the connection is no longer healthy
- `Client::parameter(name)` and `Connection::parameter(name)`: read server parameters such as `server_version`

If you want out-of-band messages such as `LISTEN` / `NOTIFY`, parameter updates,
or PostgreSQL notices, you can consume them from the callback or from
`Connection::next_message()`:

```mbt check
///|
async fn _connection_run_example(config : @client.Config) -> Unit {
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(config)
    group.spawn_bg(() => connection.run(on_async=msg => ignore(msg)))

    let version = client.parameter("server_version")
    let pending_message = connection.next_message()
    ignore(version)
    ignore(pending_message)

    let token = client.cancel_token()
    ignore(token.process_id())
    ignore(token.secret_key())

    client.close()
  })
}
```

`Client::cancel_token()` returns a `CancelToken` that can be passed to another
task or timeout handler. `CancelToken::cancel()` opens PostgreSQL's separate
cancellation connection and asks the server to interrupt the current backend
operation.

For `LISTEN` / `NOTIFY` and notices, pick one ownership model per connection:

- pass `on_async=...` to `Connection::run(...)` when you want push-style handling
- read `Connection::next_message()` from one dedicated task when you want a
  pull-style loop

Here is the pull-style pattern:

```mbt check
///|
async fn _listen_notify_example(config : @client.Config) -> Unit {
  @async.with_task_group(group => {
    let (listener, listener_connection) = @client.connect(config)
    let (publisher, publisher_connection) = @client.connect(config)
    group.spawn_bg(() => listener_connection.run())
    group.spawn_bg(() => publisher_connection.run())

    listener.batch_execute("LISTEN jobs")
    publisher.batch_execute("NOTIFY jobs, 'ready'")

    let message = listener_connection.next_message()
    ignore(message)

    publisher.close()
    listener.close()
  })
}
```

`Client::clear_type_cache()` is rarely needed in ordinary CRUD code. It is the
escape hatch for sessions that create or alter PostgreSQL types at runtime and
want later queries to lazily reload fresh metadata.

## Parameters And Row Decoding

Query parameters implement `ToSql`. Row decoding uses `FromSql`. The package
ships built-in `ToSql` and `FromSql` implementations for:

- `Bool`
- `Int`
- `Int64`
- `UInt`
- `Float`
- `Double`
- `String`
- `Bytes`
- `T?` for any existing `ToSql` / `FromSql` codec

Typical mappings are:

| MoonBit type | PostgreSQL types |
| --- | --- |
| `Bool` | `bool` |
| `Int` | `int2`, `int4` |
| `Int64` | `int8` |
| `UInt` | `oid` |
| `Float` | `float4` |
| `Double` | `float8` |
| `String` | `text`, `varchar`, `name`, and other text-like types |
| `Bytes` | `bytea`, `uuid`, and raw byte-oriented formats |
| `T?` | `NULL` on encode, optional decode on read |

Example:

```mbt check
///|
async fn _parameter_example(client : @client.Client) -> Unit {
  let name = "moonbit"
  let params : Array[&@client.ToSql] = [name as &@client.ToSql]
  let row = client.query_one("select $1::text as value", params~)
  let value : String = row.get_name("value")
  ignore(value)
}
```

Use `Row` and `Column` like this:

- `Row::get(index)` / `Row::get_name(name)`: strongly typed decode, raising `ClientError::WrongType` or `ClientError::ColumnNotFound` on mismatch
- `Row::try_get(index)` / `Row::try_get_name(name)`: return `None` only when the index or column name is missing; SQL `NULL` handling still depends on `T` versus `T?`
- `Row::get_raw(index)` / `Row::get_raw_name(name)`: raw bytes for custom decoding
- `Row::get_text(index)` / `Row::get_text_name(name)`: shorthand for nullable text access
- `Row::len()` / `Row::index_of(name)`: inspect row shape
- `Row.columns`: full `Column` metadata for each field
- `Column.name`, `Column.table_oid`, `Column.column_id`, `Column.type_`, `Column.type_size`, `Column.type_modifier`, `Column.format`: inspect where a column came from and which wire format PostgreSQL used

If you want to stream rows incrementally:

```mbt check
///|
async fn _streaming_query_example(client : @client.Client) -> Unit {
  let stream = client.query("select generate_series(1, 3)::int4 as value")
  guard stream.next() is Some(row) else { return }
  let first_value : Int = row.get_name("value")
  let summary = stream.finish()
  ignore(first_value)
  ignore(summary.row_count)
  ignore(summary.command_tag)
}
```

Warning: if you intend to discard a `RowStream` before reading it to completion,
do not just drop it. Call `detach()` first, or later requests on the same
connection can remain blocked behind the unfinished response.

If you stop reading a `RowStream` early, either call `finish()` or `detach()`.

- `finish()` drains synchronously, returns a `QuerySummary`, and still raises a
  final database error to the caller if PostgreSQL reported one.
- `detach()` returns immediately, drains the rest in the background, skips
  decoding discarded rows, and keeps later requests moving while swallowing any
  final database error locally.

After `detach()`, the stream handle is terminal. Further `next()`, `collect()`,
or `finish()` calls raise `Closed`.

Both options release backpressure and let the driver close temporary
server-side resources created by helpers such as `query`.

### Custom codecs

Use a custom `ToSql` / `FromSql` implementation when the built-in codecs are not
enough but the PostgreSQL wire value still maps cleanly to one application type.

The direct pattern is:

1. decide which PostgreSQL OIDs the codec accepts
2. choose `WireFormat::Text` or `WireFormat::Binary`
3. write bytes in `to_sql`
4. decode bytes in `from_sql`
5. implement `from_sql_null` only when SQL `NULL` should decode into the type

This is a minimal text codec that round-trips a wrapper around `text` /
`varchar`:

```mbt check
///|
struct EmailText {
  value : String
} derive(Debug, Eq)

///|
impl @client.ToSql for EmailText with format(_, _) {
  @client.WireFormat::Text
}

///|
impl @client.ToSql for EmailText with accepts(_, type_) {
  type_.oid == @client.Type::text().oid ||
  type_.oid == @client.Type::varchar().oid
}

///|
impl @client.ToSql for EmailText with moonbit_type_name(_) {
  "EmailText"
}

///|
impl @client.ToSql for EmailText with to_sql(self, _, buf) {
  buf.write_bytes(@proto.utf8_encode(self.value))
  @proto.IsNull::No
}

///|
impl @client.FromSql for EmailText with accepts(type_) {
  type_.oid == @client.Type::text().oid ||
  type_.oid == @client.Type::varchar().oid
}

///|
impl @client.FromSql for EmailText with moonbit_type_name() {
  "EmailText"
}

///|
impl @client.FromSql for EmailText with from_sql(_, _, raw) {
  { value: @utf8.decode(raw) }
}

///|
async fn _custom_codec_example(client : @client.Client) -> Unit {
  let email : EmailText = { value: "moonbit@example.com" }
  let params : Array[&@client.ToSql] = [email as &@client.ToSql]
  let row = client.query_one("select $1::text as email", params~)
  let decoded : EmailText = row.get_name("email")
  ignore(decoded)
}
```

If the column may be `NULL`, decode as `EmailText?` or implement
`FromSql::from_sql_null(...)` yourself.

## Next APIs To Learn

The quick start only shows the smallest happy path. In real applications, the
next six APIs worth learning are these.

### `Client::query_one`

Use `query_one` when the SQL contract is "there must be exactly one row". Good
examples are:

- reading one aggregate row such as `count(*)`
- loading by primary key
- asking PostgreSQL for one session value such as `current_user`

`query_one` internally uses `query`, reads the first row, drains the stream, and
then verifies the final row count. That means you get strong shape checking and
the temporary statement is still cleaned up even if the row-count assertion
fails.

If zero rows or more than one row are returned, `query_one` raises
`ClientError::RowCount`. If the row may be absent, prefer `query_opt`.

```mbt check
///|
async fn _query_one_example(client : @client.Client) -> Unit {
  let row = client.query_one("select count(*)::int8 as count from pg_class")
  let count : Int64 = row.get_name("count")
  ignore(count)
}
```

### `Client::execute`

Use `execute` when you want the affected row count and do not care about result
rows. It is the normal choice for:

- `insert`, `update`, and `delete`
- DDL or maintenance commands where only completion matters
- parameterized commands that should not be sent with the simple protocol

`execute` prepares a temporary statement, runs it once, drains the command
completion message, converts the PostgreSQL command tag to an `Int`, and then
closes the temporary statement.

If you need multi-statement raw SQL without parameters, use `batch_execute`
instead. If you already have a reusable prepared statement, use `execute_raw`.

```mbt check
///|
async fn _execute_example(client : @client.Client) -> Unit {
  let id = 42
  let params : Array[&@client.ToSql] = [id as &@client.ToSql]
  let affected = client.execute(
    "delete from items where id = $1::int4",
    params~,
  )
  ignore(affected)
}
```

### `Client::transaction`

Use `transaction()` when several operations must succeed or fail together. The
returned `Transaction` handle is a thin guard around the client API that:

- starts with `BEGIN`
- rejects further work after `commit()` or `rollback()`
- lets you open nested transactions via PostgreSQL savepoints with `tx.transaction()`

Reach for `build_transaction()` when you need `BEGIN` options such as
`SERIALIZABLE`, `READ ONLY`, or `DEFERRABLE`.

```mbt check
///|
async fn _transaction_example(client : @client.Client) -> Unit {
  let tx = client
    .build_transaction()
    .isolation_level("SERIALIZABLE")
    .read_only()
    .deferrable()
    .start()

  let nested = tx.transaction()
  nested.batch_execute("select 1")
  nested.rollback()
  tx.commit()
}
```

Use these transaction APIs according to scope:

- `Transaction::query`, `Transaction::execute`, `Transaction::batch_execute`: run work inside the active transaction
- `Transaction::prepare`, `Transaction::bind`, `Transaction::query_portal`: advanced statement and portal usage while keeping the transaction open
- `Transaction::commit()`: commit or release the savepoint
- `Transaction::rollback()`: roll back or roll back to the savepoint

The handle does not auto-commit or auto-rollback for you. Finish it explicitly.

### `Client::prepare`

Use `prepare` when the same SQL will be executed many times. A prepared
statement lets PostgreSQL resolve parameter types and result columns once and
then reuse the named server-side statement.

The common follow-up APIs are:

- `Client::query_statement(statement, params~)`: run the statement and get a `RowStream`
- `Client::execute_raw(statement, params~)`: run the statement and get an affected-row count
- `Client::bind(statement, params~)`: create a reusable `Portal`
- `Statement::close()`: explicitly close the server-side statement when you are done

Use `prepare_typed` instead of `prepare` when PostgreSQL cannot infer parameter
types from SQL context, for example `select $1` or overloaded function calls
with no cast information.

```mbt check
///|
async fn _prepare_example(client : @client.Client) -> Unit {
  let statement = client.prepare("select $1::int4 as value")
  let value = 42
  let params : Array[&@client.ToSql] = [value as &@client.ToSql]
  let row = client.query_statement(statement, params~).collect()[0]
  let decoded : Int = row.get_name("value")
  ignore(decoded)
  statement.close()
}
```

Typed preparation looks like this:

```mbt check
///|
async fn _prepare_typed_example(client : @client.Client) -> Unit {
  let statement = client.prepare_typed("select $1 as value", [
    @client.Type::text(),
  ])
  let value = "moonbit"
  let params : Array[&@client.ToSql] = [value as &@client.ToSql]
  let row = client.query_statement(statement, params~).collect()[0]
  let decoded : String = row.get_name("value")
  ignore(decoded)
  statement.close()
}
```

When result sets are large and you want explicit fetch windows, bind the
statement into a portal and execute the portal in chunks:

```mbt check
///|
async fn _portal_example(client : @client.Client) -> Unit {
  let statement = client.prepare("select generate_series(1, 5)::int4 as value")
  let portal = client.bind(statement)
  let stream = client.query_portal(portal, 2)
  let first_row = stream.next()
  let summary = stream.finish()
  ignore(first_row)
  ignore(summary.suspended)
  portal.close()
  statement.close()
}
```

`QuerySummary.suspended == true` means PostgreSQL stopped because the portal hit
your `max_rows` limit. You can call `query_portal` again on the same portal to
continue fetching, or close the portal if you no longer need it.

### `Client::copy_in`

Use `copy_in(sql)` for bulk import with `COPY ... FROM STDIN`. It returns a
single-use `CopyInSink`:

- `CopyInSink::send(bytes_view)`: send one raw payload chunk
- `CopyInSink::finish()`: tell PostgreSQL that the stream is complete and return the inserted row count
- `CopyInSink::abort(message?)`: abort the copy with a textual error message

The package keeps payloads raw on purpose. It does not parse or produce CSV,
text, or binary formats for you. That keeps the client generic and lets the
application decide the framing.

Use `copy_in` when:

- importing many rows is more important than per-row convenience
- the data is already available as CSV, text, or PostgreSQL binary `COPY`
- you want streaming input instead of building one huge SQL statement

```mbt check
///|
async fn _copy_in_example(client : @client.Client) -> Unit {
  let sink = client.copy_in(
    "COPY items(id, name) FROM STDIN WITH (FORMAT text)",
  )
  sink.send(b"1\tmoonbit\n"[:])
  let inserted = sink.finish()
  ignore(inserted)
}
```

After `finish()` or `abort()`, the sink is closed and cannot be reused.

### `Client::copy_out`

Use `copy_out(sql)` for bulk export with `COPY ... TO STDOUT`. It returns a
`CopyOutStream` of raw payload chunks:

- `CopyOutStream::next()`: read one chunk
- `CopyOutStream::collect()`: read the rest into memory
- `CopyOutStream::finish()`: drain the stream when you stop early
- `CopyOutStream::detach()`: abandon the rest and drain in the background
- `CopyOutStream.formats`: PostgreSQL wire formats for each output column

Warning: if you intend to discard a `CopyOutStream` before it reaches the
terminal state, call `detach()` first. Dropping it early can block later
requests on the same connection.

After `detach()`, treat the `CopyOutStream` handle as closed.

Use it when:

- exporting many rows is faster as `COPY` than as row-by-row queries
- another layer already knows how to parse CSV, text, or binary `COPY`
- you want streaming backpressure instead of materializing a large result set

```mbt check
///|
async fn _copy_out_example(client : @client.Client) -> Unit {
  let stream = client.copy_out(
    "COPY (select 'moonbit'::text as name) TO STDOUT",
  )
  let chunk = stream.next()
  ignore(chunk)
  stream.finish()
}
```

## Simple Query

Use `simple_query` when you explicitly want PostgreSQL's simple protocol. That
usually means one of these cases:

- the SQL string contains multiple statements
- you want to inspect raw text-format result frames
- you want `SimpleQueryMessage::RowDescription`, `SimpleQueryMessage::Row`, and
  `SimpleQueryMessage::CommandComplete` exactly as PostgreSQL emits them

The returned `SimpleQueryStream` is lower-level than `RowStream`: every row is
text-format only, and the stream exposes statement boundaries directly.

Warning: if you intend to discard a `SimpleQueryStream` before it reaches the
terminal state, call `detach()` first. Dropping it early can block later
requests on the same connection.

If you stop early, use `finish()` when you want synchronous completion or
`detach()` when you want the remaining frames discarded in the background so
later requests can continue promptly.

After `detach()`, treat the `SimpleQueryStream` handle as closed.

```mbt check
///|
async fn _simple_query_example(client : @client.Client) -> Unit {
  let stream = client.simple_query(
    "select 'hello'::text as greeting; select 1::text as number",
  )
  let first = stream.next()
  let rest = stream.collect()
  ignore(first)
  ignore(rest)
}
```

Use `batch_execute` when you still want the simple protocol but do not need to
inspect the returned frames.

## Complete Public API Reference

This section is a compact reference for every public API in the package. Use it
when you already know the package but need a reminder of what each exported
type, method, or enum variant is for.

### Top-Level, TLS, And Config

- `connect(config)`: open a PostgreSQL session and return `(Client, Connection)`.
- `SslMode::Disable`, `SslMode::VerifyCa`, `SslMode::VerifyFull`: TLS negotiation policies.
- `ChannelBinding::Disable`, `ChannelBinding::Prefer`, `ChannelBinding::Require`: SCRAM channel-binding policies.
- `Config { host, hostaddr, port, user, database, password, ssl_mode, ssl_root_cert, channel_binding, application_name, options, connect_timeout_ms, keepalives, keepalives_idle_s }`: immutable connection settings kept both for startup and later cancellation.
- `Config::new(host, hostaddr?, user~, database?, password?, port?, ssl_mode?, ssl_root_cert?, channel_binding?, application_name~, options?, connect_timeout_ms?, keepalives?, keepalives_idle_s?)`: build a config with secure defaults and an explicit PostgreSQL `application_name`.

### Client And Connection

- `Client::batch_execute(sql)`: run one or more simple-protocol SQL commands and discard rows.
- `Client::bind(statement, params~)`: bind parameters to a prepared statement and return a reusable `Portal`.
- `Client::build_transaction()`: create a `TransactionBuilder` for custom `BEGIN` clauses.
- `Client::cancel_token()`: create a `CancelToken` for out-of-band PostgreSQL cancellation.
- `Client::check_connection()`: perform a round trip that confirms the request/response path is still healthy.
- `Client::clear_type_cache()`: drop cached user-defined type metadata and keep only built-ins.
- `Client::close()`: request graceful shutdown; wait for `Connection::run` to return if you need closure completion.
- `Client::copy_in(sql)`: start `COPY ... FROM STDIN` and return a `CopyInSink`.
- `Client::copy_out(sql)`: start `COPY ... TO STDOUT` and return a `CopyOutStream`.
- `Client::execute(sql, params~)`: execute parameterized SQL once and return affected rows.
- `Client::execute_raw(statement, params~)`: execute an already prepared statement and return affected rows.
- `Client::is_closed()`: check whether the runtime has already shut down.
- `Client::parameter(name)`: read the latest server parameter value tracked by the client.
- `Client::prepare(sql)`: prepare a statement with PostgreSQL-inferred parameter types.
- `Client::prepare_typed(sql, types)`: prepare a statement with explicit parameter types.
- `Client::query(sql, params~)`: execute SQL and stream rows through `RowStream`.
- `Client::query_one(sql, params~)`: require exactly one row.
- `Client::query_opt(sql, params~)`: require zero or one row.
- `Client::query_portal(portal, max_rows)`: execute a bound portal and stream up to `max_rows` rows for that execution.
- `Client::query_statement(statement, params~)`: execute a prepared statement and stream its rows.
- `Client::query_typed(sql, param_types, params~)`: execute SQL with explicit parameter OIDs.
- `Client::query_typed_raw(sql, param_types, params~)`: backward-compatible alias for `query_typed`; prefer `query_typed` in new code.
- `Client::simple_query(sql)`: execute SQL via the simple protocol and inspect raw text frames.
- `Client::transaction()`: begin a transaction with plain `BEGIN`.
- `Connection::next_message()`: read the next queued `AsyncMessage`, or `None` after the connection loop closes.
- `Connection::parameter(name)`: read the latest server parameter value from the connection handle.
- `Connection::run(on_async?)`: run the socket-owning event loop and optionally receive async messages via callback.
- `CancelToken::cancel()`: open PostgreSQL's separate cancellation connection and interrupt the current backend operation.
- `CancelToken::process_id()`: inspect the backend process ID embedded in the token.
- `CancelToken::secret_key()`: inspect the backend secret key embedded in the token.

### Statements, Portals, And Transactions

- `Statement { params, columns }`: a prepared statement plus PostgreSQL-resolved parameter and result metadata.
- `Statement::close()`: close the server-side prepared statement.
- `Portal { columns }`: a bound portal ready for chunked or repeated execution.
- `Portal::close()`: close the server-side portal.
- `Transaction::batch_execute(sql)`: run simple-protocol SQL inside the active transaction.
- `Transaction::bind(statement, params~)`: bind a prepared statement while the transaction is still open.
- `Transaction::commit()`: commit the transaction or release the current savepoint.
- `Transaction::execute(sql, params~)`: execute SQL inside the transaction and return affected rows.
- `Transaction::prepare(sql)`: prepare a statement while the transaction is active.
- `Transaction::query(sql, params~)`: query rows inside the transaction.
- `Transaction::query_portal(portal, max_rows)`: execute a portal while the transaction is active.
- `Transaction::rollback()`: roll back the transaction or roll back to and release the savepoint.
- `Transaction::transaction()`: create a nested transaction implemented with a PostgreSQL savepoint.
- `TransactionBuilder::deferrable(enabled?)`: set `DEFERRABLE` or `NOT DEFERRABLE`.
- `TransactionBuilder::isolation_level(level)`: set `ISOLATION LEVEL ...`.
- `TransactionBuilder::read_only(enabled?)`: set `READ ONLY` or `READ WRITE`.
- `TransactionBuilder::start()`: issue `BEGIN ...` with the accumulated options and return a `Transaction`.

### Row Streams And Row Data

- `Column { name, table_oid, column_id, type_, type_size, type_modifier, format }`: metadata for one result column.
- `QuerySummary { command_tag, row_count, suspended }`: terminal information from a `RowStream`.
- `Row { columns, values }`: one materialized row, storing both column metadata and raw field payloads.
- `Row::get(index)`: decode field `index` as `T`.
- `Row::get_name(name)`: decode the named field as `T`.
- `Row::get_raw(index)`: return the raw bytes at `index`.
- `Row::get_raw_name(name)`: return the raw bytes of the named field.
- `Row::get_text(index)`: decode a field as `String?`.
- `Row::get_text_name(name)`: decode a named field as `String?`.
- `Row::index_of(name)`: find a column index by label.
- `Row::len()`: number of columns in the row.
- `Row::try_get(index)`: return `None` if the index is out of range, otherwise decode as `T`.
- `Row::try_get_name(name)`: return `None` if the named column is absent, otherwise decode as `T`.
- `RowStream { columns }`: incremental extended-query result stream. `columns` holds the latest resolved metadata.
- `RowStream::collect()`: collect the remaining rows into memory.
- `RowStream::detach()`: abandon the remaining rows and drain in the background.
- `RowStream::finish()`: drain the stream and return a `QuerySummary`.
- `RowStream::next()`: pull the next row, or `None` after the terminal `ReadyForQuery`.

### Simple Query Protocol

- `SimpleQueryMessage::RowDescription(columns)`: announces the text columns that future `Row` messages use.
- `SimpleQueryMessage::Row(row)`: one text-format row from the simple protocol.
- `SimpleQueryMessage::CommandComplete(tag)`: one statement inside the batch finished with the given command tag.
- `SimpleQueryRow { columns, values }`: one text-format row from `SimpleQueryStream`.
- `SimpleQueryRow::get(index)`: get a nullable text field by index.
- `SimpleQueryRow::get_name(name)`: get a nullable text field by column name.
- `SimpleQueryRow::index_of(name)`: find a column index by label.
- `SimpleQueryRow::len()`: number of columns in the row.
- `SimpleQueryStream::collect()`: collect the remaining simple-query frames.
- `SimpleQueryStream::detach()`: abandon the remaining frames and drain in the background.
- `SimpleQueryStream::finish()`: drain the stream to its terminal `ReadyForQuery`.
- `SimpleQueryStream::next()`: read the next `SimpleQueryMessage`.

### COPY, Notifications, And Async Messages

- `CopyInSink::send(bytes_view)`: send one raw `COPY FROM STDIN` chunk.
- `CopyInSink::finish()`: complete the copy and return PostgreSQL's inserted row count.
- `CopyInSink::abort(message?)`: abort the copy and drain PostgreSQL's completion sequence.
- `CopyOutStream { formats }`: stream of raw `COPY TO STDOUT` chunks plus PostgreSQL column wire formats.
- `WireFormat::Text`, `WireFormat::Binary`: PostgreSQL's text and binary wire formats.
- `CopyOutStream::collect()`: collect the remaining chunks.
- `CopyOutStream::detach()`: abandon the remaining chunks and drain in the background.
- `CopyOutStream::finish()`: drain the copy stream when you stop early.
- `CopyOutStream::next()`: read the next raw copy chunk.
- `Notification { process_id, channel, payload }`: one PostgreSQL `NOTIFY` payload.
- `AsyncMessage::Notice(DatabaseError)`: PostgreSQL notice that did not fail the current request.
- `AsyncMessage::Notification(Notification)`: queued `LISTEN` / `NOTIFY` message.
- `AsyncMessage::ParameterStatus(name, value)`: server parameter update, such as `server_version`.

### Type Descriptors And Codecs

- `Type { oid, name, kind }`: stable description of a PostgreSQL type known to the client.
- `Kind::Simple`: scalar type such as `int4`.
- `Kind::Array(element_oid)`: array type descriptor.
- `Kind::Enum(labels)`: enum type with all labels cached.
- `Kind::Composite(fields)`: record-like type with named `Field` members.
- `Kind::Domain(base_oid)`: domain over another PostgreSQL type.
- `Kind::Range(subtype_oid)`: range type whose subtype OID is known.
- `Kind::Pseudo`: pseudo type such as `void`.
- `Kind::Unknown`: placeholder shape when only the OID is known.
- `Field { name, type_oid }`: one field inside `Kind::Composite`.
- `Type::bool()`, `Type::bytea()`, `Type::char()`, `Type::name_type()`, `Type::int2()`, `Type::int4()`, `Type::int8()`, `Type::oid_type()`, `Type::text()`, `Type::varchar()`, `Type::float4()`, `Type::float8()`, `Type::date()`, `Type::time()`, `Type::timestamp()`, `Type::timestamptz()`, `Type::uuid()`, `Type::json()`, `Type::jsonb()`: built-in scalar descriptors to use for explicit parameter typing or metadata inspection.
- `Type::bool_array()`, `Type::bytea_array()`, `Type::int2_array()`, `Type::int4_array()`, `Type::int8_array()`, `Type::text_array()`, `Type::varchar_array()`, `Type::float4_array()`, `Type::float8_array()`, `Type::timestamp_array()`, `Type::date_array()`, `Type::uuid_array()`, `Type::json_array()`, `Type::jsonb_array()`: built-in array descriptors.
- `Type::unknown(oid, name?)`: create a placeholder descriptor when only the OID is known.
- `ToSql`: implement this trait for custom query parameter types.
- `ToSql::format(self, type_)`: choose `WireFormat::Text` or `WireFormat::Binary`; the default is binary.
- `ToSql::accepts(self, type_)`: declare whether the encoder supports the PostgreSQL target type.
- `ToSql::moonbit_type_name(self)`: provide the MoonBit-side type name for diagnostics.
- `ToSql::to_sql(self, type_, buf)`: write the encoded payload or mark it as `NULL`.
- `FromSql`: implement this trait for custom row decoders.
- `FromSql::from_sql(type_, format, raw)`: decode a non-NULL field payload.
- `FromSql::accepts(type_)`: declare which PostgreSQL types the decoder accepts.
- `FromSql::moonbit_type_name()`: provide the decoder's MoonBit-side type name for diagnostics.
- `FromSql::from_sql_null(type_, format)`: decode SQL `NULL`; `format` is a `WireFormat`, and the default implementation raises `ClientError::Decode`.
- Built-in codec implementations exist for `Bool`, `Int`, `Int64`, `UInt`, `Float`, `Double`, `String`, `Bytes`, `Json`, `T?`, and one-dimensional `Array[T]` over supported built-in element codecs. `Array[T?]` supports SQL `NULL` elements; `Array[T]` rejects them during decoding. Array parameters and rows use PostgreSQL binary array format, and text array result decoding is intentionally not supported yet.
- The `Json` codec supports PostgreSQL `json` and `jsonb`; parameters are sent in text format, while result decoding accepts text `json`/`jsonb` and binary `jsonb`.

### Errors

- `DatabaseError { severity, code, message, detail, hint }`: structured subset of PostgreSQL `ErrorResponse` and `NoticeResponse` fields.
- `WrongTypeError { moonbit_type, postgres_type }`: describes an early driver-side type mismatch.
- `ClientError::Database(err)`: PostgreSQL returned an `ErrorResponse`.
- `ClientError::Authentication(message)`: startup authentication failed.
- `ClientError::Closed(message)`: the client, statement, portal, transaction, or copy sink is already closed.
- `ClientError::Protocol(message)`: a server reply violated protocol expectations during startup or message handling.
- `ClientError::Ssl(message)`: TLS negotiation or handshake failed.
- `ClientError::Encode(message)`: query parameter encoding failed.
- `ClientError::Decode(message)`: row decoding failed.
- `ClientError::WrongType(err)`: a `ToSql` or `FromSql` implementation rejected the PostgreSQL type.
- `ClientError::ColumnNotFound(name)`: named column lookup failed.
- `ClientError::RowCount(message)`: `query_one` or `query_opt` observed the wrong row count.
- `ClientError::UnexpectedMessage(message)`: the driver received a backend message that does not fit the current state.
