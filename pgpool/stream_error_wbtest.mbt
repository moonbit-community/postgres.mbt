///|
async fn consume_error_stream(
  mode : Int32,
  next : async () -> Bool,
  finish : async () -> Unit,
  detach : () -> Unit,
) -> Unit {
  match mode {
    0 =>
      while next() {
        ()
      }
    1 => finish()
    2 => ()
    _ => detach()
  }
}

///|
async fn failing_pool_stream(
  session : Session,
  kind : Int32,
  mode : Int32,
) -> Unit {
  async fn rows(stream : RowStream) -> Unit {
    consume_error_stream(
      mode,
      () => stream.next() is Some(_),
      () => ignore(stream.finish()),
      () => stream.raw.detach(),
    )
  }
  match kind {
    0 => session.with_stream("stream error", rows)
    1 => session.with_typed_stream("stream error", [], rows)
    2 =>
      session.with_prepared("stream error", prepared => {
        prepared.with_stream(rows)
      })
    3 =>
      session.with_simple_query("stream error", stream => {
        consume_error_stream(
          mode,
          () => stream.next() is Some(_),
          () => stream.finish(),
          () => stream.raw.detach(),
        )
      })
    _ =>
      session.with_copy_out("copy error", stream => {
        consume_error_stream(
          mode,
          () => stream.next() is Some(_),
          () => stream.finish(),
          () => stream.raw.detach(),
        )
      })
  }
}

///|
async test "pooled SQL stream errors preserve the session after read finish early return and background drain" {
  for kind in 0..<5 {
    for mode in 0..<4 {
      with_control_pool(StreamError, (_, pool, probe) => {
        pool.with_session(session => {
          let connection = session.state.connection.id
          assert_true(
            expect_pgpool_error_async(() => {
              failing_pool_stream(session, kind, mode)
            })
            is @client.ClientError::Database({ code: Some("22012"), .. }),
          )
          assert_false(session.state.scoped_client().is_closed())
          assert_true(session.state.connection.failure.val is None)
          session.batch_execute("healthy")
          assert_eq(session.state.connection.id, connection)
        })
        assert_eq(pool.status().size, 1)
        assert_eq(pool.status().available, 1)
        pool.batch_execute("next borrower")
        assert_true(probe.cancel_started.try_get() is None)
      })
    }
  }
}

///|
async test "SQL errors without protocol completion retire the socket and restore capacity" {
  for kind in 0..<5 {
    for fault in [StreamErrorNoReady, StreamErrorDisconnect] {
      with_control_pool(
        fault,
        (_, pool, _) => {
          let retired : @ref.Ref[ConnectionState?] = Ref(None)
          let started = @async.now()
          let error = expect_pgpool_error_async(() => {
            pool.with_session(session => {
              retired.val = Some(session.state.connection)
              failing_pool_stream(session, kind, 2)
            })
          })
          assert_false(error is @client.ClientError::Database(_))
          if fault is StreamErrorNoReady {
            assert_true(error is PoolError::Timeout(Cleanup))
          }
          assert_true(@async.now() - started < 600L)
          assert_true(retired.val.unwrap().client.val is None)
          assert_eq(pool.status().size, 0)
          assert_eq(pool.status().available, 0)
          assert_true(pool.shared.slots.try_get() is Some(_))
          assert_true(pool.shared.slots.try_get() is None)
          assert_true(pool.shared.slots.try_put(()))
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
async test "failed temporary Close cannot be hidden by a SQL error or repeated stream finish" {
  for kind in [0, 1] {
    for mode in 0..<4 {
      with_control_pool(StreamCloseError, (_, pool, probe) => {
        let error = expect_pgpool_error_async(() => {
          pool.with_session(session => failing_pool_stream(session, kind, mode))
        })
        assert_true(
          error
          is @client.ClientError::Database({ message: "Close failed", .. }),
        )
        assert_eq(count_callback_requests(probe.requests, b'C'), 1)
        assert_eq(pool.status().size, 0)
        assert_true(pool.shared.slots.try_get() is Some(_))
        assert_true(pool.shared.slots.try_get() is None)
        assert_true(pool.shared.slots.try_put(()))
        pool.batch_execute("replacement")
        assert_eq(pool.status().available, 1)
      })
    }
  }
}

///|
async test "stream callback error keeps priority over SQL and Close errors" {
  for fault in [StreamError, StreamCloseError] {
    with_control_pool(fault, (_, pool, _) => {
      assert_true(
        expect_pgpool_error_async(() => {
          let _ : Unit = pool.with_stream("stream error", _ => {
            raise PoolError::InvalidConfig("callback failed")
          })
        })
        is PoolError::InvalidConfig("callback failed"),
      )
      assert_eq(
        pool.status().available,
        if fault is StreamError {
          1
        } else {
          0
        },
      )
    })
  }
}

///|
async test "completed stream cleanup is not repeated when its SQL error unwinds an exhausted budget" {
  with_control_pool(StreamError, (_, pool, _) => {
    pool.with_session(session => {
      let error = expect_pgpool_error_async(() => {
        session.run_scoped_operation((client, callback_error) => {
          resource_scope(
            session.state,
            callback_error,
            () => client.simple_query("stream error"),
            raw => {
              let error = raw.finish_scope()
              // Model successful drain at the very end of the shared budget.
              // A second cleanup must not turn this completed drain into an
              // expired-budget failure and retire the synchronized connection.
              session.state.cleanup_deadline.val = Some(Deadline::after_ms(0))
              error
            },
            (_, _) => (),
          )
        })
      })
      assert_true(
        error is @client.ClientError::Database({ code: Some("22012"), .. }),
      )
      assert_false(session.state.scoped_client().is_closed())
      assert_true(session.state.connection.failure.val is None)
      session.batch_execute("healthy")
    })
    assert_eq(pool.status().available, 1)
  })
}
