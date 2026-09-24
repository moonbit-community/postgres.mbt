///|
fn executor_test_pool() -> (Pool, PoolExecutor) raise {
  Pool::create(
    Config(
      [ConnectionTarget(host="127.0.0.1")],
      user="moon",
      dbname="moondb",
      ssl_mode=Disable,
      application_name="pool-executor-wbtest",
      pool=PoolConfig(1),
    ),
  )
}

///|
async test "pool executor is single use and close before run rejects ready waiters" {
  let (pool, executor) = executor_test_pool()
  @async.with_task_group(group => {
    let waiter = group.spawn(allow_failure=true, () => pool.ready())
    @async.pause()
    assert_true(waiter.try_wait() is None)
    pool.close()
    assert_true(
      expect_pgpool_error_async(() => waiter.wait()) is PoolError::Closed,
    )
    executor.run()
    assert_true(
      expect_pgpool_error_async(() => executor.run())
      is PoolError::ExecutorAlreadyStarted,
    )
  })
}

///|
async test "pool executor waits for a borrowed connection after close" {
  @async.with_task_group(group => {
    let (pool, executor) = executor_test_pool()
    let task = group.spawn(no_wait=true, () => executor.run())
    pool.ready()
    let (client, _unused) = @client.Client::create(pool.shared.targets[0])
    let connection = ConnectionState::new(pool.shared, client)
    pool.shared.size.val += 1
    pool.close()
    assert_true(pool.is_closed())
    assert_eq(pool.status().size, 1)
    assert_true(task.try_wait() is None)
    return_client(pool.shared, connection)
    task.wait()
    assert_eq(pool.status().size, 0)
  })
}

///|
async test "borrowed session can finish after pool close before executor returns" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let backend = group.spawn(() => {
      let (socket, _) = server.accept()
      defer socket.close()
      let startup = socket.read_exactly(4)
      ignore(
        socket.read_exactly(
          @proto.ByteReader::new(startup[:]).read_i32_be() - 4,
        ),
      )
      socket.write(b"R\x00\x00\x00\x08\x00\x00\x00\x00Z\x00\x00\x00\x05I")
      assert_eq(socket.read_exactly(5), b"S\x00\x00\x00\x04")
      socket.write(b"Z\x00\x00\x00\x05I")
      assert_eq(socket.read_exactly(5), b"X\x00\x00\x00\x04")
    })
    let (pool, executor) = Pool::create(
      Config(
        [ConnectionTarget(host="127.0.0.1", port=server.addr.port())],
        user="moon",
        dbname="moondb",
        ssl_mode=Disable,
        application_name="pool-borrowed-close-wbtest",
        pool=PoolConfig(1),
      ),
    )
    let task = group.spawn(no_wait=true, () => executor.run())
    @async.with_timeout(3000, () => {
      pool.ready()
      let session = pool.checkout_session()
      pool.close()
      assert_true(task.try_wait() is None)
      session.check_connection()
      session.release()
      task.wait()
      backend.wait()
      assert_eq(pool.status().size, 0)
    })
  })
}

///|
async test "cancelling a pool executor closes the pool" {
  @async.with_task_group(group => {
    let (pool, executor) = executor_test_pool()
    let task = group.spawn(allow_failure=true, () => executor.run())
    pool.ready()
    task.cancel()
    assert_true(
      expect_pgpool_error_async(() => task.wait()) is @async.TaskCancelled,
    )
    assert_true(pool.is_closed())
    assert_true(
      expect_pgpool_error_async(() => pool.with_session(_ => ()))
      is PoolError::Closed,
    )
  })
}

///|
async test "unexpected physical driver failure retires one checked-out client" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let disconnect : @async.Queue[Unit] = Queue(kind=Unbounded)
    group.spawn_bg(() => {
      let (socket, _) = server.accept()
      defer socket.close()
      let startup = socket.read_exactly(4)
      ignore(
        socket.read_exactly(
          @proto.ByteReader::new(startup[:]).read_i32_be() - 4,
        ),
      )
      socket.write(b"R\x00\x00\x00\x08\x00\x00\x00\x00Z\x00\x00\x00\x05I")
      disconnect.get()
    })
    let (pool, executor) = Pool::create(
      Config(
        [ConnectionTarget(host="127.0.0.1", port=server.addr.port())],
        user="moon",
        dbname="moondb",
        ssl_mode=Disable,
        application_name="pool-fatal-wbtest",
        pool=PoolConfig(1),
      ),
    )
    let task = group.spawn(allow_failure=true, () => executor.run())
    @async.with_timeout(2000, () => {
      pool.ready()
      let session = pool.checkout_session()
      disconnect.put(())
      let _ = session.check_connection() catch { _ => () }
      session.release()
      assert_false(pool.is_closed())
      assert_eq(pool.status().size, 0)
      pool.close()
      task.wait()
    })
  })
}
