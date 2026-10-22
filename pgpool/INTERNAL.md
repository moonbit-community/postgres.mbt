# Pool invariants

`PoolExecutor` owns physical client executors and creation/close workers.
A checkout reserves exactly one slot. Until handoff, its error defer restores
that slot; after handoff only `Session::release` restores it. Retirement changes
physical connection accounting, never checkout capacity. Reset completes before
an idle connection is published. A cancelled acquisition retires its candidate.
Idle dequeue registers retirement before checking the recycle deadline, so an
immediately expired recycle budget cannot leave an unowned physical connection.

`ClientLeaseState` is the capability state used by Session and Transaction.
`begin_operation` checks expiry, then uses `Mutex::try_acquire`: conflict never
suspends. A transaction holds its parent's gate and gets a fresh child gate.
Savepoints work identically. Closing the child expires it before releasing the
parent. Prepared callbacks retain a scope count but no gate; actual preparation
and execution use the owning capability's gate. Scope counts prevent escaped
callbacks from carrying a physical socket into the next lease. Stream/COPY
callbacks retain the owner gate; their individual methods have another gate
and an active flag. Cleanup expires the resource first. Escaped concurrent work
causes retirement, rather than releasing a live socket to another borrower.

`with_scope_exit` owns exit precedence for prepared handles and session-return
callbacks. It checks cancellation before and after the
cancellable body. A local `errdefer` runs protected `on_unwind` and suppresses
its errors, retaining the original callback exception or native cancellation.
Normal completion instead runs protected `on_return`, captures ordinary errors
in an internal `Result[Unit, Error]`, and always checks cancellation outside
protection before returning the callback value or raising the completion error.
Thus cancellation received during normal cleanup wins even if cleanup failed.
`on_return` failure never invokes `on_unwind`; each adapter owns its failure
recovery and releases resources once. The helper adds neither a task group nor
a cleanup budget, and never represents cancellation as an ordinary error.

Output resource scopes call the client's internal `finish_scope` inside bounded
cleanup and raise its returned query SQL error outside that cleanup boundary.
Only a raised synchronization or resource-cleanup failure retires the client;
callback errors keep priority. Prepared streams invalidate cache entries for
26000/0A000 during acquisition and finalization, including errors masked by a
callback exception. No execution is retried. Prepared and stream handles expire
before release, and cleanup retains the existing gate and cache-lease rules.

`Deadline` is absolute in `@async.now()` milliseconds. The minimum inherited
instant flows through checkout and child scopes; phase limits can shorten it.
Readiness and slot acquisition consume one wait budget. All hosts consume one
create budget. Hooks cannot silently turn acquisition failures into retries.
Failed health checks can replace candidates; `AcquireError::AttemptsFailed`
retains target, phase, elapsed time and original causes from failed attempts.

`ClientLeaseState::supervise` installs one client `RequestControl` for an operation
or resource scope. Its private `supervise_worker` helper starts a worker and
applies the deadline to an independent waiter outside protected I/O. Stream
methods use that helper with the scope's existing control and owner gate; their
own gate remains held until the worker exits. Method deadlines therefore also
bound protected temporary-statement Close I/O by the shared cleanup budget.
The client driver assigns
request IDs and marks possible transmission before writing bytes. The sole
reader records CommandComplete and ReadyForQuery before queue delivery, so
observations survive consumer backpressure and a subsequent disconnect.
Cancellation disables subsequent business submissions. Cleanup Close requests
may still run, but the driver waits for the cancel fence first. The fence is
released only after the separate CancelRequest TCP connection reaches EOF (or
its failure forces abort). The supervisor joins both cancellation and original
protocol cleanup before dropping the owner gate. COPY IN cleanup explicitly
joins a drain transferred to the executor by a cancelled send/finish call.
Nested cancellation first cancels its worker, then joins `cancel_active` and
protocol cleanup. Only the owner of `cancel_active` sends a packet and releases
the fence; another supervisor must never release it. Budget expiry aborts the
client, and supervisors still join their workers before releasing either gate.

`cleanup_deadline` is shared by scopes on one lease. The first unwind step
allocates the grace period; later drain, rollback, reset and initialization use
the remaining duration. The watchdog can abort even while a raw operation is
protected. Cleanup hooks use `cleanup_mode` so their queries cannot renew this
budget. A new accepted business operation after an error was handled starts a
new episode. A successful child scope clears its completed episode; failed
cleanup keeps the same budget for the remaining unwind.

Pooled transactions issue SQL through the same controlled Client path as other
operations. They do not expose the raw client's manual transaction handles.
Callback Ok requests commit, Err/exception/cancellation requests rollback.
`TransactionRecord` is claimed once, independently of event retention. Before
COMMIT, cancellation rolls back. After possible submission, bounded completion
waits for the actual server tag and never sends a compensating ROLLBACK. COMMIT,
ROLLBACK and savepoint RELEASE produce distinct statuses. Missing decisive
responses retire the socket and report unknown outcome; a recorded COMMIT
survives loss of ReadyForQuery. Connection reuse is a separate decision.

On the normal return path, `transaction_scope` checks pending cancellation after
completion handling and before clearing the cleanup budget. Cancellation received
during protected rollback therefore propagates before caller code resumes, even
when the callback returned a business Err and rollback cleanup timed out. Session
transactions, named savepoints and nested transactions share this check. Without
cancellation, the business Err is preserved even if cleanup fails; error unwinding
keeps an existing callback exception. Rollback records remain `RolledBack` on
success or `OutcomeUnknown` on failure. Cancellation unwind retains the shared
cleanup budget for enclosing rollback and session return.

Before completion SQL, transaction/savepoint exit synchronously checks its own
`active_ops`. A nonzero count sets `releasing`, retains `OperationInProgress`
as the retirement cause and aborts the physical client without suspension.
Only an `InProgress` record transitions to `OutcomeUnknown` and emits completion;
errdefer and final defer repeat the check without duplicating the event or
overwriting a confirmed result. `Ok` raises `OperationInProgress`; business Err,
exceptions, cancellation and deadline errors take precedence. No COMMIT,
RELEASE or rollback is sent on this aborted socket. Enclosing rollback records
unknown outcome with the retained cause; late cleanup cannot replace that cause
with a closed/expired-handle error. Child expiry precedes parent gate release,
while only the outer Session returns capacity. Escaped application tasks are
not joined: their ConnectionState remains retired and is never rebound to a
replacement client. This scope usage error does not change normal completion.
Retirement does not enqueue graceful close for an already closed client: abort
owns transport shutdown, and an escaped stream/COPY may still hold a raw permit
that would block the close worker and pool shutdown.

Return ordering is protocol completion, rollback if non-idle, standalone
DISCARD ALL, statement/type cache invalidation, initialize_session, then idle
publication. PreserveSession skips discard and initialization but still requires
protocol synchronization and transaction cleanup. Reconnect retires the socket.
Return cleanup is best effort with respect to the user's result, with original
failures retained in bounded PoolEvents. `with_session` delegates return and
unwind to `with_scope_exit`, calling `Session::release` once on either path.
Cancellation received during reset or initialization therefore propagates after
normal callback completion and before caller code resumes, including through
Pool convenience and transaction helpers. An existing callback exception keeps
priority; an already confirmed transaction record keeps its status.
Event overflow drops oldest entries and increments a counter; it never changes
transaction records.

Protocol tests in `request_control_wbtest.mbt` cover timing barriers, hung
cancellation sockets, ignored cancellation, lost commit responses, completion
tags, nested cleanup budgets and capacity accounting. Protected Close and method
deadline regressions live in `stream_deadline_wbtest.mbt`; immediate recycle
expiry and retirement accounting live in `recycle_cancel_wbtest.mbt`.
`stream_error_wbtest.mbt` covers SQL failures versus synchronization and Close
failures; `prepared_cancel_wbtest.mbt` covers cancellation during release.
`release_cancel_wbtest.mbt` covers session-return cancellation during reset and
initialization, callback exception priority, capacity restoration, reuse and
confirmed transaction records across Pool entry points.
`transaction_cancel_wbtest.mbt` covers cancellation during successful or timed-out
rollback across Session transactions, named savepoints and nested transactions,
including caller continuation, error priority, records, reuse and capacity.
`scope_exit_wbtest.mbt` checks cancellation at the body boundaries and
exactly-once finalization.
`tests/baseline/pgpool_stream_error_integration_test.mbt` checks backend reuse,
savepoint rollback and prepared cache invalidation against PostgreSQL.
`transaction_scope_wbtest.mbt` covers escaped prepared callbacks and active SQL
across Pool/Session transactions, named savepoints and nested transactions,
including exit precedence, cache/reset policies, diagnostics and normal reuse.
Real PostgreSQL coverage
in `tests/baseline/pgpool_redesign_integration_test.mbt` exercises state isolation,
initialization, transaction intent, stream/COPY cancellation and escaped
prepared/COPY callbacks against a new borrower's blocked backend.
