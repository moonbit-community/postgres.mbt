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

For client streams and COPY, prefer `Client::with_stream`,
`with_typed_stream`, `with_statement_stream`, `with_portal_stream`,
`with_simple_query`, `with_copy_in`, and `with_copy_out`. These scopes keep the
callback cancellable and wait for cleanup on every exit. COPY IN commits only
when the callback explicitly calls `finish()`; otherwise it is aborted.

In `0.1.0`, `Client::create(config)` returns a handle and a single-use
`ClientExecutor`. Spawn `executor.run()` in a task group, then await
`client.ready()` to observe connection and authentication errors. `Pool::create`
likewise returns a `Pool` and `PoolExecutor`; the pool executor owns its
physical connection executors. Async database calls wait for readiness.

`Client::close()` remains graceful. `Client::abort()` is the synchronous,
idempotent hard-stop for deadlines and emergency teardown: it immediately marks
the runtime closed, asks the driver to discard the physical connection, and
fails active or queued work with `ClientError::Closed("connection aborted")`.
The driver completes physical transport cleanup while cancellation unwinds.

- [client doc](./client/README.mbt.md)
- [pgpool doc](./pgpool/README.mbt.md)

### TLS

The client and pool now keep three explicit TLS modes:

- `disable`: plaintext only
- `verify-ca`: TLS with certificate-chain validation but without hostname/IP validation
- `verify-full`: TLS with certificate-chain validation and hostname/IP validation

`verify-full` is the default for both `client.Config::Config` and
`pgpool.Config::Config`. The removed `prefer` and `require` aliases are not part
of either config API.

`client.Config::Config` and `pgpool.Config::Config` expose TLS fields with
libpq-equivalent semantics:

- `ssl_mode`
- `ssl_root_cert`

`ssl_root_cert="system"` uses the platform trust store and requires
`SslMode::VerifyFull`. Custom `ssl_root_cert` paths are passed to
`moonbitlang/async/tls` as PEM root
certificates.

Migration summary:

- `prefer` -> `verify-full` for authenticated TLS, or `disable` for intentional plaintext
- `require` -> `verify-full` in most deployments, or `verify-ca` when hostname validation is intentionally out of scope
- `verify-full` now requires an explicit `host` or `hostaddr`

`pgpool` no longer parses connection URLs. Spell the pool config explicitly:

```mbt check
///|
fn _upgrade_examples() -> @pgpool.Config {
  @pgpool.Config::Config(
    "db.example",
    hostaddr="10.0.0.15",
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

MD5 password authentication is deprecated by PostgreSQL and is not supported by this client. If the server sends `AuthenticationMD5Password`, connection startup fails with a client authentication error; configure `scram-sha-256` or `password` instead.

The integration tests only execute when `RUN_POSTGRES_INTEGRATION=1`. The script above starts a temporary PostgreSQL cluster with `pg_virtualenv`, picks a high local port, creates a `moondb` database plus `moon_scram` and `moon_password` users, and runs the `integration*` test suite on both the native and WebAssembly backends against those two authentication modes.

When `--enable-coverage` is set, the same script runs `moon test --enable-coverage` for each backend and authentication mode, merges the resulting traces, and then prints caret-style line-level coverage details for all instrumented packages.
