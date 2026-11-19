# PostgreSQL connection pool

`Pool` owns physical connections. Start its executor once and call `pool.ready()`
to wait for its maintenance workers. The pool opens connections on demand at
checkout. Call `pool.close()` to stop new checkouts. Sessions already checked
out can finish before the pool closes their connections.

```mbt check
///|
pub async fn example(config : @pgpool.Config) -> Unit {
  let (pool, executor) = @pgpool.Pool::create(config)
  @async.with_task_group(group => {
    group.spawn_bg(() => executor.run())
    pool.ready()
    defer pool.close()
    let row = pool.query_one(
      "select 42::int4 as value",
      deadline=@pgpool.Deadline::after_ms(1000),
    )
    assert_eq(row.get_name("value"), 42)
  })
}
```

Pool, Session, and Transaction implement `GenericClient`, with execution and
queries for all rows, exactly one row, or an optional row. These methods also
accept explicit parameter types through their typed variants. All three
handles support prepared callbacks, row streams, simple queries, and COPY in
both directions. Pool methods borrow a session automatically.

A Session or Transaction accepts one operation at a time. Overlapping calls
raise `OperationInProgress` immediately, including reentry through the outer
Session inside a transaction and through the parent Transaction inside a
savepoint. The parent becomes usable when its child ends. An escaped handle
raises `ScopeExpired`. Use separate Pool calls for concurrent database work.

The pool locks the connection for each preparation or execution. A prepared
callback can run other queries or open another prepared scope between
operations. Stream and COPY callbacks hold the connection through cleanup.
Concurrent calls to the same stream also raise `OperationInProgress`.
Call `finish()` to complete COPY IN. Scope cleanup aborts an unfinished sink.
A NUL in an abort message raises `ProtocolError::InvalidInput` locally, and
the scope can still abort the sink. A COPY transport or writer failure closes
the affected connection. The session releases its checkout slot on return,
and the pool can continue using other connections.

SQL errors from row, typed, prepared, simple-query, and COPY OUT streams leave
the session usable once the protocol reaches `ReadyForQuery` and resource
cleanup succeeds. This includes early callback return and internally detached
drains. A failed transaction requires rollback. A savepoint scope can roll
back its error and let the outer transaction continue. Returning the connection
still runs the configured reset policy.

Prepared stream errors with SQLSTATE `26000` or `0A000` invalidate the cached
statement, even when cleanup first observes the error or a callback exception
takes precedence. The next prepared scope acquires a fresh statement. The
pool leaves retries to the caller.

`Config::Config` accepts `max_backend_message_body_bytes`, defaulting to
`67_108_864` (64 MiB). It applies to every physical connection, including
startup, and counts each backend frame's body without its tag or length word.
Use a larger value for servers returning larger rows or COPY chunks. Values
outside `1..=2_147_483_642` raise `ConfigError::InvalidConfig` at construction.
An invalid header or an oversized body closes that connection with
`ClientError::Protocol`. The limit applies to each frame, so results and the
pool can consume more memory in total.

`scram_max_iterations` defaults to `100_000` on all physical connections. Raise
it explicitly on `Config::Config` for a server using a higher SCRAM iteration
count. The valid range is `1..=2_147_483_647`. Invalid settings raise
`ConfigError::InvalidConfig` at construction.
Excessive or malformed server counts fail authentication before PBKDF2 begins.
Computation yields between bounded batches, so connection/create deadlines and
cancellation can stop authentication without sending an incomplete proof.

## Transactions

Callbacks return `Result[T, E]`. `Ok(value)` requests commit or savepoint
release. `Err(error)`, exceptions, and task cancellation request rollback.
Without task cancellation, a business `Err` is returned even if rollback
cleanup fails. The scope manages completion.

Finish all child tasks before returning from a transaction or savepoint callback.
If a prepared, stream, COPY, or query task is still active when the callback
exits, the pool closes the physical connection without sending completion
SQL. An `Ok` return raises `OperationInProgress`. A business `Err`, exception,
cancellation, or deadline error keeps its original result. A started
transaction records `OutcomeUnknown`, and diagnostics retain
`OperationInProgress`. Escaped tasks can outlive the scope. Their handles expire
and their cleanup can only reach the retired connection.

```mbt check
///|
pub async fn transaction_example(pool : @pgpool.Pool) -> Result[Int32, String] {
  let record = @pgpool.TransactionRecord()
  let result = pool.with_transaction(
    tx => {
      tx.batch_execute("SET LOCAL statement_timeout = '1s'")
      let value : Int32 = tx
        .query_one("select 7::int4 as value")
        .get_name("value")
      if value < 0 {
        Err("invalid value")
      } else {
        Ok(value)
      }
    },
    record~,
  )
  assert_eq(record.status(), Committed)
  result
}
```

`TransactionRecord` is optional, one-shot storage that can be read synchronously
outside the cancelled task. Statuses are `NotStarted`, `InProgress`, `Committed`,
`RolledBack`, `SavepointReleased`, and `OutcomeUnknown`. `SavepointReleased`
records completion of the child scope only. Reusing a record raises
`TransactionRecordUsed`.

The server command tag decides commit and savepoint release. Without task
cancellation, a ROLLBACK tag in response to COMMIT raises `CommitRolledBack`.
If COMMIT or RELEASE may have been sent and the pool receives no decisive tag,
it retires the connection and records `OutcomeUnknown`. It propagates an
explicit PostgreSQL error if one arrived, or raises `CommitOutcomeUnknown`
otherwise. It sends no follow-up ROLLBACK on that connection. A confirmed
COMMIT stays recorded if the connection fails before protocol synchronization.
Check the record when task cancellation prevents you from receiving the result.

## Deadlines and cleanup

`Deadline::after_ms` uses the async runtime's clock. Optional `deadline` arguments
cover executor readiness, capacity wait, health checks, host attempts, connection
startup, hooks and SQL. Child scopes inherit deadlines and can only shorten
them. There is no default SQL duration limit. `with_session` and Pool convenience
methods accept a per-call `timeouts` record. `wait_ms` covers both executor
readiness and capacity. Zero polls without waiting. Create and recycle
timeouts limit their respective phases. All host attempts in one checkout
share the create deadline.

On cancellation or timeout, the pool blocks further business requests. If a
request may be active, it sends PostgreSQL CancelRequest and waits for the
cancellation connection to close. Before reusing the session, it also drains
the original response to confirm protocol synchronization. The pool leaves
retries to the caller.

Drain, rollback, and reset share `cleanup_ms`, which defaults to 5000.
The pool also cleans up on normal scope exit. It retires the connection if
cleanup fails, protocol synchronization cannot be confirmed, or the budget
expires.
SQL errors reported after successful stream cleanup do not count as cleanup
failures. Temporary-statement Close results, including failures, are retained
so a repeated finish cannot turn failed cleanup into success.
Stream and COPY method deadlines use the same supervision and cleanup budget,
including protected I/O such as closing a temporary statement. A method timeout
returns `Timeout(Query)` after cancellation and protocol cleanup complete, or
after the cleanup budget expires and the connection is aborted. The method's
gate is released only after its worker exits. The connection is available to
another borrower only after the owning scope finishes cleanup.
The completion bound applies to library I/O. Application callbacks must
cooperate with async cancellation. Cleanup errors are diagnostic events and do
not replace an earlier database error, business `Err`, or callback exception.

Transactions, prepared handles, stream/COPY scopes, and session return check
for cancellation after protected cleanup, before reporting a normal return or
completion error.
This includes COMMIT, savepoint RELEASE/rollback, stream drain, statement Close,
`DISCARD ALL` and session initialization.

| Callback exit | Behavior after cleanup |
| --- | --- |
| Normal return, cancellation during cleanup | Propagate native cancellation, even if cleanup fails. An ordinary `catch` cannot resume caller code. |
| Normal return, no cancellation | Return the value or report the scope's completion error. Report session-return failures through diagnostics and preserve a transaction business `Err`. |
| Exception | Preserve the original callback exception over later cancellation or cleanup errors. |
| Native cancellation | Finish cleanup and continue propagating native cancellation. |

A transaction business `Err` is a normal callback return requesting rollback,
so cancellation during rollback still takes precedence. The pool writes the
`TransactionRecord` before propagating cancellation and retains confirmed
`Committed`, `RolledBack`, and `SavepointReleased` statuses. Enclosing scopes
share the remaining cleanup budget during cancellation, even when a child's
cleanup succeeded.

## Session isolation and hooks

`HealthCheck` (`Passive`, `Active`, or `Custom(sql)`) validates connections on
checkout of an idle connection. The default is `Active`. On return, the pool
applies `ResetPolicy`.

- With `DiscardAll` (default), synchronize protocol, roll back unfinished transactions,
  execute `DISCARD ALL` outside a transaction, clear statement/type caches,
  restore the application baseline, then make capacity available.
- With `PreserveSession`, synchronize and roll back unfinished transactions while
  retaining session state, including prepared statements. Choose this explicitly
  for persistent LISTEN or other intentional affinity across borrows.
- With `Reconnect`, retire the connection on return. Use this for extension
  state that standard SQL cannot reliably reset.

`PoolOptions::initialize_session` receives a scoped Session on new connections
and after full reset. Use it to restore application settings. `before_acquire`
runs before every checkout. A hook error or a hook leaving an open transaction
ends that acquisition, as does a hook leaving an operation active. An
initialization failure during return retires the connection and emits an event
while preserving the business result. Use transaction-local `SET LOCAL` for
temporary settings.

`DISCARD ALL` clears server prepared statements, so the default cache is useful
within a lease and clears between borrowers. FIFO or LIFO idle queue order
determines which idle connection the pool checks out next.

## Diagnostics

`next_event()` receives structured events for connection attempts/replacement,
health checks, hooks, cancellation, cleanup and transaction completion. Events
carry connection, scope and request identifiers where applicable, phase, target,
elapsed time and original errors. The default buffer holds 256 events; oldest
events are dropped on overflow and `dropped_events()` counts them. Transaction
records remain available independently. When checkout reports
`AcquireError::AttemptsFailed`, its attempt list retains the targets, phases,
elapsed time, and original causes of failed health checks and connections.

See the PostgreSQL documentation for
[cancellation](https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-CANCELING-REQUESTS)
and [DISCARD ALL](https://www.postgresql.org/docs/current/sql-discard.html).
