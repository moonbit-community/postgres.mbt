///|
enum QueryFailingParam {
  EncodeFailure
}

///|
impl ToSql for QueryFailingParam with fn accepts(_, _) {
  true
}

///|
impl ToSql for QueryFailingParam with fn moonbit_type_name(_) {
  "QueryFailingParam"
}

///|
impl ToSql for QueryFailingParam with fn to_sql(_, _, _) {
  raise ClientError::Encode("custom encoder failed")
}

///|
async test "query and query_typed close temporary statements after type and encoding failures" {
  for typed in [false, true] {
    for wrong_type in [false, true] {
      for close_fails in [false, true] {
        with_cancellation_test_client((group, client, next_request) => {
          let params : Array[&ToSql] = if wrong_type {
            [true as &ToSql]
          } else {
            [QueryFailingParam::EncodeFailure as &ToSql]
          }
          let task = group.spawn(allow_failure=true, () => {
            if typed {
              client.query_typed("select $1::int4", [Type::int4()], params~)
            } else {
              client.query("select $1::int4", params~)
            }
          })
          let prepare = next_request()
          assert_eq(prepare.bytes[0], b'P')
          scoped_test_prepare(prepare, param_types=[Type::int4()])
          // The next frontend request must be Close, never Bind/Execute.
          let close = next_request()
          assert_eq(close.bytes, close_bytes(b'S', b"q1"))
          assert_true(task.try_wait() is None)
          assert_false(client.shared.operation_gate.mutex.try_acquire())
          if close_fails {
            close.responses.put(
              copy_test_error_response_message("close failed"),
            )
            close.responses.put(copy_test_ready_for_query_message())
          } else {
            scoped_test_close(close)
          }
          let error = expect_error_async(() => task.wait())
          if wrong_type {
            assert_true(
              error is ClientError::WrongType({ moonbit_type: "Bool", .. }),
            )
          } else {
            assert_true(error is ClientError::Encode("custom encoder failed"))
          }
          assert_true(client.shared.requests.try_get() is None)
        })
      }
    }
  }
}

///|
async test "inferred parameter count mismatch closes its temporary statement" {
  with_cancellation_test_client((group, client, next_request) => {
    let task = group.spawn(allow_failure=true, () => {
      client.query("select $1::int4")
    })
    scoped_test_prepare(next_request(), param_types=[Type::int4()])
    scoped_test_close(next_request())
    assert_true(
      expect_error_async(() => task.wait())
      is ClientError::Encode("parameter count mismatch: expected 1, got 0"),
    )
    assert_true(client.shared.requests.try_get() is None)
  })
}

///|
async test "typed parameter count mismatch does not create a statement" {
  with_cancellation_test_client((_, client, _) => {
    assert_true(
      expect_error_async(() => {
        client.query_typed("select $1::int4", [Type::int4()])
      })
      is ClientError::Encode("parameter count mismatch: expected 1, got 0"),
    )
    assert_true(client.shared.requests.try_get() is None)
  })
}
