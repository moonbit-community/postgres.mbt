///|
async test "prepared callback exception and cancellation retain their cause through Close" {
  for callback_raises in [false, true] {
    for outcome in 0..<3 {
      with_control_pool(
        if outcome == 1 {
          HoldCloseError
        } else {
          HoldClose
        },
        (group, pool, probe) => {
          let session = pool.checkout_session()
          let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
          let hold : @async.Queue[Unit] = Queue(kind=Unbounded)
          defer hold.close()
          let saved : @ref.Ref[PreparedStatement?] = Ref(None)
          let task = group.spawn(allow_failure=true, () => {
            session.with_prepared("temporary", prepared => {
              saved.val = Some(prepared)
              entered.put(())
              if callback_raises {
                raise PoolError::InvalidConfig("callback exception")
              }
              hold.get()
            })
          })
          entered.get()
          if !callback_raises {
            task.cancel()
          }
          probe.close_started.get()
          task.cancel()
          if outcome != 2 {
            probe.release_close.put(())
          }
          let error = expect_pgpool_error_async(() => task.wait())
          if callback_raises {
            assert_true(error is PoolError::InvalidConfig("callback exception"))
          } else {
            assert_true(error is @async.WaitedTaskAlreadyCancelled)
          }
          assert_false(saved.val.unwrap().state.active.val)
          assert_true(saved.val.unwrap().state.released.val)
          assert_eq(count_callback_requests(probe.requests, b'C'), 1)
          assert_eq(session.state.active_ops.val, 0)
          assert_true(session.state.cleanup_deadline.val is Some(_))
          session.release()
          assert_eq(pool.status().available, if outcome == 0 { 1 } else { 0 })
          assert_returned_capacity(pool)
        },
        cache_capacity=0,
        cleanup_ms=if outcome == 2 { 40 } else { 1000 },
      )
    }
  }
}

///|
async test "prepared scope propagates cancellation received during successful or failed Close" {
  // Capacity one evicts the still-leased outer statement. Capacity zero closes
  // a temporary handle. Both paths must observe cancellation on scope exit.
  for capacity in [0, 1] {
    for outcome in 0..<3 {
      let fault = if outcome == 1 { HoldCloseError } else { HoldClose }
      with_control_pool(
        fault,
        (group, pool, probe) => {
          let after_scope = Ref(false)
          let caught_cleanup_error = Ref(false)
          let session = pool.checkout_session()
          let task = group.spawn(allow_failure=true, () => {
            session.with_prepared("outer", _ => {
              if capacity == 1 {
                session.with_prepared("inner", _ => ())
              }
            }) catch {
              @client.ClientError::Database(_) | PoolError::Timeout(_) =>
                caught_cleanup_error.val = true
              error => raise error
            }
            after_scope.val = true
          })
          probe.close_started.get()
          assert_true(task.try_wait() is None)
          assert_false(session.state.gate.try_acquire())
          assert_true(pool.shared.slots.try_get() is None)
          let started = @async.now()
          task.cancel()
          if outcome != 2 {
            probe.release_close.put(())
          }
          assert_true(
            expect_pgpool_error_async(() => task.wait())
            is @async.WaitedTaskAlreadyCancelled,
          )
          assert_false(after_scope.val)
          assert_false(caught_cleanup_error.val)
          assert_true(@async.now() - started < 600L)
          assert_eq(session.state.active_ops.val, 0)
          assert_eq(count_callback_requests(probe.requests, b'C'), 1)
          assert_true(probe.cancel_started.try_get() is None)
          if outcome == 0 {
            session.check_connection()
          } else {
            assert_true(session.state.scoped_client().is_closed())
          }
          session.release()
          assert_eq(pool.status().available, if outcome == 0 { 1 } else { 0 })
          assert_true(pool.shared.slots.try_get() is Some(_))
          assert_true(pool.shared.slots.try_get() is None)
        },
        cache_capacity=capacity,
        cleanup_ms=if outcome == 2 { 40 } else { 200 },
      )
    }
  }
}

///|
async test "prepared scope checks pending cancellation after its callback before user code resumes" {
  with_control_pool(Normal, (group, pool, _) => {
    let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
    let release_callback : @async.Queue[Unit] = Queue(kind=Unbounded)
    let after_scope = Ref(false)
    let session = pool.checkout_session()
    let task = group.spawn(allow_failure=true, () => {
      session.with_prepared("cached", _ => {
        @async.protect_from_cancel(() => {
          entered.put(())
          release_callback.get()
        })
      })
      after_scope.val = true
    })
    entered.get()
    task.cancel()
    release_callback.put(())
    assert_true(
      expect_pgpool_error_async(() => task.wait())
      is @async.WaitedTaskAlreadyCancelled,
    )
    assert_false(after_scope.val)
    assert_eq(session.state.active_ops.val, 0)
    session.check_connection()
    session.release()
  })
}
