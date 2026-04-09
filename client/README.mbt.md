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
      "127.0.0.1",
      user="postgres",
      database="app",
      password="secret",
      port=5432,
      ssl_mode=@client.SslMode::disable(),
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
    "127.0.0.1",
    user="postgres",
    database="app",
    password="secret",
    port=5432,
    ssl_mode=@client.SslMode::prefer(),
    application_name="my-service",
  )
}
```

`Config` stores:

- `host`: PostgreSQL host name or IP
- `port`: PostgreSQL port, default `5432`
- `user`: login role
- `database`: database name, default is the same as `user`
- `password`: optional password
- `ssl_mode`: `SslMode::Disable`, `SslMode::Prefer`, or `SslMode::Require`
- `application_name`: value visible in PostgreSQL session metadata

Use the `SslMode` helpers when you want a constructor-style API:

- `SslMode::disable()`: never attempt TLS
- `SslMode::prefer()`: try TLS first, but fall back to plain TCP if the server says no
- `SslMode::require()`: fail the connection if TLS cannot be established

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
- `Column.name`, `Column.table_oid`, `Column.column_id`, `Column.type_`, `Column.type_size`, `Column.type_modifier`, `Column.format`: inspect where a column came from and how PostgreSQL encoded it

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

If you stop reading a `RowStream` early, call `finish()`. It drains the
remaining protocol messages, releases backpressure, and lets the driver close
temporary server-side resources created by helpers such as `query`.

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
- `CopyOutStream.formats`: PostgreSQL format codes for each output column

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
- `SslMode::Disable`, `SslMode::Prefer`, `SslMode::Require`: TLS negotiation policies.
- `SslMode::disable()`, `SslMode::prefer()`, `SslMode::require()`: convenience constructors for those policies.
- `Config { host, port, user, database, password, ssl_mode, application_name }`: immutable connection settings kept both for startup and later cancellation.
- `Config::new(host, user~, database?, password?, port?, ssl_mode?, application_name?)`: build a config with defaults that fit local development.

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
- `SimpleQueryStream::finish()`: drain the stream to its terminal `ReadyForQuery`.
- `SimpleQueryStream::next()`: read the next `SimpleQueryMessage`.

### COPY, Notifications, And Async Messages

- `CopyInSink::send(bytes_view)`: send one raw `COPY FROM STDIN` chunk.
- `CopyInSink::finish()`: complete the copy and return PostgreSQL's inserted row count.
- `CopyInSink::abort(message?)`: abort the copy and drain PostgreSQL's completion sequence.
- `CopyOutStream { formats }`: stream of raw `COPY TO STDOUT` chunks plus PostgreSQL column format codes.
- `CopyOutStream::collect()`: collect the remaining chunks.
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
- `Type::bool_array()`, `Type::bytea_array()`, `Type::int2_array()`, `Type::int4_array()`, `Type::int8_array()`, `Type::text_array()`, `Type::varchar_array()`, `Type::float4_array()`, `Type::float8_array()`, `Type::timestamp_array()`, `Type::date_array()`, `Type::uuid_array()`: built-in array descriptors.
- `Type::unknown(oid, name?)`: create a placeholder descriptor when only the OID is known.
- `ToSql`: implement this trait for custom query parameter types.
- `ToSql::format(self, type_)`: choose text (`0`) or binary (`1`) wire format; the default is binary.
- `ToSql::accepts(self, type_)`: declare whether the encoder supports the PostgreSQL target type.
- `ToSql::moonbit_type_name(self)`: provide the MoonBit-side type name for diagnostics.
- `ToSql::to_sql(self, type_, buf)`: write the encoded payload or mark it as `NULL`.
- `FromSql`: implement this trait for custom row decoders.
- `FromSql::from_sql(type_, format, raw)`: decode a non-NULL field payload.
- `FromSql::accepts(type_)`: declare which PostgreSQL types the decoder accepts.
- `FromSql::moonbit_type_name()`: provide the decoder's MoonBit-side type name for diagnostics.
- `FromSql::from_sql_null(type_, format)`: decode SQL `NULL`; by default this raises `ClientError::Decode`.
- Built-in codec implementations exist for `Bool`, `Int`, `Int64`, `UInt`, `Float`, `Double`, `String`, `Bytes`, and `T?`.

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
