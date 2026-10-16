// Method deadlines must supervise even the raw stream's protected Close I/O.

///|
async fn stream_terminal_method(
  stream : RowStream,
  finish~ : Bool,
  milliseconds~ : Int32 = 40,
) -> Unit {
  let deadline = Deadline::after_ms(milliseconds)
  if finish {
    ignore(stream.finish(deadline~))
  } else {
    ignore(stream.next(deadline~))
  }
}

///|
async test "stream method deadlines abort hung temporary Close within the cleanup budget" {
  for finish in [false, true] {
    for fault in [HoldClose, HoldCloseCancel] {
      with_control_pool(
        fault,
        (group, pool, probe) => {
          let saved : @ref.Ref[RowStream?] = Ref(None)
          let retired : @ref.Ref[ConnectionState?] = Ref(None)
          let started = @async.now()
          let error = expect_pgpool_error_async(() => {
            pool.with_session(session => {
              retired.val = Some(session.state.connection)
              let _ : Unit = session.with_stream("select 0", stream => {
                saved.val = Some(stream)
                let pending = group.spawn(allow_failure=true, () => {
                  stream_terminal_method(stream, finish~)
                })
                probe.close_started.get()
                assert_true(
                  expect_pgpool_error_async(() => stream.next())
                  is PoolError::OperationInProgress,
                )
                assert_true(
                  expect_pgpool_error_async(() => session.check_connection())
                  is PoolError::OperationInProgress,
                )
                assert_true(pool.shared.slots.try_get() is None)
                let error = expect_pgpool_error_async(() => pending.wait())
                assert_true(error is PoolError::Timeout(Query))
                // The method joined its worker before returning the handle gate.
                assert_true(stream.scope.gate.try_acquire())
                stream.scope.gate.release()
                assert_true(session.state.scoped_client().is_closed())
                // ReadyForQuery preceded Close. Its saved summary must not
                // turn the failed Close into success on a later finish.
                for _ in 0..<2 {
                  assert_true(
                    expect_pgpool_error_async(() => stream.raw.finish())
                    is @client.ClientError::Closed(_),
                  )
                }
                raise error
              })
            })
          })
          assert_true(error is PoolError::Timeout(Query))
          assert_true(@async.now() - started < 600L)
          assert_true(probe.cancel_started.try_get() is Some(_))
          assert_true(probe.cancel_started.try_get() is None)
          assert_eq(pool.status().size, 0)
          assert_eq(pool.status().available, 0)
          assert_true(retired.val.unwrap().client.val is None)
          assert_true(pool.shared.slots.try_get() is Some(_))
          assert_true(pool.shared.slots.try_get() is None)
          assert_true(pool.shared.slots.try_put(()))
          assert_true(
            expect_pgpool_error_async(() => saved.val.unwrap().next())
            is PoolError::ScopeExpired,
          )
          pool.batch_execute("replacement")
          assert_eq(pool.status().size, 1)
          assert_eq(pool.status().available, 1)
        },
        cleanup_ms=40,
      )
    }
  }
}

///|
async test "stream timeout waits for timely Close and reuses a synchronized connection" {
  for finish in [false, true] {
    with_control_pool(HoldClose, (group, pool, probe) => {
      pool.with_session(session => {
        session.with_stream("select 0", stream => {
          let pending = group.spawn(allow_failure=true, () => {
            stream_terminal_method(stream, finish~)
          })
          probe.close_started.get()
          probe.cancel_started.get()
          session.state.active_control.val.unwrap().wait_cancel()
          assert_true(pending.try_wait() is None)
          assert_true(!stream.scope.gate.try_acquire())
          assert_true(pool.shared.slots.try_get() is None)
          probe.release_close.put(())
          assert_true(
            expect_pgpool_error_async(() => pending.wait())
            is PoolError::Timeout(Query),
          )
          assert_true(!session.state.scoped_client().is_closed())
        })
        session.check_connection()
      })
      pool.batch_execute("next")
      assert_true(probe.cancel_started.try_get() is None)
      assert_eq(pool.status().size, 1)
      assert_eq(pool.status().available, 1)
    })
  }
}

///|
async test "outer cancellation joins a stream method timeout without releasing its cancel fence" {
  with_control_pool(HoldCloseCancel, (group, pool, probe) => {
    let saved : @ref.Ref[RowStream?] = Ref(None)
    let control : @ref.Ref[@client.RequestControl?] = Ref(None)
    let task = group.spawn(allow_failure=true, () => {
      pool.with_session(session => {
        session.with_stream("select 0", stream => {
          saved.val = Some(stream)
          control.val = session.state.active_control.val
          stream_terminal_method(stream, finish=true)
        })
      })
    })
    probe.close_started.get()
    probe.cancel_started.get()
    task.cancel()
    let fence = group.spawn(() => control.val.unwrap().wait_cancel())
    probe.release_close.put(())
    @async.sleep(10)
    assert_true(task.try_wait() is None)
    assert_true(fence.try_wait() is None)
    assert_true(!saved.val.unwrap().scope.gate.try_acquire())
    assert_true(pool.shared.slots.try_get() is None)
    assert_true(probe.cancel_started.try_get() is None)
    probe.release_cancel.put(())
    fence.wait()
    assert_true(
      expect_pgpool_error_async(() => task.wait())
      is @async.WaitedTaskAlreadyCancelled,
    )
    assert_true(probe.cancel_started.try_get() is None)
    assert_eq(pool.status().size, 1)
    assert_eq(pool.status().available, 1)
    pool.batch_execute("next")
  })
}
