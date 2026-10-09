///|
async test "foreign statements reject before gate waits and cannot close same named resources" {
  with_cancellation_test_client((group, first, next_first) => {
    with_cancellation_test_client((_group, second, next_second) => {
      let preparing = group.spawn(() => first.prepare("select 'first'"))
      let request = next_first()
      assert_eq(request.bytes, prepare_bytes(b"s1", "select 'first'", []))
      scoped_test_prepare(request)
      let foreign = preparing.wait()
      let preparing = group.spawn(() => second.prepare("select 'second'"))
      let request = next_second()
      assert_eq(request.bytes, prepare_bytes(b"s1", "select 'second'", []))
      scoped_test_prepare(request)
      let own_statement = preparing.wait()
      assert_eq(foreign.name, own_statement.name)
      assert_true(first.shared.connection_id != second.shared.connection_id)
      // Keep both client gates occupied: rejection must precede any wait.
      let first_permit = first.shared.operation_gate.acquire()
      let second_permit = second.shared.operation_gate.acquire()
      for closed in [false, true] {
        foreign.closed.val = closed
        @async.with_timeout(1000, () => {
          assert_true(
            expect_error_async(() => second.query_statement(foreign))
            is ClientError::StatementConnectionMismatch,
          )
          assert_true(
            expect_error_async(() => second.execute_raw(foreign))
            is ClientError::StatementConnectionMismatch,
          )
          assert_true(
            expect_error_async(() => {
              second.with_statement_stream(foreign, _ => ())
            })
            is ClientError::StatementConnectionMismatch,
          )
          assert_true(
            expect_error_async(() => {
              second.operation_context().execute_raw(foreign, [])
            })
            is ClientError::StatementConnectionMismatch,
          )
          assert_true(
            expect_error_async(() => {
              second.operation_context().bind(foreign, [])
            })
            is ClientError::StatementConnectionMismatch,
          )
          assert_true(
            expect_error_async(() => {
              second.operation_context().close_statement(foreign)
            })
            is ClientError::StatementConnectionMismatch,
          )
        })
        assert_eq(foreign.closed.val, closed)
        assert_false(own_statement.closed.val)
        assert_true(first.shared.requests.try_get() is None)
        assert_true(second.shared.requests.try_get() is None)
        assert_false(first.is_closed())
        assert_false(second.is_closed())
      }
      foreign.closed.val = false
      first_permit.release()
      second_permit.release()
      let begin = group.spawn(() => second.transaction())
      next_second().responses.put(
        copy_test_ready_for_query_message(status=b'T'),
      )
      let tx = begin.wait()
      let tx_permit = tx.scope_gate.acquire()
      for closed in [false, true] {
        foreign.closed.val = closed
        @async.with_timeout(1000, () => {
          assert_true(
            expect_error_async(() => tx.query_statement(foreign))
            is ClientError::StatementConnectionMismatch,
          )
          assert_true(
            expect_error_async(() => tx.execute_raw(foreign))
            is ClientError::StatementConnectionMismatch,
          )
          assert_true(
            expect_error_async(() => tx.with_statement_stream(foreign, _ => ()))
            is ClientError::StatementConnectionMismatch,
          )
          assert_true(
            expect_error_async(() => tx.with_portal(foreign, _ => ()))
            is ClientError::StatementConnectionMismatch,
          )
          assert_true(
            expect_error_async(() => tx.close_statement(foreign))
            is ClientError::StatementConnectionMismatch,
          )
          assert_true(
            expect_error_async(() => tx.bind(foreign))
            is ClientError::StatementConnectionMismatch,
          )
        })
        assert_eq(tx.scoped_resources.val, 0)
        assert_true(tx.child.val is None)
        assert_true(second.shared.requests.try_get() is None)
        assert_false(own_statement.closed.val)
        assert_false(first.is_closed())
        assert_false(second.is_closed())
      }
      foreign.closed.val = false
      tx_permit.release()
      // A defensive ownership error during child creation must clear the
      // registration without aborting the otherwise healthy connection.
      assert_true(
        expect_error_async(() => {
          tx.start_stream(_ => raise ClientError::StatementConnectionMismatch)
        })
        is ClientError::StatementConnectionMismatch,
      )
      assert_true(tx.child.val is None)
      assert_false(second.is_closed())
      assert_true(second.shared.requests.try_get() is None)
      let execute = group.spawn(() => tx.execute_raw(own_statement))
      statement_test_complete(next_second(), status=b'T')
      assert_eq(execute.wait(), 1)
      let rollback = group.spawn(() => tx.rollback())
      next_second().responses.put(copy_test_ready_for_query_message())
      rollback.wait()
      for client in [first, second] {
        let check = group.spawn(() => client.check_connection())
        client.shared.requests.get().responses.put(
          copy_test_ready_for_query_message(),
        )
        check.wait()
        assert_false(client.is_closed())
      }
      assert_false(own_statement.closed.val)
      assert_false(foreign.closed.val)
    })
  })
}

///|
fn statement_test_complete(
  request : Request,
  status? : Byte = b'I',
) -> Unit raise {
  ignore(
    request.responses.try_put(copy_test_command_complete_message("SELECT 1")),
  )
  ignore(request.responses.try_put(copy_test_ready_for_query_message(status~)))
}
