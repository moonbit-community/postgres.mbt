///|
fn make_row(
  type_ : Type,
  raw : Bytes,
  format? : WireFormat = WireFormat::Text,
) -> Row {
  let columns : Array[Column] = [
    {
      name: "value",
      table_oid: 0U,
      column_id: 0,
      type_,
      type_size: -1,
      type_modifier: -1,
      format,
    },
  ]
  { columns, values: [Some(raw)] }
}

///|
fn assert_encode_ok(param : &ToSql, type_ : Type) -> Unit raise {
  let result : Result[EncodedParam, Error] = try? encode_param(param, type_)
  guard result is Ok(_) else { fail("expected encode to accept \{type_.name}") }
}

///|
fn assert_encode_wrong_type(param : &ToSql, type_ : Type) -> Unit raise {
  let result : Result[EncodedParam, Error] = try? encode_param(param, type_)
  guard result is Err(ClientError::WrongType(_)) else {
    fail("expected wrong type for \{type_.name}")
  }
}

///|
fn assert_encode_format(
  param : &ToSql,
  type_ : Type,
  expected : WireFormat,
) -> Unit raise {
  let result : Result[EncodedParam, Error] = try? encode_param(param, type_)
  guard result is Ok(encoded) else {
    fail("expected encode to accept \{type_.name}")
  }
  @debug.assert_eq(encoded.format, expected)
}

///|
test "built-in ToSql compatibility remains stable" {
  assert_encode_ok(true, Type::bool())
  assert_encode_ok(1, Type::int2())
  assert_encode_ok(1, Type::int4())
  assert_encode_wrong_type(1, Type::int8())
  assert_encode_ok(1L, Type::int8())
  assert_encode_ok(1U, Type::oid_type())
  assert_encode_ok(Float::from_double(1.5), Type::float4())
  assert_encode_ok(1.5, Type::float8())
  assert_encode_ok("moonbit", Type::text())
  assert_encode_ok("moonbit", Type::varchar())
  assert_encode_ok(b"abc", Type::bytea())
  assert_encode_ok(b"1234567890abcdef", Type::uuid())
  assert_encode_ok(
    Json::object({ "lang": Json::string("moonbit") }),
    Type::json(),
  )
  assert_encode_ok(
    Json::object({ "lang": Json::string("moonbit") }),
    Type::jsonb(),
  )
}

///|
test "built-in wire formats remain stable" {
  assert_encode_format(true, Type::bool(), WireFormat::Binary)
  assert_encode_format("moonbit", Type::text(), WireFormat::Text)
  assert_encode_format(Json::null(), Type::json(), WireFormat::Text)
  assert_encode_format(Json::null(), Type::jsonb(), WireFormat::Text)
  assert_encode_format((None : String?), Type::text(), WireFormat::Binary)
}

///|
test "built-in FromSql compatibility remains stable" {
  let bool_value : Bool = make_row(Type::bool(), b"true").get(0)
  @debug.assert_eq(bool_value, true)

  let int2_value : Int = make_row(Type::int2(), b"7").get(0)
  @debug.assert_eq(int2_value, 7)

  let int4_value : Int = make_row(Type::int4(), b"9").get(0)
  @debug.assert_eq(int4_value, 9)

  let int8_value : Int64 = make_row(Type::int8(), b"11").get(0)
  @debug.assert_eq(int8_value, 11L)

  let oid_value : UInt = make_row(Type::oid_type(), b"13").get(0)
  @debug.assert_eq(oid_value, 13U)

  let float_value : Float = make_row(Type::float4(), b"1.5").get(0)
  @debug.assert_eq(float_value, Float::from_double(1.5))

  let double_value : Double = make_row(Type::float8(), b"2.5").get(0)
  @debug.assert_eq(double_value, 2.5)

  let text_value : String = make_row(Type::text(), b"hello").get(0)
  @debug.assert_eq(text_value, "hello")

  let varchar_value : String = make_row(Type::varchar(), b"world").get(0)
  @debug.assert_eq(varchar_value, "world")

  let bytea_value : Bytes = make_row(
    Type::bytea(),
    b"abc",
    format=WireFormat::Binary,
  ).get(0)
  @debug.assert_eq(bytea_value, b"abc")

  let uuid_value : Bytes = make_row(
    Type::uuid(),
    b"1234567890abcdef",
    format=WireFormat::Binary,
  ).get(0)
  @debug.assert_eq(uuid_value, b"1234567890abcdef")

  let json_value : Json = make_row(
    Type::json(),
    b"{\"lang\":\"moonbit\",\"ok\":true}",
  ).get(0)
  @debug.assert_eq(
    json_value,
    Json::object({ "lang": Json::string("moonbit"), "ok": Json::boolean(true) }),
  )

  let jsonb_payload = @buffer.new()
  jsonb_payload.write_byte(b'\x01')
  jsonb_payload.write_bytes(b"{\"lang\":\"moonbit\",\"ok\":true}")
  let jsonb_value : Json = make_row(
    Type::jsonb(),
    jsonb_payload.to_bytes(),
    format=WireFormat::Binary,
  ).get(0)
  @debug.assert_eq(
    jsonb_value,
    Json::object({ "lang": Json::string("moonbit"), "ok": Json::boolean(true) }),
  )
}

///|
test "built-in FromSql rejects unsupported types before decoding" {
  let int_result : Result[Int, Error] = try? make_row(Type::int8(), b"1").get(0)
  guard int_result is Err(ClientError::WrongType(_)) else {
    fail("expected int wrong type")
  }

  let string_result : Result[String, Error] = try? make_row(Type::int4(), b"1").get(
    0,
  )
  guard string_result is Err(ClientError::WrongType(_)) else {
    fail("expected string wrong type")
  }

  let bytes_result : Result[Bytes, Error] = try? make_row(Type::text(), b"abc").get(
    0,
  )
  guard bytes_result is Err(ClientError::WrongType(_)) else {
    fail("expected bytes wrong type")
  }

  let json_result : Result[Json, Error] = try? make_row(Type::text(), b"{}").get(
    0,
  )
  guard json_result is Err(ClientError::WrongType(_)) else {
    fail("expected json wrong type")
  }
}

///|
test "wire format parser rejects unsupported codes" {
  let result : Result[WireFormat, Error] = try? decode_wire_format(2)
  guard result is Err(ClientError::Protocol(message)) else {
    fail("expected protocol error")
  }
  @debug.assert_eq(message, "unsupported wire format code: 2")
}
