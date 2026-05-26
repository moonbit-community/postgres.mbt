///|
fn[T] expect_pool_lease_released(result : Result[T, Error]) -> Unit raise {
  guard result is Err(PoolError::LeaseReleased) else {
    fail("expected lease released error")
  }
}

///|
fn[T] expect_pool_operation_in_progress(
  result : Result[T, Error],
) -> Unit raise {
  guard result is Err(PoolError::OperationInProgress) else {
    fail("expected operation in progress error")
  }
}

///|
fn client_api_test_pool(group : @async.TaskGroup[Unit]) -> Pool raise {
  Config::new(
    "db.example",
    user="moon",
    dbname="moondb",
    application_name="pgpool-client-api-wbtest",
    pool=PoolConfig::new(1),
  )
  .builder(group)
  .build()
}

///|
fn client_api_test_connection(
  group : @async.TaskGroup[Unit],
  id? : Int = 1,
) -> ConnectionState {
  { id, group, client: @ref.new(None), statement_cache: [] }
}
