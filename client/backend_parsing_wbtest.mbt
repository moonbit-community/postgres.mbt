///|
struct TestColumnSpec {
  name : Bytes
  table_oid : @proto.Oid
  column_id : Int
  type_oid : @proto.Oid
  type_size : Int
  type_modifier : Int
  format : Int
}

///|
fn bytes_of(bytes : ArrayView[Byte]) -> Bytes {
  Bytes::from_array(bytes)
}

///|
fn parsing_backend_packet(tag : Byte, payload : @buffer.Buffer) -> Bytes raise {
  let packet = @buffer.new()
  packet.write_byte(tag)
  packet.write_int_be(@proto.i32_from_usize(payload.length() + 4))
  packet.write_bytes(payload.to_bytes())
  packet.to_bytes()
}

///|
fn parse_backend_message(packet : Bytes) -> @backend.Message raise {
  match @backend.Message::parse(packet[:]) {
    Some({ message, .. }) => message
    None => fail("expected complete backend message")
  }
}

///|
fn make_row_description_body(
  columns : Array[TestColumnSpec],
) -> @backend.RowDescriptionBody raise {
  let payload = @buffer.new()
  payload.write_int16_be(@proto.checked_i16(columns.length()))
  for column in columns {
    payload.write_bytes(column.name)
    payload.write_byte(0)
    payload.write_uint_be(column.table_oid)
    payload.write_int16_be(@proto.checked_i16(column.column_id))
    payload.write_uint_be(column.type_oid)
    payload.write_int16_be(@proto.checked_i16(column.type_size))
    payload.write_int_be(@proto.checked_i32(column.type_modifier))
    payload.write_int16_be(@proto.checked_i16(column.format))
  }
  match
    parse_backend_message(
      parsing_backend_packet(@backend.ROW_DESCRIPTION_TAG, payload),
    ) {
    @backend.Message::RowDescription(body) => body
    _ => fail("expected RowDescription message")
  }
}

///|
fn make_data_row_body(values : Array[Bytes?]) -> @backend.DataRowBody raise {
  let payload = @buffer.new()
  payload.write_int16_be(@proto.checked_i16(values.length()))
  for value in values {
    match value {
      None => payload.write_int_be(-1)
      Some(value) => {
        payload.write_int_be(@proto.i32_from_usize(value.length()))
        payload.write_bytes(value)
      }
    }
  }
  match
    parse_backend_message(
      parsing_backend_packet(@backend.DATA_ROW_TAG, payload),
    ) {
    @backend.Message::DataRow(body) => body
    _ => fail("expected DataRow message")
  }
}

///|
fn make_copy_formats(formats : Array[Int]) -> @backend.ColumnFormats raise {
  let payload = @buffer.new()
  payload.write_byte(0)
  payload.write_int16_be(@proto.checked_i16(formats.length()))
  for format in formats {
    payload.write_int16_be(@proto.checked_i16(format))
  }
  match
    parse_backend_message(
      parsing_backend_packet(@backend.COPY_IN_RESPONSE_TAG, payload),
    ) {
    @backend.Message::CopyInResponse(body) => body.column_formats()
    _ => fail("expected CopyInResponse message")
  }
}

///|
fn make_error_fields(
  fields : Array[(Byte, Bytes)],
) -> @backend.ErrorFields raise {
  let payload = @buffer.new()
  for field in fields {
    let (type_, value) = field
    payload.write_byte(type_)
    payload.write_bytes(value)
    payload.write_byte(0)
  }
  payload.write_byte(0)
  match
    parse_backend_message(
      parsing_backend_packet(@backend.ERROR_RESPONSE_TAG, payload),
    ) {
    @backend.Message::ErrorResponse(body) => body.fields()
    _ => fail("expected ErrorResponse message")
  }
}

///|
test "backend parsing extracts columns and names from row descriptions" {
  let body = make_row_description_body([
    {
      name: b"answer",
      table_oid: 7U,
      column_id: 1,
      type_oid: 23U,
      type_size: 4,
      type_modifier: -1,
      format: 0,
    },
    {
      name: b"mystery",
      table_oid: 0U,
      column_id: 0,
      type_oid: 99999U,
      type_size: -1,
      type_modifier: -1,
      format: 1,
    },
  ])

  let columns = parse_columns(body)
  assert_eq(columns.length(), 2)
  assert_eq(columns[0].name, "answer")
  assert_eq(columns[0].table_oid, 7U)
  assert_eq(columns[0].column_id, 1)
  assert_true(columns[0].type_ == Type::int4())
  assert_true(columns[0].format == WireFormat::Text)
  assert_true(columns[1].type_ == Type::unknown(99999U, name="oid_99999"))
  assert_true(columns[1].format == WireFormat::Binary)
  assert_eq(parse_column_names(body), ["answer", "mystery"])
}

///|
test "backend parsing decodes data rows, copy formats, and invalid utf8" {
  let binary = parse_binary_values(
    make_data_row_body([Some(bytes_of([1, 2])), None, Some(b"moon")]),
  )
  assert_eq(binary, [Some(bytes_of([1, 2])), None, Some(b"moon")])

  let text = parse_text_row(
    make_data_row_body([
      Some(@proto.utf8_encode("moon")),
      None,
      Some(@proto.utf8_encode("世界")),
    ]),
    ["name", "middle", "tail"],
  )
  assert_true(text.columns == ["name", "middle", "tail"])
  assert_true(text.values == [Some("moon"), None, Some("世界")])

  let invalid_utf8 : Result[SimpleQueryRow, Error] = try? parse_text_row(
    make_data_row_body([Some(bytes_of([b'\xC2']))]),
    ["bad"],
  )
  guard invalid_utf8 is Err(@proto.ProtocolError::InvalidInput(message)) else {
    fail("expected invalid UTF-8 error")
  }
  assert_eq(message, "invalid UTF-8")

  assert_true(parse_copy_formats(make_copy_formats([0, 1])) == [Text, Binary])
  let invalid_format : Result[Array[WireFormat], Error] = try? parse_copy_formats(
    make_copy_formats([2]),
  )
  guard invalid_format is Err(ClientError::Protocol(message)) else {
    fail("expected unsupported wire format error")
  }
  assert_eq(message, "unsupported wire format code: 2")
}

///|
test "backend parsing collects database errors and defaults missing message" {
  let err = parse_database_error(
    make_error_fields([
      (b'S', b"ERROR"),
      (b'C', b"23505"),
      (b'M', b"duplicate key"),
      (b'D', b"detail text"),
      (b'H', b"hint text"),
      (b'X', b"ignored"),
    ]),
  )
  assert_eq(err.severity, Some("ERROR"))
  assert_eq(err.code, Some("23505"))
  assert_eq(err.message, "duplicate key")
  assert_eq(err.detail, Some("detail text"))
  assert_eq(err.hint, Some("hint text"))

  let default_message = parse_database_error(
    make_error_fields([(b'S', b"ERROR")]),
  )
  assert_eq(default_message.message, "database error")
  assert_eq(default_message.severity, Some("ERROR"))

  let invalid_utf8 : Result[DatabaseError, Error] = try? parse_database_error(
    make_error_fields([(b'M', bytes_of([b'\xC2']))]),
  )
  guard invalid_utf8 is Err(@proto.ProtocolError::InvalidInput(message)) else {
    fail("expected invalid UTF-8 error")
  }
  assert_eq(message, "invalid UTF-8")
}

///|
test "backend parsing merges stream columns and reports mismatches" {
  let body = make_row_description_body([
    {
      name: b"value",
      table_oid: 11U,
      column_id: 2,
      type_oid: 23U,
      type_size: 4,
      type_modifier: -1,
      format: 0,
    },
  ])
  let described = parse_columns(body)
  assert_true(merge_stream_columns([], body) == described)

  let resolved : Array[Column] = [
    {
      name: "value",
      table_oid: 0U,
      column_id: 0,
      type_: Type::unknown(23U, name="resolved_int4"),
      type_size: -1,
      type_modifier: -1,
      format: WireFormat::Binary,
    },
  ]
  let merged = merge_stream_columns(resolved, body)
  assert_eq(merged[0].name, "value")
  assert_eq(merged[0].table_oid, 11U)
  assert_true(merged[0].type_ == Type::unknown(23U, name="resolved_int4"))
  assert_true(merged[0].format == WireFormat::Text)

  let mismatch_count : Result[Array[Column], Error] = try? merge_stream_columns(
    [resolved[0], resolved[0]],
    body,
  )
  guard mismatch_count is Err(ClientError::Protocol(message)) else {
    fail("expected column count mismatch")
  }
  assert_eq(message, "row description column count mismatch: expected 2, got 1")

  let mismatch_oid : Result[Array[Column], Error] = try? merge_stream_columns(
    [{ ..resolved[0], type_: Type::unknown(25U, name="text") }],
    body,
  )
  guard mismatch_oid is Err(ClientError::Protocol(message)) else {
    fail("expected column oid mismatch")
  }
  assert_eq(
    message, "row description type mismatch at column 0: expected oid 25, got 23",
  )
}

///|
async test "backend parsing fail_response_stream closes queue with error" {
  let responses : @async.Queue[Int] = @async.Queue::new(kind=Unbounded)
  let result : Result[Unit, Error] = try? fail_response_stream(
    responses,
    ClientError::UnexpectedMessage("boom"),
  )
  guard result is Err(ClientError::UnexpectedMessage(message)) else {
    fail("expected fail_response_stream to re-raise the error")
  }
  assert_eq(message, "boom")

  let drained : Result[Int, Error] = try? responses.get()
  guard drained is Err(ClientError::UnexpectedMessage(message)) else {
    fail("expected closed queue to surface the same error")
  }
  assert_eq(message, "boom")
}
