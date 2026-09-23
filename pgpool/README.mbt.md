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
      host,
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

On normal callback return, the helper commits only if the transaction is still
open; an explicit commit or rollback prevents a second completion. If the
callback raises or is cancelled, it rolls back best-effort when the transaction
is still open. Nested transactions use savepoints. Rollback cleanup is
protected from cancellation, including the wait for in-flight operations. A
captured `Transaction` is expired when its callback completes.

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

`pgpool.Config` normalizes one or more PostgreSQL targets into concrete
`@client.Config` values. It supports host/hostaddr lists, per-target ports,
`TargetSessionAttrs`, host load balancing, TLS, authentication, startup
parameters, and `PoolConfig`.

A single host, hostaddr, or port is broadcast across the inferred target count.
Multi-value arrays must have matching lengths. Normalization rejects ports
outside the inclusive range from `1` through `65535` and, under `VerifyFull`,
any target without a non-empty host or hostaddr before opening a socket.

`PoolConfig` controls:

- `max_size`
- checkout/create/recycle timeouts
- FIFO or LIFO idle-connection selection
- fast, verified, clean, or custom recycling
- per-connection statement-cache capacity

`PoolOptions` provides `post_create`, `pre_recycle`, and `post_recycle` hooks.
Hooks receive the raw `@client.Client`; keep them short and leave the session
idle when they return.

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
