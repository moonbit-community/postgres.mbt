///|
test "row views cannot change decoding metadata or values" {
  let row = make_row(Type::int4(), b"42")
  let columns = row.columns().to_owned()
  let values = row.values().to_owned()
  columns.clear()
  values.clear()

  assert_eq(row.columns().length(), 1)
  assert_eq(row.values().length(), 1)
  assert_eq(row.columns()[0].name, "value")
  let value : Int = row.get(0)
  assert_eq(value, 42)
}

///|
test "kind retains read-only enum labels and composite fields" {
  let enum_labels = ["sad", "happy"]
  let enum_type : Type = {
    oid: 90001U,
    name: "mood",
    kind: Kind::Enum(enum_labels[:]),
  }
  guard enum_type.kind is Kind::Enum(labels) else {
    fail("expected enum metadata")
  }
  let label_copy = labels.to_owned()
  label_copy.clear()
  assert_eq(labels.length(), 2)
  assert_eq(labels[0], "sad")
  guard enum_type.kind is Kind::Enum(reloaded_labels) else {
    fail("expected retained enum metadata")
  }
  assert_eq(reloaded_labels[1], "happy")
  let composite_fields = [
    { name: "left", type_oid: 23U, },
    { name: "right", type_oid: 25U, },
  ]
  let composite_type : Type = {
    oid: 90002U,
    name: "pair",
    kind: Kind::Composite(composite_fields[:]),
  }
  guard composite_type.kind is Kind::Composite(fields) else {
    fail("expected composite metadata")
  }
  let field_copy = fields.to_owned()
  field_copy.clear()
  assert_eq(fields.length(), 2)
  assert_eq(fields[0].name, "left")
  guard composite_type.kind is Kind::Composite(reloaded_fields) else {
    fail("expected retained composite metadata")
  }
  assert_eq(reloaded_fields[1].type_oid, 25U)
  assert_true(Type::int4_array().kind is Kind::Array(23U))
}

///|
async test "statement parameter views preserve count checks" {
  with_cancellation_test_client((_, client, _) => {
    let statement : Statement = {
      client,
      name: b"view_statement",
      params: [Type::int4()],
      columns: [],
      closed: @ref.new(false),
    }
    let params = statement.params().to_owned()
    params.clear()
    assert_eq(statement.params().length(), 1)
    assert_true(
      expect_error_async(() => client.query_statement(statement))
      is ClientError::Encode("parameter count mismatch: expected 1, got 0"),
    )
    assert_true(client.shared.requests.try_get() is None)
  })
}

///|
fn view_test_row_description_message(name : Bytes) -> @backend.Message raise {
  let payload = Buffer()
  payload.write_int16_be(1)
  payload.write_bytes(name)
  payload.write_byte(0)
  payload.write_uint_be(0U)
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
async test "simple query descriptions and rows survive later result sets" {
  let responses : @async.Queue[@backend.Message] = Queue(kind=Unbounded)
  responses.put(view_test_row_description_message(b"first"))
  responses.put(copy_test_data_row_message(Some(b"one")))
  responses.put(copy_test_command_complete_message("SELECT 1"))
  responses.put(view_test_row_description_message(b"second"))
  responses.put(copy_test_data_row_message(Some(b"two")))
  responses.put(copy_test_command_complete_message("SELECT 1"))
  responses.put(copy_test_ready_for_query_message())
  let stream = SimpleQueryStream::new(test_control(None), responses, None)

  guard stream.next() is Some(SimpleQueryMessage::RowDescription(first)) else {
    fail("expected first description")
  }
  let first_copy = first.to_owned()
  first_copy.clear()
  guard stream.next() is Some(SimpleQueryMessage::Row(first_row)) else {
    fail("expected first row")
  }
  let first_values = first_row.values().to_owned()
  first_values.clear()
  let first_columns = first_row.columns().to_owned()
  first_columns.clear()
  assert_eq(first_row.get_name("first"), Some("one"))
  ignore(stream.next())

  guard stream.next() is Some(SimpleQueryMessage::RowDescription(second)) else {
    fail("expected second description")
  }
  assert_eq(first[0], "first")
  assert_eq(second[0], "second")
  guard stream.next() is Some(SimpleQueryMessage::Row(second_row)) else {
    fail("expected second row")
  }
  assert_eq(second_row.get_name("second"), Some("two"))
  assert_eq(first_row.get_name("first"), Some("one"))
  ignore(stream.next())
  assert_true(stream.next() is None)
}
