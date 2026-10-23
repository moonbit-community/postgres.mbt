///|
async fn send_scram_challenge(socket : @socket.Tcp, count : String) -> Unit {
  let mechanisms = Buffer()
  mechanisms.write_int_be(10)
  mechanisms.write_bytes(b"SCRAM-SHA-256\x00\x00")
  socket.write(startup_backend_packet(b'R', mechanisms))
  let (tag, initial) = copy_resource_frame(socket)
  assert_eq(tag, b'p')
  let reader = @proto.ByteReader::new(initial[:])
  assert_eq(reader.read_cstr(), b"SCRAM-SHA-256")
  let length = reader.read_i32_be()
  let first = reader.read_bytes(length)
  assert_eq(first[:8].to_owned(), b"n,,n=,r=")
  let challenge = Buffer()
  challenge.write_int_be(11)
  challenge.write_bytes(b"r=")
  challenge.write_bytesview(first[8:])
  challenge.write_bytes(b"server,s=c2FsdA==,i=")
  challenge.write_bytes(@proto.utf8_encode(count))
  socket.write(startup_backend_packet(b'R', challenge))
}

///|
async test "SCRAM invalid counts fail authentication before a proof is sent" {
  for
    (count, limit) in [
      ("100001", 100_000),
      ("3", 2),
      ("2147483648", 2_147_483_647),
      ("4294967297", 100_000),
      ("", 100_000),
      ("0", 100_000),
      ("-1", 100_000),
      ("1x", 100_000),
    ] {
    @async.with_timeout(2000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let backend = group.spawn(() => {
          let (socket, _) = server.accept()
          defer socket.close()
          read_startup_packet(socket)
          send_scram_challenge(socket, count)
          assert_true(socket.read_some(max_len=1) is None)
        })
        let (client, executor) = Client::create(
          Config(
            "127.0.0.1",
            port=server.addr.port(),
            user="moon",
            password="pencil",
            ssl_mode=Disable,
            application_name="scram-count-reject",
            scram_max_iterations=limit,
          ),
        )
        defer client.abort()
        let running = group.spawn(allow_failure=true, () => executor.run())
        let error = expect_error_async(() => client.ready())
        assert_true(error is ClientError::Authentication(_))
        assert_true(
          expect_error_async(() => running.wait())
          is ClientError::Authentication(_),
        )
        assert_true(client.is_closed())
        backend.wait()
      })
    })
  }
}

///|
async test "SCRAM cancellation observes both partial derivation and the final batch yield" {
  for count in [1, 254, 255, 256, 257, 100_000] {
    @async.with_timeout(2000, () => {
      @async.with_task_group(group => {
        let (client, driver, backend) = connection_test_pair(group)
        defer client.abort()
        defer driver.stream.close()
        defer backend.close()
        let scram = @auth.ScramSha256::new_inner(
          b"pencil",
          @auth.ChannelBinding::unsupported(),
          b"client",
        )
        let challenge = @proto.utf8_encode(
          "r=clientserver,s=c2FsdA==,i=\{count}",
        )
        let started : @async.Queue[Unit] = Queue(kind=Unbounded)
        let task = group.spawn(allow_failure=true, () => {
          started.put(())
          continue_scram(
            driver.stream,
            Some(scram),
            challenge,
            max_iterations=count,
          )
        })
        started.get()
        assert_true(task.try_wait() is None)
        if count <= 254 {
          // The proof is complete but must remain unsent until the final yield.
          assert_true(scram.message().length() > 0)
        } else {
          assert_true(
            @test.expect_error(() => scram.message())
            is @proto.ProtocolError::InvalidInput(_),
          )
        }
        task.cancel()
        assert_true(
          expect_error_async(() => task.wait())
          is @async.WaitedTaskAlreadyCancelled,
        )
        driver.stream.close()
        assert_true(backend.read_some(max_len=1) is None)
      })
    })
  }
}

///|
async test "SCRAM derivation permits another connection and obeys cancellation and connect timeout" {
  for timeout in [false, true] {
    @async.with_timeout(3000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let challenged : @async.Queue[Unit] = Queue(kind=Unbounded)
        let backend = group.spawn(() => {
          let (socket, _) = server.accept()
          defer socket.close()
          read_startup_packet(socket)
          send_scram_challenge(socket, "2147483647")
          challenged.put(())
          assert_true(socket.read_some(max_len=1) is None)
        })
        let (client, executor) = Client::create(
          Config(
            "127.0.0.1",
            port=server.addr.port(),
            user="moon",
            password="pencil",
            ssl_mode=Disable,
            application_name="scram-cancel-timeout",
            scram_max_iterations=2_147_483_647,
            connect_timeout_ms?=if timeout { Some(150) } else { None },
          ),
        )
        defer client.abort()
        let running = group.spawn(allow_failure=true, () => executor.run())
        let ready = group.spawn(allow_failure=true, () => client.ready())
        challenged.get()
        let (peer, peer_driver, peer_backend) = connection_test_pair(group)
        defer peer.abort()
        defer peer_backend.close()
        let peer_running = group.spawn(() => peer_driver.run(group))
        peer.shared.driver_task.val = Some(peer_running)
        let ping = group.spawn(() => peer.check_connection())
        assert_eq(peer_backend.read_exactly(5), sync_bytes())
        peer_backend.write(ready_for_query_packet(b'I'))
        ping.wait()
        assert_true(ready.try_wait() is None)
        if timeout {
          assert_true(
            expect_error_async(() => ready.wait())
            is ClientError::Protocol("connection timed out"),
          )
          assert_true(
            expect_error_async(() => running.wait())
            is ClientError::Protocol("connection timed out"),
          )
        } else {
          running.cancel()
          assert_true(
            expect_error_async(() => running.wait())
            is @async.WaitedTaskAlreadyCancelled,
          )
          assert_true(
            expect_error_async(() => ready.wait()) is ClientError::Closed(_),
          )
        }
        assert_true(client.is_closed())
        backend.wait()
        peer.abort()
        peer_running.wait() catch {
          @async.WaitedTaskAlreadyCancelled => ()
          error => raise error
        }
      })
    })
  }
}

///|
async test "SCRAM configuration rejects nonpositive budgets before connecting" {
  assert_eq(
    Config("", user="moon", application_name="scram-default").scram_max_iterations,
    100_000,
  )
  for count in [1, 100_000, 2_147_483_647] {
    Config(
      "",
      user="moon",
      application_name="scram-valid",
      scram_max_iterations=count,
    ).validate_resource_limits()
  }
  for count in [0, -1, -2_147_483_648] {
    let (client, executor) = Client::create(
      Config(
        "",
        user="moon",
        application_name="scram-invalid",
        scram_max_iterations=count,
      ),
    )
    assert_true(
      expect_error_async(() => executor.run()) is ClientError::InvalidConfig(_),
    )
    assert_true(
      expect_error_async(() => client.ready()) is ClientError::InvalidConfig(_),
    )
  }
}
