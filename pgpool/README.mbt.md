# PostgreSQL connection pool

`Pool` owns physical connections. Start its executor once, await readiness, and
close the pool when finished.

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

Pool, Session and Transaction implement `GenericClient`, including typed
all/one/optional queries and execution. Pool convenience methods borrow a
session automatically. Session and Transaction also support prepared callbacks,
row streams, simple queries and both COPY directions.

A Session or Transaction accepts one operation at a time. Overlapping calls
raise `OperationInProgress` immediately, including reentry through the outer
Session inside a transaction and through the parent Transaction inside a
savepoint. The parent becomes usable when its child ends. An escaped handle
raises `ScopeExpired`. Use separate Pool calls for concurrent database work.

Prepared callbacks do not occupy the connection: other queries and prepared
callbacks can compose within them. Each actual preparation or execution is
exclusive. Stream and COPY callbacks hold the connection until their scope
ends. Their handles are pool-owned capabilities; concurrent calls to one stream
also raise `OperationInProgress`. COPY IN requires `finish()` to accept input;
an unfinished sink is aborted on scope exit.

SQL errors from row, typed, prepared, simple-query and COPY OUT streams leave
the session usable once the protocol reaches `ReadyForQuery` and resource
cleanup succeeds. This also applies when the callback stops reading early or
the remaining results drain in the background. A failed transaction still
requires rollback; a savepoint scope can roll back its error and let the outer
transaction continue. Returning the connection to the pool still runs its
configured reset policy.

Prepared stream errors with SQLSTATE `26000` or `0A000` invalidate the cached
statement. The next prepared scope acquires a fresh statement; failed SQL is
never automatically retried. Invalidation also happens when scope cleanup first
observes the error or a callback exception takes precedence.

## Transactions

Callbacks return `Result[T, E]`. `Ok(value)` requests commit; `Err(error)` requests
rollback and returns the same business error. Exceptions and task cancellation
request rollback. Transaction handles have no public `commit` or `rollback`.

Finish all child tasks before returning from a transaction or savepoint callback.
Leaving a prepared, stream, COPY or query task active is a scope usage error:
the pool closes the physical connection before sending COMMIT or RELEASE
SAVEPOINT. An `Ok` return raises `OperationInProgress`; a business `Err`,
exception, cancellation or deadline error keeps its original result. A started
transaction records `OutcomeUnknown`, since closing the connection does not
acknowledge rollback, and diagnostics retain `OperationInProgress`. The pool
does not wait for escaped application tasks; later calls through their handles
fail, and their cleanup cannot reach a new borrower's connection. Callbacks
whose child tasks finish normally keep the usual commit and reuse behavior.

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
  assert_eq(record.status(), @pgpool.TransactionStatus::Committed)
  result
}
```

`TransactionRecord` is optional, one-shot storage that can be read synchronously
outside the cancelled task. Statuses are `NotStarted`, `InProgress`, `Committed`,
`RolledBack`, `SavepointReleased`, and `OutcomeUnknown`. Savepoint release does
not mean the top-level transaction committed. Reusing a record raises
`TransactionRecordUsed`.

The server command tag decides completion. COMMIT returning ROLLBACK raises
`CommitRolledBack`. A possibly sent COMMIT without a decisive response raises
`CommitOutcomeUnknown` and retires the connection. The library does not follow
that uncertain COMMIT with ROLLBACK. A confirmed COMMIT remains recorded even
when the connection fails before protocol synchronization. Task cancellation
can still be observed after a confirmed commit: inspect the record to determine
what happened.

## Deadlines and cleanup

`Deadline::after_ms` uses the async runtime's clock. Optional `deadline` arguments
cover executor readiness, capacity wait, health checks, host attempts, connection
startup, hooks and SQL. Child scopes inherit deadlines and can only shorten
them. There is no default SQL duration limit. `with_session` and Pool convenience
methods accept a per-call `timeouts` record. `wait_ms` covers both executor
readiness and capacity; zero polls without waiting. Create and recycle timeouts
are additional phase limits, not fresh total budgets for each host.

Task cancellation and deadlines automatically supervise active SQL. The library
prevents subsequent business requests, sends a PostgreSQL CancelRequest when a
request may be active, waits for the cancellation connection to close, and
synchronizes the original protocol before allowing reuse. CancelRequest alone
does not confirm the SQL stopped. Already-sent SQL is never replayed.

Drain, rollback and reset share a finite cleanup budget: `cleanup_ms` defaults
to 5000. Cleanup failures, untrusted protocol state and expired cleanup budgets
abort and retire the connection. Cleanup also runs on normal scope exit.
SQL errors reported after successful stream cleanup do not count as cleanup
failures. Temporary-statement Close results, including failures, are retained
so a repeated finish cannot turn failed cleanup into success.
Stream and COPY method deadlines use the same supervision and cleanup budget,
including protected I/O such as closing a temporary statement. A method timeout
returns `Timeout(Query)` after cancellation and protocol cleanup complete, or
after the cleanup budget expires and the connection is aborted. The method's
gate is released only after its worker exits; the connection is available to
another borrower only after the owning scope finishes cleanup.
The completion bound applies to library I/O; application callbacks must
cooperate with async cancellation. Cleanup errors are diagnostic events and do
not replace an earlier database error, business `Err`, or callback exception.

## Session isolation and hooks

`HealthCheck` (`Passive`, `Active`, or `Custom(sql)`) validates connections on
checkout. The default is `Active`. `ResetPolicy` is independent:

- `DiscardAll` (default): synchronize protocol, roll back unfinished transactions,
  execute `DISCARD ALL` outside a transaction, clear statement/type caches,
  restore the application baseline, then make capacity available.
- `PreserveSession`: synchronize and roll back unfinished transactions while
  retaining session state, including prepared statements. Choose this explicitly
  for persistent LISTEN or other intentional affinity across borrows.
- `Reconnect`: retire on return, for extension state that standard SQL cannot
  reliably reset.

`PoolOptions::initialize_session` receives a scoped Session on new connections
and after full reset. Use it to restore application settings. `before_acquire`
runs before every checkout. A hook error or a hook leaving an open transaction
ends that acquisition. An initialization failure during return retires the
connection and emits an event while preserving the business result. Temporary
settings should use transaction-local `SET LOCAL`, as above.

`DISCARD ALL` clears server prepared statements, so the default cache is useful
within a lease and is deliberately invalidated between borrowers. The idle queue
can use FIFO or LIFO order; this is unrelated to same-connection operation
rejection.

## Diagnostics

`next_event()` receives structured events for connection attempts/replacement,
health checks, hooks, cancellation, cleanup and transaction completion. Events
carry connection, scope and request identifiers where applicable, phase, target,
elapsed time and original errors. The default buffer holds 256 events; oldest
events are dropped on overflow and `dropped_events()` counts them. Transaction
records remain available independently. `AcquireError::AttemptsFailed` retains
all failed targets, health-check attempts, phases and original causes, including
connection-stage timeouts.

Protocol references: [PostgreSQL cancellation](https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-CANCELING-REQUESTS)
and [DISCARD ALL](https://www.postgresql.org/docs/current/sql-discard.html).
