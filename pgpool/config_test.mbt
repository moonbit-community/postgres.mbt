///|
/// Config expansion remains independent of opening a database connection.
test "pool config constructors and targets" {
  guard @pgpool.QueueMode::fifo() is Fifo else {
    fail("expected fifo queue mode")
  }
  guard @pgpool.QueueMode::lifo() is Lifo else {
    fail("expected lifo queue mode")
  }
  guard @pgpool.IsolationLevel::serializable() is Serializable else {
    fail("expected serializable isolation")
  }
  guard @pgpool.RecyclingMethod::verified() is Verified else {
    fail("expected verified recycling")
  }
  guard @pgpool.RecyclingMethod::custom("reset all") is Custom(sql) else {
    fail("expected custom recycling")
  }
  assert_eq(sql, "reset all")

  let pool_config = @pgpool.PoolConfig::PoolConfig(
    2,
    timeouts=Timeouts(wait_ms=Some(10), create_ms=Some(20), recycle_ms=Some(30)),
    queue_mode=@pgpool.QueueMode::lifo(),
    recycling_method=@pgpool.RecyclingMethod::verified(),
    statement_cache_capacity=7,
  )
  assert_eq(pool_config.max_size, 2)
  assert_eq(pool_config.statement_cache_capacity, 7)
  @debug.assert_eq(pool_config.timeouts.wait_ms, Some(10))

  let config = @pgpool.Config::Config(
    [
      @pgpool.ConnectionTarget(host="one.db", hostaddr="10.0.0.1", port=1111),
      @pgpool.ConnectionTarget(host="two.db", hostaddr="10.0.0.2", port=2222),
    ],
    user="moon",
    dbname="moondb",
    ssl_mode=VerifyCa,
    ssl_root_cert="/tmp/root.crt",
    application_name="pool-config-extra",
    pool=pool_config,
  )
  let targets = config.get_connection_targets()
  assert_eq(targets.length(), 2)
  assert_eq(targets[0].host, "one.db")
  assert_eq(targets[1].host, "two.db")
  @debug.assert_eq(targets[0].hostaddr, Some("10.0.0.1"))
  @debug.assert_eq(targets[1].hostaddr, Some("10.0.0.2"))
  assert_eq(targets[0].port, 1111)
  assert_eq(targets[1].port, 2222)
  assert_true(targets[0].ssl_mode == VerifyCa)
  assert_eq(config.get_pool_config().statement_cache_capacity, 7)
}

///|
/// Constructor inputs and inspected copies must not change connection targets.
test "pool config target array is a private snapshot" {
  let configured = [
    @pgpool.ConnectionTarget(host="primary.db", hostaddr="10.0.0.1"),
    @pgpool.ConnectionTarget(host="replica.db", hostaddr="10.0.0.2", port=5433),
  ]
  let config = @pgpool.Config::Config(
    configured,
    user="moon",
    application_name="pool-target-snapshot",
    pool=PoolConfig(1),
  )
  configured[0] = @pgpool.ConnectionTarget(host="other.db", port=9999)
  configured.clear()

  let target_view = config.targets()
  let inspected_targets = target_view.to_owned()
  inspected_targets.clear()

  assert_eq(target_view.length(), 2)
  assert_eq(target_view[0].host, Some("primary.db"))
  assert_eq(target_view[1].hostaddr, Some("10.0.0.2"))
  assert_eq(target_view[0].port, 5432)
  let targets = config.get_connection_targets()
  assert_eq(targets.length(), 2)
  assert_eq(targets[0].host, "primary.db")
  assert_eq(targets[1].host, "replica.db")
  assert_eq(targets[0].hostaddr, Some("10.0.0.1"))
  assert_eq(targets[1].hostaddr, Some("10.0.0.2"))
  assert_eq(targets[0].port, 5432)
  assert_eq(targets[1].port, 5433)
}

///|
/// Invalid capacity, timeout, and TLS settings fail before a pool starts.
test "pool config validation rejects invalid settings" {
  let invalid_max_size = @test.expect_error(() => {
    @pgpool.PoolConfig::PoolConfig(0)
  })
  guard invalid_max_size is @pgpool.PoolError::InvalidConfig(message) else {
    fail("expected invalid max size")
  }
  assert_eq(message, "pool max_size must be at least 1")

  let invalid_cache = @test.expect_error(() => {
    @pgpool.PoolConfig::PoolConfig(1, statement_cache_capacity=-1)
  })
  guard invalid_cache is @pgpool.PoolError::InvalidConfig(cache_message) else {
    fail("expected invalid cache capacity")
  }
  assert_eq(cache_message, "statement_cache_capacity must be non-negative")

  let disabled_cache = @pgpool.PoolConfig::PoolConfig(
    1,
    statement_cache_capacity=0,
  )
  assert_eq(disabled_cache.statement_cache_capacity, 0)

  let invalid_timeout = @test.expect_error(() => {
    @pgpool.PoolConfig::PoolConfig(1, timeouts=Timeouts(wait_ms=Some(-1)))
  })
  guard invalid_timeout is @pgpool.PoolError::InvalidConfig(timeout_message) else {
    fail("expected invalid timeout")
  }
  assert_eq(timeout_message, "pool wait_ms must be non-negative")

  let invalid_tls = @test.expect_error(() => {
    @pgpool.Config::Config(
      [@pgpool.ConnectionTarget(host="db.example")],
      user="moon",
      dbname="moondb",
      ssl_mode=VerifyCa,
      ssl_root_cert="system",
      application_name="pool-system-root-extra",
      pool=PoolConfig(1),
    )
  })
  guard invalid_tls is @pgpool.ConfigError::InvalidConfig(tls_message) else {
    fail("expected TLS validation error")
  }
  assert_eq(tls_message, "sslrootcert=system requires sslmode=verify-full")
}
