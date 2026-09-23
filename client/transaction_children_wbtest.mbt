///|
async test "transaction drains an unfinished query before commit" {
  with_cancellation_test_client((group, client, next_request) => {
    let task = group.spawn(() => {
      client.with_transaction(tx => {
        let stream = tx.query("select value")
        stream.next().unwrap().get(0)
      })
    })
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    scoped_test_prepare(next_request())
    let execute = next_request()
    execute.responses.put(copy_test_data_row_message(Some(b"first")))
    for _ in 0..<20 {
      execute.responses.put(copy_test_data_row_message(Some(b"later")))
    }
    execute.responses.put(copy_test_command_complete_message("SELECT 21"))
    execute.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let close = next_request()
    assert_false(client.shared.operation_gate.mutex.try_acquire())
    scoped_test_close(close)
    let commit = next_request()
    assert_eq(commit.bytes, simple_query_bytes("COMMIT"))
    commit.responses.put(copy_test_ready_for_query_message())
    assert_eq(task.wait(), "first")
    assert_true(execute.responses.try_get() is None)
  })
}

///|
async test "transaction callback error survives unfinished query cleanup" {
  with_cancellation_test_client((group, client, next_request) => {
    let task = group.spawn(allow_failure=true, () => {
      let _ : Unit = client.with_transaction(tx => {
        let stream = tx.query("select value")
        ignore(stream.next())
        raise ClientError::Decode("callback failed")
      })
    })
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    scoped_test_prepare(next_request())
    let execute = next_request()
    execute.responses.put(copy_test_data_row_message(Some(b"first")))
    execute.responses.put(copy_test_error_response_message("drain failed"))
    execute.responses.put(copy_test_ready_for_query_message(status=b'T'))
    scoped_test_close(next_request())
    let rollback = next_request()
    assert_eq(rollback.bytes, simple_query_bytes("ROLLBACK"))
    rollback.responses.put(copy_test_ready_for_query_message())
    assert_true(
      expect_error_async(() => task.wait())
      is ClientError::Decode("callback failed"),
    )
  })
}

///|
async test "transaction cancellation drains unfinished query before rollback" {
  with_cancellation_test_client((group, client, next_request) => {
    let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
    let wait_forever : @async.Queue[Unit] = Queue(kind=Unbounded)
    let task = group.spawn(allow_failure=true, () => {
      client.with_transaction(tx => {
        let stream = tx.query("select value")
        ignore(stream.next())
        entered.put(())
        wait_forever.get()
      })
    })
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    scoped_test_prepare(next_request())
    let execute = next_request()
    execute.responses.put(copy_test_data_row_message(Some(b"first")))
    entered.get()
    task.cancel()
    execute.responses.put(copy_test_data_row_message(Some(b"discard")))
    execute.responses.put(copy_test_ready_for_query_message(status=b'T'))
    scoped_test_close(next_request())
    let rollback = next_request()
    assert_eq(rollback.bytes, simple_query_bytes("ROLLBACK"))
    rollback.responses.put(copy_test_ready_for_query_message())
    assert_true(expect_error_async(() => task.wait()) is @async.TaskCancelled)
  })
}

///|
async test "database error during transaction drain rolls back and propagates" {
  with_cancellation_test_client((group, client, next_request) => {
    let task = group.spawn(allow_failure=true, () => {
      client.with_transaction(tx => {
        let stream = tx.query("select value")
        ignore(stream.next())
      })
    })
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    scoped_test_prepare(next_request())
    let execute = next_request()
    execute.responses.put(copy_test_data_row_message(Some(b"first")))
    execute.responses.put(copy_test_error_response_message("late query error"))
    execute.responses.put(copy_test_ready_for_query_message(status=b'E'))
    scoped_test_close(next_request())
    let rollback = next_request()
    assert_eq(rollback.bytes, simple_query_bytes("ROLLBACK"))
    rollback.responses.put(copy_test_ready_for_query_message())
    assert_true(
      expect_error_async(() => task.wait())
      is ClientError::Database({ message: "late query error", .. }),
    )
  })
}

///|
async test "unfinished nested transactions roll back from deepest to root" {
  with_cancellation_test_client((group, client, next_request) => {
    let task = group.spawn(allow_failure=true, () => {
      client.with_transaction(outer => {
        let inner = outer.savepoint("inner")
        ignore(inner.savepoint("leaf"))
      })
    })
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    let inner = next_request()
    assert_eq(inner.bytes, simple_query_bytes("SAVEPOINT inner"))
    inner.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let leaf = next_request()
    assert_eq(leaf.bytes, simple_query_bytes("SAVEPOINT leaf"))
    leaf.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let leaf_rollback = next_request()
    assert_eq(
      leaf_rollback.bytes,
      simple_query_bytes("ROLLBACK TO SAVEPOINT leaf; RELEASE SAVEPOINT leaf"),
    )
    leaf_rollback.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let inner_rollback = next_request()
    assert_eq(
      inner_rollback.bytes,
      simple_query_bytes("ROLLBACK TO SAVEPOINT inner; RELEASE SAVEPOINT inner"),
    )
    inner_rollback.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let root_rollback = next_request()
    assert_eq(root_rollback.bytes, simple_query_bytes("ROLLBACK"))
    root_rollback.responses.put(copy_test_ready_for_query_message())
    assert_true(
      expect_error_async(() => task.wait())
      is ClientError::UnfinishedChildTransaction,
    )
  })
}

///|
async test "transaction stream scopes cover query statement and portal" {
  for mode in 0..<3 {
    with_cancellation_test_client((group, client, next_request) => {
      let statement : Statement = {
        client,
        name: b"existing",
        params: [],
        columns: [],
        closed: @ref.new(false),
      }
      let portal : Portal = {
        name: b"existing_portal",
        columns: [],
        closed: @ref.new(false),
      }
      let task = group.spawn(() => {
        client.with_transaction(tx => {
          match mode {
            0 =>
              tx.with_stream("select value", stream => {
                ignore(stream.next())
                42
              })
            1 =>
              tx.with_statement_stream(statement, stream => {
                ignore(stream.next())
                42
              })
            _ =>
              tx.with_portal_stream(portal, 1, stream => {
                ignore(stream.next())
                42
              })
          }
        })
      })
      next_request().responses.put(
        copy_test_ready_for_query_message(status=b'T'),
      )
      if mode == 0 {
        scoped_test_prepare(next_request())
      }
      let execute = next_request()
      execute.responses.put(copy_test_data_row_message(Some(b"first")))
      execute.responses.put(copy_test_data_row_message(Some(b"discard")))
      execute.responses.put(copy_test_command_complete_message("SELECT 2"))
      execute.responses.put(copy_test_ready_for_query_message(status=b'T'))
      if mode == 0 {
        scoped_test_close(next_request())
      }
      let commit = next_request()
      assert_eq(commit.bytes, simple_query_bytes("COMMIT"))
      commit.responses.put(copy_test_ready_for_query_message())
      assert_eq(task.wait(), 42)
      assert_false(statement.closed.val)
      assert_false(portal.closed.val)
    })
  }
}

///|
async test "manual completion drains its unfinished stream before final command" {
  for commit_action in [true, false] {
    with_cancellation_test_client((group, client, next_request) => {
      let begin = group.spawn(() => client.transaction())
      next_request().responses.put(
        copy_test_ready_for_query_message(status=b'T'),
      )
      let tx = begin.wait()
      let statement : Statement = {
        client,
        name: b"existing",
        params: [],
        columns: [],
        closed: @ref.new(false),
      }
      let created = group.spawn(() => tx.query_statement(statement))
      let execute = next_request()
      let stream = created.wait()
      let finish = group.spawn(() => {
        if commit_action {
          tx.commit()
        } else {
          tx.rollback()
        }
      })
      execute.responses.put(copy_test_data_row_message(Some(b"discard")))
      execute.responses.put(copy_test_ready_for_query_message(status=b'T'))
      let final_request = next_request()
      assert_eq(
        final_request.bytes,
        simple_query_bytes(if commit_action { "COMMIT" } else { "ROLLBACK" }),
      )
      assert_false(tx.scope_gate.mutex.try_acquire())
      final_request.responses.put(copy_test_ready_for_query_message())
      finish.wait()
      assert_eq(stream.finish().row_count, 1)
      assert_true(tx.scope_gate.mutex.try_acquire())
      tx.scope_gate.mutex.release()
    })
  }
}

///|
async test "manual rollback recursively closes nested stream and savepoint" {
  with_cancellation_test_client((group, client, next_request) => {
    let begin = group.spawn(() => client.transaction())
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    let outer = begin.wait()
    let nested_task = group.spawn(() => outer.savepoint("nested"))
    let savepoint = next_request()
    savepoint.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let nested = nested_task.wait()
    let statement : Statement = {
      client,
      name: b"existing",
      params: [],
      columns: [],
      closed: @ref.new(false),
    }
    let query = group.spawn(() => nested.query_statement(statement))
    let execute = next_request()
    ignore(query.wait())
    let rollback = group.spawn(() => outer.rollback())
    execute.responses.put(copy_test_data_row_message(Some(b"discard")))
    execute.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let nested_rollback = next_request()
    assert_eq(
      nested_rollback.bytes,
      simple_query_bytes(
        "ROLLBACK TO SAVEPOINT nested; RELEASE SAVEPOINT nested",
      ),
    )
    nested_rollback.responses.put(
      copy_test_ready_for_query_message(status=b'T'),
    )
    let root_rollback = next_request()
    assert_eq(root_rollback.bytes, simple_query_bytes("ROLLBACK"))
    root_rollback.responses.put(copy_test_ready_for_query_message())
    rollback.wait()
    assert_true(nested.finished.val)
  })
}

///|
async test "manual commit with an open savepoint rolls back and reports misuse" {
  with_cancellation_test_client((group, client, next_request) => {
    let begin = group.spawn(() => client.transaction())
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    let outer = begin.wait()
    let created = group.spawn(() => outer.savepoint("open_child"))
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    let child = created.wait()
    let commit = group.spawn(allow_failure=true, () => outer.commit())
    let child_rollback = next_request()
    assert_eq(
      child_rollback.bytes,
      simple_query_bytes(
        "ROLLBACK TO SAVEPOINT open_child; RELEASE SAVEPOINT open_child",
      ),
    )
    child_rollback.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let parent_rollback = next_request()
    assert_eq(parent_rollback.bytes, simple_query_bytes("ROLLBACK"))
    parent_rollback.responses.put(copy_test_ready_for_query_message())
    assert_true(
      expect_error_async(() => commit.wait())
      is ClientError::UnfinishedChildTransaction,
    )
    assert_true(child.finished.val)
    assert_true(outer.finished.val)
  })
}

///|
async test "cancellation after stream drain leaves manual commit rollbackable" {
  with_cancellation_test_client((group, client, next_request) => {
    let begin = group.spawn(() => client.transaction())
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    let tx = begin.wait()
    let statement : Statement = {
      client,
      name: b"existing",
      params: [],
      columns: [],
      closed: @ref.new(false),
    }
    let created = group.spawn(() => tx.query_statement(statement))
    let execute = next_request()
    ignore(created.wait())
    let commit = group.spawn(allow_failure=true, () => tx.commit())
    for _ in 0..<100 {
      if tx.closing.val is Some(_) {
        break
      }
      @async.sleep(1)
    }
    assert_true(tx.closing.val is Some(_))
    commit.cancel()
    execute.responses.put(copy_test_data_row_message(Some(b"discard")))
    execute.responses.put(copy_test_ready_for_query_message(status=b'T'))
    assert_true(expect_error_async(() => commit.wait()) is @async.TaskCancelled)
    assert_false(tx.finished.val)
    assert_true(client.shared.requests.try_get() is None)
    let rollback = group.spawn(() => tx.rollback())
    let request = next_request()
    assert_eq(request.bytes, simple_query_bytes("ROLLBACK"))
    request.responses.put(copy_test_ready_for_query_message())
    rollback.wait()
  })
}

///|
async test "closing a transaction while a query is being created cleans it first" {
  with_cancellation_test_client((group, client, next_request) => {
    let begin = group.spawn(() => client.transaction())
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    let tx = begin.wait()
    let delivered = @ref.new(false)
    let creator = group.spawn(allow_failure=true, () => {
      ignore(tx.query("select value"))
      delivered.val = true
    })
    let prepare = next_request()
    let closer = group.spawn(() => tx.commit())
    for _ in 0..<100 {
      if tx.closing.val is Some(_) {
        break
      }
      @async.sleep(1)
    }
    assert_true(tx.closing.val is Some(_))
    scoped_test_prepare(prepare)
    let execute = next_request()
    execute.responses.put(copy_test_data_row_message(Some(b"discard")))
    execute.responses.put(copy_test_ready_for_query_message(status=b'T'))
    scoped_test_close(next_request())
    let commit = next_request()
    assert_eq(commit.bytes, simple_query_bytes("COMMIT"))
    commit.responses.put(copy_test_ready_for_query_message())
    closer.wait()
    assert_false(delivered.val)
    assert_true(
      expect_error_async(() => creator.wait()) is ClientError::Closed(_),
    )
  })
}

///|
async test "local query creation error during close keeps connection usable" {
  with_cancellation_test_client((group, client, next_request) => {
    let begin = group.spawn(() => client.transaction())
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    let tx = begin.wait()
    let creator = group.spawn(allow_failure=true, () => {
      ignore(tx.query("select $1", params=[true as &ToSql]))
    })
    let prepare = next_request()
    let closer = group.spawn(() => tx.commit())
    for _ in 0..<100 {
      if tx.closing.val is Some(_) {
        break
      }
      @async.sleep(1)
    }
    assert_true(tx.closing.val is Some(_))
    scoped_test_prepare(prepare, param_types=[Type::int4()])
    scoped_test_close(next_request())
    let commit = next_request()
    assert_eq(commit.bytes, simple_query_bytes("COMMIT"))
    commit.responses.put(copy_test_ready_for_query_message())
    closer.wait()
    assert_true(
      expect_error_async(() => creator.wait()) is ClientError::WrongType(_),
    )
    assert_false(client.shared.closed.val)
  })
}

///|
async test "closing a transaction while creating a savepoint rolls it back" {
  with_cancellation_test_client((group, client, next_request) => {
    let begin = group.spawn(() => client.transaction())
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    let tx = begin.wait()
    let delivered = @ref.new(false)
    let creator = group.spawn(allow_failure=true, () => {
      ignore(tx.savepoint("pending"))
      delivered.val = true
    })
    let savepoint = next_request()
    let closer = group.spawn(() => tx.commit())
    for _ in 0..<100 {
      if tx.closing.val is Some(_) {
        break
      }
      @async.sleep(1)
    }
    assert_true(tx.closing.val is Some(_))
    savepoint.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let nested_rollback = next_request()
    assert_eq(
      nested_rollback.bytes,
      simple_query_bytes(
        "ROLLBACK TO SAVEPOINT pending; RELEASE SAVEPOINT pending",
      ),
    )
    nested_rollback.responses.put(
      copy_test_ready_for_query_message(status=b'T'),
    )
    let commit = next_request()
    assert_eq(commit.bytes, simple_query_bytes("COMMIT"))
    commit.responses.put(copy_test_ready_for_query_message())
    closer.wait()
    assert_false(delivered.val)
    assert_true(
      expect_error_async(() => creator.wait()) is ClientError::Closed(_),
    )
  })
}

///|
async test "nested transaction scopes release savepoints before root commit" {
  with_cancellation_test_client((group, client, next_request) => {
    let task = group.spawn(() => {
      client.with_transaction(outer => {
        outer.with_transaction(_ => ())
        outer.with_savepoint("named", _ => ())
      })
    })
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    let unnamed = next_request()
    assert_eq(unnamed.bytes, simple_query_bytes("SAVEPOINT moon_tx_1"))
    unnamed.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let release_unnamed = next_request()
    assert_eq(
      release_unnamed.bytes,
      simple_query_bytes("RELEASE SAVEPOINT moon_tx_1"),
    )
    release_unnamed.responses.put(
      copy_test_ready_for_query_message(status=b'T'),
    )
    let named = next_request()
    assert_eq(named.bytes, simple_query_bytes("SAVEPOINT named"))
    named.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let release_named = next_request()
    assert_eq(
      release_named.bytes,
      simple_query_bytes("RELEASE SAVEPOINT named"),
    )
    release_named.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let commit = next_request()
    assert_eq(commit.bytes, simple_query_bytes("COMMIT"))
    commit.responses.put(copy_test_ready_for_query_message())
    task.wait()
  })
}

///|
async test "transaction stream scope leaves its callback cancellable" {
  with_cancellation_test_client((group, client, next_request) => {
    let statement : Statement = {
      client,
      name: b"existing",
      params: [],
      columns: [],
      closed: @ref.new(false),
    }
    let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
    let wait_forever : @async.Queue[Unit] = Queue(kind=Unbounded)
    let task = group.spawn(allow_failure=true, () => {
      client.with_transaction(tx => {
        tx.with_statement_stream(statement, stream => {
          ignore(stream.next())
          entered.put(())
          wait_forever.get()
        })
      })
    })
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    let execute = next_request()
    execute.responses.put(copy_test_data_row_message(Some(b"first")))
    entered.get()
    task.cancel()
    execute.responses.put(copy_test_data_row_message(Some(b"discard")))
    execute.responses.put(copy_test_ready_for_query_message(status=b'T'))
    let rollback = next_request()
    assert_eq(rollback.bytes, simple_query_bytes("ROLLBACK"))
    rollback.responses.put(copy_test_ready_for_query_message())
    assert_true(expect_error_async(() => task.wait()) is @async.TaskCancelled)
    assert_false(statement.closed.val)
  })
}
