///|
async fn copy_resource_frame(socket : @socket.Tcp) -> (Byte, Bytes) {
  let prefix = socket.read_exactly(5)
  let length = @proto.ByteReader::new(prefix[1:]).read_i32_be()
  (prefix[0], socket.read_exactly(length - 4))
}

///|
async test "COPY NUL abort stays usable and scope cleanup sends a valid failure" {
  for scoped in [false, true] {
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
          assert_eq(copy_resource_frame(socket).0, b'Q')
          socket.write(b"G\x00\x00\x00\x07\x00\x00\x00")
          if !scoped {
            let (tag, data) = copy_resource_frame(socket)
            assert_eq(tag, b'd')
            assert_eq(data, b"still usable\n")
          }
          let (tag, message) = copy_resource_frame(socket)
          assert_eq(tag, b'f')
          assert_eq(
            message,
            if scoped {
              b"COPY aborted\x00"
            } else {
              b"valid abort\x00"
            },
          )
          let error = Buffer()
          error.write_bytes(b"Mcopy aborted\x00\x00")
          socket.write(copy_test_backend_packet(b'E', error))
          socket.write(ready_for_query_packet(b'I'))
          assert_eq(socket.read_exactly(5), sync_bytes())
          socket.write(ready_for_query_packet(b'I'))
          assert_eq(socket.read_exactly(5), terminate_bytes())
        })
        let (client, executor) = Client::create(
          Config(
            "127.0.0.1",
            port=server.addr.port(),
            user="moon",
            ssl_mode=Disable,
            application_name="copy-abort-validation",
          ),
        )
        defer client.abort()
        let running = group.spawn(() => executor.run())
        client.ready()
        if scoped {
          assert_true(
            expect_error_async(() => {
              client.with_copy_in("COPY t FROM STDIN", sink => {
                sink.abort(message="bad\u0000message")
              })
            })
            is @proto.ProtocolError::InvalidInput(_),
          )
        } else {
          let sink = client.copy_in("COPY t FROM STDIN")
          assert_true(
            expect_error_async(() => sink.abort(message="bad\u0000message"))
            is @proto.ProtocolError::InvalidInput(_),
          )
          assert_false(sink.finished.val)
          assert_false(sink.permit.released.val)
          sink.send(b"still usable\n")
          sink.abort(message="valid abort")
          assert_true(sink.permit.released.val)
        }
        client.check_connection()
        client.close()
        running.wait()
        backend.wait()
      })
    })
  }
}

///|
async test "COPY writer failure stops its executor and wakes every request queue" {
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
        assert_eq(copy_resource_frame(socket).0, b'Q')
        socket.write(b"G\x00\x00\x00\x07\x00\x00\x00")
        // No completion: only failure supervision can unblock the driver.
        assert_true(socket.read_some(max_len=1) is None)
      })
      let (client, executor) = Client::create(
        Config(
          "127.0.0.1",
          port=server.addr.port(),
          user="moon",
          ssl_mode=Disable,
          application_name="copy-writer-failure",
        ),
      )
      defer client.abort()
      let running = group.spawn(allow_failure=true, () => executor.run())
      client.ready()
      let sink = client.copy_in("COPY t FROM STDIN")
      let queued_input : @async.Queue[CopyInAction] = Queue(kind=Blocking(1))
      let queued = client.send_request_with_copy(sync_bytes(), queued_input)
      assert_true(queued_input.try_put(Finish))
      let producer = group.spawn(allow_failure=true, () => {
        queued_input.put(Finish)
      })
      // An unexpected producer error deterministically exercises writer failure
      // without racing a TCP read failure against a TCP write failure.
      sink.input.close(
        error=ClientError::Encode("original COPY writer failure"),
        clear=true,
      )
      assert_true(
        expect_error_async(() => running.wait())
        is ClientError::Encode("original COPY writer failure"),
      )
      assert_true(
        expect_error_async(() => sink.responses.get())
        is ClientError::Encode("original COPY writer failure"),
      )
      assert_true(
        expect_error_async(() => queued.get())
        is ClientError::Encode("original COPY writer failure"),
      )
      assert_true(
        expect_error_async(() => producer.wait())
        is ClientError::Encode("original COPY writer failure"),
      )
      sink.finish_scope() catch {
        _ => ()
      }
      assert_true(sink.permit.released.val)
      assert_true(client.is_closed())
      backend.wait()
    })
  })
}

///|
async test "COPY socket write failure reaches the connection task group" {
  @async.with_timeout(2000, () => {
    @async.with_task_group(group => {
      let (client, driver, backend) = connection_test_pair(group)
      defer client.abort()
      defer backend.close()
      driver.stream.close()
      let input : @async.Queue[CopyInAction] = Queue(kind=Unbounded)
      input.put(Fail(copy_fail_bytes("abort on closed transport")))
      let error = expect_error_async(() => {
        @async.with_task_group(connection_group => {
          ignore(driver.spawn_copy_writer(connection_group, input, Ref(false)))
          // An allowed writer failure would leave this group waiting forever.
          let blocked : @async.Queue[Unit] = Queue(kind=Unbounded)
          blocked.get()
        })
      })
      assert_false(error is @async.TimeoutError)
      assert_false(error is @async.WaitedTaskAlreadyCancelled)
    })
  })
}
