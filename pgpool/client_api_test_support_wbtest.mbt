///|
fn expect_pool_lease_released(error : Error) -> Unit raise {
  guard error is PoolError::LeaseReleased else {
    fail("expected lease released error")
  }
}

///|
fn expect_pool_operation_in_progress(error : Error) -> Unit raise {
  guard error is PoolError::OperationInProgress else {
    fail("expected operation in progress error")
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
  group : @async.TaskGroup[Unit],
  id? : Int = 1,
) -> ConnectionState {
  { id, group, client: @ref.new(None), statement_cache: [] }
}
