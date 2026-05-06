///|
test "pool config new builds defaults and appended hosts" {
  let config = Config::new(
    "primary.db",
    user="moon",
    dbname="moondb",
    application_name="pool-config-test",
    hosts=["replica.db"],
    target_session_attrs=TargetSessionAttrs::read_write(),
    load_balance_hosts=LoadBalanceHosts::Random,
    pool=PoolConfig::new(2),
  )
  let targets = config.get_connection_targets()
  @debug.assert_eq(targets.length(), 2)
  @debug.assert_eq(targets[0].host, "primary.db")
  @debug.assert_eq(targets[1].host, "replica.db")
  @debug.assert_eq(targets[0].port, 5432)
  @debug.assert_eq(targets[1].port, 5432)
  assert_true(targets[0].ssl_mode == @client.SslMode::VerifyFull)
  assert_true(targets[0].channel_binding == @client.ChannelBinding::Disable)
  assert_true(
    config.target_session_attrs == Some(TargetSessionAttrs::read_write()),
  )
  assert_true(config.load_balance_hosts == Some(LoadBalanceHosts::Random))
  @debug.assert_eq(targets[0].application_name, "pool-config-test")
  @debug.assert_eq(targets[1].application_name, "pool-config-test")
}

///|
test "pool config broadcasts explicit ports" {
  let config = Config::new(
    "db.example",
    user="moon",
    dbname="moondb",
    password="secret",
    port=7000,
    application_name="pool-explicit-port",
    hosts=["replica.example"],
    pool=PoolConfig::new(1),
  )
  let targets = config.get_connection_targets()
  @debug.assert_eq(targets.length(), 2)
  @debug.assert_eq(targets[0].host, "db.example")
  @debug.assert_eq(targets[1].host, "replica.example")
  @debug.assert_eq(targets[0].port, 7000)
  @debug.assert_eq(targets[1].port, 7000)
  @debug.assert_eq(targets[0].password, Some("secret"))
  assert_true(targets[0].ssl_mode == @client.SslMode::VerifyFull)
}

///|
test "pool config keeps explicit tls settings" {
  let config = Config::new(
    "db.example",
    user="moon",
    dbname="moondb",
    ssl_mode=@client.SslMode::VerifyCa,
    ssl_root_cert="/tmp/root.crt",
    application_name="pool-tls",
    pool=PoolConfig::new(1),
  )
  let target = config.get_connection_targets()[0]
  assert_true(target.ssl_mode == @client.SslMode::VerifyCa)
  @debug.assert_eq(target.ssl_root_cert, Some("/tmp/root.crt"))
}

///|
test "pool config broadcasts hostaddr to every host" {
  let config = Config::new(
    "one.db",
    hostaddr="10.0.0.1",
    user="moon",
    dbname="moondb",
    application_name="pool-hostaddr",
    hosts=["two.db"],
    pool=PoolConfig::new(1),
  )
  let targets = config.get_connection_targets()
  @debug.assert_eq(targets[0].hostaddr, Some("10.0.0.1"))
  @debug.assert_eq(targets[1].hostaddr, Some("10.0.0.1"))
}

///|
test "pool config manual record still reports missing user" {
  let result = try? {
    user: None,
    password: None,
    dbname: Some("moondb"),
    options: None,
    application_name: "pool-missing-user",
    ssl_mode: Some(@client.SslMode::VerifyFull),
    ssl_root_cert: None,
    channel_binding: Some(@client.ChannelBinding::Disable),
    host: Some("db.example"),
    hosts: None,
    hostaddr: None,
    hostaddrs: None,
    port: Some(5432),
    ports: None,
    connect_timeout_ms: None,
    keepalives: None,
    keepalives_idle_s: None,
    target_session_attrs: Some(TargetSessionAttrs::any()),
    load_balance_hosts: Some(LoadBalanceHosts::Disable),
    manager: None,
    pool: Some(PoolConfig::new(1)),
  }.get_connection_targets()
  guard result is Err(ConfigError::UserMissing) else {
    fail("expected missing user")
  }
}

///|
test "pool config manual record still reports missing dbname" {
  let result = try? {
    user: Some("moon"),
    password: None,
    dbname: None,
    options: None,
    application_name: "pool-missing-dbname",
    ssl_mode: Some(@client.SslMode::VerifyFull),
    ssl_root_cert: None,
    channel_binding: Some(@client.ChannelBinding::Disable),
    host: Some("db.example"),
    hosts: None,
    hostaddr: None,
    hostaddrs: None,
    port: Some(5432),
    ports: None,
    connect_timeout_ms: None,
    keepalives: None,
    keepalives_idle_s: None,
    target_session_attrs: Some(TargetSessionAttrs::any()),
    load_balance_hosts: Some(LoadBalanceHosts::Disable),
    manager: None,
    pool: Some(PoolConfig::new(1)),
  }.get_connection_targets()
  guard result is Err(ConfigError::DbnameMissing) else {
    fail("expected missing dbname")
  }
}

///|
test "pool config manual record still reports empty dbname" {
  let result = try? {
    user: Some("moon"),
    password: None,
    dbname: Some(""),
    options: None,
    application_name: "pool-empty-dbname",
    ssl_mode: Some(@client.SslMode::VerifyFull),
    ssl_root_cert: None,
    channel_binding: Some(@client.ChannelBinding::Disable),
    host: Some("db.example"),
    hosts: None,
    hostaddr: None,
    hostaddrs: None,
    port: Some(5432),
    ports: None,
    connect_timeout_ms: None,
    keepalives: None,
    keepalives_idle_s: None,
    target_session_attrs: Some(TargetSessionAttrs::any()),
    load_balance_hosts: Some(LoadBalanceHosts::Disable),
    manager: None,
    pool: Some(PoolConfig::new(1)),
  }.get_connection_targets()
  guard result is Err(ConfigError::DbnameEmpty) else {
    fail("expected empty dbname")
  }
}

///|
test "pool config requires pool config before build" {
  let result = try? {
    user: Some("moon"),
    password: None,
    dbname: Some("moondb"),
    options: None,
    application_name: "pool-missing-pool",
    ssl_mode: Some(@client.SslMode::VerifyFull),
    ssl_root_cert: None,
    channel_binding: Some(@client.ChannelBinding::Disable),
    host: Some("db.example"),
    hosts: None,
    hostaddr: None,
    hostaddrs: None,
    port: Some(5432),
    ports: None,
    connect_timeout_ms: None,
    keepalives: None,
    keepalives_idle_s: None,
    target_session_attrs: Some(TargetSessionAttrs::any()),
    load_balance_hosts: Some(LoadBalanceHosts::Disable),
    manager: None,
    pool: None,
  }.get_pool_config()
  guard result is Err(ConfigError::PoolConfigMissing) else {
    fail("expected missing pool config")
  }
}

///|
test "pool config requires explicit host for verify_full" {
  let result = try? {
    user: Some("moon"),
    password: None,
    dbname: Some("moondb"),
    options: None,
    application_name: "pool-verify-full-host",
    ssl_mode: Some(@client.SslMode::VerifyFull),
    ssl_root_cert: None,
    channel_binding: Some(@client.ChannelBinding::Disable),
    host: None,
    hosts: None,
    hostaddr: None,
    hostaddrs: None,
    port: Some(5432),
    ports: None,
    connect_timeout_ms: None,
    keepalives: None,
    keepalives_idle_s: None,
    target_session_attrs: Some(TargetSessionAttrs::any()),
    load_balance_hosts: Some(LoadBalanceHosts::Disable),
    manager: None,
    pool: Some(PoolConfig::new(1)),
  }.get_connection_targets()
  guard result is Err(ConfigError::InvalidConfig(message)) else {
    fail("expected verify-full host validation error")
  }
  @debug.assert_eq(
    message, "sslmode=verify-full requires explicit host or hostaddr",
  )
}

///|
test "pool config rejects sslrootcert system without verify_full" {
  let result = try? Config::new(
    "db.example",
    user="moon",
    dbname="moondb",
    ssl_mode=@client.SslMode::VerifyCa,
    ssl_root_cert="system",
    application_name="pool-system-root",
    pool=PoolConfig::new(1),
  ).get_connection_targets()
  guard result is Err(ConfigError::InvalidConfig(message)) else {
    fail("expected sslrootcert validation error")
  }
  @debug.assert_eq(message, "sslrootcert=system requires sslmode=verify-full")
}

///|
async test "pool builder updates status and manager config without connecting" {
  @async.with_task_group(group => {
    let config = Config::new(
      "db.example",
      user="moon",
      dbname="moondb",
      application_name="pool-builder",
      pool=PoolConfig::new(1),
      manager=ManagerConfig::new(recycling_method=RecyclingMethod::verified()),
    )
    let pool = config
      .builder(group)
      .max_size(3)
      .wait_timeout(Some(11))
      .create_timeout(Some(22))
      .recycle_timeout(Some(33))
      .queue_mode(QueueMode::lifo())
      .build()
    let timeouts = pool.timeouts()
    @debug.assert_eq(pool.status().max_size, 3)
    @debug.assert_eq(timeouts.wait_ms, Some(11))
    @debug.assert_eq(timeouts.create_ms, Some(22))
    @debug.assert_eq(timeouts.recycle_ms, Some(33))
    assert_true(
      pool.manager().config().recycling_method == RecyclingMethod::verified(),
    )
    assert_false(pool.is_closed())
    pool.manager().statement_caches().clear()
    pool.close()
    assert_true(pool.is_closed())
  })
}
