///|
fn bench_row_description_body() -> @backend.RowDescriptionBody raise {
  make_row_description_body([
    {
      name: b"id",
      table_oid: 1U,
      column_id: 1,
      type_oid: 23U,
      type_size: 4,
      type_modifier: -1,
      format: 0,
    },
    {
      name: b"name",
      table_oid: 1U,
      column_id: 2,
      type_oid: 25U,
      type_size: -1,
      type_modifier: -1,
      format: 0,
    },
    {
      name: b"payload",
      table_oid: 1U,
      column_id: 3,
      type_oid: 17U,
      type_size: -1,
      type_modifier: -1,
      format: 1,
    },
  ])
}

///|
fn bench_data_row_body() -> @backend.DataRowBody raise {
  make_data_row_body([
    Some(@proto.utf8_encode("42")),
    Some(@proto.utf8_encode("moonbit-postgres")),
    None,
  ])
}

///|
fn bench_parse_columns(body : @backend.RowDescriptionBody) -> Array[Column] {
  parse_columns(body) catch {
    _ => abort("expected benchmark row description to parse")
  }
}

///|
fn bench_parse_column_names(
  body : @backend.RowDescriptionBody,
) -> Array[String] {
  parse_column_names(body) catch {
    _ => abort("expected benchmark row description names to parse")
  }
}

///|
fn bench_parse_text_row(
  body : @backend.DataRowBody,
  columns : Array[String],
) -> SimpleQueryRow {
  parse_text_row(body, columns) catch {
    _ => abort("expected benchmark text row to parse")
  }
}

///|
test "bench client parse columns from row description" (it : @bench.T) {
  let body = bench_row_description_body()
  it.bench(() => {
    let columns = bench_parse_columns(body)
    it.keep(columns)
  })
}

///|
test "bench client parse row description names" (it : @bench.T) {
  let body = bench_row_description_body()
  it.bench(() => {
    let names = bench_parse_column_names(body)
    it.keep(names)
  })
}

///|
test "bench client parse text row payload" (it : @bench.T) {
  let body = bench_data_row_body()
  let columns = ["id", "name", "payload"]
  it.bench(() => {
    let row = bench_parse_text_row(body, columns)
    it.keep(row)
  })
}
