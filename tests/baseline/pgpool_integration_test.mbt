///|
/// Build pool policy in one place for the integration tests.
fn make_pool_config(
  max_size : Int,
  wait_ms? : Int? = None,
  create_ms? : Int? = None,
  recycle_ms? : Int? = None,
  queue_mode? : @pgpool.QueueMode = @pgpool.QueueMode::fifo(),
  recycling_method? : @pgpool.RecyclingMethod = @pgpool.RecyclingMethod::fast(),
  statement_cache_capacity? : Int = 100,
) -> @pgpool.PoolConfig raise {
  @pgpool.PoolConfig::new(
    max_size,
    timeouts=@pgpool.Timeouts::new(wait_ms~, create_ms~, recycle_ms~),
    queue_mode~,
    recycling_method~,
    statement_cache_capacity~,
  )
}

///|
fn expect_pool_wait_timeout(error : Error) -> Unit raise {
  guard error is @pgpool.PoolError::Timeout(Wait) else {
    fail("expected pool wait timeout")
  }
}

///|
fn expect_pool_closed(error : Error) -> Unit raise {
  guard error is @pgpool.PoolError::Closed else {
    fail("expected closed pool error")
  }
}

///|
fn expect_pool_scope_expired(error : Error) -> Unit raise {
  guard error is @pgpool.PoolError::ScopeExpired else {
    fail("expected expired pool scope")
  }
}

///|
/// Pool-level helpers are the default API and automatically return capacity.
async test "integration pool direct query APIs" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres-pool-direct"),
      make_pool_config(2),
    )

    let one : Int = pool.query_one("select 42::int4 as value").get_name("value")
    assert_eq(one, 42)

    let rows = pool.query_all(
      "select generate_series(1, 3)::int4 as value order by value",
    )
    assert_eq(rows.length(), 3)
    assert_eq(rows[0].get_name("value"), 1)
    assert_eq(rows[2].get_name("value"), 3)

    assert_true(pool.query_opt("select 1::int4 as value where false") is None)
    pool.check_connection()
    pool.batch_execute("select 1")
    pool.close()
  })
}

///|
/// A session callback provides affinity for temp tables and other session-local
/// state without exposing manual checkout/release.
async test "integration pool with_session keeps affinity" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres-pool-session"),
      make_pool_config(1),
    )

    let value : Int = pool.with_session(session => {
      session.batch_execute(
        "create temp table moon_session_affinity(value int4)",
      )
      assert_eq(
        session.execute(
          "insert into moon_session_affinity(value) values (7), (8)",
        ),
        2,
      )
      session
      .query_one("select sum(value)::int4 as value from moon_session_affinity")
      .get_name("value")
    })
    assert_eq(value, 15)
    pool.close()
  })
}

///|
/// Pool capacity, rather than a manual lease, controls checkout waiting.
async test "integration pool direct operation observes wait timeout" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres-pool-wait"),
      make_pool_config(1, wait_ms=Some(100)),
    )
    let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
    let release : @async.Queue[Unit] = Queue(kind=Unbounded)

    let holder = group.spawn(no_wait=true, () => {
      pool.with_session(_session => {
        entered.put(())
        release.get()
      })
    })
    entered.get()

    expect_pool_wait_timeout(
      expect_error_async(() => pool.query_one("select 1::int4 as value")),
    )

    release.put(())
    holder.wait()
    let value : Int = pool
      .query_one("select 2::int4 as value")
      .get_name("value")
    assert_eq(value, 2)
    pool.close()
  })
}

///|
/// Two independent session callbacks can occupy two physical connections.
async test "integration pool supplies cross-session concurrency" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(
        config,
        application_name="moonbit-postgres-pool-concurrency",
      ),
      make_pool_config(2),
    )
    let entered : @async.Queue[Int] = Queue(kind=Unbounded)
    let release : @async.Queue[Unit] = Queue(kind=Unbounded)

    let first = group.spawn(no_wait=true, () => {
      pool.with_session(session => {
        let pid : Int = session
          .query_one("select pg_backend_pid()::int4 as pid")
          .get_name("pid")
        entered.put(pid)
        release.get()
        pid
      })
    })
    let second = group.spawn(no_wait=true, () => {
      pool.with_session(session => {
        let pid : Int = session
          .query_one("select pg_backend_pid()::int4 as pid")
          .get_name("pid")
        entered.put(pid)
        release.get()
        pid
      })
    })

    let first_pid = entered.get()
    let second_pid = entered.get()
    assert_true(first_pid != second_pid)
    release.put(())
    release.put(())
    ignore(first.wait())
    ignore(second.wait())
    pool.close()
  })
}

///|
/// A transaction owns its session until the callback ends. Work queued through
/// the outer Session must not interleave with it.
async test "integration pooled transaction blocks outer session FIFO" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres-pool-tx"),
      make_pool_config(1),
    )

    let value : Int = pool.with_session(session => {
      let waiters : @async.Queue[@async.Task[Int]] = Queue(kind=Unbounded)
      session.with_transaction(tx => {
        tx.batch_execute(
          "create temp table moon_tx_fifo(value int4); insert into moon_tx_fifo values (9)",
        )
        let task = group.spawn(no_wait=true, () => {
          session
          .query_one("select max(value)::int4 as value from moon_tx_fifo")
          .get_name("value")
        })
        waiters.put(task)
        assert_task_stays_pending(
          task, "expected outer Session call to wait until transaction completion",
        )
      })
      let task = waiters.get()
      wait_for_task_or_fail(
        task, "expected outer Session call to resume after transaction completion",
      )
    })
    assert_eq(value, 9)
    pool.close()
  })
}

///|
/// Callback-scoped handles cannot be used by a later borrower.
async test "integration stale Session raises ScopeExpired" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres-pool-scope"),
      make_pool_config(1),
    )
    let stale : @async.Queue[@pgpool.Session] = Queue(kind=Unbounded)

    pool.with_session(session => {
      stale.put(session)
      ()
    })
    let session = stale.get()
    expect_pool_scope_expired(
      expect_error_async(() => session.query_one("select 1::int4 as value")),
    )

    let probe : Int = pool
      .query_one("select 2::int4 as value")
      .get_name("value")
    assert_eq(probe, 2)
    pool.close()
  })
}

///|
/// Closing a pool rejects new direct operations.
async test "integration closed pool rejects direct operation" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres-pool-close"),
      make_pool_config(1),
    )
    pool.close()
    expect_pool_closed(
      expect_error_async(() => pool.query_one("select 1::int4 as value")),
    )
  })
}
