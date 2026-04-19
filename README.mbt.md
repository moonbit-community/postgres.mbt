## Postgres.mbt

A secure, easy-to-use PostgreSQL client library for MoonBit with an included connection pool.

### Packages

- `moonbit-community/postgres/client`: low-level PostgreSQL client
- `moonbit-community/postgres/pgpool`: single-event-loop connection pool built on top of `client`

The `pgpool` package is meant for connection reuse and PostgreSQL session
isolation. It is useful when multiple async tasks share one MoonBit event loop
but should not all queue behind the same database connection.

[client doc](./client/README.mbt.md)
[pgpool doc](./pgpool/README.mbt.md)

### TLS

The client and pool now keep three explicit TLS modes:

- `disable`: plaintext only
- `verify-ca`: TLS with certificate-chain validation but without hostname/IP validation
- `verify-full`: TLS with certificate-chain validation and hostname/IP validation

`verify-full` is the default for both `client.Config::new` and
`pgpool.Config::new`. The removed `prefer` and `require` aliases are not part
of either config API.

Supported libpq-style TLS parameters:

- `sslmode`
- `sslrootcert`

`sslrootcert=system` uses the platform trust store and requires `verify-full`.
On Windows, custom `sslrootcert` files are rejected explicitly instead of being
ignored.

Migration summary:

- `prefer` -> `verify-full` for authenticated TLS, or `disable` for intentional plaintext
- `require` -> `verify-full` in most deployments, or `verify-ca` when hostname validation is intentionally out of scope
- `verify-full` now requires an explicit `host` or `hostaddr`

`pgpool` no longer parses connection URLs. Spell the pool config explicitly:

```mbt check
///|
fn _upgrade_examples() -> @pgpool.Config {
  @pgpool.Config::new(
    "db.example",
    hostaddr="10.0.0.15",
    user="moon",
    dbname="app",
    password="secret",
    ssl_mode=@client.SslMode::VerifyFull,
    ssl_root_cert="/etc/postgres/root.crt",
    application_name="my-service",
    pool=@pgpool.PoolConfig::new(4),
  )
}
```

References:

- Aembit, "The Strange World of Postgres TLS":
  <https://aembit.io/blog/the-strange-world-of-postgres-tls>
- PostgreSQL `sslmode`:
  <https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNECT-SSLMODE>
- PostgreSQL certificate verification semantics:
  <https://www.postgresql.org/docs/current/libpq-ssl.html#LIBQ-SSL-CERTIFICATES>
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

The integration tests only execute when `RUN_POSTGRES_INTEGRATION=1`. The script above starts a temporary PostgreSQL cluster with `pg_virtualenv`, picks a high local port, creates a `moondb` database plus `moon_scram` and `moon_password` users, and runs the `integration*` test suite against those two authentication modes.

When `--enable-coverage` is set, the same script runs `moon test --enable-coverage` for each authentication mode, merges the resulting traces, and then prints caret-style line-level coverage details for all instrumented packages.
