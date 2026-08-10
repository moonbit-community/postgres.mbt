///|
async test "operation gate grants waiters in FIFO order" {
  @async.with_task_group(group => {
    let gate = OperationGate::new()
    let owner = gate.acquire()
    let ready : @async.Queue[Int] = Queue(kind=Unbounded)
    let granted : @async.Queue[Int] = Queue(kind=Unbounded)

    group.spawn_bg(() => {
      ready.put(1)
      let permit = gate.acquire()
      granted.put(1)
      permit.release()
    })
    assert_eq(ready.get(), 1)

    group.spawn_bg(() => {
      ready.put(2)
      let permit = gate.acquire()
      granted.put(2)
      permit.release()
    })
    assert_eq(ready.get(), 2)

    owner.release()
    assert_eq(granted.get(), 1)
    assert_eq(granted.get(), 2)
  })
}

///|
async test "operation permit release is idempotent" {
  let gate = OperationGate::new()
  let first = gate.acquire()
  first.release()
  first.release()

  let second = gate.acquire()
  second.release()
}

///|
async test "cancelled operation waiter does not consume the next grant" {
  @async.with_task_group(group => {
    let gate = OperationGate::new()
    let owner = gate.acquire()
    let ready : @async.Queue[Unit] = Queue(kind=Unbounded)
    let waiter = group.spawn(allow_failure=true, () => {
      ready.put(())
      let permit = gate.acquire()
      permit.release()
    })
    ready.get()
    waiter.cancel()
    let _ = waiter.wait() catch { _ => () }

    owner.release()
    let next = gate.acquire()
    next.release()
  })
}

///|
async test "row stream owns its operation permit through terminal ready" {
  let gate = OperationGate::new()
  let permit = gate.acquire()
  assert_false(gate.mutex.try_acquire())

  let responses : @async.Queue[@backend.Message] = Queue(kind=Unbounded)
  responses.put(copy_test_ready_for_query_message())
  let stream = new_row_stream(@ref.new(None), responses, Some(permit))
  let summary = stream.finish()
  assert_eq(summary.row_count, 0)

  assert_true(gate.mutex.try_acquire())
  gate.mutex.release()
}

///|
async test "finish waits for a detached row stream to release its permit" {
  @async.with_task_group(group => {
    let gate = OperationGate::new()
    let permit = gate.acquire()
    let responses : @async.Queue[@backend.Message] = Queue(kind=Unbounded)
    let stream = new_row_stream(@ref.new(Some(group)), responses, Some(permit))
    stream.detach()
    group.spawn_bg(() => {
      @async.sleep(1)
      responses.put(copy_test_data_row_message(Some(b"one")))
      responses.put(copy_test_data_row_message(Some(b"two")))
      responses.put(copy_test_ready_for_query_message())
    })

    let summary = stream.finish()
    assert_eq(summary.row_count, 2)
    assert_true(gate.mutex.try_acquire())
    gate.mutex.release()
  })
}

///|
async test "cancelling a row reader hands draining and permit release to background" {
  @async.with_task_group(group => {
    let gate = OperationGate::new()
    let permit = gate.acquire()
    let responses : @async.Queue[@backend.Message] = Queue(kind=Unbounded)
    let stream = new_row_stream(@ref.new(Some(group)), responses, Some(permit))
    let started : @async.Queue[Unit] = Queue(kind=Unbounded)
    let reader = group.spawn(allow_failure=true, () => {
      started.put(())
      ignore(stream.next())
    })
    started.get()
    reader.cancel()
    let _ = reader.wait() catch { _ => () }

    responses.put(copy_test_ready_for_query_message())
    let next = gate.acquire()
    next.release()
  })
}
