///|
async fn with_operation_test_state(
  f : async (@async.TaskGroup[Unit], OperationScopeState) -> Unit,
) -> Unit {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    group.spawn_bg(no_wait=true, () => {
      let (socket, _) = server.accept()
      serve_recycle_test_connection(socket)
    })
    let client = start_test_client(
      @client.Config::Config(
        "127.0.0.1",
        port=server.addr.port(),
        user="moon",
        ssl_mode=Disable,
        application_name="operation-cancel-test",
      ),
      group,
    )
    defer client.abort()
    let connection = client_api_test_connection(group)
    connection.client.val = Some(client)
    let (operation, _) = make_pooled_operation(connection)
    @async.with_timeout(2000, () => f(group, operation.state))
    client.close()
  })
}

///|
async test "queued operation requests wait for late cancel completion in FIFO order" {
  with_operation_test_state((group, state) => {
    ignore(state.begin_request())
    let queued : @async.Queue[Int] = Queue(kind=Unbounded)
    let granted : @async.Queue[Int] = Queue(kind=Unbounded)
    let release_request : @async.Queue[Unit] = Queue(kind=Unbounded)
    defer release_request.close()
    let waiters : Array[@async.Task[Unit]] = []
    for id in 1..<=2 {
      waiters.push(
        group.spawn(() => {
          queued.put(id)
          ignore(state.begin_request())
          defer state.finish_request()
          granted.put(id)
          release_request.get()
        }),
      )
      assert_eq(queued.get(), id)
    }
    // Model cancel() entering its protected send after both successors queued.
    state.cancel_in_flight.val = 1
    state.finish_request()
    // Let the mutex handoff run; the first waiter must now wait inside the gate.
    @async.pause()
    assert_false(state.request_in_flight.val)
    assert_eq(state.next_request_id.val, 1)
    assert_true(granted.try_get() is None)
    assert_false(state.gate.try_acquire())
    state.cancel_in_flight.val = 0
    for id in 1..<=2 {
      assert_eq(granted.get(), id)
      assert_eq(state.active_request_id.val, id + 1)
      release_request.put(())
      waiters[id - 1].wait()
    }
  })
}

///|
async test "late cancel wait releases the operation gate on cancellation or expiry" {
  for mode in 0..<3 {
    with_operation_test_state((group, state) => {
      ignore(state.begin_request())
      let queued : @async.Queue[Unit] = Queue(kind=Unbounded)
      let waiter : @async.Task[Unit] = group.spawn(allow_failure=true, () => {
        queued.put(())
        ignore(state.begin_request())
        defer state.finish_request()
        fail("request overtook its predecessor's cancel send")
      })
      queued.get()
      state.cancel_in_flight.val = 1
      state.finish_request()
      @async.pause()
      assert_false(state.request_in_flight.val)
      assert_eq(state.next_request_id.val, 1)
      match mode {
        0 => waiter.cancel()
        1 => state.closing.val = true
        _ => {
          state.connection.client.val = None
          state.cancel_in_flight.val = 0
        }
      }
      let error = expect_pgpool_error_async(() => waiter.wait())
      if mode == 0 {
        assert_true(error is @async.TaskCancelled)
      } else {
        assert_true(error is PoolError::ScopeExpired)
      }
      assert_true(state.gate.try_acquire())
      state.gate.release()
      assert_false(state.request_in_flight.val)
      assert_eq(state.active_request_id.val, 0)
      if mode == 0 {
        state.cancel_in_flight.val = 0
        ignore(state.begin_request())
        state.finish_request()
      }
    })
  }
}

///|
async test "pooled operation boundary propagates cancellation after protected work" {
  with_operation_test_state((group, state) => {
    let operation : Operation = { state, }
    let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
    let release_work : @async.Queue[Unit] = Queue(kind=Unbounded)
    defer release_work.close()
    let returned = @ref.new(false)
    let task = group.spawn(allow_failure=true, () => {
      operation.run_request(_ => {
        entered.put(())
        release_work.get()
      })
      returned.val = true
    })
    entered.get()
    task.cancel()
    release_work.put(())
    assert_true(
      expect_pgpool_error_async(() => task.wait()) is @async.TaskCancelled,
    )
    assert_false(returned.val)
    assert_false(state.request_in_flight.val)
    ignore(state.begin_request())
    state.finish_request()
  })
}

///|
async test "session boundaries recheck cancellation outside their outer protection" {
  for cancellable in [false, true] {
    with_operation_test_state((group, state) => {
      let pool = client_api_test_pool(group)
      defer pool.close()
      let session = make_session(pool.shared, state.connection)
      let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
      let release_work : @async.Queue[Unit] = Queue(kind=Unbounded)
      defer release_work.close()
      async fn work() {
        entered.put(())
        release_work.get()
      }
      let returned = @ref.new(false)
      let task = group.spawn(allow_failure=true, () => {
        if cancellable {
          session.run_cancellable((_, _) => work())
        } else {
          session.run_operation(_ => work())
        }
        returned.val = true
      })
      entered.get()
      task.cancel()
      release_work.put(())
      assert_true(
        expect_pgpool_error_async(() => task.wait()) is @async.TaskCancelled,
      )
      assert_false(returned.val)
      assert_eq(session.state.active_ops.val, 0)
      session.check_connection()
    })
  }
}
