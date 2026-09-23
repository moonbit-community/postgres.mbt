///|
async test "cancelled client and transaction prepare close before releasing the handle" {
  for transaction_scope in [false, true] {
    for typed in [false, true] {
      with_cancellation_test_client((group, client, next_request) => {
        let transaction = if transaction_scope {
          let begin = group.spawn(() => client.transaction())
          next_request().responses.put(
            copy_test_ready_for_query_message(status=b'T'),
          )
          Some(begin.wait())
        } else {
          None
        }
        let sql = if typed { "select $1::int4" } else { "select 1" }
        let types = if typed { [Type::int4()] } else { [] }
        let delivered = @ref.new(false)
        let task = group.spawn(allow_failure=true, () => {
          let statement = match transaction {
            Some(tx) =>
              if typed {
                tx.prepare_typed(sql, types)
              } else {
                tx.prepare(sql)
              }
            None =>
              if typed {
                client.prepare_typed(sql, types)
              } else {
                client.prepare(sql)
              }
          }
          delivered.val = true
          ignore(statement)
        })
        let prepare = next_request()
        assert_eq(prepare.bytes, prepare_bytes(b"s1", sql, types))
        task.cancel()
        scoped_test_prepare(prepare, param_types=types)
        let close = next_request()
        assert_eq(close.bytes, close_bytes(b'S', b"s1"))
        assert_true(task.try_wait() is None)
        assert_false(delivered.val)
        assert_false(client.shared.operation_gate.mutex.try_acquire())
        if transaction is Some(tx) {
          assert_false(tx.scope_gate.mutex.try_acquire())
        }
        close.responses.put(copy_test_close_complete_message())
        close.responses.put(
          copy_test_ready_for_query_message(
            status=if transaction_scope { b'T' } else { b'I' },
          ),
        )
        assert_true(
          expect_error_async(() => task.wait()) is @async.TaskCancelled,
        )
        assert_false(delivered.val)
        assert_true(close.responses.try_get() is None)
        if transaction is Some(tx) {
          assert_true(tx.scope_gate.mutex.try_acquire())
          tx.scope_gate.mutex.release()
          let rollback = group.spawn(() => tx.rollback())
          let request = next_request()
          assert_eq(request.bytes, simple_query_bytes("ROLLBACK"))
          request.responses.put(copy_test_ready_for_query_message())
          rollback.wait()
        }
        assert_true(client.shared.operation_gate.mutex.try_acquire())
        client.shared.operation_gate.mutex.release()
      })
    }
  }
}

///|
async test "failed Close while delivering a cancelled prepare aborts the connection" {
  for transaction_scope in [false, true] {
    for typed in [false, true] {
      @async.with_task_group(group => {
        let shared = copy_test_shared(@ref.new(Some(group)))
        let client : Client = { shared, }
        @async.with_timeout(2000, () => {
          let transaction = if transaction_scope {
            let begin = group.spawn(() => client.transaction())
            shared.requests.get().responses.put(
              copy_test_ready_for_query_message(status=b'T'),
            )
            Some(begin.wait())
          } else {
            None
          }
          let sql = if typed { "select $1::int4" } else { "select 1" }
          let types = if typed { [Type::int4()] } else { [] }
          let delivered = @ref.new(false)
          let task = group.spawn(allow_failure=true, () => {
            let statement = match transaction {
              Some(tx) =>
                if typed {
                  tx.prepare_typed(sql, types)
                } else {
                  tx.prepare(sql)
                }
              None =>
                if typed {
                  client.prepare_typed(sql, types)
                } else {
                  client.prepare(sql)
                }
            }
            delivered.val = true
            ignore(statement)
          })
          let prepare = shared.requests.get()
          assert_eq(prepare.bytes, prepare_bytes(b"s1", sql, types))
          task.cancel()
          scoped_test_prepare(prepare, param_types=types)
          let close = shared.requests.get()
          assert_eq(close.bytes, close_bytes(b'S', b"s1"))
          assert_true(task.try_wait() is None)
          if typed {
            close.responses.put(
              copy_test_error_response_message("close failed"),
            )
            close.responses.put(copy_test_ready_for_query_message())
          } else {
            close.responses.close(
              error=ClientError::Protocol("close lost"),
              clear=true,
            )
          }
          assert_true(
            expect_error_async(() => task.wait()) is @async.TaskCancelled,
          )
          assert_false(delivered.val)
          assert_true(shared.aborted.val)
          assert_true(shared.operation_gate.mutex.try_acquire())
          shared.operation_gate.mutex.release()
          if transaction is Some(tx) {
            assert_true(tx.finished.val)
            assert_true(tx.scope_gate.mutex.try_acquire())
            tx.scope_gate.mutex.release()
          }
        })
      })
    }
  }
}
