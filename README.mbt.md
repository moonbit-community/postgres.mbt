## Postgres.mbt

### Testing

- Run protocol tests: `moon test`
- Run real PostgreSQL integration tests: `node scripts/pg_integration_test.mjs`
- Run real PostgreSQL integration coverage: `node scripts/pg_integration_test.mjs --enable-coverage`

The integration tests only execute when `RUN_POSTGRES_INTEGRATION=1`. The script above starts a temporary PostgreSQL cluster with `pg_virtualenv`, picks a high local port, creates a `moondb` database plus `moon_scram`, `moon_md5`, and `moon_password` users, and runs the `integration*` test suite against all three authentication modes.

When `--enable-coverage` is set, the same script runs `moon test --enable-coverage` for each authentication mode, merges the resulting traces, and then prints caret-style line-level coverage details for all instrumented packages.
