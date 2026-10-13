///|
async test "integration escaped transaction callbacks retire backend and cannot interrupt next borrower" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    for mode in 0..<2 {
      let pool = make_pool(
        group,
        as_client_config(config, application_name="pool-escaped-transaction"),
        PoolConfig(1, statement_cache_capacity=0, reset_policy=PreserveSession),
      )
      defer pool.close()
      let observer = start_client(
        as_client_config(config, application_name="pool-escape-observer"),
        group,
      )
      defer observer.close()
      let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
      let release_callback : @async.Queue[Unit] = Queue(kind=Unbounded)
      defer release_callback.close()
      let old_task = Ref(None)
      let old_pid = Ref(0)
      let record = @pgpool.TransactionRecord()
      let error = expect_error_async(() => {
        pool.with_transaction(
          tx => {
            old_pid.val = tx
              .query_one("select pg_backend_pid()::int4 as pid")
              .get_name("pid")
            old_task.val = Some(
              group.spawn(allow_failure=true, () => {
                if mode == 0 {
                  tx.with_prepared("select 1", prepared => {
                    entered.put(())
                    release_callback.get()
                    expect_pool_scope_expired(
                      expect_error_async(() => prepared.query_all()),
                    )
                  })
                } else {
                  tx.with_copy_out("copy (select 1) to stdout", stream => {
                    entered.put(())
                    release_callback.get()
                    expect_pool_scope_expired(
                      expect_error_async(() => stream.next()),
                    )
                  })
                }
              }),
            )
            entered.get()
            (Ok(()) : Result[Unit, Unit])
          },
          record~,
        )
      })
      assert_true(error is @pgpool.PoolError::OperationInProgress)
      assert_eq(record.status(), @pgpool.TransactionStatus::OutcomeUnknown)
      assert_eq(pool.status().size, 0)
      assert_true(old_task.val.unwrap().try_wait() is None)
      observer.batch_execute("select pg_advisory_lock(537294)")
      pool.with_session(next => {
        let unlocked = Ref(false)
        defer (if !unlocked.val {
          observer.batch_execute("select pg_advisory_unlock(537294)")
        })
        let pid : Int32 = next
          .query_one("select pg_backend_pid()::int4 as pid")
          .get_name("pid")
        assert_true(pid != old_pid.val)
        let query = group.spawn(allow_failure=true, () => {
          next
          .query_one("select pg_advisory_lock(537294), 42::int4 as value")
          .get_name("value")
        })
        // Observe the new backend waiting on the lock before resuming old cleanup.
        @async.with_timeout(3000, () => {
          while true {
            let waiting : Bool = observer
              .query_one(
                "select exists(select 1 from pg_stat_activity where pid = $1 and wait_event = 'advisory') as waiting",
                params=[pid as &@client.ToSql],
              )
              .get_name("waiting")
            if waiting {
              break
            }
          }
        })
        release_callback.put(())
        ignore(old_task.val.unwrap().wait()) catch {
          @pgpool.PoolError::ScopeExpired => ()
          error => raise error
        }
        assert_true(query.try_wait() is None)
        assert_eq(pool.status().available, 0)
        observer.batch_execute("select pg_advisory_unlock(537294)")
        unlocked.val = true
        assert_eq(query.wait(), (42 : Int32))
        next.check_connection()
      })
      assert_eq(pool.status().available, 1)
      assert_eq(record.status(), @pgpool.TransactionStatus::OutcomeUnknown)
    }
  })
}

///|
async test "integration default reset isolates session state and restores initialization baseline" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let initializations = Ref(0)
    let pool = make_decl_pool(
      config,
      group,
      1,
      application_name="pool-isolation",
      options=PoolOptions(initialize_session=session => {
        initializations.val += 1
        session.batch_execute("SET application_name = 'application-baseline'")
      }),
    )
    defer pool.close()
    let pid : Int32 = pool.with_session(session => {
      session.batch_execute(
        "SET application_name = 'borrower'; SET search_path = pg_catalog; CREATE TEMP TABLE moon_isolation(i int); LISTEN moon_isolation; SELECT pg_advisory_lock(537291)",
      )
      session.with_prepared("select 99::int4", _ => ())
      session.query_one("select pg_backend_pid()::int4 as pid").get_name("pid")
    })
    assert_eq(initializations.val, 2)
    pool.with_session(session => {
      // Use simple protocol so this observation does not itself prepare a statement.
      let frames = session.with_simple_query(
        "select count(*)::text as n from pg_prepared_statements",
        stream => stream.collect(),
      )
      guard frames[1] is Row(row) else { fail("expected count row") }
      assert_eq(row.get_name("n"), Some("0"))
      let row = session.query_one(
        "select pg_backend_pid()::int4 as pid, current_setting('application_name') as app, current_setting('search_path') as path, to_regclass('pg_temp.moon_isolation') is null as no_temp, not exists(select 1 from pg_listening_channels()) as no_listen, not exists(select 1 from pg_locks where locktype = 'advisory' and pid = pg_backend_pid()) as no_lock",
      )
      assert_eq(row.get_name("pid"), pid)
      assert_eq(row.get_name("app"), "application-baseline")
      let path : String = row.get_name("path")
      assert_true(path != "pg_catalog")
      assert_true(row.get_name("no_temp"))
      assert_true(row.get_name("no_listen"))
      assert_true(row.get_name("no_lock"))
    })
    assert_eq(initializations.val, 3)
  })
}

///|
async test "integration result intent records rollback and failed transaction COMMIT" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="pool-intent"),
      PoolConfig(1),
    )
    defer pool.close()
    pool.with_session(session => {
      session.batch_execute("create temp table moon_intent(i int)")
      let record = @pgpool.TransactionRecord()
      let rejected : Result[Unit, String] = session.with_transaction(
        tx => {
          tx.batch_execute("insert into moon_intent values (1)")
          Err("business validation")
        },
        record~,
      )
      assert_eq(rejected, Err("business validation"))
      assert_eq(record.status(), @pgpool.TransactionStatus::RolledBack)
      assert_eq(
        session
        .query_one("select count(*)::int4 as n from moon_intent")
        .get_name("n"),
        0,
      )
      let failed = @pgpool.TransactionRecord()
      let error = expect_error_async(() => {
        session.with_transaction(
          tx => {
            ignore(expect_error_async(() => tx.batch_execute("select 1/0")))
            (Ok(()) : Result[Unit, Unit])
          },
          record=failed,
        )
      })
      assert_true(error is @pgpool.PoolError::CommitRolledBack)
      assert_eq(failed.status(), @pgpool.TransactionStatus::RolledBack)
      session.check_connection()
    })
  })
}

///|
async test "integration transaction prepared callbacks COPY and typed generic operations compose" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="pool-capabilities"),
      PoolConfig(1),
    )
    defer pool.close()
    let record = @pgpool.TransactionRecord()
    let result : Result[Unit, Unit] = pool.with_transaction(
      tx => {
        tx.batch_execute("create temp table moon_copy_tx(i int)")
        tx.with_prepared("select $1::int4 as value", prepared => {
          tx.check_connection()
          assert_eq(
            prepared.query_one(params=[7 as &@client.ToSql]).get_name("value"),
            7,
          )
          assert_eq(
            tx
            .query_typed_one(
              "select $1::int4 as value",
              [@client.Type::int4()],
              params=[8 as &@client.ToSql],
            )
            .get_name("value"),
            8,
          )
        })
        let sink = tx.with_copy_in("copy moon_copy_tx from stdin", sink => {
          sink.send(b"1\n2\n"[:])
          assert_eq(sink.finish(), 2UL)
          sink
        })
        expect_pool_scope_expired(
          expect_error_async(() => sink.send(b"3\n"[:])),
        )
        assert_true(
          tx.with_copy_out("copy moon_copy_tx to stdout", stream => {
            stream.collect()
          }) ==
          [b"1\n", b"2\n"],
        )
        let frames = tx.with_simple_query("select 1", stream => stream.collect())
        assert_eq(frames.length(), 3)
        Ok(())
      },
      record~,
    )
    assert_eq(result, Ok(()))
    assert_eq(record.status(), @pgpool.TransactionStatus::Committed)
  })
}

///|
async test "integration deadlines cancel stream and COPY and recover pool capacity" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="pool-stream-cancel"),
      PoolConfig(1, cleanup_ms=1000),
    )
    defer pool.close()
    for mode in 0..<3 {
      pool.with_session(session => {
        if mode == 2 {
          session.batch_execute("create temp table moon_copy_cancel(i int)")
        }
        let deadline = @pgpool.Deadline::after_ms(100)
        let error = expect_error_async(() => {
          match mode {
            0 =>
              session.with_stream(
                "select pg_sleep(30)",
                stream => ignore(stream.next()),
                deadline~,
              )
            1 =>
              session.with_copy_out(
                "copy (select pg_sleep(30)) to stdout",
                stream => ignore(stream.next()),
                deadline~,
              )
            _ =>
              session.with_copy_in(
                "copy moon_copy_cancel from stdin",
                sink => {
                  sink.send(b"1\n"[:])
                  @async.sleep(30000)
                },
                deadline~,
              )
          }
        })
        guard error is @pgpool.PoolError::Timeout(Query) else {
          fail("mode \{mode}: \{error}")
        }
      })
      assert_eq(
        pool.query_one("select 42::int4 as value").get_name("value"),
        42,
      )
      assert_eq(pool.status().available, 1)
    }
  })
}

///|
async test "integration return initialization failure preserves result and publishes original database error" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let calls = Ref(0)
    let pool = make_decl_pool(
      config,
      group,
      1,
      application_name="pool-hook-failure",
      options=PoolOptions(initialize_session=session => {
        calls.val += 1
        if calls.val > 1 {
          session.batch_execute("select 1/0")
        }
      }),
    )
    defer pool.close()
    assert_eq(pool.with_session(_ => 42), 42)
    assert_eq(pool.status().size, 0)
    let mut saw_database = false
    @async.with_timeout(1000, () => {
      while !saw_database {
        guard pool.next_event() is Some(event) else {
          fail("missing cleanup event")
        }
        if event.cause is Some(@client.ClientError::Database(error)) {
          assert_eq(error.code, Some("22012"))
          saw_database = true
        }
      }
    })
  })
}

///|
async test "integration PreserveSession and Reconnect are explicit reset policies" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    for
      policy in [
        @pgpool.ResetPolicy::PreserveSession,
        @pgpool.ResetPolicy::Reconnect,
      ] {
      let pool = make_pool(
        group,
        as_client_config(config, application_name="pool-reset-policy"),
        PoolConfig(1, reset_policy=policy),
      )
      let first : Int32 = pool.with_session(session => {
        session.batch_execute("SET application_name = 'preserved'")
        session
        .query_one("select pg_backend_pid()::int4 as pid")
        .get_name("pid")
      })
      let row = pool.query_one(
        "select pg_backend_pid()::int4 as pid, current_setting('application_name') as app",
      )
      let second : Int32 = row.get_name("pid")
      if policy == @pgpool.ResetPolicy::PreserveSession {
        assert_eq(first, second)
        assert_eq(row.get_name("app"), "preserved")
      } else {
        assert_true(first != second)
        assert_eq(row.get_name("app"), "pool-reset-policy")
      }
      pool.close()
    }
  })
}
