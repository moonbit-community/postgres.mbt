///|
async test "pooled COPY NUL abort cleans up and returns exactly one capacity slot" {
  with_control_pool(Normal, (_, pool, probe) => {
    assert_true(
      expect_pgpool_error_async(() => {
        pool.with_copy_in("held copy in", sink => {
          sink.abort(message="bad\u0000message")
        })
      })
      is @proto.ProtocolError::InvalidInput(_),
    )
    assert_eq(count_callback_requests(probe.requests, b'f'), 1)
    assert_eq(pool.status().size, 1)
    assert_eq(pool.status().available, 1)
    assert_true(pool.shared.slots.try_get() is Some(_))
    assert_true(pool.shared.slots.try_get() is None)
    assert_true(pool.shared.slots.try_put(()))
    pool.batch_execute("still healthy")
  })
}

///|
async test "one COPY transport failure leaves the pool and its other connection usable" {
  with_control_pool(CopyDisconnect, (_, pool, _) => {
    pool.resize(2)
    let peer = pool.checkout_session()
    defer peer.release()
    let peer_id = peer.state.connection.id
    let error = expect_pgpool_error_async(() => {
      pool.with_copy_in("broken copy in", sink => {
        sink.send(b"1\n")
        ignore(sink.finish())
      })
    })
    assert_false(error is PoolError::Timeout(_))
    assert_false(pool.is_closed())
    assert_eq(pool.status().size, 1)
    assert_eq(pool.status().available, 0)
    assert_true(pool.shared.slots.try_get() is Some(_))
    assert_true(pool.shared.slots.try_get() is None)
    assert_true(pool.shared.slots.try_put(()))
    peer.check_connection()
    assert_eq(peer.state.connection.id, peer_id)
    pool.batch_execute("replacement")
    peer.release()
    assert_eq(pool.status().size, 2)
    assert_eq(pool.status().available, 2)
  })
}

///|
async test "pool close during COPY waits for abort cleanup and physical shutdown" {
  with_control_pool(Normal, (group, pool, probe) => {
    let copy = group.spawn(() => {
      pool.with_copy_in("held copy in", _ => {
        pool.close()
        assert_eq(pool.status().size, 1)
        assert_false(pool.shared.done.done.val)
      })
    })
    probe.query_started.get()
    assert_true(copy.try_wait() is None)
    probe.release_query.put(())
    copy.wait()
    pool.shared.done.wait()
    assert_eq(pool.status().size, 0)
    assert_eq(pool.shared.connections.length(), 0)
    assert_eq(count_callback_requests(probe.requests, b'f'), 1)
  })
}
