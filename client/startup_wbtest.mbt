///|
let authentication_cleartext_password_subtype = 3

///|
let authentication_md5_password_subtype = 5

///|
async fn read_startup_packet(conn : @socket.Tcp) -> Unit {
  let header = conn.read_exactly(4)
  let body_len = @proto.ByteReader::new(header[:]).read_i32_be()
  ignore(conn.read_exactly(body_len - 4))
}

///|
fn authentication_md5_packet(salt : BytesView) -> Bytes {
  let payload = Buffer(size_hint=4 + salt.length())
  payload.write_int_be(authentication_md5_password_subtype)
  payload.write_bytesview(salt)

  let packet = Buffer(size_hint=1 + 4 + payload.length())
  packet.write_byte(@backend.AUTHENTICATION_TAG)
  packet.write_int_be(12)
  packet.write_bytes(payload.to_bytes())
  packet.to_bytes()
}

///|
fn startup_backend_packet(
  tag : Byte,
  payload : @buffer.Buffer,
) -> Bytes raise @proto.ProtocolError {
  let packet = Buffer()
  packet.write_byte(tag)
  packet.write_int_be(@proto.i32_from_usize(payload.length() + 4))
  packet.write_bytes(payload.to_bytes())
  packet.to_bytes()
}

///|
fn authentication_cleartext_password_packet() -> Bytes raise @proto.ProtocolError {
  let payload = Buffer(size_hint=4)
  payload.write_int_be(authentication_cleartext_password_subtype)
  startup_backend_packet(@backend.AUTHENTICATION_TAG, payload)
}

///|
fn startup_auth_ok_packet() -> Bytes raise @proto.ProtocolError {
  let payload = Buffer(size_hint=4)
  payload.write_int_be(0)
  startup_backend_packet(@backend.AUTHENTICATION_TAG, payload)
}

///|
async test "connect rejects deprecated md5 authentication" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()

    group.spawn_bg(() => {
      let (conn, _) = server.accept()
      defer conn.close()
      read_startup_packet(conn)
      conn.write(authentication_md5_packet(b"md5!"[:]))
    })

    let result = expect_error_async(() => {
      connect(
        Config::new(
          "127.0.0.1",
          user="moon",
          database="moondb",
          password="moonpass",
          port=server.addr.port(),
          ssl_mode=Disable,
          application_name="moonbit-postgres-md5-reject",
        ),
      )
    })
    guard result is ClientError::Authentication(message) else {
      fail("expected md5 authentication rejection")
    }
    @debug.assert_eq(message, deprecated_md5_authentication_message)
  })
}

///|
async test "connect rejects cleartext password when channel binding is required" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()

    group.spawn_bg(() => {
      let (conn, _) = server.accept()
      defer conn.close()
      read_startup_packet(conn)
      conn.write(authentication_cleartext_password_packet())
    })

    let result = expect_error_async(() => {
      connect(
        Config::new(
          "127.0.0.1",
          user="moon",
          database="moondb",
          password="moonpass",
          port=server.addr.port(),
          ssl_mode=Disable,
          channel_binding=Require,
          application_name="moonbit-postgres-channel-binding-password-reject",
        ),
      )
    })
    guard result is ClientError::Authentication(message) else {
      fail("expected channel binding authentication rejection")
    }
    @debug.assert_eq(message, channel_binding_required_unsupported_message)
  })
}

///|
async test "connect rejects authentication ok when channel binding is required" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()

    group.spawn_bg(() => {
      let (conn, _) = server.accept()
      defer conn.close()
      read_startup_packet(conn)
      conn.write(startup_auth_ok_packet())
    })

    let result = expect_error_async(() => {
      connect(
        Config::new(
          "127.0.0.1",
          user="moon",
          database="moondb",
          password="moonpass",
          port=server.addr.port(),
          ssl_mode=Disable,
          channel_binding=Require,
          application_name="moonbit-postgres-channel-binding-auth-ok-reject",
        ),
      )
    })
    guard result is ClientError::Authentication(message) else {
      fail("expected missing channel binding authentication rejection")
    }
    @debug.assert_eq(message, channel_binding_required_not_used_message)
  })
}
