///|
/// Build pool config in one place so each test does not spell out timeout and queue settings again.
/// Defaults stay minimal and each test overrides only the wait, create, or recycle behavior it cares about.
fn make_pool_config(
  max_size : Int,
  wait_ms? : Int? = None,
  create_ms? : Int? = None,
  recycle_ms? : Int? = None,
  queue_mode? : @pgpool.QueueMode = @pgpool.QueueMode::fifo(),
) -> @pgpool.PoolConfig raise {
  @pgpool.PoolConfig::new(
    max_size,
    timeouts=@pgpool.Timeouts::new(wait_ms~, create_ms~, recycle_ms~),
    queue_mode~,
  )
}

///|
/// These assertion helpers give the pool error branches a fixed shape.
/// The tests can focus on concurrency timing and state transitions instead of unpacking error enums over and over.
fn[T] expect_pool_wait_timeout(result : Result[T, Error]) -> Unit raise {
  guard result is Err(@pgpool.PoolError::Timeout(@pgpool.TimeoutKind::Wait)) else {
    fail("expected pool wait timeout")
  }
}

///|
/// Verify that the pool has been closed.
fn[T] expect_pool_closed(result : Result[T, Error]) -> Unit raise {
  guard result is Err(@pgpool.PoolError::Closed) else {
    fail("expected closed pool error")
  }
}

///|
/// Verify that a lease has been released and can no longer be used for new work.
fn[T] expect_pool_lease_released(result : Result[T, Error]) -> Unit raise {
  guard result is Err(@pgpool.PoolError::LeaseReleased) else {
    fail("expected released lease error")
  }
}

///|
/// Verify that mutually exclusive operations do not overlap on the same connection.
fn[T] expect_pool_operation_in_progress(
  result : Result[T, Error],
) -> Unit raise {
  guard result is Err(@pgpool.PoolError::OperationInProgress) else {
    fail("expected operation-in-progress error")
  }
}

///|
/// Verify that the async timeout wrapper really ends in a timeout error.
fn[T] expect_async_timeout(result : Result[T, Error]) -> Unit raise {
  guard result is Err(@async.TimeoutError) else {
    fail("expected async timeout")
  }
}

///|
/// This helper creates the case where the outer wait times out but the underlying query is still running.
/// Later tests use it to check whether the pool can converge back to a clean protocol state between timeout and release.
async fn run_timeout_wrapped_pool_query(
  pool : @pgpool.Pool,
  long_sql : String,
) -> Result[Int, Error] {
  try? @async.with_timeout(200, () => {
    let value : Int = pool.with_client(client => {
      let value : Int = client.query_one(long_sql).get_name("value")
      value
    })
    value
  })
}

///|
/// This verifies the most basic checkout path for the pool.
/// It creates a pool of size 1, runs one query, and checks the result to show that `with_client` checks out, uses, and returns the connection correctly.
async test "integration pool with_client query" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )

    let value : Int = pool.with_client(client => {
      client.query_one("select 42::int4 as value").get_name("value")
    })
    assert_eq(value, 42)

    pool.close()
  })
}

///|
/// This verifies that when the only connection is busy, a second checkout waits instead of preempting it.
/// The test holds one lease, starts a second task, checks that it stays pending, and then confirms that it continues after release.
async test "integration pool waits for release" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )
    // Hold the only connection first so the next request has to wait.
    let lease = pool.get()

    let waiter = group.spawn(no_wait=true, () => {
      pool.with_client(client => {
        let value : Int = client
          .query_one("select 7::int4 as value")
          .get_name("value")
        value
      })
    })

    wait_for_pool_waiters_or_fail(
      pool, 1, "expected second checkout to register as waiting",
    )
    lease.release()
    assert_eq(
      wait_for_task_or_fail(waiter, "expected waiting checkout to finish"),
      7,
    )

    pool.close()
  })
}

///|
/// This verifies that `timeout_get` maps "no free connection became available" to a wait-timeout error.
/// The setup is simple: hold the only connection, then try to borrow again with a short timeout.
async test "integration pool timeout_get reports wait timeout" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )
    let lease = pool.get()

    expect_pool_wait_timeout(
      try? pool.timeout_get(@pgpool.Timeouts::new(wait_ms=Some(0))),
    )

    lease.release()
    pool.close()
  })
}

///|
/// This verifies that with pool size 2, a long query does not block an independent query on another connection.
/// One connection enters `pg_sleep`, while the second runs a short query and proves that the two sessions are isolated.
async test "integration pool supports session isolation with two connections" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let long_sql = "select pg_sleep(2), 1::int4 as value"
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(2),
    )
    let (observer, observer_connection) = @client.connect(
      as_client_config(
        config,
        application_name="moonbit-postgres-pool-observer",
      ),
    )
    group.spawn_bg(() => observer_connection.run())
    defer observer.close()

    let warm0 = pool.get()
    let warm1 = pool.get()
    wait_for_pool_size_or_fail(
      pool, 2, "expected pool to warm two physical connections",
    )
    warm0.release()
    warm1.release()

    let lease = pool.get()
    defer lease.release()
    let backend_pid : Int = lease
      .query_one("select pg_backend_pid()::int4 as pid")
      .get_name("pid")

    let long_task = group.spawn(no_wait=true, () => {
      let value : Int = lease.query_one(long_sql).get_name("value")
      value
    })
    wait_for_backend_query(observer, backend_pid, long_sql)

    // If the pool fails to open a second connection, this would block until the timeout fires.
    let short_value : Int = @async.with_timeout(1000, () => {
      pool.with_client(client => {
        client.query_one("select 2::int4 as value").get_name("value")
      })
    })
    assert_eq(short_value, 2)
    assert_eq(
      wait_for_task_or_fail(long_task, "expected long query to finish"),
      1,
    )

    pool.close()
  })
}

///|
/// This verifies that clean recycling clears session-level state before a connection is reused.
/// The test changes `search_path`, then borrows the same backend again and checks that the pid stayed the same while the session setting was reset.
async test "integration pool clean recycle resets session state" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let application_name = "moonbit-postgres-pool-clean"
    let pool = make_pool(
      group,
      as_client_config(config, application_name~),
      make_pool_config(1),
      manager=@pgpool.ManagerConfig::new(
        recycling_method=@pgpool.RecyclingMethod::clean(),
      ),
    )

    // Deliberately dirty the session state during the first checkout.
    let (before_pid, before_search_path) = pool.with_client(client => {
      let backend_pid : Int = client
        .query_one("select pg_backend_pid()::int4 as pid")
        .get_name("pid")
      let search_path : String = client
        .query_one("select current_setting('search_path')::text as search_path")
        .get_name("search_path")
      client.batch_execute("set search_path = pg_catalog")
      (backend_pid, search_path)
    })
    // On the second checkout, the recycle logic should already have restored the session state.
    let (after_pid, after_search_path) = pool.with_client(client => {
      let backend_pid : Int = client
        .query_one("select pg_backend_pid()::int4 as pid")
        .get_name("pid")
      let search_path : String = client
        .query_one("select current_setting('search_path')::text as search_path")
        .get_name("search_path")
      (backend_pid, search_path)
    })

    assert_eq(after_pid, before_pid)
    assert_eq(after_search_path, before_search_path)

    pool.close()
  })
}

///|
/// This verifies that when the pool closes, already borrowed clients can finish their current work while blocked checkouts wake up with a closed error.
/// That covers both graceful shutdown for active borrowers and refusal of new work still waiting in line.
async test "integration pool close wakes blocked checkout and borrowed client can finish" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )
    let lease = pool.get()

    // Hold the connection first, then let the second checkout block behind it.
    let waiter = group.spawn(no_wait=true, () => try? pool.get())
    wait_for_pool_waiters_or_fail(
      pool, 1, "expected blocked checkout to register as waiting",
    )

    pool.close()

    // A borrowed lease should still be allowed to finish its current query after pool close.
    let value : Int = lease
      .query_one("select 9::int4 as value")
      .get_name("value")
    assert_eq(value, 9)
    expect_pool_closed(waiter.wait())

    lease.release()
    assert_eq(pool.status().closed, true)
    assert_eq(pool.status().size, 0)
  })
}

///|
/// This verifies that when a borrowed connection is killed by the server, the pool discards the broken connection and restores capacity.
/// The test gets the backend pid, calls `pg_terminate_backend`, then checks that the old lease fails and a fresh lease works.
async test "integration pool restores capacity after leased client connection dies" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1, wait_ms=Some(200)),
    )
    let lease = pool.get()
    let backend_pid : Int = lease
      .query_one("select pg_backend_pid()::int4 as pid")
      .get_name("pid")
    let (observer, observer_connection) = @client.connect(
      as_client_config(
        config,
        application_name="moonbit-postgres-pool-terminate-observer",
      ),
    )
    group.spawn_bg(() => observer_connection.run())

    // The observer connection terminates the borrowed backend from the database side.
    let terminate_params : Array[&@client.ToSql] = [
      backend_pid as &@client.ToSql,
    ]
    let terminated : Bool = observer
      .query_one(
        "select pg_terminate_backend($1)::bool as terminated",
        params=terminate_params,
      )
      .get_name("terminated")
    assert_eq(terminated, true)
    guard (try? lease.query_one("select 1::int4 as value")) is Err(_) else {
      fail("expected terminated backend to break leased client")
    }

    // Once the broken lease is released, pool size should drop to 0 first, and the next checkout should trigger replacement.
    lease.release()
    assert_eq(pool.status().size, 0)

    let replacement = pool.get()
    let value : Int = replacement
      .query_one("select 5::int4 as value")
      .get_name("value")
    assert_eq(value, 5)
    replacement.release()

    pool.close()
    observer.close()
  })
}

///|
/// This verifies that after an outer timeout, the pool does not hand out a connection that is still converging back to a clean state.
/// The query keeps running in the database, `timeout_get` still cannot borrow the connection, and only after cleanup does the connection become reusable.
async test "integration pool timeout waits for protocol-safe release" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let long_sql = "select pg_sleep(2), 1::int4 as value"
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )
    let (observer, observer_connection) = @client.connect(
      as_client_config(
        config,
        application_name="moonbit-postgres-pool-timeout-observer",
      ),
    )
    group.spawn_bg(() => observer_connection.run())
    defer observer.close()
    // Get the backend pid for the long query so the observer can confirm it reached `pg_sleep`.
    let backend_pid : Int = pool.with_client(client => {
      client.query_one("select pg_backend_pid()::int4 as pid").get_name("pid")
    })

    // This task times out after 200ms on the outside, while the database-side query keeps running for a while.
    let timed : @async.Task[Result[Int, Error]] = group.spawn(no_wait=true, () => {
      run_timeout_wrapped_pool_query(pool, long_sql)
    })
    wait_for_backend_query(observer, backend_pid, long_sql)

    // Until cleanup finishes, the pool must not make this connection borrowable again.
    let wait_timeout = try? pool.timeout_get(
      @pgpool.Timeouts::new(wait_ms=Some(0)),
    )
    let timed_result = wait_for_task_or_fail(
      timed, "expected timed operation to finish",
    )
    expect_pool_wait_timeout(wait_timeout)
    expect_async_timeout(timed_result)

    let value : Int = pool.with_client(client => {
      client.query_one("select 11::int4 as value").get_name("value")
    })
    assert_eq(value, 11)

    pool.close()
  })
}

///|
/// This verifies that calling `release` while a lease still has active work does not return the connection to the pool immediately.
/// The test starts a long query, releases the lease, checks that other checkouts still time out, and then confirms the connection becomes available only after the query ends.
async test "integration pool lease release waits for active operation to finish" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let long_sql = "select pg_sleep(1), 1::int4 as value"
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )
    let lease = pool.get()
    let backend_pid : Int = lease
      .query_one("select pg_backend_pid()::int4 as pid")
      .get_name("pid")
    let (observer, observer_connection) = @client.connect(
      as_client_config(
        config,
        application_name="moonbit-postgres-pool-active-op-observer",
      ),
    )
    group.spawn_bg(() => observer_connection.run())
    defer observer.close()

    let query_task = group.spawn(no_wait=true, () => {
      let value : Int = lease.query_one(long_sql).get_name("value")
      value
    })
    wait_for_backend_query(observer, backend_pid, long_sql)

    // Releasing while the query is still running is the core delayed-return case.
    lease.release()
    let wait_timeout = try? pool.timeout_get(
      @pgpool.Timeouts::new(wait_ms=Some(0)),
    )
    expect_pool_wait_timeout(wait_timeout)
    assert_eq(
      wait_for_task_or_fail(query_task, "expected active query to finish"),
      1,
    )

    let value : Int = pool.with_client(client => {
      client.query_one("select 3::int4 as value").get_name("value")
    })
    assert_eq(value, 3)

    pool.close()
  })
}

///|
/// This verifies that `run_cancellable` blocks overlapping work on the same connection.
/// Inside the cancellable scope, a plain query, a nested cancellable scope, and a second query through the same `op` should all fail with `OperationInProgress`.
async test "integration pool run_cancellable rejects overlapping work" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let long_sql = "select pg_sleep(1), 1::int4 as value"
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )
    let (observer, observer_connection) = @client.connect(
      as_client_config(
        config,
        application_name="moonbit-postgres-pool-cancellable-overlap-observer",
      ),
    )
    group.spawn_bg(() => observer_connection.run())
    defer observer.close()

    pool.with_client(client => {
      client.run_cancellable((op, _) => {
        // Once the scope starts, the original client handle must not start new protocol work.
        expect_pool_operation_in_progress(
          try? client.query_one("select 1::int4 as value"),
        )
        // The cancellable scope itself must not be re-entered either.
        expect_pool_operation_in_progress(
          try? client.run_cancellable((_, _) => 1),
        )

        // While the long query is running, another query on the same `op` must also be blocked.
        let backend_pid : Int = op
          .query_one("select pg_backend_pid()::int4 as pid")
          .get_name("pid")
        let query_task = group.spawn(no_wait=true, () => {
          try? op.query_one(long_sql)
        })
        wait_for_backend_query(observer, backend_pid, long_sql)
        expect_pool_operation_in_progress(
          try? op.query_one("select 2::int4 as value"),
        )

        let row_result = wait_for_task_or_fail(
          query_task, "expected cancellable scoped query to finish",
        )
        guard row_result is Ok(row) else {
          fail("expected cancellable scoped query success")
        }
        let value : Int = row.get_name("value")
        assert_eq(value, 1)
      })
    })

    pool.close()
  })
}

///|
/// This verifies that the cancel token exposed by `run_cancellable` really interrupts an active query.
/// The test sends the backend pid and token back to the parent task, cancels only after the query is confirmed running, and then checks that the connection can still be reused.
async test "integration pool run_cancellable cancels running query" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let long_sql = "select pg_sleep(5), 1::int4 as value"
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )
    let pid_queue : @async.Queue[Int] = @async.Queue::new(kind=Unbounded)
    let token_queue : @async.Queue[@pgpool.OperationCancelToken] = @async.Queue::new(
      kind=Unbounded,
    )
    let (observer, observer_connection) = @client.connect(
      as_client_config(
        config,
        application_name="moonbit-postgres-pool-cancellable-cancel-observer",
      ),
    )
    group.spawn_bg(() => observer_connection.run())
    defer observer.close()

    // Borrow the connection in a child task and publish the context needed for cancellation.
    let task = group.spawn(no_wait=true, () => {
      try? pool.with_client(client => {
        client.run_cancellable((op, token) => {
          let backend_pid : Int = op
            .query_one("select pg_backend_pid()::int4 as pid")
            .get_name("pid")
          pid_queue.put(backend_pid)
          token_queue.put(token)
          let value : Int = op.query_one(long_sql).get_name("value")
          value
        })
      })
    })

    let backend_pid = pid_queue.get()
    let token = token_queue.get()
    // Confirm that the long query is really holding the connection before canceling it.
    wait_for_backend_query(observer, backend_pid, long_sql)
    let wait_timeout = try? pool.timeout_get(
      @pgpool.Timeouts::new(wait_ms=Some(0)),
    )
    token.cancel()
    let task_result = wait_for_task_or_fail(
      task, "expected cancellable task to finish",
    )

    expect_pool_wait_timeout(wait_timeout)
    let err = expect_database_error(task_result)
    assert_eq(err.code, Some("57014"))
    let value : Int = pool.with_client(client => {
      client.query_one("select 11::int4 as value").get_name("value")
    })
    assert_eq(value, 11)

    pool.close()
  })
}

///|
/// This verifies that if the lease is released while a cancellable operation is still cleaning up, the pool still waits for cleanup before returning the connection.
/// The sequence is: start a long query, release the lease, prove that other checkouts still cannot borrow, cancel the query, then confirm that the connection becomes usable again.
async test "integration pool release waits for cancellable cleanup" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let long_sql = "select pg_sleep(5), 1::int4 as value"
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )
    let lease = pool.get()
    let backend_pid : Int = lease
      .query_one("select pg_backend_pid()::int4 as pid")
      .get_name("pid")
    let token_queue : @async.Queue[@pgpool.OperationCancelToken] = @async.Queue::new(
      kind=Unbounded,
    )
    let (observer, observer_connection) = @client.connect(
      as_client_config(
        config,
        application_name="moonbit-postgres-pool-cancellable-release-observer",
      ),
    )
    group.spawn_bg(() => observer_connection.run())
    defer observer.close()

    let task = group.spawn(no_wait=true, () => {
      try? lease.run_cancellable((op, token) => {
        token_queue.put(token)
        let value : Int = op.query_one(long_sql).get_name("value")
        value
      })
    })

    let token = token_queue.get()
    wait_for_backend_query(observer, backend_pid, long_sql)
    // Release first and cancel later to cover cleanup when those two actions interleave.
    lease.release()
    let wait_timeout = try? pool.timeout_get(
      @pgpool.Timeouts::new(wait_ms=Some(0)),
    )
    token.cancel()
    let task_result = wait_for_task_or_fail(
      task, "expected released cancellable lease task to finish",
    )

    expect_pool_wait_timeout(wait_timeout)
    let err = expect_database_error(task_result)
    assert_eq(err.code, Some("57014"))
    let value : Int = pool.with_client(client => {
      client.query_one("select 3::int4 as value").get_name("value")
    })
    assert_eq(value, 3)

    pool.close()
  })
}

///|
/// This verifies that a stale cancel token cannot cancel newer work that later reuses the same physical connection.
/// The test first captures an old token, then runs a new long query on the same backend pid, triggers the stale token, and checks that the new query still finishes normally.
async test "integration pool stale cancel token cannot cancel reused connection" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let long_sql = "select pg_sleep(1), 2::int4 as value"
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )
    let stale_token_queue : @async.Queue[@pgpool.OperationCancelToken] = @async.Queue::new(
      kind=Unbounded,
    )
    let pid_queue : @async.Queue[Int] = @async.Queue::new(kind=Unbounded)
    let (observer, observer_connection) = @client.connect(
      as_client_config(
        config,
        application_name="moonbit-postgres-pool-cancellable-stale-observer",
      ),
    )
    group.spawn_bg(() => observer_connection.run())

    // The first cancellable scope exists only to capture a token that will later become stale.
    let first_pid : Int = pool.with_client(client => {
      client.run_cancellable((op, token) => {
        stale_token_queue.put(token)
        op.query_one("select pg_backend_pid()::int4 as pid").get_name("pid")
      })
    })
    let stale_token = stale_token_queue.get()

    let task = group.spawn(no_wait=true, () => {
      pool.with_client(client => {
        client.run_cancellable((op, _) => {
          let backend_pid : Int = op
            .query_one("select pg_backend_pid()::int4 as pid")
            .get_name("pid")
          pid_queue.put(backend_pid)
          let value : Int = op.query_one(long_sql).get_name("value")
          value
        })
      })
    })

    // Reuse the same physical connection on purpose to show that cancellation protection depends on the current generation, not just the pid.
    let second_pid = pid_queue.get()
    assert_eq(second_pid, first_pid)
    wait_for_backend_query(observer, second_pid, long_sql)
    stale_token.cancel()
    assert_eq(
      wait_for_task_or_fail(task, "expected reused connection query to finish"),
      2,
    )

    pool.close()
    observer.close()
  })
}

///|
/// This verifies that pool close, blocked-checkout wakeup, and cancellable-query cancellation still converge to a clean state when they happen together.
/// The point is not a single error code. The point is that the waiter sees a closed error, the long query sees a cancellation error, and the pool ends closed with no leftover connections.
async test "integration pool close wakes blocked checkout while cancellable task converges" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let long_sql = "select pg_sleep(5), 1::int4 as value"
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )
    let pid_queue : @async.Queue[Int] = @async.Queue::new(kind=Unbounded)
    let token_queue : @async.Queue[@pgpool.OperationCancelToken] = @async.Queue::new(
      kind=Unbounded,
    )
    let (observer, observer_connection) = @client.connect(
      as_client_config(
        config,
        application_name="moonbit-postgres-pool-cancellable-close-observer",
      ),
    )
    group.spawn_bg(() => observer_connection.run())

    let task = group.spawn(no_wait=true, () => {
      try? pool.with_client(client => {
        client.run_cancellable((op, token) => {
          let backend_pid : Int = op
            .query_one("select pg_backend_pid()::int4 as pid")
            .get_name("pid")
          pid_queue.put(backend_pid)
          token_queue.put(token)
          let value : Int = op.query_one(long_sql).get_name("value")
          value
        })
      })
    })

    let backend_pid = pid_queue.get()
    let token = token_queue.get()
    wait_for_backend_query(observer, backend_pid, long_sql)

    // The waiter must enter the queue first, otherwise there is nothing to wake up on pool close.
    let waiter = group.spawn(no_wait=true, () => try? pool.get())
    wait_for_pool_waiters_or_fail(
      pool, 1, "expected blocked checkout to register as waiting before close",
    )

    pool.close()
    token.cancel()

    expect_pool_closed(
      wait_for_task_or_fail(waiter, "expected blocked checkout to wake"),
    )
    let err = expect_database_error(
      wait_for_task_or_fail(
        task, "expected cancellable task to finish after pool close",
      ),
    )
    assert_eq(err.code, Some("57014"))
    assert_eq(pool.status().closed, true)
    assert_eq(pool.status().size, 0)

    observer.close()
  })
}

///|
/// This verifies that the statement cache on one pooled connection reuses identical SQL and supports explicit clearing.
/// The test covers both untyped and typed cached statements, then checks how the cache size changes.
async test "integration pool cached prepared statements reuse and clear" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )

    pool.with_client(client => {
      // The repeated SQL should reuse one cache entry, while the typed query adds a second one.
      let first : Int = client.with_prepared_cached(
        "select 1 + $1::int4 as value",
        prepared => prepared.query_one(params=[2]).get_name("value"),
      )
      let second : Int = client.with_prepared_cached(
        "select 1 + $1::int4 as value",
        prepared => {
          prepared.query_one(params=[3 as &@client.ToSql]).get_name("value")
        },
      )
      let typed : Int = client.with_prepared_typed_cached(
        "select $1::int4 as value",
        [@client.Type::int4()],
        prepared => {
          prepared.query_one(params=[9 as &@client.ToSql]).get_name("value")
        },
      )
      assert_eq(first, 3)
      assert_eq(second, 4)
      assert_eq(typed, 9)
      let cache = client.statement_cache()
      assert_eq(cache.size(), 2)
      cache.clear()
      assert_eq(cache.size(), 0)
    })

    pool.close()
  })
}

///|
/// This verifies that the cache collection exposed by the pool manager reaches leases that are currently checked out.
/// Two active leases each create cached statements, the manager clears them, and both leases should immediately observe empty caches.
async test "integration pool clear statement caches reaches active leases" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(2),
    )
    let lease0 = pool.get()
    let lease1 = pool.get()

    let value0 : Int = lease0.with_prepared_cached("select 11::int4 as value", prepared => {
      prepared.query_one().get_name("value")
    })
    let value1 : Int = lease1.with_prepared_cached("select 22::int4 as value", prepared => {
      prepared.query_one().get_name("value")
    })
    assert_eq(value0, 11)
    assert_eq(value1, 22)
    let caches = pool.manager().statement_caches()
    assert_eq(lease0.statement_cache().size(), 1)
    assert_eq(lease1.statement_cache().size(), 1)

    caches.clear()

    assert_eq(lease0.statement_cache().size(), 0)
    assert_eq(lease1.statement_cache().size(), 0)
    lease0.release()
    lease1.release()
    pool.close()
  })
}

///|
/// This verifies that removing one cache entry by SQL only removes the target statement and leaves unrelated entries intact.
/// The test creates two cached statements, removes one, and then runs the other again to show that it is still cached.
async test "integration pool remove cached statement keeps unrelated entries" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )

    pool.with_client(client => {
      let one : Int = client.with_prepared_cached("select 1::int4 as value", prepared => {
        prepared.query_one().get_name("value")
      })
      let two : Int = client.with_prepared_cached("select 2::int4 as value", prepared => {
        prepared.query_one().get_name("value")
      })
      assert_eq(one, 1)
      assert_eq(two, 2)
      let cache = client.statement_cache()
      assert_eq(cache.size(), 2)
      pool.manager().statement_caches().remove("select 1::int4 as value")
      assert_eq(cache.size(), 1)
      let still_cached : Int = client.with_prepared_cached(
        "select 2::int4 as value",
        prepared => prepared.query_one().get_name("value"),
      )
      assert_eq(still_cached, 2)
    })

    pool.close()
  })
}

///|
/// This verifies that the pool-side transaction builder really applies isolation level, read-only, and deferrable options to the database session.
/// The test reads them back with `current_setting`, then performs a write to show that the transaction object itself still works.
async test "integration pool transaction builder applies options" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )

    let (isolation, read_only, deferrable) = pool.with_client(client => {
      client
      .build_transaction()
      .isolation_level(@pgpool.IsolationLevel::serializable())
      .read_only()
      .deferrable()
      .run(tx => {
        let isolation : String = tx
          .query_one(
            "select current_setting('transaction_isolation')::text as value",
          )
          .get_name("value")
        let read_only : String = tx
          .query_one(
            "select current_setting('transaction_read_only')::text as value",
          )
          .get_name("value")
        let deferrable : String = tx
          .query_one(
            "select current_setting('transaction_deferrable')::text as value",
          )
          .get_name("value")
        (isolation, read_only, deferrable)
      })
    })

    assert_eq(isolation, "serializable")
    assert_eq(read_only, "on")
    assert_eq(deferrable, "on")
    pool.close()
  })
}

///|
/// This verifies that a failure inside a savepoint rolls back only the savepoint's work and does not discard work that already completed in the outer transaction.
/// The test inserts one row outside the savepoint, inserts another row inside it, then triggers an error and checks that only the first row remains.
async test "integration pool savepoint rollback keeps outer transaction work" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )

    let count : Int = pool.with_client(client => {
      client
      .build_transaction()
      .run(tx => {
        tx.batch_execute(
          "create temp table moon_pool_savepoint (value int4 not null) on commit drop",
        )
        ignore(tx.execute("insert into moon_pool_savepoint (value) values (1)"))
        // Trigger an error on purpose so the savepoint rolls back without rolling back the whole transaction.
        let nested : Result[Unit, Error] = try? tx.with_savepoint(
          "inner_step",
          inner => {
            ignore(
              inner.execute(
                "insert into moon_pool_savepoint (value) values (2)",
              ),
            )
            inner.batch_execute(
              "insert into definitely_missing_table (value) values (3)",
            )
          },
        )
        guard nested is Err(_) else {
          fail("expected savepoint callback rollback")
        }
        tx
        .query_one("select count(*)::int4 as count from moon_pool_savepoint")
        .get_name("count")
      })
    })

    assert_eq(count, 1)
    pool.close()
  })
}

///|
/// This verifies that a statement handle returned by `with_prepared` is valid only inside the callback scope.
/// The test keeps the handle past the callback and then checks that it fails with a released-lease error instead of continuing to run.
async test "integration pool prepared statement expires after callback scope" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )
    let queue : @async.Queue[@pgpool.PreparedStatement] = @async.Queue::new(
      kind=Unbounded,
    )

    let value : Int = pool.with_client(client => {
      client.with_prepared("select 13::int4 as value", prepared => {
        queue.put(prepared)
        prepared.query_one().get_name("value")
      })
    })
    assert_eq(value, 13)
    let stale = queue.get()
    expect_pool_lease_released(try? stale.query_one())

    pool.close()
  })
}

///|
/// This verifies that when a transaction handle is kept directly, the connection stays checked out until commit.
/// The test starts a transaction, releases the outer lease, shows that the pool still cannot hand out a new connection, and then checks that checkout resumes after commit.
async test "integration pool direct transaction keeps lease checked out until commit" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )
    let lease = pool.get()
    let tx = lease
      .build_transaction()
      .isolation_level(@pgpool.IsolationLevel::serializable())
      .start()

    let isolation : String = tx
      .query_one(
        "select current_setting('transaction_isolation')::text as value",
      )
      .get_name("value")
    assert_eq(isolation, "serializable")

    // Releasing the outer lease is not the same as ending the transaction, so the connection should still be occupied by the transaction.
    lease.release()
    expect_pool_lease_released(try? lease.query_one("select 1::int4 as value"))

    let waiter = group.spawn(no_wait=true, () => try? pool.get())
    assert_task_stays_pending(
      waiter, "expected open transaction to keep lease checked out",
    )

    tx.commit()

    let next_result = wait_for_task_or_fail(
      waiter, "expected checkout to resume after commit",
    )
    guard next_result is Ok(next) else {
      fail("expected checkout after direct transaction commit")
    }
    let value : Int = next
      .query_one("select 1::int4 as value")
      .get_name("value")
    assert_eq(value, 1)
    next.release()
    pool.close()
  })
}

///|
/// This verifies that when a savepoint handle is used directly, it can be rolled back on its own without affecting the outer transaction.
/// The test inserts base data, inserts a second row inside the savepoint, rolls back that savepoint, and checks that only the first row survives commit.
async test "integration pool direct savepoint handle rolls back independently" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )

    let count : Int = pool.with_client(client => {
      let tx = client.transaction()
      tx.batch_execute(
        "create temp table moon_pool_savepoint_direct (value int4 not null) on commit drop",
      )
      ignore(
        tx.execute("insert into moon_pool_savepoint_direct (value) values (1)"),
      )

      let nested = tx.savepoint("inner_direct")
      ignore(
        nested.execute(
          "insert into moon_pool_savepoint_direct (value) values (2)",
        ),
      )
      nested.rollback()

      let count : Int = tx
        .query_one(
          "select count(*)::int4 as count from moon_pool_savepoint_direct",
        )
        .get_name("count")
      tx.commit()
      count
    })

    assert_eq(count, 1)
    pool.close()
  })
}

///|
/// This verifies that a transaction's own statement cache only controls the current connection and the current transaction.
/// The test creates a cache entry, removes one entry, recreates it, and clears the cache, checking the size at each step.
async test "integration pool transaction cache controls current connection" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )

    pool.with_client(client => {
      let tx = client.transaction()

      let value : Int = tx.with_prepared_cached("select 31::int4 as value", prepared => {
        prepared.query_one().get_name("value")
      })
      assert_eq(value, 31)
      let cache = tx.statement_cache()
      assert_eq(cache.size(), 1)

      cache.remove("select 31::int4 as value")
      assert_eq(cache.size(), 0)

      let recreated : Int = tx.with_prepared_cached(
        "select 31::int4 as value",
        prepared => prepared.query_one().get_name("value"),
      )
      assert_eq(recreated, 31)
      assert_eq(cache.size(), 1)

      cache.clear()
      assert_eq(cache.size(), 0)
      tx.rollback()
    })

    pool.close()
  })
}

///|
/// This verifies that once a lease is released, it cannot be used to start new work.
/// The test is short, but it underpins many concurrency tests: handles must become invalid as soon as their lifetime ends.
async test "integration pool released lease rejects new work" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )
    let lease = pool.get()

    lease.release()
    expect_pool_lease_released(try? lease.query_one("select 1::int4 as value"))

    pool.close()
  })
}
