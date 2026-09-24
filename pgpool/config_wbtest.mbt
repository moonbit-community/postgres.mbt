///|
test "pool config preserves ordered target records and common defaults" {
  let config = Config::Config(
    [ConnectionTarget(host="primary.db"), ConnectionTarget(host="replica.db")],
    user="moon",
    dbname="moondb",
    application_name="pool-config-test",
    target_session_attrs=TargetSessionAttrs::read_write(),
    load_balance_hosts=Random,
    pool=PoolConfig(2),
  )
  let configured = config.targets()
  assert_eq(configured.length(), 2)
  assert_eq(configured[0].host, Some("primary.db"))
  assert_eq(configured[1].host, Some("replica.db"))
  assert_eq(configured[0].port, 5432)
  let targets = config.get_connection_targets()
  assert_eq(targets.length(), 2)
  assert_eq(targets[0].host, "primary.db")
  assert_eq(targets[1].host, "replica.db")
  assert_eq(targets[0].port, 5432)
  assert_eq(targets[1].port, 5432)
  assert_true(targets[0].ssl_mode == VerifyFull)
  assert_true(targets[0].channel_binding == Disable)
  assert_eq(config.target_session_attrs, Some(TargetSessionAttrs::read_write()))
  assert_eq(config.load_balance_hosts, Some(Random))
  assert_eq(targets[0].application_name, "pool-config-test")
  assert_eq(targets[1].application_name, "pool-config-test")
}

///|
test "pool config keeps independent ports and mixed address forms" {
  let config = Config::Config(
    [
      ConnectionTarget(host="db.example", hostaddr="10.0.0.1", port=7000),
      ConnectionTarget(hostaddr="10.0.0.2", port=7001),
      ConnectionTarget(host="replica.example", port=7002),
    ],
    user="moon",
    password="secret",
    application_name="pool-target-addresses",
    pool=PoolConfig(1),
  )
  let targets = config.get_connection_targets()
  assert_eq(targets.length(), 3)
  assert_eq(targets[0].host, "db.example")
  assert_eq(targets[0].hostaddr, Some("10.0.0.1"))
  assert_eq(targets[0].port, 7000)
  assert_eq(targets[1].host, "")
  assert_eq(targets[1].hostaddr, Some("10.0.0.2"))
  assert_eq(targets[1].port, 7001)
  assert_eq(targets[2].host, "replica.example")
  assert_eq(targets[2].hostaddr, None)
  assert_eq(targets[2].port, 7002)
  assert_eq(targets[0].password, Some("secret"))
  assert_eq(targets[0].database, "moon")
}

///|
test "pool config keeps explicit tls settings" {
  let config = Config::Config(
    [ConnectionTarget(host="db.example")],
    user="moon",
    dbname="moondb",
    ssl_mode=VerifyCa,
    ssl_root_cert="/tmp/root.crt",
    application_name="pool-tls",
    pool=PoolConfig(1),
  )
  let target = config.get_connection_targets()[0]
  assert_true(target.ssl_mode == VerifyCa)
  assert_eq(target.ssl_root_cert, Some("/tmp/root.crt"))
}

///|
test "pool config rejects an empty target list at construction" {
  let error = @test.expect_error(() => {
    Config::Config(
      [],
      user="moon",
      application_name="pool-empty-targets",
      pool=PoolConfig(1),
    )
  })
  guard error is ConfigError::InvalidConfig(message) else {
    fail("expected empty target error")
  }
  assert_eq(message, "targets must not be empty")
}

///|
test "pool config rejects missing addresses with a target index" {
  let error = @test.expect_error(() => {
    Config::Config(
      [
        ConnectionTarget(host="valid.db"),
        ConnectionTarget(host="", hostaddr=""),
      ],
      user="moon",
      ssl_mode=Disable,
      application_name="pool-target-address",
      pool=PoolConfig(1),
    )
  })
  guard error is ConfigError::InvalidConfig(message) else {
    fail("expected target address error")
  }
  assert_eq(message, "target 1: host or hostaddr must be non-empty")
}

///|
test "pool config rejects invalid ports with a target index" {
  for port in [0, 65536] {
    let error = @test.expect_error(() => {
      Config::Config(
        [
          ConnectionTarget(host="valid.db"),
          ConnectionTarget(hostaddr="10.0.0.2", port~),
        ],
        user="moon",
        application_name="pool-target-port",
        pool=PoolConfig(1),
      )
    })
    guard error is ConfigError::InvalidConfig(message) else {
      fail("expected target port error")
    }
    assert_eq(message, "target 1: port must be between 1 and 65535")
  }
}

///|
test "pool config validates user and database at construction" {
  let invalid_user = @test.expect_error(() => {
    Config::Config(
      [ConnectionTarget(host="db.example")],
      user="",
      application_name="pool-missing-user",
      pool=PoolConfig(1),
    )
  })
  assert_true(invalid_user is ConfigError::UsernameEmpty)
  let invalid_db = @test.expect_error(() => {
    Config::Config(
      [ConnectionTarget(host="db.example")],
      user="moon",
      dbname="",
      application_name="pool-empty-dbname",
      pool=PoolConfig(1),
    )
  })
  assert_true(invalid_db is ConfigError::DbnameEmpty)
}

///|
test "pool config validates TLS at construction" {
  let error = @test.expect_error(() => {
    Config::Config(
      [ConnectionTarget(host="db.example")],
      user="moon",
      ssl_mode=VerifyCa,
      ssl_root_cert="system",
      application_name="pool-system-root",
      pool=PoolConfig(1),
    )
  })
  guard error is ConfigError::InvalidConfig(message) else {
    fail("expected sslrootcert validation error")
  }
  assert_eq(message, "sslrootcert=system requires sslmode=verify-full")
}

///|
async test "pool new updates status and config without connecting" {
  @async.with_task_group(group => {
    let config = Config::Config(
      [ConnectionTarget(host="db.example")],
      user="moon",
      dbname="moondb",
      application_name="pool-new",
      pool=PoolConfig(
        3,
        timeouts=Timeouts(
          wait_ms=Some(11),
          create_ms=Some(22),
          recycle_ms=Some(33),
        ),
        queue_mode=QueueMode::lifo(),
        recycling_method=RecyclingMethod::verified(),
        statement_cache_capacity=7,
      ),
    )
    let pool = start_test_pool(config, group)
    let timeouts = pool.timeouts()
    @debug.assert_eq(pool.status().max_size, 3)
    @debug.assert_eq(timeouts.wait_ms, Some(11))
    @debug.assert_eq(timeouts.create_ms, Some(22))
    @debug.assert_eq(timeouts.recycle_ms, Some(33))
    assert_true(pool.config().recycling_method == RecyclingMethod::verified())
    assert_eq(pool.config().statement_cache_capacity, 7)
    assert_false(pool.is_closed())
    pool.close()
    assert_true(pool.is_closed())
  })
}

///|
async test "pool resize shrinks unopened checkout capacity" {
  @async.with_task_group(group => {
    let pool = start_test_pool(
      Config(
        [ConnectionTarget(host="db.example")],
        user="moon",
        dbname="moondb",
        application_name="pool-resize",
        pool=PoolConfig(3),
      ),
      group,
    )
    pool.resize(1)
    assert_true(pool.shared.slots.try_get() is Some(_))
    assert_true(pool.shared.slots.try_get() is None)
    pool.close()
  })
}

///|
async test "pool resize debt prevents capacity from reappearing during expansion" {
  @async.with_task_group(group => {
    let pool = start_test_pool(
      Config(
        [ConnectionTarget(host="db.example")],
        user="moon",
        dbname="moondb",
        application_name="pool-resize-debt",
        pool=PoolConfig(3),
      ),
      group,
    )
    assert_true(pool.shared.slots.try_get() is Some(_))
    assert_true(pool.shared.slots.try_get() is Some(_))
    assert_true(pool.shared.slots.try_get() is Some(_))

    pool.resize(1)
    assert_eq(pool.shared.resize_debt.val, 2)
    pool.resize(2)
    assert_eq(pool.shared.resize_debt.val, 1)
    assert_true(pool.shared.slots.try_get() is None)

    release_capacity(pool.shared)
    assert_eq(pool.shared.resize_debt.val, 0)
    assert_true(pool.shared.slots.try_get() is None)
    release_capacity(pool.shared)
    assert_true(pool.shared.slots.try_get() is Some(_))
    assert_true(pool.shared.slots.try_get() is None)
    release_capacity(pool.shared)
    assert_true(pool.shared.slots.try_get() is Some(_))
    assert_true(pool.shared.slots.try_get() is None)
    pool.close()
  })
}

///|
async test "pool expansion adds only capacity beyond resize debt" {
  @async.with_task_group(group => {
    let pool = start_test_pool(
      Config(
        [ConnectionTarget(host="db.example")],
        user="moon",
        dbname="moondb",
        application_name="pool-resize-expand-beyond-debt",
        pool=PoolConfig(3),
      ),
      group,
    )
    assert_true(pool.shared.slots.try_get() is Some(_))
    assert_true(pool.shared.slots.try_get() is Some(_))
    assert_true(pool.shared.slots.try_get() is Some(_))

    pool.resize(1)
    assert_eq(pool.shared.resize_debt.val, 2)
    pool.resize(4)
    assert_eq(pool.shared.resize_debt.val, 0)
    assert_true(pool.shared.slots.try_get() is Some(_))
    assert_true(pool.shared.slots.try_get() is None)
    pool.close()
  })
}

///|
test "pool config validates statement cache capacity" {
  assert_eq(PoolConfig::PoolConfig(1).statement_cache_capacity, 100)
  assert_eq(
    PoolConfig::PoolConfig(1, statement_cache_capacity=0).statement_cache_capacity,
    0,
  )
  let error = @test.expect_error(() => {
    ignore(PoolConfig::PoolConfig(1, statement_cache_capacity=-1))
  })
  guard error is PoolError::InvalidConfig(message) else {
    fail("expected invalid statement cache capacity")
  }
  assert_eq(message, "statement_cache_capacity must be non-negative")
}
