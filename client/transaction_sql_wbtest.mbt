///|
/// Isolation options render only the four fixed PostgreSQL spellings.
async test "transaction isolation levels use fixed BEGIN SQL" {
  with_cancellation_test_client((group, client, next_request) => {
    let cases : Array[(IsolationLevel, String)] = [
      (IsolationLevel::read_uncommitted(), "READ UNCOMMITTED"),
      (IsolationLevel::read_committed(), "READ COMMITTED"),
      (IsolationLevel::repeatable_read(), "REPEATABLE READ"),
      (IsolationLevel::serializable(), "SERIALIZABLE"),
    ]
    for case in cases {
      let (level, sql) = case
      let begin = group.spawn(() => {
        client.transaction(options=TransactionOptions(isolation_level=level))
      })
      let request = next_request()
      assert_eq(
        request.bytes,
        simple_query_bytes("BEGIN ISOLATION LEVEL \{sql}"),
      )
      request.responses.put(copy_test_ready_for_query_message(status=b'T'))
      let transaction = begin.wait()
      let commit = group.spawn(() => transaction.commit())
      let complete = next_request()
      assert_eq(complete.bytes, simple_query_bytes("COMMIT"))
      complete.responses.put(copy_test_ready_for_query_message())
      commit.wait()
    }
  })
}

///|
/// Every completion path reuses the same quoted identifier sent at creation.
async test "named savepoints quote identifiers for commit and rollback" {
  with_cancellation_test_client((group, client, next_request) => {
    let begin = group.spawn(() => client.transaction())
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    let transaction = begin.wait()
    let cases : Array[(String, String)] = [
      ("with space", "\"with space\""),
      ("has\"quote", "\"has\"\"quote\""),
      ("semi;colon", "\"semi;colon\""),
      ("MiXeD_雪", "\"MiXeD_雪\""),
    ]
    for case in cases {
      let (name, quoted) = case
      for roll_back in [false, true] {
        let creating = group.spawn(() => transaction.savepoint(name))
        let savepoint = next_request()
        assert_eq(savepoint.bytes, simple_query_bytes("SAVEPOINT \{quoted}"))
        savepoint.responses.put(copy_test_ready_for_query_message(status=b'T'))
        let child = creating.wait()
        let finishing = group.spawn(() => {
          if roll_back {
            child.rollback()
          } else {
            child.commit()
          }
        })
        let completion = next_request()
        let sql = if roll_back {
          "ROLLBACK TO SAVEPOINT \{quoted}; RELEASE SAVEPOINT \{quoted}"
        } else {
          "RELEASE SAVEPOINT \{quoted}"
        }
        assert_eq(completion.bytes, simple_query_bytes(sql))
        completion.responses.put(copy_test_ready_for_query_message(status=b'T'))
        finishing.wait()
      }
    }
    let finish = group.spawn(() => transaction.commit())
    let commit = next_request()
    assert_eq(commit.bytes, simple_query_bytes("COMMIT"))
    commit.responses.put(copy_test_ready_for_query_message())
    finish.wait()
  })
}

///|
/// Rejected names never occupy the parent or enqueue a PostgreSQL request.
async test "invalid savepoint names leave parent transaction usable" {
  with_cancellation_test_client((group, client, next_request) => {
    let begin = group.spawn(() => client.transaction())
    next_request().responses.put(copy_test_ready_for_query_message(status=b'T'))
    let transaction = begin.wait()
    for name in ["", "bad\u0000name"] {
      let error = expect_error_async(() => transaction.savepoint(name))
      assert_true(error is ClientError::InvalidSavepointName(_))
      assert_true(client.shared.requests.try_get() is None)
    }
    let query = group.spawn(() => transaction.batch_execute("SELECT 1"))
    let request = next_request()
    assert_eq(request.bytes, simple_query_bytes("SELECT 1"))
    request.responses.put(copy_test_ready_for_query_message(status=b'T'))
    query.wait()
    let finish = group.spawn(() => transaction.commit())
    let commit = next_request()
    assert_eq(commit.bytes, simple_query_bytes("COMMIT"))
    commit.responses.put(copy_test_ready_for_query_message())
    finish.wait()
  })
}
