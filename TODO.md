# TODO

- [ ] Enforce `client_encoding=UTF8` throughout each connection's lifetime.
  The client requests UTF-8 at startup and keeps using it for encoding and
  decoding strings after recording a `ParameterStatus` change. A change can
  cause decode errors or silently corrupt stored text. When the server interprets
  the UTF-8 bytes for `é` as LATIN1, it stores two characters (`Ã` and `©`).
  Reading back on the same connection can decode them as `é` again.
  - Validate the server-reported encoding before delivering a ready connection.
  - Fail explicitly and invalidate the connection when a later
    `ParameterStatus` reports an unsupported client encoding. Fail active and
    queued operations and prevent pool reuse.
  - Cover startup validation, encoding changes via `SET`, `SET NAMES`, and
    `set_config`, and changes within SQL batches. Verify stored text using a
    separate UTF-8 connection or server-side character counts.
  - Account for statements the server may have completed before detection and
    for client encoding conversion in binary `text` format.
  See the [client encoding warning](client/README.mbt.md#client-encoding).
