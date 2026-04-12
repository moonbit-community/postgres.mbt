# Postgres Pool

Single-event-loop PostgreSQL connection pooling for MoonBit.

Package path: `moonbit-community/postgres/pgpool`.

This package is for:

- reusing PostgreSQL sessions
- isolating long-running queries from short ones
- letting multiple async tasks talk to PostgreSQL without sharing one connection timeline

This package is not a multi-threaded throughput layer. MoonBit still runs on a
single event loop, so pool sizing should reflect session isolation needs rather
than CPU core count.

## Quick Start

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
      pool=PoolConfig::new(2),
    )
    let pool = config.create_pool(group)

    let value : Int = pool.with_client(client => {
      client.query_one("select 1::int4 as value").get_name("value")
    })
    ignore(value)

    pool.close()
  })
}
```

`Pool::with_client` is the main entry point. It avoids the usual "borrow and
forget to return" problem that shows up in MoonBit because there is no Rust
style `Drop` hook to rely on.

When one pooled operation needs explicit PostgreSQL cancellation, use
`Client::run_cancellable(...)`. The callback receives a short-lived
`OperationCancelToken` plus an `Operation` handle that keeps the cancel scope
tied to that one callback:

```mbt check
///|
async fn _pool_cancellable_example(pool : Pool) -> Unit {
  @async.with_task_group(group => {
    let result : Result[Int, Error] = try? pool.with_client(client => {
      client.run_cancellable((op, token) => {
        group.spawn_bg(no_wait=true, () => {
          @async.sleep(50)
          token.cancel()
        })
        op.query_one("select pg_sleep(5), 1::int4 as value").get_name("value")
      })
    })
    ignore(result)
  })
}
```

The pooled cancel token is best-effort and operation-scoped. After the
callback returns, later `cancel()` calls become inert, so a stale handle cannot
interrupt a later borrower that reuses the same physical PostgreSQL session.

## Choose The Checkout Style

Start with the smallest API that matches the ownership you need:

- `Pool::with_client(...)`: the normal entry point; borrow one client for one
  callback and release it automatically
- `Pool::get()`: manual lease management when the client must outlive one
  callback
- `Client::with_transaction(...)`: run one callback inside a transaction that
  auto-commits on success and rolls back best-effort on error
- `Client::with_stream(...)`, `with_simple_query(...)`, `with_copy_in(...)`,
  `with_copy_out(...)`: callback-scoped access to low-level streaming APIs
- `Client::run_cancellable(...)`: exclusive one-request-at-a-time scope with a
  cancel token

Use `Pool::get()` only when the automatic callback-scoped APIs are not enough.
The lease must be released explicitly, and any open transaction or raw stream
still belongs to that lease.

## Multi-Target Config

`pgpool.Config` is declarative. The pool normalizes it into one or more
concrete `@client.Config` targets before any network connection is opened.
`Config::new(...)` mirrors `@client.Config::new(...)` for the primary target
and then adds pool-specific multi-target options such as `hosts`, `hostaddrs`,
`ports`, `target_session_attrs`, and `load_balance_hosts`.

The practical rules are:

- `host` and `hosts` are appended together in order
- `port` is broadcast to every target when `ports` is absent
- `hostaddr` and `hostaddrs` let TCP routing differ from certificate identity
- `application_name` is required by `Config::new` and is copied to every target
- `target_session_attrs=ReadWrite` rejects a target that reports
  `transaction_read_only = on`
- `load_balance_hosts=Random` randomizes the order in which new connections try
  targets; it does not reshuffle already-open idle connections

```mbt check
///|
fn _multi_target_config() -> Config raise {
  Config::new(
    "primary.db",
    user="moon",
    dbname="app",
    application_name="my-service",
    hosts=["replica.db"],
    ports=[5432, 5432],
    target_session_attrs=TargetSessionAttrs::read_write(),
    load_balance_hosts=LoadBalanceHosts::Random,
    pool=PoolConfig::new(
      4,
      timeouts=Timeouts::new(
        wait_ms=Some(500),
        create_ms=Some(1000),
        recycle_ms=Some(250),
      ),
      queue_mode=QueueMode::lifo(),
    ),
    manager=ManagerConfig::new(recycling_method=RecyclingMethod::verified()),
  )
}
```

Use `host` / `hosts` when certificate identity matters. Add `hostaddr` only
when routing must use a different IP address than the hostname used for TLS.

## Timeouts, Queue Mode, And Recycling

`PoolConfig.max_size` is required. There is no implicit CPU-based default,
because this pool is about session isolation, not thread-per-core throughput.

`Timeouts::new(...)` controls three different waits:

- `wait_ms`: time spent waiting for pool capacity
- `create_ms`: time spent opening a new physical connection
- `recycle_ms`: time spent validating or cleaning one idle connection

`QueueMode::fifo()` reuses the oldest idle connection first.
`QueueMode::lifo()` reuses the most recently returned idle connection first.
This changes idle-connection selection only; it does not reorder tasks already
waiting in `get()`.

Recycling methods mean:

- `RecyclingMethod::fast()`: trust the idle connection as-is
- `RecyclingMethod::verified()`: run a lightweight health check
- `RecyclingMethod::clean()`: reset session state before reuse
- `RecyclingMethod::custom(sql)`: run your own cleanup SQL during checkout

Choose `fast` for simple stateless workloads, `verified` when broken idle
connections are the main concern, and `clean` when borrowers regularly leave
session-local state such as prepared statements, LISTEN state, advisory locks,
or temporary objects behind.

## Builder Hooks

`Config::builder(group)` exposes three hook points:

- `post_create`: run after a brand-new connection opens
- `pre_recycle`: run before recycle-time validation / cleanup of an idle
  connection
- `post_recycle`: run after recycling succeeded and just before checkout

Keep these hooks short and leave the session idle when they return. Good uses
are `SET search_path`, session GUCs, or a custom validation query.

```mbt check
///|
fn _pool_builder_hook_example(group : @async.TaskGroup[Unit]) -> Pool raise {
  let config = Config::new(
    "db.example",
    user="moon",
    dbname="app",
    application_name="my-service",
    pool=PoolConfig::new(2),
  )
  config
  .builder(group)
  .post_create(client => client.batch_execute("set search_path to app, public"))
  .pre_recycle(client => client.check_connection())
  .build()
}
```

## Safe API Surface

Most high-level operations on `Client`, `Operation`, and `Transaction` are
scope-safe:

- fully-drained query helpers such as `query_all`, `query_one`, `query_opt`,
  and `query_typed_all`
- command helpers such as `execute`, `batch_execute`, and `check_connection`
- transaction helpers such as `transaction`, `build_transaction`,
  `with_transaction`, and `with_savepoint`
- scope-bound prepared statement helpers such as `with_prepared(...)` and
  `with_prepared_cached(...)`
- scope-bound low-level helpers such as `with_stream(...)`,
  `with_simple_query(...)`, `with_copy_in(...)`, `with_copy_out(...)`, and
  `PreparedStatement::with_portal(...)`

There are still a few explicit ownership handoff APIs:

- `Pool::get()` requires the caller to release the lease
- `Client::transaction()` and `Transaction::transaction()` require an explicit
  `commit()` or `rollback()`
- `Client::detach_raw()` permanently removes the connection from pool management

Prepared statements are available, but only through callback-scoped
`PreparedStatement` handles. The handle is released automatically when the
callback finishes, so it cannot leak across pool reuse boundaries.

Low-level streams, portals, and `COPY` handles are available only through
callback-scoped wrappers. When the callback returns, the pool drains, aborts,
or closes unfinished protocol state before the connection becomes reusable.

`Pool::close()` rejects future checkouts immediately and closes idle
connections, but it does not revoke already borrowed clients. Those leases keep
working until they are released, and then their physical connections are closed
instead of returning to the idle pool.

## Statement Cache

Prepared-statement caching is per physical connection, not per pool. A cache hit
on one connection does not warm up other connections.

Use `with_prepared_cached(...)` when you want the pool to create or reuse one
cached statement for the current callback:

```mbt check
///|
async fn _statement_cache_example(pool : Pool) -> Unit {
  pool.with_client(client => {
    client.with_prepared_cached("select $1::int4 as value", prepared => {
      let value = 7
      let params : Array[&@client.ToSql] = [value as &@client.ToSql]
      let row = prepared.query_one(params~)
      let decoded : Int = row.get_name("value")
      ignore(decoded)
    })
  })
  |> ignore

  let cache_size = pool.with_client(client => client.statement_cache().size())
  ignore(cache_size)

  pool.manager().statement_caches().clear()
}
```

Use the handles like this:

- `client.statement_cache()`: manage the cache of the currently checked-out
  physical connection
- `transaction.statement_cache()`: same, but from inside one pooled transaction
- `pool.manager().statement_caches()`: clear or remove cached statements across
  every connection that is live right now

## Detaching A Raw Client

`Client::detach_raw()` is the escape hatch when you intentionally want to stop
using the pool for one checked-out connection.

After detaching:

- the pool frees one capacity slot immediately
- the returned `@client.Client` keeps using the existing background driver task
- the pool no longer recycles, tracks, or closes that connection for you
- you must close the raw client yourself

```mbt check
///|
async fn _detach_raw_example(pool : Pool) -> Unit {
  let lease = pool.get()
  let raw = lease.detach_raw()
  let value : Int = raw.query_one("select 1::int4 as value").get_name("value")
  ignore(value)
  raw.close()
}
```

Use this only when you really need to transfer ownership out of the pool.
