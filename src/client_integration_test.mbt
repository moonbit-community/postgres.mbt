///|
async fn assert_auth_ok(
  config : IntegrationConfig,
  user : String,
  password : String,
) -> Unit {
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      auth_client_config(config, user, password=Some(password)),
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
async fn assert_missing_password(
  config : IntegrationConfig,
  user : String,
) -> Unit {
  let message = expect_authentication_error(
    try? @client.connect(auth_client_config(config, user, password=None)),
  )
  assert_eq(message, "server requires a password")
}

///|
async fn assert_wrong_password(
  config : IntegrationConfig,
  user : String,
) -> Unit {
  let err = expect_database_error(
    try? @client.connect(
      auth_client_config(config, user, password=Some("wrongpass")),
    ),
  )
  assert_eq(err.code(), Some("28P01"))
}

///|
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
async fn assert_tls_query_ok(
  config : IntegrationConfig,
  ssl_mode : @client.SslMode,
  application_name : String,
) -> Unit {
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, ssl_mode~, application_name~),
    )
    group.spawn_bg(() => connection.run())

    assert_eq(client.parameter("application_name"), Some(application_name))
    let negotiated_application_name : String = client
      .query_one(
        "select current_setting('application_name')::text as application_name",
      )
      .get_name("application_name")
    assert_eq(negotiated_application_name, application_name)
    let value : Int = client
      .query_one("select 1::int4 as value")
      .get_name("value")
    assert_eq(value, 1)

    client.close()
  })
}

///|
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
async test "integration connect and typed query" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
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
async test "integration tls prefer connects and queries" {
  guard integration_config() is Some(config) else { return }
  guard !integration_tls_failure_expected() else { return }
  assert_tls_query_ok(
    config,
    @client.SslMode::prefer(),
    "moonbit-postgres-tls-prefer",
  )
}

///|
async test "integration tls require connects and queries" {
  guard integration_config() is Some(config) else { return }
  guard !integration_tls_failure_expected() else { return }
  assert_tls_query_ok(
    config,
    @client.SslMode::require(),
    "moonbit-postgres-tls-require",
  )
}

///|
async test "integration tls rejects untrusted server certificate" {
  guard integration_config() is Some(config) else { return }
  guard integration_tls_failure_expected() else { return }

  let message = expect_ssl_error(
    try? @client.connect(
      as_client_config(
        config,
        ssl_mode=@client.SslMode::require(),
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
async test "integration plain password missing" {
  guard integration_config() is Some(config) else { return }
  assert_missing_password(config, "moon_password")
}

///|
async test "integration plain password wrong" {
  guard integration_config() is Some(config) else { return }
  assert_wrong_password(config, "moon_password")
}

///|
async test "integration plain password ok" {
  guard integration_config() is Some(config) else { return }
  assert_auth_ok(config, "moon_password", "moonpass")
}

///|
async test "integration md5 password missing" {
  guard integration_config() is Some(config) else { return }
  assert_missing_password(config, "moon_md5")
}

///|
async test "integration md5 password wrong" {
  guard integration_config() is Some(config) else { return }
  assert_wrong_password(config, "moon_md5")
}

///|
async test "integration md5 password ok" {
  guard integration_config() is Some(config) else { return }
  assert_auth_ok(config, "moon_md5", "moonpass")
}

///|
async test "integration scram password missing" {
  guard integration_config() is Some(config) else { return }
  assert_missing_password(config, "moon_scram")
}

///|
async test "integration scram password wrong" {
  guard integration_config() is Some(config) else { return }
  assert_wrong_password(config, "moon_scram")
}

///|
async test "integration scram password ok" {
  guard integration_config() is Some(config) else { return }
  assert_auth_ok(config, "moon_scram", "moonpass")
}

///|
async test "integration check connection" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
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
async test "integration exposes startup parameters" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
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
async test "integration prepare and parameterized execute" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
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
async test "integration raw query closes temporary prepared statements" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
    group.spawn_bg(() => connection.run())

    let before : Int = client
      .query_one("select count(*)::int4 as count from pg_prepared_statements")
      .get_name("count")
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
async test "integration simple query supports multiple result sets" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
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
    assert_eq(stream.next(), None)
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
async test "integration simple query supports pipelining" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
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
async test "integration portal pagination" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
    group.spawn_bg(() => connection.run())

    client.batch_execute(
      "create temp table moon_driver_portal (id serial, name text)",
    )
    client.batch_execute(
      "insert into moon_driver_portal (name) values ('alice'), ('bob'), ('charlie')",
    )
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
async test "integration row stream supports pipelining" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
    group.spawn_bg(() => connection.run())

    let stream = client.query(
      "select generate_series(1, 3)::int4 as value order by value",
    )
    let columns = stream.columns()
    assert_eq(columns.length(), 1)
    assert_eq(columns[0].name(), "value")
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
    assert_eq(summary.row_count(), 3)
    assert_eq(summary.suspended(), false)

    client.close()
  })
}

///|
async test "integration row stream backpressures after bounded buffering" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
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
    assert_eq(summary.row_count(), 16)
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
async test "integration transaction commit" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
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
async test "integration transaction rollback" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
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
async test "integration transaction builder" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
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

    let token = client.cancel_token()
    let backend_pid : Int = client
      .query_one("select pg_backend_pid()::int4 as pid")
      .get_name("pid")
    let task = group.spawn(() => try? client.query_one("select pg_sleep(5)"))

    wait_for_backend_query(observer, backend_pid, "select pg_sleep(5)")
    token.cancel()

    let err = expect_database_error(task.wait())
    assert_eq(err.code(), Some("57014"))
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
async test "integration notice and notification surface as async messages" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
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
    assert_eq(first_notice.message(), "integration notice 1")
    assert_eq(second_notice.message(), "integration notice 2")
    assert_eq(first_notification.channel(), "moon_driver_notification")
    assert_eq(first_notification.payload(), "hello")
    assert_eq(second_notification.channel(), "moon_driver_notification")
    assert_eq(second_notification.payload(), "world")

    client.close()
  })
}

///|
async test "integration copy out" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
    group.spawn_bg(() => connection.run())

    client.batch_execute(
      "create temp table moon_driver_copy_out (id int, name text)",
    )
    client.batch_execute(
      "insert into moon_driver_copy_out(id, name) values (1, 'jim'), (2, 'joe')",
    )
    let stream = client.copy_out(
      "copy moon_driver_copy_out (id, name) to stdout",
    )
    let chunks : Array[Bytes] = []
    let payload = @buffer.new()
    loop stream.next() {
      None => ()
      Some(chunk) => {
        chunks.push(chunk)
        payload.write_bytes(chunk)
        continue stream.next()
      }
    }
    assert_eq(stream.column_formats(), [0, 0])
    assert_true(chunks.length() >= 1)
    assert_eq(payload.contents(), b"1\tjim\n2\tjoe\n")

    client.close()
  })
}

///|
async test "integration copy out supports pipelining" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
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
    assert_eq(stream.column_formats(), [0, 0])
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
async test "integration copy in" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
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
async test "integration copy in large" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
    group.spawn_bg(() => connection.run())

    client.batch_execute(
      "create temp table moon_driver_copy_in_large (id int not null, name text not null)",
    )
    let sink = client.copy_in(
      "copy moon_driver_copy_in_large (id, name) from stdin",
    )
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
async test "integration copy in abort rolls back copy" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
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
async test "integration query one" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
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
async test "integration query opt" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
    group.spawn_bg(() => connection.run())

    client.batch_execute("create temp table moon_driver_query_opt (name text)")
    client.batch_execute(
      "insert into moon_driver_query_opt (name) values ('alice'), ('bob'), ('carol')",
    )

    let none_row = client.query_opt(
      "select * from moon_driver_query_opt where name = 'dave'",
    )
    assert_eq(none_row, None)

    guard client.query_opt(
        "select * from moon_driver_query_opt where name = 'alice'",
      )
      is Some(row) else {
      fail("expected row")
    }
    let name : String = row.get_name("name")
    assert_eq(name, "alice")

    let many_message = expect_row_count_error(
      try? client.query_opt("select * from moon_driver_query_opt"),
    )
    assert_eq(many_message, "expected zero or one row, got 3")

    client.close()
  })
}

///|
async test "integration deferred constraint" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
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
    assert_eq(err.code(), Some("23505"))
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
async test "integration query typed without transaction" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
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
async test "integration scalar type roundtrips" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
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

    client.close()
  })
}

///|
async test "integration float roundtrips" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
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
async test "integration bytea and bpchar roundtrips" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
    group.spawn_bg(() => connection.run())

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
async test "integration resolves custom type metadata" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
    group.spawn_bg(() => connection.run())

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
    let mood_type = mood_stream.columns()[0].type_()
    ignore(mood_stream.finish())
    assert_eq(mood_type.name(), "moon_driver_mood")
    guard mood_type.kind() is @client.Kind::Enum(labels) else {
      fail("expected enum type metadata")
    }
    assert_eq(labels, ["sad", "happy"])

    let pair_stream = client.query(
      "select row(1, 'hi')::pg_temp.moon_driver_pair as pair",
    )
    let pair_type = pair_stream.columns()[0].type_()
    ignore(pair_stream.finish())
    assert_eq(pair_type.name(), "moon_driver_pair")
    guard pair_type.kind() is @client.Kind::Composite(fields) else {
      fail("expected composite type metadata")
    }
    assert_eq(fields.map(field => field.name()), ["left_value", "right_value"])
    assert_eq(fields.map(field => field.type_oid()), [23U, 25U])

    let domain_type = client
      .prepare("select $1::pg_temp.moon_driver_name as name")
      .params()[0]
    assert_eq(domain_type.name(), "moon_driver_name")
    guard domain_type.kind() is @client.Kind::Domain(base_oid) else {
      fail("expected domain type metadata")
    }
    assert_eq(base_oid, 25U)

    let range_stream = client.query("select int4range(1, 3) as r")
    let range_type = range_stream.columns()[0].type_()
    ignore(range_stream.finish())
    assert_eq(range_type.name(), "int4range")
    guard range_type.kind() is @client.Kind::Range(subtype_oid) else {
      fail("expected range type metadata")
    }
    assert_eq(subtype_oid, 23U)

    client.close()
  })
}

///|
async test "integration database errors surface" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
    group.spawn_bg(() => connection.run())

    let err = expect_database_error(try? client.query_one("select 1 / 0"))
    assert_eq(err.code(), Some("22012"))

    client.close()
  })
}
