///|
fn[T] expect_authentication_error(result : Result[T, Error]) -> String raise {
  guard result is Err(@client.ClientError::Authentication(message)) else {
    fail("expected authentication error")
  }
  message
}

///|
fn[T] expect_unsupported(result : Result[T, Error]) -> String raise {
  guard result is Err(@client.ClientError::Unsupported(message)) else {
    fail("expected unsupported error")
  }
  message
}

///|
fn[T] expect_ssl_error(result : Result[T, Error]) -> String raise {
  guard result is Err(@client.ClientError::Ssl(message)) else {
    fail("expected ssl error")
  }
  message
}

///|
async fn assert_connection_still_usable(client : @client.Client) -> Unit {
  let ping = client.simple_query("select 1::int4 as value")
  assert_eq(ping.command_tag(), "SELECT 1")
  assert_eq(try! ping.rows()[0].get_named_text("value"), Some(Some("1")))
  assert_eq(client.transaction_status(), b'I')
}

///|
async test "integration connect and simple_query" {
  guard integration_session() is Some(session) else { return }
  let config = session.config
  let client = session.client
  defer client.close()

  assert_true(client.process_id() > 0)
  assert_true(client.secret_key() != 0)
  assert_eq(client.transaction_status(), b'I')
  assert_eq(client.parameter_status("client_encoding"), Some("UTF8"))
  assert_eq(
    client.parameter_status("application_name"),
    Some("moonbit-postgres"),
  )
  assert_true(client.parameter_status("server_version") is Some(_))

  let result = client.simple_query(
    "select current_user::text as current_user, current_database()::text as current_database",
  )
  assert_eq(result.command_tag(), "SELECT 1")
  assert_eq(result.row_count(), 1)
  let row = result.rows()[0]
  assert_eq(try! row.get_named_text("current_user"), Some(Some(config.user)))
  assert_eq(
    try! row.get_named_text("current_database"),
    Some(Some(config.database)),
  )
}

///|
async test "integration empty query response" {
  guard integration_session() is Some(session) else { return }
  let client = session.client
  defer client.close()

  let result = client.simple_query("")
  assert_eq(result.command_tag(), "")
  assert_eq(result.column_count(), 0)
  assert_eq(result.row_count(), 0)
  assert_eq(client.transaction_status(), b'I')
}

///|
async test "integration row accessors and null handling" {
  guard integration_session() is Some(session) else { return }
  let client = session.client
  defer client.close()

  let result = client.simple_query(
    "select 42::int4 as answer, null::text as nothing, '你好🌙'::text as greeting, 'first'::text as repeated, 'second'::text as repeated",
  )
  assert_eq(result.command_tag(), "SELECT 1")
  assert_eq(result.column_count(), 5)
  assert_eq(result.row_count(), 1)
  let row = result.rows()[0]
  assert_eq(row.len(), 5)
  assert_eq(try! row.get_text(0), Some("42"))
  assert_eq(row.get(1), None)
  assert_eq(try! row.get_named_text("nothing"), Some(None))
  assert_eq(try! row.get_named_text("greeting"), Some(Some("你好🌙")))
  assert_eq(row.index_of("repeated"), Some(3))
  assert_eq(try! row.get_named_text("repeated"), Some(Some("first")))
  assert_eq(try! row.get_named_text("missing"), None)
  assert_true(row.get_named("missing") is None)
}

///|
async test "integration getters and type modifiers" {
  guard integration_session() is Some(session) else { return }
  let client = session.client
  defer client.close()

  let result = client.simple_query(
    "select cast('abc' as varchar(5)) as short_text",
  )
  assert_eq(result.command_tag(), "SELECT 1")
  assert_eq(result.row_count(), 1)
  let row = result.rows()[0]
  assert_eq(row.columns().length(), 1)
  assert_eq(row.values().length(), 1)
  assert_eq(row.get_named("short_text"), Some(Some(@proto.utf8_encode("abc"))))
  let column = row.columns()[0]
  assert_eq(column.name(), "short_text")
  assert_eq(column.type_oid(), 1043U)
  assert_true(column.type_modifier() > 0)
}

///|
async test "integration zero rows still return columns" {
  guard integration_session() is Some(session) else { return }
  let client = session.client
  defer client.close()

  let result = client.simple_query(
    "select 1::int4 as id, 'value'::text as name where false",
  )
  assert_eq(result.command_tag(), "SELECT 0")
  assert_eq(result.column_count(), 2)
  assert_eq(result.row_count(), 0)
  assert_eq(result.columns()[0].name(), "id")
  assert_eq(result.columns()[0].type_oid(), 23U)
  assert_eq(result.columns()[1].name(), "name")
  assert_eq(result.columns()[1].type_oid(), 25U)
}

///|
async test "integration extended query roundtrip" {
  guard integration_session() is Some(session) else { return }
  let client = session.client
  defer client.close()

  let create = client.simple_query(
    "create temp table moon_driver_integration (id int primary key, name text not null)",
  )
  assert_eq(create.command_tag(), "CREATE TABLE")
  assert_eq(create.row_count(), 0)

  let insert = client.query(
    "insert into moon_driver_integration (id, name) values ($1::int4, $2::text)",
    params=[@client.QueryParam::int(7), @client.QueryParam::string("hello")],
  )
  assert_eq(insert.command_tag(), "INSERT 0 1")
  assert_eq(insert.row_count(), 0)

  let result = client.query(
    "select id, name from moon_driver_integration where id = $1::int4",
    params=[@client.QueryParam::int(7)],
  )
  assert_eq(result.command_tag(), "SELECT 1")
  assert_eq(result.column_count(), 2)
  assert_eq(result.row_count(), 1)
  assert_eq(result.columns()[0].name(), "id")
  assert_true(result.columns()[0].table_oid() > 0U)
  assert_eq(result.columns()[0].column_id(), 1)
  assert_eq(result.columns()[0].type_oid(), 23U)
  assert_eq(result.columns()[0].type_size(), 4)
  assert_eq(result.columns()[0].format(), 0)
  assert_eq(result.columns()[1].name(), "name")
  assert_true(result.columns()[1].table_oid() > 0U)
  assert_eq(result.columns()[1].column_id(), 2)
  assert_eq(result.columns()[1].type_oid(), 25U)
  assert_eq(result.columns()[1].type_size(), -1)
  assert_eq(result.columns()[1].format(), 0)
  let row = result.rows()[0]
  assert_eq(try! row.get_text(0), Some("7"))
  assert_eq(try! row.get_named_text("id"), Some(Some("7")))
  assert_eq(try! row.get_named_text("name"), Some(Some("hello")))
}

///|
async test "integration startup failures are surfaced" {
  guard integration_config() is Some(config) else { return }

  let missing_password = expect_authentication_error(
    try? @client.Client::connect(
      config.host,
      user=config.user,
      database=config.database,
      port=config.port,
      ssl_mode=@client.SslMode::disable(),
    ),
  )
  assert_true(missing_password.contains("server requires a password"))

  let bad_password = expect_database_error(
    try? @client.Client::connect(
      config.host,
      user=config.user,
      database=config.database,
      password="definitely-wrong-password",
      port=config.port,
      ssl_mode=@client.SslMode::disable(),
    ),
  )
  assert_eq(bad_password.code(), Some("28P01"))
}

///|
async test "integration tls modes establish tls connections" {
  guard integration_config() is Some(config) else { return }

  let preferred = @client.Client::connect(
    config.host,
    user=config.user,
    database=config.database,
    password=config.password,
    port=config.port,
    ssl_mode=@client.SslMode::prefer(),
    application_name="moonbit-postgres-prefer",
  )
  defer preferred.close()
  let preferred_status = preferred.simple_query(
    "select ssl::text as using_tls from pg_stat_ssl where pid = pg_backend_pid()",
  )
  assert_eq(preferred_status.command_tag(), "SELECT 1")
  assert_eq(
    try! preferred_status.rows()[0].get_named_text("using_tls"),
    Some(Some("true")),
  )

  let required = @client.Client::connect(
    config.host,
    user=config.user,
    database=config.database,
    password=config.password,
    port=config.port,
    ssl_mode=@client.SslMode::require(),
    application_name="moonbit-postgres-require",
  )
  defer required.close()
  let required_status = required.simple_query(
    "select ssl::text as using_tls from pg_stat_ssl where pid = pg_backend_pid()",
  )
  assert_eq(required_status.command_tag(), "SELECT 1")
  assert_eq(
    try! required_status.rows()[0].get_named_text("using_tls"),
    Some(Some("true")),
  )
}

///|
async test "integration tls rejects untrusted server certificate" {
  guard integration_config() is Some(config) else { return }
  guard env_var("POSTGRES_TLS_EXPECT_FAILURE") == Some("1") else { return }

  let message = expect_ssl_error(
    try? @client.Client::connect(
      config.host,
      user=config.user,
      database=config.database,
      password=config.password,
      port=config.port,
      ssl_mode=@client.SslMode::require(),
      application_name="moonbit-postgres-bad-ca",
    ),
  )
  assert_true(message.length() > 0)
}

///|
async test "integration scalar parameter helpers" {
  guard integration_session() is Some(session) else { return }
  let client = session.client
  defer client.close()

  let result = client.query(
    "select ($1::boolean)::text as bool_value, ($2::int4)::text as int_value, ($3::int8)::text as int64_value, ($4::float8)::text as double_value",
    params=[
      @client.QueryParam::bool(true),
      @client.QueryParam::int(-7),
      @client.QueryParam::int64(1234567890123L),
      @client.QueryParam::double(1.25),
    ],
  )
  assert_eq(result.command_tag(), "SELECT 1")
  let row = result.rows()[0]
  assert_eq(try! row.get_named_text("bool_value"), Some(Some("true")))
  assert_eq(try! row.get_named_text("int_value"), Some(Some("-7")))
  assert_eq(try! row.get_named_text("int64_value"), Some(Some("1234567890123")))
  assert_eq(try! row.get_named_text("double_value"), Some(Some("1.25")))
}

///|
async test "integration null and unicode parameters" {
  guard integration_session() is Some(session) else { return }
  let client = session.client
  defer client.close()

  let result = client.query(
    "select coalesce($1::text, 'fallback') as fallback_value, $1::text as null_value, $2::text as greeting",
    params=[
      @client.QueryParam::null(),
      @client.QueryParam::string("你好🌙"),
    ],
  )
  assert_eq(result.command_tag(), "SELECT 1")
  let row = result.rows()[0]
  assert_eq(try! row.get_named_text("fallback_value"), Some(Some("fallback")))
  assert_eq(try! row.get_named_text("null_value"), Some(None))
  assert_eq(try! row.get_named_text("greeting"), Some(Some("你好🌙")))
}

///|
async test "integration bytes parameter large payload" {
  guard integration_session() is Some(session) else { return }
  let client = session.client
  defer client.close()

  let payload = "moonbit!".repeat(1024)
  let result = client.query(
    "select octet_length($1::text)::text as byte_len, left($1::text, 8)::text as prefix, right($1::text, 8)::text as suffix",
    params=[@client.QueryParam::bytes(@proto.utf8_encode(payload)[:])],
  )
  assert_eq(result.command_tag(), "SELECT 1")
  let row = result.rows()[0]
  assert_eq(try! row.get_named_text("byte_len"), Some(Some("8192")))
  assert_eq(try! row.get_named_text("prefix"), Some(Some("moonbit!")))
  assert_eq(try! row.get_named_text("suffix"), Some(Some("moonbit!")))
}

///|
async test "integration database error fields" {
  guard integration_session() is Some(session) else { return }
  let client = session.client
  defer client.close()

  let err = expect_database_error(
    try? client.simple_query(
      "do $$ begin raise exception using errcode = '22023', message = 'integration boom', detail = 'detail text', hint = 'hint text'; end $$;",
    ),
  )
  assert_eq(err.severity(), Some("ERROR"))
  assert_eq(err.code(), Some("22023"))
  assert_eq(err.message(), "integration boom")
  assert_eq(err.detail(), Some("detail text"))
  assert_eq(err.hint(), Some("hint text"))
  assert_eq(client.transaction_status(), b'I')
}

///|
async test "integration transaction status after database error" {
  guard integration_session() is Some(session) else { return }
  let client = session.client
  defer client.close()

  let begin = client.simple_query("begin")
  assert_eq(begin.command_tag(), "BEGIN")
  assert_eq(client.transaction_status(), b'T')

  let err = expect_database_error(try? client.simple_query("select 1 / 0"))
  assert_eq(err.code(), Some("22012"))
  assert_eq(client.transaction_status(), b'E')

  let rollback = client.simple_query("rollback")
  assert_eq(rollback.command_tag(), "ROLLBACK")
  assert_eq(client.transaction_status(), b'I')
}

///|
async test "integration notice response is ignored" {
  guard integration_session() is Some(session) else { return }
  let client = session.client
  defer client.close()

  let set_notice = client.simple_query("set client_min_messages = notice")
  assert_eq(set_notice.command_tag(), "SET")

  let result = client.simple_query(
    "do $$ begin raise notice 'integration notice'; end $$;",
  )
  assert_eq(result.command_tag(), "DO")
  assert_eq(client.transaction_status(), b'I')
}

///|
async test "integration notification response is ignored" {
  guard integration_session() is Some(session) else { return }
  let client = session.client
  defer client.close()

  let listen = client.simple_query("listen moon_driver_notification")
  assert_eq(listen.command_tag(), "LISTEN")

  let notify = client.simple_query("notify moon_driver_notification, 'payload'")
  assert_eq(notify.command_tag(), "NOTIFY")

  let result = client.simple_query("select 'still alive'::text as value")
  assert_eq(result.command_tag(), "SELECT 1")
  assert_eq(
    try! result.rows()[0].get_named_text("value"),
    Some(Some("still alive")),
  )

  let unlisten = client.simple_query("unlisten *")
  assert_eq(unlisten.command_tag(), "UNLISTEN")
}

///|
async test "integration parameter status updates" {
  guard integration_session() is Some(session) else { return }
  let client = session.client
  defer client.close()

  let updated_name = "moonbit-postgres-it"
  let result = client.simple_query(
    "set application_name = 'moonbit-postgres-it'",
  )
  assert_eq(result.command_tag(), "SET")
  assert_eq(client.parameter_status("application_name"), Some(updated_name))
}

///|
async test "integration multiple result sets are unsupported" {
  guard integration_session() is Some(session) else { return }
  let client = session.client
  defer client.close()

  let message = expect_unsupported(
    try? client.simple_query(
      "select 1::int4 as left_value; select 2::int4 as right_value",
    ),
  )
  assert_true(message.contains("multiple result sets"))
  assert_connection_still_usable(client)
}

///|
async test "integration multiple command tags are unsupported" {
  guard integration_session() is Some(session) else { return }
  let client = session.client
  defer client.close()

  let create = client.simple_query(
    "create temp table moon_driver_multi_command (value int not null)",
  )
  assert_eq(create.command_tag(), "CREATE TABLE")

  let message = expect_unsupported(
    try? client.simple_query(
      "insert into moon_driver_multi_command values (1); update moon_driver_multi_command set value = value + 1",
    ),
  )
  assert_true(message.contains("multiple result sets"))
  assert_connection_still_usable(client)
}

///|
async test "integration copy is unsupported" {
  guard integration_session() is Some(session) else { return }
  let client = session.client
  defer client.close()

  let message = expect_unsupported(
    try? client.simple_query("copy (select 1::int4) to stdout"),
  )
  assert_true(message.contains("COPY"))
  assert_connection_still_usable(client)
}
