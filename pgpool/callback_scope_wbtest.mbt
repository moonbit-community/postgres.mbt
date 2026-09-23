// Local protocol backend for callback cancellation and statement-scope tests.

///|
/// Each test uses one physical connection. Mode 0 serves extended queries,
/// mode 1 simple queries, mode 2 COPY OUT, and mode 3 COPY IN.
async fn serve_callback_scope_connection(
  socket : @socket.Tcp,
  mode : Int,
  requests : Array[Byte],
  execute_started : @async.Queue[Unit],
  resume_execute : @async.Queue[Unit],
) -> Unit {
  defer socket.close()
  let startup = socket.read_exactly(4)
  ignore(
    socket.read_exactly(@proto.ByteReader::new(startup[:]).read_i32_be() - 4),
  )
  socket.write(b"R\x00\x00\x00\x08\x00\x00\x00\x00Z\x00\x00\x00\x05I")
  while true {
    guard socket.read_some(max_len=1) is Some(tag) else { return }
    let header = socket.read_exactly(4)
    let length = @proto.ByteReader::new(header[:]).read_i32_be()
    let payload = socket.read_exactly(length - 4)
    requests.push(tag[0])
    match tag[0] {
      b'P' => socket.write(b"1\x00\x00\x00\x04")
      b'D' => socket.write(b"t\x00\x00\x00\x06\x00\x00n\x00\x00\x00\x04")
      b'B' => socket.write(b"2\x00\x00\x00\x04")
      b'E' => {
        if mode == 4 {
          execute_started.put(())
          resume_execute.get()
        }
        socket.write(b"C\x00\x00\x00\x0dSELECT 0\x00")
      }
      b'C' =>
        if mode == 5 {
          socket.write(b"E\x00\x00\x00\x13Mclose failed\x00\x00")
        } else {
          socket.write(b"3\x00\x00\x00\x04")
        }
      b'S' => socket.write(b"Z\x00\x00\x00\x05I")
      b'Q' =>
        if mode == 2 {
          socket.write(
            b"H\x00\x00\x00\x07\x00\x00\x00d\x00\x00\x00\x06x\nc\x00\x00\x00\x04C\x00\x00\x00\x0bCOPY 1\x00Z\x00\x00\x00\x05I",
          )
        } else if mode == 3 {
          socket.write(b"G\x00\x00\x00\x07\x00\x00\x00")
        } else if payload.length() >= 5 &&
          payload[0] == b'B' &&
          payload[1] == b'E' &&
          payload[2] == b'G' &&
          payload[3] == b'I' &&
          payload[4] == b'N' {
          socket.write(b"C\x00\x00\x00\x0aBEGIN\x00Z\x00\x00\x00\x05T")
        } else {
          socket.write(b"C\x00\x00\x00\x0dSELECT 0\x00Z\x00\x00\x00\x05I")
        }
      b'f' => socket.write(b"Z\x00\x00\x00\x05I")
      b'd' | b'c' => ()
      b'X' => return
      _ => fail("unexpected callback-scope test request")
    }
  }
}

///|
async fn with_callback_scope_pool(
  mode : Int,
  cache_capacity : Int,
  f : async (
    @async.TaskGroup[Unit],
    Pool,
    Array[Byte],
    @async.Queue[Unit],
    @async.Queue[Unit],
  ) -> Unit,
) -> Unit {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let requests : Array[Byte] = []
    let execute_started : @async.Queue[Unit] = Queue(kind=Unbounded)
    let resume_execute : @async.Queue[Unit] = Queue(kind=Unbounded)
    defer resume_execute.close()
    group.spawn_bg(no_wait=true, () => {
      let (socket, _) = server.accept()
      serve_callback_scope_connection(
        socket, mode, requests, execute_started, resume_execute,
      )
    })
    let pool = start_test_pool(
      Config(
        "127.0.0.1",
        port=server.addr.port(),
        user="moon",
        ssl_mode=Disable,
        application_name="callback-scope-test",
        pool=PoolConfig(1, statement_cache_capacity=cache_capacity),
      ),
      group,
    )
    defer pool.close()
    @async.with_timeout(3000, () => {
      f(group, pool, requests, execute_started, resume_execute)
    })
  })
}

///|
fn count_callback_requests(requests : Array[Byte], tag : Byte) -> Int {
  let mut count = 0
  for request in requests {
    if request == tag {
      count += 1
    }
  }
  count
}

///|
async test "prepared callback composes session queries and nested handles at cache capacities zero and one" {
  for capacity in [0, 1] {
    with_callback_scope_pool(0, capacity, (_group, pool, requests, _, _) => {
      let session = pool.checkout_session()
      session.with_prepared("select 1", outer => {
        session.batch_execute("select 0")
        session.with_prepared("select 1", same => {
          assert_eq(same.query_all().length(), 0)
        })
        session.with_prepared("select 2", other => {
          assert_eq(other.query_all().length(), 0)
        })
        // The outer statement remains usable after its cache entry was evicted.
        assert_eq(outer.query_all().length(), 0)
      })
      assert_eq(
        count_callback_requests(requests, b'P'),
        if capacity == 0 {
          3
        } else {
          2
        },
      )
      assert_eq(
        count_callback_requests(requests, b'C'),
        if capacity == 0 {
          3
        } else {
          1
        },
      )
      assert_eq(session.state.active_ops.val, 0)
      assert_true(session.state.gate.try_acquire())
      session.state.gate.release()
      session.release()
      assert_eq(pool.status().available, 1)
    })
  }
}

///|
async test "prepared callback cancellation exits without releasing its user wait" {
  for capacity in [0, 1] {
    with_callback_scope_pool(0, capacity, (group, pool, requests, _, _) => {
      let session = pool.checkout_session()
      let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
      let waiting : @async.Queue[Unit] = Queue(kind=Unbounded)
      defer waiting.close()
      let task = group.spawn(allow_failure=true, () => {
        session.with_prepared("select 1", _ => {
          entered.put(())
          waiting.get()
        })
      })
      entered.get()
      assert_eq(session.state.active_ops.val, 1)
      assert_true(session.state.gate.try_acquire())
      session.state.gate.release()
      task.cancel()
      assert_true(
        expect_pgpool_error_async(() => task.wait()) is @async.TaskCancelled,
      )
      assert_eq(
        count_callback_requests(requests, b'C'),
        if capacity == 0 {
          1
        } else {
          0
        },
      )
      assert_eq(session.state.active_ops.val, 0)
      session.check_connection()
      session.release()
      assert_eq(pool.status().available, 1)
    })
  }
}

///|
async test "stream and COPY callbacks cancel while waiting for user work" {
  for mode in 0..<4 {
    with_callback_scope_pool(mode, 0, (group, pool, requests, _, _) => {
      let session = pool.checkout_session()
      let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
      let waiting : @async.Queue[Unit] = Queue(kind=Unbounded)
      defer waiting.close()
      let task = group.spawn(allow_failure=true, () => {
        match mode {
          0 =>
            session.with_stream("select 1", _ => {
              entered.put(())
              waiting.get()
            })
          1 =>
            session.with_simple_query("select 1", _ => {
              entered.put(())
              waiting.get()
            })
          2 =>
            session.with_copy_out("COPY t TO STDOUT", _ => {
              entered.put(())
              waiting.get()
            })
          _ =>
            session.with_copy_in("COPY t FROM STDIN", _ => {
              entered.put(())
              waiting.get()
            })
        }
      })
      entered.get()
      assert_false(session.state.gate.try_acquire())
      task.cancel()
      assert_true(
        expect_pgpool_error_async(() => task.wait()) is @async.TaskCancelled,
      )
      if mode == 0 {
        assert_eq(count_callback_requests(requests, b'C'), 1)
      }
      if mode == 3 {
        assert_eq(count_callback_requests(requests, b'f'), 1)
      }
      assert_eq(session.state.active_ops.val, 0)
      assert_true(session.state.gate.try_acquire())
      session.state.gate.release()
      session.check_connection()
      session.release()
      assert_eq(pool.status().available, 1)
    })
  }
}

///|
async test "run_cancellable callback cancels its user wait and expires its token" {
  with_callback_scope_pool(0, 1, (group, pool, _requests, _, _) => {
    let session = pool.checkout_session()
    let entered : @async.Queue[OperationCancelToken] = Queue(kind=Unbounded)
    let waiting : @async.Queue[Unit] = Queue(kind=Unbounded)
    defer waiting.close()
    let task = group.spawn(allow_failure=true, () => {
      session.run_cancellable((_, token) => {
        entered.put(token)
        waiting.get()
      })
    })
    let token = entered.get()
    // Model a cancel packet that entered its protected send just before the
    // callback was cancelled. Scope exit must wait for it before reuse.
    token.state.cancel_in_flight.val = 1
    task.cancel()
    while !token.state.closing.val {
      @async.pause()
    }
    assert_true(task.try_wait() is None)
    assert_eq(session.state.active_ops.val, 1)
    assert_false(session.state.gate.try_acquire())
    token.state.cancel_in_flight.val = 0
    assert_true(
      expect_pgpool_error_async(() => task.wait()) is @async.TaskCancelled,
    )
    token.cancel()
    assert_eq(session.state.active_ops.val, 0)
    session.check_connection()
    session.release()
    assert_eq(pool.status().available, 1)
  })
}

///|
async test "prepared scope rejects late calls but waits for a started query" {
  for capacity in [0, 1] {
    with_callback_scope_pool(4, capacity, (
      group,
      pool,
      requests,
      execute_started,
      resume_execute,
    ) => {
      let session = pool.checkout_session()
      let saved : @async.Queue[PreparedStatement] = Queue(kind=Unbounded)
      let query_tasks : @async.Queue[@async.Task[Unit]] = Queue(kind=Unbounded)
      let scope = group.spawn(() => {
        session.with_prepared("select 1", prepared => {
          saved.put(prepared)
          let query = group.spawn(() => {
            assert_eq(prepared.query_all().length(), 0)
          })
          query_tasks.put(query)
          while prepared.state.active_calls.val == 0 {
            @async.pause()
          }
        })
      })
      let prepared = saved.get()
      let query = query_tasks.get()
      execute_started.get()
      while prepared.state.active.val {
        @async.pause()
      }
      assert_true(scope.try_wait() is None)
      assert_eq(prepared.state.active_calls.val, 1)
      assert_true(
        expect_pgpool_error_async(() => prepared.query_all())
        is PoolError::ScopeExpired,
      )
      assert_false(session.state.gate.try_acquire())
      resume_execute.put(())
      query.wait()
      scope.wait()
      assert_eq(prepared.state.active_calls.val, 0)
      assert_eq(
        count_callback_requests(requests, b'C'),
        if capacity == 0 {
          1
        } else {
          0
        },
      )
      assert_eq(session.state.active_ops.val, 0)
      session.release()
      assert_eq(pool.status().available, 1)
    })
  }
}

///|
async test "prepared cleanup propagates its own error and preserves callback errors" {
  for callback_fails in [false, true] {
    with_callback_scope_pool(5, 0, (_group, pool, requests, _, _) => {
      let session = pool.checkout_session()
      let error = expect_pgpool_error_async(() => {
        session.with_prepared("select 1", _ => {
          if callback_fails {
            raise PoolError::ScopeExpired
          }
        })
      })
      if callback_fails {
        assert_true(error is PoolError::ScopeExpired)
      } else {
        assert_true(error is @client.ClientError::Database(_))
      }
      assert_eq(count_callback_requests(requests, b'C'), 1)
      assert_eq(session.state.active_ops.val, 0)
      session.release()
      assert_eq(pool.status().size, 0)
      assert_true(pool.shared.slots.try_get() is Some(_))
    })
  }
}

///|
async test "transaction prepared callback cancellation rolls back before release" {
  for capacity in [0, 1] {
    with_callback_scope_pool(0, capacity, (group, pool, requests, _, _) => {
      let session = pool.checkout_session()
      let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
      let waiting : @async.Queue[Unit] = Queue(kind=Unbounded)
      defer waiting.close()
      let task = group.spawn(allow_failure=true, () => {
        session.with_transaction(tx => {
          tx.with_prepared("select 1", _ => {
            entered.put(())
            waiting.get()
          })
        })
      })
      entered.get()
      task.cancel()
      assert_true(
        expect_pgpool_error_async(() => task.wait()) is @async.TaskCancelled,
      )
      assert_eq(count_callback_requests(requests, b'Q'), 2)
      assert_eq(
        count_callback_requests(requests, b'C'),
        if capacity == 0 {
          1
        } else {
          0
        },
      )
      assert_eq(session.state.active_ops.val, 0)
      session.check_connection()
      session.release()
      assert_eq(pool.status().available, 1)
    })
  }
}
