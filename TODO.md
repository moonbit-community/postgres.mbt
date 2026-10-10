# TODO

- [ ] Enforce `client_encoding=UTF8` throughout each connection's lifetime.
  Startup requests UTF-8, but the client currently only records later
  `ParameterStatus` changes; string encoders and decoders continue to use UTF-8
  regardless of the reported encoding. Changing the setting can cause decode
  failures or silently store incorrect text. A same-connection write/read
  round trip can hide the corruption: UTF-8 bytes for `é` interpreted as LATIN1
  store two characters (`Ã` and `©`), which can decode back to `é` on retrieval.
  - Validate the server-reported encoding before delivering a ready connection.
  - Fail explicitly and invalidate the connection when a later
    `ParameterStatus` reports an unsupported client encoding. Ensure active
    and queued operations fail, and the pool cannot reuse the connection.
  - Cover startup validation, encoding changes via `SET`, `SET NAMES`, and
    `set_config`, and changes within SQL batches. Verify stored text using a
    separate UTF-8 connection or server-side character counts, rather than
    relying only on same-connection round trips.
  - Do not assume detection can undo statements already executed by the
    server, or that binary `text` format bypasses client encoding conversion.
  See the [client encoding warning](client/README.mbt.md#client-encoding).
