///|
fn make_decl_pool(
  config : IntegrationConfig,
  group : @async.TaskGroup[Unit],
  max_size : Int,
  application_name~ : String,
  create_ms? : Int? = None,
  recycle_ms? : Int? = None,
  recycling_method? : @pgpool.RecyclingMethod = @pgpool.RecyclingMethod::fast(),
  statement_cache_capacity? : Int = 100,
  options? : @pgpool.PoolOptions = @pgpool.PoolOptions::new(),
) -> @pgpool.Pool raise {
  let declarative = @pgpool.Config::new(
    config.host,
    user=config.user,
    dbname=config.database,
    password=config.password,
    port=config.port,
    application_name~,
    pool=make_pool_config(
      max_size,
      create_ms~,
      recycle_ms~,
      recycling_method~,
      statement_cache_capacity~,
    ),
  )
  @pgpool.Pool::new(declarative, group, options~)
}

///|
/// A create timeout aborts a client already returned by the connector, so a
/// post-create hook blocked in client I/O cannot extend the configured limit.
async test "integration pool create timeout aborts post-create client I/O" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let options = @pgpool.PoolOptions::new(post_create=client => {
      client.batch_execute("select pg_sleep(30)")
    })
    let pool = make_decl_pool(
      config,
      group,
      1,
      application_name="moonbit-postgres-pool-create-timeout",
      create_ms=Some(100),
      options~,
    )
    let started = @async.now()
    let error = @async.with_timeout(10000, () => {
      expect_error_async(() => pool.query_one("select 1::int4 as value"))
    })
    guard error is @pgpool.PoolError::Timeout(Create) else {
      fail("expected pool create timeout")
    }
    assert_true(@async.now() - started < 9000L)
    assert_eq(pool.status().size, 0)
    pool.close()
  })
}

///|
/// A recycle timeout aborts the old physical connection and lets the same
/// checkout replace it with a fresh one.
async test "integration pool recycle timeout replaces blocked connection" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let options = @pgpool.PoolOptions::new(pre_recycle=client => {
      client.batch_execute("select pg_sleep(30)")
    })
    let pool = make_decl_pool(
      config,
      group,
      1,
      application_name="moonbit-postgres-pool-recycle-timeout",
      recycle_ms=Some(100),
      options~,
    )
    let first_pid : Int = pool
      .query_one("select pg_backend_pid()::int4 as pid")
      .get_name("pid")
    let started = @async.now()
    let second_pid : Int = @async.with_timeout(10000, () => {
      pool.query_one("select pg_backend_pid()::int4 as pid").get_name("pid")
    })
    assert_true(@async.now() - started < 9000L)
    assert_true(first_pid != second_pid)
    assert_eq(pool.status().size, 1)
    pool.close()
  })
}

///|
/// Runtime hooks and a custom connector receive an already-owned task group and
/// operate on auto-driven raw clients.
async test "integration pool connector and lifecycle hooks" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let connect_calls : Array[Int] = []
    let post_create_calls : Array[Int] = []
    let pre_recycle_calls : Array[Int] = []
    let post_recycle_calls : Array[Int] = []

    let connector = @pgpool.Connector::new((target, driver_group) => {
      connect_calls.push(1)
      @client.connect(target, driver_group)
    })
    let options = @pgpool.PoolOptions::new(
      connector~,
      post_create=client => {
        post_create_calls.push(1)
        client.check_connection()
      },
      pre_recycle=client => {
        pre_recycle_calls.push(1)
        client.check_connection()
      },
      post_recycle=client => {
        post_recycle_calls.push(1)
        client.check_connection()
      },
    )
    let pool = make_decl_pool(
      config,
      group,
      1,
      application_name="moonbit-postgres-pool-hooks",
      recycling_method=@pgpool.RecyclingMethod::verified(),
      options~,
    )

    let first : Int = pool
      .query_one("select 1::int4 as value")
      .get_name("value")
    let second : Int = pool
      .query_one("select 2::int4 as value")
      .get_name("value")
    assert_eq(first, 1)
    assert_eq(second, 2)
    assert_eq(connect_calls.length(), 1)
    assert_eq(post_create_calls.length(), 1)
    assert_true(pre_recycle_calls.length() >= 1)
    assert_true(post_recycle_calls.length() >= 1)

    pool.resize(2)
    assert_eq(pool.status().max_size, 2)
    pool.resize(1)
    assert_eq(pool.status().max_size, 1)
    pool.close()
  })
}

///|
/// Clean recycling resets session state before the same backend is reused.
async test "integration pool clean recycle resets session state" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_decl_pool(
      config,
      group,
      1,
      application_name="moonbit-postgres-pool-clean",
      recycling_method=@pgpool.RecyclingMethod::clean(),
    )

    let before_pid : Int = pool.with_session(session => {
      session.batch_execute("set search_path to pg_catalog")
      session.query_one("select pg_backend_pid()::int4 as pid").get_name("pid")
    })
    let (after_pid, path) : (Int, String) = pool.with_session(session => {
      let pid : Int = session
        .query_one("select pg_backend_pid()::int4 as pid")
        .get_name("pid")
      let path : String = session
        .query_one("show search_path")
        .get_name("search_path")
      (pid, path)
    })
    assert_eq(before_pid, after_pid)
    assert_true(path != "pg_catalog")
    pool.close()
  })
}

///|
/// Returning from a COPY IN callback without finishing aborts the operation and
/// leaves the session reusable.
async test "integration pool unfinished COPY IN auto aborts" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_decl_pool(
      config,
      group,
      1,
      application_name="moonbit-postgres-pool-copy-abort",
    )

    let count : Int = pool.with_session(session => {
      session.batch_execute("create temp table moon_copy_abort(value int4)")
      session.with_copy_in("copy moon_copy_abort from stdin", _sink => ())
      session
      .query_one("select count(*)::int4 as value from moon_copy_abort")
      .get_name("value")
    })
    assert_eq(count, 0)

    let probe : Int = pool
      .query_one("select 3::int4 as value")
      .get_name("value")
    assert_eq(probe, 3)
    pool.close()
  })
}

///|
/// Callback errors still trigger stream cleanup before capacity is returned.
async test "integration pooled detached stream cleanup survives error" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_decl_pool(
      config,
      group,
      1,
      application_name="moonbit-postgres-pool-detach",
    )

    let error = expect_error_async(() => {
      pool.with_session(session => {
        session.with_stream("select generate_series(1, 16)::int4 as value", stream => {
          guard stream.next() is Some(_) else { fail("expected first row") }
          stream.detach()
          ignore(stream.next())
        })
      })
    })
    guard error is @client.ClientError::Closed(_) else {
      fail("expected detached stream to reject reads")
    }

    let probe : Int = pool
      .query_one("select 4::int4 as value")
      .get_name("value")
    assert_eq(probe, 4)
    pool.close()
  })
}
