///|
test "command tags preserve the full UInt64 row count" {
  let counts : Array[(String, UInt64)] = [
    ("0", 0),
    ("7", 7),
    ("2147483648", 2147483648),
    ("9223372036854775808", 9223372036854775808),
    ("18446744073709551615", 18446744073709551615),
  ]
  for
    command in [
      "INSERT 0", "DELETE", "UPDATE", "MERGE", "SELECT", "MOVE", "FETCH", "COPY",
    ] {
    for (digits, expected) in counts {
      assert_eq(rows_affected("\{command} \{digits}"), expected)
    }
  }
  assert_eq(rows_affected("INSERT 123 7"), 7)
  for
    tag in [
      "", "BEGIN", "COMMIT", "ROLLBACK", "CREATE TABLE", "CREATE TABLE 42", "VACUUM 42",
    ] {
    assert_eq(rows_affected(tag), 0)
  }
}

///|
test "counted command tags reject missing invalid and overflowing counts" {
  for
    command in [
      "INSERT 0", "DELETE", "UPDATE", "MERGE", "SELECT", "MOVE", "FETCH", "COPY",
    ] {
    for
      suffix in [
        "", " ", " nope", " -1", " +1", " 1_000", " 0x10", " 1.5", " 1 extra", "  1",
        " 18446744073709551616",
      ] {
      assert_true(
        @test.expect_error(() => rows_affected("\{command}\{suffix}"))
        is ClientError::Protocol(_),
      )
    }
  }
  for tag in ["INSERT", "INSERT 7", "INSERT  7", "INSERT nope 7"] {
    assert_true(
      @test.expect_error(() => rows_affected(tag)) is ClientError::Protocol(_),
    )
  }
}

///|
async test "normal and detached row streams count across integer boundaries" {
  @async.with_task_group(group => {
    let counts : Array[UInt64] = [
      2147483647, 9223372036854775807, 18446744073709551614,
    ]
    for initial in counts {
      for discard in [false, true] {
        let gate = OperationGate::new()
        let permit = gate.acquire()
        let responses : @async.Queue[@backend.Message] = Queue(kind=Unbounded)
        responses.put(copy_test_data_row_message(Some(b"row")))
        responses.put(copy_test_command_complete_message("SELECT 1"))
        responses.put(copy_test_ready_for_query_message())
        let stream = RowStream::new(
          test_control(Some(group)),
          responses,
          Some(permit),
        )
        stream.row_count = initial
        if discard {
          stream.detach()
        } else {
          assert_true(stream.next() is Some(_))
        }
        let summary = @async.with_timeout(1000, () => stream.finish())
        assert_eq(summary.row_count, initial + 1)
        assert_eq(stream.finish(), summary)
        assert_true(responses.try_get() is None)
        assert_true(permit.released.val)
        assert_true(gate.mutex.try_acquire())
        gate.mutex.release()
      }
    }
  })
}

///|
async test "execute and execute_raw release resources after row count parse errors" {
  for raw in [false, true] {
    @async.with_task_group(group => {
      let shared = make_shared(group~)
      let client : Client = { shared, }
      let statement : Statement = {
        client,
        name: b"caller",
        params: [],
        columns: [],
        closed: @ref.new(false),
      }
      let tags = [
        "UPDATE 2147483648", "UPDATE 9223372036854775808", "UPDATE 18446744073709551615",
        "UPDATE invalid", "UPDATE 18446744073709551616", "SELECT 1",
      ]
      let requests : Array[Request] = []
      defer {
        for request in requests {
          request.responses.close(
            error=ClientError::Closed("test cleanup"),
            clear=true,
          )
        }
        shared.requests.close(error=ClientError::Closed("test cleanup"))
      }
      group.spawn_bg(no_wait=true, () => {
        for tag in tags {
          if !raw {
            let prepare = shared.requests.get()
            requests.push(prepare)
            prepare.responses.put(parse_backend_message(b"1\x00\x00\x00\x04"))
            prepare.responses.put(parse_backend_message(b"n\x00\x00\x00\x04"))
            prepare.responses.put(copy_test_ready_for_query_message())
          }
          let request = shared.requests.get()
          requests.push(request)
          request.responses.put(copy_test_command_complete_message(tag))
          request.responses.put(copy_test_ready_for_query_message())
          if !raw {
            let close = shared.requests.get()
            requests.push(close)
            assert_eq(close.bytes[0], b'C')
            close.responses.put(copy_test_close_complete_message())
            close.responses.put(copy_test_ready_for_query_message())
          }
        }
      })
      @async.with_timeout(2000, () => {
        for index, _ in tags {
          async fn execute() -> UInt64 {
            if raw {
              client.execute_raw(statement)
            } else {
              client.execute("update test set value = 1")
            }
          }
          if index == 3 || index == 4 {
            assert_true(expect_error_async(execute) is ClientError::Protocol(_))
          } else {
            let expected : UInt64 = match index {
              0 => 2147483648
              1 => 9223372036854775808
              2 => 18446744073709551615
              _ => 1
            }
            assert_eq(execute(), expected)
          }
          assert_false(shared.aborted.val)
          assert_false(statement.closed.val)
          assert_true(shared.operation_gate.mutex.try_acquire())
          shared.operation_gate.mutex.release()
        }
      })
      assert_eq(
        requests.length(),
        if raw {
          tags.length()
        } else {
          tags.length() * 3
        },
      )
      for request in requests {
        assert_true(request.responses.try_get() is None)
      }
    })
  }
}

///|
async test "COPY finish parses counts after ready and never drains twice" {
  @async.with_task_group(group => {
    let shared = copy_test_shared(@ref.new(Some(group)))
    let client : Client = { shared, }
    let tags = [
      "COPY 2147483648", "COPY 9223372036854775808", "COPY 18446744073709551615",
      "COPY invalid", "COPY 18446744073709551616",
    ]
    let requests : Array[Request] = []
    defer {
      for request in requests {
        request.responses.close(
          error=ClientError::Closed("test cleanup"),
          clear=true,
        )
      }
      shared.requests.close(error=ClientError::Closed("test cleanup"))
    }
    group.spawn_bg(no_wait=true, () => {
      for tag in tags {
        let request = shared.requests.get()
        requests.push(request)
        let input = request.copy_input.unwrap()
        request.responses.put(copy_test_copy_in_response_message([]))
        assert_true(input.get() is Finish)
        request.responses.put(copy_test_command_complete_message(tag))
        request.responses.put(copy_test_ready_for_query_message())
      }
      let probe = shared.requests.get()
      requests.push(probe)
      probe.responses.put(copy_test_command_complete_message("SELECT 1"))
      probe.responses.put(copy_test_ready_for_query_message())
    })
    @async.with_timeout(2000, () => {
      for index, _ in tags {
        let sink = client.copy_in("COPY test FROM STDIN")
        if index >= 3 {
          assert_true(
            expect_error_async(() => sink.finish()) is ClientError::Protocol(_),
          )
        } else {
          let expected : UInt64 = match index {
            0 => 2147483648
            1 => 9223372036854775808
            _ => 18446744073709551615
          }
          assert_eq(sink.finish(), expected)
        }
        assert_true(sink.finished.val)
        assert_true(sink.permit.released.val)
        assert_true(sink.abandoned_done.val is None)
        assert_true(sink.responses.try_get() is None)
        assert_true(sink.input.try_get() is None)
        assert_true(shared.operation_gate.mutex.try_acquire())
        shared.operation_gate.mutex.release()
      }
      client.batch_execute("select 1")
    })
    assert_false(shared.aborted.val)
  })
}
