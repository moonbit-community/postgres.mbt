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
    let config = Config::new(
      host,
      user~,
      dbname=database,
      password~,
      application_name="my-service",
      pool=PoolConfig::new(4),
    )
    let pool = Pool::new(config, group)
    let value : Int = pool
      .query_one("select 1::int4 as value")
      .get_name("value")
    ignore(value)
    pool.close()
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
async fn _session_example(pool : Pool) -> Int {
  pool.with_session(session => {
    session.batch_execute("set application_name = 'pool-example'")
    session.query_one("select 42::int4 as value").get_name("value")
  })
}
```

`Session` replaces the former pooled `Client` name. A session is valid only
during its callback. Captured handles used afterwards raise
`PoolError::ScopeExpired`.

Calls submitted through one `Session` execute FIFO. Do not capture the outer
session and wait on it from inside a transaction, prepared-statement, or
cancellable callback: use the capability passed to that callback.

## Transactions

Pool and session transaction helpers reserve one physical connection for the
callback:

```mbt check
///|
async fn _pool_transaction(pool : Pool) -> Unit {
  pool.with_transaction(tx => {
    ignore(tx.execute("update accounts set active = true"))
    ()
  })
}
```

The callback commits on success and rolls back best-effort on error. Nested
transactions use savepoints. A captured `Transaction` is expired when its
callback completes.

## Streaming And COPY

Low-level protocol handles are callback-scoped so the pool can restore the
connection before reuse:

- `Session::with_stream` and `with_typed_stream` receive
  `@client.RowStream`
- `Session::with_simple_query` receives `@client.SimpleQueryStream`
- `Session::with_copy_in` receives `@client.CopyInSink`
- `Session::with_copy_out` receives `@client.CopyOutStream`

The callbacks may consume, finish, abort, or detach their handles. On callback
exit, the pool waits for required cleanup before recycling the connection.
There are no duplicate pgpool stream, portal, or COPY wrapper types.

## Prepared Statements And Cache

`Session::with_prepared` and `with_prepared_typed` provide a scoped
`PreparedStatement`. It supports fully consumed query/execute helpers and
`with_stream`; explicit bind, pooled portals, and manual close are not exposed.

Ordinary query, execute, and streaming helpers use prepared statements cached
automatically per physical connection. Configure the LRU capacity through
`PoolConfig::new`:

```mbt check
///|
fn _pool_config() -> PoolConfig raise {
  PoolConfig::new(
    8,
    statement_cache_capacity=100,
    timeouts=Timeouts::new(wait_ms=Some(500)),
    queue_mode=QueueMode::fifo(),
    recycling_method=RecyclingMethod::verified(),
  )
}
```

The default capacity is `100`. Set it to `0` to disable caching; negative
values raise `PoolError::InvalidConfig`. Cache entries are local to one
physical connection. Typed parameter arrays are copied when inserted, so later
caller mutation cannot rewrite a cache key. There are no public cache-manager
or cache-handle APIs.

Invalid-statement SQLSTATE `26000` and unsupported-plan SQLSTATE `0A000`
invalidate the affected entry and propagate the original database error. The
pool does not retry automatically inside a transaction.

## Operation-Scoped Cancellation

Use `Session::run_cancellable` when cancellation must be tied to one pooled
operation:

```mbt check
///|
async fn _cancellable(pool : Pool) -> Unit {
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

## Configuration

`pgpool.Config` normalizes one or more PostgreSQL targets into concrete
`@client.Config` values. It supports host/hostaddr lists, per-target ports,
`TargetSessionAttrs`, host load balancing, TLS, authentication, startup
parameters, and `PoolConfig`.

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

A custom `Connector` receives `(Config, TaskGroup[Unit])` and returns an
already-driven `@client.Client`.

## Lifecycle And Errors

`Pool::close()` rejects new operations and closes idle connections. Active
callbacks are allowed to clean up; their physical connections close instead of
returning to the idle set.

`Pool::resize()` never interrupts checked-out sessions. When shrinking cannot
remove enough currently available capacity tokens, the pool records resize
debt; later failed checkouts and session returns repay that debt before making
tokens available. Expanding first cancels debt and adds only the remaining
capacity, preventing shrink/expand races from exceeding the configured maximum.

`PoolError` is limited to pool lifecycle:

- `Closed`
- `Timeout`
- `ScopeExpired`
- `InvalidConfig`

Database, decoding, and row-count errors are propagated as
`@client.ClientError`.
