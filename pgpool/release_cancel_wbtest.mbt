///|
priv enum PoolReturnEntry {
  SessionCallback
  BatchExecute
  QueryAll
  TransactionCommit
  TransactionRollback
}

///|
fn assert_returned_capacity(pool : Pool) -> Unit raise {
  assert_eq(pool.status().waiting, 0)
  assert_true(pool.shared.slots.try_get() is Some(_))
  assert_true(pool.shared.slots.try_get() is None)
  assert_true(pool.shared.slots.try_put(()))
}

///|
async test "pool entries propagate cancellation during successful reset or cleanup timeout" {
  for
    entry in [
      SessionCallback,
      BatchExecute,
      QueryAll,
      TransactionCommit,
      TransactionRollback,
    ] {
    for reset_completes in [true, false] {
      with_control_pool(
        HoldReset,
        (group, pool, probe) => {
          let after_scope = Ref(false)
          let record = TransactionRecord()
          let task = group.spawn(allow_failure=true, () => {
            match entry {
              SessionCallback => assert_eq(pool.with_session(_ => 7), 7)
              BatchExecute => pool.batch_execute("work")
              QueryAll => assert_eq(pool.query_all("select 1").length(), 0)
              TransactionCommit => {
                let result : Result[Int32, String] = pool.with_transaction(
                  _ => Ok(7),
                  record~,
                )
                assert_eq(result, Ok(7))
              }
              TransactionRollback => {
                let result : Result[Int32, String] = pool.with_transaction(
                  _ => Err("business"),
                  record~,
                )
                assert_eq(result, Err("business"))
              }
            }
            after_scope.val = true
          })
          probe.query_started.get()
          let connection = pool.shared.connections[0]
          assert_eq(pool.status().available, 0)
          assert_true(pool.shared.slots.try_get() is None)
          assert_true(task.try_wait() is None)
          match entry {
            TransactionCommit => assert_eq(record.status(), Committed)
            TransactionRollback => assert_eq(record.status(), RolledBack)
            _ => ()
          }
          let started = @async.now()
          task.cancel()
          assert_true(task.try_wait() is None)
          assert_eq(pool.status().available, 0)
          assert_true(pool.shared.slots.try_get() is None)
          if reset_completes {
            probe.release_query.put(())
          }
          assert_true(
            expect_pgpool_error_async(() => task.wait())
            is @async.WaitedTaskAlreadyCancelled,
          )
          assert_false(after_scope.val)
          assert_true(@async.now() - started < 600L)
          assert_eq(pool.status().size, if reset_completes { 1 } else { 0 })
          assert_eq(
            pool.status().available,
            if reset_completes {
              1
            } else {
              0
            },
          )
          assert_eq(
            pool.shared.connections.length(),
            if reset_completes {
              1
            } else {
              0
            },
          )
          if !reset_completes {
            assert_true(connection.client.val is None)
          }
          match entry {
            SessionCallback | QueryAll =>
              assert_true(probe.sql == ["DISCARD ALL"])
            BatchExecute => assert_true(probe.sql == ["work", "DISCARD ALL"])
            TransactionCommit => {
              assert_eq(record.status(), Committed)
              assert_true(probe.sql == ["BEGIN", "COMMIT", "DISCARD ALL"])
            }
            TransactionRollback => {
              assert_eq(record.status(), RolledBack)
              assert_true(probe.sql == ["BEGIN", "ROLLBACK", "DISCARD ALL"])
            }
          }
          assert_true(probe.cancel_started.try_get() is None)
          assert_returned_capacity(pool)

          if !reset_completes {
            // The retired backend still owns its barrier after client abort.
            probe.release_query.put(())
          }
          let next = pool.checkout_session()
          assert_eq(next.state.connection.id == connection.id, reset_completes)
          assert_true(pool.shared.slots.try_get() is None)
          // Let the next return reset normally, including on a replacement.
          probe.release_query.put(())
          next.release()
          assert_eq(pool.status().size, 1)
          assert_eq(pool.status().available, 1)
          assert_returned_capacity(pool)
        },
        cleanup_ms=if reset_completes { 1000 } else { 40 },
        reset=DiscardAll,
      )
    }
  }
}

///|
async test "session return propagates cancellation after initialization hook cleanup" {
  for hook_fails in [false, true] {
    let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
    let release_hook : @async.Queue[Unit] = Queue(kind=Unbounded)
    defer release_hook.close()
    let hook_calls = Ref(0)
    let hook_finished = Ref(false)
    let options = PoolOptions(initialize_session=session => {
      hook_calls.val += 1
      if hook_calls.val == 2 {
        entered.put(())
        release_hook.get()
        session.batch_execute("initialize return")
        hook_finished.val = true
        if hook_fails {
          raise PoolError::InvalidConfig("return hook failed")
        }
      }
    })
    with_control_pool(
      Normal,
      (group, pool, probe) => {
        let after_scope = Ref(false)
        let task = group.spawn(allow_failure=true, () => {
          pool.with_session(_ => ())
          after_scope.val = true
        })
        entered.get()
        let connection = pool.shared.connections[0]
        assert_true(probe.sql == ["DISCARD ALL"])
        assert_eq(pool.status().available, 0)
        assert_true(pool.shared.slots.try_get() is None)
        task.cancel()
        assert_true(task.try_wait() is None)
        release_hook.put(())
        assert_true(
          expect_pgpool_error_async(() => task.wait())
          is @async.WaitedTaskAlreadyCancelled,
        )
        assert_true(hook_finished.val)
        assert_false(after_scope.val)
        assert_eq(hook_calls.val, 2)
        assert_true(probe.sql == ["DISCARD ALL", "initialize return"])
        assert_eq(pool.status().size, if hook_fails { 0 } else { 1 })
        assert_eq(pool.status().available, if hook_fails { 0 } else { 1 })
        assert_returned_capacity(pool)
        let next = pool.checkout_session()
        assert_eq(next.state.connection.id == connection.id, !hook_fails)
        next.release()
        assert_eq(pool.status().available, 1)
        assert_returned_capacity(pool)
      },
      cleanup_ms=1000,
      reset=DiscardAll,
      options~,
    )
  }
}

///|
async test "callback exception wins over cancellation during session return" {
  for reset_completes in [true, false] {
    with_control_pool(
      HoldReset,
      (group, pool, probe) => {
        let after_scope = Ref(false)
        let task = group.spawn(allow_failure=true, () => {
          pool.with_session(_ => {
            raise PoolError::InvalidConfig("callback exception")
          })
          after_scope.val = true
        })
        probe.query_started.get()
        assert_eq(pool.status().available, 0)
        assert_true(pool.shared.slots.try_get() is None)
        task.cancel()
        if reset_completes {
          probe.release_query.put(())
        }
        assert_true(
          expect_pgpool_error_async(() => task.wait())
          is PoolError::InvalidConfig("callback exception"),
        )
        assert_false(after_scope.val)
        assert_true(probe.sql == ["DISCARD ALL"])
        assert_eq(pool.status().size, if reset_completes { 1 } else { 0 })
        assert_eq(pool.status().available, if reset_completes { 1 } else { 0 })
        assert_returned_capacity(pool)
      },
      cleanup_ms=if reset_completes { 1000 } else { 40 },
      reset=DiscardAll,
    )
  }
}
