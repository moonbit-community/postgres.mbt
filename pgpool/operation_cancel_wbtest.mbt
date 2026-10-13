///|
async test "wait zero includes an executor that never started" {
  let (pool, _) = Pool::create(
    Config(
      [ConnectionTarget(host="unused")],
      user="moon",
      application_name="wait-zero",
      pool=PoolConfig(1),
    ),
  )
  defer pool.close()
  assert_true(
    expect_pgpool_error_async(() => {
      pool.with_session(_ => (), timeouts=Timeouts(wait_ms=Some(0)))
    })
    is PoolError::Timeout(Wait),
  )
  assert_eq(pool.status().size, 0)
  assert_eq(pool.status().waiting, 0)
  pool.close()
  assert_true(pool.next_event() is None)
}

///|
async test "deadline includes executor readiness" {
  let (pool, _) = Pool::create(
    Config(
      [ConnectionTarget(host="unused")],
      user="moon",
      application_name="wait-deadline",
      pool=PoolConfig(1),
    ),
  )
  defer pool.close()
  assert_true(
    expect_pgpool_error_async(() => {
      pool.with_session(_ => (), deadline=Deadline::after_ms(10))
    })
    is PoolError::Timeout(Wait),
  )
}

///|
async test "single flight rejects concurrent work and restores its scope" {
  with_callback_scope_pool(4, 1, (group, pool, _, started, continue_query) => {
    pool.with_session(session => {
      let task = group.spawn(() => session.query_all("select 1"))
      started.get()
      assert_true(
        expect_pgpool_error_async(() => session.check_connection())
        is PoolError::OperationInProgress,
      )
      continue_query.put(())
      assert_eq(task.wait().length(), 0)
      session.check_connection()
    })
  })
}
