## Postgres.mbt

A PostgreSQL client and connection pool for MoonBit.

### Packages

- `moonbit-community/postgres/client` runs operations one at a time on a single
  PostgreSQL session, in FIFO order.
- `moonbit-community/postgres/pgpool` runs operations concurrently across
  separate sessions.

The `client`, `pgpool`, and PostgreSQL integration-test packages support the
`native` and classic `wasm` targets. WasmGC lacks the socket and TLS runtime
required for live connections. The packages under `protocol` are
backend-independent.

Streams and transactions hold their `client.Client` session until they finish.
Use `pgpool.Pool` for concurrent work. Ordinary pool methods check out and
return sessions automatically. Use `Pool::with_session` to keep the same
session for a callback.

Pooled Session and Transaction handles reject overlapping operations immediately
with `OperationInProgress`. Deadlines and task cancellation apply to active SQL,
with a separate cleanup budget. By default the pool runs `DISCARD ALL` and
reruns the initialization hook before reuse. Pooled transaction callbacks return
`Result`. `Ok` requests commit and `Err` requests rollback. A
`TransactionRecord` preserves completion independently of task cancellation.
See [pool documentation](./pgpool/README.mbt.md).

For client streams and COPY, prefer `Client::with_stream`,
`with_typed_stream`, `with_statement_stream`, `with_simple_query`,
`with_copy_in`, and `with_copy_out`. Create portals with
`Transaction::with_portal` or a transaction-owned `ScopedStatement::with_portal`,
then fetch successive windows through `Portal::with_stream`.
These scopes keep the callback cancellable and wait for cleanup on every exit.
Call `finish()` inside the COPY IN callback to complete the copy. Scope cleanup
aborts unfinished input.

For named statements, `Client::with_prepared` and
`Transaction::with_prepared` close the Statement after the callback.
Statements belong to their creating connection. Passing one to another Client
or Transaction raises `ClientError::StatementConnectionMismatch` locally.
`Portal` is the only public portal handle. Each fetch finishes its stream, and
the portal closes when its callback ends. A caller-owned `Statement` remains
open for reuse, including across transactions. See the
[pagination example](./client/README.mbt.md#prepared-statements-and-portals).

Client transaction scopes drain unfinished query streams before completion.
An open nested transaction at commit causes rollback and raises
`UnfinishedChildTransaction`. Client and Pool both buffer async backend
messages with a size limit.

The client and pool use `UInt64` for observed row counts
(`QuerySummary.row_count`) and for affected row counts from `execute` and COPY IN
`finish`. The client's `execute_raw` also returns `UInt64`. Commands without a
row count return zero. Missing, invalid, or overflowing counts in counted
command tags raise `ClientError::Protocol`.

`Client::create(config)` returns a handle and a single-use
`ClientExecutor`. Spawn `executor.run()` in a task group, then call
`client.ready()` to observe connection and authentication errors. Async client
operations also wait for startup. `Pool::create` returns a `Pool` and
`PoolExecutor`. Pool readiness means its workers can accept requests. Checkout
opens physical connections on demand.

`Client::shutdown()` waits for graceful shutdown. `Client::close()` is synchronous
and idempotent, so it can be used in `defer`. It immediately marks the runtime
closed, requests driver cancellation, and fails active or queued work with
`ClientError::Closed("connection aborted")`. The driver closes the physical
connection while cancellation unwinds.

When migrating, replace the former async `Client::close()` with `shutdown()` and
the former `Client::abort()` with the synchronous `close()`.

- [client doc](./client/README.mbt.md)
- [pgpool doc](./pgpool/README.mbt.md)

Keep `client_encoding=UTF8` for the lifetime of every client and pooled session.
The client keeps using UTF-8 even if the server reports a different encoding.
A mismatch can cause decode errors or silently corrupt stored text. See the
[client encoding warning](./client/README.mbt.md#client-encoding) and
[TODO.md](./TODO.md).

### Resource limits

Client and pool configs limit each backend message body to 64 MiB by default
(`max_backend_message_body_bytes=67_108_864`). The body excludes the tag and
four-byte length word. For servers returning larger rows or COPY chunks, set a
larger positive limit explicitly on `client.Config` or `pgpool.Config`. The
maximum is `2_147_483_642`, and zero is invalid. Invalid client settings fail
`ready()` with `ClientError::InvalidConfig` before connecting. Invalid pool
settings fail construction with `ConfigError::InvalidConfig`.
An invalid header or a body size over the limit fails the connection with
`ClientError::Protocol` before the body is read. Results and the pool can
consume more memory in total.

SCRAM authentication accepts at most `100_000` server-requested iterations by
default. If your server uses a higher count, explicitly set
`scram_max_iterations` on `client.Config` or `pgpool.Config` to a suitable larger
value in `1..=2_147_483_647`. Zero is invalid. Invalid settings use the same
configuration errors as the message limit. Excessive or malformed server
counts fail with `ClientError::Authentication` before PBKDF2 begins.
The client yields after batches of at most 256 HMAC operations, so cancellation,
connection timeouts, and other connections can progress during authentication.
The protocol package is synchronous and independent of the async runtime.
`ScramSha256::update(..., max_iterations=...)` has the same default limit.
The low-level `hi` function uses the positive count supplied by its caller.

### TLS

`client.Config::Config` and `pgpool.Config::Config` accept the following
`ssl_mode` values.

| Mode | Connection |
| --- | --- |
| `disable` | Plaintext only |
| `verify-ca` | TLS with certificate-chain validation only |
| `verify-full` (default) | TLS with certificate-chain and hostname/IP validation |

With TLS enabled, the platform trust store is the default. The explicit value
`ssl_root_cert="system"` also selects that store and requires
`SslMode::VerifyFull`. The client passes a custom `ssl_root_cert` path to
`moonbitlang/async/tls` as a PEM root certificate file.

`verify-full` requires an explicit `host` or `hostaddr`. Every pool target
requires one, regardless of TLS mode.

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

#### TLS references

- Aembit, [The Strange World of Postgres TLS](https://aembit.io/blog/the-strange-world-of-postgres-tls)
- [PostgreSQL `sslmode`](https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNECT-SSLMODE)
- [PostgreSQL certificate verification](https://www.postgresql.org/docs/current/libpq-ssl.html#LIBPQ-SSL-CERTIFICATES)
- [PostgreSQL TLS protection matrix](https://www.postgresql.org/docs/current/libpq-ssl.html#LIBPQ-SSL-PROTECTION)
- [PostgreSQL `sslrootcert`](https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNECT-SSLROOTCERT)

Unsupported libpq options include `sslcert`, `sslkey`, `sslpassword`,
`sslcrl`, `sslcrldir`, `sslsni`, `ssl_min_protocol_version`,
`ssl_max_protocol_version`, `sslnegotiation`, `sslcertmode`,
`sslkeylogfile`, and `sslcompression`.

### Testing

- `node scripts/resource_safety_test.mjs` runs resource safety regressions with an independent process watchdog.
- `node scripts/pg_integration_test.mjs` runs PostgreSQL integration tests.
- `node scripts/pg_integration_test.mjs --enable-coverage` adds coverage.

Configure PostgreSQL to use `scram-sha-256` or `password`. The client rejects
`AuthenticationMD5Password` with an authentication error during startup.

The integration tests run only when `RUN_POSTGRES_INTEGRATION=1`. The script
starts a temporary PostgreSQL cluster with `pg_virtualenv` on a high local
port and generates TLS certificates with `openssl`. It creates the `moondb`
database and the `moon_scram` and `moon_password` users, then runs the
`integration*` suite by default on the native and WebAssembly backends for
both authentication modes. It also runs the untrusted-certificate test on
both backends.

With `--enable-coverage`, the script runs `moon test --enable-coverage` for
each backend and authentication mode. It then prints caret-style line coverage
for the instrumented packages.
