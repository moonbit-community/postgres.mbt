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
    let mut suspend_hook = false
    async fn hook(_operation : Session) {
      if suspend_hook {
        suspend_hook = false
        entered.put(())
        hook_gate.get()
      }
    }
    let options = if post {
      PoolOptions::PoolOptions(initialize_session=hook)
    } else {
      PoolOptions(before_acquire=hook)
    }
    let pool = start_test_pool(
      Config(
        [ConnectionTarget(host="127.0.0.1", port=server.addr.port())],
        user="moon",
        ssl_mode=Disable,
        application_name="recycle-cancel-test",
        pool=PoolConfig(1, health_check=Active, reset_policy=PreserveSession),
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

      if post {
        ignore(pool.shared.idle.remove(0))
        pool.discard_client(retired)
      }
      suspend_hook = true
      let checkout = group.spawn(allow_failure=true, () => {
        pool.checkout_session()
      })
      entered.get()
      assert_eq(pool.status().available, 0)
      assert_true(pool.shared.slots.try_get() is None)
      checkout.cancel()
      try @async.with_timeout(1000, () => checkout.wait()) catch {
        error => assert_true(error is @async.WaitedTaskAlreadyCancelled)
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
async test "pool cancellation in before_acquire retires connection and restores capacity" {
  check_recycle_cancellation(post=false)
}

///|
async test "pool cancellation in initialize_session retires connection and restores capacity" {
  check_recycle_cancellation(post=true)
}

///|
async test "zero recycle budget retires the dequeued client and restores exactly one slot" {
  with_control_pool(Normal, (_, pool, _) => {
    let first = pool.checkout_session()
    first.with_prepared("select 0", _ => ())
    let retired = first.state.connection
    first.release()
    assert_eq(retired.statement_cache.length(), 1)
    assert_eq(pool.status().available, 1)
    assert_true(
      expect_pgpool_error_async(() => {
        pool.with_session(_ => (), timeouts=Timeouts(recycle_ms=Some(0)))
      })
      is PoolError::Timeout(Recycle),
    )
    assert_eq(pool.status().size, 0)
    assert_eq(pool.status().available, 0)
    assert_eq(pool.shared.connections.length(), 0)
    assert_true(retired.client.val is None)
    assert_eq(retired.statement_cache.length(), 0)
    assert_true(pool.shared.slots.try_get() is Some(_))
    assert_true(pool.shared.slots.try_get() is None)
    assert_true(pool.shared.slots.try_put(()))
    let replacement = pool.checkout_session()
    defer replacement.release()
    assert_true(replacement.state.connection.id != retired.id)
    assert_eq(pool.status().size, 1)
    assert_true(
      expect_pgpool_error_async(() => {
        pool.with_session(_ => (), timeouts=Timeouts(wait_ms=Some(0)))
      })
      is PoolError::Timeout(Wait),
    )
    assert_eq(pool.status().size, pool.status().max_size)
    replacement.release()
    pool.close()
    pool.shared.done.wait()
    assert_eq(pool.status().size, 0)
  })
}

///|
async test "pool close during health check closes and retires the connection once" {
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let checking : @async.Queue[Unit] = Queue(kind=Unbounded)
      let check_gate : @async.Queue[Unit] = Queue(kind=Unbounded)
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
        checking.put(())
        check_gate.get()
        socket.write(b"Z\x00\x00\x00\x05I")
        assert_eq(socket.read_exactly(5), b"X\x00\x00\x00\x04")
        assert_true(socket.read_some(max_len=1) is None)
      })
      let (pool, executor) = Pool::create(
        Config(
          [ConnectionTarget(host="127.0.0.1", port=server.addr.port())],
          user="moon",
          ssl_mode=Disable,
          application_name="close-during-health-check",
          pool=PoolConfig(1, health_check=Active, reset_policy=PreserveSession),
        ),
      )
      defer pool.close()
      let running = group.spawn(() => executor.run())
      pool.ready()
      let session = pool.checkout_session()
      let retired = session.state.connection
      let physical = retired.client.val.unwrap()
      defer physical.abort()
      session.release()
      let checkout = group.spawn(allow_failure=true, () => {
        pool.checkout_session()
      })
      checking.get()
      pool.close()
      assert_eq(pool.status().size, 1)
      assert_true(running.try_wait() is None)
      check_gate.put(())
      assert_true(
        expect_pgpool_error_async(() => checkout.wait()) is PoolError::Closed,
      )
      running.wait()
      backend.wait()
      assert_true(physical.is_closed())
      assert_true(retired.client.val is None)
      assert_eq(pool.status().size, 0)
      assert_eq(pool.status().available, 0)
      assert_eq(pool.status().waiting, 0)
      assert_eq(pool.shared.connections.length(), 0)
      pool.discard_client(retired)
      pool.discard_client(retired)
      pool.close()
      assert_eq(pool.status().size, 0)
      let mut replacements = 0
      while pool.next_event() is Some(event) {
        if event.kind is ConnectionReplaced {
          assert_eq(event.connection_id, Some(retired.id))
          replacements += 1
        }
      }
      assert_eq(replacements, 1)
    })
  })
}
