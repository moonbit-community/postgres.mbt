///|
/// Observe an actual PostgreSQL lock wait instead of guessing when SQL starts.
async fn wait_for_backend_lock(observer : @client.Client, pid : Int) -> Unit {
  @async.with_timeout(5000, () => {
    while true {
      let waiting : Bool = observer
        .query_one(
          "select exists(select 1 from pg_stat_activity where pid = $1::int4 and state = 'active' and wait_event_type = 'Lock') as waiting",
          params=[pid as &@client.ToSql],
        )
        .get_name("waiting")
      if waiting {
        return
      }
      @async.pause()
    }
  })
}

///|
/// Keep SQL blocked until cancellation has been requested, then permit the
/// protected exchange to finish and verify that cancellation still propagates.
async fn cancel_during_locked_sql(
  observer : @client.Client,
  pid : Int,
  f : async (String) -> Unit,
) -> Unit {
  observer.batch_execute("select pg_advisory_lock(91827, \{pid})")
  @async.with_task_group(group => {
    defer @async.protect_from_cancel(() => {
      observer.batch_execute("select pg_advisory_unlock(91827, \{pid})")
    })
    let task = group.spawn(allow_failure=true, () => {
      f("select pg_advisory_xact_lock(91827, \{pid})")
    })
    wait_for_backend_lock(observer, pid)
    task.cancel()
    // Task cancellation must not send a PostgreSQL cancel request by itself.
    wait_for_backend_lock(observer, pid)
    observer.batch_execute("select pg_advisory_unlock(91827, \{pid})")
    assert_true(
      expect_error_async(() => @async.with_timeout(5000, () => task.wait()))
      is @async.TaskCancelled,
    )
  })
}

///|
async test "integration client transaction cancellation during SQL rolls back writes" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let client = start_client(
      as_client_config(config, application_name="client-sql-cancel"),
      group,
    )
    defer client.abort()
    let observer = start_client(
      as_client_config(config, application_name="client-sql-cancel-observer"),
      group,
    )
    defer observer.abort()
    client.batch_execute("create temp table moon_sql_cancel(value int4)")
    for batch in [false, true] {
      cancel_during_locked_sql(observer, client.cancel_token().process_id(), sql => {
        client.with_transaction(tx => {
          tx.batch_execute("insert into moon_sql_cancel values (1)")
          if batch {
            tx.batch_execute(sql)
          } else {
            ignore(tx.execute(sql))
          }
        })
      })
      let count : Int = client
        .query_one("select count(*)::int4 as n from moon_sql_cancel")
        .get_name("n")
      assert_eq(count, 0)
    }
    client.with_transaction(tx => {
      tx.batch_execute("insert into moon_sql_cancel values (2)")
    })
    let value : Int = client
      .query_one("select value from moon_sql_cancel")
      .get_name("value")
    assert_eq(value, 2)
    client.close()
    observer.close()
  })
}

///|
async test "integration pooled transaction cancellation during SQL rolls back writes" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="pool-sql-cancel"),
      @pgpool.PoolConfig::PoolConfig(1),
    )
    defer pool.close()
    let observer = start_client(
      as_client_config(config, application_name="pool-sql-cancel-observer"),
      group,
    )
    defer observer.abort()
    pool.with_session(session => {
      session.batch_execute("create temp table moon_sql_cancel(value int4)")
      let pid : Int = session
        .query_one("select pg_backend_pid()::int4 as pid")
        .get_name("pid")
      for mode in 0..<3 {
        cancel_during_locked_sql(observer, pid, sql => {
          session.with_transaction(tx => {
            tx.batch_execute("insert into moon_sql_cancel values (1)")
            if mode == 0 {
              tx.batch_execute(sql)
            } else if mode == 1 {
              ignore(tx.execute(sql))
            } else {
              // The callback's own protection defers cancellation until the
              // auto-commit boundary rather than the operation boundary.
              @async.protect_from_cancel(() => tx.batch_execute(sql))
            }
          })
        })
        let count : Int = session
          .query_one("select count(*)::int4 as n from moon_sql_cancel")
          .get_name("n")
        assert_eq(count, 0)
      }
    })
    assert_eq(pool.status().available, 1)
    pool.with_transaction(tx => {
      tx.batch_execute("insert into moon_sql_cancel values (2)")
    })
    let value : Int = pool
      .query_one("select value from moon_sql_cancel")
      .get_name("value")
    assert_eq(value, 2)
    observer.close()
  })
}

///|
async test "integration savepoint cancellation during SQL preserves outer writes" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="savepoint-sql-cancel"),
      @pgpool.PoolConfig::PoolConfig(1),
    )
    defer pool.close()
    let observer = start_client(
      as_client_config(config, application_name="savepoint-sql-cancel-observer"),
      group,
    )
    defer observer.abort()
    pool.with_session(session => {
      session.batch_execute("create temp table moon_sql_cancel(value int4)")
      let pid : Int = session
        .query_one("select pg_backend_pid()::int4 as pid")
        .get_name("pid")
      session.with_transaction(outer => {
        outer.batch_execute("insert into moon_sql_cancel values (1)")
        for named in [false, true] {
          cancel_during_locked_sql(observer, pid, sql => {
            async fn run_nested(nested : @pgpool.Transaction) {
              nested.batch_execute("insert into moon_sql_cancel values (2)")
              @async.protect_from_cancel(() => nested.batch_execute(sql))
            }
            if named {
              outer.with_savepoint("cancelled_savepoint", run_nested)
            } else {
              outer.with_transaction(run_nested)
            }
          })
        }
        let value : Int = outer
          .query_one("select value from moon_sql_cancel")
          .get_name("value")
        assert_eq(value, 1)
      })
    })
    let value : Int = pool
      .query_one("select value from moon_sql_cancel")
      .get_name("value")
    assert_eq(value, 1)
    observer.close()
  })
}

///|
async test "integration prepare timeout behind a table lock does not leak the operation permit" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let client = start_client(
      as_client_config(config, application_name="prepare-lock-timeout"),
      group,
    )
    defer client.abort()
    let blocker = start_client(
      as_client_config(config, application_name="prepare-lock-holder"),
      group,
    )
    defer blocker.abort()
    let schema = "moon_prepare_cancel_\{client.cancel_token().process_id()}"
    blocker.batch_execute(
      "create schema \{schema}; create table \{schema}.t(value int4)",
    )
    defer @async.protect_from_cancel(() => {
      blocker.batch_execute("ROLLBACK; DROP SCHEMA \{schema} CASCADE")
    })
    blocker.batch_execute(
      "BEGIN; LOCK TABLE \{schema}.t IN ACCESS EXCLUSIVE MODE",
    )
    let timeout_fired : @async.Queue[Unit] = Queue(kind=Unbounded)
    let mut delivered = false
    let task = group.spawn(allow_failure=true, () => {
      @async.with_timeout(500, () => {
        @async.with_task_group(timeout_group => {
          let pending : @async.Queue[Unit] = Queue(kind=Unbounded)
          // This independent child observes timeout cancellation even while
          // query creation is still protected waiting for PostgreSQL's lock.
          timeout_group.spawn_bg(no_wait=true, () => {
            defer ignore(timeout_fired.try_put(()))
            pending.get()
          })
          let stream = client.query("select value from \{schema}.t")
          delivered = true
          stream.detach()
        })
      })
    })
    wait_for_backend_lock(blocker, client.cancel_token().process_id())
    @async.with_timeout(5000, () => timeout_fired.get())
    blocker.batch_execute("ROLLBACK")
    assert_true(
      expect_error_async(() => @async.with_timeout(5000, () => task.wait()))
      is @async.TimeoutError,
    )
    assert_false(delivered)
    @async.with_timeout(5000, () => {
      client.check_connection()
      client.close()
    })
  })
}
