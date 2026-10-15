// Escaped callbacks belong to the old physical connection, even after checkout.

///|
async fn run_transaction_entry(
  pool : Pool,
  entry : Int32,
  parents : Array[ClientLeaseState],
  record : TransactionRecord,
  f : async (Transaction) -> Result[Unit, String],
  deadline : Deadline?,
) -> Result[Unit, String] {
  if entry == 0 {
    pool.with_transaction(f, record~, deadline?)
  } else {
    pool.with_session(session => {
      parents.push(session.state)
      if entry == 1 {
        session.with_transaction(f, record~, deadline?)
      } else {
        session.with_transaction(tx => {
          parents.push(tx.state)
          if entry == 2 {
            tx.with_savepoint("escaped", f, record~, deadline?)
          } else {
            tx.with_transaction(f, record~, deadline?)
          }
        })
      }
    })
  }
}

///|
async test "all transaction entries retire escaped children and preserve exit precedence" {
  // Pool, Session, named savepoint and nested transaction; Ok, business Err,
  // exception, cancellation and deadline. Entry/exit barriers avoid sleeps.
  for entry in 0..<4 {
    for exit in 0..<5 {
      with_control_pool(
        Normal,
        (group, pool, probe) => {
          pool.batch_execute("seed")
          let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
          let returning : @async.Queue[Unit] = Queue(kind=Unbounded)
          let release_callback : @async.Queue[Unit] = Queue(kind=Unbounded)
          let hold_scope : @async.Queue[Unit] = Queue(kind=Unbounded)
          defer release_callback.close()
          defer hold_scope.close()
          let saved : @ref.Ref[Transaction?] = Ref(None)
          let old_task : @ref.Ref[@async.Task[Unit]?] = Ref(None)
          let parents : Array[ClientLeaseState] = []
          let record = TransactionRecord()
          let task = group.spawn(allow_failure=true, () => {
            run_transaction_entry(
              pool,
              entry,
              parents,
              record,
              tx => {
                saved.val = Some(tx)
                old_task.val = Some(
                  group.spawn(allow_failure=true, () => {
                    tx.with_prepared("select 1", prepared => {
                      entered.put(())
                      if exit == 4 {
                        // Keep this child active even if its inherited deadline
                        // fires first; the transaction must exit independently.
                        @async.protect_from_cancel(() => release_callback.get())
                      } else {
                        release_callback.get()
                      }
                      assert_true(
                        expect_pgpool_error_async(() => prepared.query_all())
                        is PoolError::ScopeExpired,
                      )
                    })
                  }),
                )
                entered.get()
                returning.put(())
                match exit {
                  0 => Ok(())
                  1 => Err("business error")
                  2 => raise PoolError::InvalidConfig("callback exception")
                  _ => {
                    hold_scope.get()
                    Ok(())
                  }
                }
              },
              if exit == 4 {
                Some(Deadline::after_ms(100))
              } else {
                None
              },
            )
          })
          returning.get()
          if exit == 3 {
            task.cancel()
          }
          if exit == 1 {
            assert_eq(task.wait(), Err("business error"))
          } else {
            let error = expect_pgpool_error_async(() => task.wait())
            match exit {
              0 => assert_true(error is PoolError::OperationInProgress)
              2 =>
                assert_true(
                  error is PoolError::InvalidConfig("callback exception"),
                )
              3 => assert_true(error is @async.WaitedTaskAlreadyCancelled)
              _ => assert_true(error is PoolError::Timeout(Query))
            }
          }
          let state = saved.val.unwrap().state
          assert_eq(record.status(), OutcomeUnknown)
          assert_true(state.releasing.val && state.released.val)
          assert_true(state.connection.client.val is None)
          assert_true(
            state.connection.failure.val is Some(PoolError::OperationInProgress),
          )
          assert_true(
            expect_pgpool_error_async(() => {
              saved.val.unwrap().check_connection()
            })
            is PoolError::ScopeExpired,
          )
          for parent in parents {
            assert_eq(parent.active_ops.val, 0)
            assert_true(parent.gate.try_acquire())
            parent.gate.release()
          }
          assert_eq(pool.status().size, 0)
          assert_eq(pool.shared.idle.length(), 0)
          for sql in probe.sql {
            assert_true(
              sql == "seed" || sql == "BEGIN" || sql.has_prefix("SAVEPOINT"),
            )
          }
          let mut completions = 0
          let mut replacements = 0
          while pool.shared.events.try_get() is Some(event) {
            if event.kind == TransactionCompleted &&
              event.scope_id == Some(state.id) {
              completions += 1
              assert_eq(event.transaction_status, Some(OutcomeUnknown))
              assert_true(event.cause is Some(PoolError::OperationInProgress))
            }
            if event.kind == ConnectionReplaced {
              replacements += 1
              assert_true(event.cause is Some(PoolError::OperationInProgress))
            }
          }
          assert_eq(completions, 1)
          assert_eq(replacements, 1)
          release_callback.put(())
          ignore(old_task.val.unwrap().wait()) catch {
            PoolError::ScopeExpired | @async.WaitedTaskAlreadyCancelled => ()
            PoolError::Timeout(Query) if exit == 4 => ()
            error => raise error
          }
          assert_eq(state.active_ops.val, 0)
          assert_true(state.gate.try_acquire())
          state.gate.release()
          // No double notification or capacity return from late child cleanup.
          while pool.shared.events.try_get() is Some(event) {
            assert_true(event.kind != TransactionCompleted)
          }
          assert_true(pool.shared.slots.try_get() is Some(_))
          assert_true(pool.shared.slots.try_get() is None)
        },
        cache_capacity=0,
        event_capacity=64,
      )
    }
  }
}

///|
async test "escaped transaction prepared cleanup cannot interrupt the next borrower" {
  for
    (capacity, evict, reset) in [
      (0, false, PreserveSession),
      (1, false, PreserveSession),
      (1, true, PreserveSession),
      (0, false, DiscardAll),
    ] {
    with_control_pool(
      Normal,
      (group, pool, probe) => {
        let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
        let release_callback : @async.Queue[Unit] = Queue(kind=Unbounded)
        defer release_callback.close()
        let saved : @ref.Ref[Transaction?] = Ref(None)
        let old_task : @ref.Ref[@async.Task[Unit]?] = Ref(None)
        let record = TransactionRecord()
        let error = expect_pgpool_error_async(() => {
          pool.with_transaction(
            tx => {
              saved.val = Some(tx)
              old_task.val = Some(
                group.spawn(allow_failure=true, () => {
                  tx.with_prepared("select 1", prepared => {
                    entered.put(())
                    release_callback.get()
                    assert_true(
                      expect_pgpool_error_async(() => prepared.query_all())
                      is PoolError::ScopeExpired,
                    )
                  })
                }),
              )
              entered.get()
              if evict {
                tx.with_prepared("select 2", _ => ())
              }
              (Ok(()) : Result[Unit, String])
            },
            record~,
          )
        })
        assert_true(error is PoolError::OperationInProgress)
        assert_eq(record.status(), OutcomeUnknown)
        assert_true(probe.sql == ["BEGIN"])
        let old = saved.val.unwrap().state
        assert_true(old.connection.client.val is None)
        assert_eq(old.active_ops.val, 1)
        assert_eq(pool.shared.idle.length(), 0)
        assert_eq(pool.status().size, 0)
        assert_true(old_task.val.unwrap().try_wait() is None)
        let next = pool.checkout_session()
        assert_true(next.state.connection.id != old.connection.id)
        let query = group.spawn(allow_failure=true, () => {
          next.batch_execute("blocked")
        })
        probe.query_started.get()
        while probe.close_started.try_get() is Some(_) {

        }
        release_callback.put(())
        // Temporary/evicted handles can fail to clean up the retired scope.
        ignore(old_task.val.unwrap().wait()) catch {
          PoolError::ScopeExpired => ()
          error => raise error
        }
        assert_eq(old.active_ops.val, 0)
        assert_true(probe.close_started.try_get() is None)
        assert_true(query.try_wait() is None)
        assert_eq(pool.status().available, 0)
        probe.release_query.put(())
        query.wait()
        next.check_connection()
        next.release()
        next.release()
        assert_true(pool.shared.slots.try_get() is Some(_))
        assert_true(pool.shared.slots.try_get() is None)
      },
      cache_capacity=capacity,
      reset~,
    )
  }
}

///|
async test "transaction exit aborts escaped SQL and frees capacity before its user task ends" {
  with_control_pool(Normal, (group, pool, probe) => {
    let failed : @async.Queue[Error] = Queue(kind=Unbounded)
    let release_user : @async.Queue[Unit] = Queue(kind=Unbounded)
    defer release_user.close()
    let saved : @ref.Ref[Transaction?] = Ref(None)
    let old_task : @ref.Ref[@async.Task[Unit]?] = Ref(None)
    let record = TransactionRecord()
    assert_true(
      expect_pgpool_error_async(() => {
        pool.with_transaction(
          tx => {
            saved.val = Some(tx)
            old_task.val = Some(
              group.spawn(allow_failure=true, () => {
                let error = expect_pgpool_error_async(() => {
                  tx.batch_execute("blocked")
                })
                failed.put(error)
                release_user.get()
              }),
            )
            probe.query_started.get()
            assert_eq(tx.state.active_ops.val, 1)
            (Ok(()) : Result[Unit, Unit])
          },
          record~,
        )
      })
      is PoolError::OperationInProgress,
    )
    assert_eq(record.status(), OutcomeUnknown)
    assert_true(failed.get() is @client.ClientError::Closed(_))
    assert_true(probe.sql == ["BEGIN", "blocked"])
    let old = saved.val.unwrap().state
    assert_true(old.connection.client.val is None)
    assert_eq(old.active_ops.val, 0)
    assert_true(old.gate.try_acquire())
    old.gate.release()
    assert_true(old_task.val.unwrap().try_wait() is None)
    pool.with_session(next => {
      assert_true(next.state.connection.id != old.connection.id)
      next.batch_execute("next")
    })
    assert_true(old_task.val.unwrap().try_wait() is None)
    release_user.put(())
    old_task.val.unwrap().wait()
    assert_true(pool.shared.slots.try_get() is Some(_))
    assert_true(pool.shared.slots.try_get() is None)
  })
}

///|
async test "escaped transaction COPY callback cannot delay pool shutdown" {
  with_control_pool(Normal, (group, pool, _) => {
    let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
    let release_callback : @async.Queue[Unit] = Queue(kind=Unbounded)
    defer release_callback.close()
    let old_task = Ref(None)
    let record = TransactionRecord()
    assert_true(
      expect_pgpool_error_async(() => {
        pool.with_transaction(
          tx => {
            old_task.val = Some(
              group.spawn(allow_failure=true, () => {
                tx.with_copy_out("copy out", stream => {
                  entered.put(())
                  release_callback.get()
                  assert_true(
                    expect_pgpool_error_async(() => stream.next())
                    is PoolError::ScopeExpired,
                  )
                })
              }),
            )
            entered.get()
            (Ok(()) : Result[Unit, Unit])
          },
          record~,
        )
      })
      is PoolError::OperationInProgress,
    )
    assert_eq(record.status(), OutcomeUnknown)
    assert_eq(pool.status().size, 0)
    // Shutdown must finish even while the application retains the raw permit.
    pool.close()
    pool.shared.done.wait()
    assert_true(old_task.val.unwrap().try_wait() is None)
    release_callback.put(())
    assert_true(
      expect_pgpool_error_async(() => old_task.val.unwrap().wait())
      is PoolError::ScopeExpired,
    )
  })
}

///|
async test "completed transaction children retain normal commit savepoint release and reuse" {
  for entry in 0..<4 {
    for capacity in [0, 1] {
      with_control_pool(
        Normal,
        (_, pool, probe) => {
          let parents : Array[ClientLeaseState] = []
          let record = TransactionRecord()
          let saved : @ref.Ref[Transaction?] = Ref(None)
          assert_eq(
            run_transaction_entry(
              pool,
              entry,
              parents,
              record,
              tx => {
                saved.val = Some(tx)
                tx.with_prepared("select 1", prepared => {
                  assert_eq(prepared.query_all().length(), 0)
                })
                tx.with_transaction(child => {
                  child.check_connection()
                  (Ok(()) : Result[Unit, String])
                })
              },
              None,
            ),
            Ok(()),
          )
          assert_eq(
            record.status(),
            if entry < 2 {
              Committed
            } else {
              SavepointReleased
            },
          )
          let state = saved.val.unwrap().state
          assert_eq(state.active_ops.val, 0)
          assert_eq(pool.status().size, 1)
          let next = pool.checkout_session()
          assert_eq(next.state.connection.id, state.connection.id)
          next.check_connection()
          next.release()
          assert_true(probe.sql.contains("COMMIT"))
          assert_true(
            probe.sql.iter().any(sql => sql.has_prefix("RELEASE SAVEPOINT")),
          )
          assert_true(pool.shared.slots.try_get() is Some(_))
          assert_true(pool.shared.slots.try_get() is None)
        },
        cache_capacity=capacity,
      )
    }
  }
}
