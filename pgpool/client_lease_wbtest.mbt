///|
async test "lease expiration wins over busy gate and releases capacity once" {
  with_callback_scope_pool(0, 1, (_, pool, _, _, _) => {
    let session = pool.checkout_session()
    let client = session.state.begin_operation()
    assert_true(!client.is_closed())
    assert_true(
      @test.expect_error(() => session.state.begin_operation())
      is PoolError::OperationInProgress,
    )
    session.state.finish_operation()
    session.release()
    session.release()
    assert_true(
      @test.expect_error(() => session.state.begin_operation())
      is PoolError::ScopeExpired,
    )
    assert_true(pool.shared.slots.try_get() is Some(_))
    assert_true(pool.shared.slots.try_get() is None)
  })
}
