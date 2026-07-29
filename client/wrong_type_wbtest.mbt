///|
struct OnlyInt8Value {
  value : Int64
} derive(Debug, Eq)

///|
impl FromSql for OnlyInt8Value with fn accepts(type_) {
  type_.oid == INT8_OID
}

///|
impl FromSql for OnlyInt8Value with fn moonbit_type_name() {
  "OnlyInt8Value"
}

///|
impl FromSql for OnlyInt8Value with fn from_sql(_, _, _) {
  { value: 0L }
}

///|
fn make_text_row(type_ : Type, value : String) -> Row {
  let columns : Array[Column] = [
    {
      name: "value",
      table_oid: 0U,
      column_id: 0,
      type_,
      type_size: -1,
      type_modifier: -1,
      format: Text,
    },
  ]
  let values : Array[Bytes?] = [Some(@proto.utf8_encode(value))]
  { columns, values }
}

///|
test "row get reports wrong type before custom decoder" {
  let row = make_text_row(Type::int4(), "1")
  let result = @test.expect_error(() => {
    let _ : OnlyInt8Value = row.get(0)
  })
  guard result is ClientError::WrongType(err) else {
    fail("expected wrong type error")
  }
  @debug.assert_eq(err.moonbit_type, "OnlyInt8Value")
  @debug.assert_eq(err.postgres_type, Type::int4())
}
