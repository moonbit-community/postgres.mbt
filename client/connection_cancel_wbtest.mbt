///|
async fn connection_test_pair(
  group : @async.TaskGroup[Unit],
) -> (Client, Driver, @socket.Tcp) {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  let socket = @socket.Tcp::connect(server.addr)
  let (backend, _) = server.accept()
  let shared = make_shared(group~)
  ({ shared, }, { shared, stream: Plain(socket), }, backend)
}

///|
async test "connection cancellation closes idle runtime before joining protected listeners" {
  @async.with_task_group(group => {
    let (client, connection, backend) = connection_test_pair(group)
    defer backend.close()
    defer connection.stream.close()
    defer close_runtime(client.shared)
    @async.with_timeout(2000, () => {
      let driver = group.spawn(allow_failure=true, () => connection.run(group))
      // A completed round trip leaves the driver idle in the submission queue.
      let ping = group.spawn(() => client.check_connection())
      assert_eq(backend.read_exactly(5), sync_bytes())
      backend.write(ready_for_query_packet(b'I'))
      ping.wait()
      let started : @async.Queue[Unit] = Queue(kind=Unbounded)
      let listener = group.spawn(no_wait=true, allow_failure=true, () => {
        @async.protect_from_cancel(() => {
          started.put(())
          assert_true(client.next_message() is None)
        })
      })
      started.get()
      driver.cancel()
      let error = expect_error_async(() => {
        @async.with_timeout(1000, () => driver.wait())
      })
      assert_true(error is @async.TaskCancelled)
      listener.wait()
      assert_true(client.is_closed())
      assert_true(client.shared.closing.val)
      assert_true(
        @test.expect_error(() => client.shared.control.queue.try_put(() => ()))
        is @aqueue.QueueAlreadyClosed,
      )
      assert_true(
        expect_error_async(() => client.check_connection())
        is ClientError::Closed(_),
      )
      assert_true(backend.read_some() is None)
    })
  })
}

///|
async test "connection cancellation closes pending and queued COPY requests" {
  @async.with_task_group(group => {
    let (client, connection, backend) = connection_test_pair(group)
    defer backend.close()
    defer connection.stream.close()
    defer close_runtime(client.shared)
    let input : @async.Queue[CopyInAction] = Queue(kind=Blocking(1))
    let pending = client.send_request_with_copy(sync_bytes(), input)
    defer pending.close(clear=true)
    defer input.close(clear=true)
    @async.with_timeout(2000, () => {
      let driver = group.spawn(allow_failure=true, () => connection.run(group))
      assert_eq(backend.read_exactly(5), sync_bytes())
      let queued_input : @async.Queue[CopyInAction] = Queue(kind=Blocking(1))
      let queued = client.send_request_with_copy(sync_bytes(), queued_input)
      defer queued.close(clear=true)
      defer queued_input.close(clear=true)
      // The driver drains its active request before taking this queued request.
      assert_true(queued_input.try_put(Finish))
      let started : @async.Queue[Unit] = Queue(kind=Unbounded)
      let pending_waiter = group.spawn(no_wait=true, allow_failure=true, () => {
        @async.protect_from_cancel(() => {
          started.put(())
          assert_true(
            expect_error_async(() => pending.get()) is ClientError::Closed(_),
          )
        })
      })
      let queued_waiter = group.spawn(() => {
        started.put(())
        assert_true(
          expect_error_async(() => queued.get()) is ClientError::Closed(_),
        )
      })
      let producer = group.spawn(() => {
        started.put(())
        assert_true(
          expect_error_async(() => queued_input.put(Finish))
          is ClientError::Closed(_),
        )
      })
      for _ in 0..<3 {
        started.get()
      }
      driver.cancel()
      let error = expect_error_async(() => {
        @async.with_timeout(1000, () => driver.wait())
      })
      assert_true(error is @async.TaskCancelled)
      pending_waiter.wait()
      queued_waiter.wait()
      producer.wait()
      assert_true(
        @test.expect_error(() => input.try_put(Finish))
        is ClientError::Closed(_),
      )
      assert_true(client.is_closed())
      assert_true(client.next_message() is None)
      assert_true(backend.read_some() is None)
    })
  })
}

///|
async test "connection write failures retain requests and preserve their error" {
  for kind in [Messages, CopyIn, Terminate] {
    @async.with_task_group(group => {
      let (client, connection, backend) = connection_test_pair(group)
      defer backend.close()
      connection.stream.close()
      let responses : @async.Queue[@backend.Message] = Queue(kind=Blocking(8))
      let input : @async.Queue[CopyInAction] = Queue(kind=Blocking(1))
      let request : Request = {
        kind,
        bytes: sync_bytes(),
        responses,
        copy_input: Some(input),
        copy_error: Some(@ref.new(None)),
      }
      assert_true(client.shared.requests.try_put(request))
      let queued = client.send_request(Messages, sync_bytes())
      @async.with_timeout(1000, () => {
        let driver = group.spawn(() => connection.run(group))
        driver.wait()
        let error = expect_error_async(() => responses.get())
        // The driver must retain the I/O failure through both cleanup calls.
        assert_false(error is ClientError::Closed(_))
        assert_eq(
          expect_error_async(() => queued.get()).to_string(),
          error.to_string(),
        )
        assert_eq(
          expect_error_async(() => input.get()).to_string(),
          error.to_string(),
        )
        assert_eq(
          @test.expect_error(() => client.shared.requests.try_get()).to_string(),
          error.to_string(),
        )
        assert_true(client.is_closed())
        assert_true(client.next_message() is None)
      })
    })
  }
}

///|
async test "connection Terminate closes its response queue and socket" {
  @async.with_task_group(group => {
    let (client, connection, backend) = connection_test_pair(group)
    defer backend.close()
    defer connection.stream.close()
    let responses = client.send_request(Terminate, terminate_bytes())
    @async.with_timeout(1000, () => {
      let driver = group.spawn(() => connection.run(group))
      driver.wait()
      assert_true(client.is_closed())
      assert_true(
        expect_error_async(() => responses.get()) is @aqueue.QueueAlreadyClosed,
      )
      assert_eq(backend.read_exactly(5), terminate_bytes())
      assert_true(backend.read_some() is None)
    })
  })
}
