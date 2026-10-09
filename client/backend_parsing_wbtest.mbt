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
  let packet = Buffer()
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
  let payload = Buffer()
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
    RowDescription(body) => body
    _ => fail("expected RowDescription message")
  }
}

///|
fn make_data_row_body(values : Array[Bytes?]) -> @backend.DataRowBody raise {
  let payload = Buffer()
  payload.write_int16_be(@proto.checked_i16(values.length()))
  for value in values {
    if value is Some(value) {
      payload.write_int_be(@proto.i32_from_usize(value.length()))
      payload.write_bytes(value)
    } else {
      payload.write_int_be(-1)
    }
  }
  match
    parse_backend_message(
      parsing_backend_packet(@backend.DATA_ROW_TAG, payload),
    ) {
    DataRow(body) => body
    _ => fail("expected DataRow message")
  }
}

///|
fn make_copy_formats(formats : Array[Int]) -> @backend.ColumnFormats raise {
  let payload = Buffer()
  payload.write_byte(0)
  payload.write_int16_be(@proto.checked_i16(formats.length()))
  for format in formats {
    payload.write_int16_be(@proto.checked_i16(format))
  }
  match
    parse_backend_message(
      parsing_backend_packet(@backend.COPY_IN_RESPONSE_TAG, payload),
    ) {
    CopyInResponse(body) => body.column_formats()
    _ => fail("expected CopyInResponse message")
  }
}

///|
fn make_error_fields(
  fields : Array[(Byte, Bytes)],
) -> @backend.ErrorFields raise {
  let payload = Buffer()
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
    ErrorResponse(body) => body.fields()
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
  @debug.assert_eq(columns.length(), 2)
  @debug.assert_eq(columns[0].name, "answer")
  @debug.assert_eq(columns[0].table_oid, 7U)
  @debug.assert_eq(columns[0].column_id, 1)
  assert_true(columns[0].type_ == Type::int4())
  assert_true(columns[0].format == Text)
  assert_true(columns[1].type_ == Type::unknown(99999U, name="oid_99999"))
  assert_true(columns[1].format == Binary)
  @debug.assert_eq(parse_column_names(body), ["answer", "mystery"])
}

///|
test "backend parsing decodes data rows, copy formats, and invalid utf8" {
  let binary = parse_binary_values(
    make_data_row_body([Some(bytes_of([1, 2])), None, Some(b"moon")]),
  )
  @debug.assert_eq(binary, [Some(bytes_of([1, 2])), None, Some(b"moon")])

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

  let invalid_utf8 = @test.expect_error(() => {
    parse_text_row(make_data_row_body([Some(bytes_of([b'\xC2']))]), ["bad"])
  })
  guard invalid_utf8 is @proto.ProtocolError::InvalidInput(message) else {
    fail("expected invalid UTF-8 error")
  }
  @debug.assert_eq(message, "invalid UTF-8")

  assert_true(parse_copy_formats(make_copy_formats([0, 1])) == [Text, Binary])
  let invalid_format = @test.expect_error(() => {
    parse_copy_formats(make_copy_formats([2]))
  })
  guard invalid_format is ClientError::Protocol(message) else {
    fail("expected unsupported wire format error")
  }
  @debug.assert_eq(message, "unsupported wire format code: 2")
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
  @debug.assert_eq(err.severity, Some("ERROR"))
  @debug.assert_eq(err.code, Some("23505"))
  @debug.assert_eq(err.message, "duplicate key")
  @debug.assert_eq(err.detail, Some("detail text"))
  @debug.assert_eq(err.hint, Some("hint text"))

  let default_message = parse_database_error(
    make_error_fields([(b'S', b"ERROR")]),
  )
  @debug.assert_eq(default_message.message, "database error")
  @debug.assert_eq(default_message.severity, Some("ERROR"))

  let invalid_utf8 = @test.expect_error(() => {
    parse_database_error(make_error_fields([(b'M', bytes_of([b'\xC2']))]))
  })
  guard invalid_utf8 is @proto.ProtocolError::InvalidInput(message) else {
    fail("expected invalid UTF-8 error")
  }
  @debug.assert_eq(message, "invalid UTF-8")
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
      format: Binary,
    },
  ]
  let merged = merge_stream_columns(resolved, body)
  @debug.assert_eq(merged[0].name, "value")
  @debug.assert_eq(merged[0].table_oid, 11U)
  assert_true(merged[0].type_ == Type::unknown(23U, name="resolved_int4"))
  assert_true(merged[0].format == Text)

  let mismatch_count = @test.expect_error(() => {
    merge_stream_columns([resolved[0], resolved[0]], body)
  })
  guard mismatch_count is ClientError::Protocol(message) else {
    fail("expected column count mismatch")
  }
  @debug.assert_eq(
    message, "row description column count mismatch: expected 2, got 1",
  )

  let mismatch_oid = @test.expect_error(() => {
    merge_stream_columns(
      [{ ..resolved[0], type_: Type::unknown(25U, name="text"), }],
      body,
    )
  })
  guard mismatch_oid is ClientError::Protocol(message) else {
    fail("expected column oid mismatch")
  }
  @debug.assert_eq(
    message, "row description type mismatch at column 0: expected oid 25, got 23",
  )
}

///|
async test "backend parsing fail_response_stream closes queue with error" {
  let responses : @async.Queue[Int] = Queue(kind=Unbounded)
  let result = expect_error_async(() => {
    let _ : Unit = fail_response_stream(
      responses,
      ClientError::UnexpectedMessage("boom"),
    )
  })
  guard result is ClientError::UnexpectedMessage(message) else {
    fail("expected fail_response_stream to re-raise the error")
  }
  @debug.assert_eq(message, "boom")

  let drained = expect_error_async(() => responses.get())
  guard drained is ClientError::UnexpectedMessage(message) else {
    fail("expected closed queue to surface the same error")
  }
  @debug.assert_eq(message, "boom")
}

///|
fn all_database_error_fields() -> Array[(Byte, Bytes)] {
  [
    (b'S', @proto.utf8_encode("错误")),
    (b'V', @proto.utf8_encode("ERROR")),
    (b'C', @proto.utf8_encode("23505")),
    (b'M', @proto.utf8_encode("重复 🔑")),
    (b'D', @proto.utf8_encode("第一行\n第二行")),
    (b'H', @proto.utf8_encode("提示\n重试")),
    (b's', @proto.utf8_encode("模式")),
    (b't', @proto.utf8_encode("表😀")),
    (b'c', @proto.utf8_encode("列")),
    (b'd', @proto.utf8_encode("类型")),
    (b'n', @proto.utf8_encode("唯一约束")),
    (b'P', @proto.utf8_encode("19")),
    (b'p', @proto.utf8_encode("7")),
    (b'q', @proto.utf8_encode("select '😀';\nselect missing")),
    (b'W', @proto.utf8_encode("函数一\n函数二")),
    (b'F', @proto.utf8_encode("source.c")),
    (b'L', @proto.utf8_encode("123")),
    (b'R', @proto.utf8_encode("routine_name")),
  ]
}

///|
test "database error preserves every official field and Unicode text" {
  let err = parse_database_error(make_error_fields(all_database_error_fields()))
  @debug.assert_eq(err.severity, Some("错误"))
  @debug.assert_eq(err.severity_nonlocalized, Some("ERROR"))
  @debug.assert_eq(err.code, Some("23505"))
  @debug.assert_eq(err.message, "重复 🔑")
  @debug.assert_eq(err.detail, Some("第一行\n第二行"))
  @debug.assert_eq(err.hint, Some("提示\n重试"))
  @debug.assert_eq(err.schema, Some("模式"))
  @debug.assert_eq(err.table, Some("表😀"))
  @debug.assert_eq(err.column, Some("列"))
  @debug.assert_eq(err.datatype, Some("类型"))
  @debug.assert_eq(err.constraint, Some("唯一约束"))
  @debug.assert_eq(err.position, Some(19U))
  @debug.assert_eq(err.internal_position, Some(7U))
  @debug.assert_eq(err.internal_query, Some("select '😀';\nselect missing"))
  @debug.assert_eq(err.where_, Some("函数一\n函数二"))
  @debug.assert_eq(err.file, Some("source.c"))
  @debug.assert_eq(err.line, Some(123U))
  @debug.assert_eq(err.routine, Some("routine_name"))
}

///|
test "database error fields are independently optional" {
  let fields = all_database_error_fields()
  let full = parse_database_error(make_error_fields(fields))
  let empty = parse_database_error(make_error_fields([]))
  @debug.assert_eq(empty.message, "database error")
  @debug.assert_eq(empty.severity, None)
  @debug.assert_eq(empty.severity_nonlocalized, None)
  @debug.assert_eq(empty.code, None)
  @debug.assert_eq(empty.detail, None)
  @debug.assert_eq(empty.hint, None)
  @debug.assert_eq(empty.schema, None)
  @debug.assert_eq(empty.table, None)
  @debug.assert_eq(empty.column, None)
  @debug.assert_eq(empty.datatype, None)
  @debug.assert_eq(empty.constraint, None)
  @debug.assert_eq(empty.position, None)
  @debug.assert_eq(empty.internal_position, None)
  @debug.assert_eq(empty.internal_query, None)
  @debug.assert_eq(empty.where_, None)
  @debug.assert_eq(empty.file, None)
  @debug.assert_eq(empty.line, None)
  @debug.assert_eq(empty.routine, None)
  for field in fields {
    let (tag, value) = field
    let without = parse_database_error(
      make_error_fields(fields.filter(field => field.0 != tag)),
    )
    let alone = parse_database_error(make_error_fields([(tag, value)]))
    let expected_without = match tag {
      b'S' => { ..full, severity: None, }
      b'V' => { ..full, severity_nonlocalized: None, }
      b'C' => { ..full, code: None, }
      b'M' => { ..full, message: "database error", }
      b'D' => { ..full, detail: None, }
      b'H' => { ..full, hint: None, }
      b's' => { ..full, schema: None, }
      b't' => { ..full, table: None, }
      b'c' => { ..full, column: None, }
      b'd' => { ..full, datatype: None, }
      b'n' => { ..full, constraint: None, }
      b'P' => { ..full, position: None, }
      b'p' => { ..full, internal_position: None, }
      b'q' => { ..full, internal_query: None, }
      b'W' => { ..full, where_: None, }
      b'F' => { ..full, file: None, }
      b'L' => { ..full, line: None, }
      b'R' => { ..full, routine: None, }
      _ => fail("unexpected fixture tag")
    }
    let expected_alone = match tag {
      b'S' => { ..empty, severity: full.severity, }
      b'V' => { ..empty, severity_nonlocalized: full.severity_nonlocalized, }
      b'C' => { ..empty, code: full.code, }
      b'M' => { ..empty, message: full.message, }
      b'D' => { ..empty, detail: full.detail, }
      b'H' => { ..empty, hint: full.hint, }
      b's' => { ..empty, schema: full.schema, }
      b't' => { ..empty, table: full.table, }
      b'c' => { ..empty, column: full.column, }
      b'd' => { ..empty, datatype: full.datatype, }
      b'n' => { ..empty, constraint: full.constraint, }
      b'P' => { ..empty, position: full.position, }
      b'p' => { ..empty, internal_position: full.internal_position, }
      b'q' => { ..empty, internal_query: full.internal_query, }
      b'W' => { ..empty, where_: full.where_, }
      b'F' => { ..empty, file: full.file, }
      b'L' => { ..empty, line: full.line, }
      b'R' => { ..empty, routine: full.routine, }
      _ => fail("unexpected fixture tag")
    }
    @debug.assert_eq(without, expected_without)
    @debug.assert_eq(alone, expected_alone)
    assert_true(without != full)
  }
}

///|
test "database error severity is independent of S and V order" {
  let sv = parse_database_error(
    make_error_fields([(b'S', @proto.utf8_encode("错误")), (b'V', b"ERROR")]),
  )
  let vs = parse_database_error(
    make_error_fields([(b'V', b"ERROR"), (b'S', @proto.utf8_encode("错误"))]),
  )
  @debug.assert_eq(sv, vs)
  @debug.assert_eq(sv.severity, Some("错误"))
  @debug.assert_eq(sv.severity_nonlocalized, Some("ERROR"))
}

///|
test "database error equality includes constraint and object fields" {
  let base = [(b'C', b"23505"), (b'M', b"duplicate key")]
  let first = parse_database_error(
    make_error_fields(
      base + [(b's', b"public"), (b't', b"accounts"), (b'n', b"email_unique")],
    ),
  )
  let second = parse_database_error(
    make_error_fields(
      base + [(b's', b"public"), (b't', b"accounts"), (b'n', b"name_unique")],
    ),
  )
  let stripped = parse_database_error(make_error_fields(base))
  @debug.assert_eq(first.code, second.code)
  assert_true(first != second)
  assert_true(first != stripped)
}

///|
test "database error validates UTF8 for all fields including unknown tags" {
  for
    tag in [
      b'S', b'V', b'C', b'M', b'D', b'H', b's', b't', b'c', b'd', b'n', b'P', b'p',
      b'q', b'W', b'F', b'L', b'R', b'X',
    ] {
    let err = @test.expect_error(() => {
      parse_database_error(make_error_fields([(tag, bytes_of([0xC2]))]))
    })
    assert_true(err is @proto.ProtocolError::InvalidInput("invalid UTF-8"))
  }
}

///|
test "database error numeric fields reject malformed and overflowing values" {
  for tag in [b'P', b'p', b'L'] {
    for
      value in [
        "", "+1", "-1", " 1", "1 ", "1\n", "1.0", "0x10", "1_0", "one", "１", "١",
        "4294967296", "18446744073709551616",
      ] {
      let err = @test.expect_error(() => {
        parse_database_error(
          make_error_fields([(tag, @proto.utf8_encode(value))]),
        )
      })
      assert_true(err is @proto.ProtocolError::InvalidInput(_))
    }
    for
      case in [
        ("1", 1U),
        ("0001", 1U),
        ("2147483648", 2147483648U),
        ("4294967295", 4294967295U),
      ] {
      let (value, expected) = case
      let err = parse_database_error(
        make_error_fields([(tag, @proto.utf8_encode(value))]),
      )
      let actual = match tag {
        b'P' => err.position
        b'p' => err.internal_position
        _ => err.line
      }
      @debug.assert_eq(actual, Some(expected))
    }
  }
  for tag in [b'P', b'p'] {
    for value in [b"0", b"000"] {
      let err = @test.expect_error(() => {
        parse_database_error(make_error_fields([(tag, value)]))
      })
      assert_true(err is @proto.ProtocolError::InvalidInput(_))
    }
  }
  @debug.assert_eq(
    parse_database_error(make_error_fields([(b'L', b"0")])).line,
    Some(0U),
  )
}
