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
  let config = Config::new(
    "db.example",
    user="moon",
    dbname="moondb",
    application_name="pgpool-client-api-wbtest",
    pool=PoolConfig::new(1),
  )
  Pool::new(config, group)
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
