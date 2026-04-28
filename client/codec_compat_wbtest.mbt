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
test "built-in Array codecs support binary arrays" {
  let ints = [1, 2, 3]
  assert_encode_format(ints, Type::int4_array(), WireFormat::Binary)
  let encoded_ints = encode_param(ints, Type::int4_array())
  guard encoded_ints.value is Some(int_bytes) else {
    fail("expected encoded int array bytes")
  }
  let decoded_ints : Array[Int] = make_row(
    Type::int4_array(),
    int_bytes,
    format=WireFormat::Binary,
  ).get(0)
  @debug.assert_eq(decoded_ints, ints)

  let texts = ["moon", "bit"]
  let encoded_texts = encode_param(texts, Type::text_array())
  guard encoded_texts.value is Some(text_bytes) else {
    fail("expected encoded text array bytes")
  }
  let decoded_texts : Array[String] = make_row(
    Type::text_array(),
    text_bytes,
    format=WireFormat::Binary,
  ).get(0)
  @debug.assert_eq(decoded_texts, texts)

  let nullable : Array[String?] = [Some("a"), None, Some("b")]
  let encoded_nullable = encode_param(nullable, Type::text_array())
  guard encoded_nullable.value is Some(nullable_bytes) else {
    fail("expected encoded nullable array bytes")
  }
  let decoded_nullable : Array[String?] = make_row(
    Type::text_array(),
    nullable_bytes,
    format=WireFormat::Binary,
  ).get(0)
  @debug.assert_eq(decoded_nullable, nullable)

  let json_values = [
    Json::object({ "lang": Json::string("moonbit") }),
    Json::null(),
  ]
  let encoded_json = encode_param(json_values, Type::json_array())
  guard encoded_json.value is Some(json_bytes) else {
    fail("expected encoded json array bytes")
  }
  let decoded_json : Array[Json] = make_row(
    Type::json_array(),
    json_bytes,
    format=WireFormat::Binary,
  ).get(0)
  @debug.assert_eq(decoded_json, json_values)

  let encoded_jsonb = encode_param(json_values, Type::jsonb_array())
  guard encoded_jsonb.value is Some(jsonb_bytes) else {
    fail("expected encoded jsonb array bytes")
  }
  let decoded_jsonb : Array[Json] = make_row(
    Type::jsonb_array(),
    jsonb_bytes,
    format=WireFormat::Binary,
  ).get(0)
  @debug.assert_eq(decoded_jsonb, json_values)
}

///|
test "built-in Array codecs reject unsupported and mismatched arrays" {
  let ints = [1, 2]
  assert_encode_wrong_type(ints, Type::text_array())

  let text_array_result : Result[Array[String], Error] = try? make_row(
    Type::text_array(),
    b"{moon,bit}",
  ).get(0)
  guard text_array_result is Err(ClientError::Decode(_)) else {
    fail("expected text array decode failure")
  }
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
