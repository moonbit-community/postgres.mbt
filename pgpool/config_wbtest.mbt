///|
test "pool config new builds defaults and appended hosts" {
  let config = Config::Config(
    "primary.db",
    user="moon",
    dbname="moondb",
    application_name="pool-config-test",
    hosts=["replica.db"],
    target_session_attrs=TargetSessionAttrs::read_write(),
    load_balance_hosts=Random,
    pool=PoolConfig(2),
  )
  let targets = config.get_connection_targets()
  @debug.assert_eq(targets.length(), 2)
  @debug.assert_eq(targets[0].host, "primary.db")
  @debug.assert_eq(targets[1].host, "replica.db")
  @debug.assert_eq(targets[0].port, 5432)
  @debug.assert_eq(targets[1].port, 5432)
  assert_true(targets[0].ssl_mode == VerifyFull)
  assert_true(targets[0].channel_binding == Disable)
  assert_true(
    config.target_session_attrs == Some(TargetSessionAttrs::read_write()),
  )
  assert_true(config.load_balance_hosts == Some(Random))
  @debug.assert_eq(targets[0].application_name, "pool-config-test")
  @debug.assert_eq(targets[1].application_name, "pool-config-test")
}

///|
test "pool config broadcasts explicit ports" {
  let config = Config::Config(
    "db.example",
    user="moon",
    dbname="moondb",
    password="secret",
    port=7000,
    application_name="pool-explicit-port",
    hosts=["replica.example"],
    pool=PoolConfig(1),
  )
  let targets = config.get_connection_targets()
  @debug.assert_eq(targets.length(), 2)
  @debug.assert_eq(targets[0].host, "db.example")
  @debug.assert_eq(targets[1].host, "replica.example")
  @debug.assert_eq(targets[0].port, 7000)
  @debug.assert_eq(targets[1].port, 7000)
  @debug.assert_eq(targets[0].password, Some("secret"))
  assert_true(targets[0].ssl_mode == VerifyFull)
}

///|
test "pool config keeps explicit tls settings" {
  let config = Config::Config(
    "db.example",
    user="moon",
    dbname="moondb",
    ssl_mode=VerifyCa,
    ssl_root_cert="/tmp/root.crt",
    application_name="pool-tls",
    pool=PoolConfig(1),
  )
  let target = config.get_connection_targets()[0]
  assert_true(target.ssl_mode == VerifyCa)
  @debug.assert_eq(target.ssl_root_cert, Some("/tmp/root.crt"))
}

///|
test "pool config broadcasts hostaddr to every host" {
  let config = Config::Config(
    "one.db",
    hostaddr="10.0.0.1",
    user="moon",
    dbname="moondb",
    application_name="pool-hostaddr",
    hosts=["two.db"],
    pool=PoolConfig(1),
  )
  let targets = config.get_connection_targets()
  @debug.assert_eq(targets[0].hostaddr, Some("10.0.0.1"))
  @debug.assert_eq(targets[1].hostaddr, Some("10.0.0.1"))
}

///|
test "pool config broadcasts one host across per-target ports" {
  let targets = Config::Config(
    "db.example",
    user="moon",
    dbname="moondb",
    application_name="pool-host-broadcast",
    ports=[5432, 5433],
    pool=PoolConfig(1),
  ).get_connection_targets()
  @debug.assert_eq(targets.length(), 2)
  @debug.assert_eq(targets[0].host, "db.example")
  @debug.assert_eq(targets[1].host, "db.example")
  @debug.assert_eq(targets[0].port, 5432)
  @debug.assert_eq(targets[1].port, 5433)
}

///|
test "pool config rejects mismatched multi-target arrays" {
  let result = @test.expect_error(() => {
    Config::Config(
      "one.db",
      user="moon",
      dbname="moondb",
      application_name="pool-target-arity",
      hosts=["two.db"],
      ports=[5432, 5433, 5434],
      pool=PoolConfig(1),
    ).get_connection_targets()
  })
  guard result is ConfigError::HostPortArityMismatch else {
    fail("expected host/port arity mismatch")
  }
}

///|
test "pool config validates verify_full identity for every target" {
  let result = @test.expect_error(() => {
    Config::Config(
      "valid.db",
      user="moon",
      dbname="moondb",
      application_name="pool-target-identity",
      hosts=[""],
      pool=PoolConfig(1),
    ).get_connection_targets()
  })
  guard result is ConfigError::InvalidConfig(message) else {
    fail("expected per-target verify-full identity error")
  }
  @debug.assert_eq(
    message, "sslmode=verify-full requires explicit host or hostaddr",
  )
}

///|
test "pool config validates every target port" {
  let result = @test.expect_error(() => {
    Config::Config(
      "db.example",
      user="moon",
      dbname="moondb",
      application_name="pool-target-port",
      ports=[5432, 0],
      pool=PoolConfig(1),
    ).get_connection_targets()
  })
  guard result is ConfigError::InvalidConfig(message) else {
    fail("expected per-target port validation error")
  }
  @debug.assert_eq(message, "port must be between 1 and 65535")
}

///|
test "pool config constructor still reports empty user name" {
  let result = @test.expect_error(() => {
    Config::Config(
      "db.example",
      user="",
      dbname="moondb",
      application_name="pool-missing-user",
      pool=PoolConfig(1),
    ).get_connection_targets()
  })
  guard result is ConfigError::UsernameEmpty else {
    fail("expected username empty")
  }
}

///|
test "pool config constructor still reports empty dbname" {
  let result = @test.expect_error(() => {
    Config::Config(
      "db.example",
      user="moon",
      dbname="",
      application_name="pool-empty-dbname",
      pool=PoolConfig(1),
    ).get_connection_targets()
  })
  guard result is ConfigError::DbnameEmpty else {
    fail("expected empty dbname")
  }
}

///|
test "pool config requires explicit host for verify_full" {
  let result = @test.expect_error(() => {
    Config::Config(
      "",
      user="moon",
      dbname="moondb",
      application_name="pool-verify-full-host",
      pool=PoolConfig(1),
    ).get_connection_targets()
  })
  guard result is ConfigError::InvalidConfig(message) else {
    fail("expected verify-full host validation error")
  }
  @debug.assert_eq(
    message, "sslmode=verify-full requires explicit host or hostaddr",
  )
}

///|
test "pool config accepts hostaddr identity when host is empty" {
  let targets = Config::Config(
    "",
    hostaddr="10.0.0.1",
    user="moon",
    dbname="moondb",
    application_name="pool-verify-full-hostaddr",
    pool=PoolConfig(1),
  ).get_connection_targets()
  @debug.assert_eq(targets[0].host, "")
  @debug.assert_eq(targets[0].hostaddr, Some("10.0.0.1"))
}

///|
test "pool config rejects sslrootcert system without verify_full" {
  let result = @test.expect_error(() => {
    Config::Config(
      "db.example",
      user="moon",
      dbname="moondb",
      ssl_mode=VerifyCa,
      ssl_root_cert="system",
      application_name="pool-system-root",
      pool=PoolConfig(1),
    ).get_connection_targets()
  })
  guard result is ConfigError::InvalidConfig(message) else {
    fail("expected sslrootcert validation error")
  }
  @debug.assert_eq(message, "sslrootcert=system requires sslmode=verify-full")
}

///|
async test "pool new updates status and config without connecting" {
  @async.with_task_group(group => {
    let config = Config::Config(
      "db.example",
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
        "db.example",
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
        "db.example",
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
        "db.example",
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
