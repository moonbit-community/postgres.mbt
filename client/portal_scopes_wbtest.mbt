///|
async test "portal scope waits for started calls and rejects expired operations" {
  with_cancellation_test_client((group, client, next_request) => {
    let begin = group.spawn(() => client.transaction())
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    let transaction = begin.wait()
    let statement : Statement = {
      client,
      name: b"existing",
      params: [],
      columns: [],
      closed: @ref.new(false),
    }
    let delivered : @async.Queue[Portal] = Queue(kind=Unbounded)
    let leave_scope : @async.Queue[Unit] = Queue(kind=Unbounded)
    defer leave_scope.close()
    let task = group.spawn(() => {
      transaction.with_portal(statement, portal => {
        delivered.put(portal)
        leave_scope.get()
        42
      })
    })
    let bind = next_request()
    assert_eq(bind.bytes, bind_portal_bytes(b"p1", b"existing", [], []))
    bind.responses.put(parse_backend_message(b"2\x00\x00\x00\x04"))
    bind.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let portal = delivered.get()
    let fetch = group.spawn(() => {
      portal.with_stream(1, stream => stream.finish())
    })
    let execute = next_request()
    assert_eq(execute.bytes, execute_portal_bytes(b"p1", 1))
    leave_scope.put(())
    // Wait until the callback has returned and its finalizer is waiting for
    // the already started fetch. New operations must fail during this wait.
    while portal.active.val {
      @async.pause()
    }
    assert_false(portal.closed.val)
    assert_true(task.try_wait() is None)
    assert_true(client.shared.requests.try_get() is None)
    assert_true(
      expect_error_async(() => portal.execute())
      is ClientError::Closed("portal scope expired"),
    )
    assert_true(
      expect_error_async(() => portal.with_stream(1, _ => ()))
      is ClientError::Closed("portal scope expired"),
    )
    assert_true(
      expect_error_async(() => transaction.commit())
      is ClientError::Closed("transaction has active resource scope"),
    )
    assert_true(
      expect_error_async(() => transaction.rollback())
      is ClientError::Closed("transaction has active resource scope"),
    )
    execute.responses.put(copy_test_data_row_message(Some(b"value")))
    execute.responses.put(parse_backend_message(b"s\x00\x00\x00\x04"))
    execute.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let summary = fetch.wait()
    assert_eq(summary.row_count, 1)
    assert_true(summary.suspended)
    let close = next_request()
    assert_eq(close.bytes, close_bytes(b'P', b"p1"))
    assert_true(task.try_wait() is None)
    close.responses.put(copy_test_close_complete_message())
    close.responses.put(copy_test_ready_for_query_message(status=b'T'))
    assert_eq(task.wait(), 42)
    assert_true(portal.closed.val)
    assert_false(statement.closed.val)
    assert_eq(transaction.scoped_resources.val, 0)
    let rollback = group.spawn(() => transaction.rollback())
    next_request().responses.put(copy_test_ready_for_query_message())
    rollback.wait()
  })
}

///|
async test "portal scope preserves cancellation during bind fetch callback and Close" {
  // 0: Bind before delivery; 1: cancellable fetch callback; 2: pending cancel
  // on return from a protected callback; 3: final protected portal Close.
  for phase in 0..<4 {
    with_cancellation_test_client((group, client, next_request) => {
      let begin = group.spawn(() => client.transaction())
      next_request().responses.put(
        copy_test_ready_for_query_message(status=b'T'),
      )
      let transaction = begin.wait()
      let statement : Statement = {
        client,
        name: b"existing",
        params: [],
        columns: [],
        closed: @ref.new(false),
      }
      let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
      let waiting : @async.Queue[Unit] = Queue(kind=Unbounded)
      defer waiting.close()
      let delivered = @ref.new(false)
      let task = group.spawn(allow_failure=true, () => {
        transaction.with_portal(statement, portal => {
          delivered.val = true
          portal.with_stream(0, _ => {
            entered.put(())
            if phase == 1 {
              waiting.get()
            } else if phase == 2 {
              @async.protect_from_cancel(() => waiting.get())
            }
          })
        })
      })
      let bind = next_request()
      if phase == 0 {
        task.cancel()
      }
      bind.responses.put(parse_backend_message(b"2\x00\x00\x00\x04"))
      bind.responses.put(copy_test_ready_for_query_message(status=b'T'))
      if phase != 0 {
        let execute = next_request()
        assert_eq(execute.bytes, execute_portal_bytes(b"p1", 0))
        entered.get()
        if phase != 3 {
          task.cancel()
        }
        if phase == 2 {
          waiting.put(())
        }
        // More than the response queue capacity proves that cancelled reads
        // release backpressure before the scope submits Close.
        for _ in 0..<32 {
          execute.responses.put(copy_test_data_row_message(Some(b"discard")))
        }
        execute.responses.put(copy_test_command_complete_message("SELECT 32"))
        assert_true(task.try_wait() is None)
        assert_true(client.shared.requests.try_get() is None)
        execute.responses.put(copy_test_ready_for_query_message(status=b'T'))
      }
      let close = next_request()
      assert_eq(close.bytes, close_bytes(b'P', b"p1"))
      if phase == 3 {
        task.cancel()
      }
      assert_eq(delivered.val, phase != 0)
      assert_true(task.try_wait() is None)
      assert_eq(transaction.scoped_resources.val, 1)
      close.responses.put(copy_test_close_complete_message())
      close.responses.put(copy_test_ready_for_query_message(status=b'T'))
      assert_true(
        expect_error_async(() => task.wait())
        is @async.WaitedTaskAlreadyCancelled,
      )
      assert_eq(transaction.scoped_resources.val, 0)
      assert_false(statement.closed.val)
      let rollback = group.spawn(() => transaction.rollback())
      let request = next_request()
      assert_eq(request.bytes, simple_query_bytes("ROLLBACK"))
      request.responses.put(copy_test_ready_for_query_message())
      rollback.wait()
    })
  }
}

///|
async test "portal bind closes its server resource when column type resolution fails" {
  for close_fails in [false, true] {
    with_cancellation_test_client((group, client, next_request) => {
      let begin = group.spawn(() => client.transaction())
      next_request().responses.put(
        copy_test_ready_for_query_message(status=b'T'),
      )
      let transaction = begin.wait()
      let statement : Statement = {
        client,
        name: b"existing",
        params: [],
        columns: [
          {
            name: "value",
            table_oid: 0U,
            column_id: 0,
            type_: Type::unknown(99999U, name="custom_type"),
            type_size: -1,
            type_modifier: -1,
            format: Binary,
          },
        ],
        closed: @ref.new(false),
      }
      let delivered = @ref.new(false)
      let task = group.spawn(allow_failure=true, () => {
        transaction.with_portal(statement, _ => delivered.val = true)
      })
      let bind = next_request()
      assert_eq(bind.bytes, bind_portal_bytes(b"p1", b"existing", [], []))
      bind.responses.put(parse_backend_message(b"2\x00\x00\x00\x04"))
      bind.responses.put(copy_test_ready_for_query_message(status=b'T'))
      let prepare = next_request()
      assert_eq(
        prepare.bytes,
        prepare_bytes(b"q2", typeinfo_query, [Type::oid_type()]),
      )
      scoped_test_prepare(prepare, param_types=[Type::oid_type()])
      let catalog = next_request()
      // A NULL type name fails decoding after the catalog stream is drained.
      catalog.responses.put(copy_test_data_row_message(None))
      catalog.responses.put(copy_test_command_complete_message("SELECT 1"))
      catalog.responses.put(copy_test_ready_for_query_message(status=b'T'))
      let close_statement = next_request()
      assert_eq(close_statement.bytes, close_bytes(b'S', b"q2"))
      close_statement.responses.put(copy_test_close_complete_message())
      close_statement.responses.put(
        copy_test_ready_for_query_message(status=b'T'),
      )
      let close = next_request()
      assert_eq(close.bytes, close_bytes(b'P', b"p1"))
      assert_false(delivered.val)
      assert_true(task.try_wait() is None)
      assert_eq(transaction.scoped_resources.val, 1)
      assert_false(transaction.scope_gate.mutex.try_acquire())
      if close_fails {
        close.responses.put(copy_test_error_response_message("close failed"))
      } else {
        close.responses.put(copy_test_close_complete_message())
      }
      close.responses.put(copy_test_ready_for_query_message(status=b'T'))
      assert_true(
        expect_error_async(() => task.wait()) is ClientError::Decode(_),
      )
      assert_false(delivered.val)
      assert_false(statement.closed.val)
      assert_eq(transaction.scoped_resources.val, 0)
      assert_true(client.shared.requests.try_get() is None)
      let rollback = group.spawn(() => transaction.rollback())
      next_request().responses.put(copy_test_ready_for_query_message())
      rollback.wait()
    })
  }
}
