///|
fn connect_backend_packet(
  tag : Byte,
  payload : @buffer.Buffer,
) -> Bytes raise @proto.ProtocolError {
  let packet = @buffer.new()
  packet.write_byte(tag)
  packet.write_int_be(@proto.i32_from_usize(payload.length() + 4))
  packet.write_bytes(payload.to_bytes())
  packet.to_bytes()
}

///|
fn auth_ok_packet() -> Bytes raise @proto.ProtocolError {
  let payload = @buffer.new()
  payload.write_int_be(0)
  connect_backend_packet(@backend.AUTHENTICATION_TAG, payload)
}

///|
fn parameter_status_packet(
  name : String,
  value : String,
) -> Bytes raise @proto.ProtocolError {
  let payload = @buffer.new()
  payload.write_bytes(@proto.utf8_encode(name))
  payload.write_byte(0)
  payload.write_bytes(@proto.utf8_encode(value))
  payload.write_byte(0)
  connect_backend_packet(@backend.PARAMETER_STATUS_TAG, payload)
}

///|
fn backend_key_data_packet(
  process_id : Int,
  secret_key : Int,
) -> Bytes raise @proto.ProtocolError {
  let payload = @buffer.new()
  payload.write_int_be(process_id)
  payload.write_int_be(secret_key)
  connect_backend_packet(@backend.BACKEND_KEY_DATA_TAG, payload)
}

///|
fn ready_for_query_packet(status : Byte) -> Bytes raise @proto.ProtocolError {
  let payload = @buffer.new()
  payload.write_byte(status)
  connect_backend_packet(@backend.READY_FOR_QUERY_TAG, payload)
}

///|
fn make_shared(
  parameters? : Map[String, String] = {},
  closed? : Bool = false,
  closing? : Bool = false,
) -> Shared {
  let types : Map[@proto.Oid, Type] = {}
  seed_builtin_types(types)
  {
    config: Config::new(
      "127.0.0.1",
      user="moon",
      database="moondb",
      password="moonpass",
      port=55432,
      ssl_mode=Disable,
      application_name="moonbit-postgres-connect-wbtest",
    ),
    requests: @async.Queue::new(kind=Unbounded),
    async_messages: @async.Queue::new(kind=Unbounded),
    background_group: @ref.new(None),
    parameters,
    types,
    process_id: @ref.new(321),
    secret_key: @ref.new(654),
    transaction_status: @ref.new(b'I'),
    closed: @ref.new(closed),
    closing: @ref.new(closing),
    next_id: @ref.new(0),
  }
}

///|
async test "connect captures startup state and close enqueues terminate request" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer::new(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()

    group.spawn_bg(() => {
      let (conn, _) = server.accept()
      defer conn.close()
      read_startup_packet(conn)
      conn.write(auth_ok_packet())
      conn.write(parameter_status_packet("client_encoding", "UTF8"))
      conn.write(
        parameter_status_packet(
          "application_name", "moonbit-postgres-connect-wbtest",
        ),
      )
      conn.write(backend_key_data_packet(321, 654))
      conn.write(ready_for_query_packet(b'I'))
    })

    let (client, connection) = connect(
      Config::new(
        "127.0.0.1",
        user="moon",
        database="moondb",
        password="moonpass",
        port=server.addr.port(),
        ssl_mode=Disable,
        application_name="moonbit-postgres-connect-wbtest",
        connect_timeout_ms=200,
      ),
    )
    defer connection.stream.close()

    @debug.assert_eq(client.is_closed(), false)
    @debug.assert_eq(client.parameter("client_encoding"), Some("UTF8"))
    @debug.assert_eq(client.parameter("missing"), None)
    @debug.assert_eq(
      connection.parameter("application_name"),
      Some("moonbit-postgres-connect-wbtest"),
    )

    let token = client.cancel_token()
    @debug.assert_eq(token.process_id(), 321)
    @debug.assert_eq(token.secret_key(), 654)

    client.shared.types[99999U] = Type::unknown(99999U, name="tmp")
    client.clear_type_cache()
    assert_true(client.shared.types.get(Type::bool().oid) == Some(Type::bool()))
    assert_true(client.shared.types.get(99999U) is None)

    client.close()
    let request = client.shared.requests.try_get() catch { _ => None }
    guard request is Some(request) else { fail("expected terminate request") }
    assert_true(request.kind is RequestKind::Terminate)
    @debug.assert_eq(request.bytes, terminate_bytes())

    client.close()
    let extra = client.shared.requests.try_get() catch { _ => None }
    assert_true(extra is None)
  })
}

///|
async test "connect timeout surfaces protocol timeout" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer::new(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()

    group.spawn_bg(() => {
      let (conn, _) = server.accept()
      defer conn.close()
      read_startup_packet(conn)
      @async.sleep(100)
    })

    let result : Result[(Client, Connection), Error] = try? connect(
      Config::new(
        "127.0.0.1",
        user="moon",
        database="moondb",
        password="moonpass",
        port=server.addr.port(),
        ssl_mode=Disable,
        application_name="moonbit-postgres-connect-timeout",
        connect_timeout_ms=10,
      ),
    )
    guard result is Err(ClientError::Protocol(message)) else {
      fail("expected timeout error")
    }
    @debug.assert_eq(message, "connection timed out")
  })
}

///|
async test "client close handles closed request queue and check_connection rejects closed runtime" {
  let shared = make_shared()
  let client : Client = { shared, }

  shared.requests.close()
  client.close()
  @debug.assert_eq(shared.closed.val, true)
  @debug.assert_eq(shared.closing.val, true)

  let closed_shared = make_shared(closed=true)
  let closed_client : Client = { shared: closed_shared }
  let result : Result[Unit, Error] = try? closed_client.check_connection()
  guard result is Err(ClientError::Closed(message)) else {
    fail("expected closed connection error")
  }
  @debug.assert_eq(message, "connection is closed")
}

///|
async test "cancel token returns early when connection is already closed" {
  let shared = make_shared(closed=true)
  let client : Client = { shared, }
  let token = client.cancel_token()
  token.cancel()
  @debug.assert_eq(token.process_id(), 321)
  @debug.assert_eq(token.secret_key(), 654)
}
