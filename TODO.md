# TODO

## Low-cost `detach()` plan

Goal:

- solve the case where explicitly abandoning a result stream still blocks later
  requests on the same connection
- keep the change small and avoid rewriting `Connection::run`, `Request`,
  `Shared`, or `@async.Queue`
- minimize extra client-side cost rather than trying to change the protocol
  lower bound itself

Non-goals:

- do not try to make dropped stream objects automatically detach
- do not convert the current client into a `tokio-postgres`-style lazy /
  first-poll-driven model
- do not change the current semantics of transactions, `Statement`, `Portal`,
  or `CopyInSink`

### Design direction

1. Add explicit `detach()` APIs to:
   - `RowStream`
   - `SimpleQueryStream`
   - `CopyOutStream`

2. `detach()` consumes `self` and starts a background coroutine:
   - the background task drains the remaining protocol messages to the terminal
     state
   - row values and database errors are ignored
   - the purpose is to keep the connection making progress, not to return
     useful data to the caller

3. Do not use the existing `finish()` implementation as the final behavior:
   - `finish()` follows the normal decode path
   - for `RowStream` and `SimpleQueryStream`, that would still do avoidable row
     decoding and object allocation
   - add a dedicated discard-drain path that keeps only the minimum protocol
     state machine logic

### Implementation steps

#### Step 1: add the minimal API surface

- add `pub fn RowStream::detach(self : RowStream) -> Unit` to
  `src/client/row_stream.mbt`
- add `pub fn SimpleQueryStream::detach(self : SimpleQueryStream) -> Unit` to
  `src/client/simple_query.mbt`
- add `pub fn CopyOutStream::detach(self : CopyOutStream) -> Unit` to
  `src/client/copy.mbt`

Acceptance criteria:

- this is an additive API change only
- `detach()` returns immediately and does not block the caller

#### Step 2: implement low-cost discard drain

- add an internal `drain_discard()` path for `RowStream`:
  - skip `DataRow` without calling `parse_binary_values`
  - keep only the minimal state needed for `CommandComplete`,
    `PortalSuspended`, `ErrorResponse`, and `ReadyForQuery`
  - still run the existing cleanup when the stream reaches terminal state

- add an internal `drain_discard()` path for `SimpleQueryStream`:
  - skip `RowDescription`, `DataRow`, and `CommandComplete`
  - do not construct `SimpleQueryRow`
  - keep terminal and error handling aligned with the current behavior

- add an internal `drain_discard()` path for `CopyOutStream`:
  - discard `CopyData`
  - stop when `ReadyForQuery` is seen

Acceptance criteria:

- `detach()` no longer uses the full row-decoding path
- for large result sets, client CPU and allocation cost are noticeably lower
  than a background call to `finish()`

#### Step 3: background execution behavior

- use a lightweight coroutine spawn to run discard drain
- swallow final database errors inside the background task so that explicit
  abandonment of a stream does not surface as a caller-visible failure
- if deferred cleanup fails, that failure should stay local to the background
  drain and should not break later request progress

Acceptance criteria:

- after `detach()`, later requests can continue even if the detached request
  would have ended in a database error
- background drain errors are not rethrown to the caller

#### Step 4: test coverage

- add an integration test for `RowStream`:
  - read part of a result stream
  - call `detach()`
  - verify that a later short query completes promptly

- add an integration test for `SimpleQueryStream`:
  - read part of the stream
  - call `detach()`
  - verify that later queries are no longer blocked

- add an integration test for `CopyOutStream`:
  - read part of the copy output
  - call `detach()`
  - verify that later queries continue to make progress

- add a regression test for temporary statement cleanup:
  - create a `RowStream` through `Client::query(...)`
  - call `detach()`
  - verify that the temporary statement is not leaked

Acceptance criteria:

- existing backpressure tests still pass
- new tests show that `detach()` solves the explicit-abandonment case

#### Step 5: documentation updates

- update `src/client/INTERNAL.md`
- update `src/client/README.mbt.md`
- change the guidance from:
  - consume to `None`
  - or call `finish()`
- to:
  - consume to `None`
  - or call `finish()`
  - or call `detach()`

Acceptance criteria:

- documentation clearly distinguishes:
  - `finish()`: stop reading but synchronously observe completion
  - `detach()`: explicitly abandon results while letting the connection
    continue in the background

### Additional notes

- `detach()` cannot remove the network cost or server-side cost of work that is
  already in flight; it can only minimize extra client-side overhead
- for very large result sets, if the real goal is to stop server work as soon as
  possible, cancellation or portal-based paging is still the better tool
- this change should not try to add automatic drop-based cleanup, since the
  current runtime and queue model does not expose a receiver-drop signal
