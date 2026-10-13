///|
/// Observe an actual PostgreSQL lock wait instead of guessing when SQL starts.
async fn wait_for_backend_lock(observer : @client.Client, pid : Int32) -> Unit {
  @async.with_timeout(5000, () => {
    while true {
      // A transaction keeps its first activity snapshot until it is cleared.
      // The observer may also be the connection holding the blocking lock.
      observer.batch_execute("select pg_stat_clear_snapshot()")
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
  pid : Int32,
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
      is @async.WaitedTaskAlreadyCancelled,
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
      let count : Int32 = client
        .query_one("select count(*)::int4 as n from moon_sql_cancel")
        .get_name("n")
      assert_eq(count, 0)
    }
    client.with_transaction(tx => {
      tx.batch_execute("insert into moon_sql_cancel values (2)")
    })
    let value : Int32 = client
      .query_one("select value from moon_sql_cancel")
      .get_name("value")
    assert_eq(value, 2)
    client.close()
    observer.close()
  })
}

///|
/// Cancellation must finish while the observer still holds the lock.
async fn cancel_pooled_locked(
  observer : @client.Client,
  pid : Int32,
  f : async (String) -> Unit,
) -> Unit {
  observer.batch_execute("select pg_advisory_lock(91827, \{pid})")
  defer @async.protect_from_cancel(() => {
    observer.batch_execute("select pg_advisory_unlock(91827, \{pid})")
  })
  @async.with_task_group(group => {
    let task = group.spawn(allow_failure=true, () => {
      f("select pg_advisory_xact_lock(91827, \{pid})")
    })
    wait_for_backend_lock(observer, pid)
    task.cancel()
    assert_true(
      expect_error_async(() => @async.with_timeout(3000, () => task.wait()))
      is @async.WaitedTaskAlreadyCancelled,
    )
  })
}

///|
async test "integration pooled SQL and savepoint cancellation roll back without unlocking the blocker" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="pool-lock-cancel"),
      PoolConfig(1),
    )
    defer pool.close()
    let observer = start_client(
      as_client_config(config, application_name="pool-lock-observer"),
      group,
    )
    defer observer.abort()
    pool.with_session(session => {
      session.batch_execute("create temp table moon_sql_cancel(value int4)")
      let pid : Int32 = session
        .query_one("select pg_backend_pid()::int4 as pid")
        .get_name("pid")
      for batch in [false, true] {
        cancel_pooled_locked(observer, pid, sql => {
          ignore(
            session.with_transaction(tx => {
              tx.batch_execute("insert into moon_sql_cancel values (1)")
              if batch {
                tx.batch_execute(sql)
              } else {
                ignore(tx.execute(sql))
              }
              (Ok(()) : Result[Unit, Unit])
            }),
          )
        })
        assert_eq(
          session
          .query_one("select count(*)::int4 as n from moon_sql_cancel")
          .get_name("n"),
          0,
        )
      }
      let result : Result[Unit, Unit] = session.with_transaction(outer => {
        outer.batch_execute("insert into moon_sql_cancel values (1)")
        cancel_pooled_locked(observer, pid, sql => {
          ignore(
            outer.with_savepoint("cancelled_child", child => {
              child.batch_execute("insert into moon_sql_cancel values (2)")
              child.batch_execute(sql)
              (Ok(()) : Result[Unit, Unit])
            }),
          )
        })
        assert_eq(
          outer.query_one("select value from moon_sql_cancel").get_name("value"),
          1,
        )
        Ok(())
      })
      assert_eq(result, Ok(()))
    })
    assert_eq(pool.status().available, 1)
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
    // Cache the target's idle state before starting its query. The lock waiter
    // must refresh this transaction's snapshot to observe the later lock wait.
    let initial_state : String = blocker
      .query_one("select state from pg_stat_activity where pid = $1::int4", params=[
        client.cancel_token().process_id() as &@client.ToSql,
      ])
      .get_name("state")
    assert_eq(initial_state, "idle")
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
