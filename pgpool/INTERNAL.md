# Pool Cancellation Invariants

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
