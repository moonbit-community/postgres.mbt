///|
/// Config normalization remains independent of opening a database connection.
test "integration pool config constructors and normalization" {
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

  let pool_config = @pgpool.PoolConfig::new(
    2,
    timeouts=@pgpool.Timeouts::new(
      wait_ms=Some(10),
      create_ms=Some(20),
      recycle_ms=Some(30),
    ),
    queue_mode=@pgpool.QueueMode::lifo(),
    recycling_method=@pgpool.RecyclingMethod::verified(),
    statement_cache_capacity=7,
  )
  assert_eq(pool_config.max_size, 2)
  assert_eq(pool_config.statement_cache_capacity, 7)
  @debug.assert_eq(pool_config.timeouts.wait_ms, Some(10))

  let config = @pgpool.Config::new(
    "one.db",
    hostaddrs=["10.0.0.1", "10.0.0.2"],
    ports=[1111, 2222],
    user="moon",
    dbname="moondb",
    ssl_mode=VerifyCa,
    ssl_root_cert="/tmp/root.crt",
    application_name="pool-config-extra",
    hosts=["two.db"],
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
/// Invalid capacity, timeout, and TLS settings fail before a pool starts.
test "integration pool config validation rejects invalid settings" {
  let invalid_max_size = @test.expect_error(() => @pgpool.PoolConfig::new(0))
  guard invalid_max_size is @pgpool.PoolError::InvalidConfig(message) else {
    fail("expected invalid max size")
  }
  assert_eq(message, "pool max_size must be at least 1")

  let invalid_cache = @test.expect_error(() => {
    @pgpool.PoolConfig::new(1, statement_cache_capacity=-1)
  })
  guard invalid_cache is @pgpool.PoolError::InvalidConfig(cache_message) else {
    fail("expected invalid cache capacity")
  }
  assert_eq(cache_message, "statement_cache_capacity must be non-negative")

  let disabled_cache = @pgpool.PoolConfig::new(1, statement_cache_capacity=0)
  assert_eq(disabled_cache.statement_cache_capacity, 0)

  let invalid_timeout = @test.expect_error(() => {
    @pgpool.PoolConfig::new(1, timeouts=@pgpool.Timeouts::new(wait_ms=Some(-1)))
  })
  guard invalid_timeout is @pgpool.PoolError::InvalidConfig(timeout_message) else {
    fail("expected invalid timeout")
  }
  assert_eq(timeout_message, "pool wait_ms must be non-negative")

  let invalid_tls = @test.expect_error(() => {
    @pgpool.Config::new(
      "db.example",
      user="moon",
      dbname="moondb",
      ssl_mode=VerifyCa,
      ssl_root_cert="system",
      application_name="pool-system-root-extra",
      pool=@pgpool.PoolConfig::new(1),
    ).get_connection_targets()
  })
  guard invalid_tls is @pgpool.ConfigError::InvalidConfig(tls_message) else {
    fail("expected TLS validation error")
  }
  assert_eq(tls_message, "sslrootcert=system requires sslmode=verify-full")
}

///|
/// A custom Connector receives the TaskGroup that must own the auto-driven
/// client. Multi-target checkout continues after a failed first target.
async test "integration pool custom connector supports target failover" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let attempts : Array[Int] = []
    let connector = @pgpool.Connector::new((target, driver_group) => {
      if attempts.length() == 0 {
        attempts.push(1)
        let bad_target = @client.Config::from_parts(
          target.host,
          target.hostaddr,
          0,
          target.user,
          target.database,
          target.password,
          target.ssl_mode,
          target.ssl_root_cert,
          target.channel_binding,
          target.application_name,
          target.options,
          Some(100),
          target.keepalives,
          target.keepalives_idle_s,
        )
        @client.connect(bad_target, driver_group)
      } else {
        @client.connect(target, driver_group)
      }
    })
    let declarative = @pgpool.Config::new(
      config.host,
      user=config.user,
      dbname=config.database,
      password=config.password,
      port=config.port,
      application_name="moonbit-postgres-pool-failover",
      hosts=[config.host],
      ports=[config.port, config.port],
      pool=@pgpool.PoolConfig::new(1),
    )
    let pool = @pgpool.Pool::new(
      declarative,
      group,
      options=@pgpool.PoolOptions::new(connector~),
    )

    let value : Int = pool
      .query_one("select 29::int4 as value")
      .get_name("value")
    assert_eq(value, 29)
    assert_eq(attempts.length(), 1)
    pool.close()
  })
}
