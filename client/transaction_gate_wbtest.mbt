///|
async test "failed top-level commit finishes transaction and releases client" {
  @async.with_task_group(group => {
    let shared = copy_test_shared(@ref.new(None))
    let client : Client = { shared, }
    let root_permit = shared.operation_gate.acquire()
    let transaction : Transaction = {
      client,
      context: client.operation_context(),
      scope_gate: OperationGate::new(),
      root_permit: Some(root_permit),
      parent_permit: None,
      savepoint: None,
      finished: @ref.new(false),
    }
    group.spawn_bg(() => {
      let request = shared.requests.get()
      request.responses.put(
        copy_test_error_response_message("deferred constraint failed"),
      )
      request.responses.put(copy_test_ready_for_query_message())
    })

    let result = expect_error_async(() => transaction.commit())
    guard result is ClientError::Database(err) else {
      fail("expected deferred commit database error")
    }
    assert_eq(err.message, "deferred constraint failed")
    assert_true(transaction.finished.val)
    assert_true(shared.operation_gate.mutex.try_acquire())
    shared.operation_gate.mutex.release()
  })
}

///|
async test "failed nested completion returns its permit to parent transaction" {
  @async.with_task_group(group => {
    let shared = copy_test_shared(@ref.new(None))
    let client : Client = { shared, }
    let parent_gate = OperationGate::new()
    let parent_permit = parent_gate.acquire()
    let nested : Transaction = {
      client,
      context: client.operation_context(),
      scope_gate: OperationGate::new(),
      root_permit: None,
      parent_permit: Some(parent_permit),
      savepoint: Some("nested"),
      finished: @ref.new(false),
    }
    group.spawn_bg(() => {
      let request = shared.requests.get()
      request.responses.put(
        copy_test_error_response_message("savepoint release failed"),
      )
      request.responses.put(copy_test_ready_for_query_message())
    })

    let result = expect_error_async(() => nested.commit())
    guard result is ClientError::Database(err) else {
      fail("expected nested completion database error")
    }
    assert_eq(err.message, "savepoint release failed")
    assert_true(nested.finished.val)
    assert_true(parent_gate.mutex.try_acquire())
    parent_gate.mutex.release()
  })
}
