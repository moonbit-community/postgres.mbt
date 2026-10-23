## Postgres.mbt

A secure, easy-to-use PostgreSQL client library for MoonBit with an included connection pool.

### Packages

- `moonbit-community/postgres/client`: one FIFO single-flight
  PostgreSQL session
- `moonbit-community/postgres/pgpool`: a connection pool that provides
  concurrency across independent sessions

The `client`, `pgpool`, and PostgreSQL integration-test packages support the
`native` and classic `wasm` targets. They intentionally exclude WasmGC because
the socket/TLS runtime used by live PostgreSQL connections is not available
there. The packages under `protocol` remain backend-independent.

Calls sharing one `client.Client` execute one complete logical operation at a
time. Streams and transactions retain the session until they finish. Use
`pgpool.Pool` when multiple async tasks should run database work concurrently;
ordinary pool methods checkout and return sessions automatically, while
`Pool::with_session` provides callback-scoped session affinity.

Pooled Session and Transaction handles reject overlapping operations immediately
with `OperationInProgress`. Deadlines and task cancellation supervise SQL and
bounded cleanup. The default return policy runs `DISCARD ALL` and restores the
initialization hook before reuse. Pooled transaction callbacks return `Result`:
`Ok` requests commit and `Err` requests rollback; a `TransactionRecord` preserves
completion independently of task cancellation. See the
[pool documentation](./pgpool/README.mbt.md) for scoped operations, deadlines,
session isolation, and diagnostics.

For client streams and COPY, prefer `Client::with_stream`,
`with_typed_stream`, `with_statement_stream`, `with_simple_query`,
`with_copy_in`, and `with_copy_out`. Create portals with
`Transaction::with_portal` or a transaction-owned `ScopedStatement::with_portal`,
then fetch successive windows through `Portal::with_stream`.
These scopes keep the callback cancellable
and wait for cleanup on every exit. COPY IN commits only when the callback
explicitly calls `finish()`; otherwise it is aborted.
For named statements, `Client::with_prepared` and
`Transaction::with_prepared` close the Statement after the callback.
Statements belong to their creating connection; passing one to another Client
or Transaction raises `ClientError::StatementConnectionMismatch` locally.
`Portal` is the only public portal handle: each fetch finishes its stream,
and the portal closes when its callback ends. A caller-owned `Statement` remains
open for reuse, including across transactions. See the
[pagination example](./client/README.mbt.md#prepared-statements-and-portals).
Async backend messages use bounded buffers on both Client and Pool.
Transaction scopes also drain unfinished query streams before completion and
roll back with `UnfinishedChildTransaction` if a nested transaction is left open.

Observed row counts (`QuerySummary.row_count`) and affected row counts from
`execute`, `execute_raw`, and COPY IN `finish` use `UInt64` throughout the client
and pool. Commands without a row count return zero. Missing, invalid, or
overflowing counts in counted command tags raise `ClientError::Protocol`.

`Client::create(config)` returns a handle and a single-use
`ClientExecutor`. Spawn `executor.run()` in a task group, then await
`client.ready()` to observe connection and authentication errors. `Pool::create`
likewise returns a `Pool` and `PoolExecutor`; the pool executor owns its
physical connection executors. Async database calls wait for readiness.

`Client::close()` performs graceful shutdown. `Client::abort()` is the synchronous,
idempotent hard-stop for deadlines and emergency teardown: it immediately marks
the runtime closed, asks the driver to discard the physical connection, and
fails active or queued work with `ClientError::Closed("connection aborted")`.
The driver completes physical transport cleanup while cancellation unwinds.

- [client doc](./client/README.mbt.md)
- [pgpool doc](./pgpool/README.mbt.md)

**Dangerous operation:** changing `client_encoding` away from UTF-8 can cause
decode failures or silently store incorrect text. The client always uses UTF-8
and currently does not reject encoding changes. Keep `client_encoding=UTF8`
for the lifetime of every client and pooled session; see the
[client encoding warning](./client/README.mbt.md#client-encoding) and
[TODO.md](./TODO.md).

### Backend message size

Client and pool configs limit each backend message body to 64 MiB by default
(`max_backend_message_body_bytes=67_108_864`). The body excludes the tag and
four-byte length word. For servers returning larger rows or COPY chunks, set a
larger positive limit explicitly on `client.Config` or `pgpool.Config`; the
maximum is `2_147_483_642`. Zero does not disable the limit. Invalid client
settings fail `ready()` with `ClientError::InvalidConfig` before connecting;
invalid pool settings fail construction with `ConfigError::InvalidConfig`.
Malformed or oversized frames fail the connection with `ClientError::Protocol`
before reading the body. This is a per-frame bound, not a total result-memory
or pool-memory budget.

### TLS

The client and pool support three explicit TLS modes:

- `disable`: plaintext only
- `verify-ca`: TLS with certificate-chain validation but without hostname/IP validation
- `verify-full`: TLS with certificate-chain validation and hostname/IP validation

`verify-full` is the default for both `client.Config::Config` and
`pgpool.Config::Config`.

`client.Config::Config` and `pgpool.Config::Config` expose TLS fields with
libpq-equivalent semantics:

- `ssl_mode`
- `ssl_root_cert`

`ssl_root_cert="system"` uses the platform trust store and requires
`SslMode::VerifyFull`. Custom `ssl_root_cert` paths are passed to
`moonbitlang/async/tls` as PEM root
certificates.

`verify-full` requires an explicit `host` or `hostaddr`; every pool target
requires one even when TLS verification is disabled.

Configure the pool with connection targets and explicit options:

```mbt check
///|
fn _pool_config_example() -> @pgpool.Config raise {
  @pgpool.Config::Config(
    [@pgpool.ConnectionTarget(host="db.example", hostaddr="10.0.0.15")],
    user="moon",
    dbname="app",
    password="secret",
    ssl_mode=@client.SslMode::VerifyFull,
    ssl_root_cert="/etc/postgres/root.crt",
    application_name="my-service",
    pool=@pgpool.PoolConfig::PoolConfig(4),
  )
}
```

References:

- Aembit, "The Strange World of Postgres TLS":
  <https://aembit.io/blog/the-strange-world-of-postgres-tls>
- PostgreSQL `sslmode`:
  <https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNECT-SSLMODE>
- PostgreSQL certificate verification semantics:
  <https://www.postgresql.org/docs/current/libpq-ssl.html#LIBPQ-SSL-CERTIFICATES>
- PostgreSQL TLS protection matrix:
  <https://www.postgresql.org/docs/current/libpq-ssl.html#LIBPQ-SSL-PROTECTION>
- PostgreSQL `sslrootcert`:
  <https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNECT-SSLROOTCERT>
- PostgreSQL unsupported parameters called out in this project:
  `sslcert`, `sslkey`, `sslpassword`, `sslcrl`, `sslcrldir`, `sslsni`,
  `ssl_min_protocol_version`, `ssl_max_protocol_version`, `sslnegotiation`,
  `sslcertmode`, `sslkeylogfile`, `sslcompression`

### Testing

- Run PostgreSQL integration tests: `node scripts/pg_integration_test.mjs`
- Run PostgreSQL integration coverage tests: `node scripts/pg_integration_test.mjs --enable-coverage`

MD5 password authentication is not supported by this client. If the server sends `AuthenticationMD5Password`, connection startup fails with a client authentication error; configure `scram-sha-256` or `password`.

The integration tests only execute when `RUN_POSTGRES_INTEGRATION=1`. The script above starts a temporary PostgreSQL cluster with `pg_virtualenv`, picks a high local port, creates a `moondb` database plus `moon_scram` and `moon_password` users, and runs the `integration*` test suite on both the native and WebAssembly backends against those two authentication modes.

When `--enable-coverage` is set, the same script runs `moon test --enable-coverage` for each backend and authentication mode, merges the resulting traces, and then prints caret-style line-level coverage details for all instrumented packages.
