///|
fn expect_pool_lease_released(error : Error) -> Unit raise {
  guard error is PoolError::ScopeExpired else {
    fail("expected lease released error")
  }
}

///|
async fn[T, E : Error] expect_pgpool_error_async(
  f : async () -> T raise E,
) -> E {
  try f() catch {
    error => error
  } noraise {
    _ => fail("expected async operation to raise")
  }
}

///|
fn client_api_test_pool(group : @async.TaskGroup[Unit]) -> Pool raise {
  let config = Config::Config(
    [ConnectionTarget(host="db.example")],
    user="moon",
    dbname="moondb",
    application_name="pgpool-client-api-wbtest",
    pool=PoolConfig(1),
  )
  start_test_pool(config, group)
}

///|
fn start_test_pool(
  config : Config,
  group : @async.TaskGroup[Unit],
  options? : PoolOptions = PoolOptions(),
) -> Pool raise {
  let (pool, executor) = Pool::create(config, options~)
  group.spawn_bg(allow_failure=true, () => executor.run())
  pool
}

///|
async fn start_test_client(
  config : @client.Config,
  group : @async.TaskGroup[Unit],
) -> @client.Client {
  let (client, executor) = @client.Client::create(config)
  group.spawn_bg(allow_failure=true, () => executor.run())
  client.ready()
  client
}

///|
fn client_api_test_connection(
  _group : @async.TaskGroup[Unit],
  id? : Int = 1,
) -> ConnectionState {
  {
    id,
    client: @ref.new(None),
    statement_cache_capacity: 100,
    statement_cache: [],
  }
}
