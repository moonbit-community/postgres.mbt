///|
async test "client executor does not connect before run and rejects a second run" {
  let (client, executor) = Client::create(
    Config(
      "127.0.0.1",
      user="moon",
      database="moondb",
      ssl_mode=Disable,
      application_name="executor-wbtest",
    ),
  )
  assert_true(
    @test.expect_error(() => client.parameter("client_encoding"))
    is ClientError::NotReady,
  )
  assert_true(
    @test.expect_error(() => client.cancel_token()) is ClientError::NotReady,
  )
  @async.with_task_group(group => {
    let first = group.spawn(allow_failure=true, () => client.ready())
    let second = group.spawn(allow_failure=true, () => client.ready())
    @async.pause()
    assert_true(first.try_wait() is None)
    assert_true(second.try_wait() is None)
    client.close()
    assert_true(
      expect_error_async(() => first.wait()) is ClientError::Closed(_),
    )
    assert_true(
      expect_error_async(() => second.wait()) is ClientError::Closed(_),
    )
    executor.run()
    assert_true(
      expect_error_async(() => executor.run())
      is ClientError::ExecutorAlreadyStarted,
    )
  })
}

///|
async test "several client ready waiters observe the same startup result" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let accepted : @async.Queue[Unit] = Queue(kind=Unbounded)
    let release : @async.Queue[Unit] = Queue(kind=Unbounded)
    group.spawn_bg(() => {
      let (conn, _) = server.accept()
      defer conn.close()
      read_startup_packet(conn)
      accepted.put(())
      release.get()
      conn.write(auth_ok_packet())
      conn.write(parameter_status_packet("client_encoding", "UTF8"))
      conn.write(backend_key_data_packet(321, 654))
      conn.write(ready_for_query_packet(b'I'))
      assert_eq(conn.read_exactly(5), terminate_bytes())
    })
    let (client, executor) = Client::create(
      Config(
        "127.0.0.1",
        user="moon",
        database="moondb",
        port=server.addr.port(),
        ssl_mode=Disable,
        application_name="executor-ready-wbtest",
      ),
    )
    let driver = group.spawn(no_wait=true, () => executor.run())
    accepted.get()
    let first = group.spawn(() => client.ready())
    let second = group.spawn(() => client.ready())
    @async.pause()
    assert_true(first.try_wait() is None)
    assert_true(second.try_wait() is None)
    release.put(())
    first.wait()
    second.wait()
    client.ready()
    assert_eq(client.parameter("client_encoding"), Some("UTF8"))
    assert_eq(client.cancel_token().process_id(), 321)
    client.close()
    driver.wait()
  })
}

///|
async test "close during client startup cancels authentication and waits for cleanup" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let accepted : @async.Queue[Unit] = Queue(kind=Unbounded)
    let backend = group.spawn(() => {
      let (conn, _) = server.accept()
      defer conn.close()
      read_startup_packet(conn)
      accepted.put(())
      conn.read_some(max_len=1)
    })
    let (client, executor) = Client::create(
      Config(
        "127.0.0.1",
        user="moon",
        database="moondb",
        port=server.addr.port(),
        ssl_mode=Disable,
        application_name="executor-close-wbtest",
      ),
    )
    let driver = group.spawn(no_wait=true, () => executor.run())
    accepted.get()
    @async.with_timeout(1000, () => client.close())
    assert_true(client.is_closed())
    assert_true(
      expect_error_async(() => client.ready()) is ClientError::Closed(_),
    )
    assert_true(backend.wait() is None)
    driver.wait()
  })
}

///|
async test "cancelling a running client executor closes the socket" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let backend = group.spawn(() => {
      let (conn, _) = server.accept()
      defer conn.close()
      read_startup_packet(conn)
      conn.write(auth_ok_packet())
      conn.write(ready_for_query_packet(b'I'))
      conn.read_some(max_len=1)
    })
    let (client, executor) = Client::create(
      Config(
        "127.0.0.1",
        user="moon",
        database="moondb",
        port=server.addr.port(),
        ssl_mode=Disable,
        application_name="executor-cancel-wbtest",
      ),
    )
    let task = group.spawn(allow_failure=true, () => executor.run())
    client.ready()
    task.cancel()
    assert_true(expect_error_async(() => task.wait()) is @async.TaskCancelled)
    assert_true(client.is_closed())
    assert_true(backend.wait() is None)
  })
}
