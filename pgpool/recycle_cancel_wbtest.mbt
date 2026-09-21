///|
/// Minimal backend for startup, cached preparation, validation, and shutdown.
async fn serve_recycle_test_connection(socket : @socket.Tcp) -> Unit {
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
      b'P' => socket.write(b"1\x00\x00\x00\x04")
      b'D' => socket.write(b"t\x00\x00\x00\x06\x00\x00n\x00\x00\x00\x04")
      b'S' => socket.write(b"Z\x00\x00\x00\x05I")
      b'X' => return
      _ => fail("unexpected recycle test request")
    }
  }
}

///|
async fn check_recycle_cancellation(post~ : Bool) -> Unit {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let disconnected : @async.Queue[Unit] = Queue(kind=Unbounded)
    group.spawn_bg(no_wait=true, () => {
      while true {
        let (socket, _) = server.accept()
        group.spawn_bg(no_wait=true, () => {
          serve_recycle_test_connection(socket)
          disconnected.put(())
        })
      }
    })
    let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
    let hook_gate : @async.Queue[Unit] = Queue(kind=Unbounded)
    defer hook_gate.close()
    let mut suspend_hook = true
    async fn hook(_client : @client.Client) {
      if suspend_hook {
        suspend_hook = false
        entered.put(())
        hook_gate.get()
      }
    }
    let options = if post {
      PoolOptions::PoolOptions(post_recycle=hook)
    } else {
      PoolOptions(pre_recycle=hook)
    }
    let pool = start_test_pool(
      Config(
        "127.0.0.1",
        port=server.addr.port(),
        user="moon",
        ssl_mode=Disable,
        application_name="recycle-cancel-test",
        pool=PoolConfig(1, recycling_method=Verified),
      ),
      group,
      options~,
    )
    defer {
      // Also close any checked-out connection if an assertion fails early.
      for connection in pool.shared.connections {
        if connection.client.val is Some(client) {
          client.abort()
        }
      }
      pool.close()
    }
    @async.with_timeout(3000, () => {
      let first = pool.checkout_session()
      first.with_prepared("select 1", _ => ())
      first.release()
      let retired = pool.shared.connections[0]
      assert_eq(retired.statement_cache.length(), 1)
      assert_eq(pool.status().size, 1)
      assert_eq(pool.status().available, 1)

      let checkout = group.spawn(allow_failure=true, () => {
        pool.checkout_session()
      })
      entered.get()
      assert_eq(pool.status().available, 0)
      assert_true(pool.shared.slots.try_get() is None)
      checkout.cancel()
      try @async.with_timeout(1000, () => checkout.wait()) catch {
        error => assert_true(error is @async.TaskCancelled)
      } noraise {
        lease => {
          lease.release()
          fail("expected cancelled checkout")
        }
      }
      assert_eq(pool.status().size, 0)
      assert_eq(pool.status().available, 0)
      assert_eq(pool.status().waiting, 0)
      assert_eq(pool.shared.connections.length(), 0)
      assert_true(retired.client.val is None)
      assert_eq(retired.statement_cache.length(), 0)
      // Exactly one slot is restored by checkout, never by run_recycle.
      assert_true(pool.shared.slots.try_get() is Some(_))
      assert_true(pool.shared.slots.try_get() is None)
      assert_true(pool.shared.slots.try_put(()))
      disconnected.get()

      let replacement = pool.checkout_session()
      assert_true(replacement.state.connection.id != retired.id)
      assert_eq(pool.status().size, 1)
      replacement.release()
      assert_eq(pool.status().available, 1)
      let reused = pool.checkout_session()
      assert_eq(reused.state.connection.id, replacement.state.connection.id)
      reused.release()
      assert_eq(pool.status().size, 1)
      assert_eq(pool.status().available, 1)
    })
  })
}

///|
async test "pool cancellation in pre_recycle retires connection and restores capacity" {
  check_recycle_cancellation(post=false)
}

///|
async test "pool cancellation in post_recycle retires connection and restores capacity" {
  check_recycle_cancellation(post=true)
}
