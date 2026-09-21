///|
async test "row stream detach does not swallow non-database drain failures" {
  let result = expect_error_async(() => {
    @async.with_task_group(group => {
      let control : DrainControl = test_control(Some(group))
      let responses : @async.Queue[@backend.Message] = Queue(kind=Unbounded)
      let stream = RowStream::new(control, responses, None)
      responses.close(error=ClientError::UnexpectedMessage("boom"), clear=true)
      stream.detach()
    })
  })
  guard result is ClientError::UnexpectedMessage(message) else {
    fail("expected detached drain to surface non-database error")
  }
  @debug.assert_eq(message, "boom")
}

///|
async test "queued detached drain receives closure before its worker starts" {
  let control = DrainControl::new()
  let responses : @async.Queue[@backend.Message] = Queue(kind=Blocking(8))
  let stream = RowStream::new(control, responses, None)
  stream.detach()
  assert_eq(control.pending.length(), 1)
  responses.close(error=ClientError::Closed("connection aborted"))
  control.close(error=ClientError::Closed("connection aborted"))
  assert_true(
    expect_error_async(() => stream.finish())
    is ClientError::Closed("connection aborted"),
  )
  assert_eq(control.pending.length(), 0)
}

///|
/// Share lifecycle assertions across the three public output stream types.
fn detach_test_stream(
  kind : Int,
  control : DrainControl,
  responses : @async.Queue[@backend.Message],
  permit : OperationPermit?,
) -> (async () -> Unit, () -> Unit) {
  match kind {
    0 => {
      let stream = RowStream::new(control, responses, permit)
      (() => ignore(stream.finish()), () => stream.detach())
    }
    1 => {
      let stream = SimpleQueryStream::new(control, responses, permit)
      (() => stream.finish(), () => stream.detach())
    }
    _ => {
      let stream : CopyOutStream = {
        control,
        responses,
        permit,
        formats: [],
        database_error: None,
        detached: false,
        detached_done: None,
        finished: false,
      }
      (() => stream.finish(), () => stream.detach())
    }
  }
}

///|
async test "detached stream abort reports Closed without failing sibling connections" {
  for kind in 0..<3 {
    @async.with_task_group(group => {
      let (client, driver, backend) = connection_test_pair(group)
      defer backend.close()
      client.shared.driver_task.val = Some(
        group.spawn(no_wait=true, () => driver.run(group)),
      )
      defer client.abort()
      let (sibling, sibling_driver, sibling_backend) = connection_test_pair(
        group,
      )
      defer sibling_backend.close()
      sibling.shared.driver_task.val = Some(
        group.spawn(no_wait=true, () => sibling_driver.run(group)),
      )
      defer sibling.abort()
      @async.with_timeout(2000, () => {
        let permit = client.shared.operation_gate.acquire()
        let bytes = simple_query_bytes("select 1")
        let responses = client.send_request(Messages, bytes)
        let (finish, detach) = detach_test_stream(
          kind,
          client.shared.control,
          responses,
          Some(permit),
        )
        assert_eq(backend.read_exactly(bytes.length()), bytes)
        detach()
        client.abort()
        for _ in 0..<2 {
          assert_true(
            expect_error_async(finish)
            is ClientError::Closed("connection aborted"),
          )
        }
        assert_true(permit.released.val)
        // A failure in the detached task would cancel this independent driver.
        let ping = group.spawn(() => sibling.check_connection())
        assert_eq(sibling_backend.read_exactly(5), sync_bytes())
        sibling_backend.write(ready_for_query_packet(b'I'))
        ping.wait()
        // This fixture drives `Driver` directly, without `ClientExecutor`
        // to publish its lifecycle completion.
      })
    })
  }
}

///|
async test "detached finish drains synchronously when its control queue is closed" {
  for kind in 0..<3 {
    for closed in [false, true] {
      let responses : @async.Queue[@backend.Message] = Queue(kind=Unbounded)
      let gate = OperationGate::new()
      let permit = gate.acquire()
      let (finish, detach) = detach_test_stream(
        kind,
        test_control(None),
        responses,
        Some(permit),
      )
      if closed {
        responses.close(error=ClientError::Closed("connection aborted"))
      } else {
        responses.put(copy_test_ready_for_query_message())
      }
      detach()
      if closed {
        assert_true(
          expect_error_async(finish)
          is ClientError::Closed("connection aborted"),
        )
      } else {
        finish()
        assert_true(responses.try_get() is None)
      }
      assert_true(permit.released.val)
    }
  }
}

///|
async test "all detached stream types preserve database errors for finish" {
  for kind in 0..<3 {
    @async.with_task_group(group => {
      let responses : @async.Queue[@backend.Message] = Queue(kind=Unbounded)
      let (finish, detach) = detach_test_stream(
        kind,
        test_control(Some(group)),
        responses,
        None,
      )
      responses.put(copy_test_error_response_message("query failed"))
      responses.put(copy_test_ready_for_query_message())
      detach()
      assert_true(
        expect_error_async(finish)
        is ClientError::Database({ message: "query failed", .. }),
      )
    })
  }
}

///|
async test "all detached stream types still fail the task group on protocol errors" {
  for kind in 0..<3 {
    let error = expect_error_async(() => {
      @async.with_task_group(group => {
        let responses : @async.Queue[@backend.Message] = Queue(kind=Unbounded)
        let (finish, detach) = detach_test_stream(
          kind,
          test_control(Some(group)),
          responses,
          None,
        )
        responses.close(error=ClientError::Protocol("invalid response"))
        detach()
        ignore(expect_error_async(finish))
      })
    })
    assert_true(error is ClientError::Protocol("invalid response"))
  }
}
