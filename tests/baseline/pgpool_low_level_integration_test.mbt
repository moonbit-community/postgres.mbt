///|
/// These low-level pool tests build the pool from declarative config.
/// That covers the full path from `@pgpool.Config` to a live pool instance instead of only testing a higher-level wrapper.
fn make_decl_pool(
  config : IntegrationConfig,
  group : @async.TaskGroup[Unit],
  max_size : Int,
  application_name~ : String,
) -> @pgpool.Pool raise {
  let pool_config = @pgpool.Config::new(
    config.host,
    user=config.user,
    dbname=config.database,
    password=config.password,
    port=config.port,
    application_name~,
    pool=make_pool_config(max_size),
  )
  pool_config.create_pool(group)
}

///|
/// This verifies that `with_stream` cleans up unread rows when the callback exits.
/// The test reads only the first row, then immediately runs another query. If that query succeeds, the connection state was restored.
async test "integration pool with_stream auto finishes unfinished rows" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_decl_pool(
      config,
      group,
      1,
      application_name="moonbit-postgres-pool-low-level",
    )

    // Read only the first row and leave the rest for the callback cleanup path.
    let first : Int = pool.with_client(client => {
      client.with_stream(
        "select 1::int4 as value union all select 2::int4 as value order by value",
        stream => {
          match stream.next() {
            Some(row) => row.get_name("value")
            None => fail("expected first streamed row")
          }
        },
      )
    })
    assert_eq(first, 1)

    // If the previous stream was not cleaned up, this query would get stuck behind the protocol state.
    let second : Int = pool.with_client(client => {
      client.query_one("select 3::int4 as value").get_name("value")
    })
    assert_eq(second, 3)

    pool.close()
  })
}

///|
/// This verifies that `with_copy_in` aborts COPY automatically when the callback neither writes data nor finishes explicitly.
/// The test first checks that no rows leaked into the table, then runs a normal query to confirm the connection is reusable again.
async test "integration pool with_copy_in auto aborts unfinished copy" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_decl_pool(
      config,
      group,
      1,
      application_name="moonbit-postgres-pool-low-level",
    )

    // Leave the callback empty so the outer cleanup path has to finish the operation.
    let count : Int = pool.with_client(client => {
      client.batch_execute("create temp table pool_copy_abort(value int4)")
      client.with_copy_in("copy pool_copy_abort from stdin", _sink => ())
      client
      .query_one("select count(*)::int4 as value from pool_copy_abort")
      .get_name("value")
    })
    assert_eq(count, 0)

    let probe : Int = pool.with_client(client => {
      client.query_one("select 4::int4 as value").get_name("value")
    })
    assert_eq(probe, 4)

    pool.close()
  })
}

///|
/// This verifies that `with_typed_stream` still decodes rows with explicit type information inside a transaction.
/// The test borrows a pooled connection, enters a transaction, runs a typed stream query, and collects the full result.
async test "integration pool transaction with_typed_stream" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_decl_pool(
      config,
      group,
      1,
      application_name="moonbit-postgres-pool-low-level",
    )

    let value : Int = pool.with_client(client => {
      client.with_transaction(tx => {
        let params : Array[&@client.ToSql] = [31 as &@client.ToSql]
        tx.with_typed_stream(
          "select $1::int4 as value",
          [@client.Type::int4()],
          params~,
          stream => {
            let rows = stream.collect()
            assert_eq(rows.length(), 1)
            rows[0].get_name("value")
          },
        )
      })
    })
    assert_eq(value, 31)

    pool.close()
  })
}

///|
/// This verifies that `detach_raw` removes the underlying connection from pool slot management.
/// The test first checks that the slot becomes available again, then checks that the detached raw connection still works after the pool closes.
async test "integration pool detach_raw restores slot" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_decl_pool(
      config,
      group,
      1,
      application_name="moonbit-postgres-pool-low-level",
    )
    let lease = pool.get()
    let raw = lease.detach_raw()

    // After `detach_raw`, the pool no longer owns this connection, so size and available should both drop to 0.
    assert_eq(pool.status().size, 0)
    assert_eq(pool.status().available, 0)

    // A new checkout succeeds because the pool already released the previous slot.
    let waiter = group.spawn(no_wait=true, () => {
      pool.with_client(client => {
        let value : Int = client
          .query_one("select 9::int4 as value")
          .get_name("value")
        value
      })
    })
    assert_eq(
      wait_for_task_or_fail(waiter, "expected checkout after detach_raw"),
      9,
    )

    // The raw connection is now independent, so it should keep working after the pool closes.
    let raw_value : Int = raw
      .query_one("select 7::int4 as value")
      .get_name("value")
    assert_eq(raw_value, 7)

    pool.close()

    let after_close : Int = raw
      .query_one("select 8::int4 as value")
      .get_name("value")
    assert_eq(after_close, 8)
    raw.close()
  })
}
