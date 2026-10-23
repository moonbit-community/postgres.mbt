///|
fn backend_length_header(length : Int32) -> Bytes {
  let bytes = Buffer()
  bytes.write_byte(b'd')
  bytes.write_int_be(length)
  bytes.to_bytes()
}

///|
async fn check_backend_length_rejection(
  length : Int32,
  startup~ : Bool,
) -> Unit {
  @async.with_timeout(2000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let reject : @async.Queue[Unit] = Queue(kind=Unbounded)
      let backend = group.spawn(() => {
        let (socket, _) = server.accept()
        defer socket.close()
        read_startup_packet(socket)
        if !startup {
          socket.write(auth_ok_packet())
          socket.write(ready_for_query_packet(b'I'))
          assert_eq(socket.read_exactly(5), sync_bytes())
          reject.get()
        }
        // Send only the header: rejecting it must never wait for body bytes.
        socket.write(backend_length_header(length))
        assert_true(socket.read_some(max_len=1) is None)
      })
      let (client, executor) = Client::create(
        Config(
          "127.0.0.1",
          port=server.addr.port(),
          user="moon",
          ssl_mode=Disable,
          application_name="backend-length-test",
          max_backend_message_body_bytes=8,
        ),
      )
      defer client.abort()
      let running = group.spawn(allow_failure=true, () => executor.run())
      if startup {
        let first = group.spawn(allow_failure=true, () => client.ready())
        let second = group.spawn(allow_failure=true, () => client.ready())
        assert_true(
          expect_error_async(() => first.wait()) is ClientError::Protocol(_),
        )
        assert_true(
          expect_error_async(() => second.wait()) is ClientError::Protocol(_),
        )
      } else {
        client.ready()
        let active = client.send_request(Messages, sync_bytes())
        let queued = client.send_request(Messages, sync_bytes())
        reject.put(())
        assert_true(
          expect_error_async(() => active.get()) is ClientError::Protocol(_),
        )
        assert_true(
          expect_error_async(() => queued.get()) is ClientError::Protocol(_),
        )
      }
      assert_true(
        expect_error_async(() => running.wait()) is ClientError::Protocol(_),
      )
      assert_true(client.is_closed())
      backend.wait()
    })
  })
}

///|
async test "backend framing rejects invalid and oversized lengths at startup and runtime" {
  for startup in [true, false] {
    for
      length in [
        -2_147_483_648, -1, 0, 1, 2, 3, 13, 2_147_483_646, 2_147_483_647,
      ] {
      check_backend_length_rejection(length, startup~)
    }
  }
}

///|
async test "backend framing accepts zero body and the exact configured limit" {
  @async.with_timeout(2000, () => {
    @async.with_task_group(group => {
      let (client, driver, backend) = connection_test_pair(group)
      defer client.abort()
      defer driver.stream.close()
      defer backend.close()
      for
        (packet, limit) in [
          (b"1\x00\x00\x00\x04", 1),
          (b"d\x00\x00\x00\x0C12345678", 8),
        ] {
        backend.write(packet)
        let message = read_backend_message(driver.stream, limit)
        match message {
          ParseComplete => assert_eq(limit, 1)
          CopyData(body) => assert_eq(body.storage, b"12345678")
          _ => fail("unexpected boundary message")
        }
      }
    })
  })
}

///|
async test "startup and runtime accept frames exactly at the configured limit" {
  @async.with_timeout(2000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let backend = group.spawn(() => {
        let (socket, _) = server.accept()
        defer socket.close()
        read_startup_packet(socket)
        socket.write(auth_ok_packet())
        socket.write(ready_for_query_packet(b'I'))
        assert_eq(socket.read_exactly(5), sync_bytes())
        socket.write(parameter_status_packet("a", "b"))
        socket.write(ready_for_query_packet(b'I'))
        assert_eq(socket.read_exactly(5), terminate_bytes())
      })
      let (client, executor) = Client::create(
        Config(
          "127.0.0.1",
          port=server.addr.port(),
          user="moon",
          ssl_mode=Disable,
          application_name="backend-limit-boundary",
          max_backend_message_body_bytes=4,
        ),
      )
      defer client.abort()
      let running = group.spawn(() => executor.run())
      client.ready()
      client.check_connection()
      assert_eq(client.parameter("a"), Some("b"))
      client.close()
      running.wait()
      backend.wait()
    })
  })
}

///|
async test "invalid backend message budgets fail readiness before connecting" {
  let defaults = Config("", user="moon", application_name="budget-defaults")
  assert_eq(defaults.max_backend_message_body_bytes, 67_108_864)
  for limit in [1, 2_147_483_642] {
    Config(
      "",
      user="moon",
      application_name="budget-valid",
      max_backend_message_body_bytes=limit,
    ).validate_resource_limits()
  }
  for limit in [-1, 0, 2_147_483_643, 2_147_483_647] {
    // An empty TLS host would fail differently if transport setup were reached.
    let config = Config(
      "",
      user="moon",
      application_name="budget-invalid",
      max_backend_message_body_bytes=limit,
    )
    let (client, executor) = Client::create(config)
    assert_true(
      expect_error_async(() => executor.run()) is ClientError::InvalidConfig(_),
    )
    assert_true(
      expect_error_async(() => client.ready()) is ClientError::InvalidConfig(_),
    )
    assert_true(client.is_closed())
  }
}
