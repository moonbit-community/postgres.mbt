///|
/// Act as the backend with explicit request/response barriers. On failure,
/// unblock protected cleanup before the task group joins its children.
async fn with_cancellation_test_client(
  f : async (@async.TaskGroup[Unit], Client, async () -> Request) -> Unit,
) -> Unit {
  @async.with_task_group(group => {
    let shared = copy_test_shared(@ref.new(Some(group)))
    let client : Client = { shared, }
    let requests : Array[Request] = []
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
    async fn next_request() -> Request {
      let request = shared.requests.get()
      requests.push(request)
      request
    }
    @async.with_timeout(2000, () => {
      f(group, client, next_request)
      let ping = group.spawn(() => client.check_connection())
      let request = next_request()
      assert_eq(request.bytes, sync_bytes())
      request.responses.put(copy_test_ready_for_query_message())
      ping.wait()
    })
  })
}

///|
async test "transaction cancellation during SQL rolls back before releasing ownership" {
  // The protected callback also checks the auto-commit boundary itself.
  for protect_callback in [false, true] {
    with_cancellation_test_client((group, client, next_request) => {
      let task = group.spawn(allow_failure=true, () => {
        client.with_transaction(tx => {
          if protect_callback {
            @async.protect_from_cancel(() => {
              tx.batch_execute("insert into t values (1)")
            })
          } else {
            tx.batch_execute("insert into t values (1)")
          }
        })
      })
      let begin = next_request()
      assert_eq(begin.bytes, simple_query_bytes("BEGIN"))
      begin.responses.put(copy_test_ready_for_query_message(status=b'T'))
      let insert = next_request()
      assert_eq(insert.bytes, simple_query_bytes("insert into t values (1)"))
      task.cancel()
      insert.responses.put(copy_test_ready_for_query_message(status=b'T'))
      let rollback = next_request()
      assert_eq(rollback.bytes, simple_query_bytes("ROLLBACK"))
      assert_false(client.shared.operation_gate.mutex.try_acquire())
      rollback.responses.put(copy_test_ready_for_query_message())
      assert_true(expect_error_async(() => task.wait()) is @async.TaskCancelled)
    })
  }
}

///|
async test "cancelled BEGIN rolls back before handing out a transaction" {
  with_cancellation_test_client((group, client, next_request) => {
    let delivered = @ref.new(false)
    let task = group.spawn(allow_failure=true, () => {
      let tx = client.transaction()
      delivered.val = true
      tx.commit()
    })
    let begin = next_request()
    assert_eq(begin.bytes, simple_query_bytes("BEGIN"))
    task.cancel()
    begin.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let rollback = next_request()
    assert_eq(rollback.bytes, simple_query_bytes("ROLLBACK"))
    assert_false(delivered.val)
    assert_false(client.shared.operation_gate.mutex.try_acquire())
    rollback.responses.put(copy_test_ready_for_query_message())
    assert_true(expect_error_async(() => task.wait()) is @async.TaskCancelled)
  })
}

///|
async test "cancelled SAVEPOINT restores the parent scope before releasing ownership" {
  with_cancellation_test_client((group, client, next_request) => {
    let begin_task = group.spawn(() => client.transaction())
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    let outer = begin_task.wait()
    let delivered = @ref.new(false)
    let task = group.spawn(allow_failure=true, () => {
      let nested = outer.savepoint("cancelled")
      delivered.val = true
      nested.commit()
    })
    let savepoint = next_request()
    assert_eq(savepoint.bytes, simple_query_bytes("SAVEPOINT cancelled"))
    task.cancel()
    savepoint.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let rollback = next_request()
    assert_eq(
      rollback.bytes,
      simple_query_bytes(
        "ROLLBACK TO SAVEPOINT cancelled; RELEASE SAVEPOINT cancelled",
      ),
    )
    assert_false(delivered.val)
    assert_false(outer.scope_gate.mutex.try_acquire())
    rollback.responses.put(copy_test_ready_for_query_message(status=b'T'))
    assert_true(expect_error_async(() => task.wait()) is @async.TaskCancelled)
    let complete = group.spawn(() => outer.commit())
    let commit = next_request()
    assert_eq(commit.bytes, simple_query_bytes("COMMIT"))
    commit.responses.put(copy_test_ready_for_query_message())
    complete.wait()
  })
}

///|
async test "cancellation after COMMIT submission still completes the transaction" {
  with_cancellation_test_client((group, client, next_request) => {
    let task = group.spawn(allow_failure=true, () => {
      client.with_transaction(_ => ())
    })
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    let commit = next_request()
    assert_eq(commit.bytes, simple_query_bytes("COMMIT"))
    task.cancel()
    commit.responses.put(copy_test_ready_for_query_message())
    assert_true(expect_error_async(() => task.wait()) is @async.TaskCancelled)
    assert_true(client.shared.requests.try_get() is None)
  })
}

///|
async test "query creation cancellation transfers the stream and permit to drain" {
  // Cover both client preparation paths and the transaction-owned stream gate.
  for mode in 0..<3 {
    with_cancellation_test_client((group, client, next_request) => {
      let transaction = if mode == 2 {
        let task = group.spawn(() => client.transaction())
        next_request().responses.put(
          copy_test_ready_for_query_message(status=b'T'),
        )
        Some(task.wait())
      } else {
        None
      }
      let delivered = @ref.new(false)
      let task = group.spawn(allow_failure=true, () => {
        let stream = match transaction {
          Some(tx) => tx.query("select 1")
          None =>
            if mode == 0 {
              client.query("select 1")
            } else {
              client.query_typed("select 1", [])
            }
        }
        delivered.val = true
        ignore(stream.finish())
      })
      let prepare = next_request()
      task.cancel()
      prepare.responses.put(parse_backend_message(b"1\x00\x00\x00\x04"))
      prepare.responses.put(parse_backend_message(b"n\x00\x00\x00\x04"))
      prepare.responses.put(copy_test_ready_for_query_message())
      let execute = next_request()
      assert_true(expect_error_async(() => task.wait()) is @async.TaskCancelled)
      assert_false(delivered.val)
      // More than the response queue capacity proves a consumer owns cleanup.
      for _ in 0..<32 {
        execute.responses.put(copy_test_data_row_message(Some(b"row")))
      }
      execute.responses.put(copy_test_ready_for_query_message())
      let close = next_request()
      assert_eq(close.bytes[0], b'C')
      close.responses.put(copy_test_close_complete_message())
      close.responses.put(copy_test_ready_for_query_message())
      if transaction is Some(tx) {
        let complete = group.spawn(() => tx.rollback())
        let rollback = next_request()
        assert_eq(rollback.bytes, simple_query_bytes("ROLLBACK"))
        rollback.responses.put(copy_test_ready_for_query_message())
        complete.wait()
      }
    })
  }
}

///|
async test "COPY OUT creation cancellation drains and releases its permit" {
  with_cancellation_test_client((group, client, next_request) => {
    let delivered = @ref.new(false)
    let task = group.spawn(allow_failure=true, () => {
      let stream = client.copy_out("COPY t TO STDOUT")
      delivered.val = true
      stream.finish()
    })
    let request = next_request()
    task.cancel()
    request.responses.put(copy_test_copy_out_response_message([0]))
    assert_true(expect_error_async(() => task.wait()) is @async.TaskCancelled)
    assert_false(delivered.val)
    for _ in 0..<32 {
      request.responses.put(copy_test_copy_data_message(b"row\n"))
    }
    request.responses.put(copy_test_copy_done_message())
    request.responses.put(copy_test_ready_for_query_message())
  })
}

///|
async test "pending cancellation prevents new client and transaction stream requests" {
  for transaction_scope in [false, true] {
    with_cancellation_test_client((group, client, next_request) => {
      let transaction = if transaction_scope {
        let task = group.spawn(() => client.transaction())
        next_request().responses.put(
          copy_test_ready_for_query_message(status=b'T'),
        )
        Some(task.wait())
      } else {
        None
      }
      let statement : Statement = {
        client,
        name: b"existing",
        params: [],
        columns: [],
        closed: @ref.new(false),
      }
      let portal : Portal = {
        name: b"existing",
        columns: [],
        closed: @ref.new(false),
      }
      for mode in 0..<(if transaction_scope { 7 } else { 6 }) {
        let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
        let release_start : @async.Queue[Unit] = Queue(kind=Unbounded)
        defer release_start.close()
        let task = group.spawn(allow_failure=true, () => {
          @async.protect_from_cancel(() => {
            entered.put(())
            release_start.get()
          })
          match transaction {
            Some(tx) =>
              match mode {
                0 => ignore(tx.query("select 1"))
                1 => tx.batch_execute("select 1")
                2 => ignore(tx.savepoint("cancelled"))
                3 => ignore(tx.query_statement(statement))
                4 => ignore(tx.query_portal(portal, 1))
                5 => tx.commit()
                _ => tx.rollback()
              }
            None =>
              match mode {
                0 => ignore(client.query("select 1"))
                1 => ignore(client.simple_query("select 1"))
                2 => ignore(client.copy_out("COPY t TO STDOUT"))
                3 => ignore(client.copy_in("COPY t FROM STDIN"))
                4 => ignore(client.query_typed("select 1", []))
                _ => ignore(client.query_statement(statement))
              }
          }
        })
        entered.get()
        task.cancel()
        release_start.put(())
        assert_true(
          expect_error_async(() => task.wait()) is @async.TaskCancelled,
        )
        assert_true(client.shared.requests.try_get() is None)
      }
      if transaction is Some(tx) {
        let complete = group.spawn(() => tx.rollback())
        next_request().responses.put(copy_test_ready_for_query_message())
        complete.wait()
      }
    })
  }
}
