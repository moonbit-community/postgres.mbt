///|
struct IntegrationConfig {
  host : String
  port : Int
  user : String
  password : String
  database : String
}

///|
struct IntegrationSession {
  config : IntegrationConfig
  client : @client.Client
}

///|
async fn env_var(name : String) -> String? {
  let (code, output) = @process.collect_stdout("/usr/bin/printenv", [name])
  if code != 0 {
    return None
  }
  Some(output.text().trim().to_string())
}

///|
async fn integration_config() -> IntegrationConfig? {
  guard env_var("RUN_POSTGRES_INTEGRATION") == Some("1") else { return None }
  let host = env_var("POSTGRES_HOST").unwrap_or("127.0.0.1")
  let port = match env_var("POSTGRES_PORT") {
    None => 5432
    Some(port) => @strconv.parse_int(port)
  }
  let user = env_var("POSTGRES_USER").unwrap_or("moon")
  let password = env_var("POSTGRES_PASSWORD").unwrap_or("moonpass")
  let database = env_var("POSTGRES_DB").unwrap_or("moondb")
  Some({ host, port, user, password, database })
}

///|
async fn integration_session(
  ssl_mode? : @client.SslMode = @client.SslMode::disable(),
  application_name? : String = "moonbit-postgres",
) -> IntegrationSession? {
  match integration_config() {
    None => None
    Some(config) => {
      let client = @client.Client::connect(
        config.host,
        user=config.user,
        database=config.database,
        password=config.password,
        port=config.port,
        ssl_mode~,
        application_name~,
      )
      Some({ config, client })
    }
  }
}

///|
fn[T] expect_database_error(
  result : Result[T, Error],
) -> @client.DatabaseError raise {
  guard result is Err(@client.ClientError::Database(err)) else {
    fail("expected database error")
  }
  err
}

///|
struct WireDatabaseError {
  severity : String?
  code : String?
  message : String
  detail : String?
  hint : String?
}

///|
struct WireConnection {
  socket : @socket.Tcp
  mut process_id : Int
  mut secret_key : Int
  parameters : Map[String, String]
  mut transaction_status : Byte
}

///|
fn WireConnection::close(self : WireConnection) -> Unit {
  self.socket.close()
}

///|
async fn WireConnection::write_buffer(
  self : WireConnection,
  buf : @buffer.Buffer,
) -> Unit {
  self.socket.write(buf.to_bytes())
}

///|
async fn WireConnection::read_message(
  self : WireConnection,
) -> @backend.Message {
  let header = self.socket.read_exactly(5)
  let body_len = ByteReader::new(header[1:]).read_i32_be()
  let body = self.socket.read_exactly(body_len - 4)
  let packet = @buffer.new(size_hint=header.length() + body.length())
  packet.write_bytes(header)
  packet.write_bytes(body)
  match @backend.Message::parse(packet.to_bytes()[:]) {
    Some(parsed) => parsed.message()
    None => fail("incomplete backend message")
  }
}

///|
async fn WireConnection::collect_until_ready(
  self : WireConnection,
) -> Array[@backend.Message] {
  let messages : Array[@backend.Message] = []
  loop self.read_message() {
    message => {
      match message {
        @backend.Message::ReadyForQuery(body) =>
          self.transaction_status = body.status()
        @backend.Message::ParameterStatus(body) =>
          self.parameters[body.name_str()] = body.value_str()
        @backend.Message::BackendKeyData(body) => {
          self.process_id = body.process_id()
          self.secret_key = body.secret_key()
        }
        _ => ()
      }
      messages.push(message)
      if message is @backend.Message::ReadyForQuery(_) {
        messages
      } else {
        continue self.read_message()
      }
    }
  }
}

///|
async fn WireConnection::send_and_collect(
  self : WireConnection,
  buf : @buffer.Buffer,
) -> Array[@backend.Message] {
  self.write_buffer(buf)
  self.collect_until_ready()
}

///|
async fn WireConnection::simple_query(
  self : WireConnection,
  sql : String,
  flush? : Bool = false,
) -> Array[@backend.Message] {
  let sql_bytes = utf8_encode(sql)
  let buf = @buffer.new()
  @frontend.query(sql_bytes[:], buf)
  if flush {
    @frontend.flush(buf)
  }
  self.send_and_collect(buf)
}

///|
async fn wire_connect(
  config : IntegrationConfig,
  application_name? : String = "moonbit-postgres-wire",
) -> WireConnection {
  let socket = @socket.Tcp::connect_to_host(config.host, port=config.port)
  let connection = {
    socket,
    process_id: 0,
    secret_key: 0,
    parameters: {},
    transaction_status: b'I',
  }
  let user_bytes = utf8_encode(config.user)
  let database_bytes = utf8_encode(config.database)
  let application_name_bytes = utf8_encode(application_name)
  let parameters : Array[(BytesView, BytesView)] = [
    (b"user"[:], user_bytes[:]),
    (b"database"[:], database_bytes[:]),
    (b"client_encoding"[:], b"UTF8"[:]),
    (b"application_name"[:], application_name_bytes[:]),
  ]
  let buf = @buffer.new()
  @frontend.startup_message(parameters.iter(), buf)
  connection.write_buffer(buf)

  let mut scram : @sasl.ScramSha256? = None
  loop connection.read_message() {
    @backend.Message::AuthenticationOk => continue connection.read_message()
    @backend.Message::AuthenticationCleartextPassword => {
      wire_send_password(connection, config.password)
      continue connection.read_message()
    }
    @backend.Message::AuthenticationMd5Password(body) => {
      wire_send_md5_password(
        connection,
        config.user,
        config.password,
        body.salt(),
      )
      continue connection.read_message()
    }
    @backend.Message::AuthenticationSasl(body) => {
      scram = Some(wire_begin_scram(connection, body, config.password))
      continue connection.read_message()
    }
    @backend.Message::AuthenticationSaslContinue(body) => {
      wire_continue_scram(connection, scram, body.data())
      continue connection.read_message()
    }
    @backend.Message::AuthenticationSaslFinal(body) => {
      wire_finish_scram(scram, body.data())
      continue connection.read_message()
    }
    @backend.Message::ParameterStatus(body) => {
      ignore(body.name_bytes())
      ignore(body.value_bytes())
      connection.parameters[body.name_str()] = body.value_str()
      continue connection.read_message()
    }
    @backend.Message::BackendKeyData(body) => {
      connection.process_id = body.process_id()
      connection.secret_key = body.secret_key()
      continue connection.read_message()
    }
    @backend.Message::NoticeResponse(_) => continue connection.read_message()
    @backend.Message::ReadyForQuery(body) => {
      connection.transaction_status = body.status()
      connection
    }
    @backend.Message::ErrorResponse(body) => {
      let err = parse_wire_database_error(body.fields())
      fail("startup failed: \{err.message}")
    }
    _ => fail("unexpected startup message")
  }
}

///|
async fn wire_send_password(
  connection : WireConnection,
  password : String,
) -> Unit {
  let password_bytes = utf8_encode(password)
  let buf = @buffer.new()
  @frontend.password_message(password_bytes[:], buf)
  connection.write_buffer(buf)
}

///|
async fn wire_send_md5_password(
  connection : WireConnection,
  user : String,
  password : String,
  salt : BytesView,
) -> Unit {
  let user_bytes = utf8_encode(user)
  let password_bytes = utf8_encode(password)
  let digest = @auth.md5_hash(user_bytes[:], password_bytes[:], salt)
  let buf = @buffer.new()
  @frontend.password_message(digest[:], buf)
  connection.write_buffer(buf)
}

///|
async fn wire_begin_scram(
  connection : WireConnection,
  body : @backend.AuthenticationSaslBody,
  password : String,
) -> @sasl.ScramSha256 {
  guard wire_supports_scram(body) else {
    fail("server does not offer SCRAM-SHA-256 authentication")
  }
  let password_bytes = utf8_encode(password)
  let nonce = @tls.rand_bytes(18)
  let scram = @sasl.ScramSha256::new(
    password_bytes[:],
    @sasl.ChannelBinding::unsupported(),
    nonce[:],
  )
  let buf = @buffer.new()
  @frontend.sasl_initial_response(@sasl.SCRAM_SHA_256[:], scram.message(), buf)
  connection.write_buffer(buf)
  scram
}

///|
async fn wire_continue_scram(
  connection : WireConnection,
  scram : @sasl.ScramSha256?,
  data : BytesView,
) -> Unit {
  let scram = wire_require_scram(scram)
  scram.update(data)
  let buf = @buffer.new()
  @frontend.sasl_response(scram.message(), buf)
  connection.write_buffer(buf)
}

///|
fn wire_finish_scram(
  scram : @sasl.ScramSha256?,
  data : BytesView,
) -> Unit raise {
  wire_require_scram(scram).finish(data)
}

///|
fn wire_require_scram(scram : @sasl.ScramSha256?) -> @sasl.ScramSha256 raise {
  match scram {
    Some(scram) => scram
    None => fail("missing SCRAM state")
  }
}

///|
fn wire_supports_scram(body : @backend.AuthenticationSaslBody) -> Bool raise {
  let mechanisms = body.mechanisms()
  loop mechanisms.next() {
    None => false
    Some(mechanism) =>
      if mechanism == @sasl.SCRAM_SHA_256 {
        true
      } else {
        continue mechanisms.next()
      }
  }
}

///|
fn wire_serialize_param(
  param : @client.QueryParam,
  buf : @buffer.Buffer,
) -> IsNull {
  match param {
    @client.QueryParam::Null => IsNull::Yes
    @client.QueryParam::Text(value) => {
      buf.write_bytes(value)
      IsNull::No
    }
  }
}

///|
fn wire_decode_utf8(bytes : BytesView) -> String raise ProtocolError {
  @utf8.decode(bytes) catch {
    _ => raise ProtocolError::InvalidInput("invalid UTF-8")
  }
}

///|
fn parse_wire_database_error(
  fields : @backend.ErrorFields,
) -> WireDatabaseError raise ProtocolError {
  let mut severity = None
  let mut code = None
  let mut message = None
  let mut detail = None
  let mut hint = None
  loop fields.next() {
    None =>
      {
        severity,
        code,
        message: message.unwrap_or("database error"),
        detail,
        hint,
      }
    Some(field) => {
      let value = wire_decode_utf8(field.value_bytes())
      match field.type_() {
        b'S' | b'V' => severity = Some(value)
        b'C' => code = Some(value)
        b'M' => message = Some(value)
        b'D' => detail = Some(value)
        b'H' => hint = Some(value)
        _ => ()
      }
      continue fields.next()
    }
  }
}

///|
fn data_row_texts(
  body : @backend.DataRowBody,
) -> Array[String?] raise ProtocolError {
  let out : Array[String?] = []
  let ranges = body.ranges()
  let buffer = body.buffer()
  loop ranges.next() {
    None => out
    Some(None) => {
      out.push(None)
      continue ranges.next()
    }
    Some(Some(range)) => {
      out.push(Some(wire_decode_utf8(buffer[range.start():range.end()])))
      continue ranges.next()
    }
  }
}

///|
fn find_notification_response(
  messages : Array[@backend.Message],
) -> @backend.NotificationResponseBody raise {
  for message in messages {
    if message is @backend.Message::NotificationResponse(body) {
      return body
    }
  }
  fail("expected notification response")
}

///|
fn find_notice_response(
  messages : Array[@backend.Message],
) -> @backend.NoticeResponseBody raise {
  for message in messages {
    if message is @backend.Message::NoticeResponse(body) {
      return body
    }
  }
  fail("expected notice response")
}

///|
async fn wait_for_backend_query(
  client : @client.Client,
  backend_pid : Int,
  sql : String,
) -> Unit {
  for _ in 0..<100 {
    let result = client.query(
      "select state::text as state, coalesce(wait_event::text, '') as wait_event, query::text as query from pg_stat_activity where pid = $1::int4",
      params=[@client.QueryParam::int(backend_pid)],
    )
    if result.row_count() == 1 {
      let row = result.rows()[0]
      let state = try! row.get_named_text("state")
      let wait_event = try! row.get_named_text("wait_event")
      let running_query = try! row.get_named_text("query")
      if state == Some(Some("active")) &&
        wait_event == Some(Some("PgSleep")) &&
        running_query == Some(Some(sql)) {
        return
      }
    }
    @async.sleep(50)
  }
  fail("timed out waiting for backend query to start")
}

///|
async test "integration protocol ssl request reports tls support" {
  guard integration_config() is Some(config) else { return }
  let socket = @socket.Tcp::connect_to_host(config.host, port=config.port)
  defer socket.close()

  let buf = @buffer.new()
  @frontend.ssl_request(buf)
  socket.write(buf.to_bytes())
  let response = socket.read_exactly(1)
  assert_eq(response[0], b'S')
}

///|
async test "integration cancel request uses protocol frontend" {
  guard integration_session() is Some(session) else { return }
  let config = session.config
  let client = session.client
  defer client.close()
  let observer = @client.Client::connect(
    config.host,
    user=config.user,
    database=config.database,
    password=config.password,
    port=config.port,
    ssl_mode=@client.SslMode::disable(),
    application_name="moonbit-postgres-cancel-observer",
  )
  defer observer.close()

  let result = @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() {
      try? client.simple_query("select pg_sleep(5)")
    })
    wait_for_backend_query(observer, client.process_id(), "select pg_sleep(5)")
    let cancel = @socket.Tcp::connect_to_host(config.host, port=config.port)
    defer cancel.close()
    let buf = @buffer.new()
    @frontend.cancel_request(client.process_id(), client.secret_key(), buf)
    cancel.write(buf.to_bytes())
    task.wait()
  })
  let err = expect_database_error(result)
  assert_eq(err.code(), Some("57014"))
  assert_eq(client.transaction_status(), b'I')
  let ping = client.simple_query("select 1::int4 as value")
  assert_eq(ping.command_tag(), "SELECT 1")
  assert_eq(try! ping.rows()[0].get_named_text("value"), Some(Some("1")))
}

///|
async test "integration protocol copy out flush and terminate" {
  guard integration_config() is Some(config) else { return }
  let wire = wire_connect(config, application_name="moonbit-postgres-copy-out")

  let messages = wire.simple_query(
    "copy (select 'hello'::text as value) to stdout",
    flush=true,
  )
  assert_true(wire.process_id > 0)
  assert_true(wire.secret_key != 0)
  assert_eq(wire.transaction_status, b'I')
  match messages[0] {
    @backend.Message::CopyOutResponse(body) => {
      assert_eq(body.format().to_int(), 0)
      let formats = body.column_formats()
      assert_eq(try! formats.next(), Some(0))
      assert_eq(try! formats.next(), None)
    }
    _ => fail("expected CopyOutResponse")
  }
  let payload = @buffer.new()
  let mut saw_copy_data = false
  let mut saw_copy_done = false
  let mut saw_command_complete = false
  let mut saw_ready = false
  for message in messages {
    match message {
      @backend.Message::CopyData(body) => {
        saw_copy_data = true
        payload.write_bytes(body.data().to_bytes())
      }
      @backend.Message::CopyDone => saw_copy_done = true
      @backend.Message::CommandComplete(body) => {
        saw_command_complete = true
        assert_eq(try! body.tag_str(), "COPY 1")
      }
      @backend.Message::ReadyForQuery(_) => saw_ready = true
      _ => ()
    }
  }
  assert_true(saw_copy_data)
  assert_eq(wire_decode_utf8(payload.to_bytes()[:]), "hello\n")
  assert_eq(payload.to_bytes().length(), 6)
  assert_true(saw_copy_done)
  assert_true(saw_command_complete)
  assert_true(saw_ready)

  let terminate = @buffer.new()
  @frontend.terminate(terminate)
  wire.write_buffer(terminate)
  wire.close()
}

///|
async test "integration protocol copy in success" {
  guard integration_config() is Some(config) else { return }
  let wire = wire_connect(config, application_name="moonbit-postgres-copy-in")
  defer wire.close()

  let create = wire.simple_query(
    "create temp table wire_copy_in (value text not null)",
  )
  match create[0] {
    @backend.Message::CommandComplete(body) =>
      assert_eq(try! body.tag_str(), "CREATE TABLE")
    _ => fail("expected CREATE TABLE")
  }

  let start = @buffer.new()
  @frontend.query(b"copy wire_copy_in from stdin"[:], start)
  wire.write_buffer(start)
  match wire.read_message() {
    @backend.Message::CopyInResponse(body) => {
      assert_eq(body.format().to_int(), 0)
      let formats = body.column_formats()
      assert_eq(try! formats.next(), Some(0))
      assert_eq(try! formats.next(), None)
    }
    _ => fail("expected CopyInResponse")
  }

  let copy_payload = @buffer.new()
  let first = @frontend.CopyData::new(b"alpha\n"[:])
  first.write(copy_payload)
  let second = @frontend.CopyData::new(b"beta\n"[:])
  second.write(copy_payload)
  @frontend.copy_done(copy_payload)
  let copy_messages = wire.send_and_collect(copy_payload)
  match copy_messages[0] {
    @backend.Message::CommandComplete(body) =>
      assert_eq(try! body.tag_str(), "COPY 2")
    _ => fail("expected COPY command complete")
  }

  let verify = wire.simple_query(
    "select string_agg(value, ',' order by value) as values from wire_copy_in",
  )
  match verify[1] {
    @backend.Message::DataRow(body) =>
      assert_eq(data_row_texts(body), [Some("alpha,beta")])
    _ => fail("expected DataRow")
  }
}

///|
async test "integration protocol copy fail surfaces backend error" {
  guard integration_config() is Some(config) else { return }
  let wire = wire_connect(config, application_name="moonbit-postgres-copy-fail")
  defer wire.close()

  let create = wire.simple_query(
    "create temp table wire_copy_fail (value text not null)",
  )
  match create[0] {
    @backend.Message::CommandComplete(body) =>
      assert_eq(try! body.tag_str(), "CREATE TABLE")
    _ => fail("expected CREATE TABLE")
  }

  let start = @buffer.new()
  @frontend.query(b"copy wire_copy_fail from stdin"[:], start)
  wire.write_buffer(start)
  assert_true(wire.read_message() is @backend.Message::CopyInResponse(_))

  let fail_buf = @buffer.new()
  @frontend.copy_fail(b"integration copy failure"[:], fail_buf)
  let fail_messages = wire.send_and_collect(fail_buf)
  match fail_messages[0] {
    @backend.Message::ErrorResponse(body) => {
      let err = parse_wire_database_error(body.fields())
      assert_eq(err.severity, Some("ERROR"))
      assert_true(err.code is Some(_))
      assert_true(err.message.contains("integration copy failure"))
      assert_true(err.detail is None)
      assert_true(err.hint is None)
    }
    _ => fail("expected ErrorResponse")
  }
  assert_true(fail_messages[1] is @backend.Message::ReadyForQuery(_))
}

///|
async test "integration protocol describe close and parameter description" {
  guard integration_config() is Some(config) else { return }
  let wire = wire_connect(config, application_name="moonbit-postgres-describe")
  defer wire.close()

  let sql_bytes = utf8_encode("select $1::int4 as value")
  let buf = @buffer.new()
  @frontend.parse(b"stmt1"[:], sql_bytes[:], [23U].iter(), buf)
  @frontend.describe(b'S', b"stmt1"[:], buf)
  @frontend.close(b'S', b"stmt1"[:], buf)
  @frontend.sync(buf)

  let messages = wire.send_and_collect(buf)
  assert_true(messages[0] is @backend.Message::ParseComplete)
  match messages[1] {
    @backend.Message::ParameterDescription(body) => {
      let parameters = body.parameters()
      assert_eq(try! parameters.next(), Some(23U))
      assert_eq(try! parameters.next(), None)
    }
    _ => fail("expected ParameterDescription")
  }
  match messages[2] {
    @backend.Message::RowDescription(body) => {
      let fields = body.fields()
      let first_field = try! fields.next()
      match first_field {
        Some(field) => {
          assert_eq(wire_decode_utf8(field.name_bytes()), "value")
          assert_eq(field.type_oid(), 23U)
          assert_eq(field.type_size(), 4)
          assert_eq(field.format(), 0)
        }
        None => fail("missing described field")
      }
      assert_true((try! fields.next()) is None)
    }
    _ => fail("expected RowDescription")
  }
  assert_true(messages[3] is @backend.Message::CloseComplete)
  assert_true(messages[4] is @backend.Message::ReadyForQuery(_))
}

///|
async test "integration protocol portal suspended" {
  guard integration_config() is Some(config) else { return }
  let wire = wire_connect(config, application_name="moonbit-postgres-portal")
  defer wire.close()

  let sql_bytes = utf8_encode("select generate_series(1, 3)::int4 as value")
  let formats : Array[Int] = []
  let params : Array[@client.QueryParam] = []
  let result_formats : Array[Int] = []
  let buf = @buffer.new()
  @frontend.parse(b"stmt_portal"[:], sql_bytes[:], [].iter(), buf)
  @frontend.bind(
    b"portal1"[:],
    b"stmt_portal"[:],
    formats.iter(),
    params.iter(),
    fn(param, payload) { wire_serialize_param(param, payload) },
    result_formats.iter(),
    buf,
  )
  @frontend.describe(b'P', b"portal1"[:], buf)
  @frontend.execute(b"portal1"[:], 1, buf)
  @frontend.sync(buf)

  let messages = wire.send_and_collect(buf)
  assert_true(messages[0] is @backend.Message::ParseComplete)
  assert_true(messages[1] is @backend.Message::BindComplete)
  assert_true(messages[2] is @backend.Message::RowDescription(_))
  match messages[3] {
    @backend.Message::DataRow(body) => {
      assert_true(body.buffer_bytes().length() > 0)
      assert_eq(data_row_texts(body), [Some("1")])
    }
    _ => fail("expected DataRow")
  }
  assert_true(messages[4] is @backend.Message::PortalSuspended)
  assert_true(messages[5] is @backend.Message::ReadyForQuery(_))
}

///|
async test "integration protocol notice and notification getters" {
  guard integration_config() is Some(config) else { return }
  let wire = wire_connect(config, application_name="moonbit-postgres-notify")
  defer wire.close()

  let notice_messages = wire.simple_query(
    "do $$ begin raise notice 'wire notice'; end $$;",
  )
  let notice = find_notice_response(notice_messages)
  let notice_fields = notice.fields()
  let mut saw_message = false
  loop notice_fields.next() {
    None => break
    Some(field) =>
      if field.type_() == b'M' {
        saw_message = true
        assert_eq(wire_decode_utf8(field.value_bytes()), "wire notice")
      } else {
        continue notice_fields.next()
      }
  }
  assert_true(saw_message)

  let listen_messages = wire.simple_query("listen wire_channel")
  match listen_messages[0] {
    @backend.Message::CommandComplete(body) =>
      assert_eq(try! body.tag_str(), "LISTEN")
    _ => fail("expected LISTEN command complete")
  }

  let notify_messages = wire.simple_query("notify wire_channel, 'payload'")
  let notification = find_notification_response(notify_messages)
  assert_true(notification.process_id() > 0)
  assert_eq(notification.channel_bytes().to_bytes(), b"wire_channel")
  assert_eq(try! notification.channel_str(), "wire_channel")
  assert_eq(notification.message_bytes().to_bytes(), b"payload")
  assert_eq(try! notification.message_str(), "payload")
}
