///|
async fn scoped_prepared_count(client : @client.Client) -> Int {
  client.with_simple_query("select count(*) from pg_prepared_statements", stream => {
    for message = stream.next() {
      match message {
        Some(Row(row)) => break @string.parse_int(row.get(0).unwrap())
        Some(_) => continue stream.next()
        None => fail("expected prepared statement count")
      }
    }
  })
}

///|
async test "integration scoped streams drain early exits and release temporary statements" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let client = start_client(
      as_client_config(
        config,
        application_name="moonbit-postgres-scoped-streams",
      ),
      group,
    )
    defer client.abort()
    @async.with_timeout(5000, () => {
      let prepared_before = scoped_prepared_count(client)
      let first : Int = client.with_stream(
        "select generate_series(1, 64) as value",
        stream => stream.next().unwrap().get_name("value"),
      )
      assert_eq(first, 1)
      let count = 64
      let first_typed : Int = client.with_typed_stream(
        "select generate_series(1, $1::int4) as value",
        [@client.Type::int4()],
        params=[count as &@client.ToSql],
        stream => stream.next().unwrap().get_name("value"),
      )
      assert_eq(first_typed, 1)
      assert_eq(scoped_prepared_count(client), prepared_before)

      assert_eq(
        client.with_copy_out("copy (select generate_series(1, 64)) to stdout", stream => {
          stream.next().unwrap()
        }),
        b"1\n",
      )
      let statement = client.prepare("select generate_series(1, 64) as value")
      defer @async.protect_from_cancel(() => statement.close())
      for _ in 0..<2 {
        let value : Int = client.with_statement_stream(statement, stream => {
          stream.next().unwrap().get_name("value")
        })
        assert_eq(value, 1)
      }
      let probe : Int = client.query_one("select 42::int4").get(0)
      assert_eq(probe, 42)
    })
    client.close()
  })
}

///|
async test "integration scoped COPY IN aborts unfinished returns errors and cancellation" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let client = start_client(
      as_client_config(config, application_name="moonbit-postgres-scoped-copy"),
      group,
    )
    defer client.abort()
    client.batch_execute("create temp table scoped_copy(value int4)")
    @async.with_timeout(5000, () => {
      assert_eq(
        client.with_copy_in("copy scoped_copy from stdin", sink => {
          sink.send(b"1\n")
          42
        }),
        42,
      )
      assert_true(
        expect_error_async(() => {
          let _ : Unit = client.with_copy_in("copy scoped_copy from stdin", sink => {
            sink.send(b"2\n")
            raise Failure::Failure("callback failed")
          })
        })
        is Failure::Failure("callback failed"),
      )

      let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
      let waiting : @async.Queue[Unit] = Queue(kind=Unbounded)
      defer waiting.close()
      let task = group.spawn(allow_failure=true, () => {
        client.with_copy_in("copy scoped_copy from stdin", sink => {
          sink.send(b"3\n")
          entered.put(())
          waiting.get()
        })
      })
      entered.get()
      task.cancel()
      assert_true(expect_error_async(() => task.wait()) is @async.TaskCancelled)

      let count : Int = client
        .query_one("select count(*)::int4 from scoped_copy")
        .get(0)
      assert_eq(count, 0)
      assert_eq(
        client.with_copy_in("copy scoped_copy from stdin", sink => {
          sink.send(b"4\n5\n")
          sink.finish()
        }),
        2,
      )
      let committed : Int = client
        .query_one("select count(*)::int4 from scoped_copy")
        .get(0)
      assert_eq(committed, 2)
    })
    client.close()
  })
}

///|
async test "integration scoped row decoding and parameter encoding errors keep connection reusable" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let client = start_client(
      as_client_config(
        config,
        application_name="moonbit-postgres-scoped-errors",
      ),
      group,
    )
    defer client.abort()
    @async.with_timeout(5000, () => {
      let prepared_before = scoped_prepared_count(client)
      assert_true(
        expect_error_async(() => {
          client.with_stream(
            "select 'text'::text from generate_series(1, 64)",
            stream => {
              let value : Int = stream.next().unwrap().get(0)
              value
            },
          )
        })
        is @client.ClientError::WrongType(_),
      )
      for typed in [false, true] {
        assert_true(
          expect_error_async(() => {
            if typed {
              client.query_typed("select $1::int4", [@client.Type::int4()], params=[
                true as &@client.ToSql,
              ])
            } else {
              client.query("select $1::int4", params=[true as &@client.ToSql])
            }
          })
          is @client.ClientError::WrongType(_),
        )
        assert_eq(scoped_prepared_count(client), prepared_before)
      }
      let probe : Int = client.query_one("select 42::int4").get(0)
      assert_eq(probe, 42)
    })
    client.close()
  })
}
