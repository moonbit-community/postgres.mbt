///|
/// Helper assertion for successful authentication.
/// It requires not only that `connect` succeeds, but also that the server reports the expected `current_user`.
async fn assert_auth_ok(
  config : IntegrationConfig,
  user : String,
  password : String,
) -> Unit {
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      auth_client_config(
        config,
        user,
        password=Some(password),
        application_name="moonbit-postgres",
      ),
    )
    group.spawn_bg(() => connection.run())

    let current_user : String = client
      .query_one("select current_user::text as current_user")
      .get_name("current_user")
    assert_eq(current_user, user)

    client.close()
  })
}

///|
/// Missing passwords should fail immediately during connection setup with an authentication error.
async fn assert_missing_password(
  config : IntegrationConfig,
  user : String,
) -> Unit {
  let message = expect_authentication_error(
    try? @client.connect(
      auth_client_config(
        config,
        user,
        password=None,
        application_name="moonbit-postgres",
      ),
    ),
  )
  assert_eq(message, "server requires a password")
}

///|
/// Wrong passwords should surface PostgreSQL's standard authentication failure code `28P01`.
async fn assert_wrong_password(
  config : IntegrationConfig,
  user : String,
) -> Unit {
  let err = expect_database_error(
    try? @client.connect(
      auth_client_config(
        config,
        user,
        password=Some("wrongpass"),
        application_name="moonbit-postgres",
      ),
    ),
  )
  assert_eq(err.code, Some("28P01"))
}

///|
/// Collect messages from the driver's async channel.
/// Parameter-status updates are not the point of these tests, so they are skipped and only notice or notification messages are kept.
async fn collect_driver_async_messages(
  connection : @client.Connection,
  expected : Int,
) -> Array[@client.AsyncMessage] {
  let messages : Array[@client.AsyncMessage] = []
  while messages.length() < expected {
    guard connection.next_message() is Some(message) else {
      fail("expected async message")
    }
    if message is @client.AsyncMessage::ParameterStatus(_, _) {
      continue
    }
    messages.push(message)
  }
  messages
}

///|
/// Poll until a background task finishes.
/// These concurrency tests need to distinguish between "already finished" and "should still be pending", so they do not wait forever.
async fn[T] wait_for_task_or_fail(
  task : @async.Task[T],
  message : String,
  polls? : Int = 500,
) -> T {
  let mut remaining = polls
  while remaining > 0 {
    match task.try_wait() {
      Some(value) => return value
      None => {
        remaining -= 1
        @async.sleep(10)
      }
    }
  }
  fail(message)
}

///|
/// Assert that a task stays pending for the whole observation window.
/// This is mainly used to prove that some stream or session still holds protocol execution rights.
async fn[T] assert_task_stays_pending(
  task : @async.Task[T],
  message : String,
  polls? : Int = 50,
) -> Unit {
  let mut remaining = polls
  while remaining > 0 {
    match task.try_wait() {
      Some(_) => fail(message)
      None => {
        remaining -= 1
        @async.sleep(10)
      }
    }
  }
}

///|
/// Wait until the pool's waiter count reaches the expected value.
/// This is only used by the few client-side concurrency tests that inspect pool state directly.
async fn wait_for_pool_waiters_or_fail(
  pool : @pgpool.Pool,
  expected : Int,
  message : String,
  polls? : Int = 500,
) -> Unit {
  let mut remaining = polls
  while remaining > 0 {
    if pool.status().waiting == expected {
      return
    }
    remaining -= 1
    @async.sleep(10)
  }
  fail(message)
}

///|
/// Verify that a TLS connection was established and remains usable for follow-up queries.
/// The check looks at both the client's cached startup parameters and `pg_stat_ssl` on the server side to confirm the session is really using TLS.
async fn assert_tls_query_ok(config : @client.Config) -> Unit {
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(config)
    group.spawn_bg(() => connection.run())

    assert_eq(
      client.parameter("application_name"),
      Some(config.application_name),
    )
    let negotiated_application_name : String = client
      .query_one(
        "select current_setting('application_name')::text as application_name",
      )
      .get_name("application_name")
    assert_eq(negotiated_application_name, config.application_name)
    let backend_pid : Int = client
      .query_one("select pg_backend_pid()::int4 as pid")
      .get_name("pid")
    let using_tls : Bool = client
      .query_one("select ssl from pg_stat_ssl where pid = $1::int4", params=[
        backend_pid as &@client.ToSql,
      ])
      .get_name("ssl")
    assert_eq(using_tls, true)
    let value : Int = client
      .query_one("select 1::int4 as value")
      .get_name("value")
    assert_eq(value, 1)

    client.close()
  })
}

///|
/// Verify the three basic read-write paths for one scalar type.
/// The same value must round-trip through a literal read, a bound parameter, and a `query_typed` read.
async fn[T : @client.ToSql + @client.FromSql + Eq + Show] assert_roundtrip(
  client : @client.Client,
  sql_type : String,
  param_type : @client.Type,
  literal : String,
  value : T,
) -> Unit {
  let from_literal : T = client
    .query_one("select \{literal}::\{sql_type} as value")
    .get_name("value")
  assert_eq(from_literal, value)

  let params : Array[&@client.ToSql] = [value as &@client.ToSql]
  let from_param : T = client
    .query_one("select $1::\{sql_type} as value", params~)
    .get_name("value")
  assert_eq(from_param, value)

  let typed_rows = client
    .query_typed("select $1::\{sql_type} as value", [param_type], params~)
    .collect()
  assert_eq(typed_rows.length(), 1)
  let from_typed : T = typed_rows[0].get_name("value")
  assert_eq(from_typed, value)
}

///|
/// `NaN` cannot be compared with ordinary equality, so float4 gets a dedicated round-trip check that uses `is_nan()`.
async fn assert_float_nan_roundtrip(client : @client.Client) -> Unit {
  let from_literal : Float = client
    .query_one("select 'NaN'::real as value")
    .get_name("value")
  assert_true(from_literal.is_nan())

  let params : Array[&@client.ToSql] = [@float.not_a_number as &@client.ToSql]
  let from_param : Float = client
    .query_one("select $1::real as value", params~)
    .get_name("value")
  assert_true(from_param.is_nan())

  let typed_rows = client
    .query_typed("select $1::real as value", [@client.Type::float4()], params~)
    .collect()
  assert_eq(typed_rows.length(), 1)
  let from_typed : Float = typed_rows[0].get_name("value")
  assert_true(from_typed.is_nan())
}

///|
/// Verify JSON values across literal reads, inferred parameters, and explicit parameter typing.
async fn assert_json_roundtrip(
  client : @client.Client,
  sql_type : String,
  param_type : @client.Type,
) -> Unit {
  let expected = Json::object({
    "lang": Json::string("moonbit"),
    "ok": Json::boolean(true),
    "count": Json::number(2.0),
  })
  let literal = "'{\"lang\":\"moonbit\",\"ok\":true,\"count\":2}'"

  let from_literal : Json = client
    .query_one("select \{literal}::\{sql_type} as value")
    .get_name("value")
  assert_eq(from_literal, expected)

  let params : Array[&@client.ToSql] = [expected as &@client.ToSql]
  let from_param : Json = client
    .query_one("select $1::\{sql_type} as value", params~)
    .get_name("value")
  assert_eq(from_param, expected)

  let typed_rows = client
    .query_typed("select $1::\{sql_type} as value", [param_type], params~)
    .collect()
  assert_eq(typed_rows.length(), 1)
  let from_typed : Json = typed_rows[0].get_name("value")
  assert_eq(from_typed, expected)
}

///|
/// The `double precision` version of the NaN round-trip test.
async fn assert_double_nan_roundtrip(client : @client.Client) -> Unit {
  let from_literal : Double = client
    .query_one("select 'NaN'::double precision as value")
    .get_name("value")
  assert_true(from_literal.is_nan())

  let params : Array[&@client.ToSql] = [@double.not_a_number as &@client.ToSql]
  let from_param : Double = client
    .query_one("select $1::double precision as value", params~)
    .get_name("value")
  assert_true(from_param.is_nan())

  let typed_rows = client
    .query_typed(
      "select $1::double precision as value",
      [@client.Type::float8()],
      params~,
    )
    .collect()
  assert_eq(typed_rows.length(), 1)
  let from_typed : Double = typed_rows[0].get_name("value")
  assert_true(from_typed.is_nan())
}

///|
/// This verifies basic connection setup, background connection driving, and column-based decoding.
/// One query returns text, integer, and boolean values together so the test covers common typed reads by column name.
async test "integration connect and typed query" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    let row = client.query_one(
      "select current_user::text as current_user, current_database()::text as current_database, 42::int4 as answer, true::bool as enabled",
    )
    let current_user : String = row.get_name("current_user")
    let current_database : String = row.get_name("current_database")
    let answer : Int = row.get_name("answer")
    let enabled : Bool = row.get_name("enabled")
    assert_eq(current_user, config.user)
    assert_eq(current_database, config.database)
    assert_eq(answer, 42)
    assert_eq(enabled, true)

    client.close()
  })
}

///|
/// This verifies the successful TLS path for `verify_ca`.
/// The helper checks the handshake details. This test just exercises that configuration branch.
async test "integration tls verify_ca connects and queries" {
  guard integration_config() is Some(config) else { return }
  guard !integration_tls_failure_expected() else { return }
  assert_tls_query_ok(
    as_client_config(
      config,
      ssl_mode=@client.SslMode::VerifyCa,
      application_name="moonbit-postgres-tls-verify-ca",
    ),
  )
}

///|
/// This verifies the successful TLS path for `verify_full`.
async test "integration tls verify_full connects and queries" {
  guard integration_config() is Some(config) else { return }
  guard !integration_tls_failure_expected() else { return }
  assert_tls_query_ok(
    as_client_config(
      config,
      ssl_mode=@client.SslMode::VerifyFull,
      application_name="moonbit-postgres-tls-verify-full",
    ),
  )
}

///|
/// This verifies that an untrusted server certificate fails during TLS setup.
/// The assertion only captures the certificate-verification meaning and does not tie itself to one exact TLS-library error string.
async test "integration tls rejects untrusted server certificate" {
  guard integration_config() is Some(config) else { return }
  guard integration_tls_failure_expected() else { return }

  let message = expect_ssl_error(
    try? @client.connect(
      as_client_config(
        config,
        ssl_mode=@client.SslMode::VerifyFull,
        application_name="moonbit-postgres-tls-untrusted",
      ),
    ),
  )
  assert_true(
    message.contains("certificate") ||
    message.contains("verify") ||
    message.contains("unknown ca") ||
    message.contains("alert"),
  )
}

///|
/// This verifies that `verify_ca` checks the certificate chain but not the hostname.
/// The test intentionally mismatches `host` against the certificate name while still connecting to the real address through `hostaddr`.
async test "integration tls verify_ca ignores hostname mismatch" {
  guard integration_config() is Some(config) else { return }
  guard !integration_tls_failure_expected() else { return }
  assert_tls_query_ok(
    as_client_config(
      config,
      host="db.invalid",
      hostaddr=config.host,
      ssl_mode=@client.SslMode::VerifyCa,
      application_name="moonbit-postgres-tls-verify-ca-host-mismatch",
    ),
  )
}

///|
/// This verifies that `verify_full` treats a hostname mismatch as an error.
/// The setup is similar to the previous test, but this time the connection must fail.
async test "integration tls verify_full rejects hostname mismatch" {
  guard integration_config() is Some(config) else { return }
  guard !integration_tls_failure_expected() else { return }
  let message = expect_ssl_error(
    try? @client.connect(
      as_client_config(
        config,
        host="db.invalid",
        hostaddr=config.host,
        ssl_mode=@client.SslMode::VerifyFull,
        application_name="moonbit-postgres-tls-verify-full-host-mismatch",
      ),
    ),
  )
  assert_true(
    message.contains("hostname") ||
    message.contains("IP") ||
    message.contains("host") ||
    message.contains("verify"),
  )
}

///|
/// This verifies that `verify_full` can use an explicit `hostaddr` as the identity target when there is no DNS hostname.
async test "integration tls verify_full accepts explicit hostaddr identity" {
  guard integration_config() is Some(config) else { return }
  guard !integration_tls_failure_expected() else { return }
  assert_tls_query_ok(
    as_client_config(
      config,
      host="",
      hostaddr=config.host,
      ssl_mode=@client.SslMode::VerifyFull,
      application_name="moonbit-postgres-tls-verify-full-hostaddr",
    ),
  )
}

///|
/// This verifies the local config precondition for `verify_full`.
/// If neither `host` nor `hostaddr` is available for identity checks, the client should reject the config before attempting the connection.
async test "integration tls verify_full requires explicit host or hostaddr" {
  guard integration_config() is Some(config) else { return }
  let message = expect_ssl_error(
    try? @client.connect(
      @client.Config::new(
        "",
        user=config.user,
        database=config.database,
        password=config.password,
        port=config.port,
        ssl_mode=@client.SslMode::VerifyFull,
        application_name="moonbit-postgres-tls-verify-full-missing-host",
      ),
    ),
  )
  assert_eq(message, "sslmode=verify-full requires explicit host or hostaddr")
}

///|
/// This verifies that `sslrootcert=system` is only valid together with `verify_full`.
async test "integration tls sslrootcert system requires verify_full" {
  guard integration_config() is Some(config) else { return }
  let message = expect_ssl_error(
    try? @client.connect(
      as_client_config(
        config,
        ssl_mode=@client.SslMode::VerifyCa,
        ssl_root_cert="system",
        application_name="moonbit-postgres-tls-system-root-invalid",
      ),
    ),
  )
  assert_eq(message, "sslrootcert=system requires sslmode=verify-full")
}

///|
/// This verifies the successful path for `sslrootcert=system` together with `verify_full`.
async test "integration tls sslrootcert system works with verify_full" {
  guard integration_config() is Some(config) else { return }
  guard !integration_tls_failure_expected() else { return }
  assert_tls_query_ok(
    as_client_config(
      config,
      ssl_mode=@client.SslMode::VerifyFull,
      ssl_root_cert="system",
      application_name="moonbit-postgres-tls-system-root",
    ),
  )
}

///|
/// This covers the missing-password error path for cleartext password authentication.
/// The helper owns the connection setup and the error extraction. This test only selects the cleartext account case.
async test "integration plain password missing" {
  guard integration_config() is Some(config) else { return }
  assert_missing_password(config, "moon_password")
}

///|
/// This verifies that cleartext password authentication returns the standard auth failure for a wrong password.
async test "integration plain password wrong" {
  guard integration_config() is Some(config) else { return }
  assert_wrong_password(config, "moon_password")
}

///|
/// This verifies the successful path for cleartext password authentication.
async test "integration plain password ok" {
  guard integration_config() is Some(config) else { return }
  assert_auth_ok(config, "moon_password", "moonpass")
}

///|
/// This covers the missing-password error path for SCRAM authentication.
async test "integration scram password missing" {
  guard integration_config() is Some(config) else { return }
  assert_missing_password(config, "moon_scram")
}

///|
/// This covers the wrong-password error path for SCRAM authentication.
async test "integration scram password wrong" {
  guard integration_config() is Some(config) else { return }
  assert_wrong_password(config, "moon_scram")
}

///|
/// This verifies the successful path for SCRAM authentication.
async test "integration scram password ok" {
  guard integration_config() is Some(config) else { return }
  assert_auth_ok(config, "moon_scram", "moonpass")
}

///|
/// This verifies that `check_connection` only performs a health check and does not damage the connection state.
/// A normal query runs afterward to prove that the connection is still usable.
async test "integration check connection" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    client.check_connection()
    let value : Int = client
      .query_one("select 1::int4 as value")
      .get_name("value")
    assert_eq(value, 1)

    client.close()
  })
}

///|
/// This verifies that both the client and the background connection task can see the parameters negotiated at startup.
/// The point is to confirm that those parameters are cached and exposed through the public accessors.
async test "integration exposes startup parameters" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    assert_eq(client.parameter("client_encoding"), Some("UTF8"))
    assert_eq(connection.parameter("client_encoding"), Some("UTF8"))
    assert_eq(client.parameter("application_name"), Some("moonbit-postgres"))
    assert_eq(
      connection.parameter("application_name"),
      Some("moonbit-postgres"),
    )

    client.close()
  })
}

///|
/// This verifies the parameterized execution path after an explicit prepare.
/// The test prepares a statement, sends two parameters, and reads the result back by column name.
async test "integration prepare and parameterized execute" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    let statement = client.prepare(
      "select $1::int4 as id, $2::text as name, ($1::int4 + 1)::int4 as next_id",
    )
    let params : Array[&@client.ToSql] = [
      7 as &@client.ToSql,
      "moonbit" as &@client.ToSql,
    ]
    let stream = client.query_statement(statement, params~)
    let rows = stream.collect()
    assert_eq(rows.length(), 1)
    let row = rows[0]
    let id : Int = row.get_name("id")
    let name : String = row.get_name("name")
    let next_id : Int = row.get_name("next_id")
    assert_eq(id, 7)
    assert_eq(name, "moonbit")
    assert_eq(next_id, 8)

    client.close()
  })
}

///|
/// This verifies that temporary prepared statements created inside convenience APIs like `query_one` are closed promptly.
/// The test counts `pg_prepared_statements` before and after repeated parameterized queries so temporary server-side statements do not accumulate.
async test "integration raw query closes temporary prepared statements" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    let before : Int = client
      .query_one("select count(*)::int4 as count from pg_prepared_statements")
      .get_name("count")
    // Repeat convenience queries with parameters to cover the path that creates and then auto-cleans temporary statements.
    for value in 0..<5 {
      let params : Array[&@client.ToSql] = [value as &@client.ToSql]
      let row = client.query_one("select $1::int4 as value", params~)
      let observed : Int = row.get_name("value")
      assert_eq(observed, value)
    }
    let after : Int = client
      .query_one("select count(*)::int4 as count from pg_prepared_statements")
      .get_name("count")
    assert_eq(after, before)

    client.close()
  })
}

///|
/// This verifies that after a row stream is detached early, the driver cleans up its temporary prepared statement.
/// The test reads one row, detaches the stream, and then immediately checks the prepared-statement count on the server.
async test "integration row stream detach closes temporary prepared statements" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    let before : Int = client
      .query_one("select count(*)::int4 as count from pg_prepared_statements")
      .get_name("count")

    // Read only the first row and leave the rest for the cleanup path that runs after detach.
    let stream = client.query(
      "select generate_series(1, 16)::int4 as value order by value",
    )
    guard stream.next() is Some(first_row) else { fail("expected first row") }
    let first_value : Int = first_row.get_name("value")
    assert_eq(first_value, 1)

    stream.detach()

    let task = group.spawn(no_wait=true, () => {
      let count : Int = client
        .query_one("select count(*)::int4 as count from pg_prepared_statements")
        .get_name("count")
      count
    })

    assert_eq(
      wait_for_task_or_fail(
        task, "expected detached temporary statement cleanup to complete",
      ),
      before,
    )

    client.close()
  })
}

///|
/// This verifies that simple query can produce multiple result sets in sequence.
/// The test reads the column descriptions, data rows, and command tags for both `SELECT` statements in message order.
async test "integration simple query supports multiple result sets" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    let stream = client.simple_query(
      "select 'left'::text as side, null::text as missing; select 'right'::text as side",
    )
    guard stream.next()
      is Some(@client.SimpleQueryMessage::RowDescription(left_columns)) else {
      fail("expected first row description")
    }
    guard stream.next() is Some(@client.SimpleQueryMessage::Row(left_row)) else {
      fail("expected first row")
    }
    guard stream.next()
      is Some(@client.SimpleQueryMessage::CommandComplete(left_tag)) else {
      fail("expected first command tag")
    }
    guard stream.next()
      is Some(@client.SimpleQueryMessage::RowDescription(right_columns)) else {
      fail("expected second row description")
    }
    guard stream.next() is Some(@client.SimpleQueryMessage::Row(right_row)) else {
      fail("expected second row")
    }
    guard stream.next()
      is Some(@client.SimpleQueryMessage::CommandComplete(right_tag)) else {
      fail("expected second command tag")
    }
    @debug.assert_eq(stream.next(), None)
    assert_eq(left_columns, ["side", "missing"])
    assert_eq(try! left_row.get_name("side"), Some("left"))
    assert_eq(try! left_row.get_name("missing"), None)
    assert_eq(left_tag, "SELECT 1")
    assert_eq(right_columns, ["side"])
    assert_eq(try! right_row.get_name("side"), Some("right"))
    assert_eq(right_tag, "SELECT 1")

    client.close()
  })
}

///|
/// This verifies that simple-query result streams support pipelining.
/// The test consumes only part of the first result, then starts another ordinary query and checks that the driver can still move later work forward.
async test "integration simple query supports pipelining" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    let stream = client.simple_query(
      "select generate_series(1, 3)::int4 as value; select 'done'::text as marker",
    )
    guard stream.next()
      is Some(@client.SimpleQueryMessage::RowDescription(columns)) else {
      fail("expected row description")
    }
    assert_eq(columns, ["value"])
    guard stream.next() is Some(@client.SimpleQueryMessage::Row(row)) else {
      fail("expected first row")
    }
    assert_eq(try! row.get_name("value"), Some("1"))

    // If the simple-query stream held the connection until full completion, this concurrent query would stay blocked.
    let task = group.spawn(no_wait=true, () => {
      let result : Int = client
        .query_one("select 9::int4 as value")
        .get_name("value")
      result
    })
    assert_eq(
      wait_for_task_or_fail(
        task, "expected pipelined query to finish before simple query stream completion",
      ),
      9,
    )

    stream.finish()

    client.close()
  })
}

///|
/// This verifies that a simple-query stream gives protocol execution back to later requests after `detach`.
/// The test first shows that the next query blocks before detach, then shows that it resumes afterward, and also checks the explicit error on repeated detach.
async test "integration simple query detach unblocks later requests" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    let stream = client.simple_query(
      "select generate_series(1, 16)::int4 as value order by value",
    )
    guard stream.next()
      is Some(@client.SimpleQueryMessage::RowDescription(columns)) else {
      fail("expected row description")
    }
    assert_eq(columns, ["value"])
    guard stream.next() is Some(@client.SimpleQueryMessage::Row(row)) else {
      fail("expected first row")
    }
    assert_eq(try! row.get_name("value"), Some("1"))

    let task = group.spawn(no_wait=true, () => {
      let value : Int = client
        .query_one("select 13::int4 as value")
        .get_name("value")
      value
    })

    assert_task_stays_pending(
      task, "expected follow-up query to stay blocked before detaching simple query stream",
    )

    stream.detach()
    stream.detach()

    let closed_message = expect_closed_error(try? stream.next())
    assert_eq(closed_message, "simple query stream already detached")

    assert_eq(
      wait_for_task_or_fail(
        task, "expected detach to let the blocked simple query complete",
      ),
      13,
    )

    client.close()
  })
}

///|
/// This verifies that simple-query `detach` swallows database errors that would appear later in the stream.
/// That lets callers explicitly abandon the remaining results and continue using the same connection.
async test "integration simple query detach swallows trailing database error" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    let stream = client.simple_query("select 'ok'::text as value; select 1 / 0")
    guard stream.next()
      is Some(@client.SimpleQueryMessage::RowDescription(columns)) else {
      fail("expected row description")
    }
    assert_eq(columns, ["value"])
    guard stream.next() is Some(@client.SimpleQueryMessage::Row(row)) else {
      fail("expected first row")
    }
    assert_eq(try! row.get_name("value"), Some("ok"))

    stream.detach()

    let value : Int = client
      .query_one("select 21::int4 as value")
      .get_name("value")
    assert_eq(value, 21)

    client.close()
  })
}

///|
/// This verifies portal-based pagination.
/// The test binds a portal inside a transaction, fetches three times, and checks that the batches are 2 rows, then 1 row, then empty.
async test "integration portal pagination" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    client.batch_execute(
      "create temp table moon_driver_portal (id serial, name text)",
    )
    client.batch_execute(
      "insert into moon_driver_portal (name) values ('alice'), ('bob'), ('charlie')",
    )
    // A portal has a stable lifetime only inside a transaction, so the test starts one explicitly.
    let statement = client.prepare(
      "select id, name from moon_driver_portal order by id",
    )
    let tx = client.transaction()
    let portal = tx.bind(statement)
    let first = tx.query_portal(portal, 2).collect()
    let second = tx.query_portal(portal, 2).collect()
    let third = tx.query_portal(portal, 2).collect()
    portal.close()
    tx.commit()

    assert_eq(first.length(), 2)
    let first_id : Int = first[0].get_name("id")
    let first_name : String = first[0].get_name("name")
    let second_id : Int = first[1].get_name("id")
    let second_name : String = first[1].get_name("name")
    assert_eq(first_id, 1)
    assert_eq(first_name, "alice")
    assert_eq(second_id, 2)
    assert_eq(second_name, "bob")

    assert_eq(second.length(), 1)
    let third_id : Int = second[0].get_name("id")
    let third_name : String = second[0].get_name("name")
    assert_eq(third_id, 3)
    assert_eq(third_name, "charlie")
    assert_eq(third.length(), 0)

    client.close()
  })
}

///|
/// This verifies that row streams returned by extended queries also support pipelining.
/// The pattern matches the simple-query case: consume one row, start another query concurrently, then finish the stream and check its summary.
async test "integration row stream supports pipelining" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    let stream = client.query(
      "select generate_series(1, 3)::int4 as value order by value",
    )
    let columns = stream.columns
    assert_eq(columns.length(), 1)
    assert_eq(columns[0].name, "value")
    guard stream.next() is Some(first_row) else { fail("expected first row") }
    let first_value : Int = first_row.get_name("value")
    assert_eq(first_value, 1)

    let task = group.spawn(no_wait=true, () => {
      let value : Int = client
        .query_one("select 5::int4 as value")
        .get_name("value")
      value
    })
    assert_eq(
      wait_for_task_or_fail(
        task, "expected pipelined query to finish before row stream completion",
      ),
      5,
    )

    let summary = stream.finish()
    assert_eq(summary.row_count, 3)
    assert_eq(summary.suspended, false)

    client.close()
  })
}

///|
/// This verifies that row streams do not buffer forever behind the scenes.
/// While the result set is still not fully consumed, later queries should remain blocked. They should resume only after the stream is drained.
async test "integration row stream backpressures after bounded buffering" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    let stream = client.query(
      "select generate_series(1, 16)::int4 as value order by value",
    )
    let task = group.spawn(no_wait=true, () => {
      let value : Int = client
        .query_one("select 7::int4 as value")
        .get_name("value")
      value
    })

    assert_task_stays_pending(
      task, "expected bounded buffering to keep the follow-up query blocked",
    )

    let summary = stream.finish()
    assert_eq(summary.row_count, 16)
    assert_eq(
      wait_for_task_or_fail(
        task, "expected blocked query to complete after draining buffered rows",
      ),
      7,
    )

    client.close()
  })
}

///|
/// This verifies that a row stream terminates itself after `detach` and hands the connection back to later requests.
/// It also covers repeated detach calls and the explicit error message they return.
async test "integration row stream detach unblocks later requests" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    let stream = client.query(
      "select generate_series(1, 16)::int4 as value order by value",
    )
    guard stream.next() is Some(first_row) else { fail("expected first row") }
    let first_value : Int = first_row.get_name("value")
    assert_eq(first_value, 1)

    let task = group.spawn(no_wait=true, () => {
      let value : Int = client
        .query_one("select 15::int4 as value")
        .get_name("value")
      value
    })

    assert_task_stays_pending(
      task, "expected follow-up query to stay blocked before detaching row stream",
    )

    stream.detach()
    stream.detach()

    let closed_message = expect_closed_error(try? stream.finish())
    assert_eq(closed_message, "row stream already detached")

    assert_eq(
      wait_for_task_or_fail(
        task, "expected detach to let the blocked row-stream query complete",
      ),
      15,
    )

    client.close()
  })
}

///|
/// This verifies that writes made inside a transaction become visible to later queries in the same session after commit.
/// The test inserts one row in a transaction, commits it, and then checks the temp table outside the transaction.
async test "integration transaction commit" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    let tx = client.transaction()
    tx.batch_execute(
      "create temp table moon_driver_tx (id int primary key, name text not null)",
    )
    let params : Array[&@client.ToSql] = [
      1 as &@client.ToSql,
      "alpha" as &@client.ToSql,
    ]
    let inserted = tx.execute(
      "insert into moon_driver_tx(id, name) values ($1::int4, $2::text)",
      params~,
    )
    assert_eq(inserted, 1)
    tx.commit()

    let rows = client.query("select id, name from moon_driver_tx").collect()
    assert_eq(rows.length(), 1)
    let id : Int = rows[0].get_name("id")
    let name : String = rows[0].get_name("name")
    assert_eq(id, 1)
    assert_eq(name, "alpha")

    client.close()
  })
}

///|
/// This verifies that rollback discards the writes performed earlier in the transaction.
/// It mirrors the commit test, but rolls back at the end and checks that the table stays empty.
async test "integration transaction rollback" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    client.batch_execute(
      "create temp table moon_driver_tx_rollback (id int primary key, name text not null)",
    )
    let tx = client.transaction()
    let params : Array[&@client.ToSql] = [
      1 as &@client.ToSql,
      "steven" as &@client.ToSql,
    ]
    let inserted = tx.execute(
      "insert into moon_driver_tx_rollback(id, name) values ($1::int4, $2::text)",
      params~,
    )
    assert_eq(inserted, 1)
    tx.rollback()

    let count : Int = client
      .query_one("select count(*)::int4 as count from moon_driver_tx_rollback")
      .get_name("count")
    assert_eq(count, 0)

    client.close()
  })
}

///|
/// This verifies that the transaction builder carries isolation level, read-only, and deferrable options into the transaction.
/// The test reads the settings back with `show`, then performs a write and commits to prove the transaction object itself still works.
async test "integration transaction builder" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    client.batch_execute(
      "create temp table moon_driver_tx_builder (id serial, name text)",
    )
    let tx = client
      .build_transaction()
      .isolation_level("SERIALIZABLE")
      .read_only()
      .deferrable()
      .start()
    let isolation : String = tx.query("show transaction_isolation").collect()[0].get_name(
      "transaction_isolation",
    )
    let read_only : String = tx.query("show transaction_read_only").collect()[0].get_name(
      "transaction_read_only",
    )
    let deferrable : String = tx.query("show transaction_deferrable").collect()[0].get_name(
      "transaction_deferrable",
    )
    assert_eq(isolation, "serializable")
    assert_eq(read_only, "on")
    assert_eq(deferrable, "on")

    let params : Array[&@client.ToSql] = ["steven" as &@client.ToSql]
    let inserted = tx.execute(
      "insert into moon_driver_tx_builder(name) values ($1::text)",
      params~,
    )
    assert_eq(inserted, 1)
    tx.commit()

    let rows = client
      .query("select name from moon_driver_tx_builder order by id")
      .collect()
    assert_eq(rows.length(), 1)
    let name : String = rows[0].get_name("name")
    assert_eq(name, "steven")

    client.close()
  })
}

///|
/// This verifies that a cancel token can interrupt a running ordinary client query.
/// The observer connection first confirms that the target query reached `pg_sleep`, then cancellation is triggered, and finally the connection is checked for reuse.
async test "integration cancel token cancels running query" {
  guard integration_config() is Some(config) else { return }

  let result = @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(
        config,
        application_name="moonbit-postgres-client-cancel-main",
      ),
    )
    group.spawn_bg(() => connection.run())

    let (observer, observer_connection) = @client.connect(
      as_client_config(
        config,
        application_name="moonbit-postgres-client-cancel-observer",
      ),
    )
    group.spawn_bg(() => observer_connection.run())

    // The observer connection exists only to provide a reliable "the query is really running" sync point.
    let token = client.cancel_token()
    let backend_pid : Int = client
      .query_one("select pg_backend_pid()::int4 as pid")
      .get_name("pid")
    let task = group.spawn(() => try? client.query_one("select pg_sleep(5)"))

    wait_for_backend_query(observer, backend_pid, "select pg_sleep(5)")
    token.cancel()

    let err = expect_database_error(task.wait())
    assert_eq(err.code, Some("57014"))
    let value : Int = client
      .query_one("select 1::int4 as value")
      .get_name("value")
    assert_eq(value, 1)

    client.close()
    observer.close()
  })
  ignore(result)
}

///|
/// This verifies that PostgreSQL notices and notifications surface through the driver's async message channel.
/// The test emits two notices and two notifications, then consumes the messages in order and checks their fields.
async test "integration notice and notification surface as async messages" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    client.batch_execute("set client_min_messages = notice")
    client.batch_execute("listen moon_driver_notification")
    client.batch_execute(
      "do $$ begin raise notice 'integration notice 1'; end $$;",
    )
    client.batch_execute(
      "do $$ begin raise notice 'integration notice 2'; end $$;",
    )
    client.batch_execute("notify moon_driver_notification, 'hello'")
    client.batch_execute("notify moon_driver_notification, 'world'")

    // Filter out parameter-status messages first so the test can focus only on notice and notification payloads.
    let messages = collect_driver_async_messages(connection, 4)
    guard messages[0] is @client.AsyncMessage::Notice(first_notice) else {
      fail("expected first notice")
    }
    guard messages[1] is @client.AsyncMessage::Notice(second_notice) else {
      fail("expected second notice")
    }
    guard messages[2] is @client.AsyncMessage::Notification(first_notification) else {
      fail("expected first notification")
    }
    guard messages[3] is @client.AsyncMessage::Notification(second_notification) else {
      fail("expected second notification")
    }
    assert_eq(first_notice.message, "integration notice 1")
    assert_eq(second_notice.message, "integration notice 2")
    assert_eq(first_notification.channel, "moon_driver_notification")
    assert_eq(first_notification.payload, "hello")
    assert_eq(second_notification.channel, "moon_driver_notification")
    assert_eq(second_notification.payload, "world")

    client.close()
  })
}

///|
/// This verifies the basic read path for COPY OUT.
/// The test joins all chunks back into one buffer and then checks both the format codes and the final text payload.
async test "integration copy out" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    client.batch_execute(
      "create temp table moon_driver_copy_out (id int, name text)",
    )
    client.batch_execute(
      "insert into moon_driver_copy_out(id, name) values (1, 'jim'), (2, 'joe')",
    )
    let stream = client.copy_out(
      "copy (select id, name from moon_driver_copy_out order by id) to stdout",
    )
    let chunks : Array[Bytes] = []
    let payload = @buffer.new()
    for chunk = stream.next() {
      match chunk {
        None => break ()
        Some(chunk) => {
          chunks.push(chunk)
          payload.write_bytes(chunk)
          continue stream.next()
        }
      }
    }
    assert_true(
      stream.formats == [@client.WireFormat::Text, @client.WireFormat::Text],
    )
    assert_true(chunks.length() >= 1)
    assert_eq(payload.contents(), b"1\tjim\n2\tjoe\n")

    client.close()
  })
}

///|
/// This verifies that a COPY OUT stream still allows later queries to be pipelined before the stream is fully consumed.
/// The test reads one chunk, starts a normal query, and then calls `finish` to cleanly drain the stream.
async test "integration copy out supports pipelining" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    client.batch_execute(
      "create temp table moon_driver_copy_out_finish (id int, name text)",
    )
    client.batch_execute(
      "insert into moon_driver_copy_out_finish(id, name) values (1, 'jim'), (2, 'joe'), (3, 'jan')",
    )
    let stream = client.copy_out(
      "copy moon_driver_copy_out_finish (id, name) to stdout",
    )
    assert_true(
      stream.formats == [@client.WireFormat::Text, @client.WireFormat::Text],
    )
    guard stream.next() is Some(chunk) else { fail("expected copy chunk") }
    assert_true(chunk.length() > 0)

    let task = group.spawn(no_wait=true, () => {
      let value : Int = client
        .query_one("select 11::int4 as value")
        .get_name("value")
      value
    })
    assert_eq(
      wait_for_task_or_fail(
        task, "expected pipelined query to finish before copy out completion",
      ),
      11,
    )

    stream.finish()

    client.close()
  })
}

///|
/// This verifies that a COPY OUT stream hands the connection back to later requests after `detach`.
/// The test again shows blocking before detach, recovery after detach, and the explicit error on repeated detach.
async test "integration copy out detach unblocks later requests" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    let stream = client.copy_out(
      "copy (select repeat('x', 32768) from generate_series(1, 32)) to stdout",
    )
    guard stream.next() is Some(chunk) else { fail("expected copy chunk") }
    assert_true(chunk.length() > 0)

    let task = group.spawn(no_wait=true, () => {
      let value : Int = client
        .query_one("select 17::int4 as value")
        .get_name("value")
      value
    })

    assert_task_stays_pending(
      task, "expected follow-up query to stay blocked before detaching copy out stream",
    )

    stream.detach()
    stream.detach()

    let closed_message = expect_closed_error(try? stream.next())
    assert_eq(closed_message, "copy out stream already detached")

    assert_eq(
      wait_for_task_or_fail(
        task, "expected detach to let the blocked copy out query complete",
      ),
      17,
    )

    client.close()
  })
}

///|
/// This verifies the basic write path for COPY IN.
/// The test sends two text rows into the sink, finishes the copy, and then checks both row count and row contents in the temp table.
async test "integration copy in" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    client.batch_execute(
      "create temp table moon_driver_copy_in (id int not null, name text not null)",
    )
    let sink = client.copy_in("copy moon_driver_copy_in (id, name) from stdin")
    sink.send(b"1\tjim\n2\tjoe\n")
    let copied = sink.finish()
    assert_eq(copied, 2)

    let rows = client
      .query("select id, name from moon_driver_copy_in order by id")
      .collect()
    assert_eq(rows.length(), 2)
    let id1 : Int = rows[0].get_name("id")
    let name1 : String = rows[0].get_name("name")
    let id2 : Int = rows[1].get_name("id")
    let name2 : String = rows[1].get_name("name")
    assert_eq(id1, 1)
    assert_eq(name1, "jim")
    assert_eq(id2, 2)
    assert_eq(name2, "joe")

    client.close()
  })
}

///|
/// This verifies that COPY IN still works when a large amount of data is sent in batches.
/// The test splits 10000 rows across three writes to cover large buffers and repeated `send` calls together.
async test "integration copy in large" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    client.batch_execute(
      "create temp table moon_driver_copy_in_large (id int not null, name text not null)",
    )
    let sink = client.copy_in(
      "copy moon_driver_copy_in_large (id, name) from stdin",
    )
    // Send in three chunks on purpose to cover the repeated-write path on the sink.
    sink.send(b"0\tname0\n")

    let first = @buffer.new()
    for i in 1..<5000 {
      first.write_bytes(@proto.utf8_encode("\{i}\tname\{i}\n"))
    }
    sink.send(first.contents())

    let second = @buffer.new()
    for i in 5000..<10000 {
      second.write_bytes(@proto.utf8_encode("\{i}\tname\{i}\n"))
    }
    sink.send(second.contents())

    let copied = sink.finish()
    assert_eq(copied, 10000)

    let count : Int = client
      .query_one(
        "select count(*)::int4 as count from moon_driver_copy_in_large",
      )
      .get_name("count")
    assert_eq(count, 10000)

    client.close()
  })
}

///|
/// This verifies that aborting COPY IN rolls back the import instead of leaving partial rows behind.
async test "integration copy in abort rolls back copy" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    client.batch_execute(
      "create temp table moon_driver_copy_abort (id int not null, name text not null)",
    )
    let sink = client.copy_in(
      "copy moon_driver_copy_abort (id, name) from stdin",
    )
    sink.send(b"1\tsteven\n")
    sink.abort()

    let count : Int = client
      .query_one("select count(*)::int4 as count from moon_driver_copy_abort")
      .get_name("count")
    assert_eq(count, 0)

    client.close()
  })
}

///|
/// This verifies the three result branches of `query_one`.
/// Zero rows should be an error, exactly one row should succeed, and more than one row should be a row-count error.
async test "integration query one" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    client.batch_execute("create temp table moon_driver_query_one (name text)")
    client.batch_execute(
      "insert into moon_driver_query_one (name) values ('alice'), ('bob'), ('carol')",
    )

    let none_message = expect_row_count_error(
      try? client.query_one(
        "select * from moon_driver_query_one where name = 'dave'",
      ),
    )
    assert_eq(none_message, "expected exactly one row, got 0")

    let row = client.query_one(
      "select * from moon_driver_query_one where name = 'alice'",
    )
    let name : String = row.get_name("name")
    assert_eq(name, "alice")

    let many_message = expect_row_count_error(
      try? client.query_one("select * from moon_driver_query_one"),
    )
    assert_eq(many_message, "expected exactly one row, got 3")

    client.close()
  })
}

///|
/// This verifies that `query_opt` differs from `query_one` only in the zero-row case.
/// Zero rows should return `None`, while one row still succeeds and multiple rows still fail.
async test "integration query opt" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    client.batch_execute("create temp table moon_driver_query_opt (name text)")
    client.batch_execute(
      "insert into moon_driver_query_opt (name) values ('alice'), ('bob'), ('carol')",
    )

    let none_row = client.query_opt(
      "select * from moon_driver_query_opt where name = 'dave'",
    )
    @debug.assert_eq(none_row, None)

    guard client.query_opt(
        "select * from moon_driver_query_opt where name = 'alice'",
      )
      is Some(row) else {
      fail("expected row")
    }
    let name : String = row.get_name("name")
    @debug.assert_eq(name, "alice")

    let many_message = expect_row_count_error(
      try? client.query_opt("select * from moon_driver_query_opt"),
    )
    assert_eq(many_message, "expected zero or one row, got 3")

    client.close()
  })
}

///|
/// This verifies that a deferred unique constraint fires at commit time instead of insert time.
/// The test inserts duplicate values in one transaction, gets the unique-constraint error on commit, and then checks that the whole transaction rolled back.
async test "integration deferred constraint" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    client.batch_execute(
      "create temp table moon_driver_deferred_constraint (i int, unique (i) deferrable initially deferred)",
    )
    let tx = client.transaction()
    assert_eq(
      tx.execute("insert into moon_driver_deferred_constraint (i) values (1)"),
      1,
    )
    assert_eq(
      tx.execute("insert into moon_driver_deferred_constraint (i) values (1)"),
      1,
    )
    let err = expect_database_error(try? tx.commit())
    assert_eq(err.code, Some("23505"))
    let count : Int = client
      .query_one(
        "select count(*)::int4 as count from moon_driver_deferred_constraint",
      )
      .get_name("count")
    assert_eq(count, 0)

    client.close()
  })
}

///|
/// This verifies that `query_typed` still works with explicit parameter types even without an explicit transaction.
/// The test first runs a query with text and integer parameters, then runs an `update` with no rows returned so both branches are covered.
async test "integration query typed without transaction" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    client.batch_execute(
      "create temp table moon_driver_query_typed (name text, age int)",
    )
    client.batch_execute(
      "insert into moon_driver_query_typed (name, age) values ('alice', 20), ('bob', 30), ('carol', 40)",
    )

    let params : Array[&@client.ToSql] = [
      "alice" as &@client.ToSql,
      50 as &@client.ToSql,
    ]
    let rows = client
      .query_typed(
        "select name, age, 'literal'::text as literal, 5::int4 as number from moon_driver_query_typed where name <> $1 and age < $2 order by age",
        [@client.Type::text(), @client.Type::int4()],
        params~,
      )
      .collect()
    assert_eq(rows.length(), 2)

    let first_name : String = rows[0].get_name("name")
    let first_age : Int = rows[0].get_name("age")
    let first_literal : String = rows[0].get_name("literal")
    let first_number : Int = rows[0].get_name("number")
    assert_eq(first_name, "bob")
    assert_eq(first_age, 30)
    assert_eq(first_literal, "literal")
    assert_eq(first_number, 5)

    let second_name : String = rows[1].get_name("name")
    let second_age : Int = rows[1].get_name("age")
    let second_literal : String = rows[1].get_name("literal")
    let second_number : Int = rows[1].get_name("number")
    assert_eq(second_name, "carol")
    assert_eq(second_age, 40)
    assert_eq(second_literal, "literal")
    assert_eq(second_number, 5)

    let no_types : Array[@client.Type] = []
    let updated = client
      .query_typed("update moon_driver_query_typed set age = 33", no_types)
      .collect()
    assert_eq(updated.length(), 0)

    client.close()
  })
}

///|
/// This verifies round-trip consistency for common scalar types between the client and PostgreSQL.
/// Each type goes through literal reads, bound parameters, and typed queries so both encoding and decoding paths are covered.
async test "integration scalar type roundtrips" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    assert_roundtrip(client, "bool", @client.Type::bool(), "true", true)
    assert_roundtrip(client, "smallint", @client.Type::int2(), "15001", 15001)
    assert_roundtrip(
      client,
      "integer",
      @client.Type::int4(),
      "-2147483548",
      -2147483548,
    )
    assert_roundtrip(
      client,
      "bigint",
      @client.Type::int8(),
      "9223372036854775708",
      9223372036854775708L,
    )
    assert_roundtrip(
      client,
      "oid",
      @client.Type::oid_type(),
      "4000000000",
      4000000000U,
    )
    assert_roundtrip(
      client,
      "name",
      @client.Type::name_type(),
      "'hello world'",
      "hello world",
    )
    assert_roundtrip(
      client,
      "varchar",
      @client.Type::varchar(),
      "'hello world'",
      "hello world",
    )
    assert_roundtrip(
      client,
      "text",
      @client.Type::text(),
      "'hello world'",
      "hello world",
    )
    assert_json_roundtrip(client, "json", @client.Type::json())
    assert_json_roundtrip(client, "jsonb", @client.Type::jsonb())

    client.close()
  })
}

///|
/// This verifies that floating-point special values and ordinary numeric values all round-trip correctly.
/// Infinity, -Infinity, and NaN are split out because NaN has to be checked with `is_nan()`.
async test "integration float roundtrips" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    assert_roundtrip(
      client,
      "real",
      @client.Type::float4(),
      "'Infinity'",
      @float.infinity,
    )
    assert_roundtrip(
      client,
      "real",
      @client.Type::float4(),
      "'-Infinity'",
      @float.neg_infinity,
    )
    assert_roundtrip(
      client,
      "real",
      @client.Type::float4(),
      "1000.55",
      Float::from_double(1000.55),
    )
    assert_float_nan_roundtrip(client)

    assert_roundtrip(
      client,
      "double precision",
      @client.Type::float8(),
      "'Infinity'",
      @double.infinity,
    )
    assert_roundtrip(
      client,
      "double precision",
      @client.Type::float8(),
      "'-Infinity'",
      @double.neg_infinity,
    )
    assert_roundtrip(
      client,
      "double precision",
      @client.Type::float8(),
      "10000.55",
      10000.55,
    )
    assert_double_nan_roundtrip(client)

    client.close()
  })
}

///|
/// This verifies edge behavior for binary and fixed-width character types.
/// `bytea` and `uuid` cover raw byte round trips, while `char(5)` focuses on PostgreSQL's right-padding rule and NULL handling.
async test "integration bytea and bpchar roundtrips" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    // First check that raw byte types are not corrupted by any text encoding path.
    let bytea_value = Bytes::from_array([
      b'\x00', b'\x01', b'\x02', b'\x03', b'\xfe', b'\xff',
    ])
    assert_roundtrip(
      client,
      "bytea",
      @client.Type::bytea(),
      "'\\x00010203feff'",
      bytea_value,
    )

    let uuid_value = Bytes::from_array([
      b'\x00', b'\x01', b'\x02', b'\x03', b'\x04', b'\x05', b'\x06', b'\x07', b'\x08',
      b'\x09', b'\x0a', b'\x0b', b'\x0c', b'\x0d', b'\x0e', b'\x0f',
    ])
    assert_roundtrip(
      client,
      "uuid",
      @client.Type::uuid(),
      "'00010203-0405-0607-0809-0a0b0c0d0e0f'",
      uuid_value,
    )

    // Then check fixed-width character padding semantics together with nullable parameters.
    client.batch_execute(
      "create temp table moon_driver_bpchar (id serial primary key, b char(5))",
    )
    let missing_value : String? = None
    let params : Array[&@client.ToSql] = [
      "12345" as &@client.ToSql,
      "123" as &@client.ToSql,
      missing_value as &@client.ToSql,
    ]
    let inserted = client.execute(
      "insert into moon_driver_bpchar (b) values ($1), ($2), ($3)",
      params~,
    )
    assert_eq(inserted, 3)
    let rows = client
      .query("select b from moon_driver_bpchar order by id")
      .collect()
    let values = rows.map(row => {
      let value : String? = row.get(0)
      value
    })
    assert_eq(values, [Some("12345"), Some("123  "), None])

    assert_roundtrip(
      client,
      "char(5)",
      @client.Type::unknown(1042U, name="bpchar"),
      "'123'",
      "123  ",
    )

    client.close()
  })
}

///|
/// This verifies that the client can resolve custom type metadata on demand.
/// The test covers enum, composite, domain, and range types, and checks that after clearing the type cache the reloaded kind information is correct.
async test "integration resolves custom type metadata" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    // Create temporary custom types first, then clear the cache so the client has to reload metadata from the catalogs.
    client.batch_execute(
      "create type pg_temp.moon_driver_mood as enum ('sad', 'happy')",
    )
    client.batch_execute(
      "create type pg_temp.moon_driver_pair as (left_value int4, right_value text)",
    )
    client.batch_execute(
      "create domain pg_temp.moon_driver_name as text check (value <> '')",
    )
    client.clear_type_cache()

    let mood_stream = client.query(
      "select 'happy'::pg_temp.moon_driver_mood as mood",
    )
    let mood_type = mood_stream.columns[0].type_
    ignore(mood_stream.finish())
    assert_eq(mood_type.name, "moon_driver_mood")
    guard mood_type.kind is @client.Kind::Enum(labels) else {
      fail("expected enum type metadata")
    }
    assert_eq(labels, ["sad", "happy"])

    let pair_stream = client.query(
      "select row(1, 'hi')::pg_temp.moon_driver_pair as pair",
    )
    let pair_type = pair_stream.columns[0].type_
    ignore(pair_stream.finish())
    assert_eq(pair_type.name, "moon_driver_pair")
    guard pair_type.kind is @client.Kind::Composite(fields) else {
      fail("expected composite type metadata")
    }
    assert_eq(fields.map(field => field.name), ["left_value", "right_value"])
    assert_eq(fields.map(field => field.type_oid), [23U, 25U])

    let domain_type = client.prepare(
        "select $1::pg_temp.moon_driver_name as name",
      ).params[0]
    assert_eq(domain_type.name, "moon_driver_name")
    guard domain_type.kind is @client.Kind::Domain(base_oid) else {
      fail("expected domain type metadata")
    }
    assert_eq(base_oid, 25U)

    let range_stream = client.query("select int4range(1, 3) as r")
    let range_type = range_stream.columns[0].type_
    ignore(range_stream.finish())
    assert_eq(range_type.name, "int4range")
    guard range_type.kind is @client.Kind::Range(subtype_oid) else {
      fail("expected range type metadata")
    }
    assert_eq(subtype_oid, 23U)

    client.close()
  })
}

///|
/// This verifies that database errors surface as structured error objects.
/// The test triggers a simple division-by-zero error and checks the SQLSTATE code.
async test "integration database errors surface" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    let err = expect_database_error(try? client.query_one("select 1 / 0"))
    assert_eq(err.code, Some("22012"))

    client.close()
  })
}
