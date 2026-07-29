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
    expect_pool_lease_released(
      @test.expect_error(() => released_client.statement_cache()),
    )

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
    expect_pool_lease_released(
      @test.expect_error(() => delaying_client.detach_raw()),
    )

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
    expect_pool_operation_in_progress(
      @test.expect_error(() => busy_client.detach_raw()),
    )

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
    expect_pool_lease_released(
      @test.expect_error(() => empty_client.detach_raw()),
    )

    pool.close()
  })
}
