///|
async fn serve_pool_async_test_connection(
  socket : @socket.Tcp,
  connection_id : Int,
) -> Unit {
  defer socket.close()
  let startup = socket.read_exactly(4)
  ignore(
    socket.read_exactly(@proto.ByteReader::new(startup[:]).read_i32_be() - 4),
  )
  socket.write(b"R\x00\x00\x00\x08\x00\x00\x00\x00Z\x00\x00\x00\x05I")
  while true {
    guard socket.read_some(max_len=1) is Some(tag) else { return }
    let header = socket.read_exactly(4)
    let length = @proto.ByteReader::new(header[:]).read_i32_be()
    ignore(socket.read_exactly(length - 4))
    match tag[0] {
      b'S' => {
        if connection_id == 1 {
          for _ in 0..<1000 {
            socket.write(b"S\x00\x00\x00\x08n\x00a\x00")
          }
          socket.write(b"S\x00\x00\x00\x08n\x00c\x00")
        } else {
          socket.write(b"S\x00\x00\x00\x08n\x00b\x00")
        }
        socket.write(b"Z\x00\x00\x00\x05I")
      }
      b'Q' => socket.write(b"Z\x00\x00\x00\x05T")
      b'X' => return
      _ => fail("unexpected pool async test request")
    }
  }
}

///|
async test "pool messages retain newest items with source IDs after close" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let next_id = @ref.new(0)
    group.spawn_bg(no_wait=true, () => {
      while true {
        let (socket, _) = server.accept()
        next_id.val += 1
        let connection_id = next_id.val
        group.spawn_bg(no_wait=true, () => {
          serve_pool_async_test_connection(socket, connection_id)
        })
      }
    })
    let pool = start_test_pool(
      Config(
        [ConnectionTarget(host="127.0.0.1", port=server.addr.port())],
        user="moon",
        dbname="moondb",
        ssl_mode=Disable,
        application_name="pool-async-wbtest",
        pool=PoolConfig(2, async_message_capacity=2),
      ),
      group,
    )
    @async.with_timeout(3000, () => {
      pool.with_session(first => {
        first.check_connection()
        pool.with_session(second => second.check_connection())
      })
      assert_eq(pool.dropped_async_messages(), 1000L)
      pool.close()
      assert_true(
        pool.next_message()
        is Some(
          {
            connection_id: 1,
            message: @client.AsyncMessage::ParameterStatus("n", "c"),
          }
        ),
      )
      assert_true(
        pool.next_message()
        is Some(
          {
            connection_id: 2,
            message: @client.AsyncMessage::ParameterStatus("n", "b"),
          }
        ),
      )
      assert_true(pool.next_message() is None)
    })
  })
}

///|
async fn serve_pool_idle_disconnect_test_connection(
  socket : @socket.Tcp,
  connection_id : Int,
  close_first : @async.Queue[Unit],
) -> Unit {
  defer socket.close()
  let startup = socket.read_exactly(4)
  ignore(
    socket.read_exactly(@proto.ByteReader::new(startup[:]).read_i32_be() - 4),
  )
  socket.write(b"R\x00\x00\x00\x08\x00\x00\x00\x00Z\x00\x00\x00\x05I")
  assert_eq(socket.read_exactly(5), b"S\x00\x00\x00\x04")
  socket.write(b"Z\x00\x00\x00\x05I")
  if connection_id == 1 {
    close_first.get()
  } else {
    assert_eq(socket.read_exactly(5), b"X\x00\x00\x00\x04")
  }
}

///|
async test "idle connection failure does not close the pool" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let close_first : @async.Queue[Unit] = Queue(kind=Unbounded)
    let next_id = @ref.new(0)
    group.spawn_bg(no_wait=true, () => {
      while true {
        let (socket, _) = server.accept()
        next_id.val += 1
        let connection_id = next_id.val
        group.spawn_bg(no_wait=true, () => {
          serve_pool_idle_disconnect_test_connection(
            socket, connection_id, close_first,
          )
        })
      }
    })
    let pool = start_test_pool(
      Config(
        [ConnectionTarget(host="127.0.0.1", port=server.addr.port())],
        user="moon",
        dbname="moondb",
        ssl_mode=Disable,
        application_name="pool-idle-disconnect-wbtest",
        pool=PoolConfig(1),
      ),
      group,
    )
    @async.with_timeout(3000, () => {
      pool.check_connection()
      let old_client = pool.shared.connections[0].client.val.unwrap()
      close_first.put(())
      while !old_client.is_closed() {
        @async.pause()
      }
      assert_false(pool.is_closed())
      pool.check_connection()
      assert_eq(pool.shared.connections[0].id, 2)
      assert_eq(pool.status().size, 1)
      pool.close()
    })
  })
}

///|
async test "pool hook handle expires and rejects a leaked transaction" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    group.spawn_bg(no_wait=true, () => {
      while true {
        let (socket, _) = server.accept()
        group.spawn_bg(no_wait=true, () => {
          serve_pool_async_test_connection(socket, 2)
        })
      }
    })
    let config = Config(
      [ConnectionTarget(host="127.0.0.1", port=server.addr.port())],
      user="moon",
      dbname="moondb",
      ssl_mode=Disable,
      application_name="pool-hook-wbtest",
      pool=PoolConfig(1),
    )
    @async.with_timeout(3000, () => {
      let saved : @ref.Ref[Operation?] = @ref.new(None)
      let pool = start_test_pool(
        config,
        group,
        options=PoolOptions(post_create=operation => {
          saved.val = Some(operation)
          operation.check_connection()
        }),
      )
      pool.with_session(_ => ())
      assert_true(
        expect_pgpool_error_async(() => saved.val.unwrap().check_connection())
        is PoolError::ScopeExpired,
      )
      pool.close()

      let leaking = start_test_pool(
        config,
        group,
        options=PoolOptions(post_create=operation => {
          operation.batch_execute("BEGIN")
        }),
      )
      assert_true(
        expect_pgpool_error_async(() => leaking.with_session(_ => ()))
        is PoolError::HookLeftOpenTransaction,
      )
      assert_eq(leaking.status().size, 0)
      leaking.close()
    })
  })
}

///|
async test "recycle hook transaction discards the old connection" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    group.spawn_bg(no_wait=true, () => {
      while true {
        let (socket, _) = server.accept()
        group.spawn_bg(no_wait=true, () => {
          serve_pool_async_test_connection(socket, 2)
        })
      }
    })
    let pool = start_test_pool(
      Config(
        [ConnectionTarget(host="127.0.0.1", port=server.addr.port())],
        user="moon",
        dbname="moondb",
        ssl_mode=Disable,
        application_name="pool-recycle-hook-wbtest",
        pool=PoolConfig(1),
      ),
      group,
      options=PoolOptions(pre_recycle=operation => {
        operation.batch_execute("BEGIN")
      }),
    )
    @async.with_timeout(3000, () => {
      pool.with_session(session => session.check_connection())
      assert_eq(pool.shared.connections[0].id, 1)
      pool.with_session(session => session.check_connection())
      assert_eq(pool.shared.connections[0].id, 2)
      assert_eq(pool.status().size, 1)
      pool.close()
    })
  })
}

///|
test "pool async message capacity must be positive" {
  assert_true(
    @test.expect_error(() => ignore(PoolConfig(1, async_message_capacity=0)))
    is PoolError::InvalidConfig(_),
  )
}
