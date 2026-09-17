# Pool Cancellation Invariants

Session, transaction, and cancellable-operation gates own the connection until
their protected work and cleanup finish. Check cancellation before entering
protection and after leaving it, while scope release is still guaranteed.
The raw client's checks cannot observe cancellation hidden by a pool-level
protection, so the pool must check at its own outer boundary as well.

Transaction callbacks check cancellation before automatic commit, including
unnamed and named savepoints. Rollback runs under protection and waits for any
active operation before releasing the owner scope. Transaction creation relies
on the raw client to roll back a completed `BEGIN` or `SAVEPOINT` if cancellation
prevents delivery; the pool then releases its lease or parent transaction gate.
Completion checks cancellation before taking the transaction out of scope.
Once `COMMIT` is sent, record the server result and release ownership before
propagating cancellation.

`OperationScopeState::begin_request` acquires its FIFO gate before waiting for
`cancel_in_flight` to reach zero. A successor may already have queued when the
previous request starts sending a cancel packet. Checking only before acquiring
the gate would let that successor run while the old packet is still in flight.
The waiter rechecks scope expiry and releases the gate on cancellation or error;
only then may it allocate a request ID and mark a new request active.

Streaming callbacks finish or abandon their raw handles before returning the
connection. Detached drains save expected connection closure for `finish()`
without failing the shared task group; database errors remain in stream state,
and unexpected protocol errors still fail the group. Ordinary task cancellation
does not imply a PostgreSQL cancel packet, automatic retry, or physical abort.
