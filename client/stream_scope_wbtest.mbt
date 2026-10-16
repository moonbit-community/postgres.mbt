///|
/// Exercise the internal cleanup boundary alongside the public error boundary.
fn scope_test_stream(
  kind : Int32,
  control : DrainControl,
  responses : @async.Queue[@backend.Message],
  permit : OperationPermit,
) -> (async () -> DatabaseError?, async () -> Unit, () -> Unit) {
  match kind {
    0 => {
      let stream = RowStream::new(control, responses, Some(permit))
      (
        () => stream.finish_scope(),
        () => ignore(stream.finish()),
        () => stream.detach(),
      )
    }
    1 => {
      let stream = SimpleQueryStream::new(control, responses, Some(permit))
      (
        () => stream.finish_scope(),
        () => stream.finish(),
        () => stream.detach(),
      )
    }
    _ => {
      let stream : CopyOutStream = {
        control,
        responses,
        permit: Some(permit),
        formats: [],
        database_error: None,
        detached: false,
        detached_done: None,
        finished: false,
      }
      (
        () => stream.finish_scope(),
        () => stream.finish(),
        () => stream.detach(),
      )
    }
  }
}

///|
async test "scope finish returns SQL errors only after ReadyForQuery in attached and detached streams" {
  for kind in 0..<3 {
    // Attached, background drain, and synchronous fallback after detach.
    for mode in 0..<3 {
      @async.with_task_group(group => {
        let control = test_control(if mode == 2 { None } else { Some(group) })
        let responses : @async.Queue[@backend.Message] = Queue(kind=Unbounded)
        let permit = OperationGate::new().acquire()
        let (finish_scope, finish, detach) = scope_test_stream(
          kind, control, responses, permit,
        )
        responses.put(copy_test_error_response_message("query failed"))
        if mode != 0 {
          detach()
        }
        let pending = group.spawn(finish_scope)
        assert_true(pending.try_wait() is None)
        responses.put(copy_test_ready_for_query_message())
        assert_true(pending.wait() is Some({ message: "query failed", .. }))
        assert_true(permit.released.val)
        for _ in 0..<2 {
          assert_true(finish_scope() is Some({ message: "query failed", .. }))
          assert_true(
            expect_error_async(finish)
            is ClientError::Database({ message: "query failed", .. }),
          )
        }
      })
    }
  }
}

///|
async test "scope finish does not convert missing ReadyForQuery into a query error" {
  for kind in 0..<3 {
    for detached in [false, true] {
      @async.with_task_group(group => {
        let responses : @async.Queue[@backend.Message] = Queue(kind=Unbounded)
        let permit = OperationGate::new().acquire()
        let (finish_scope, _, detach) = scope_test_stream(
          kind,
          test_control(Some(group)),
          responses,
          permit,
        )
        responses.put(copy_test_error_response_message("query failed"))
        responses.close(error=ClientError::Closed("lost ReadyForQuery"))
        if detached {
          detach()
        }
        for _ in 0..<2 {
          assert_true(
            expect_error_async(finish_scope)
            is ClientError::Closed("lost ReadyForQuery"),
          )
        }
      })
    }
  }
}

///|
async test "scope finish preserves protocol failures even after a SQL error" {
  for kind in 0..<3 {
    for detached in [false, true] {
      let responses : @async.Queue[@backend.Message] = Queue(kind=Unbounded)
      let permit = OperationGate::new().acquire()
      let (finish_scope, _, detach) = scope_test_stream(
        kind,
        test_control(None),
        responses,
        permit,
      )
      responses.put(copy_test_error_response_message("query failed"))
      responses.close(error=ClientError::Protocol("invalid response"))
      if detached {
        detach()
      }
      assert_true(
        expect_error_async(finish_scope)
        is ClientError::Protocol("invalid response"),
      )
    }
  }
}

///|
async test "temporary Close completion retains failure across concurrent and repeated finishers" {
  for mode in 0..<3 {
    for disconnect in [false, true] {
      with_cancellation_test_client((group, client, next_request) => {
        let query = group.spawn(() => client.query("select value"))
        scoped_test_prepare(next_request())
        let execute = next_request()
        let stream = query.wait()
        execute.responses.put(copy_test_error_response_message("query failed"))
        execute.responses.put(copy_test_ready_for_query_message())
        if mode == 2 {
          stream.detach()
        }
        let first = group.spawn(allow_failure=true, () => {
          if mode == 0 {
            ignore(stream.next())
          } else {
            ignore(stream.finish())
          }
        })
        let close = next_request()
        assert_eq(close.bytes, close_bytes(b'S', b"q1"))
        let second = group.spawn(allow_failure=true, () => stream.finish_scope())
        assert_true(first.try_wait() is None)
        assert_true(second.try_wait() is None)
        if disconnect {
          close.responses.close(error=ClientError::Closed("Close disconnected"))
        } else {
          close.responses.put(copy_test_error_response_message("Close failed"))
          close.responses.put(copy_test_ready_for_query_message())
        }
        let errors = [
          expect_error_async(() => first.wait()),
          expect_error_async(() => second.wait()),
          expect_error_async(() => stream.finish()),
          expect_error_async(() => stream.finish_scope()),
        ]
        for error in errors {
          if disconnect {
            assert_true(error is ClientError::Closed("Close disconnected"))
          } else {
            assert_true(
              error is ClientError::Database({ message: "Close failed", .. }),
            )
          }
        }
        assert_true(client.shared.requests.try_get() is None)
      })
    }
  }
}
