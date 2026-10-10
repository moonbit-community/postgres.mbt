///|
fn make_row(type_ : Type, raw : Bytes, format? : WireFormat = Text) -> Row {
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
  { columns, values: [Some(raw)], }
}

///|
fn assert_encode_ok(param : &ToSql, type_ : Type) -> Unit raise {
  ignore(encode_param(param, type_))
}

///|
fn assert_encode_wrong_type(param : &ToSql, type_ : Type) -> Unit raise {
  let error = @test.expect_error(() => encode_param(param, type_))
  guard error is ClientError::WrongType(_) else {
    fail("expected wrong type for \{type_.name}")
  }
}

///|
fn assert_encode_format(
  param : &ToSql,
  type_ : Type,
  expected : WireFormat,
) -> Unit raise {
  let encoded = encode_param(param, type_)
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
  let text_view = "prefix-moonbit-suffix".exact_view(start=7, end=14)
  assert_encode_ok(text_view, Type::text())
  assert_encode_ok(text_view, Type::varchar())
  assert_encode_wrong_type(text_view, Type::int4())
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
  assert_encode_format(true, Type::bool(), Binary)
  assert_encode_format("moonbit", Type::text(), Text)
  assert_encode_format("moonbit"[:], Type::text(), Text)
  assert_encode_format(Json::null(), Type::json(), Text)
  assert_encode_format(Json::null(), Type::jsonb(), Text)
  assert_encode_format((None : String?), Type::text(), Binary)
}

///|
test "StringView ToSql encodes only the viewed text" {
  let text_view = "prefix-moonbit-suffix".exact_view(start=7, end=14)
  let encoded = encode_param(text_view, Type::text())
  @debug.assert_eq(encoded.value, Some(b"moonbit"))
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

  let bytea_value : Bytes = make_row(Type::bytea(), b"abc", format=Binary).get(
    0,
  )
  @debug.assert_eq(bytea_value, b"abc")

  let uuid_value : Bytes = make_row(
    Type::uuid(),
    b"1234567890abcdef",
    format=Binary,
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

  let jsonb_payload = Buffer()
  jsonb_payload.write_byte(b'\x01')
  jsonb_payload.write_bytes(b"{\"lang\":\"moonbit\",\"ok\":true}")
  let jsonb_value : Json = make_row(
    Type::jsonb(),
    jsonb_payload.to_bytes(),
    format=Binary,
  ).get(0)
  @debug.assert_eq(
    jsonb_value,
    Json::object({ "lang": Json::string("moonbit"), "ok": Json::boolean(true) }),
  )
}

///|
test "built-in Array codecs support binary arrays" {
  let ints = [1, 2, 3]
  assert_encode_format(ints, Type::int4_array(), Binary)
  let encoded_ints = encode_param(ints, Type::int4_array())
  guard encoded_ints.value is Some(int_bytes) else {
    fail("expected encoded int array bytes")
  }
  let decoded_ints : Array[Int] = make_row(
    Type::int4_array(),
    int_bytes,
    format=Binary,
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
    format=Binary,
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
    format=Binary,
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
    format=Binary,
  ).get(0)
  @debug.assert_eq(decoded_json, json_values)

  let encoded_jsonb = encode_param(json_values, Type::jsonb_array())
  guard encoded_jsonb.value is Some(jsonb_bytes) else {
    fail("expected encoded jsonb array bytes")
  }
  let decoded_jsonb : Array[Json] = make_row(
    Type::jsonb_array(),
    jsonb_bytes,
    format=Binary,
  ).get(0)
  @debug.assert_eq(decoded_jsonb, json_values)
}

///|
test "built-in Array codecs reject unsupported and mismatched arrays" {
  let ints = [1, 2]
  assert_encode_wrong_type(ints, Type::text_array())

  let text_array_error = @test.expect_error(() => {
    let _ : Array[String] = make_row(Type::text_array(), b"{moon,bit}").get(0)
  })
  guard text_array_error is ClientError::Decode(_) else {
    fail("expected text array decode failure")
  }
}

///|
test "built-in FromSql rejects unsupported types before decoding" {
  let int_error = @test.expect_error(() => {
    let _ : Int = make_row(Type::int8(), b"1").get(0)
  })
  guard int_error is ClientError::WrongType(_) else {
    fail("expected int wrong type")
  }

  let string_error = @test.expect_error(() => {
    let _ : String = make_row(Type::int4(), b"1").get(0)
  })
  guard string_error is ClientError::WrongType(_) else {
    fail("expected string wrong type")
  }

  let bytes_error = @test.expect_error(() => {
    let _ : Bytes = make_row(Type::text(), b"abc").get(0)
  })
  guard bytes_error is ClientError::WrongType(_) else {
    fail("expected bytes wrong type")
  }

  let json_error = @test.expect_error(() => {
    let _ : Json = make_row(Type::text(), b"{}").get(0)
  })
  guard json_error is ClientError::WrongType(_) else {
    fail("expected json wrong type")
  }
}

///|
test "wire format parser rejects unsupported codes" {
  let error = @test.expect_error(() => decode_wire_format(2))
  guard error is ClientError::Protocol(message) else {
    fail("expected protocol error")
  }
  @debug.assert_eq(message, "unsupported wire format code: 2")
}

///|
fn text_extension_type(name : String) -> Type {
  Type::unknown(90010U, name~)
}

///|
fn text_extension_array_type(element : Type) -> Type {
  {
    oid: 90011U,
    name: "_\{element.name}",
    schema: element.schema,
    kind: Array(element),
  }
}

///|
test "extension strings and views encode versioned binary UTF-8" {
  let cases : Array[(String, String, Bytes)] = [
    ("ltree", "a.b", b"\x01a.b"),
    ("lquery", "*.x", b"\x01*.x"),
    ("ltxtquery", "foo & bar", b"\x01foo & bar"),
  ]
  for case in cases {
    let (name, value, expected) = case
    let type_ = text_extension_type(name)
    let encoded = encode_param(value, type_)
    assert_eq(encoded.format, Binary)
    assert_eq(encoded.value, Some(expected))
    let source = "prefix-\{value}-suffix"
    let view = source.exact_view(start=7, end=7 + value.length())
    let encoded_view = encode_param(view, type_)
    assert_eq(encoded_view.format, Binary)
    assert_eq(encoded_view.value, Some(expected))
    let unicode = "树.🌙"
    let unicode_bytes : Bytes = b"\x01\xe6\xa0\x91.\xf0\x9f\x8c\x99"
    assert_eq(encode_param(unicode, type_).value, Some(unicode_bytes))
    let unicode_source = "prefix-树.🌙-suffix"
    let unicode_view = unicode_source.exact_view(start=7, end=11)
    assert_eq(encode_param(unicode_view, type_).value, Some(unicode_bytes))
    assert_eq(encode_param("", type_).value, Some(b"\x01"))
    assert_encode_format(Some(value), type_, Binary)
    let null = encode_param((None : String?), type_)
    assert_eq(null.format, Binary)
    assert_eq(null.value, None)
  }
}

///|
test "extension strings decode text and versioned binary including Unicode and NULL" {
  for name in ["ltree", "lquery", "ltxtquery"] {
    let type_ = text_extension_type(name)
    for
      case in [
        (Text, b"\xe6\xa0\x91.\xf0\x9f\x8c\x99"),
        (Binary, b"\x01\xe6\xa0\x91.\xf0\x9f\x8c\x99"),
      ] {
      let (format, bytes) = case
      let value : String = make_row(type_, bytes, format~).get(0)
      assert_eq(value, "树.🌙")
      let optional : String? = make_row(type_, bytes, format~).get(0)
      assert_eq(optional, Some(value))
      let null_row = { ..make_row(type_, bytes, format~), values: [None], }
      let null : String? = null_row.get(0)
      assert_eq(null, None)
      assert_true(
        @test.expect_error(() => {
          let _ : String = null_row.get(0)
        })
        is ClientError::Decode(_),
      )
    }
    let empty_text : String = make_row(type_, b"").get(0)
    let empty_binary : String = make_row(type_, b"\x01", format=Binary).get(0)
    assert_eq(empty_text, "")
    assert_eq(empty_binary, "")
    // A leading version-like byte in text format must remain part of the text.
    let text : String = make_row(type_, b"\x01a").get(0)
    assert_eq(text, "\u0001a")
  }
}

///|
test "extension string decoders reject missing versions wrong versions and invalid UTF-8" {
  for name in ["ltree", "lquery", "ltxtquery"] {
    let type_ = text_extension_type(name)
    for bytes in [b"", b"\x00a", b"\x02a", b"a.b"] {
      let error = @test.expect_error(() => {
        let _ : String = make_row(type_, bytes, format=Binary).get(0)
      })
      guard error is @proto.ProtocolError::InvalidInput(message) else {
        fail("expected invalid version")
      }
      assert_eq(message, "\{name} version 1 only supported")
    }
    for case in [(Text, b"\xff"), (Binary, b"\x01\xff")] {
      let (format, bytes) = case
      assert_true(
        @test.expect_error(() => {
          let _ : String = make_row(type_, bytes, format~).get(0)
        })
        is @proto.ProtocolError::InvalidInput("invalid UTF-8"),
      )
    }
  }
}

///|
test "extension string arrays reuse scalar framing for empty multiple and NULL elements" {
  for name in ["ltree", "lquery", "ltxtquery"] {
    let element_type = text_extension_type(name)
    let type_ = text_extension_array_type(element_type)
    let cases : Array[Array[String?]] = [
      [],
      [Some("a"), Some("树.🌙")],
      [Some("a"), None, Some("")],
      [None],
    ]
    for values in cases {
      let encoded = encode_param(values, type_)
      assert_eq(encoded.format, Binary)
      let bytes = encoded.value.unwrap()
      let pg_array = @types.array_from_sql(bytes[:])
      assert_eq(pg_array.element_type, element_type.oid)
      assert_eq(pg_array.elements, values.length())
      let payloads = pg_array.values()
      for value in values {
        if value is Some(text) {
          let expected = Buffer()
          expected.write_byte(b'\x01')
          expected.write_bytes(@utf8.encode(text))
          assert_eq(payloads.next(), Some(Some(expected.to_bytes())))
        } else {
          assert_eq(payloads.next(), Some(None))
        }
      }
      assert_eq(payloads.next(), None)
      let decoded : Array[String?] = make_row(type_, bytes, format=Binary).get(
        0,
      )
      assert_eq(decoded, values)
    }
    for values in [([] : Array[String]), ["a", "b"]] {
      let bytes = encode_param(values, type_).value.unwrap()
      let decoded : Array[String] = make_row(type_, bytes, format=Binary).get(0)
      assert_eq(decoded, values)
    }
    let views = ["prefix-a-suffix".exact_view(start=7, end=8), "b"[:]]
    let bytes = encode_param(views, type_).value.unwrap()
    let decoded : Array[String] = make_row(type_, bytes, format=Binary).get(0)
    assert_eq(decoded, ["a", "b"])
  }
}

///|
test "ordinary string codecs preserve raw UTF-8 and text parameter formats" {
  for
    type_ in [
      Type::text(),
      Type::varchar(),
      Type::name_type(),
      Type::unknown(90012U, name="bpchar"),
      Type::unknown(90013U, name="citext"),
      Type::unknown(90014U, name="unknown"),
    ] {
    assert_encode_format("moonbit", type_, Text)
    assert_encode_format("moonbit"[:], type_, Text)
    assert_eq(encode_param("moonbit", type_).value, Some(b"moonbit"))
    let value : String = make_row(type_, b"\x01moonbit", format=Binary).get(0)
    assert_eq(value, "\u0001moonbit")
  }
}

///|
test "extension string arrays propagate scalar binary validation errors" {
  for name in ["ltree", "lquery", "ltxtquery"] {
    let element = text_extension_type(name)
    let type_ = text_extension_array_type(element)
    for invalid in [b"", b"\x02a", b"\x01\xff"] {
      let buf = Buffer()
      @types.array_to_sql(
        [@types.ArrayDimension::new(1, 1)].iter(),
        element.oid,
        [invalid].iter(),
        (bytes, out) => {
          out.write_bytes(bytes)
          No
        },
        buf,
      )
      let error = @test.expect_error(() => {
        let _ : Array[String] = make_row(type_, buf.to_bytes(), format=Binary).get(
          0,
        )
      })
      guard error is @proto.ProtocolError::InvalidInput(message) else {
        fail("expected scalar protocol error from array decoding")
      }
      assert_eq(
        message,
        if invalid == b"\x01\xff" {
          "invalid UTF-8"
        } else {
          "\{name} version 1 only supported"
        },
      )
    }
  }
}
