///|
/// Cancel only after the callback reaches its suspension point, then wait for
/// rollback to finish before inspecting the database from the parent task.
async fn cancel_transaction_callback(
  f : async (async () -> Unit) -> Unit,
) -> Unit {
  @async.with_task_group(group => {
    let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
    let blocked : @async.Queue[Unit] = Queue(kind=Unbounded)
    let task = group.spawn(() => {
      f(() => {
        entered.put(())
        blocked.get()
      })
    })
    entered.get()
    task.cancel()
    let error = expect_error_async(() => {
      @async.with_timeout(5000, () => task.wait())
    })
    assert_true(error is @async.TaskCancelled)
  })
}

///|
async test "integration client transaction cancellation rolls back" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-client-tx-cancel"),
    )
    defer client.close()
    group.spawn_bg(() => connection.run())
    client.batch_execute("create temp table moon_tx_cancel(value int4)")
    cancel_transaction_callback(wait_for_cancel => {
      client.with_transaction(tx => {
        tx.batch_execute("insert into moon_tx_cancel values (1)")
        wait_for_cancel()
      })
    })
    let count : Int = client
      .query_one("select count(*)::int4 as value from moon_tx_cancel")
      .get_name("value")
    assert_eq(count, 0)
    client.with_transaction(tx => {
      tx.batch_execute("insert into moon_tx_cancel values (2)")
    })
    let value : Int = client
      .query_one("select value from moon_tx_cancel")
      .get_name("value")
    assert_eq(value, 2)
  })
}
