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
fn start_test_pool(
  config : Config,
  group : @async.TaskGroup[Unit],
  options~ : PoolOptions = PoolOptions(),
) -> Pool raise {
  let (pool, executor) = Pool::create(config, options~)
  group.spawn_bg(allow_failure=true, () => executor.run())
  pool
}
