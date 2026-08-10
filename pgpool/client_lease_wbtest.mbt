///|
async test "pgpool session gate rejects work after scope expiry" {
  @async.with_task_group(group => {
    let pool = client_api_test_pool(group)
    let connection = client_api_test_connection(group)
    let state : ClientLeaseState = {
      pool: pool.shared,
      connection,
      gate: Mutex(),
      active_ops: @ref.new(0),
      releasing: @ref.new(true),
      released: @ref.new(false),
    }

    expect_pool_lease_released(
      expect_pgpool_error_async(() => state.begin_operation()),
    )
    expect_pool_lease_released(
      expect_pgpool_error_async(() => state.begin_cancellable_scope()),
    )
    expect_pool_lease_released(
      expect_pgpool_error_async(() => state.begin_transaction_scope()),
    )

    state.releasing.val = false
    state.released.val = true
    expect_pool_lease_released(
      expect_pgpool_error_async(() => state.begin_operation()),
    )
    pool.close()
  })
}

///|
async test "pgpool session release waits for the active gate owner" {
  @async.with_task_group(group => {
    let pool = client_api_test_pool(group)
    let connection = client_api_test_connection(group, id=1)
    pool.shared.connections.push(connection)
    let state : ClientLeaseState = {
      pool: pool.shared,
      connection,
      gate: Mutex(),
      active_ops: @ref.new(1),
      releasing: @ref.new(false),
      released: @ref.new(false),
    }
    assert_true(state.gate.try_acquire())
    let session : Session = { state, }

    session.release()
    assert_true(state.releasing.val)
    assert_false(state.released.val)

    state.finish_operation()
    assert_eq(state.active_ops.val, 0)
    assert_true(state.released.val)
    assert_eq(pool.shared.connections.length(), 0)

    session.release()
    state.finalize_release()
    assert_eq(pool.shared.connections.length(), 0)
    pool.close()
  })
}
