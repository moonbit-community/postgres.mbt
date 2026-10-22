///|
priv enum CompletionReply {
  Success
  SqlError
  Disconnect
  TagOnly
  RollbackTag
  Timeout
}

///|
async fn check_transaction_completion_exit(cancel~ : Bool) -> Unit {
  for savepoint in [false, true] {
    for reply in [Success, SqlError, Disconnect, TagOnly, RollbackTag, Timeout] {
      if savepoint && reply is RollbackTag {
        continue
      }
      let fault = match reply {
        Success | Timeout => HoldCommit
        SqlError => HoldCommitError
        Disconnect => HoldCommitDisconnect
        TagOnly => HoldCommitTagOnly
        RollbackTag => HoldCommitRollback
      }
      with_control_pool(
        fault,
        (group, pool, probe) => {
          let record = TransactionRecord()
          let parent_record = TransactionRecord()
          let saved : @ref.Ref[Transaction?] = Ref(None)
          let caught : @ref.Ref[Error?] = Ref(None)
          let continued = Ref(false)
          let task = group.spawn(allow_failure=true, () => {
            let callback : async (Transaction) -> Result[Int32, String] = tx => {
              saved.val = Some(tx)
              Ok(7)
            }
            let result = try {
              if savepoint {
                pool.with_transaction(
                  parent => {
                    parent.with_savepoint("completion", callback, record~)
                  },
                  record=parent_record,
                )
              } else {
                pool.with_transaction(callback, record~)
              }
            } catch {
              error => {
                caught.val = Some(error)
                Err("caught completion error")
              }
            }
            continued.val = true
            result
          })
          probe.query_started.get()
          let state = saved.val.unwrap().state
          assert_eq(record.status(), InProgress)
          assert_true(task.try_wait() is None)
          assert_true(pool.shared.slots.try_get() is None)
          if cancel {
            task.cancel()
          }
          if !(reply is Timeout) {
            probe.release_query.put(())
          }
          // A successful uncancelled savepoint is followed by outer COMMIT.
          if savepoint && !cancel && reply is Success {
            probe.query_started.get()
            assert_eq(record.status(), SavepointReleased)
            probe.release_query.put(())
          }
          if cancel {
            assert_true(
              expect_pgpool_error_async(() => task.wait())
              is @async.WaitedTaskAlreadyCancelled,
            )
            assert_true(caught.val is None)
            assert_false(continued.val)
          } else {
            let result = task.wait()
            assert_true(continued.val)
            match reply {
              Success => {
                assert_eq(result, Ok(7))
                assert_true(caught.val is None)
              }
              SqlError =>
                assert_true(
                  caught.val
                  is Some(
                    @client.ClientError::Database({ code: Some("40001"), .. })
                  ),
                )
              Disconnect | Timeout =>
                assert_true(caught.val is Some(PoolError::CommitOutcomeUnknown))
              TagOnly => assert_true(caught.val is Some(_))
              RollbackTag =>
                assert_true(caught.val is Some(PoolError::CommitRolledBack))
            }
          }
          let status = match reply {
            Success | TagOnly =>
              if savepoint {
                SavepointReleased
              } else {
                Committed
              }
            RollbackTag => RolledBack
            _ => OutcomeUnknown
          }
          assert_eq(record.status(), status)
          let reusable = reply is (Success | RollbackTag)
          if savepoint {
            assert_eq(
              parent_record.status(),
              if reply is Success {
                if cancel {
                  RolledBack
                } else {
                  Committed
                }
              } else {
                OutcomeUnknown
              },
            )
            let expected = [
              "BEGIN", "SAVEPOINT \"completion\"", "RELEASE SAVEPOINT \"completion\"",
            ]
            if reply is Success {
              expected.push(if cancel { "ROLLBACK" } else { "COMMIT" })
            }
            assert_true(probe.sql == expected)
          } else {
            assert_true(probe.sql == ["BEGIN", "COMMIT"])
          }
          assert_eq(state.active_ops.val, 0)
          assert_true(state.releasing.val && state.released.val)
          assert_true(state.gate.try_acquire())
          state.gate.release()
          assert_eq(pool.status().size, if reusable { 1 } else { 0 })
          assert_eq(pool.status().available, if reusable { 1 } else { 0 })
          assert_true(probe.cancel_started.try_get() is None)
          let mut completions = 0
          while pool.shared.events.try_get() is Some(event) {
            if event.kind == TransactionCompleted &&
              event.scope_id == Some(state.id) {
              completions += 1
              assert_eq(event.transaction_status, Some(status))
              if reply is Timeout {
                assert_true(event.cause is Some(PoolError::Timeout(Cleanup)))
              }
            }
          }
          assert_eq(completions, 1)
          assert_returned_capacity(pool)
          let next = pool.checkout_session()
          assert_eq(next.state.connection.id == state.connection.id, reusable)
          next.batch_execute("next")
          next.release()
          assert_returned_capacity(pool)
        },
        cleanup_ms=if reply is Timeout { 40 } else { 1000 },
        event_capacity=64,
      )
    }
  }
}

///|
async test "COMMIT and RELEASE cancellation follows recording across success SQL error disconnect and timeout" {
  check_transaction_completion_exit(cancel=true)
}

///|
async test "COMMIT and RELEASE keep completion errors and records without cancellation" {
  check_transaction_completion_exit(cancel=false)
}

///|
async test "precommit gate failure still rolls back after the callback returned" {
  with_control_pool(Normal, (_, pool, probe) => {
    let record = TransactionRecord()
    let gate : @ref.Ref[@async.Mutex?] = Ref(None)
    assert_true(
      expect_pgpool_error_async(() => {
        pool.with_transaction(
          tx => {
            // Inject a preflight failure without an active child or any
            // completion SQL; normal completion must own conditional rollback.
            assert_true(tx.state.gate.try_acquire())
            gate.val = Some(tx.state.gate)
            (Ok(()) : Result[Unit, String])
          },
          record~,
        )
      })
      is PoolError::OperationInProgress,
    )
    gate.val.unwrap().release()
    assert_eq(record.status(), RolledBack)
    assert_true(probe.sql == ["BEGIN", "ROLLBACK"])
    assert_eq(pool.status().available, 1)
    assert_returned_capacity(pool)
  })
}
