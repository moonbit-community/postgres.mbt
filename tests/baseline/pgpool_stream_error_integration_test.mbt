///|
/// Avoid a constant expression: failure must happen during execution, after
/// the stream has been delivered and at least one row has been produced.
let stream_failure_sql = "select 10 / (3 - value) as value from generate_series(1, 4) as value"

///|
async fn consume_failing_stream(
  mode : Int32,
  next : async () -> Bool,
  finish : async () -> Unit,
) -> Unit {
  match mode {
    0 =>
      while next() {
        ()
      }
    1 => finish()
    _ => assert_true(next())
  }
}

///|
async fn consume_failing_rows(stream : @pgpool.RowStream, mode : Int32) -> Unit {
  consume_failing_stream(mode, () => stream.next() is Some(_), () => {
    ignore(stream.finish())
  })
}

///|
async fn consume_failing_simple(
  stream : @pgpool.SimpleQueryStream,
  mode : Int32,
) -> Unit {
  consume_failing_stream(mode, () => stream.next() is Some(_), () => {
    stream.finish()
  })
}

///|
async fn consume_failing_copy(
  stream : @pgpool.CopyOutStream,
  mode : Int32,
) -> Unit {
  consume_failing_stream(mode, () => stream.next() is Some(_), () => {
    stream.finish()
  })
}

///|
async fn session_stream_failure(
  session : @pgpool.Session,
  kind : Int32,
  mode : Int32,
) -> Unit {
  match kind {
    0 =>
      session.with_stream(stream_failure_sql, stream => {
        consume_failing_rows(stream, mode)
      })
    1 =>
      session.with_typed_stream(stream_failure_sql, [], stream => {
        consume_failing_rows(stream, mode)
      })
    2 =>
      session.with_prepared(stream_failure_sql, prepared => {
        prepared.with_stream(stream => consume_failing_rows(stream, mode))
      })
    3 =>
      session.with_simple_query(stream_failure_sql, stream => {
        consume_failing_simple(stream, mode)
      })
    _ =>
      session.with_copy_out("copy (\{stream_failure_sql}) to stdout", stream => {
        consume_failing_copy(stream, mode)
      })
  }
}

///|
async fn transaction_stream_failure(
  tx : @pgpool.Transaction,
  kind : Int32,
  mode : Int32,
) -> Unit {
  match kind {
    0 =>
      tx.with_stream(stream_failure_sql, stream => {
        consume_failing_rows(stream, mode)
      })
    1 =>
      tx.with_typed_stream(stream_failure_sql, [], stream => {
        consume_failing_rows(stream, mode)
      })
    2 =>
      tx.with_prepared(stream_failure_sql, prepared => {
        prepared.with_stream(stream => consume_failing_rows(stream, mode))
      })
    3 =>
      tx.with_simple_query(stream_failure_sql, stream => {
        consume_failing_simple(stream, mode)
      })
    _ =>
      tx.with_copy_out("copy (\{stream_failure_sql}) to stdout", stream => {
        consume_failing_copy(stream, mode)
      })
  }
}

///|
async test "integration pooled SQL stream errors retain the same session backend and normal reset" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="stream-error-recovery"),
      make_pool_config(1),
    )
    defer pool.close()
    let pid : Int32 = pool.with_session(session => {
      let pid : Int32 = session.query_one("select pg_backend_pid()").get(0)
      session.batch_execute("set application_name = 'stream-error-borrower'")
      for kind in 0..<5 {
        for mode in 0..<3 {
          let error = expect_error_async(() => {
            session_stream_failure(session, kind, mode)
          })
          assert_eq(expect_database_error(error).code, Some("22012"))
          let row = session.query_one("select pg_backend_pid(), 42::int4")
          assert_eq(row.get(0), pid)
          assert_eq(row.get(1), 42)
        }
      }
      pid
    })
    assert_eq(pool.status().size, 1)
    assert_eq(pool.status().available, 1)
    let row = pool.query_one(
      "select pg_backend_pid(), current_setting('application_name')",
    )
    assert_eq(row.get(0), pid)
    assert_eq(row.get(1), "stream-error-recovery")
  })
}

///|
async test "integration pooled SQL stream errors roll back savepoints and commit the outer transaction" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="stream-error-savepoint"),
      make_pool_config(1),
    )
    defer pool.close()
    let record = @pgpool.TransactionRecord()
    let result : Result[Unit, Unit] = pool.with_transaction(
      tx => {
        let pid : Int32 = tx.query_one("select pg_backend_pid()").get(0)
        tx.batch_execute("create temp table stream_recovery(value int)")
        for kind in 0..<5 {
          for mode in 0..<3 {
            let child_record = @pgpool.TransactionRecord()
            let error = expect_error_async(() => {
              let _ : Result[Unit, Unit] = tx.with_savepoint(
                "recover",
                child => {
                  transaction_stream_failure(child, kind, mode)
                  Ok(())
                },
                record=child_record,
              )
            })
            assert_eq(expect_database_error(error).code, Some("22012"))
            assert_eq(
              child_record.status(),
              @pgpool.TransactionStatus::RolledBack,
            )
            assert_eq(tx.query_one("select pg_backend_pid()").get(0), pid)
            tx.batch_execute("insert into stream_recovery values (1)")
          }
        }
        assert_eq(
          tx.query_one("select count(*)::int4 from stream_recovery").get(0),
          15,
        )
        Ok(())
      },
      record~,
    )
    assert_eq(result, Ok(()))
    assert_eq(record.status(), @pgpool.TransactionStatus::Committed)
    assert_eq(pool.status().available, 1)
  })
}

///|
/// Observe the cache without creating a new prepared statement for this query.
async fn cached_stream_statement_name(
  session : @pgpool.Session,
  sql : String,
) -> String {
  let escaped = sql.replace_all(old="'", new="''")
  let messages = session.with_simple_query(
    "select name from pg_prepared_statements where statement = '\{escaped}'",
    stream => stream.collect(),
  )
  guard messages[1] is Row(row) else { fail("expected cached statement") }
  row.get(0).unwrap()
}

///|
async test "integration prepared streams invalidate missing statements and changed result plans without retry" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="stream-cache-invalidation"),
      make_pool_config(1),
    )
    defer pool.close()
    for code in ["26000", "0A000"] {
      // Read the error, leave it for scope cleanup, or mask it with a callback
      // exception. Invalidation must happen in cleanup in all three cases.
      for mode in 0..<3 {
        pool.with_session(session => {
          session.batch_execute(
            "create temp table stream_cache(value int); insert into stream_cache values (7)",
          )
          let sql = "select * from stream_cache"
          let old_name = session.with_prepared(sql, _ => {
            cached_stream_statement_name(session, sql)
          })
          if code == "26000" {
            session.batch_execute("deallocate all")
          } else {
            session.batch_execute(
              "alter table stream_cache add column extra text",
            )
          }
          let error = expect_error_async(() => {
            session.with_prepared(sql, prepared => {
              prepared.with_stream(stream => {
                if mode == 0 {
                  ignore(stream.collect())
                } else if mode == 2 {
                  fail("callback failed")
                }
              })
            })
          })
          if mode == 2 {
            assert_false(error is @client.ClientError::Database(_))
          } else {
            assert_eq(expect_database_error(error).code, Some(code))
          }
          session.with_prepared(sql, prepared => {
            assert_true(cached_stream_statement_name(session, sql) != old_name)
            let rows = prepared.with_stream(stream => stream.collect())
            assert_eq(rows.length(), 1)
            assert_eq(rows[0].get(0), 7)
            assert_eq(rows[0].len(), if code == "26000" { 1 } else { 2 })
          })
        })
      }
    }
  })
}

///|
/// Force a captured SQL error before Bind/Execute, while acquiring the stream.
struct StreamCreationErrorParam {
  error : Error
}

///|
impl @client.ToSql for StreamCreationErrorParam with fn accepts(_, type_) {
  type_ == @client.Type::int4()
}

///|
impl @client.ToSql for StreamCreationErrorParam with fn moonbit_type_name(_) {
  "StreamCreationErrorParam"
}

///|
impl @client.ToSql for StreamCreationErrorParam with fn to_sql(self, _, _) {
  raise self.error
}

///|
async test "integration prepared streams invalidate cache on creation errors" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="stream-creation-invalidation"),
      make_pool_config(1),
    )
    defer pool.close()
    for code in ["26000", "0A000"] {
      pool.with_session(session => {
        let error = expect_error_async(() => {
          session.batch_execute(
            "do $$ begin raise exception using errcode = '\{code}', message = 'injected'; end $$",
          )
        })
        assert_eq(expect_database_error(error).code, Some(code))
        let param : StreamCreationErrorParam = { error, }
        let sql = "select $1::int4"
        let old_name = session.with_prepared(sql, _ => {
          cached_stream_statement_name(session, sql)
        })
        let delivered = Ref(false)
        let error = expect_error_async(() => {
          session.with_prepared(sql, prepared => {
            prepared.with_stream(params=[param as &@client.ToSql], _ => {
              delivered.val = true
            })
          })
        })
        assert_eq(expect_database_error(error).code, Some(code))
        assert_false(delivered.val)
        session.with_prepared(sql, prepared => {
          assert_true(cached_stream_statement_name(session, sql) != old_name)
          let value = 9
          let row = prepared.with_stream(params=[value as &@client.ToSql], stream => {
            stream.one()
          })
          assert_eq(row.get(0), 9)
        })
      })
    }
  })
}
