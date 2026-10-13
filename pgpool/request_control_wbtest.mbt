// Deterministic backend faults; no PostgreSQL installation is needed.

///|
priv enum BackendFault {
  Normal
  LostCommit
  CommitTagOnly
  CommitRollback
  BlockQuery
  IgnoreCancel
  HoldCancel
  HoldReset
  HoldCommit
  HoldRollback
  HoldClose
  HoldCloseCancel
}

///|
priv struct ProtocolProbe {
  sql : Array[String]
  query_started : @async.Queue[Unit]
  cancel_started : @async.Queue[Unit]
  release_query : @async.Queue[Unit]
  release_cancel : @async.Queue[Unit]
  close_started : @async.Queue[Unit]
  release_close : @async.Queue[Unit]
}

///|
async fn send_command(
  socket : @socket.Tcp,
  tag : String,
  status : Byte,
) -> Unit {
  let bytes = @proto.utf8_encode(tag)
  let buffer = @buffer.Buffer()
  buffer.write_byte(b'C')
  buffer.write_int_be(bytes.length() + 5)
  buffer.write_bytes(bytes)
  buffer.write_byte(b'\x00')
  buffer.write_bytes([b'Z', 0, 0, 0, 5, status])
  socket.write(buffer.to_bytes())
}

///|
async fn serve_control_backend(
  socket : @socket.Tcp,
  fault : BackendFault,
  probe : ProtocolProbe,
) -> Unit {
  defer socket.close()
  let header = socket.read_exactly(4)
  let size = @proto.ByteReader::new(header[:]).read_i32_be()
  ignore(socket.read_exactly(size - 4))
  if size == 16 {
    probe.cancel_started.put(())
    match fault {
      HoldCancel | HoldCloseCancel => probe.release_cancel.get()
      IgnoreCancel | HoldClose => ()
      _ => probe.release_query.put(())
    }
    return
  }
  socket.write(
    b"R\x00\x00\x00\x08\x00\x00\x00\x00K\x00\x00\x00\x0c\x00\x00\x00\x01\x00\x00\x00\x02Z\x00\x00\x00\x05I",
  )
  let mut status = b'I'
  while true {
    guard socket.read_some(max_len=1) is Some(tag) else { return }
    let header = socket.read_exactly(4)
    let size = @proto.ByteReader::new(header[:]).read_i32_be()
    let bytes = socket.read_exactly(size - 4)
    match tag[0] {
      b'X' => return
      b'P' => socket.write(b"1\x00\x00\x00\x04")
      b'D' => socket.write(b"t\x00\x00\x00\x06\x00\x00n\x00\x00\x00\x04")
      b'B' => socket.write(b"2\x00\x00\x00\x04")
      b'E' => socket.write(b"C\x00\x00\x00\x0dSELECT 0\x00")
      b'C' => {
        probe.close_started.put(())
        if fault is (HoldClose | HoldCloseCancel) {
          probe.release_close.get()
        }
        socket.write(b"3\x00\x00\x00\x04")
      }
      b'S' => socket.write(([b'Z', 0, 0, 0, 5, status] : Bytes))
      b'Q' => {
        let sql = @utf8.decode(bytes[:bytes.length() - 1])
        probe.sql.push(sql)
        if sql == "copy out" {
          socket.write(
            b"H\x00\x00\x00\x07\x00\x00\x00d\x00\x00\x00\x06x\nc\x00\x00\x00\x04C\x00\x00\x00\x0bCOPY 1\x00",
          )
          socket.write(([b'Z', 0, 0, 0, 5, status] : Bytes))
          continue
        }
        if sql == "blocked" {
          probe.query_started.put(())
          probe.release_query.get()
        }
        if sql == "DISCARD ALL" && fault is HoldReset {
          probe.query_started.put(())
          probe.release_query.get()
        }
        if sql.has_prefix("ROLLBACK") && fault is HoldRollback {
          probe.query_started.put(())
          probe.release_query.get()
        }
        if sql == "COMMIT" {
          match fault {
            HoldCommit => {
              probe.query_started.put(())
              probe.release_query.get()
            }
            LostCommit => return
            CommitTagOnly => {
              socket.write(b"C\x00\x00\x00\x0bCOMMIT\x00")
              return
            }
            CommitRollback => {
              send_command(socket, "ROLLBACK", b'I')
              continue
            }
            _ => ()
          }
        }
        let tag = if sql.has_prefix("BEGIN") {
          status = b'T'
          "BEGIN"
        } else if sql == "COMMIT" || sql == "ROLLBACK" {
          status = b'I'
          sql
        } else if sql.has_prefix("SAVEPOINT") {
          "SAVEPOINT"
        } else if sql.has_prefix("RELEASE") {
          "RELEASE"
        } else if sql.has_prefix("ROLLBACK TO") {
          "RELEASE"
        } else {
          "SELECT 0"
        }
        send_command(socket, tag, status)
      }
      _ => fail("unexpected control backend request")
    }
  }
}

///|
async fn with_control_pool(
  fault : BackendFault,
  f : async (@async.TaskGroup[Unit], Pool, ProtocolProbe) -> Unit,
  cleanup_ms~ : Int32 = 200,
  reset~ : ResetPolicy = PreserveSession,
  health~ : HealthCheck = Passive,
  cache_capacity~ : Int32 = 100,
  event_capacity~ : Int32 = 2,
  options~ : PoolOptions = PoolOptions(),
) -> Unit {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let probe : ProtocolProbe = {
      sql: [],
      query_started: Queue(kind=Unbounded),
      cancel_started: Queue(kind=Unbounded),
      release_query: Queue(kind=Unbounded),
      release_cancel: Queue(kind=Unbounded),
      close_started: Queue(kind=Unbounded),
      release_close: Queue(kind=Unbounded),
    }
    group.spawn_bg(no_wait=true, () => {
      while true {
        let (socket, _) = server.accept()
        group.spawn_bg(no_wait=true, allow_failure=true, () => {
          serve_control_backend(socket, fault, probe)
        })
      }
    })
    let pool = start_test_pool(
      Config(
        [ConnectionTarget(host="127.0.0.1", port=server.addr.port())],
        user="moon",
        ssl_mode=Disable,
        application_name="control-probe",
        pool=PoolConfig(
          1,
          cleanup_ms~,
          reset_policy=reset,
          health_check=health,
          statement_cache_capacity=cache_capacity,
          event_capacity~,
        ),
      ),
      group,
      options~,
    )
    defer {
      for connection in pool.shared.connections {
        if connection.client.val is Some(client) {
          client.abort()
        }
      }
      pool.close()
    }
    // A timeout cannot interrupt regressed protected I/O. Independently abort
    // sockets so a failing regression reports an assertion instead of hanging.
    let watchdog = group.spawn(allow_failure=true, () => {
      @async.sleep(2500)
      for connection in pool.shared.connections {
        if connection.client.val is Some(client) {
          client.abort()
        }
      }
    })
    defer watchdog.cancel()
    @async.with_timeout(3000, () => f(group, pool, probe))
  })
}

///|
async test "late cancel fences original protocol completion and the next borrower" {
  with_control_pool(HoldCancel, (group, pool, probe) => {
    let task = group.spawn(allow_failure=true, () => {
      pool.batch_execute("blocked")
    })
    probe.query_started.get()
    task.cancel()
    probe.cancel_started.get()
    probe.release_query.put(())
    // The original query is done, but the cancel packet is still outstanding.
    @async.sleep(10)
    assert_true(task.try_wait() is None)
    assert_eq(pool.status().available, 0)
    assert_true(pool.shared.slots.try_get() is None)
    probe.release_cancel.put(())
    assert_true(
      expect_pgpool_error_async(() => task.wait())
      is @async.WaitedTaskAlreadyCancelled,
    )
    pool.batch_execute("next")
    assert_true(probe.sql == ["blocked", "next"])
    assert_eq(pool.status().size, 1)
    assert_true(pool.shared.slots.try_get() is Some(_))
    assert_true(pool.shared.slots.try_get() is None)
  })
}

///|
async test "blocked cancel connection and unresponsive SQL each retire within one cleanup budget" {
  for fault in [HoldCancel, IgnoreCancel] {
    with_control_pool(
      fault,
      (group, pool, probe) => {
        let task = group.spawn(allow_failure=true, () => {
          pool.batch_execute("blocked")
        })
        probe.query_started.get()
        let started = @async.now()
        task.cancel()
        assert_true(
          expect_pgpool_error_async(() => task.wait())
          is @async.WaitedTaskAlreadyCancelled,
        )
        assert_true(@async.now() - started < 600L)
        assert_eq(pool.status().size, 0)
        assert_eq(pool.status().available, 0)
        assert_true(pool.shared.slots.try_get() is Some(_))
        assert_true(pool.shared.slots.try_get() is None)
      },
      cleanup_ms=40,
    )
  }
}

///|
async test "query deadline cancels SQL and preserves the timeout phase" {
  with_control_pool(BlockQuery, (_, pool, probe) => {
    // Start the query budget after startup; a cold connection can legitimately
    // consume the whole budget and report Create instead under a loaded runtime.
    pool.with_session(session => {
      assert_true(
        expect_pgpool_error_async(() => {
          session.batch_execute("blocked", deadline=Deadline::after_ms(30))
        })
        is PoolError::Timeout(Query),
      )
    })
    assert_true(probe.cancel_started.try_get() is Some(_))
    assert_eq(pool.status().available, 1)
  })
}

///|
async test "transaction command tags distinguish commit rollback and unknown outcomes" {
  for fault in [Normal, LostCommit, CommitTagOnly, CommitRollback] {
    with_control_pool(fault, (_, pool, probe) => {
      let record = TransactionRecord()
      let result = try
        pool.with_transaction(_ => (Ok(7) : Result[Int32, String]), record~)
      catch {
        error => Err(error)
      } noraise {
        value => Ok(value)
      }
      match fault {
        Normal => {
          assert_true(result is Ok(Ok(7)))
          assert_eq(record.status(), Committed)
        }
        LostCommit => {
          assert_true(result is Err(PoolError::CommitOutcomeUnknown))
          assert_eq(record.status(), OutcomeUnknown)
        }
        CommitTagOnly => {
          assert_true(result is Err(_))
          assert_eq(record.status(), Committed)
        }
        CommitRollback => {
          assert_true(result is Err(PoolError::CommitRolledBack))
          assert_eq(record.status(), RolledBack)
        }
        _ => fail("unexpected fault")
      }
      assert_true(probe.sql == ["BEGIN", "COMMIT"])
      assert_true(pool.dropped_events() > 0L)
      // Event overflow cannot erase the independent record.
      assert_true(record.status() != NotStarted)
    })
  }
}

///|
async test "business error rolls back and record cannot be reused" {
  with_control_pool(Normal, (_, pool, probe) => {
    let record = TransactionRecord()
    let result : Result[Int32, String] = pool.with_transaction(
      _ => Err("business"),
      record~,
    )
    assert_eq(result, Err("business"))
    assert_eq(record.status(), RolledBack)
    assert_true(probe.sql == ["BEGIN", "ROLLBACK"])
    assert_true(
      expect_pgpool_error_async(() => {
        pool.with_transaction(_ => (Ok(()) : Result[Unit, Unit]), record~)
      })
      is PoolError::TransactionRecordUsed,
    )
    assert_eq(probe.sql.length(), 2)
  })
}

///|
async test "nested scope restores parent and savepoint record never claims commit" {
  with_control_pool(Normal, (_, pool, _) => {
    let child_record = TransactionRecord()
    let parent_record = TransactionRecord()
    let saved : @ref.Ref[Transaction?] = Ref(None)
    let result : Result[Unit, String] = pool.with_session(session => {
      session.with_transaction(
        tx => {
          assert_true(
            expect_pgpool_error_async(() => session.check_connection())
            is PoolError::OperationInProgress,
          )
          let child : Result[Unit, String] = tx.with_savepoint(
            "child",
            nested => {
              saved.val = Some(nested)
              assert_true(
                expect_pgpool_error_async(() => tx.check_connection())
                is PoolError::OperationInProgress,
              )
              nested.check_connection()
              Ok(())
            },
            record=child_record,
          )
          assert_eq(child, Ok(()))
          assert_eq(child_record.status(), SavepointReleased)
          assert_eq(parent_record.status(), InProgress)
          tx.check_connection()
          assert_true(
            expect_pgpool_error_async(() => {
              saved.val.unwrap().check_connection()
            })
            is PoolError::ScopeExpired,
          )
          Err("rollback parent")
        },
        record=parent_record,
      )
    })
    assert_eq(result, Err("rollback parent"))
    assert_eq(parent_record.status(), RolledBack)
    assert_eq(child_record.status(), SavepointReleased)
  })
}

///|
async test "normal return waits for bounded reset before restoring capacity" {
  with_control_pool(
    HoldReset,
    (group, pool, probe) => {
      let task = group.spawn(() => pool.with_session(_ => 7))
      probe.query_started.get()
      assert_eq(pool.status().available, 0)
      assert_true(pool.shared.slots.try_get() is None)
      assert_eq(task.wait(), 7)
      assert_eq(pool.status().size, 0)
      assert_true(pool.shared.slots.try_get() is Some(_))
      assert_true(pool.shared.slots.try_get() is None)
    },
    cleanup_ms=30,
    reset=DiscardAll,
  )
}

///|
async test "cancellation before commit rolls back but cancellation after submission observes commit" {
  with_control_pool(Normal, (group, pool, probe) => {
    let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
    let wait : @async.Queue[Unit] = Queue(kind=Unbounded)
    let record = TransactionRecord()
    let task = group.spawn(allow_failure=true, () => {
      pool.with_transaction(
        _ => {
          entered.put(())
          wait.get()
          (Ok(()) : Result[Unit, Unit])
        },
        record~,
      )
    })
    entered.get()
    task.cancel()
    assert_true(
      expect_pgpool_error_async(() => task.wait())
      is @async.WaitedTaskAlreadyCancelled,
    )
    assert_eq(record.status(), RolledBack)
    assert_true(probe.sql == ["BEGIN", "ROLLBACK"])
  })
  with_control_pool(HoldCommit, (group, pool, probe) => {
    let record = TransactionRecord()
    let task = group.spawn(allow_failure=true, () => {
      pool.with_transaction(_ => (Ok(()) : Result[Unit, Unit]), record~)
    })
    probe.query_started.get()
    task.cancel()
    assert_eq(record.status(), InProgress)
    probe.release_query.put(())
    assert_true(
      expect_pgpool_error_async(() => task.wait())
      is @async.WaitedTaskAlreadyCancelled,
    )
    assert_eq(record.status(), Committed)
    assert_true(probe.sql == ["BEGIN", "COMMIT"])
    assert_true(probe.cancel_started.try_get() is None)
  })
}

///|
async test "nested rollback failures share one grace period and preserve business Err" {
  with_control_pool(
    HoldRollback,
    (_, pool, _) => {
      let parent = TransactionRecord()
      let child = TransactionRecord()
      let started = @async.now()
      let result : Result[Unit, String] = pool.with_transaction(
        tx => {
          let result : Result[Unit, String] = tx.with_savepoint(
            "child",
            _ => Err("child error"),
            record=child,
          )
          assert_eq(result, Err("child error"))
          Err("parent error")
        },
        record=parent,
      )
      assert_eq(result, Err("parent error"))
      assert_true(@async.now() - started < 300L)
      assert_eq(child.status(), OutcomeUnknown)
      assert_eq(parent.status(), OutcomeUnknown)
      assert_eq(pool.status().size, 0)
      assert_true(pool.shared.slots.try_get() is Some(_))
      assert_true(pool.shared.slots.try_get() is None)
    },
    cleanup_ms=40,
  )
}

///|
async test "short child deadline cannot extend the outer deadline" {
  with_control_pool(BlockQuery, (_, pool, _) => {
    assert_true(
      expect_pgpool_error_async(() => {
        pool.with_session(
          session => {
            session.batch_execute("blocked", deadline=Deadline::after_ms(1000))
          },
          deadline=Deadline::after_ms(40),
        )
      })
      is PoolError::Timeout(Query),
    )
    assert_eq(pool.status().available, 1)
  })
}

///|
async test "host attempts consume one create budget and retain original causes" {
  @async.with_task_group(group => {
    let targets : Array[String] = []
    let pool = start_test_pool(
      Config(
        [ConnectionTarget(host="first"), ConnectionTarget(host="second")],
        user="moon",
        application_name="attempts",
        pool=PoolConfig(1, timeouts=Timeouts(create_ms=Some(60))),
      ),
      group,
      options=PoolOptions(
        connector=Connector(target => {
          targets.push(target.host)
          if target.host == "first" {
            @async.sleep(35)
            raise PoolError::InvalidConfig("first failure")
          }
          @async.sleep(1000)
          @client.Client::create(target)
        }),
      ),
    )
    defer pool.close()
    let started = @async.now()
    let error = expect_pgpool_error_async(() => pool.with_session(_ => ()))
    guard error is AcquireError::AttemptsFailed(attempts) else {
      fail("expected all attempts")
    }
    assert_eq(attempts.length(), 2)
    assert_eq(attempts[0].target, "first:5432")
    assert_true(attempts[0].cause is PoolError::InvalidConfig("first failure"))
    assert_eq(attempts[1].target, "second:5432")
    assert_true(attempts[1].cause is PoolError::Timeout(Create))
    assert_true(@async.now() - started < 180L)
    assert_true(targets == ["first", "second"])
    assert_true(pool.shared.slots.try_get() is Some(_))
    assert_true(pool.shared.slots.try_get() is None)
  })
}

///|
async test "stream methods reject overlap and enforce their own shorter deadline" {
  with_control_pool(BlockQuery, (group, pool, probe) => {
    pool.with_session(session => {
      session.with_simple_query("blocked", stream => {
        let next = group.spawn(allow_failure=true, () => {
          stream.next(deadline=Deadline::after_ms(80))
        })
        probe.query_started.get()
        assert_true(
          expect_pgpool_error_async(() => stream.next())
          is PoolError::OperationInProgress,
        )
        assert_true(
          expect_pgpool_error_async(() => session.check_connection())
          is PoolError::OperationInProgress,
        )
        assert_true(
          expect_pgpool_error_async(() => next.wait())
          is PoolError::Timeout(Query),
        )
      })
      session.check_connection()
    })
  })
}

///|
async test "health check cancellation is bounded even without a business deadline" {
  with_control_pool(
    IgnoreCancel,
    (group, pool, probe) => {
      pool.batch_execute("seed")
      let checkout = group.spawn(allow_failure=true, () => {
        pool.with_session(_ => ())
      })
      probe.query_started.get()
      let started = @async.now()
      checkout.cancel()
      assert_true(
        expect_pgpool_error_async(() => checkout.wait())
        is @async.WaitedTaskAlreadyCancelled,
      )
      assert_true(@async.now() - started < 600L)
      assert_eq(pool.status().size, 0)
      assert_true(pool.shared.slots.try_get() is Some(_))
      assert_true(pool.shared.slots.try_get() is None)
    },
    health=Custom("blocked"),
    cleanup_ms=40,
  )
}
