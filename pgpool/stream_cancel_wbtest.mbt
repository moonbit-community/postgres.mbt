///|
async fn run_cancel_stream(
  session : Session,
  kind : Int32,
  f : async (StreamScope) -> Int32,
) -> Int32 {
  match kind {
    0 => session.with_stream("held rows", stream => f(stream.scope))
    1 => session.with_typed_stream("held rows", [], stream => f(stream.scope))
    2 =>
      session.with_prepared("held rows", prepared => {
        prepared.with_stream(stream => f(stream.scope))
      })
    3 => session.with_simple_query("held simple", stream => f(stream.scope))
    4 => session.with_copy_out("held copy out", stream => f(stream.scope))
    _ => session.with_copy_in("held copy in", sink => f(sink.scope))
  }
}

///|
async fn check_stream_scope_exit(
  cancel~ : Bool,
  callback_exit~ : Int32,
) -> Unit {
  for kind in 0..<6 {
    // Successful drain, synchronized SQL error, and exhausted cleanup budget.
    for outcome in 0..<3 {
      with_control_pool(
        if outcome == 1 {
          HoldStreamError
        } else {
          HoldStream
        },
        (group, pool, probe) => {
          let session = pool.checkout_session()
          let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
          let hold_callback : @async.Queue[Unit] = Queue(kind=Unbounded)
          defer hold_callback.close()
          let saved : @ref.Ref[StreamScope?] = Ref(None)
          let caught : @ref.Ref[Error?] = Ref(None)
          let continued = Ref(false)
          let task = group.spawn(allow_failure=true, () => {
            let result = try
              run_cancel_stream(session, kind, scope => {
                saved.val = Some(scope)
                entered.put(())
                match callback_exit {
                  1 => raise PoolError::InvalidConfig("callback exception")
                  2 => hold_callback.get()
                  _ => ()
                }
                7
              })
            catch {
              error => Err(error)
            } noraise {
              value => Ok(value)
            }
            match result {
              Err(error) => {
                caught.val = Some(error)
                raise error
              }
              Ok(value) => {
                continued.val = true
                value
              }
            }
          })
          entered.get()
          if callback_exit == 2 {
            task.cancel()
          }
          probe.query_started.get()
          if callback_exit != 2 {
            assert_false(saved.val.unwrap().active.val)
          }
          assert_true(pool.shared.slots.try_get() is None)
          if cancel && callback_exit != 2 {
            task.cancel()
          }
          if outcome != 2 {
            probe.release_query.put(())
          }
          let cancelled = callback_exit == 2 || (cancel && callback_exit == 0)
          let returns = !cancelled &&
            callback_exit == 0 &&
            (outcome == 0 || (kind == 5 && outcome == 1))
          if returns {
            assert_eq(task.wait(), 7)
          } else {
            let error = expect_pgpool_error_async(() => task.wait())
            if cancelled {
              assert_true(error is @async.WaitedTaskAlreadyCancelled)
              assert_true(caught.val is None)
            } else if callback_exit == 1 {
              assert_true(
                error is PoolError::InvalidConfig("callback exception"),
              )
            } else if outcome == 1 {
              assert_true(
                error
                is @client.ClientError::Database({ code: Some("22012"), .. }),
              )
            } else {
              assert_true(error is PoolError::Timeout(Cleanup))
            }
          }
          assert_eq(continued.val, returns)
          let scope = saved.val.unwrap()
          assert_false(scope.active.val)
          assert_true(scope.gate.try_acquire())
          scope.gate.release()
          assert_eq(session.state.active_ops.val, 0)
          assert_true(session.state.gate.try_acquire())
          session.state.gate.release()
          assert_eq(
            count_callback_requests(probe.requests, b'C'),
            if kind < 2 && outcome != 2 {
              1
            } else {
              0
            },
          )
          assert_eq(
            count_callback_requests(probe.requests, b'f'),
            if kind == 5 {
              1
            } else {
              0
            },
          )
          assert_eq(session.state.cleanup_deadline.val is None, returns)
          let connection = session.state.connection
          session.release()
          assert_eq(pool.status().available, if outcome == 2 { 0 } else { 1 })
          assert_returned_capacity(pool)
          let next = pool.checkout_session()
          assert_eq(next.state.connection.id == connection.id, outcome != 2)
          next.batch_execute("next")
          next.release()
          assert_returned_capacity(pool)
        },
        cleanup_ms=if outcome == 2 { 40 } else { 1000 },
      )
    }
  }
}

///|
async test "stream and COPY return propagate cancellation before cleanup errors or caller continuation" {
  check_stream_scope_exit(cancel=true, callback_exit=0)
}

///|
async test "stream and COPY return preserve results and synchronized SQL errors without cancellation" {
  check_stream_scope_exit(cancel=false, callback_exit=0)
}

///|
async test "stream and COPY callback exception wins over later cancellation and cleanup failure" {
  check_stream_scope_exit(cancel=true, callback_exit=1)
}

///|
async test "stream and COPY callback cancellation remains native after cleanup" {
  check_stream_scope_exit(cancel=true, callback_exit=2)
}

///|
async test "stream callback exception keeps priority over cancellation during Close" {
  with_control_pool(HoldClose, (group, pool, probe) => {
    let task = group.spawn(allow_failure=true, () => {
      let _ : Unit = pool.with_stream("select 0", _ => {
        raise PoolError::InvalidConfig("callback exception")
      })
    })
    probe.close_started.get()
    task.cancel()
    probe.release_close.put(())
    assert_true(
      expect_pgpool_error_async(() => task.wait())
      is PoolError::InvalidConfig("callback exception"),
    )
    assert_eq(count_callback_requests(probe.requests, b'C'), 1)
    assert_eq(pool.status().available, 1)
    assert_returned_capacity(pool)
  })
}
