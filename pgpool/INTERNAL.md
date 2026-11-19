# Pool invariants

`PoolExecutor` owns physical client executors and the workers that open and
close connections. Checkout reserves one slot. Before handoff, the checkout's
error defer returns it. After handoff, `Session::release` returns it. Retirement
updates the physical connection count. The pool puts a connection back on
the idle queue after reset completes. A cancelled acquisition retires its
candidate. When checkout removes an idle connection, it registers retirement
on error before checking the recycle deadline. Even an already expired
deadline then has a cleanup path.

Session and Transaction use `ClientLeaseState`. `begin_operation` checks
expiry, then uses `Mutex::try_acquire` to reject overlap immediately. A
transaction or savepoint holds its parent's gate and has its own gate. On exit,
the child expires before the parent gate is released. Prepared callbacks count
toward active scopes. Preparation, execution, and handle release take the
owner's gate. Stream and COPY callbacks hold that gate through cleanup, and
their methods use a separate gate and an active flag. Cleanup expires the
resource first. The pool retires the connection if work is still active when
its owning scope exits.

`with_scope_exit` owns exit precedence for transaction, prepared, stream/COPY
and session-return callbacks. It checks cancellation before and after the
cancellable body. A local `errdefer` runs protected `on_unwind` and suppresses
its errors, retaining the original callback exception or native cancellation.
On normal completion, the helper runs protected `on_return`, captures ordinary
errors in an internal `Result[Unit, Error]`, then checks cancellation outside
protection. Cancellation during cleanup takes precedence over its result.
Each adapter handles its own `on_return` failures and releases resources once.
`on_unwind` runs only when the body unwinds. The helper uses the caller's task
group and cleanup budget and leaves cancellation to the runtime.

Output resource scopes call the client's internal `finish_scope` inside bounded
cleanup and raise the returned SQL error after leaving that cleanup boundary.
A synchronization or resource-cleanup failure retires the client. Callback
errors keep priority. Prepared streams invalidate cache entries for
26000/0A000 during acquisition and finalization, even if a callback exception
has priority. The pool leaves retries to the caller. Prepared and stream
handles expire before release, and cleanup still takes the appropriate gates
and releases the cache lease.

`Deadline` is an absolute time in `@async.now()` milliseconds. Checkout and
child scopes inherit the earliest deadline. Phase limits can shorten it.
Readiness and slot acquisition share one wait budget. All hosts share one
create budget. A hook failure ends checkout. A failed health check can lead to
another candidate. If checkout raises `AcquireError::AttemptsFailed`, it
retains the target, phase, elapsed time, and cause for each recorded attempt.

`ClientLeaseState::supervise` installs one client `RequestControl` for an operation
or resource scope. Its private `supervise_worker` helper starts a worker and
applies the deadline to an independent waiter outside protected I/O. Stream
methods use that helper with the scope's existing control and owner gate.
Their own gate remains held until the worker exits. Method deadlines also
bound protected temporary-statement Close I/O by the shared cleanup budget.

Each client request has an ID. The driver marks it as possibly sent before
writing bytes. The reader records CommandComplete and ReadyForQuery before
queue delivery, so observations survive backpressure and a later disconnect.
Cancellation disables subsequent business submissions. The driver waits for
the cancellation fence before sending cleanup Close requests. If a cancel
packet is needed, the owner waits for EOF on the separate TCP connection.
Cancellation failure triggers connection cleanup and abort. The supervisor
joins cancellation and original protocol cleanup before releasing the owner
gate. COPY IN cleanup also joins a drain transferred to the executor by a
cancelled send/finish call.
Nested cancellation first cancels its worker, then joins `cancel_active` and
protocol cleanup. Only the owner of `cancel_active` sends a packet and releases
the fence. On budget expiry, the supervisor aborts the client and joins the
worker before releasing either gate.

Stream/COPY callbacks run in the supervised worker. They publish an ordinary
callback exception before starting cleanup. When the waiter starts to unwind,
it saves any exception already published and preserves it after joining cleanup
and the fence. Cancellation takes precedence over later exceptions, such as a
stream method reporting a timeout after its cleanup.
Normal-return cleanup errors and native cancellation never enter this channel.

`cleanup_deadline` is shared by scopes on one lease. The first cleanup step
allocates the grace period. Later drain, rollback, reset and initialization use
the remaining duration. The watchdog can abort even while a raw operation is
protected. Cleanup hooks use `cleanup_mode` so their queries cannot renew this
budget. After the caller handles an error, the next accepted business operation
starts a new cleanup period. A child scope clears its completed budget when
`with_scope_exit` returns normally. On failure or cancellation, enclosing
scopes use the remaining budget even if the child's cleanup succeeded.

Pooled transactions issue SQL through the same controlled Client path as other
operations. Their scope handles completion. Callback Ok requests commit or
savepoint release. Err, an exception, or cancellation requests rollback.
`TransactionRecord` is claimed once, independently of event retention. Before
COMMIT, cancellation rolls back. After possible submission, bounded completion
waits for the actual server tag. COMMIT, ROLLBACK, and savepoint RELEASE produce
distinct statuses. Without a decisive tag, the pool records an unknown outcome
and retires the connection without sending ROLLBACK. It propagates a database
error if one arrived. Otherwise it raises CommitOutcomeUnknown. A recorded COMMIT
survives loss of ReadyForQuery.

COMMIT/RELEASE and rollback helpers finish protocol handling, diagnostics and
the independent transaction record before `with_scope_exit` decides how the
caller exits. The normal-return adapter handles rollback after precommit
failures for started `InProgress` transactions without active children.
A possibly sent COMMIT determines its record before
raising, so this recovery cannot append ROLLBACK after an unknown outcome.
A business Err is a normal callback return requesting rollback. Without
cancellation it survives rollback failure. Cancellation during that cleanup
propagates before caller code resumes. Rollback records remain `RolledBack` on
success or `OutcomeUnknown` on failure. Confirmed completion records are not
rewritten by cancellation or later session-return failure.

Before completion SQL, transaction/savepoint exit synchronously checks its own
`active_ops`. A nonzero count sets `releasing`, retains `OperationInProgress`
as the retirement cause and aborts the physical client without suspension.
Only an `InProgress` record transitions to `OutcomeUnknown` and emits completion.
Both cleanup defers can check again while preserving the original event and
confirmed results. `Ok` raises `OperationInProgress`. Business Err,
exceptions, cancellation and deadline errors take precedence. No COMMIT,
RELEASE or rollback is sent on this aborted socket. Enclosing rollback records
unknown outcome with the retained cause. Late cleanup preserves that cause
even if it encounters a closed or expired handle. Child expiry precedes parent gate release,
and the outermost Session returns capacity. Escaped application tasks can
outlive the scope, and their ConnectionState stays bound to the retired
connection.

Every retirement owns physical closure, including a successful health check
that finishes after pool close. Repeated retirement settles size and diagnostics
once. Checkout or session release restores capacity.
Retirement skips enqueueing `Client::shutdown()` for an already closed client.
The driver handles transport cleanup after `Client::close()`. An escaped
stream/COPY may still hold a raw permit that would block the close worker and
pool shutdown.

On return, the default policy finishes protocol cleanup, rolls back a non-idle
transaction, runs standalone DISCARD ALL, clears statement and type caches,
and runs initialize_session before putting the connection on the idle queue.
PreserveSession performs protocol and transaction cleanup and keeps session
state. Reconnect closes the connection after any required rollback.
Return failures go to bounded PoolEvents, and the business result is preserved.
`with_session` uses `with_scope_exit` to call `Session::release` once on either
normal return or unwind.
Cancellation received during reset or initialization therefore propagates after
normal callback completion and before caller code resumes, including through
Pool convenience and transaction helpers. An existing callback exception keeps
priority, and an already confirmed transaction record keeps its status.
Event overflow drops the oldest entries and increments a counter.

## Tests

`request_control_wbtest.mbt` covers timing barriers, hung
cancellation sockets, ignored cancellation, lost commit responses, completion
tags, nested cleanup budgets, and capacity accounting. `stream_deadline_wbtest.mbt`
covers protected Close and method deadlines. `recycle_cancel_wbtest.mbt` covers
immediate recycle expiry and retirement accounting.
`stream_error_wbtest.mbt` distinguishes SQL errors from synchronization and
Close failures. `prepared_cancel_wbtest.mbt` covers cancellation during release.

`release_cancel_wbtest.mbt` covers session-return cancellation during reset and
initialization, callback exception priority, capacity restoration, reuse and
confirmed transaction records across Pool entry points.
`transaction_cancel_wbtest.mbt` covers cancellation during successful or timed-out
rollback across Session transactions, named savepoints and nested transactions,
including caller continuation, error priority, records, reuse and capacity.
`transaction_completion_wbtest.mbt` covers COMMIT/RELEASE success, SQL errors,
disconnects, timeouts and tags without ReadyForQuery, both with and without
cancellation. The cancelled-COMMIT timeout regression checks that neither catch
nor subsequent caller code executes. `scope_exit_wbtest.mbt` checks cancellation
at the body boundaries and exactly-once finalization. `stream_cancel_wbtest.mbt`
covers the exit-priority matrix across all stream and COPY entry points,
including the supervising waiter's preservation of an earlier callback error.

`tests/baseline/pgpool_stream_error_integration_test.mbt` checks backend reuse,
savepoint rollback and prepared cache invalidation against PostgreSQL.
`transaction_scope_wbtest.mbt` covers escaped prepared callbacks and active SQL
across Pool/Session transactions, named savepoints and nested transactions,
including exit precedence, cache/reset policies, diagnostics and normal reuse.
`tests/baseline/pgpool_redesign_integration_test.mbt` checks state isolation,
initialization, transaction intent, stream/COPY cancellation and escaped
prepared/COPY callbacks against a new borrower's blocked backend.
