///|
fn[T] expect_pool_row_count(result : Result[T, Error]) -> String raise {
  guard result is Err(@pgpool.PoolError::RowCount(message)) else {
    fail("expected pool row count error")
  }
  message
}

///|
fn row_values(rows : Array[@client.Row]) -> Array[Int] raise {
  let values : Array[Int] = []
  for row in rows {
    values.push(row.get_name("value"))
  }
  values
}

///|
/// This verifies that scoped COPY IN can finish normally, reject reuse of the finished sink, and leave the pooled connection reusable.
/// The row count is checked both through `finish()` and by querying the temp table before the lease returns to the pool.
async test "integration pool with_copy_in explicit finish keeps connection reusable" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_decl_pool(
      config,
      group,
      1,
      application_name="moonbit-postgres-pool-low-level",
    )

    let inserted : Int = pool.with_client(client => {
      client.batch_execute("create temp table pool_copy_finish(value int4)")
      let inserted = client.with_copy_in("copy pool_copy_finish from stdin", sink => {
        sink.send(b"1\n2\n"[:])
        let inserted = sink.finish()
        let send_closed = expect_closed_error(try? sink.send(b"3\n"[:]))
        assert_eq(send_closed, "copy sink already finished")
        let finish_closed = expect_closed_error(try? sink.finish())
        assert_eq(finish_closed, "copy sink already finished")
        inserted
      })
      let count : Int = client
        .query_one("select count(*)::int4 as value from pool_copy_finish")
        .get_name("value")
      assert_eq(count, 2)
      inserted
    })
    assert_eq(inserted, 2)

    let probe : Int = pool.with_client(client => {
      client.query_one("select 5::int4 as value").get_name("value")
    })
    assert_eq(probe, 5)

    pool.close()
  })
}

///|
/// This verifies the pooled client convenience wrappers around query, execute, typed prepare, statement close, and portal helpers.
/// The test also covers row-count errors on scoped prepared statements and checks that stale portal handles fail after callback cleanup.
async test "integration pool client wrappers cover prepared statements and portals" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )

    pool.with_client(client => {
      client.batch_execute("create temp table moon_pool_client_api(value int4)")
      assert_eq(
        client.execute(
          "insert into moon_pool_client_api (value) values (1), (2), (3)",
        ),
        3,
      )
      assert_eq(
        row_values(
          client.query_all(
            "select value from moon_pool_client_api order by value",
          ),
        ),
        [1, 2, 3],
      )
      guard client.query_opt(
          "select value from moon_pool_client_api where value = 99",
        )
        is None else {
        fail("expected no pooled client row")
      }
      assert_eq(
        row_values(
          client.query_typed_all(
            "select $1::int4 as value",
            [@client.Type::int4()],
            params=[17 as &@client.ToSql],
          ),
        ),
        [17],
      )
      client.check_connection()

      let typed_value : Int = client.with_prepared_typed(
        "select $1::int4 as value",
        [@client.Type::int4()],
        prepared => {
          prepared.query_one(params=[19 as &@client.ToSql]).get_name("value")
        },
      )
      assert_eq(typed_value, 19)

      let prepared_rows = client.with_prepared(
        "select value from moon_pool_client_api order by value",
        prepared => {
          assert_eq(
            expect_pool_row_count(try? prepared.query_one()),
            "expected exactly one row, got 3",
          )
          assert_eq(
            expect_pool_row_count(try? prepared.query_opt()),
            "expected zero or one row, got 3",
          )
          prepared.query_all()
        },
      )
      assert_eq(row_values(prepared_rows), [1, 2, 3])

      let inserted = client.with_prepared(
        "insert into moon_pool_client_api (value) values (4)",
        prepared => prepared.execute(),
      )
      assert_eq(inserted, 1)

      client.with_prepared("select 41::int4 as value", prepared => {
        assert_eq(prepared.query_one().get_name("value"), 41)
        prepared.close()
        prepared.close()
        expect_pool_lease_released(try? prepared.query_one())
      })
    })

    let probe : Int = pool.with_client(client => {
      client.query_one("select 24::int4 as value").get_name("value")
    })
    assert_eq(probe, 24)

    pool.close()
  })
}

///|
/// This verifies portal helpers inside a pooled transaction, where PostgreSQL guarantees portal lifetime across multiple fetches.
/// The test covers direct `bind`, callback-scoped `with_portal`, idempotent close, and stale-handle rejection after callback cleanup.
async test "integration pool transaction portals support pagination and cleanup" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )
    let stale_portals : @async.Queue[@pgpool.Portal] = @async.Queue::new(
      kind=Unbounded,
    )

    pool.with_client(client => {
      let tx = client.transaction()
      tx.batch_execute("create temp table moon_pool_portal(value int4)")
      ignore(
        tx.execute("insert into moon_pool_portal (value) values (1), (2), (3)"),
      )

      tx.with_prepared("select value from moon_pool_portal order by value", prepared => {
        let portal = prepared.bind()
        let first = row_values(
          portal.with_stream(2, stream => stream.collect()),
        )
        let second = row_values(
          portal.with_stream(2, stream => stream.collect()),
        )
        assert_eq(first, [1, 2])
        assert_eq(second, [3])
        portal.close()
        portal.close()
        expect_pool_lease_released(
          try? portal.with_stream(1, stream => stream.collect()),
        )

        prepared.with_portal(portal => {
          stale_portals.put(portal)
          assert_eq(
            row_values(portal.with_stream(2, stream => stream.collect())),
            [1, 2],
          )
        })
      })

      tx.rollback()
    })

    let stale_portal = stale_portals.get()
    expect_pool_lease_released(
      try? stale_portal.with_stream(1, stream => stream.collect()),
    )

    pool.close()
  })
}

///|
/// This verifies the cancellable-operation wrappers around query, execute, and prepared statements.
/// The point is not cancellation here; it is that `Operation` exposes the same high-level helpers while keeping the scope serial.
async test "integration pool operation wrappers cover prepared helpers" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )

    let values = pool.with_client(client => {
      client.run_cancellable((op, _) => {
        op.batch_execute("create temp table moon_pool_operation(value int4)")
        assert_eq(
          op.execute("insert into moon_pool_operation (value) values (1), (2)"),
          2,
        )
        assert_eq(
          row_values(
            op.query_all("select value from moon_pool_operation order by value"),
          ),
          [1, 2],
        )
        guard op.query_opt(
            "select value from moon_pool_operation where value = 99",
          )
          is None else {
          fail("expected no operation row")
        }
        assert_eq(
          row_values(
            op.query_typed_all(
              "select $1::int4 as value",
              [@client.Type::int4()],
              params=[13 as &@client.ToSql],
            ),
          ),
          [13],
        )
        op.check_connection()

        (
          op.with_prepared("select 21::int4 as value", prepared => {
            prepared.query_one().get_name("value")
          }),
          op.with_prepared_typed(
            "select $1::int4 as value",
            [@client.Type::int4()],
            prepared => {
              prepared
              .query_one(params=[34 as &@client.ToSql])
              .get_name("value")
            },
          ),
          op.with_prepared_cached("select 55::int4 as value", prepared => {
            prepared.query_one().get_name("value")
          }),
          op.with_prepared_typed_cached(
            "select $1::int4 as value",
            [@client.Type::int4()],
            prepared => {
              prepared
              .query_one(params=[89 as &@client.ToSql])
              .get_name("value")
            },
          ),
        )
      })
    })

    assert_eq(values, (21, 34, 55, 89))

    pool.close()
  })
}

///|
/// This verifies that releasing a lease during an active stream delays pool return until cleanup finishes.
/// It also checks that `detach_raw()` is rejected while work is active and again after release begins.
async test "integration pool release waits for active stream cleanup and rejects detach_raw" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )
    let lease = pool.get()
    let entered : @async.Queue[Unit] = @async.Queue::new(kind=Unbounded)
    let finish_stream : @async.Queue[Unit] = @async.Queue::new(kind=Unbounded)

    let task = group.spawn(no_wait=true, () => {
      lease.with_stream(
        "select generate_series(1, 8)::int4 as value order by value",
        stream => {
          guard stream.next() is Some(row) else {
            fail("expected first streamed row")
          }
          assert_eq(row.get_name("value"), 1)
          entered.put(())
          finish_stream.get()
          stream.collect().length()
        },
      )
    })

    entered.get()
    expect_pool_operation_in_progress(try? lease.detach_raw())

    lease.release()
    lease.release()
    expect_pool_lease_released(try? lease.query_one("select 1::int4 as value"))
    expect_pool_lease_released(try? lease.detach_raw())

    finish_stream.put(())
    assert_eq(
      wait_for_task_or_fail(task, "expected released stream task to finish"),
      7,
    )

    let probe : Int = pool.with_client(client => {
      client.query_one("select 51::int4 as value").get_name("value")
    })
    assert_eq(probe, 51)

    pool.close()
  })
}

///|
/// This verifies that cancellable handles become stale once their callback returns.
/// The old `Operation` must reject new requests and the stale cancel token must not poison later work.
async test "integration pool stale cancellable handles reject new work" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )
    let stale_operations : @async.Queue[@pgpool.Operation] = @async.Queue::new(
      kind=Unbounded,
    )
    let stale_tokens : @async.Queue[@pgpool.OperationCancelToken] = @async.Queue::new(
      kind=Unbounded,
    )

    let value : Int = pool.with_client(client => {
      client.run_cancellable((op, token) => {
        stale_operations.put(op)
        stale_tokens.put(token)
        op.query_one("select 61::int4 as value").get_name("value")
      })
    })
    assert_eq(value, 61)

    let stale_op = stale_operations.get()
    let stale_token = stale_tokens.get()
    expect_pool_lease_released(
      try? stale_op.query_one("select 62::int4 as value"),
    )
    stale_token.cancel()
    stale_token.cancel()

    let probe : Int = pool.with_client(client => {
      client.query_one("select 63::int4 as value").get_name("value")
    })
    assert_eq(probe, 63)

    pool.close()
  })
}

///|
/// This verifies the pooled transaction wrappers around row-count checks, typed queries, prepared statements, and statement-cache guards.
/// It also checks that once a transaction is committed, its statement-cache handle becomes invalid.
async test "integration pool transaction wrappers cover row counts and cache guards" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres"),
      make_pool_config(1),
    )
    let stale_caches : @async.Queue[@pgpool.StatementCache] = @async.Queue::new(
      kind=Unbounded,
    )

    pool.with_client(client => {
      let tx = client.transaction()
      tx.batch_execute("create temp table moon_pool_transaction(value int4)")
      assert_eq(
        tx.execute(
          "insert into moon_pool_transaction (value) values (1), (2), (3)",
        ),
        3,
      )
      assert_eq(
        row_values(
          tx.query_all("select value from moon_pool_transaction order by value"),
        ),
        [1, 2, 3],
      )
      assert_eq(
        expect_pool_row_count(
          try? tx.query_one("select value from moon_pool_transaction"),
        ),
        "expected exactly one row, got 3",
      )
      assert_eq(
        expect_pool_row_count(
          try? tx.query_opt("select value from moon_pool_transaction"),
        ),
        "expected zero or one row, got 3",
      )
      guard tx.query_opt(
          "select value from moon_pool_transaction where value = 99",
        )
        is None else {
        fail("expected no transaction row")
      }
      assert_eq(
        row_values(
          tx.query_typed_all(
            "select $1::int4 as value",
            [@client.Type::int4()],
            params=[88 as &@client.ToSql],
          ),
        ),
        [88],
      )
      tx.check_connection()

      assert_eq(
        tx.with_prepared("select 41::int4 as value", prepared => {
          prepared.query_one().get_name("value")
        }),
        41,
      )
      assert_eq(
        tx.with_prepared_typed(
          "select $1::int4 as value",
          [@client.Type::int4()],
          prepared => {
            prepared.query_one(params=[42 as &@client.ToSql]).get_name("value")
          },
        ),
        42,
      )
      assert_eq(
        tx.with_prepared_cached("select 43::int4 as value", prepared => {
          prepared.query_one().get_name("value")
        }),
        43,
      )
      assert_eq(
        tx.with_prepared_typed_cached(
          "select $1::int4 as value",
          [@client.Type::int4()],
          prepared => {
            prepared.query_one(params=[44 as &@client.ToSql]).get_name("value")
          },
        ),
        44,
      )

      let cache = tx.statement_cache()
      stale_caches.put(cache)
      assert_true(cache.size() >= 1)
      tx.commit()
      guard (try? tx.statement_cache()) is Err(@pgpool.PoolError::LeaseReleased) else {
        fail("expected finished transaction cache guard")
      }
    })

    let stale_cache = stale_caches.get()
    pool.close()
    guard (try? stale_cache.size()) is Err(@pgpool.PoolError::LeaseReleased) else {
      fail("expected stale cache size guard")
    }
  })
}

///|
/// This verifies direct pooled transaction builders together with named and unnamed savepoints.
/// The test keeps one pooled lease checked out explicitly, exercises rollback and auto-commit on nested transaction helpers, and then confirms the released lease rejects new work while the pool stays reusable.
async test "integration pool direct transaction builder and savepoints keep lease reusable" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_decl_pool(
      config,
      group,
      1,
      application_name="moonbit-postgres-pool-low-level",
    )

    let client = pool.get()
    let total : Int = client
      .build_transaction()
      .isolation_level(@pgpool.IsolationLevel::serializable())
      .read_only(enabled=false)
      .deferrable(enabled=false)
      .run(tx => {
        tx.batch_execute("create temp table moon_pool_nested_tx(value int4)")
        assert_eq(
          tx.execute("insert into moon_pool_nested_tx(value) values (1)"),
          1,
        )

        let named_count : Int = tx.with_savepoint("named_inner", nested => {
          assert_eq(
            nested.execute("insert into moon_pool_nested_tx(value) values (2)"),
            1,
          )
          nested
          .query_one("select count(*)::int4 as value from moon_pool_nested_tx")
          .get_name("value")
        })
        assert_eq(named_count, 2)

        let manual = tx.savepoint("manual_inner")
        assert_eq(
          manual.execute("insert into moon_pool_nested_tx(value) values (3)"),
          1,
        )
        manual.rollback()

        let callback_count : Int = tx.with_transaction(nested => {
          assert_eq(
            nested.execute("insert into moon_pool_nested_tx(value) values (4)"),
            1,
          )
          nested
          .query_one("select count(*)::int4 as value from moon_pool_nested_tx")
          .get_name("value")
        })
        assert_eq(callback_count, 3)

        let explicit = tx.transaction()
        assert_eq(
          explicit.execute("insert into moon_pool_nested_tx(value) values (5)"),
          1,
        )
        assert_eq(
          row_values(
            explicit.query_all(
              "select value from moon_pool_nested_tx order by value",
            ),
          ),
          [1, 2, 4, 5],
        )
        explicit.commit()

        let isolation : String = tx
          .query_one(
            "select current_setting('transaction_isolation')::text as value",
          )
          .get_name("value")
        let read_only : String = tx
          .query_one(
            "select current_setting('transaction_read_only')::text as value",
          )
          .get_name("value")
        let deferrable : String = tx
          .query_one(
            "select current_setting('transaction_deferrable')::text as value",
          )
          .get_name("value")
        assert_eq(isolation, "serializable")
        assert_eq(read_only, "off")
        assert_eq(deferrable, "off")
        tx
        .query_one("select sum(value)::int4 as value from moon_pool_nested_tx")
        .get_name("value")
      })
    assert_eq(total, 12)

    client.release()
    guard (try? client.query_one("select 1::int4 as value"))
      is Err(@pgpool.PoolError::LeaseReleased) else {
      fail("expected released pooled client to reject new work")
    }

    let probe : Int = pool.with_client(client => {
      client.query_one("select 52::int4 as value").get_name("value")
    })
    assert_eq(probe, 52)

    pool.close()
  })
}

///|
/// This verifies that scoped COPY OUT can collect all remaining chunks and return the connection to ordinary pooled use.
async test "integration pool with_copy_out collect keeps connection reusable" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_decl_pool(
      config,
      group,
      1,
      application_name="moonbit-postgres-pool-low-level",
    )

    let chunks = pool.with_client(client => {
      client.with_copy_out(
        "copy (select value from (values ('alpha'), ('beta')) as t(value) order by value) to stdout",
        stream => stream.collect(),
      )
    })
    assert_true(chunks == [b"alpha\n", b"beta\n"])

    let probe : Int = pool.with_client(client => {
      client.query_one("select 6::int4 as value").get_name("value")
    })
    assert_eq(probe, 6)

    pool.close()
  })
}

///|
/// This verifies that detaching a pooled row stream and then touching it again still leaves the connection reusable.
/// The callback error forces the helper through its best-effort closeout path while the detached drain finishes in background.
async test "integration pool with_stream detach cleanup survives callback error" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_decl_pool(
      config,
      group,
      1,
      application_name="moonbit-postgres-pool-low-level",
    )

    let detached_err : Result[Unit, Error] = try? pool.with_client(client => {
      client.with_stream(
        "select generate_series(1, 16)::int4 as value order by value",
        stream => {
          guard stream.next() is Some(row) else {
            fail("expected first streamed row")
          }
          assert_eq(row.get_name("value"), 1)
          stream.detach()
          stream.detach()
          ignore(stream.next())
        },
      )
    })
    expect_pool_lease_released(detached_err)

    let probe : Int = pool.with_client(client => {
      client.query_one("select 71::int4 as value").get_name("value")
    })
    assert_eq(probe, 71)

    pool.close()
  })
}

///|
/// This verifies the same detach-and-error cleanup path for transaction-scoped typed row streams.
/// The surrounding transaction should stay usable after the detached cleanup finishes.
async test "integration pool transaction typed stream detach cleanup survives callback error" {
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
        let detached_err : Result[Unit, Error] = try? tx.with_typed_stream(
          "select $1::int4 as value union all select 99::int4 as value order by value",
          [@client.Type::int4()],
          params=[77 as &@client.ToSql],
          stream => {
            guard stream.next() is Some(row) else {
              fail("expected first typed streamed row")
            }
            assert_eq(row.get_name("value"), 77)
            stream.detach()
            stream.detach()
            ignore(stream.next())
          },
        )
        expect_pool_lease_released(detached_err)
        tx.query_one("select 78::int4 as value").get_name("value")
      })
    })
    assert_eq(value, 78)

    pool.close()
  })
}

///|
/// This verifies that scoped simple-query collection drains the full response stream before the pooled client is reused.
/// The test checks both result-set ordering and a follow-up query on the same pool.
async test "integration pool with_simple_query collect keeps connection reusable" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_decl_pool(
      config,
      group,
      1,
      application_name="moonbit-postgres-pool-low-level",
    )

    let messages = pool.with_client(client => {
      client.with_simple_query(
        "select 'left'::text as side; select 'right'::text as side",
        stream => stream.collect(),
      )
    })

    guard messages[0]
      is @client.SimpleQueryMessage::RowDescription(left_columns) else {
      fail("expected first row description")
    }
    guard messages[1] is @client.SimpleQueryMessage::Row(left_row) else {
      fail("expected first row")
    }
    guard messages[2] is @client.SimpleQueryMessage::CommandComplete(left_tag) else {
      fail("expected first command tag")
    }
    guard messages[3]
      is @client.SimpleQueryMessage::RowDescription(right_columns) else {
      fail("expected second row description")
    }
    guard messages[4] is @client.SimpleQueryMessage::Row(right_row) else {
      fail("expected second row")
    }
    guard messages[5] is @client.SimpleQueryMessage::CommandComplete(right_tag) else {
      fail("expected second command tag")
    }
    assert_eq(left_columns, ["side"])
    @debug.assert_eq(try! left_row.get_name("side"), Some("left"))
    assert_eq(left_tag, "SELECT 1")
    assert_eq(right_columns, ["side"])
    @debug.assert_eq(try! right_row.get_name("side"), Some("right"))
    assert_eq(right_tag, "SELECT 1")

    let probe : Int = pool.with_client(client => {
      client.query_one("select 8::int4 as value").get_name("value")
    })
    assert_eq(probe, 8)

    pool.close()
  })
}

///|
/// This verifies that detaching a pooled simple-query stream and then reading it again still converges back to a reusable connection.
/// The callback error exercises the helper's closeout path after background draining has already started.
async test "integration pool with_simple_query detach cleanup survives callback error" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_decl_pool(
      config,
      group,
      1,
      application_name="moonbit-postgres-pool-low-level",
    )

    let detached_err : Result[Unit, Error] = try? pool.with_client(client => {
      client.with_simple_query(
        "select generate_series(1, 16)::int4 as value order by value",
        stream => {
          guard stream.next()
            is Some(@client.SimpleQueryMessage::RowDescription(columns)) else {
            fail("expected row description")
          }
          assert_eq(columns, ["value"])
          guard stream.next() is Some(@client.SimpleQueryMessage::Row(row)) else {
            fail("expected first row")
          }
          @debug.assert_eq(try! row.get_name("value"), Some("1"))
          stream.detach()
          stream.detach()
          ignore(stream.next())
        },
      )
    })
    expect_pool_lease_released(detached_err)

    let probe : Int = pool.with_client(client => {
      client.query_one("select 81::int4 as value").get_name("value")
    })
    assert_eq(probe, 81)

    pool.close()
  })
}

///|
/// This verifies that detaching a pooled COPY OUT stream and then touching it again still lets the pool recover cleanly.
/// The callback error should not leak the underlying connection or keep COPY state alive for later work.
async test "integration pool with_copy_out detach cleanup survives callback error" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_decl_pool(
      config,
      group,
      1,
      application_name="moonbit-postgres-pool-low-level",
    )

    let detached_err : Result[Unit, Error] = try? pool.with_client(client => {
      client.with_copy_out(
        "copy (select value from (values ('alpha'), ('beta')) as t(value) order by value) to stdout",
        stream => {
          guard stream.next() is Some(chunk) else {
            fail("expected first copy chunk")
          }
          assert_true(chunk == b"alpha\n")
          stream.detach()
          stream.detach()
          ignore(stream.next())
        },
      )
    })
    expect_pool_lease_released(detached_err)

    let probe : Int = pool.with_client(client => {
      client.query_one("select 91::int4 as value").get_name("value")
    })
    assert_eq(probe, 91)

    pool.close()
  })
}

///|
/// This verifies the direct checked-out lease success path across ordinary operations, one cancellable scope, and one default transaction scope.
/// The same lease first creates session-local state, then reuses it after both exclusive scopes finish, and finally returns to the pool cleanly.
async test "integration pool direct lease operation and default transaction scopes stay reusable" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_decl_pool(
      config,
      group,
      1,
      application_name="moonbit-postgres-pool-low-level",
    )
    let lease = pool.get()

    let initial_count : Int = lease.run_cancellable((op, _) => {
      op.batch_execute("create temp table moon_pool_direct_scope(value int4)")
      assert_eq(
        op.execute("insert into moon_pool_direct_scope(value) values (1), (2)"),
        2,
      )
      op.check_connection()
      op
      .query_one("select count(*)::int4 as value from moon_pool_direct_scope")
      .get_name("value")
    })
    assert_eq(initial_count, 2)

    let tx = lease.build_transaction().start()
    assert_eq(
      tx.execute("insert into moon_pool_direct_scope(value) values (3)"),
      1,
    )
    let named = tx.savepoint("lease_named_commit")
    assert_eq(
      named.execute("insert into moon_pool_direct_scope(value) values (4)"),
      1,
    )
    named.commit()
    assert_eq(
      row_values(
        tx.query_all("select value from moon_pool_direct_scope order by value"),
      ),
      [1, 2, 3, 4],
    )
    tx.commit()

    lease.check_connection()
    assert_eq(
      row_values(
        lease.query_all(
          "select value from moon_pool_direct_scope order by value",
        ),
      ),
      [1, 2, 3, 4],
    )

    lease.release()
    expect_pool_lease_released(try? lease.query_one("select 1::int4 as value"))

    let probe : Int = pool.with_client(client => {
      client.query_one("select 67::int4 as value").get_name("value")
    })
    assert_eq(probe, 67)

    pool.close()
  })
}
