///|
async test "cancelled COMMIT timeout bypasses catch and caller continuation" {
  with_control_pool(
    HoldCommit,
    (group, pool, probe) => {
      let caught = Ref(false)
      let continued = Ref(false)
      let record = TransactionRecord()
      let task = group.spawn(allow_failure=true, () => {
        ignore(
          pool.with_transaction(_ => (Ok(7) : Result[Int32, String]), record~),
        ) catch {
          _ => caught.val = true
        }
        continued.val = true
      })
      probe.query_started.get()
      assert_eq(record.status(), InProgress)
      task.cancel()
      assert_true(
        expect_pgpool_error_async(() => task.wait())
        is @async.WaitedTaskAlreadyCancelled,
      )
      assert_false(caught.val)
      assert_false(continued.val)
      assert_eq(record.status(), OutcomeUnknown)
      assert_true(probe.sql == ["BEGIN", "COMMIT"])
      assert_eq(pool.status().size, 0)
      assert_returned_capacity(pool)
    },
    cleanup_ms=40,
  )
}

///|
priv enum RollbackEntry {
  SessionTransaction
  NamedSavepoint
  NestedTransaction
}

///|
async fn check_transaction_rollback_exit(
  cancel~ : Bool,
  callback_raises~ : Bool,
) -> Unit {
  for entry in [SessionTransaction, NamedSavepoint, NestedTransaction] {
    for rollback_completes in [true, false] {
      with_control_pool(
        HoldRollback,
        (group, pool, probe) => {
          let after_scope = Ref(false)
          let after_session = Ref(false)
          let record = TransactionRecord()
          let parent_record = TransactionRecord()
          let saved : @ref.Ref[Transaction?] = Ref(None)
          let parents : Array[ClientLeaseState] = []
          let task = group.spawn(allow_failure=true, () => {
            let result = pool.with_session(session => {
              parents.push(session.state)
              let callback : async (Transaction) -> Result[Unit, String] = tx => {
                saved.val = Some(tx)
                if callback_raises {
                  raise PoolError::InvalidConfig("callback exception")
                }
                Err("business error")
              }
              match entry {
                SessionTransaction => {
                  let result = session.with_transaction(callback, record~)
                  after_scope.val = true
                  result
                }
                NamedSavepoint | NestedTransaction =>
                  session.with_transaction(
                    parent => {
                      parents.push(parent.state)
                      let result = match entry {
                        NamedSavepoint =>
                          parent.with_savepoint("cancelled", callback, record~)
                        _ => parent.with_transaction(callback, record~)
                      }
                      after_scope.val = true
                      result
                    },
                    record=parent_record,
                  )
              }
            })
            after_session.val = true
            result
          })
          // Cancellation arrives after the business callback has exited and
          // rollback is waiting for its protected server response.
          probe.query_started.get()
          let state = saved.val.unwrap().state
          let cleanup_deadline = state.cleanup_deadline.val.unwrap().at
          assert_eq(record.status(), InProgress)
          assert_false(after_scope.val)
          assert_true(task.try_wait() is None)
          assert_eq(pool.status().available, 0)
          assert_true(pool.shared.slots.try_get() is None)
          let started = @async.now()
          if cancel {
            task.cancel()
            assert_true(task.try_wait() is None)
            assert_eq(pool.status().available, 0)
            assert_true(pool.shared.slots.try_get() is None)
          }
          if rollback_completes {
            probe.release_query.put(())
            match entry {
              SessionTransaction => ()
              NamedSavepoint | NestedTransaction => {
                // The enclosing transaction must roll back on the same
                // connection, including when cancellation unwinds the child.
                probe.query_started.get()
                assert_eq(record.status(), RolledBack)
                assert_eq(parent_record.status(), InProgress)
                assert_eq(after_scope.val, !cancel && !callback_raises)
                if cancel || callback_raises {
                  assert_eq(
                    state.cleanup_deadline.val.unwrap().at,
                    cleanup_deadline,
                  )
                }
                assert_true(task.try_wait() is None)
                assert_true(pool.shared.slots.try_get() is None)
                probe.release_query.put(())
              }
            }
          }
          if callback_raises {
            assert_true(
              expect_pgpool_error_async(() => task.wait())
              is PoolError::InvalidConfig("callback exception"),
            )
          } else if cancel {
            assert_true(
              expect_pgpool_error_async(() => task.wait())
              is @async.WaitedTaskAlreadyCancelled,
            )
          } else {
            assert_eq(task.wait(), Err("business error"))
          }
          assert_true(@async.now() - started < 600L)
          assert_eq(after_scope.val, !cancel && !callback_raises)
          assert_eq(after_session.val, !cancel && !callback_raises)
          if cancel || callback_raises {
            assert_eq(state.cleanup_deadline.val.unwrap().at, cleanup_deadline)
          }
          let status = if rollback_completes {
            RolledBack
          } else {
            OutcomeUnknown
          }
          assert_eq(record.status(), status)
          let expected_sql = ["BEGIN"]
          if saved.val.unwrap().savepoint is Some(name) {
            assert_eq(parent_record.status(), status)
            expected_sql.push("SAVEPOINT \{name}")
            expected_sql.push(
              "ROLLBACK TO SAVEPOINT \{name}; RELEASE SAVEPOINT \{name}",
            )
            if rollback_completes {
              expected_sql.push("ROLLBACK")
            }
          } else {
            assert_eq(parent_record.status(), NotStarted)
            expected_sql.push("ROLLBACK")
          }
          assert_true(probe.sql == expected_sql)
          assert_true(probe.cancel_started.try_get() is None)
          assert_eq(state.active_ops.val, 0)
          assert_true(state.releasing.val && state.released.val)
          assert_true(state.gate.try_acquire())
          state.gate.release()
          for parent in parents {
            assert_eq(parent.active_ops.val, 0)
            assert_true(parent.gate.try_acquire())
            parent.gate.release()
          }
          assert_eq(pool.status().size, if rollback_completes { 1 } else { 0 })
          assert_eq(
            pool.status().available,
            if rollback_completes {
              1
            } else {
              0
            },
          )
          assert_eq(
            pool.shared.connections.length(),
            if rollback_completes {
              1
            } else {
              0
            },
          )
          if !rollback_completes {
            assert_true(state.connection.client.val is None)
            assert_true(
              state.connection.failure.val is Some(PoolError::Timeout(Cleanup)),
            )
            // Let the retired backend leave its barrier after client abort.
            probe.release_query.put(())
          }
          let mut completions = 0
          while pool.shared.events.try_get() is Some(event) {
            if event.kind == TransactionCompleted {
              completions += 1
              assert_eq(event.transaction_status, Some(status))
              if rollback_completes {
                assert_true(event.cause is None)
              } else {
                assert_true(event.cause is Some(PoolError::Timeout(Cleanup)))
              }
            }
          }
          assert_eq(
            completions,
            if saved.val.unwrap().savepoint is None {
              1
            } else {
              2
            },
          )
          assert_returned_capacity(pool)
          let next = pool.checkout_session()
          assert_eq(
            next.state.connection.id == state.connection.id,
            rollback_completes,
          )
          next.batch_execute("next")
          next.release()
          assert_eq(pool.status().available, 1)
          assert_returned_capacity(pool)
        },
        cleanup_ms=if rollback_completes { 1000 } else { 40 },
        event_capacity=64,
      )
    }
  }
}

///|
async test "transaction entries propagate cancellation during rollback success or timeout" {
  check_transaction_rollback_exit(cancel=true, callback_raises=false)
}

///|
async test "transaction rollback preserves business Err without cancellation" {
  check_transaction_rollback_exit(cancel=false, callback_raises=false)
}

///|
async test "transaction callback exception wins over cancellation during rollback" {
  check_transaction_rollback_exit(cancel=true, callback_raises=true)
}
