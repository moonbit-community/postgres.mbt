///|
priv enum MetadataMood {
  Ready
  Done
} derive(Debug, Eq)

///|
fn metadata_mood_accepts(type_ : Type) -> Bool {
  type_.schema == Some("a") && type_.name == "status" && type_.kind is Enum(_)
}

///|
impl ToSql for MetadataMood with fn accepts(_, type_) {
  metadata_mood_accepts(type_)
}

///|
impl ToSql for MetadataMood with fn moonbit_type_name(_) {
  "MetadataMood"
}

///|
impl ToSql for MetadataMood with fn to_sql(self, type_, buf) {
  assert_true(metadata_mood_accepts(type_))
  buf.write_bytes(
    match self {
      Ready => b"ready"
      Done => b"done"
    },
  )
  No
}

///|
impl FromSql for MetadataMood with fn accepts(type_) {
  metadata_mood_accepts(type_)
}

///|
impl FromSql for MetadataMood with fn moonbit_type_name() {
  "MetadataMood"
}

///|
impl FromSql for MetadataMood with fn from_sql(type_, format, raw) {
  assert_true(metadata_mood_accepts(type_))
  assert_eq(format, Binary)
  match decode_utf8(raw) {
    "ready" => Ready
    "done" => Done
    _ => raise ClientError::Decode("invalid status")
  }
}

///|
fn metadata_mood_type() -> Type {
  {
    oid: 90000U,
    name: "status",
    schema: Some("a"),
    kind: Enum(["ready", "done"]),
  }
}

///|
fn metadata_mood_array(element : Type) -> Type {
  {
    oid: 90001U,
    name: "_status",
    schema: element.schema,
    kind: Array(element),
  }
}

///|
test "scalar enum codec supports custom arrays empty arrays and NULL elements" {
  let type_ = metadata_mood_array(metadata_mood_type())
  let cases : Array[Array[MetadataMood?]] = [
    [],
    [Some(Ready), None, Some(Done)],
    [None],
  ]
  for values in cases {
    let encoded = encode_param(values, type_)
    assert_eq(encoded.format, Binary)
    let bytes = encoded.value.unwrap()
    let pg_array = @types.array_from_sql(bytes[:])
    assert_eq(pg_array.element_type, metadata_mood_type().oid)
    assert_eq(pg_array.elements, values.length())
    let decoded : Array[MetadataMood?] = make_row(type_, bytes, format=Binary).get(
      0,
    )
    assert_eq(decoded, values)
  }
  let plain = [MetadataMood::Ready, Done]
  let bytes = encode_param(plain, type_).value.unwrap()
  let decoded : Array[MetadataMood] = make_row(type_, bytes, format=Binary).get(
    0,
  )
  assert_eq(decoded, plain)
}

///|
test "schema checked scalar and array codecs reject matching names in other schemas" {
  let a = metadata_mood_type()
  let b : Type = { ..a, oid: 90002U, schema: Some("b"), }
  assert_encode_wrong_type(MetadataMood::Ready, b)
  assert_encode_wrong_type([MetadataMood::Ready], metadata_mood_array(b))
  assert_encode_wrong_type([1], metadata_mood_array(a))
  assert_true(
    @test.expect_error(() => {
      let _ : MetadataMood = make_row(b, b"ready", format=Binary).get(0)
    })
    is ClientError::WrongType(_),
  )
  let bytes = encode_param([MetadataMood::Ready], metadata_mood_array(a)).value.unwrap()
  assert_true(
    @test.expect_error(() => {
      let _ : Array[MetadataMood] = make_row(
        metadata_mood_array(b),
        bytes,
        format=Binary,
      ).get(0)
    })
    is ClientError::WrongType(_),
  )
}

///|
test "custom array decoder checks binary element OID and rejects nonnullable NULL" {
  let type_ = metadata_mood_array(metadata_mood_type())
  let nullable : Array[MetadataMood?] = [None]
  let bytes = encode_param(nullable, type_).value.unwrap()
  assert_true(
    @test.expect_error(() => {
      let _ : Array[MetadataMood] = make_row(type_, bytes, format=Binary).get(0)
    })
    is ClientError::Decode(_),
  )
  let wrong = encode_param([1], Type::int4_array()).value.unwrap()
  assert_true(
    @test.expect_error(() => {
      let _ : Array[MetadataMood] = make_row(type_, wrong, format=Binary).get(0)
    })
    is ClientError::Decode("array element OID does not match type descriptor"),
  )
}
