///|
async test "integration statements reject foreign connections and retain manual transaction reuse" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let first = start_client(
      as_client_config(config, application_name="statement-owner-first"),
      group,
    )
    let second = start_client(
      as_client_config(config, application_name="statement-owner-second"),
      group,
    )
    defer first.abort()
    defer second.abort()
    @async.with_timeout(5000, () => {
      let first_statement = first.prepare("select 11::int4 as value")
      let second_statement = second.prepare("select 22::int4 as value")
      let first_name : String = first
        .query_one(
          "select name from pg_prepared_statements where statement = 'select 11::int4 as value'",
        )
        .get(0)
      let second_name : String = second
        .query_one(
          "select name from pg_prepared_statements where statement = 'select 22::int4 as value'",
        )
        .get(0)
      assert_eq(first_name, second_name)
      assert_true(
        expect_error_async(() => second.query_statement(first_statement))
        is @client.ClientError::StatementConnectionMismatch,
      )
      assert_true(
        expect_error_async(() => second.execute_raw(first_statement))
        is @client.ClientError::StatementConnectionMismatch,
      )
      assert_true(
        expect_error_async(() => {
          second.with_statement_stream(first_statement, _ => ())
        })
        is @client.ClientError::StatementConnectionMismatch,
      )
      // A root transaction keeps the client permit, so foreign client calls
      // and transaction calls must reject without waiting for that permit.
      second.with_transaction(tx => {
        assert_true(
          expect_error_async(() => second.execute_raw(first_statement))
          is @client.ClientError::StatementConnectionMismatch,
        )
        assert_true(
          expect_error_async(() => tx.query_statement(first_statement))
          is @client.ClientError::StatementConnectionMismatch,
        )
        assert_true(
          expect_error_async(() => tx.execute_raw(first_statement))
          is @client.ClientError::StatementConnectionMismatch,
        )
        assert_true(
          expect_error_async(() => {
            tx.with_statement_stream(first_statement, _ => ())
          })
          is @client.ClientError::StatementConnectionMismatch,
        )
        assert_true(
          expect_error_async(() => tx.with_portal(first_statement, _ => ()))
          is @client.ClientError::StatementConnectionMismatch,
        )
        assert_true(
          expect_error_async(() => tx.close_statement(first_statement))
          is @client.ClientError::StatementConnectionMismatch,
        )
        let value : Int = tx.query_statement(second_statement).one().get(0)
        assert_eq(value, 22)
        let value : Int = tx.with_portal(second_statement, portal => {
          portal.with_stream(0, stream => stream.one().get(0))
        })
        assert_eq(value, 22)
      })
      // Manual statements keep their capabilities across transaction scopes.
      for _ in 0..<2 {
        first.with_transaction(tx => {
          let value : Int = tx.query_statement(first_statement).one().get(0)
          assert_eq(value, 11)
          assert_eq(tx.execute_raw(first_statement), 1)
        })
      }
      let copy = first
      let value : Int = copy.with_statement_stream(first_statement, stream => {
        stream.one().get(0)
      })
      assert_eq(value, 11)
      first_statement.close()
      assert_true(
        expect_error_async(() => second.execute_raw(first_statement))
        is @client.ClientError::StatementConnectionMismatch,
      )
      second.with_transaction(tx => {
        assert_true(
          expect_error_async(() => tx.close_statement(first_statement))
          is @client.ClientError::StatementConnectionMismatch,
        )
        assert_true(
          expect_error_async(() => tx.with_portal(first_statement, _ => ()))
          is @client.ClientError::StatementConnectionMismatch,
        )
        assert_eq(tx.execute_raw(second_statement), 1)
        tx.close_statement(second_statement)
        tx.close_statement(second_statement)
      })
      first.check_connection()
      second.check_connection()
      assert_false(first.is_closed())
      assert_false(second.is_closed())
    })
    first.close()
    second.close()
  })
}
