///|
fn assert_no_execute_request(
  shared : Shared,
  requests : Array[Request],
) -> Unit raise {
  if shared.requests.try_get() is Some(request) {
    // Keep unexpected requests reachable so failing tests can unblock cleanup.
    requests.push(request)
    fail("unexpected request before execution cleanup completed")
  }
}

///|
/// Model the driver's bounded response queue, with the test acting as backend.
async fn check_execute_cancellation(raw~ : Bool) -> Unit {
  @async.with_task_group(group => {
    let shared = make_shared(group~)
    let client : Client = { shared, }
    let requests : Array[Request] = []
    // A failed assertion or timeout must also release protected cleanup.
    defer {
      for request in requests {
        request.responses.close(
          error=ClientError::Closed("test cleanup"),
          clear=true,
        )
      }
      while shared.requests.try_get() is Some(request) {
        request.responses.close(
          error=ClientError::Closed("test cleanup"),
          clear=true,
        )
      }
      shared.requests.close(error=ClientError::Closed("test cleanup"))
    }
    @async.with_timeout(2000, () => {
      let statement : Statement = {
        client,
        name: b"s1",
        params: [],
        columns: [],
        closed: @ref.new(false),
      }
      let task = group.spawn(allow_failure=true, () => {
        if raw {
          client.execute_raw(statement)
        } else {
          client.execute("select generate_series(1, 32)")
        }
      })
      if !raw {
        let prepare = shared.requests.get()
        requests.push(prepare)
        prepare.responses.put(parse_backend_message(b"1\x00\x00\x00\x04"))
        prepare.responses.put(parse_backend_message(b"n\x00\x00\x00\x04"))
        prepare.responses.put(copy_test_ready_for_query_message())
      }
      // Receiving the execution request proves the consumer reached finish().
      let execute = shared.requests.get()
      requests.push(execute)
      task.cancel()
      for _ in 0..<32 {
        execute.responses.put(copy_test_data_row_message(Some(b"row")))
        assert_no_execute_request(shared, requests)
      }
      execute.responses.put(copy_test_command_complete_message("SELECT 32"))
      assert_no_execute_request(shared, requests)
      execute.responses.put(copy_test_ready_for_query_message())
      if !raw {
        let close = shared.requests.get()
        requests.push(close)
        assert_eq(close.bytes, close_bytes(b'S', b"s1"))
        close.responses.put(copy_test_close_complete_message())
        close.responses.put(copy_test_ready_for_query_message())
      }
      let error = expect_error_async(() => {
        @async.with_timeout(1000, () => task.wait())
      })
      assert_true(error is @async.TaskCancelled)
      if raw {
        assert_false(statement.closed.val)
      }
      assert_true(execute.responses.try_get() is None)
      assert_no_execute_request(shared, requests)

      // Reuse the client, and also reuse the caller-owned statement for raw.
      let next = group.spawn(() => {
        if raw {
          assert_eq(client.execute_raw(statement), 1)
        } else {
          client.batch_execute("select 1")
        }
      })
      let request = shared.requests.get()
      requests.push(request)
      request.responses.put(copy_test_command_complete_message("SELECT 1"))
      request.responses.put(copy_test_ready_for_query_message())
      next.wait()
    })
  })
}

///|
async test "execute cancellation drains before closing its temporary statement" {
  check_execute_cancellation(raw=false)
}

///|
async test "execute_raw cancellation drains without closing the caller statement" {
  check_execute_cancellation(raw=true)
}

///|
async test "execute_raw cancellation survives a drain error" {
  @async.with_task_group(group => {
    let shared = make_shared()
    let client : Client = { shared, }
    let statement : Statement = {
      client,
      name: b"s1",
      params: [],
      columns: [],
      closed: @ref.new(false),
    }
    let task = group.spawn(allow_failure=true, () => {
      client.execute_raw(statement)
    })
    let request = @async.with_timeout(1000, () => shared.requests.get())
    defer request.responses.close(clear=true)
    task.cancel()
    request.responses.close(
      error=ClientError::Protocol("drain failed"),
      clear=true,
    )
    let error = expect_error_async(() => {
      @async.with_timeout(1000, () => task.wait())
    })
    assert_true(error is @async.TaskCancelled)
    assert_false(statement.closed.val)
  })
}

///|
async test "execute_raw preserves decoding failure when cleanup sees a database error" {
  @async.with_task_group(group => {
    let shared = make_shared()
    let client : Client = { shared, }
    let statement : Statement = {
      client,
      name: b"s1",
      params: [],
      columns: [],
      closed: @ref.new(false),
    }
    let task = group.spawn(allow_failure=true, () => {
      client.execute_raw(statement)
    })
    let request = @async.with_timeout(1000, () => shared.requests.get())
    defer request.responses.close(clear=true)
    // One column with an invalid field length (-2), decoded lazily by next().
    request.responses.put(
      parse_backend_message(b"D\x00\x00\x00\x0a\x00\x01\xff\xff\xff\xfe"),
    )
    request.responses.put(
      copy_test_error_response_message("later database error"),
    )
    request.responses.put(copy_test_ready_for_query_message())
    let error = expect_error_async(() => {
      @async.with_timeout(1000, () => task.wait())
    })
    assert_true(
      error is @proto.ProtocolError::InvalidInput("invalid value length"),
    )
    assert_true(request.responses.try_get() is None)
    assert_false(statement.closed.val)
  })
}
