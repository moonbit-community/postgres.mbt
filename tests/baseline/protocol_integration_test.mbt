///|
/// Structured error fields used by the protocol tests.
/// The wire format exposes many fields, but these tests only keep the ones they assert on directly.
struct WireDatabaseError {
  severity : String?
  code : String?
  message : String
  detail : String?
  hint : String?
}

///|
/// Connection wrapper used by the protocol tests.
/// Besides the socket itself, it keeps the backend pid, cancel key, parameter map, and transaction status for later assertions.
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
/// Read one full backend packet.
/// PostgreSQL packets carry their length in the header, so this reads the header first and then the body.
async fn read_socket_packet(socket : @socket.Tcp) -> Bytes {
  let header = socket.read_exactly(5)
  let body_len = @proto.ByteReader::new(header[1:]).read_i32_be()
  let body = socket.read_exactly(body_len - 4)
  let packet = @buffer.new(size_hint=header.length() + body.length())
  packet.write_bytes(header)
  packet.write_bytes(body)
  packet.to_bytes()
}

///|
/// Parse one full packet into a backend message.
/// If a complete packet still cannot be parsed, either the test setup or the protocol implementation is wrong.
async fn WireConnection::read_message(
  self : WireConnection,
) -> @backend.Message {
  let packet = read_socket_packet(self.socket)
  match @backend.Message::parse(packet[:]) {
    Some(parsed) => parsed.message
    None => fail("incomplete backend message")
  }
}

///|
/// Read messages until `ReadyForQuery`.
/// That lets each test follow a simple pattern: send one batch of frontend messages and collect the full backend response batch.
async fn WireConnection::collect_until_ready(
  self : WireConnection,
) -> Array[@backend.Message] {
  let messages : Array[@backend.Message] = []
  for message = self.read_message() {
    match message {
      @backend.Message::ReadyForQuery(body) =>
        self.transaction_status = body.status
      @backend.Message::ParameterStatus(body) =>
        self.parameters[body.name_str()] = body.value_str()
      @backend.Message::BackendKeyData(body) => {
        self.process_id = body.process_id
        self.secret_key = body.secret_key
      }
      _ => ()
    }
    messages.push(message)
    if message is @backend.Message::ReadyForQuery(_) {
      break messages
    } else {
      continue self.read_message()
    }
  }
}

///|
/// This helper matches the most common protocol-test pattern: write a buffer, then collect the full response batch.
async fn WireConnection::send_and_collect(
  self : WireConnection,
  buf : @buffer.Buffer,
) -> Array[@backend.Message] {
  self.write_buffer(buf)
  self.collect_until_ready()
}

///|
/// Send one SQL string through the simple-query protocol.
/// The optional `flush` is mainly used in cases like COPY where an explicit flush matters.
async fn WireConnection::simple_query(
  self : WireConnection,
  sql : String,
  flush? : Bool = false,
) -> Array[@backend.Message] {
  let sql_bytes = @proto.utf8_encode(sql)
  let buf = @buffer.new()
  @frontend.query(sql_bytes[:], buf)
  if flush {
    @frontend.flush(buf)
  }
  self.send_and_collect(buf)
}

///|
/// Complete the startup handshake at the protocol level and return a connection that can send raw frontend messages.
/// It supports cleartext and SCRAM authentication so later tests can focus on protocol details.
async fn wire_connect(
  config : IntegrationConfig,
  application_name~ : String,
) -> WireConnection {
  let socket = @socket.Tcp::connect_to_host(config.host, port=config.port)
  let connection = {
    socket,
    process_id: 0,
    secret_key: 0,
    parameters: {},
    transaction_status: b'I',
  }
  let user_bytes = @proto.utf8_encode(config.user)
  let database_bytes = @proto.utf8_encode(config.database)
  let application_name_bytes = @proto.utf8_encode(application_name)
  let parameters : Array[(BytesView, BytesView)] = [
    (b"user"[:], user_bytes[:]),
    (b"database"[:], database_bytes[:]),
    (b"client_encoding"[:], b"UTF8"[:]),
    (b"application_name"[:], application_name_bytes[:]),
  ]
  let buf = @buffer.new()
  @frontend.startup_message(parameters.iter(), buf)
  connection.write_buffer(buf)

  // This startup loop drives every authentication branch until the session reaches ReadyForQuery.
  let mut scram : @auth.ScramSha256? = None
  for message = connection.read_message() {
    match message {
      @backend.Message::AuthenticationOk => continue connection.read_message()
      @backend.Message::AuthenticationCleartextPassword => {
        wire_send_password(connection, config.password)
        continue connection.read_message()
      }
      @backend.Message::AuthenticationMd5Password(_) =>
        fail(
          "protocol integration tests do not support deprecated md5 authentication",
        )
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
        connection.process_id = body.process_id
        connection.secret_key = body.secret_key
        continue connection.read_message()
      }
      @backend.Message::NoticeResponse(_) => continue connection.read_message()
      @backend.Message::ReadyForQuery(body) => {
        connection.transaction_status = body.status
        break connection
      }
      @backend.Message::ErrorResponse(body) => {
        let err = parse_wire_database_error(body.fields())
        fail("startup failed: \{err.message}")
      }
      _ => fail("unexpected startup message")
    }
  }
}

///|
/// Send a cleartext password message.
async fn wire_send_password(
  connection : WireConnection,
  password : String,
) -> Unit {
  let password_bytes = @proto.utf8_encode(password)
  let buf = @buffer.new()
  @frontend.password_message(password_bytes[:], buf)
  connection.write_buffer(buf)
}

///|
/// Start the SCRAM exchange and return the state object used by later steps.
#warnings("-14")
async fn wire_begin_scram(
  connection : WireConnection,
  body : @backend.AuthenticationSaslBody,
  password : String,
) -> @auth.ScramSha256 {
  guard wire_supports_scram(body) else {
    fail("server does not offer SCRAM-SHA-256 authentication")
  }
  let password_bytes = @proto.utf8_encode(password)
  let nonce = @tls.rand_bytes(18)
  let scram = @auth.ScramSha256::new(
    password_bytes[:],
    @auth.ChannelBinding::unsupported(),
    nonce[:],
  )
  let buf = @buffer.new()
  @frontend.sasl_initial_response(@auth.SCRAM_SHA_256[:], scram.message(), buf)
  connection.write_buffer(buf)
  scram
}

///|
/// Continue the SCRAM exchange.
async fn wire_continue_scram(
  connection : WireConnection,
  scram : @auth.ScramSha256?,
  data : BytesView,
) -> Unit {
  let scram = wire_require_scram(scram)
  scram.update(data)
  let buf = @buffer.new()
  @frontend.sasl_response(scram.message(), buf)
  connection.write_buffer(buf)
}

///|
/// Finish the SCRAM exchange and validate the server-final message.
fn wire_finish_scram(
  scram : @auth.ScramSha256?,
  data : BytesView,
) -> Unit raise {
  wire_require_scram(scram).finish(data)
}

///|
/// Turn optional SCRAM state into a required value so out-of-order protocol steps fail clearly.
fn wire_require_scram(scram : @auth.ScramSha256?) -> @auth.ScramSha256 raise {
  match scram {
    Some(scram) => scram
    None => fail("missing SCRAM state")
  }
}

///|
/// Check whether the server's advertised SASL mechanisms include SCRAM-SHA-256.
fn wire_supports_scram(body : @backend.AuthenticationSaslBody) -> Bool raise {
  let mechanisms = body.mechanisms()
  for mechanism = mechanisms.next() {
    match mechanism {
      None => break false
      Some(mechanism) =>
        if mechanism == @auth.SCRAM_SHA_256 {
          break true
        } else {
          continue mechanisms.next()
        }
    }
  }
}

///|
/// Serialize an optional text parameter in the protocol's length-plus-payload format.
/// `None` becomes SQL `NULL`, encoded as length `-1`.
fn wire_serialize_param(param : String?, buf : @buffer.Buffer) -> @proto.IsNull {
  match param {
    None => @proto.IsNull::Yes
    Some(value) => {
      buf.write_bytes(@proto.utf8_encode(value))
      @proto.IsNull::No
    }
  }
}

///|
/// Centralize UTF-8 decoding for protocol tests so each test does not repeat the same error handling.
fn wire_decode_utf8(bytes : BytesView) -> String raise @proto.ProtocolError {
  @utf8.decode(bytes) catch {
    _ => raise @proto.ProtocolError::InvalidInput("invalid UTF-8")
  }
}

///|
/// Pull the error fields the tests actually care about out of a low-level error response.
fn parse_wire_database_error(
  fields : @backend.ErrorFields,
) -> WireDatabaseError raise @proto.ProtocolError {
  let mut severity = None
  let mut code = None
  let mut message = None
  let mut detail = None
  let mut hint = None
  for field = fields.next() {
    match field {
      None =>
        break {
          severity,
          code,
          message: message.unwrap_or("database error"),
          detail,
          hint,
        }
      Some(field) => {
        let value = wire_decode_utf8(field.value_bytes())
        match field.type_ {
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
}

///|
/// Convert each `DataRow` column into an easy-to-assert text array.
/// `None` is preserved so tests can check NULL encoding directly.
fn data_row_texts(
  body : @backend.DataRowBody,
) -> Array[String?] raise @proto.ProtocolError {
  let out : Array[String?] = []
  let ranges = body.ranges()
  let buffer = body.buffer()
  for range = ranges.next() {
    match range {
      None => break out
      Some(None) => {
        out.push(None)
        continue ranges.next()
      }
      Some(Some(range)) => {
        out.push(Some(wire_decode_utf8(buffer[range.start:range.end])))
        continue ranges.next()
      }
    }
  }
}

///|
/// Find a notification response in a message sequence.
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
/// Find a notice response in a message sequence.
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
/// Wait until the given backend is actually running the target SQL.
/// The cancel and concurrency tests rely on this sync point so cancellation does not happen too early.
async fn wait_for_backend_query(
  client : @client.Client,
  backend_pid : Int,
  sql : String,
) -> Unit {
  for _ in 0..<100 {
    let params : Array[&@client.ToSql] = [backend_pid as &@client.ToSql]
    let rows = client
      .query(
        "select state::text as state, coalesce(wait_event::text, '') as wait_event, query::text as query from pg_stat_activity where pid = $1::int4",
        params~,
      )
      .collect()
    if rows.length() == 1 {
      let row = rows[0]
      let state : String = row.get_name("state")
      let wait_event : String = row.get_name("wait_event")
      let running_query : String = row.get_name("query")
      if state == "active" && wait_event == "PgSleep" && running_query == sql {
        return
      }
    }
    @async.sleep(50)
  }
  fail("timed out waiting for backend query to start")
}

///|
/// This verifies the basic SSLRequest round trip.
/// The test sends only the TLS probe packet and checks for `S`, which means the server advertises TLS support.
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
/// This verifies that the startup authentication packet can be parsed both as a Header and as a full Message.
/// The test first feeds incomplete slices to make sure the parser does not guess, then checks the full packet tag, length, and SASL mechanisms.
async test "integration protocol startup packet header parsing" {
  guard integration_config() is Some(config) else { return }
  // Use a SCRAM account on purpose so the server returns AuthenticationSasl and exposes its mechanism list.
  let scram_config = {
    host: config.host,
    port: config.port,
    user: "moon_scram",
    password: config.password,
    database: config.database,
  }
  let socket = @socket.Tcp::connect_to_host(
    scram_config.host,
    port=scram_config.port,
  )
  defer socket.close()

  let user_bytes = @proto.utf8_encode(scram_config.user)
  let database_bytes = @proto.utf8_encode(scram_config.database)
  let application_name_bytes = @proto.utf8_encode("moonbit-postgres-startup")
  let parameters : Array[(BytesView, BytesView)] = [
    (b"user"[:], user_bytes[:]),
    (b"database"[:], database_bytes[:]),
    (b"client_encoding"[:], b"UTF8"[:]),
    (b"application_name"[:], application_name_bytes[:]),
  ]
  let startup = @buffer.new()
  @frontend.startup_message(parameters.iter(), startup)
  socket.write(startup.to_bytes())

  let packet = read_socket_packet(socket)
  assert_true(@backend.Header::parse(packet[:4]) is None)
  let header = match @backend.Header::parse(packet[:]) {
    Some(header) => header
    None => fail("expected startup header")
  }
  assert_eq(header.tag, @backend.AUTHENTICATION_TAG)
  assert_eq(header.len, packet.length() - 1)

  assert_true(@backend.Message::parse(packet[:4]) is None)
  assert_true(@backend.Message::parse(packet[:packet.length() - 1]) is None)
  let parsed = match @backend.Message::parse(packet[:]) {
    Some(parsed) => parsed
    None => fail("expected startup authentication message")
  }
  assert_eq(parsed.consumed, packet.length())
  match parsed.message {
    @backend.Message::AuthenticationSasl(body) => {
      let mechanisms = body.mechanisms()
      assert_eq(try! mechanisms.next_str(), Some("SCRAM-SHA-256"))
      assert_eq(try! mechanisms.next(), None)
      assert_eq(try! mechanisms.next(), None)
      assert_eq(try! mechanisms.next_str(), None)
    }
    _ => fail("expected AuthenticationSasl")
  }
}

///|
/// This verifies how the cancel-request packet works together with the high-level cancel token.
/// The client produces the pid and secret key, the protocol frontend builds the cancel request, and the database should answer with a cancellation error.
async test "integration cancel request uses protocol frontend" {
  guard integration_config() is Some(config) else { return }

  let result = @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres-cancel-main"),
    )
    group.spawn_bg(() => connection.run())

    let (observer, observer_connection) = @client.connect(
      as_client_config(
        config,
        application_name="moonbit-postgres-cancel-observer",
      ),
    )
    group.spawn_bg(() => observer_connection.run())

    // The observer connection only confirms that the target query is really running.
    let token = client.cancel_token()
    let backend_pid : Int = client
      .query_one("select pg_backend_pid()::int4 as pid")
      .get_name("pid")

    let task = group.spawn(() => try? client.query_one("select pg_sleep(5)"))
    wait_for_backend_query(observer, backend_pid, "select pg_sleep(5)")
    let cancel = @socket.Tcp::connect_to_host(config.host, port=config.port)
    defer cancel.close()
    let buf = @buffer.new()
    @frontend.cancel_request(token.process_id(), token.secret_key(), buf)
    cancel.write(buf.to_bytes())
    let err = expect_database_error(task.wait())
    assert_eq(err.code, Some("57014"))
    let ping : Int = client
      .query_one("select 1::int4 as value")
      .get_name("value")
    assert_eq(ping, 1)
    client.close()
    observer.close()
  })
  ignore(result)
}

///|
/// This verifies three basic protocol branches: empty query, statement with no result set, and parameter description.
/// The test first checks that empty SQL returns `EmptyQueryResponse`, then checks that a statement like `CREATE TABLE` returns `NoData` and parameter metadata.
async test "integration protocol empty query and no data" {
  guard integration_config() is Some(config) else { return }
  let wire = wire_connect(
    config,
    application_name="moonbit-postgres-empty-query",
  )
  defer wire.close()

  let empty = wire.simple_query("")
  assert_true(empty[0] is @backend.Message::EmptyQueryResponse)
  assert_true(empty[1] is @backend.Message::ReadyForQuery(_))

  let create = wire.simple_query(
    "create temp table wire_no_data (value int4 not null)",
  )
  match create[0] {
    @backend.Message::CommandComplete(body) =>
      assert_eq(body.tag_bytes().to_bytes(), b"CREATE TABLE")
    _ => fail("expected CREATE TABLE")
  }

  // Build parse/describe/sync directly to verify that low-level frontend encoding matches the backend description messages.
  let sql_bytes = @proto.utf8_encode(
    "insert into wire_no_data (value) values ($1::int4)",
  )
  let buf = @buffer.new()
  @frontend.parse(b"stmt_no_data"[:], sql_bytes[:], [23U].iter(), buf)
  @frontend.describe(b'S', b"stmt_no_data"[:], buf)
  @frontend.sync(buf)

  let messages = wire.send_and_collect(buf)
  assert_true(messages[0] is @backend.Message::ParseComplete)
  match messages[1] {
    @backend.Message::ParameterDescription(body) => {
      let parameters = body.parameters()
      assert_eq(try! parameters.next(), Some(23U))
      assert_eq(try! parameters.next(), None)
      assert_eq(try! parameters.next(), None)
    }
    _ => fail("expected ParameterDescription")
  }
  assert_true(messages[2] is @backend.Message::NoData)
  assert_true(messages[3] is @backend.Message::ReadyForQuery(_))
}

///|
/// This verifies `flush`, data messages, and terminate cleanup in a COPY OUT flow.
/// The test checks that `CopyOutResponse`, `CopyData`, `CopyDone`, `CommandComplete`, and `ReadyForQuery` all appear.
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
      assert_eq(body.format.to_int(), 0)
      let formats = body.column_formats()
      assert_eq(try! formats.next(), Some(0))
      assert_eq(try! formats.next(), None)
      assert_eq(try! formats.next(), None)
    }
    _ => fail("expected CopyOutResponse")
  }
  // Flags make it clear that this test cares about the full message set, not a fragile fixed index for every packet.
  let payload = @buffer.new()
  let mut saw_copy_data = false
  let mut saw_copy_done = false
  let mut saw_command_complete = false
  let mut saw_ready = false
  for message in messages {
    match message {
      @backend.Message::CopyData(body) => {
        saw_copy_data = true
        let data_len = body.data().length()
        let bytes = body.storage
        assert_eq(bytes.length(), data_len)
        payload.write_bytes(bytes)
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
/// This verifies the successful COPY IN path.
/// The test first waits for `CopyInResponse`, then writes two `CopyData` frames plus `CopyDone`, and finally checks the imported rows with a normal query.
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
      assert_eq(body.format.to_int(), 0)
      let formats = body.column_formats()
      assert_eq(try! formats.next(), Some(0))
      assert_eq(try! formats.next(), None)
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
/// This verifies that after the client sends `CopyFail`, the backend returns an error message and still ends the round in a reusable state.
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
/// This verifies that combining parse, describe, and close frontend messages yields complete parameter and row descriptions.
/// It also covers `CloseComplete`, proving that the named statement was closed successfully.
async test "integration protocol describe close and parameter description" {
  guard integration_config() is Some(config) else { return }
  let wire = wire_connect(config, application_name="moonbit-postgres-describe")
  defer wire.close()

  let sql_bytes = @proto.utf8_encode("select $1::int4 as value")
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
          assert_eq(field.type_oid, 23U)
          assert_eq(field.type_size, 4)
          assert_eq(field.format, 0)
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
/// This verifies text-format binding, result-column description, and the way `DataRow` represents NULL columns.
/// The test builds the bind packet by hand, then checks both column descriptions and the row encoding where the first column has data and the second is NULL.
async test "integration protocol bind text formats and null row ranges" {
  guard integration_config() is Some(config) else { return }
  let wire = wire_connect(
    config,
    application_name="moonbit-postgres-bind-formats",
  )
  defer wire.close()

  let create = wire.simple_query(
    "create temp table wire_bind_formats (id int4 primary key, note text)",
  )
  match create[0] {
    @backend.Message::CommandComplete(body) =>
      assert_eq(body.tag_bytes().to_bytes(), b"CREATE TABLE")
    _ => fail("expected CREATE TABLE")
  }

  let insert = wire.simple_query(
    "insert into wire_bind_formats values (7, null)",
  )
  match insert[0] {
    @backend.Message::CommandComplete(body) =>
      assert_eq(body.tag_bytes().to_bytes(), b"INSERT 0 1")
    _ => fail("expected INSERT command complete")
  }

  let sql_bytes = @proto.utf8_encode(
    "select id, note from wire_bind_formats where id = $1::int4",
  )
  let formats : Array[Int] = [0]
  let params : Array[String?] = [Some("7")]
  let result_formats : Array[Int] = [0, 0]
  let buf = @buffer.new()
  @frontend.parse(b"stmt_formats"[:], sql_bytes[:], [23U].iter(), buf)
  @frontend.bind(
    b"portal_formats"[:],
    b"stmt_formats"[:],
    formats.iter(),
    params.iter(),
    fn(param, payload) { wire_serialize_param(param, payload) },
    result_formats.iter(),
    buf,
  )
  @frontend.describe(b'P', b"portal_formats"[:], buf)
  @frontend.execute(b"portal_formats"[:], 0, buf)
  @frontend.sync(buf)

  let messages = wire.send_and_collect(buf)
  assert_true(messages[0] is @backend.Message::ParseComplete)
  assert_true(messages[1] is @backend.Message::BindComplete)
  match messages[2] {
    @backend.Message::RowDescription(body) => {
      let fields = body.fields()
      let first = try! fields.next()
      let second = try! fields.next()
      match first {
        Some(field) => {
          assert_eq(try! field.name_str(), "id")
          assert_true(field.table_oid > 0U)
          assert_eq(field.column_id, 1)
          assert_eq(field.type_oid, 23U)
          assert_eq(field.type_size, 4)
          assert_eq(field.type_modifier, -1)
          assert_eq(field.format, 0)
        }
        None => fail("missing first described field")
      }
      match second {
        Some(field) => {
          assert_eq(try! field.name_str(), "note")
          assert_true(field.table_oid > 0U)
          assert_eq(field.column_id, 2)
          assert_eq(field.type_oid, 25U)
          assert_eq(field.type_size, -1)
          assert_eq(field.type_modifier, -1)
          assert_eq(field.format, 0)
        }
        None => fail("missing second described field")
      }
      assert_true((try! fields.next()) is None)
      assert_true((try! fields.next()) is None)
    }
    _ => fail("expected RowDescription")
  }
  match messages[3] {
    @backend.Message::DataRow(body) => {
      let ranges = body.ranges()
      let buffer = body.buffer()
      let first_range = try! ranges.next()
      match first_range {
        Some(Some(range)) =>
          assert_eq(wire_decode_utf8(buffer[range.start:range.end]), "7")
        _ => fail("expected first column data")
      }
      assert_true((try! ranges.next()) is Some(None))
      assert_true((try! ranges.next()) is None)
      assert_true((try! ranges.next()) is None)
    }
    _ => fail("expected DataRow")
  }
  match messages[4] {
    @backend.Message::CommandComplete(body) =>
      assert_eq(body.tag_bytes().to_bytes(), b"SELECT 1")
    _ => fail("expected SELECT command complete")
  }
  assert_true(messages[5] is @backend.Message::ReadyForQuery(_))
}

///|
/// This verifies that a portal with a row limit returns part of the result and then emits `PortalSuspended`.
/// That shows the protocol-level pagination behavior is working instead of draining the full result at once.
async test "integration protocol portal suspended" {
  guard integration_config() is Some(config) else { return }
  let wire = wire_connect(config, application_name="moonbit-postgres-portal")
  defer wire.close()

  let sql_bytes = @proto.utf8_encode(
    "select generate_series(1, 3)::int4 as value",
  )
  let formats : Array[Int] = []
  let params : Array[String?] = []
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
      assert_true(body.storage.length() > 0)
      assert_eq(data_row_texts(body), [Some("1")])
    }
    _ => fail("expected DataRow")
  }
  assert_true(messages[4] is @backend.Message::PortalSuspended)
  assert_true(messages[5] is @backend.Message::ReadyForQuery(_))
}

///|
/// This verifies the field accessors for notice and notification messages.
/// The notice side scans for the `M` message field, and the notification side checks both raw bytes and decoded string accessors.
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
  for field = notice_fields.next() {
    match field {
      None => break ()
      Some(field) =>
        if field.type_ == b'M' {
          saw_message = true
          assert_eq(wire_decode_utf8(field.value_bytes()), "wire notice")
          break ()
        } else {
          continue notice_fields.next()
        }
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
  assert_true(notification.process_id > 0)
  assert_eq(notification.channel_bytes().to_bytes(), b"wire_channel")
  assert_eq(try! notification.channel_str(), "wire_channel")
  assert_eq(notification.message_bytes().to_bytes(), b"payload")
  assert_eq(try! notification.message_str(), "payload")
}
