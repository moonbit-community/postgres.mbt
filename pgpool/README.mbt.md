# Postgres Pool

Single-event-loop PostgreSQL connection pooling for MoonBit.

Package path: `moonbit-community/postgres/pgpool`.

The package supports `native` and classic `wasm`. WasmGC is intentionally
excluded because pooled clients require the socket/TLS transport.

Each physical `@client.Client` is single-flight. The pool supplies concurrency
by checking out different sessions, while preserving FIFO execution within one
callback-scoped `Session`.

## Quick Start

For ordinary fully consumed operations, call the pool directly:

```mbt check
///|
async fn _pool_quick_start(
  host : String,
  user : String,
  database : String,
  password : String,
) -> Unit {
  @async.with_task_group(group => {
    let config = @pgpool.Config::Config(
      [@pgpool.ConnectionTarget(host~)],
      user~,
      dbname=database,
      password~,
      application_name="my-service",
      pool=PoolConfig(4),
    )
    let (pool, executor) = @pgpool.Pool::create(config)
    let task = group.spawn(no_wait=true, () => executor.run())
    pool.ready()
    let value : Int = pool
      .query_one("select 1::int4 as value")
      .get_name("value")
    ignore(value)
    pool.close()
    task.wait()
  })
}
```

Pool-level operations automatically checkout, use, and return a connection:

- `query_all`, `query_one`, `query_opt`, and `query_typed_all`
- `execute` and `batch_execute`
- `check_connection`
- `with_transaction`

There is no manual `get` / `release` / `detach_raw` API.

## Session-Scoped Work

Use `Pool::with_session` when several operations must use the same PostgreSQL
session:

```mbt check
///|
async fn _session_example(pool : @pgpool.Pool) -> Int {
  pool.with_session(session => {
    session.batch_execute("set application_name = 'pool-example'")
    session.query_one("select 42::int4 as value").get_name("value")
  })
}
```

`Session` replaces the former pooled `Client` name. A session is valid only
during its callback. Captured handles used afterwards raise
`PoolError::ScopeExpired`.

Calls submitted through one `Session` execute FIFO. A prepared-statement
callback may use the same `Session` for other SQL or nested `with_prepared`
calls. Transaction, streaming/COPY, and cancellable callbacks keep an exclusive
session operation until their protocol work finishes, so use the capability
passed to those callbacks.

## Transactions

Pool and session transaction helpers reserve one physical connection for the
callback:

```mbt check
///|
async fn _pool_transaction(pool : @pgpool.Pool) -> Unit {
  pool.with_transaction(tx => {
    ignore(tx.execute("update accounts set active = true"))
    ()
  })
}
```

Pool transaction options use the `client` isolation enum re-exported as
`@pgpool.IsolationLevel`; existing enum constructor calls remain valid. The
isolation level is selected from four fixed SQL spellings:

```mbt check
///|
async fn _pool_serializable_transaction(pool : @pgpool.Pool) -> Unit {
  pool.with_transaction(
    _tx => (),
    options=@pgpool.TransactionOptions(
      isolation_level=@pgpool.IsolationLevel::serializable(),
    ),
  )
}
```

On normal callback return, the helper commits only if the transaction is still
open; an explicit commit or rollback prevents a second completion. If the
callback raises or is cancelled, it rolls back best-effort when the transaction
is still open. Nested transactions use savepoints. Rollback cleanup is
protected from cancellation, including the wait for in-flight operations. A
captured `Transaction` is expired when its callback completes.

`with_savepoint(name, ...)` quotes `name` as a case-sensitive PostgreSQL
identifier. Spaces, double quotes, semicolons, and Unicode are supported.
Empty names and names containing NUL raise the client's
`InvalidSavepointName` error before SQL is sent; the parent remains usable.

Cancellation received while SQL is waiting for a response propagates after
protected protocol cleanup and before automatic commit. This includes nested
savepoints. If cancellation arrives during `BEGIN` or `SAVEPOINT`, successful
creation is rolled back before releasing the session or parent scope. A
`COMMIT` already sent still completes according to PostgreSQL's response.

## Streaming And COPY

Low-level protocol handles are callback-scoped so the pool can restore the
connection before reuse:

- `Session::with_stream` and `with_typed_stream` receive
  `@client.RowStream`
- `Session::with_simple_query` receives `@client.SimpleQueryStream`
- `Session::with_copy_in` receives `@client.CopyInSink`
- `Session::with_copy_out` receives `@client.CopyOutStream`

The callbacks may consume, finish, abort, or detach their handles. They remain
cancellable while waiting for application work. On callback exit, the pool
drains streams or aborts unfinished COPY input before recycling the connection;
task cancellation may therefore wait for an in-flight database response.
There are no duplicate pgpool stream, portal, or COPY wrapper types.

An aborted connection's detached drain saves `ClientError::Closed`, which an
explicit `finish()` rethrows. Expected closure does not fail other connections
in the same task group; unexpected protocol errors still propagate.

## Prepared Statements And Cache

`Session::with_prepared` and `with_prepared_typed` provide a scoped
`PreparedStatement`. It supports fully consumed query/execute helpers and
`with_stream`; explicit bind, pooled portals, and manual close are not exposed.
Inspect inferred parameter and result metadata through its read-only
`params()` and `columns()` views. Use `to_owned()` for an editable copy.
The callback remains cancellable and does not hold the Session operation lock.
On exit, the scope rejects new calls, waits for calls already started, then
closes a temporary or evicted statement. Transaction-scoped prepared callbacks
remain exclusive to their transaction.

Ordinary query, execute, and streaming helpers use prepared statements cached
automatically per physical connection. Configure the LRU capacity through
`PoolConfig::PoolConfig`:

```mbt check
///|
fn _pool_config() -> @pgpool.PoolConfig raise {
  PoolConfig(
    8,
    statement_cache_capacity=100,
    timeouts=Timeouts(wait_ms=Some(500)),
    queue_mode=@pgpool.QueueMode::fifo(),
    recycling_method=@pgpool.RecyclingMethod::verified(),
  )
}
```

The default capacity is `100`. Set it to `0` to disable caching; negative
values raise `PoolError::InvalidConfig`. Cache entries are local to one
physical connection. Typed parameter arrays are copied when inserted, so later
caller mutation cannot rewrite a cache key. There are no public cache-manager
or cache-handle APIs. Clean recycling preserves prepared statements and their
cached plans, keeping the connection-local cache reusable across checkouts.

Invalid-statement SQLSTATE `26000` and unsupported-plan SQLSTATE `0A000`
invalidate the affected entry and propagate the original database error. The
pool does not retry automatically inside a transaction.

## Operation-Scoped Cancellation

Use `Session::run_cancellable` when cancellation must be tied to one pooled
operation:

```mbt check
///|
async fn _cancellable(pool : @pgpool.Pool) -> Unit {
  @async.with_task_group(group => {
    ignore(
      pool.with_session(session => {
        session.run_cancellable((op, token) => {
          group.spawn_bg(no_wait=true, () => {
            @async.sleep(50)
            token.cancel()
          })
          let value : Int = op
            .query_one("select pg_sleep(5), 1::int4 as value")
            .get_name("value")
          ignore(value)
        })
      }),
    ) catch {
      _ => ()
    }
  })
}
```

`OperationCancelToken` is best-effort and becomes inert when its callback
ends, preventing a stale token from cancelling work performed by a later
borrower.

The `run_cancellable` callback remains cancellable while waiting for
application work. Before releasing its exclusive session operation, the scope
waits for in-flight requests and any cancel packet already being sent.

Queued requests keep FIFO order while waiting for a previous cancel send to
finish. The next request is marked active only after that wait, so a delayed
cancel cannot spill into the next request. Cancelling a waiter releases its
place and any acquired operation lock.

Ordinary task cancellation waits for required protocol cleanup and rollback;
it does not automatically send a PostgreSQL cancellation request or retry SQL.
Cancellation is checked again when the outermost protected operation ends.
Explicit caller protection defers cancellation further. Use explicit `abort()`
on a raw client when the physical connection must be stopped immediately.

## Configuration

`pgpool.Config` takes a non-empty array of `ConnectionTarget` records. Each
record supplies a `host`, a `hostaddr`, or both, plus its own port (default
`5432`). If both addresses are present, the client connects to `hostaddr` and
uses `host` for TLS hostname verification. The order of records is the order
of connection attempts unless host load balancing is enabled.

`Config::Config` validates every address and port, the user and database names,
and TLS settings before the pool is created. A target needs at least one
non-empty address, and its port must be in `1..65535`. Errors identify the
zero-based target index. The constructor copies the supplied array; `targets()`
returns a read-only view of that snapshot. Common authentication, TLS, startup,
`TargetSessionAttrs`, host load balancing, and `PoolConfig` options stay on the
outer config.

`PoolConfig` controls:

- `max_size`
- checkout/create/recycle timeouts
- FIFO or LIFO idle-connection selection
- fast, verified, clean, or custom recycling
- per-connection statement-cache capacity
- shared asynchronous-message capacity (256 by default)

The default `Fast` mode sends no cleanup SQL when an idle connection is
checked out. On every `Session` return, the pool checks the client's latest
`ReadyForQuery` status. A connection still in an active (`T`) or failed (`E`)
transaction is discarded, along with its statement cache, instead of being
offered to the next borrower. The pool does not issue an automatic `ROLLBACK`.
Idle connections retain session state such as `SET` values and `LISTEN`
subscriptions under `Fast`; select `Clean` when that state must be cleared.

`PoolOptions` provides `post_create`, `pre_recycle`, and `post_recycle` hooks.
Hooks receive an `Operation` that expires when the callback ends. Queries and
commands issued through it finish before the next borrower uses the connection.
Hooks must leave the connection transaction idle. A `post_create` hook that
leaves a transaction open raises `PoolError::HookLeftOpenTransaction` and
discards the connection; recycle hooks discard the connection and retry with a
new one. Custom `Connector` remains a low-level entry that returns a raw Client.

`Pool::next_message()` reads notices, notifications, and parameter changes
from one shared bounded buffer. Each `PoolAsyncMessage` includes a unique
physical `connection_id` and the `message`. Use one consumer. When the buffer
fills, the oldest message is discarded and
`Pool::dropped_async_messages()` increases. `PoolConfig::PoolConfig` accepts a
positive `async_message_capacity`; the default is 256. After `Pool::close()`,
buffered messages can still be read, then `next_message()` returns `None`.

Create and recycle deadlines are hard for client I/O: when either expires, the
pool first calls `Client::abort()` on the candidate physical connection and
then reports `PoolError::Timeout(Create)` or retires the timed-out recycle
candidate. Custom connector code before it returns a `Client`, and hook code
that does not perform client I/O, must still cooperate with ordinary task
cancellation.

If checkout is cancelled during recycling, including either recycle hook, the
pool discards that connection and its statement cache and restores the reserved
capacity slot. A later checkout can open a replacement connection.

A custom `Connector` receives a `@client.Config` and returns a
`(@client.Client, @client.ClientExecutor)` pair. The pool executor starts the
physical executor and checkout waits for `client.ready()`.

## Lifecycle And Errors

`Pool::create()` does not open a socket. Spawn the single-use `PoolExecutor::run()`
and await `pool.ready()` before use. A repeated `run()` raises
`PoolError::ExecutorAlreadyStarted`. `Pool::close()` rejects new operations and
closes idle connections. Active callbacks are allowed to finish; their physical
connections close instead of returning to the idle set. Await the executor task
to know that all connections have stopped. Cancellation or an unexpected
background connection failure closes the whole pool.

`Pool::resize()` never interrupts checked-out sessions. When shrinking cannot
remove enough currently available capacity tokens, the pool records resize
debt; later failed checkouts and session returns repay that debt before making
tokens available. Expanding first cancels debt and adds only the remaining
capacity, preventing shrink/expand races from exceeding the configured maximum.

`PoolError` is limited to pool lifecycle:

- `Closed`
- `ExecutorAlreadyStarted`
- `Timeout`
- `ScopeExpired`
- `InvalidConfig`

Database, decoding, and row-count errors are propagated as
`@client.ClientError`.
