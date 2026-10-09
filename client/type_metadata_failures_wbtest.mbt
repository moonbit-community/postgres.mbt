///|
async test "prepare query and typed query close undelivered statements on metadata cycles" {
  for mode in 0..<3 {
    with_cancellation_test_client((group, client, next_request) => {
      let task = group.spawn(allow_failure=true, () => {
        if mode == 0 {
          ignore(client.prepare("select custom"))
        } else if mode == 1 {
          ignore(client.query("select custom"))
        } else {
          ignore(client.query_typed("select custom", []))
        }
      })
      let prepare = next_request()
      let name = metadata_test_name(prepare)
      metadata_test_prepare(prepare, [Type::unknown(90000U)])
      metadata_test_shape(next_request, 90000U, elem=90000U)
      let close = next_request()
      assert_true(task.try_wait() is None)
      assert_false(client.shared.operation_gate.mutex.try_acquire())
      metadata_test_close(close, name)
      assert_true(
        expect_error_async(() => task.wait())
        is ClientError::UnsupportedRecursiveType(90000U),
      )
      assert_true(client.shared.types.get(90000U) is None)
      assert_true(client.shared.operation_gate.mutex.try_acquire())
      client.shared.operation_gate.mutex.release()
      assert_true(client.shared.requests.try_get() is None)
    })
  }
}

///|
async test "failed Close after metadata resolution aborts and preserves original error" {
  for lost_close in [false, true] {
    @async.with_task_group(group => {
      let shared = copy_test_shared(@ref.new(Some(group)))
      let client : Client = { shared, }
      @async.with_timeout(2000, () => {
        let task = group.spawn(allow_failure=true, () => {
          ignore(client.prepare("select custom"))
        })
        let prepare = shared.requests.get()
        let name = metadata_test_name(prepare)
        metadata_test_prepare(prepare, [Type::unknown(90000U)])
        metadata_test_shape(() => shared.requests.get(), 90000U, elem=90000U)
        let close = shared.requests.get()
        assert_eq(close.bytes, close_bytes(b'S', name[:]))
        if lost_close {
          close.responses.close(
            error=ClientError::Protocol("close lost"),
            clear=true,
          )
        } else {
          close.responses.put(copy_test_error_response_message("close denied"))
          close.responses.put(copy_test_ready_for_query_message())
        }
        assert_true(
          expect_error_async(() => task.wait())
          is ClientError::UnsupportedRecursiveType(90000U),
        )
        assert_true(shared.aborted.val)
        assert_true(shared.types.get(90000U) is None)
        assert_true(shared.operation_gate.mutex.try_acquire())
        shared.operation_gate.mutex.release()
      })
    })
  }
}

///|
async test "interrupted catalog preparation propagates and closes outer statement" {
  for protocol_error in [false, true] {
    with_cancellation_test_client((group, client, next_request) => {
      let task = group.spawn(allow_failure=true, () => {
        ignore(client.prepare("select custom"))
      })
      let prepare = next_request()
      let name = metadata_test_name(prepare)
      metadata_test_prepare(prepare, [Type::unknown(90000U)])
      let catalog_prepare = next_request()
      let error : Error = if protocol_error {
        ClientError::Protocol("catalog interrupted")
      } else {
        ClientError::Closed("catalog interrupted")
      }
      catalog_prepare.responses.close(error~, clear=true)
      metadata_test_close(next_request(), name)
      let result = expect_error_async(() => task.wait())
      if protocol_error {
        assert_true(result is ClientError::Protocol("catalog interrupted"))
      } else {
        assert_true(result is ClientError::Closed("catalog interrupted"))
      }
      assert_true(client.shared.types.get(90000U) is None)
    })
  }
}

///|
async test "cancelled catalog resolution removes active marks and can retry" {
  with_cancellation_test_client((group, client, next_request) => {
    let active : Map[UInt, Unit] = Map([])
    let task = group.spawn(allow_failure=true, () => {
      cached_type_recursive(client.operation_context(), 90000U, active)
    })
    let prepare = next_request()
    let name = metadata_test_name(prepare)
    metadata_test_prepare(
      prepare,
      [
        Type::text(),
        Type::text(),
        Type::oid_type(),
        Type::oid_type(),
        Type::oid_type(),
        Type::text(),
        Type::oid_type(),
      ],
      params=[26U],
    )
    let execute = next_request()
    assert_true(active.contains(90000U))
    task.cancel()
    assert_true(
      expect_error_async(() => task.wait()) is @async.WaitedTaskAlreadyCancelled,
    )
    assert_true(active.is_empty())
    assert_true(client.shared.types.get(90000U) is None)
    execute.responses.put(copy_test_ready_for_query_message())
    metadata_test_close(next_request(), name)
    let retry = group.spawn(() => {
      cached_type_recursive(client.operation_context(), 90000U, active)
    })
    metadata_test_shape(next_request, 90000U, elem=23U)
    guard retry.wait().kind is Array(element) else { fail("expected array") }
    assert_eq(element, Type::int4())
    assert_true(active.is_empty())
  })
}

///|
async test "cancelled public prepare during metadata resolution closes before releasing permit" {
  with_cancellation_test_client((group, client, next_request) => {
    let task = group.spawn(allow_failure=true, () => {
      client.prepare("select custom")
    })
    let prepare = next_request()
    let name = metadata_test_name(prepare)
    metadata_test_prepare(prepare, [Type::unknown(90000U)])
    let catalog_prepare = next_request()
    task.cancel()
    let catalog_name = metadata_test_name(catalog_prepare)
    metadata_test_prepare(catalog_prepare, [])
    next_request().responses.put(copy_test_ready_for_query_message())
    metadata_test_close(next_request(), catalog_name)
    let close = next_request()
    assert_eq(close.bytes, close_bytes(b'S', name[:]))
    assert_true(task.try_wait() is None)
    assert_false(client.shared.operation_gate.mutex.try_acquire())
    metadata_test_close(close, name)
    assert_true(
      expect_error_async(() => task.wait()) is @async.WaitedTaskAlreadyCancelled,
    )
  })
}

///|
async test "recursive type error leaves transaction usable" {
  with_cancellation_test_client((group, client, next_request) => {
    let begin = group.spawn(() => client.transaction())
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    let tx = begin.wait()
    let task = group.spawn(allow_failure=true, () => {
      ignore(tx.prepare("select custom"))
    })
    let prepare = next_request()
    let name = metadata_test_name(prepare)
    metadata_test_prepare(prepare, [], params=[90000U])
    metadata_test_shape(next_request, 90000U, elem=90000U)
    metadata_test_close(next_request(), name)
    assert_true(
      expect_error_async(() => task.wait())
      is ClientError::UnsupportedRecursiveType(90000U),
    )
    assert_false(client.is_closed())
    assert_false(tx.finished.val)
    assert_true(tx.scope_gate.mutex.try_acquire())
    tx.scope_gate.mutex.release()
    let reuse = group.spawn(() => tx.batch_execute("select 1"))
    let query = next_request()
    assert_eq(query.bytes, simple_query_bytes("select 1"))
    query.responses.put(copy_test_ready_for_query_message(status=b'T'))
    reuse.wait()
    let commit = group.spawn(() => tx.commit())
    next_request().responses.put(copy_test_ready_for_query_message())
    commit.wait()
  })
}
