///|
async fn scoped_test_prepare(
  request : Request,
  param_types? : Array[Type] = [],
) -> Unit {
  request.responses.put(parse_backend_message(b"1\x00\x00\x00\x04"))
  let payload = Buffer()
  payload.write_int16_be(@proto.checked_i16(param_types.length()))
  for type_ in param_types {
    payload.write_uint_be(type_.oid)
  }
  request.responses.put(
    copy_test_parse_backend_message(copy_test_backend_packet(b't', payload)),
  )
  request.responses.put(copy_test_row_description_message())
  request.responses.put(copy_test_ready_for_query_message())
}

///|
async fn scoped_test_close(request : Request) -> Unit {
  assert_eq(request.bytes, close_bytes(b'S', b"q1"))
  request.responses.put(copy_test_close_complete_message())
  request.responses.put(copy_test_ready_for_query_message())
}

///|
async test "scoped inferred and typed rows drain early returns and close temporary statements" {
  for typed in [false, true] {
    with_cancellation_test_client((group, client, next_request) => {
      async fn first_row(stream : RowStream) -> String {
        return stream.next().unwrap().get(0)
      }
      let task = group.spawn(() => {
        if typed {
          client.with_typed_stream("select value", [], first_row)
        } else {
          client.with_stream("select value", first_row)
        }
      })
      scoped_test_prepare(next_request())
      let execute = next_request()
      for _ in 0..<32 {
        execute.responses.put(copy_test_data_row_message(Some(b"first")))
      }
      assert_true(task.try_wait() is None)
      assert_true(client.shared.requests.try_get() is None)
      execute.responses.put(copy_test_command_complete_message("SELECT 32"))
      execute.responses.put(copy_test_ready_for_query_message())
      let close = next_request()
      assert_false(client.shared.operation_gate.mutex.try_acquire())
      assert_true(task.try_wait() is None)
      scoped_test_close(close)
      assert_eq(task.wait(), "first")
      assert_true(execute.responses.try_get() is None)
    })
  }
}

///|
async test "scoped row decoding error survives stream and statement cleanup errors" {
  with_cancellation_test_client((group, client, next_request) => {
    let task = group.spawn(allow_failure=true, () => {
      client.with_stream("select value", stream => {
        let value : Int = stream.next().unwrap().get(0)
        value
      })
    })
    scoped_test_prepare(next_request())
    let execute = next_request()
    execute.responses.put(copy_test_data_row_message(Some(b"text")))
    execute.responses.put(copy_test_error_response_message("drain failed"))
    execute.responses.put(copy_test_ready_for_query_message())
    let close = next_request()
    assert_eq(close.bytes, close_bytes(b'S', b"q1"))
    close.responses.put(copy_test_error_response_message("close failed"))
    close.responses.put(copy_test_ready_for_query_message())
    assert_true(
      expect_error_async(() => task.wait())
      is ClientError::WrongType({ moonbit_type: "Int", .. }),
    )
    assert_true(execute.responses.try_get() is None)
    assert_true(close.responses.try_get() is None)
  })
}

///|
async test "scoped rows await detached cleanup after next fails to decode" {
  with_cancellation_test_client((group, client, next_request) => {
    let task = group.spawn(allow_failure=true, () => {
      client.with_stream("select value", stream => ignore(stream.next()))
    })
    scoped_test_prepare(next_request())
    let execute = next_request()
    execute.responses.put(
      parse_backend_message(b"D\x00\x00\x00\x0a\x00\x01\xff\xff\xff\xfe"),
    )
    for _ in 0..<32 {
      execute.responses.put(copy_test_data_row_message(Some(b"discard")))
    }
    execute.responses.put(copy_test_ready_for_query_message())
    let close = next_request()
    assert_true(task.try_wait() is None)
    scoped_test_close(close)
    assert_true(
      expect_error_async(() => task.wait())
      is @proto.ProtocolError::InvalidInput("invalid value length"),
    )
  })
}

///|
async test "scoped rows propagate cancellation at acquisition callback and cleanup boundaries" {
  for typed in [false, true] {
    // 0: startup; 1: cancellable callback wait; 2: callback with pending cancel;
    // 3: cancellation during the final protected Close exchange.
    for phase in 0..<4 {
      with_cancellation_test_client((group, client, next_request) => {
        let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
        let waiting : @async.Queue[Unit] = Queue(kind=Unbounded)
        defer waiting.close()
        let delivered = @ref.new(false)
        let exited = @ref.new(false)
        async fn callback(_ : RowStream) -> Unit {
          delivered.val = true
          entered.put(())
          if phase == 1 {
            waiting.get()
          } else if phase == 2 {
            @async.protect_from_cancel(() => waiting.get())
          }
        }
        let task = group.spawn(allow_failure=true, () => {
          defer {
            exited.val = true
          }
          if typed {
            client.with_typed_stream("select value", [], callback)
          } else {
            client.with_stream("select value", callback)
          }
        })
        let prepare = next_request()
        if phase == 0 {
          task.cancel()
        }
        scoped_test_prepare(prepare)
        let execute = next_request()
        if phase != 0 {
          entered.get()
          if phase != 3 {
            task.cancel()
          }
          if phase == 2 {
            waiting.put(())
          }
        }
        // A protected user callback would hang here on its unrelated queue.
        for _ in 0..<32 {
          execute.responses.put(copy_test_data_row_message(Some(b"discard")))
        }
        execute.responses.put(copy_test_ready_for_query_message())
        let close = next_request()
        if phase == 3 {
          task.cancel()
        }
        assert_false(exited.val)
        assert_eq(delivered.val, phase != 0)
        assert_false(client.shared.operation_gate.mutex.try_acquire())
        // A cleanup failure must also leave cancellation observable.
        close.responses.put(copy_test_error_response_message("close failed"))
        close.responses.put(copy_test_ready_for_query_message())
        assert_true(
          expect_error_async(() => task.wait()) is @async.TaskCancelled,
        )
      })
    }
  }
}

///|
async test "scoped acquisition waits for the client permit cancellably" {
  with_cancellation_test_client((group, client, next_request) => {
    let active = client.simple_query("select active")
    let request = next_request()
    let started : @async.Queue[Unit] = Queue(kind=Unbounded)
    let task : @async.Task[Unit] = group.spawn(allow_failure=true, () => {
      started.put(())
      client.with_stream("select queued", _ => fail("callback must not run"))
    })
    started.get()
    task.cancel()
    assert_true(expect_error_async(() => task.wait()) is @async.TaskCancelled)
    assert_true(client.shared.requests.try_get() is None)
    request.responses.put(copy_test_ready_for_query_message())
    active.finish()
  })
}

///|
async test "scoped statement and portal streams leave caller resources open and reusable" {
  for use_portal in [false, true] {
    with_cancellation_test_client((group, client, next_request) => {
      let statement : Statement = {
        client,
        name: b"owned_statement",
        params: [],
        columns: [],
        closed: @ref.new(false),
      }
      let portal : Portal = {
        name: b"owned_portal",
        columns: [],
        closed: @ref.new(false),
      }
      let transaction = if use_portal {
        let begin = group.spawn(() => client.transaction())
        next_request().responses.put(
          copy_test_ready_for_query_message(status=b'T'),
        )
        Some(begin.wait())
      } else {
        None
      }
      for _ in 0..<2 {
        let task = group.spawn(() => {
          match transaction {
            Some(tx) => tx.with_portal_stream(portal, 1, _ => 42)
            None => client.with_statement_stream(statement, _ => 42)
          }
        })
        let request = next_request()
        assert_eq(
          request.bytes,
          if use_portal {
            execute_portal_bytes(b"owned_portal", 1)
          } else {
            execute_statement_bytes(b"owned_statement", [], [])
          },
        )
        request.responses.put(copy_test_data_row_message(Some(b"value")))
        if use_portal {
          request.responses.put(parse_backend_message(b"s\x00\x00\x00\x04"))
        }
        request.responses.put(
          copy_test_ready_for_query_message(
            status=if use_portal { b'T' } else { b'I' },
          ),
        )
        assert_eq(task.wait(), 42)
        assert_false(statement.closed.val)
        assert_false(portal.closed.val)
        assert_true(client.shared.requests.try_get() is None)
      }
      if transaction is Some(tx) {
        let rollback = group.spawn(() => tx.rollback())
        next_request().responses.put(copy_test_ready_for_query_message())
        rollback.wait()
      }
    })
  }
}

///|
async test "scoped simple query and COPY OUT drain early returns and propagate cleanup errors" {
  for copy_out in [false, true] {
    for error in [false, true] {
      with_cancellation_test_client((group, client, next_request) => {
        let task = group.spawn(allow_failure=true, () => {
          if copy_out {
            client.with_copy_out("COPY t TO STDOUT", _ => 42)
          } else {
            client.with_simple_query("select value", _ => 42)
          }
        })
        let request = next_request()
        if copy_out {
          request.responses.put(copy_test_copy_out_response_message([0]))
        } else {
          request.responses.put(copy_test_row_description_message())
        }
        for _ in 0..<32 {
          request.responses.put(
            if copy_out {
              copy_test_copy_data_message(b"value\n")
            } else {
              copy_test_data_row_message(Some(b"value"))
            },
          )
        }
        assert_true(task.try_wait() is None)
        if error {
          request.responses.put(
            copy_test_error_response_message("finish failed"),
          )
        }
        request.responses.put(copy_test_ready_for_query_message())
        if error {
          assert_true(
            expect_error_async(() => task.wait())
            is ClientError::Database({ message: "finish failed", .. }),
          )
        } else {
          assert_eq(task.wait(), 42)
        }
        assert_true(request.responses.try_get() is None)
      })
    }
  }
}

///|
async test "scoped row cleanup errors propagate after successful callbacks" {
  with_cancellation_test_client((group, client, next_request) => {
    let task = group.spawn(allow_failure=true, () => {
      client.with_stream("select value", _ => 42)
    })
    scoped_test_prepare(next_request())
    next_request().responses.put(copy_test_ready_for_query_message())
    let close = next_request()
    close.responses.put(copy_test_error_response_message("close failed"))
    close.responses.put(copy_test_ready_for_query_message())
    assert_true(
      expect_error_async(() => task.wait())
      is ClientError::Database({ message: "close failed", .. }),
    )
  })
}

///|
async test "scoped COPY IN commits only on explicit finish and aborts other callback exits" {
  // 0: explicit finish; 1: unfinished return; 2: callback error; 3: cancellation.
  for mode in 0..<4 {
    with_cancellation_test_client((group, client, next_request) => {
      let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
      let waiting : @async.Queue[Unit] = Queue(kind=Unbounded)
      defer waiting.close()
      let task = group.spawn(allow_failure=true, () => {
        client.with_copy_in("COPY t FROM STDIN", sink => {
          sink.send(b"1\n")
          entered.put(())
          match mode {
            0 => sink.finish()
            1 => 42
            2 => raise ClientError::Decode("callback failed")
            _ => {
              waiting.get()
              42
            }
          }
        })
      })
      let request = next_request()
      request.responses.put(copy_test_copy_in_response_message([0]))
      let input = request.copy_input.unwrap()
      assert_true(input.get() is Data(b"1\n"))
      entered.get()
      if mode == 3 {
        task.cancel()
      }
      let action = input.get()
      assert_true(if mode == 0 { action is Finish } else { action is Fail(_) })
      assert_true(task.try_wait() is None)
      assert_false(client.shared.operation_gate.mutex.try_acquire())
      if mode == 0 {
        request.responses.put(copy_test_command_complete_message("COPY 1"))
      } else {
        request.responses.put(copy_test_error_response_message("COPY aborted"))
      }
      request.responses.put(copy_test_ready_for_query_message())
      match mode {
        0 => assert_eq(task.wait(), 1)
        1 => assert_eq(task.wait(), 42)
        2 =>
          assert_true(
            expect_error_async(() => task.wait())
            is ClientError::Decode("callback failed"),
          )
        _ =>
          assert_true(
            expect_error_async(() => task.wait()) is @async.TaskCancelled,
          )
      }
      assert_true(input.try_get() is None)
      assert_true(request.responses.try_get() is None)
    })
  }
}

///|
async test "scoped COPY startup cancellation cleans up before propagating" {
  for copy_in in [false, true] {
    with_cancellation_test_client((group, client, next_request) => {
      let delivered = @ref.new(false)
      let task = group.spawn(allow_failure=true, () => {
        if copy_in {
          client.with_copy_in("COPY t FROM STDIN", _ => delivered.val = true)
        } else {
          client.with_copy_out("COPY t TO STDOUT", _ => delivered.val = true)
        }
      })
      let request = next_request()
      task.cancel()
      if copy_in {
        request.responses.put(copy_test_copy_in_response_message([0]))
        assert_true(request.copy_input.unwrap().get() is Fail(_))
        request.responses.put(copy_test_error_response_message("COPY aborted"))
      } else {
        request.responses.put(copy_test_copy_out_response_message([0]))
        for _ in 0..<32 {
          request.responses.put(copy_test_copy_data_message(b"value\n"))
        }
      }
      assert_false(delivered.val)
      assert_true(task.try_wait() is None)
      assert_false(client.shared.operation_gate.mutex.try_acquire())
      request.responses.put(copy_test_ready_for_query_message())
      assert_true(expect_error_async(() => task.wait()) is @async.TaskCancelled)
    })
  }
}

///|
async test "scoped COPY IN awaits abandoned cleanup when send or finish is cancelled" {
  for during_finish in [false, true] {
    with_cancellation_test_client((group, client, next_request) => {
      let blocked : @async.Queue[Unit] = Queue(kind=Unbounded)
      let callback_exited : @async.Queue[Unit] = Queue(kind=Unbounded)
      let task = group.spawn(allow_failure=true, () => {
        client.with_copy_in("COPY t FROM STDIN", sink => {
          defer ignore(callback_exited.try_put(()))
          if during_finish {
            ignore(sink.finish())
          } else {
            for _ in 0..<8 {
              sink.send(b"1\n")
            }
            blocked.put(())
            sink.send(b"blocked\n")
          }
        })
      })
      let request = next_request()
      request.responses.put(copy_test_copy_in_response_message([0]))
      let input = request.copy_input.unwrap()
      if during_finish {
        assert_true(input.get() is Finish)
        task.cancel()
        callback_exited.get()
      } else {
        blocked.get()
        task.cancel()
        // Let cancellation remove the blocked writer before freeing capacity.
        callback_exited.get()
        for _ in 0..<8 {
          assert_true(input.get() is Data(b"1\n"))
        }
      }
      assert_true(input.get() is Fail(_))
      assert_true(task.try_wait() is None)
      assert_false(client.shared.operation_gate.mutex.try_acquire())
      request.responses.put(copy_test_error_response_message("COPY abandoned"))
      request.responses.put(copy_test_ready_for_query_message())
      assert_true(expect_error_async(() => task.wait()) is @async.TaskCancelled)
      assert_true(request.responses.try_get() is None)
    })
  }
}
