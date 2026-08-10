///|
fn row_values(rows : Array[@client.Row]) -> Array[Int] raise {
  rows.map(row => row.get_name("value"))
}

///|
/// Scoped row streams expose the client package's stream directly and are
/// drained automatically when the callback stops early.
async test "integration pooled row stream callback restores session" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres-pool-stream"),
      make_pool_config(1),
    )

    let first : Int = pool.with_session(session => {
      session.with_stream(
        "select generate_series(1, 4)::int4 as value order by value",
        stream => {
          let _ : @client.RowStream = stream
          guard stream.next() is Some(row) else { fail("expected first row") }
          row.get_name("value")
        },
      )
    })
    assert_eq(first, 1)

    let probe : Int = pool
      .query_one("select 5::int4 as value")
      .get_name("value")
    assert_eq(probe, 5)
    pool.close()
  })
}

///|
/// Simple-query callbacks likewise use `@client.SimpleQueryStream`.
async test "integration pooled simple query callback collects frames" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres-pool-simple"),
      make_pool_config(1),
    )

    let messages = pool.with_session(session => {
      session.with_simple_query(
        "select 'left'::text as side; select 'right'::text as side",
        stream => {
          let _ : @client.SimpleQueryStream = stream
          stream.collect()
        },
      )
    })
    assert_eq(messages.length(), 6)
    guard messages[1] is Row(left) else { fail("expected first row") }
    guard messages[4] is Row(right) else { fail("expected second row") }
    @debug.assert_eq(try! left.get_name("side"), Some("left"))
    @debug.assert_eq(try! right.get_name("side"), Some("right"))

    let probe : Int = pool
      .query_one("select 6::int4 as value")
      .get_name("value")
    assert_eq(probe, 6)
    pool.close()
  })
}

///|
/// COPY handles are client-owned concrete types but remain callback-scoped.
async test "integration pooled COPY callbacks keep connection reusable" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres-pool-copy"),
      make_pool_config(1),
    )

    let values : Array[Int] = pool.with_session(session => {
      session.batch_execute("create temp table moon_pool_copy(value int4)")
      let inserted = session.with_copy_in("copy moon_pool_copy from stdin", sink => {
        let _ : @client.CopyInSink = sink
        sink.send(b"1\n2\n3\n"[:])
        sink.finish()
      })
      assert_eq(inserted, 3)

      let chunks = session.with_copy_out(
        "copy (select value from moon_pool_copy order by value) to stdout",
        stream => {
          let _ : @client.CopyOutStream = stream
          stream.collect()
        },
      )
      assert_true(chunks == [b"1\n", b"2\n", b"3\n"])
      row_values(
        session.query_all(
          "select value::int4 as value from moon_pool_copy order by value",
        ),
      )
    })
    assert_true(values == [1, 2, 3])

    let probe : Int = pool
      .query_one("select 7::int4 as value")
      .get_name("value")
    assert_eq(probe, 7)
    pool.close()
  })
}

///|
/// Prepared statements are callback-scoped and automatically managed by the
/// connection-local cache.
async test "integration pooled prepared statement scope and typed parameters" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(
        config,
        application_name="moonbit-postgres-pool-prepared",
      ),
      make_pool_config(1, statement_cache_capacity=2),
    )
    let stale : @async.Queue[@pgpool.PreparedStatement] = Queue(kind=Unbounded)

    let value : Int = pool.with_session(session => {
      session.with_prepared_typed(
        "select $1::int4 + 1 as value",
        [@client.Type::int4()],
        prepared => {
          stale.put(prepared)
          let input = 8
          prepared.query_one(params=[input as &@client.ToSql]).get_name("value")
        },
      )
    })
    assert_eq(value, 9)

    let expired = stale.get()
    expect_pool_scope_expired(expect_error_async(() => expired.query_one()))

    let probe : Int = pool
      .query_one("select 10::int4 as value")
      .get_name("value")
    assert_eq(probe, 10)
    pool.close()
  })
}

///|
/// Mutating the caller's typed-prepare array must not rewrite an existing
/// cache key or make a differently typed request reuse the old statement.
async test "integration pooled prepared cache snapshots typed parameter keys" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(
        config,
        application_name="moonbit-postgres-pool-prepared-key-snapshot",
      ),
      make_pool_config(1, statement_cache_capacity=2),
    )
    let parameter_types = [@client.Type::int4()]
    let (first_type, second_type) : (String, String) = pool.with_session(session => {
      let first : String = session.with_prepared_typed(
        "select pg_typeof($1)::text as value",
        parameter_types,
        prepared => {
          let value = 7
          prepared.query_one(params=[value as &@client.ToSql]).get_name("value")
        },
      )
      parameter_types[0] = @client.Type::text()
      let second : String = session.with_prepared_typed(
        "select pg_typeof($1)::text as value",
        parameter_types,
        prepared => {
          prepared
          .query_one(params=["seven" as &@client.ToSql])
          .get_name("value")
        },
      )
      (first, second)
    })
    assert_eq(first_type, "integer")
    assert_eq(second_type, "text")
    pool.close()
  })
}

///|
/// Row-count errors come directly from the client package rather than being
/// wrapped as pool lifecycle errors.
async test "integration pool propagates client row count errors" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(
        config,
        application_name="moonbit-postgres-pool-row-count",
      ),
      make_pool_config(1),
    )
    let message = expect_row_count_error(
      expect_error_async(() => {
        pool.query_one(
          "select generate_series(1, 2)::int4 as value order by value",
        )
      }),
    )
    assert_eq(message, "expected exactly one row, got 2")
    pool.close()
  })
}

///|
/// Operation and token handles expire together at the end of a cancellable
/// callback; a stale token cannot affect a later borrower.
async test "integration pooled cancellable handles expire by scope" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres-pool-cancel"),
      make_pool_config(1),
    )
    let operations : @async.Queue[@pgpool.Operation] = Queue(kind=Unbounded)
    let tokens : @async.Queue[@pgpool.OperationCancelToken] = Queue(
      kind=Unbounded,
    )

    let value : Int = pool.with_session(session => {
      session.run_cancellable((op, token) => {
        operations.put(op)
        tokens.put(token)
        op.query_one("select 11::int4 as value").get_name("value")
      })
    })
    assert_eq(value, 11)

    let stale_op = operations.get()
    let stale_token = tokens.get()
    expect_pool_scope_expired(
      expect_error_async(() => stale_op.query_one("select 12::int4 as value")),
    )
    stale_token.cancel()

    let probe : Int = pool
      .query_one("select 13::int4 as value")
      .get_name("value")
    assert_eq(probe, 13)
    pool.close()
  })
}

///|
/// Transaction options and savepoints remain available through the scoped
/// transaction capability.
async test "integration pooled transaction options and savepoint" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(
        config,
        application_name="moonbit-postgres-pool-savepoint",
      ),
      make_pool_config(1),
    )

    let value : Int = pool.with_transaction(
      tx => {
        tx.batch_execute(
          "create temp table moon_pool_savepoint(value int4); insert into moon_pool_savepoint values (1)",
        )
        tx.with_transaction(child => {
          ignore(child.execute("insert into moon_pool_savepoint values (2)"))
          child.rollback()
        })
        tx
        .query_one("select sum(value)::int4 as value from moon_pool_savepoint")
        .get_name("value")
      },
      options=@pgpool.TransactionOptions::new(
        isolation_level=@pgpool.IsolationLevel::serializable(),
        read_only=false,
      ),
    )
    assert_eq(value, 1)
    pool.close()
  })
}
