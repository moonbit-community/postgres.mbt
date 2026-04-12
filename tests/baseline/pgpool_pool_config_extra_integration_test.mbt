///|
/// This verifies declarative config normalization for explicit arrays and constructor defaults.
/// The test is intentionally pure so coverage can hit config code paths without needing a live database.
test "integration pool config constructors and normalization" {
  guard @pgpool.QueueMode::fifo() is Fifo else {
    fail("expected fifo queue mode")
  }
  guard @pgpool.QueueMode::lifo() is Lifo else {
    fail("expected lifo queue mode")
  }
  guard @pgpool.IsolationLevel::read_uncommitted() is ReadUncommitted else {
    fail("expected read uncommitted")
  }
  guard @pgpool.IsolationLevel::read_committed() is ReadCommitted else {
    fail("expected read committed")
  }
  guard @pgpool.IsolationLevel::repeatable_read() is RepeatableRead else {
    fail("expected repeatable read")
  }
  guard @pgpool.IsolationLevel::serializable() is Serializable else {
    fail("expected serializable")
  }
  guard @pgpool.RecyclingMethod::fast() is Fast else {
    fail("expected fast recycling")
  }
  guard @pgpool.RecyclingMethod::verified() is Verified else {
    fail("expected verified recycling")
  }
  guard @pgpool.RecyclingMethod::clean() is Clean else {
    fail("expected clean recycling")
  }
  guard @pgpool.RecyclingMethod::custom("reset all") is Custom(sql) else {
    fail("expected custom recycling")
  }
  assert_eq(sql, "reset all")

  let config = @pgpool.Config::new(
    "one.db",
    hostaddrs=["10.0.0.1", "10.0.0.2"],
    ports=[1111, 2222],
    user="moon",
    dbname="moondb",
    ssl_mode=@client.SslMode::VerifyCa,
    ssl_root_cert="/tmp/root.crt",
    application_name="pool-config-extra",
    hosts=["two.db"],
    pool=@pgpool.PoolConfig::new(2),
  )
  let targets = config.get_connection_targets()
  assert_eq(targets.length(), 2)
  assert_eq(targets[0].host, "one.db")
  assert_eq(targets[1].host, "two.db")
  assert_eq(targets[0].hostaddr, Some("10.0.0.1"))
  assert_eq(targets[1].hostaddr, Some("10.0.0.2"))
  assert_eq(targets[0].port, 1111)
  assert_eq(targets[1].port, 2222)
  assert_true(targets[0].ssl_mode == @client.SslMode::VerifyCa)
  assert_eq(targets[0].ssl_root_cert, Some("/tmp/root.crt"))
  assert_true(
    config.get_manager_config().recycling_method ==
    @pgpool.RecyclingMethod::fast(),
  )
}

///|
/// This verifies that config validation rejects invalid pool settings and TLS combinations before any connection opens.
test "integration pool config validation rejects invalid settings" {
  let invalid_max_size : Result[@pgpool.PoolConfig, Error] = try? @pgpool.PoolConfig::new(
    0,
  )
  guard invalid_max_size
    is Err(@pgpool.PoolError::InvalidConfig(max_size_message)) else {
    fail("expected invalid max size")
  }
  assert_eq(max_size_message, "pool max_size must be at least 1")

  let invalid_timeout : Result[@pgpool.PoolConfig, Error] = try? @pgpool.PoolConfig::new(
    1,
    timeouts=@pgpool.Timeouts::new(wait_ms=Some(-1)),
  )
  guard invalid_timeout
    is Err(@pgpool.PoolError::InvalidConfig(timeout_message)) else {
    fail("expected invalid timeout")
  }
  assert_eq(timeout_message, "pool wait_ms must be non-negative")

  let invalid_tls : Result[Array[@client.Config], Error] = try? @pgpool.Config::new(
    "db.example",
    user="moon",
    dbname="moondb",
    ssl_mode=@client.SslMode::VerifyCa,
    ssl_root_cert="system",
    application_name="pool-system-root-extra",
    pool=@pgpool.PoolConfig::new(1),
  ).get_connection_targets()
  guard invalid_tls is Err(@pgpool.ConfigError::InvalidConfig(tls_message)) else {
    fail("expected tls validation error")
  }
  assert_eq(tls_message, "sslrootcert=system requires sslmode=verify-full")
}

///|
/// This verifies builder hooks, LIFO idle reuse, resize behavior, and a custom connector over a real PostgreSQL server.
/// It also exercises `target_session_attrs=read_write` and random host ordering on multi-target declarative config.
async test "integration pool builder hooks resize and custom connector" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let connect_calls : Array[Int] = []
    let post_create_calls : Array[Int] = []
    let pre_recycle_calls : Array[Int] = []
    let post_recycle_calls : Array[Int] = []

    let connector = @pgpool.Connector::new(target => {
      connect_calls.push(1)
      @client.connect(target)
    })
    let pool = @pgpool.Config::new(
        config.host,
        user=config.user,
        dbname=config.database,
        password=config.password,
        port=config.port,
        application_name="moonbit-postgres-pool-builder-extra",
        hosts=[config.host],
        ports=[config.port, config.port],
        target_session_attrs=@pgpool.TargetSessionAttrs::read_write(),
        load_balance_hosts=@pgpool.LoadBalanceHosts::Random,
        pool=@pgpool.PoolConfig::new(1),
      )
      .builder(group)
      .config(@pgpool.PoolConfig::new(2))
      .wait_timeout(Some(11))
      .create_timeout(Some(2_000))
      .recycle_timeout(Some(2_000))
      .queue_mode(@pgpool.QueueMode::lifo())
      .manager_config(
        @pgpool.ManagerConfig::new(
          recycling_method=@pgpool.RecyclingMethod::verified(),
        ),
      )
      .connector(connector)
      .post_create(client => {
        post_create_calls.push(1)
        client.check_connection()
      })
      .pre_recycle(client => {
        pre_recycle_calls.push(1)
        client.check_connection()
      })
      .post_recycle(client => {
        post_recycle_calls.push(1)
        client.check_connection()
      })
      .build()

    assert_eq(pool.status().max_size, 2)
    assert_eq(pool.timeouts().wait_ms, Some(11))
    assert_eq(pool.timeouts().create_ms, Some(2_000))
    assert_eq(pool.timeouts().recycle_ms, Some(2_000))
    assert_true(
      pool.manager().config().recycling_method ==
      @pgpool.RecyclingMethod::verified(),
    )

    let first = pool.get()
    let first_pid : Int = first
      .query_one("select pg_backend_pid()::int4 as pid")
      .get_name("pid")
    let second = pool.get()
    let second_pid : Int = second
      .query_one("select pg_backend_pid()::int4 as pid")
      .get_name("pid")
    assert_true(first_pid != second_pid)

    first.release()
    second.release()

    let reused = pool.get()
    let reused_pid : Int = reused
      .query_one("select pg_backend_pid()::int4 as pid")
      .get_name("pid")
    assert_eq(reused_pid, second_pid)
    reused.release()

    assert_true(connect_calls.length() >= 2)
    assert_true(post_create_calls.length() >= 2)
    assert_true(pre_recycle_calls.length() >= 1)
    assert_true(post_recycle_calls.length() >= 1)

    pool.resize(1)
    assert_eq(pool.status().max_size, 1)
    assert_eq(pool.status().size, 1)

    pool.resize(3)
    assert_eq(pool.status().max_size, 3)

    guard (try? pool.resize(0))
      is Err(@pgpool.PoolError::InvalidConfig(message)) else {
      fail("expected invalid resize")
    }
    assert_eq(message, "pool max_size must be at least 1")

    pool.close()
    pool.resize(2)
    assert_true(pool.is_closed())
  })
}

///|
/// This verifies that declarative multi-target pools fall through to a later target after an earlier target fails.
/// The first target intentionally points at a closed local port so the second target has to win.
async test "integration pool declarative config fails over to later target" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let attempts : Array[Int] = []
    let connector = @pgpool.Connector::new(target => {
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
        @client.connect(bad_target)
      } else {
        @client.connect(target)
      }
    })
    let pool = @pgpool.Config::new(
        config.host,
        user=config.user,
        dbname=config.database,
        password=config.password,
        port=config.port,
        application_name="moonbit-postgres-pool-failover-extra",
        hosts=[config.host],
        ports=[config.port, config.port],
        pool=@pgpool.PoolConfig::new(1),
      )
      .builder(group)
      .connector(connector)
      .build()
    let targets = @pgpool.Config::new(
      config.host,
      user=config.user,
      dbname=config.database,
      password=config.password,
      port=config.port,
      application_name="moonbit-postgres-pool-failover-extra",
      hosts=[config.host],
      ports=[config.port, config.port],
      pool=@pgpool.PoolConfig::new(1),
    ).get_connection_targets()
    assert_eq(targets.length(), 2)
    assert_eq(targets[0].port, config.port)
    assert_eq(targets[1].port, config.port)

    let value : Int = pool.with_client(client => {
      client.query_one("select 29::int4 as value").get_name("value")
    })
    assert_eq(value, 29)
    assert_eq(attempts.length(), 1)

    pool.close()
  })
}
