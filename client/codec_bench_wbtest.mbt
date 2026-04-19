///|
fn bench_multi_column_row() -> Row {
  let columns : Array[Column] = [
    {
      name: "id",
      table_oid: 0U,
      column_id: 0,
      type_: Type::int4(),
      type_size: 4,
      type_modifier: -1,
      format: WireFormat::Text,
    },
    {
      name: "name",
      table_oid: 0U,
      column_id: 0,
      type_: Type::text(),
      type_size: -1,
      type_modifier: -1,
      format: WireFormat::Text,
    },
    {
      name: "flag",
      table_oid: 0U,
      column_id: 0,
      type_: Type::bool(),
      type_size: 1,
      type_modifier: -1,
      format: WireFormat::Text,
    },
  ]
  let values : Array[Bytes?] = [Some(b"42"), Some(b"moonbit"), Some(b"true")]
  { columns, values }
}

///|
fn bench_get_int(row : Row) -> Int {
  row.get(0) catch {
    _ => abort("expected benchmark int row to decode")
  }
}

///|
fn bench_get_text_name(row : Row, name : String) -> String {
  row.get_name(name) catch {
    _ => abort("expected benchmark text row to decode")
  }
}

///|
fn bench_get_int_name(row : Row, name : String) -> Int {
  row.get_name(name) catch {
    _ => abort("expected benchmark int row to decode")
  }
}

///|
fn bench_get_bool_name(row : Row, name : String) -> Bool {
  row.get_name(name) catch {
    _ => abort("expected benchmark bool row to decode")
  }
}

///|
test "bench client decode int4 by index" (it : @bench.T) {
  let row = make_row(Type::int4(), b"42")
  it.bench(() => {
    let value = bench_get_int(row)
    it.keep(value)
  })
}

///|
test "bench client decode text by name" (it : @bench.T) {
  let row = make_row(Type::text(), b"moonbit-postgres")
  it.bench(() => {
    let value = bench_get_text_name(row, "value")
    it.keep(value)
  })
}

///|
test "bench client decode multi-column named lookup" (it : @bench.T) {
  let row = bench_multi_column_row()
  it.bench(() => {
    let id = bench_get_int_name(row, "id")
    let name = bench_get_text_name(row, "name")
    let flag = bench_get_bool_name(row, "flag")
    it.keep((id, name, flag))
  })
}
