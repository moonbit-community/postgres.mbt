///|
struct NulTestParam {
  payload : Bytes
  format_ : WireFormat
  is_null : @proto.IsNull
  accepts_ : Bool
  error : String?
  events : Array[String]
}

///|
fn nul_test_param(
  payload : Bytes,
  format? : WireFormat = Text,
  is_null? : @proto.IsNull = No,
  accepts? : Bool = true,
  error? : String,
) -> NulTestParam {
  { payload, format_: format, is_null, accepts_: accepts, error, events: [], }
}

///|
impl ToSql for NulTestParam with fn accepts(self, _) {
  self.events.push("accepts")
  self.accepts_
}

///|
impl ToSql for NulTestParam with fn moonbit_type_name(_) {
  "NulTestParam"
}

///|
impl ToSql for NulTestParam with fn to_sql(self, _, buf) {
  self.events.push("to_sql")
  buf.write_bytes(self.payload)
  if self.error is Some(message) {
    raise ClientError::Encode(message)
  }
  self.is_null
}

///|
impl ToSql for NulTestParam with fn format(self, _) {
  self.events.push("format")
  self.format_
}

///|
fn assert_string_nul_error(param : &ToSql, type_ : Type) -> Unit raise {
  assert_true(
    @test.expect_error(() => encode_param(param, type_))
    is ClientError::Encode(
      "PostgreSQL string parameters must not contain NUL (U+0000)"
    ),
  )
}

///|
test "string parameters reject NUL in scalars views options and arrays" {
  for
    type_ in [
      Type::text(),
      Type::varchar(),
      Type::name_type(),
      Type::unknown(90012U, name="bpchar"),
      Type::unknown(90013U, name="citext"),
      Type::unknown(90014U, name="unknown"),
      text_extension_type("ltree"),
      text_extension_type("lquery"),
      text_extension_type("ltxtquery"),
    ] {
    let array_type = text_extension_array_type(type_)
    for
      value in [
        "\u0000abc", "a\u0000bc", "abc\u0000", "\u0000a\u0000", "\u0000",
      ] {
      let source = "prefix-\{value}-suffix"
      let view = source.exact_view(start=7, end=7 + value.length())
      assert_string_nul_error(value, type_)
      assert_string_nul_error(view, type_)
      assert_string_nul_error(Some(value), type_)
      assert_string_nul_error(Some(view), type_)
      assert_string_nul_error(["valid", value], array_type)
      assert_string_nul_error(["valid"[:], view], array_type)
      assert_string_nul_error([Some("valid"), None, Some(value)], array_type)
    }
  }
  // Type compatibility is still checked before inspecting string content.
  assert_encode_wrong_type("\u0000", Type::int4())
}

///|
test "string codec NUL failures leave existing buffers untouched" {
  for
    type_ in [
      Type::text(),
      text_extension_type("ltree"),
      text_extension_type("lquery"),
      text_extension_type("ltxtquery"),
    ] {
    let value = "a\u0000b"
    let params : Array[&ToSql] = [value, value[:], Some(value), Some(value[:])]
    for param in params {
      let buf = Buffer()
      buf.write_bytes(b"existing\x00bytes")
      assert_true(
        @test.expect_error(() => param.to_sql(type_, buf))
        is ClientError::Encode(
          "PostgreSQL string parameters must not contain NUL (U+0000)"
        ),
      )
      assert_eq(buf.to_bytes(), b"existing\x00bytes")
    }
  }
}

///|
test "string NUL validation preserves empty Unicode NULL and clean slices" {
  for
    type_ in [
      Type::text(),
      text_extension_type("ltree"),
      text_extension_type("lquery"),
      text_extension_type("ltxtquery"),
    ] {
    for value in ["", "中文", "🌙", "中文🌙", "\\u0000"] {
      let encoded = encode_param(value, type_)
      let expected = Buffer()
      if string_format(type_) is Binary {
        expected.write_byte(b'\x01')
      }
      expected.write_bytes(@utf8.encode(value))
      assert_eq(encoded.value, Some(expected.to_bytes()))
      assert_eq(encode_param(Some(value), type_).value, encoded.value)
      assert_eq(encode_param(value[:], type_).value, encoded.value)
    }
    assert_eq(encode_param((None : String?), type_).value, None)
    assert_eq(encode_param((None : StringView?), type_).value, None)
    let view = "\u0000中文🌙\u0000".exact_view(start=1, end=5)
    assert_eq(
      encode_param(view, type_).value,
      encode_param("中文🌙", type_).value,
    )
  }
}

///|
test "custom text payloads reject zero bytes after encoding and format selection" {
  for bytes in [b"\x00abc", b"a\x00bc", b"abc\x00", b"\x00a\x00", b"\x00"] {
    let param = nul_test_param(bytes)
    assert_true(
      @test.expect_error(() => encode_param(param, Type::text()))
      is ClientError::Encode(
        "PostgreSQL text-format parameters must not contain NUL (0x00)"
      ),
    )
    assert_eq(param.events, ["accepts", "to_sql", "format"])
  }
  for bytes in [b"", b"valid", b"\\u0000", b"\xe4\xb8\xad\xf0\x9f\x8c\x99"] {
    let param = nul_test_param(bytes)
    let encoded = encode_param(param, Type::text())
    assert_eq(encoded.format, Text)
    assert_eq(encoded.value, Some(bytes))
    assert_eq(param.events, ["accepts", "to_sql", "format"])
  }
  let null = nul_test_param(b"\x00ignored", is_null=Yes)
  assert_eq(encode_param(null, Type::text()).value, None)
  assert_eq(null.events, ["accepts", "to_sql", "format"])
  let wrong_type = nul_test_param(b"\x00", accepts=false)
  assert_encode_wrong_type(wrong_type, Type::text())
  assert_eq(wrong_type.events, ["accepts"])
  let failing = nul_test_param(b"\x00", error="original codec error")
  assert_true(
    @test.expect_error(() => encode_param(failing, Type::text()))
    is ClientError::Encode("original codec error"),
  )
  assert_eq(failing.events, ["accepts", "to_sql"])
}

///|
test "binary payloads and bytea preserve zero bytes" {
  let bytes = b"\x00a\x00b\x00"
  let param = nul_test_param(bytes, format=Binary)
  let encoded = encode_param(param, Type::text())
  assert_eq(encoded.format, Binary)
  assert_eq(encoded.value, Some(bytes))
  assert_eq(param.events, ["accepts", "to_sql", "format"])
  let bytea = encode_param(bytes, Type::bytea())
  assert_eq(bytea.format, Binary)
  assert_eq(bytea.value, Some(bytes))
}

///|
test "JSON escaped NUL is not a zero byte or a logical value validation error" {
  for type_ in [Type::json(), Type::jsonb()] {
    let encoded = encode_param(Json::string("a\u0000b"), type_)
    assert_eq(encoded.format, Text)
    assert_eq(encoded.value, Some(b"\"a\\u0000b\""))
    let custom = nul_test_param(b"\"a\\u0000b\"")
    assert_eq(encode_param(custom, type_).value, encoded.value)
  }
}
