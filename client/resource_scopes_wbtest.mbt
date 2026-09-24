///|
async test "client async messages discard oldest without blocking producer" {
  let config = make_shared().config
  assert_true(
    expect_error_async(() => {
      ignore(Client::create_with_async_message_capacity(config, 0))
    })
    is ClientError::InvalidConfig(_),
  )
  let (client, _) = Client::create_with_async_message_capacity(config, 2)
  client.shared.ready.complete(None)
  for i in 0..<1000 {
    client.shared.push_async_message(ParameterStatus("n", i.to_string()))
  }
  assert_eq(client.dropped_async_messages(), 998L)
  assert_true(client.next_message() is Some(ParameterStatus("n", "998")))
  assert_true(client.next_message() is Some(ParameterStatus("n", "999")))
  client.shared.async_messages.close()
  assert_true(client.next_message() is None)
}

///|
async test "client prepared scope drains stream then closes statement and expires" {
  with_cancellation_test_client((group, client, next_request) => {
    let saved : @ref.Ref[ScopedStatement?] = @ref.new(None)
    let task = group.spawn(() => {
      client.with_prepared("select value", scoped => {
        saved.val = Some(scoped)
        scoped.with_stream(stream => {
          let value : String = stream.next().unwrap().get(0)
          value
        })
      })
    })
    let prepare = next_request()
    assert_eq(prepare.bytes, prepare_bytes(b"s1", "select value", []))
    scoped_test_prepare(prepare)
    let execute = next_request()
    assert_eq(execute.bytes, execute_statement_bytes(b"s1", [], []))
    execute.responses.put(copy_test_data_row_message(Some(b"first")))
    for _ in 0..<32 {
      execute.responses.put(copy_test_data_row_message(Some(b"later")))
    }
    assert_true(task.try_wait() is None)
    execute.responses.put(copy_test_command_complete_message("SELECT 33"))
    execute.responses.put(copy_test_ready_for_query_message())
    let close = next_request()
    assert_eq(close.bytes, close_bytes(b'S', b"s1"))
    assert_true(task.try_wait() is None)
    close.responses.put(copy_test_close_complete_message())
    close.responses.put(copy_test_ready_for_query_message())
    assert_eq(task.wait(), "first")
    assert_true(
      expect_error_async(() => saved.val.unwrap().execute())
      is ClientError::Closed("prepared statement scope expired"),
    )
  })
}

///|
async test "prepared scope keeps callback error and aborts on Close failure" {
  @async.with_task_group(group => {
    let shared = copy_test_shared(@ref.new(Some(group)))
    let client : Client = { shared, }
    let task : @async.Task[Unit] = group.spawn(allow_failure=true, () => {
      client.with_prepared("select value", _ => {
        raise ClientError::Encode("callback failed")
      })
    })
    scoped_test_prepare(shared.requests.get())
    let close = shared.requests.get()
    assert_eq(close.bytes, close_bytes(b'S', b"s1"))
    close.responses.put(copy_test_error_response_message("close failed"))
    close.responses.put(copy_test_ready_for_query_message())
    assert_true(
      expect_error_async(() => task.wait())
      is ClientError::Encode("callback failed"),
    )
    assert_true(client.is_closed())
  })
}

///|
async test "prepared scopes preserve cancellation and close before releasing ownership" {
  for in_transaction in [false, true] {
    with_cancellation_test_client((group, client, next_request) => {
      let transaction = if in_transaction {
        let begin = group.spawn(() => client.transaction())
        next_request().responses.put(
          copy_test_ready_for_query_message(status=b'T'),
        )
        Some(begin.wait())
      } else {
        None
      }
      let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
      let waiting : @async.Queue[Unit] = Queue(kind=Unbounded)
      defer waiting.close()
      let task = group.spawn(allow_failure=true, () => {
        match transaction {
          Some(tx) =>
            tx.with_prepared("select value", _ => {
              entered.put(())
              waiting.get()
            })
          None =>
            client.with_prepared("select value", _ => {
              entered.put(())
              waiting.get()
            })
        }
      })
      scoped_test_prepare(next_request())
      entered.get()
      task.cancel()
      let close = next_request()
      assert_eq(close.bytes, close_bytes(b'S', b"s1"))
      assert_true(task.try_wait() is None)
      close.responses.put(copy_test_close_complete_message())
      close.responses.put(
        copy_test_ready_for_query_message(
          status=if in_transaction { b'T' } else { b'I' },
        ),
      )
      assert_true(expect_error_async(() => task.wait()) is @async.TaskCancelled)
      if transaction is Some(tx) {
        let rollback = group.spawn(() => tx.rollback())
        next_request().responses.put(copy_test_ready_for_query_message())
        rollback.wait()
      }
    })
  }
}

///|
async test "transaction scopes close portal before statement and reject early commit" {
  with_cancellation_test_client((group, client, next_request) => {
    let begin = group.spawn(() => client.transaction())
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    let transaction = begin.wait()
    let saved : @ref.Ref[ScopedPortal?] = @ref.new(None)
    let task = group.spawn(() => {
      transaction.with_prepared("select value", statement => {
        assert_true(
          expect_error_async(() => transaction.commit())
          is ClientError::Closed("transaction has active resource scope"),
        )
        statement.with_portal(portal => {
          saved.val = Some(portal)
          portal.with_stream(1, _ => 7)
        })
      })
    })
    let prepare = next_request()
    assert_eq(prepare.bytes, prepare_bytes(b"s1", "select value", []))
    scoped_test_prepare(prepare)
    let bind = next_request()
    assert_eq(bind.bytes[0], b'B')
    bind.responses.put(parse_backend_message(b"2\x00\x00\x00\x04"))
    bind.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let execute = next_request()
    assert_eq(execute.bytes, execute_portal_bytes(b"p2", 1))
    execute.responses.put(copy_test_data_row_message(Some(b"value")))
    execute.responses.put(parse_backend_message(b"s\x00\x00\x00\x04"))
    execute.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let close_portal = next_request()
    assert_eq(close_portal.bytes, close_bytes(b'P', b"p2"))
    close_portal.responses.put(copy_test_close_complete_message())
    close_portal.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let close_statement = next_request()
    assert_eq(close_statement.bytes, close_bytes(b'S', b"s1"))
    close_statement.responses.put(copy_test_close_complete_message())
    close_statement.responses.put(
      copy_test_ready_for_query_message(status=b'T'),
    )
    assert_eq(task.wait(), 7)
    assert_true(
      expect_error_async(() => saved.val.unwrap().execute())
      is ClientError::Closed("portal scope expired"),
    )
    let rollback = group.spawn(() => transaction.rollback())
    next_request().responses.put(copy_test_ready_for_query_message())
    rollback.wait()
  })
}

///|
async test "child transaction commits inside parent statement scope" {
  with_cancellation_test_client((group, client, next_request) => {
    let begin = group.spawn(() => client.transaction())
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    let transaction = begin.wait()
    let task = group.spawn(() => {
      transaction.with_prepared("select value", _ => {
        transaction.with_transaction(_child => 42)
      })
    })
    scoped_test_prepare(next_request())
    let savepoint = next_request()
    assert_eq(savepoint.bytes, simple_query_bytes("SAVEPOINT \"moon_tx_2\""))
    savepoint.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let release = next_request()
    assert_eq(
      release.bytes,
      simple_query_bytes("RELEASE SAVEPOINT \"moon_tx_2\""),
    )
    release.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let close = next_request()
    assert_eq(close.bytes, close_bytes(b'S', b"s1"))
    close.responses.put(copy_test_close_complete_message())
    close.responses.put(copy_test_ready_for_query_message(status=b'T'))
    assert_eq(task.wait(), 42)
    let rollback = group.spawn(() => transaction.rollback())
    next_request().responses.put(copy_test_ready_for_query_message())
    rollback.wait()
  })
}

///|
async test "bind cancellation closes an undelivered portal" {
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
    let task = group.spawn(allow_failure=true, () => transaction.bind(statement))
    let bind = next_request()
    task.cancel()
    bind.responses.put(parse_backend_message(b"2\x00\x00\x00\x04"))
    bind.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let close = next_request()
    assert_eq(close.bytes, close_bytes(b'P', b"p1"))
    assert_true(task.try_wait() is None)
    close.responses.put(copy_test_close_complete_message())
    close.responses.put(copy_test_ready_for_query_message(status=b'T'))
    assert_true(expect_error_async(() => task.wait()) is @async.TaskCancelled)
    let rollback = group.spawn(() => transaction.rollback())
    next_request().responses.put(copy_test_ready_for_query_message())
    rollback.wait()
  })
}

///|
async test "portal scope preserves cancellation and closes before transaction rollback" {
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
    let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
    let waiting : @async.Queue[Unit] = Queue(kind=Unbounded)
    defer waiting.close()
    let task = group.spawn(allow_failure=true, () => {
      transaction.with_portal(statement, _ => {
        entered.put(())
        waiting.get()
      })
    })
    let bind = next_request()
    bind.responses.put(parse_backend_message(b"2\x00\x00\x00\x04"))
    bind.responses.put(copy_test_ready_for_query_message(status=b'T'))
    entered.get()
    task.cancel()
    let close = next_request()
    assert_eq(close.bytes, close_bytes(b'P', b"p1"))
    assert_true(task.try_wait() is None)
    close.responses.put(copy_test_close_complete_message())
    close.responses.put(copy_test_ready_for_query_message(status=b'T'))
    assert_true(expect_error_async(() => task.wait()) is @async.TaskCancelled)
    let rollback = group.spawn(() => transaction.rollback())
    next_request().responses.put(copy_test_ready_for_query_message())
    rollback.wait()
  })
}

///|
async test "portal Close failure aborts transaction connection" {
  @async.with_task_group(group => {
    let shared = copy_test_shared(@ref.new(Some(group)))
    let client : Client = { shared, }
    let begin = group.spawn(() => client.transaction())
    shared.requests.get().responses.put(
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
    let task = group.spawn(allow_failure=true, () => {
      transaction.with_portal(statement, _ => 42)
    })
    let bind = shared.requests.get()
    bind.responses.put(parse_backend_message(b"2\x00\x00\x00\x04"))
    bind.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let close = shared.requests.get()
    assert_eq(close.bytes, close_bytes(b'P', b"p1"))
    close.responses.put(copy_test_error_response_message("close failed"))
    close.responses.put(copy_test_ready_for_query_message(status=b'T'))
    assert_true(
      expect_error_async(() => task.wait()) is ClientError::Database(_),
    )
    assert_true(client.is_closed())
    assert_true(transaction.finished.val)
    assert_eq(shared.root_transaction_occupancy.val, 0)
  })
}

///|
async test "statement close rejects root transaction waiting for client permit" {
  @async.with_task_group(group => {
    let shared = copy_test_shared(@ref.new(Some(group)))
    let client : Client = { shared, }
    let owner = shared.operation_gate.acquire()
    let started : @async.Queue[Unit] = Queue(kind=Unbounded)
    let waiter = group.spawn(allow_failure=true, () => {
      started.put(())
      client.transaction()
    })
    started.get()
    @async.pause()
    let statement : Statement = {
      client,
      name: b"existing",
      params: [],
      columns: [],
      closed: @ref.new(false),
    }
    assert_eq(shared.root_transaction_occupancy.val, 1)
    assert_true(
      expect_error_async(() => statement.close())
      is ClientError::Closed(
        "transaction owns the connection; use Transaction::close_statement"
      ),
    )
    waiter.cancel()
    assert_true(expect_error_async(() => waiter.wait()) is @async.TaskCancelled)
    assert_eq(shared.root_transaction_occupancy.val, 0)
    owner.release()
  })
}
