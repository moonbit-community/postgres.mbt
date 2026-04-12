///|
fn copy_test_backend_packet(
  tag : Byte,
  payload : @buffer.Buffer,
) -> Bytes raise @proto.ProtocolError {
  let packet = @buffer.new()
  packet.write_byte(tag)
  packet.write_int_be(@proto.i32_from_usize(payload.length() + 4))
  packet.write_bytes(payload.to_bytes())
  packet.to_bytes()
}

///|
fn copy_test_parse_backend_message(packet : Bytes) -> @backend.Message raise {
  match @backend.Message::parse(packet[:]) {
    Some({ message, .. }) => message
    None => fail("expected complete backend message")
  }
}

///|
fn copy_test_ready_for_query_message(
  status? : Byte = b'I',
) -> @backend.Message raise {
  let payload = @buffer.new()
  payload.write_byte(status)
  copy_test_parse_backend_message(
    copy_test_backend_packet(@backend.READY_FOR_QUERY_TAG, payload),
  )
}

///|
fn copy_test_copy_response_message(
  tag : Byte,
  formats : Array[Int],
) -> @backend.Message raise {
  let payload = @buffer.new()
  payload.write_byte(0)
  payload.write_int16_be(@proto.checked_i16(formats.length()))
  for format in formats {
    payload.write_int16_be(@proto.checked_i16(format))
  }
  copy_test_parse_backend_message(copy_test_backend_packet(tag, payload))
}

///|
fn copy_test_copy_in_response_message(
  formats : Array[Int],
) -> @backend.Message raise {
  copy_test_copy_response_message(@backend.COPY_IN_RESPONSE_TAG, formats)
}

///|
fn copy_test_copy_out_response_message(
  formats : Array[Int],
) -> @backend.Message raise {
  copy_test_copy_response_message(@backend.COPY_OUT_RESPONSE_TAG, formats)
}

///|
fn copy_test_copy_data_message(data : Bytes) -> @backend.Message raise {
  let payload = @buffer.new()
  payload.write_bytes(data)
  copy_test_parse_backend_message(
    copy_test_backend_packet(@backend.COPY_DATA_TAG, payload),
  )
}

///|
fn copy_test_copy_done_message() -> @backend.Message raise {
  copy_test_parse_backend_message(
    copy_test_backend_packet(@backend.COPY_DONE_TAG, @buffer.new()),
  )
}

///|
fn copy_test_command_complete_message(tag : String) -> @backend.Message raise {
  let payload = @buffer.new()
  payload.write_bytes(@proto.utf8_encode(tag))
  payload.write_byte(0)
  copy_test_parse_backend_message(
    copy_test_backend_packet(@backend.COMMAND_COMPLETE_TAG, payload),
  )
}

///|
fn copy_test_close_complete_message() -> @backend.Message raise {
  copy_test_parse_backend_message(
    copy_test_backend_packet(@backend.CLOSE_COMPLETE_TAG, @buffer.new()),
  )
}

///|
fn copy_test_error_response_message(message : String) -> @backend.Message raise {
  let payload = @buffer.new()
  payload.write_byte(b'M')
  payload.write_bytes(@proto.utf8_encode(message))
  payload.write_byte(0)
  payload.write_byte(0)
  copy_test_parse_backend_message(
    copy_test_backend_packet(@backend.ERROR_RESPONSE_TAG, payload),
  )
}

///|
fn copy_test_database_error(message : String) -> DatabaseError raise {
  guard copy_test_error_response_message(message)
    is @backend.Message::ErrorResponse(body) else {
    fail("expected backend error response")
  }
  parse_database_error(body.fields())
}

///|
fn copy_test_row_description_message() -> @backend.Message raise {
  let payload = @buffer.new()
  payload.write_int16_be(1)
  payload.write_bytes(b"value")
  payload.write_byte(0)
  payload.write_uint_be(Type::text().oid)
  payload.write_int16_be(0)
  payload.write_uint_be(Type::text().oid)
  payload.write_int16_be(-1)
  payload.write_int_be(-1)
  payload.write_int16_be(0)
  copy_test_parse_backend_message(
    copy_test_backend_packet(@backend.ROW_DESCRIPTION_TAG, payload),
  )
}

///|
fn copy_test_data_row_message(value : Bytes?) -> @backend.Message raise {
  let payload = @buffer.new()
  payload.write_int16_be(1)
  match value {
    None => payload.write_int_be(-1)
    Some(value) => {
      payload.write_int_be(@proto.i32_from_usize(value.length()))
      payload.write_bytes(value)
    }
  }
  copy_test_parse_backend_message(
    copy_test_backend_packet(@backend.DATA_ROW_TAG, payload),
  )
}

///|
fn copy_test_shared(
  background_group : @ref.Ref[@async.TaskGroup[Unit]?],
) -> Shared {
  let types : Map[@proto.Oid, Type] = {}
  seed_builtin_types(types)
  {
    config: Config::new(
      "127.0.0.1",
      user="moon",
      database="moondb",
      password="moonpass",
      port=55432,
      ssl_mode=Disable,
      application_name="moonbit-postgres-copy-wbtest",
    ),
    requests: @async.Queue::new(kind=Unbounded),
    async_messages: @async.Queue::new(kind=Unbounded),
    background_group,
    parameters: {},
    types,
    process_id: @ref.new(11),
    secret_key: @ref.new(22),
    transaction_status: @ref.new(b'I'),
    closed: @ref.new(false),
    closing: @ref.new(false),
    next_id: @ref.new(0),
  }
}

///|
async test "client copy in streams input and returns affected rows" {
  @async.with_task_group(group => {
    let shared = copy_test_shared(@ref.new(None))
    let client : Client = { shared, }

    group.spawn_bg(() => {
      let request = shared.requests.get()
      guard request.kind is RequestKind::CopyIn else {
        fail("expected COPY IN request")
      }
      guard request.copy_input is Some(input) else {
        fail("expected copy input queue")
      }
      request.responses.put(copy_test_copy_in_response_message([0, 1]))

      match input.get() {
        CopyInAction::Data(data) => assert_eq(data, b"alpha")
        _ => fail("expected copy data")
      }
      match input.get() {
        CopyInAction::Finish => ()
        _ => fail("expected copy finish")
      }

      request.responses.put(copy_test_copy_done_message())
      request.responses.put(copy_test_command_complete_message("COPY 1"))
      request.responses.put(copy_test_ready_for_query_message())
    })

    let sink = client.copy_in("COPY test FROM STDIN")
    sink.send(b"alpha"[:])
    assert_eq(sink.finish(), 1)

    let send_after_finish : Result[Unit, Error] = try? sink.send(b"beta"[:])
    guard send_after_finish is Err(ClientError::Closed(message)) else {
      fail("expected closed sink error")
    }
    assert_eq(message, "copy sink already finished")
  })
}

///|
async test "client copy in surfaces startup errors and missing startup response" {
  @async.with_task_group(group => {
    let error_shared = copy_test_shared(@ref.new(None))
    let error_client : Client = { shared: error_shared }

    group.spawn_bg(() => {
      let request = error_shared.requests.get()
      request.responses.put(copy_test_error_response_message("copy denied"))
      request.responses.put(copy_test_ready_for_query_message())
    })

    let startup_error : Result[CopyInSink, Error] = try? error_client.copy_in(
      "COPY denied FROM STDIN",
    )
    guard startup_error is Err(ClientError::Database(err)) else {
      fail("expected startup database error")
    }
    assert_eq(err.message, "copy denied")
  })

  @async.with_task_group(group => {
    let missing_shared = copy_test_shared(@ref.new(None))
    let missing_client : Client = { shared: missing_shared }

    group.spawn_bg(() => {
      let request = missing_shared.requests.get()
      request.responses.put(copy_test_ready_for_query_message())
    })

    let missing_response : Result[CopyInSink, Error] = try? missing_client.copy_in(
      "COPY missing FROM STDIN",
    )
    guard missing_response is Err(ClientError::UnexpectedMessage(message)) else {
      fail("expected missing CopyInResponse error")
    }
    assert_eq(message, "expected CopyInResponse")
  })
}

///|
async test "copy in abort is best effort and idempotent" {
  @async.with_task_group(group => {
    let shared = copy_test_shared(@ref.new(None))
    let client : Client = { shared, }

    group.spawn_bg(() => {
      let request = shared.requests.get()
      guard request.copy_input is Some(input) else {
        fail("expected copy input queue")
      }
      request.responses.put(copy_test_copy_in_response_message([]))

      match input.get() {
        CopyInAction::Fail(message) => assert_eq(message, "stop now")
        _ => fail("expected copy fail")
      }

      request.responses.put(copy_test_error_response_message("copy aborted"))
      request.responses.put(copy_test_ready_for_query_message())
    })

    let sink = client.copy_in("COPY abort FROM STDIN")
    sink.abort(message="stop now")
    sink.abort(message="ignored")

    let finish_after_abort : Result[Int, Error] = try? sink.finish()
    guard finish_after_abort is Err(ClientError::Closed(message)) else {
      fail("expected closed sink after abort")
    }
    assert_eq(message, "copy sink already finished")
  })
}

///|
async test "client copy out collects chunks and remembers wire formats" {
  @async.with_task_group(group => {
    let shared = copy_test_shared(@ref.new(None))
    let client : Client = { shared, }

    group.spawn_bg(() => {
      let request = shared.requests.get()
      guard request.kind is RequestKind::Messages else {
        fail("expected messages request")
      }
      request.responses.put(copy_test_copy_out_response_message([0, 1]))
      request.responses.put(copy_test_copy_data_message(b"row1\n"))
      request.responses.put(copy_test_copy_data_message(b"row2\n"))
      request.responses.put(copy_test_copy_done_message())
      request.responses.put(copy_test_command_complete_message("COPY 2"))
      request.responses.put(copy_test_ready_for_query_message())
    })

    let stream = client.copy_out("COPY test TO STDOUT")
    assert_true(stream.formats == [Text, Binary])
    assert_true(stream.collect() == [b"row1\n", b"row2\n"])
    assert_true(stream.next() is None)
  })
}

///|
async test "client copy out detach drains in background and terminal errors surface" {
  @async.with_task_group(group => {
    let shared = copy_test_shared(@ref.new(Some(group)))
    let client : Client = { shared, }

    group.spawn_bg(() => {
      let request = shared.requests.get()
      request.responses.put(copy_test_copy_out_response_message([]))
      request.responses.put(copy_test_copy_data_message(b"discard"))
      request.responses.put(copy_test_copy_done_message())
      request.responses.put(copy_test_command_complete_message("COPY 1"))
      request.responses.put(copy_test_ready_for_query_message())
    })

    let detached = client.copy_out("COPY detached TO STDOUT")
    detached.detach()

    let detached_result : Result[Bytes?, Error] = try? detached.next()
    guard detached_result is Err(ClientError::Closed(message)) else {
      fail("expected detached stream error")
    }
    assert_eq(message, "copy out stream already detached")
  })

  @async.with_task_group(group => {
    let shared = copy_test_shared(@ref.new(None))
    let client : Client = { shared, }

    group.spawn_bg(() => {
      let request = shared.requests.get()
      request.responses.put(copy_test_copy_out_response_message([]))
      request.responses.put(copy_test_error_response_message("copy failed"))
      request.responses.put(copy_test_ready_for_query_message())
    })

    let stream = client.copy_out("COPY broken TO STDOUT")
    let failed : Result[Bytes?, Error] = try? stream.next()
    guard failed is Err(ClientError::Database(err)) else {
      fail("expected terminal copy out database error")
    }
    assert_eq(err.message, "copy failed")
  })
}

///|
async test "client copy helpers reject unexpected messages and finish empty streams" {
  @async.with_task_group(group => {
    let shared = copy_test_shared(@ref.new(None))
    let client : Client = { shared, }

    group.spawn_bg(() => {
      let request = shared.requests.get()
      guard request.kind is RequestKind::CopyIn else {
        fail("expected COPY IN request")
      }
      request.responses.put(copy_test_row_description_message())
    })

    let startup_result : Result[CopyInSink, Error] = try? client.copy_in(
      "COPY invalid FROM STDIN",
    )
    guard startup_result is Err(ClientError::UnexpectedMessage(message)) else {
      fail("expected unexpected COPY IN startup response")
    }
    assert_eq(message, "unexpected copy-in response")
  })

  let finish_responses : @async.Queue[@backend.Message] = @async.Queue::new(
    kind=Unbounded,
  )
  finish_responses.put(copy_test_copy_done_message())
  finish_responses.put(copy_test_command_complete_message("COPY 0"))
  finish_responses.put(copy_test_ready_for_query_message())
  let finished_stream : CopyOutStream = {
    background_group: @ref.new(None),
    responses: finish_responses,
    formats: [],
    database_error: None,
    detached: false,
    finished: false,
  }
  finished_stream.finish()
  assert_true(finished_stream.finished)
  finished_stream.detach()
}

///|
async test "client copy out drain_discard covers finished error and unexpected paths" {
  let completed_stream : CopyOutStream = {
    background_group: @ref.new(None),
    responses: @async.Queue::new(kind=Unbounded),
    formats: [],
    database_error: None,
    detached: false,
    finished: true,
  }
  completed_stream.drain_discard()

  let finished_error_stream : CopyOutStream = {
    background_group: @ref.new(None),
    responses: @async.Queue::new(kind=Unbounded),
    formats: [],
    database_error: Some(copy_test_database_error("copy already failed")),
    detached: false,
    finished: true,
  }
  let finished_error : Result[Unit, Error] = try? finished_error_stream.drain_discard()
  guard finished_error is Err(ClientError::Database(err)) else {
    fail("expected finished drain to surface stored database error")
  }
  assert_eq(err.message, "copy already failed")

  let draining_responses : @async.Queue[@backend.Message] = @async.Queue::new(
    kind=Unbounded,
  )
  draining_responses.put(copy_test_error_response_message("copy drain failed"))
  draining_responses.put(copy_test_ready_for_query_message())
  let draining_stream : CopyOutStream = {
    background_group: @ref.new(None),
    responses: draining_responses,
    formats: [],
    database_error: None,
    detached: false,
    finished: false,
  }
  let draining_error : Result[Unit, Error] = try? draining_stream.drain_discard()
  guard draining_error is Err(ClientError::Database(err)) else {
    fail("expected detached drain database error")
  }
  assert_eq(err.message, "copy drain failed")
  assert_true(draining_stream.finished)

  let next_responses : @async.Queue[@backend.Message] = @async.Queue::new(
    kind=Unbounded,
  )
  next_responses.put(copy_test_row_description_message())
  let next_stream : CopyOutStream = {
    background_group: @ref.new(None),
    responses: next_responses,
    formats: [],
    database_error: None,
    detached: false,
    finished: false,
  }
  let next_error : Result[Bytes?, Error] = try? next_stream.next()
  guard next_error is Err(ClientError::UnexpectedMessage(message)) else {
    fail("expected unexpected copy-out response")
  }
  assert_eq(message, "unexpected copy out response")

  let discard_responses : @async.Queue[@backend.Message] = @async.Queue::new(
    kind=Unbounded,
  )
  discard_responses.put(copy_test_row_description_message())
  let discard_stream : CopyOutStream = {
    background_group: @ref.new(None),
    responses: discard_responses,
    formats: [],
    database_error: None,
    detached: false,
    finished: false,
  }
  let discard_error : Result[Unit, Error] = try? discard_stream.drain_discard()
  guard discard_error is Err(ClientError::UnexpectedMessage(message)) else {
    fail("expected unexpected detached copy-out response")
  }
  assert_eq(message, "unexpected copy out response")
}

///|
async test "response helpers drain simple query and close sequences" {
  let simple_responses : @async.Queue[@backend.Message] = @async.Queue::new(
    kind=Unbounded,
  )
  simple_responses.put(copy_test_row_description_message())
  simple_responses.put(copy_test_data_row_message(Some(b"ok")))
  simple_responses.put(copy_test_command_complete_message("SELECT 1"))
  simple_responses.put(copy_test_ready_for_query_message())
  drain_simple_query(simple_responses)

  let close_responses : @async.Queue[@backend.Message] = @async.Queue::new(
    kind=Unbounded,
  )
  close_responses.put(copy_test_close_complete_message())
  close_responses.put(copy_test_ready_for_query_message())
  drain_close_response(close_responses)

  assert_eq(rows_affected("INSERT 0 7"), 7)
  assert_eq(rows_affected("BEGIN"), 0)
  assert_eq(join_clauses(["READ ONLY", "DEFERRABLE"]), "READ ONLY DEFERRABLE")
}
