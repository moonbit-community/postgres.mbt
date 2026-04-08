# Performance TODO

This file tracks likely efficiency risks in the current PostgreSQL client
implementation based on static code review.

## High Priority

- Reduce round trips for one-shot `query` and `execute`.
  Current flow does `Parse + Describe + Sync`, then `Bind + Execute + Sync`,
  and temporary statements also add a close step. This is a latency penalty for
  common short queries.
  Affected code:
  `src/client/client.mbt`

- Remove avoidable copies in the inbound row path.
  `Connection::read_message` rebuilds a full packet buffer, backend parsing
  copies message bodies into owned `Bytes`, and `parse_binary_values` copies
  each field again into per-column `Bytes`. Wide rows and large result sets will
  amplify this cost.
  Affected code:
  `src/client/client.mbt`
  `src/protocol/message/backend/backend.mbt`
  `src/client/types.mbt`

- Batch or amortize dynamic type metadata lookups.
  Unknown OIDs are resolved one by one through internal catalog queries, and
  enum/composite metadata can trigger additional follow-up queries. First-hit
  latency can spike when result sets contain many custom types.
  Affected code:
  `src/client/client.mbt`

## Medium Priority

- Reduce buffer layering in outbound bind and COPY IN paths.
  Parameter encoding currently materializes each argument into its own `Bytes`,
  then bind serialization builds more temporary buffers before writing the final
  request. COPY IN chunks also take extra copies before reaching the socket.
  Affected code:
  `src/client/client.mbt`
  `src/protocol/message/frontend/frontend.mbt`

- Revisit queue backpressure.
  Per-request response queues are bounded, but the shared request queue and
  async message queue are unbounded. Bursty producers or unconsumed async
  notifications can grow memory usage without limit.
  Affected code:
  `src/client/client.mbt`

- Avoid repeated linear scans for named column access.
  `Row::get_name` and related helpers linearly scan `columns` for each lookup.
  This is acceptable for narrow result sets, but it becomes steady overhead for
  wide rows or hot code paths that decode by name.
  Affected code:
  `src/client/types.mbt`

## Suggested Order

1. Add a lower-RTT fast path for one-shot query execution.
2. Change row/message representation to preserve slices instead of eagerly
   copying each value.
3. Replace per-OID catalog lookups with batch lookup or stronger caching.
4. Flatten outbound buffer construction for bind and COPY IN.
5. Add bounded or configurable limits for shared queues.
6. Consider a cached name-to-index map for `Row`.
