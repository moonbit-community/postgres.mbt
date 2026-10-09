///|
fn metadata_test_oid(oid : UInt) -> Bytes {
  let buf = Buffer()
  buf.write_uint_be(oid)
  buf.to_bytes()
}

///|
fn metadata_test_name(request : Request) -> Bytes raise {
  assert_eq(request.bytes[0], b'P')
  let mut end = 5
  while request.bytes[end] != 0 {
    end += 1
  }
  request.bytes[5:end].to_owned()
}

///|
async fn metadata_test_prepare(
  request : Request,
  columns : Array[Type],
  params? : Array[UInt] = [],
) -> Unit {
  request.responses.put(parse_backend_message(b"1\x00\x00\x00\x04"))
  let payload = Buffer()
  payload.write_int16_be(@proto.checked_i16(params.length()))
  for oid in params {
    payload.write_uint_be(oid)
  }
  request.responses.put(
    copy_test_parse_backend_message(copy_test_backend_packet(b't', payload)),
  )
  request.responses.put(metadata_test_description(columns))
  request.responses.put(copy_test_ready_for_query_message())
}

///|
async fn metadata_test_close(request : Request, name : Bytes) -> Unit {
  assert_eq(request.bytes, close_bytes(b'S', name[:]))
  request.responses.put(copy_test_close_complete_message())
  request.responses.put(copy_test_ready_for_query_message())
}

///|
/// Drive the real catalog-query protocol, including its temporary Close.
async fn metadata_test_catalog(
  next_request : async () -> Request,
  sql : String,
  oid : UInt,
  columns : Array[Type],
  rows : Array[Array[Bytes?]],
  database_error? : Bool = false,
) -> Unit {
  let prepare = next_request()
  let name = metadata_test_name(prepare)
  assert_eq(prepare.bytes, prepare_bytes(name[:], sql, [Type::oid_type()]))
  metadata_test_prepare(prepare, columns, params=[Type::oid_type().oid])
  let execute = next_request()
  let params : Array[&ToSql] = [oid]
  assert_eq(
    execute.bytes,
    execute_statement_bytes(name[:], [Type::oid_type()], params),
  )
  for row in rows {
    execute.responses.put(metadata_test_row(row))
  }
  if database_error {
    execute.responses.put(copy_test_error_response_message("catalog denied"))
  } else {
    execute.responses.put(
      copy_test_command_complete_message("SELECT \{rows.length()}"),
    )
  }
  execute.responses.put(copy_test_ready_for_query_message())
  metadata_test_close(next_request(), name)
}

///|
async fn metadata_test_shape(
  next_request : async () -> Request,
  oid : UInt,
  elem? : UInt = 0U,
  base? : UInt = 0U,
  subtype? : UInt,
  relid? : UInt = 0U,
  typtype? : String = "b",
) -> Unit {
  metadata_test_catalog(
    next_request,
    typeinfo_query,
    oid,
    [
      Type::text(),
      Type::text(),
      Type::oid_type(),
      Type::oid_type(),
      Type::oid_type(),
      Type::text(),
      Type::oid_type(),
    ],
    [
      [
        Some(b"custom"),
        Some(@proto.utf8_encode(typtype)),
        Some(metadata_test_oid(elem)),
        subtype.map(metadata_test_oid),
        Some(metadata_test_oid(base)),
        Some(b"test_schema"),
        Some(metadata_test_oid(relid)),
      ],
    ],
  )
}

///|
fn metadata_test_description(columns : Array[Type]) -> @backend.Message raise {
  let payload = Buffer()
  payload.write_int16_be(@proto.checked_i16(columns.length()))
  for type_ in columns {
    payload.write_bytes(b"value")
    payload.write_byte(0)
    payload.write_uint_be(0U)
    payload.write_int16_be(0)
    payload.write_uint_be(type_.oid)
    payload.write_int16_be(-1)
    payload.write_int_be(-1)
    payload.write_int16_be(1)
  }
  parse_backend_message(
    parsing_backend_packet(@backend.ROW_DESCRIPTION_TAG, payload),
  )
}

///|
fn metadata_test_row(values : Array[Bytes?]) -> @backend.Message raise {
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
  parse_backend_message(parsing_backend_packet(@backend.DATA_ROW_TAG, payload))
}
