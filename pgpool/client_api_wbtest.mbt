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

///|
async test "pgpool client lease state rejects released busy and empty connections" {
  @async.with_task_group(group => {
    let pool = client_api_test_pool(group)
    let connection = client_api_test_connection(group)
    let state : ClientLeaseState = {
      pool: pool.shared,
      connection,
      active_ops: @ref.new(0),
      scope_active: @ref.new(false),
      releasing: @ref.new(true),
      released: @ref.new(false),
    }

    expect_pool_lease_released(try? state.begin_operation())
    expect_pool_lease_released(try? state.begin_cancellable_scope())
    expect_pool_lease_released(try? state.begin_transaction_scope())

    state.releasing.val = false
    state.released.val = true
    expect_pool_lease_released(try? state.begin_operation())

    state.released.val = false
    state.scope_active.val = true
    expect_pool_operation_in_progress(try? state.begin_operation())
    expect_pool_operation_in_progress(try? state.begin_cancellable_scope())
    expect_pool_operation_in_progress(try? state.begin_transaction_scope())

    state.scope_active.val = false
    state.active_ops.val = 1
    expect_pool_operation_in_progress(try? state.begin_cancellable_scope())
    expect_pool_operation_in_progress(try? state.begin_transaction_scope())

    state.active_ops.val = 0
    expect_pool_lease_released(try? state.begin_operation())
    expect_pool_lease_released(try? state.begin_cancellable_scope())
    expect_pool_lease_released(try? state.begin_transaction_scope())

    pool.close()
  })
}

///|
async test "pgpool client lease finish helpers finalize delayed release" {
  @async.with_task_group(group => {
    let pool = client_api_test_pool(group)
    let connection = client_api_test_connection(group, id=1)
    pool.shared.connections.push(connection)
    let state : ClientLeaseState = {
      pool: pool.shared,
      connection,
      active_ops: @ref.new(2),
      scope_active: @ref.new(true),
      releasing: @ref.new(false),
      released: @ref.new(false),
    }

    state.finish_operation()
    assert_eq(state.active_ops.val, 1)
    assert_false(state.released.val)

    state.releasing.val = true
    state.finish_operation()
    assert_eq(state.active_ops.val, 0)
    assert_true(state.released.val)
    assert_eq(pool.shared.connections.length(), 0)

    state.finalize_release()
    assert_eq(pool.shared.connections.length(), 0)

    let cancellable_connection = client_api_test_connection(group, id=2)
    pool.shared.connections.push(cancellable_connection)
    let cancellable_state : ClientLeaseState = {
      pool: pool.shared,
      connection: cancellable_connection,
      active_ops: @ref.new(1),
      scope_active: @ref.new(true),
      releasing: @ref.new(true),
      released: @ref.new(false),
    }
    cancellable_state.finish_cancellable_scope()
    assert_false(cancellable_state.scope_active.val)
    assert_eq(cancellable_state.active_ops.val, 0)
    assert_true(cancellable_state.released.val)

    let transaction_connection = client_api_test_connection(group, id=3)
    pool.shared.connections.push(transaction_connection)
    let transaction_state : ClientLeaseState = {
      pool: pool.shared,
      connection: transaction_connection,
      active_ops: @ref.new(1),
      scope_active: @ref.new(true),
      releasing: @ref.new(true),
      released: @ref.new(false),
    }
    transaction_state.finish_transaction_scope()
    assert_false(transaction_state.scope_active.val)
    assert_eq(transaction_state.active_ops.val, 0)
    assert_true(transaction_state.released.val)

    pool.close()
  })
}

///|
async test "pgpool client wrapper helpers cover release and detach guards" {
  @async.with_task_group(group => {
    let pool = client_api_test_pool(group)

    let released_connection = client_api_test_connection(group, id=10)
    pool.shared.connections.push(released_connection)
    let released_state : ClientLeaseState = {
      pool: pool.shared,
      connection: released_connection,
      active_ops: @ref.new(0),
      scope_active: @ref.new(false),
      releasing: @ref.new(false),
      released: @ref.new(false),
    }
    let released_client : Client = { state: released_state }
    let cache = released_client.statement_cache()
    assert_eq(cache.connection.id, 10)
    released_client.release()
    assert_true(released_state.releasing.val)
    assert_true(released_state.released.val)
    released_client.release()
    expect_pool_lease_released(try? released_client.statement_cache())

    let delaying_connection = client_api_test_connection(group, id=11)
    pool.shared.connections.push(delaying_connection)
    let delaying_state : ClientLeaseState = {
      pool: pool.shared,
      connection: delaying_connection,
      active_ops: @ref.new(1),
      scope_active: @ref.new(false),
      releasing: @ref.new(false),
      released: @ref.new(false),
    }
    let delaying_client : Client = { state: delaying_state }
    delaying_client.release()
    assert_true(delaying_state.releasing.val)
    assert_false(delaying_state.released.val)
    expect_pool_lease_released(try? delaying_client.detach_raw())

    let busy_connection = client_api_test_connection(group, id=12)
    let busy_client : Client = {
      state: {
        pool: pool.shared,
        connection: busy_connection,
        active_ops: @ref.new(0),
        scope_active: @ref.new(true),
        releasing: @ref.new(false),
        released: @ref.new(false),
      },
    }
    expect_pool_operation_in_progress(try? busy_client.detach_raw())

    let empty_connection = client_api_test_connection(group, id=13)
    let empty_client : Client = {
      state: {
        pool: pool.shared,
        connection: empty_connection,
        active_ops: @ref.new(0),
        scope_active: @ref.new(false),
        releasing: @ref.new(false),
        released: @ref.new(false),
      },
    }
    expect_pool_lease_released(try? empty_client.detach_raw())

    pool.close()
  })
}
