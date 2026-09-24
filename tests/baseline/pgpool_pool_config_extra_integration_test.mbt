///|
/// A custom Connector returns each client and executor pair. Multi-target
/// checkout continues after a failed first target.
async test "integration pool custom connector supports target failover" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let attempts : Array[Int] = []
    let connector = @pgpool.Connector::Connector(target => {
      if attempts.length() == 0 {
        attempts.push(1)
        let bad_target = @client.Config::new_internal(
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
        @client.Client::create(bad_target)
      } else {
        @client.Client::create(target)
      }
    })
    let declarative = @pgpool.Config::Config(
      [
        @pgpool.ConnectionTarget(host=config.host, port=config.port),
        @pgpool.ConnectionTarget(host=config.host, port=config.port),
      ],
      user=config.user,
      dbname=config.database,
      password=config.password,
      application_name="moonbit-postgres-pool-failover",
      pool=PoolConfig(1),
    )
    let (pool, executor) = @pgpool.Pool::create(
      declarative,
      options=PoolOptions(connector~),
    )
    group.spawn_bg(allow_failure=true, () => executor.run())

    let value : Int = pool
      .query_one("select 29::int4 as value")
      .get_name("value")
    assert_eq(value, 29)
    assert_eq(attempts.length(), 1)
    pool.close()
  })
}
