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
  let payload = @buffer.new(size_hint=4 + salt.length())
  payload.write_int_be(authentication_md5_password_subtype)
  payload.write_bytesview(salt)

  let packet = @buffer.new(size_hint=1 + 4 + payload.length())
  packet.write_byte(@backend.AUTHENTICATION_TAG)
  packet.write_int_be(12)
  packet.write_bytes(payload.to_bytes())
  packet.to_bytes()
}

///|
async test "connect rejects deprecated md5 authentication" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer::new(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()

    group.spawn_bg(() => {
      let (conn, _) = server.accept()
      defer conn.close()
      read_startup_packet(conn)
      conn.write(authentication_md5_packet(b"md5!"[:]))
    })

    let result = try? connect(
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
    guard result is Err(ClientError::Authentication(message)) else {
      fail("expected md5 authentication rejection")
    }
    @debug.assert_eq(message, deprecated_md5_authentication_message)
  })
}
