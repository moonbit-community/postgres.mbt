///|
fn dummy_task_group() -> @async.TaskGroup[Unit] {
  let store : UninitializedArray[@async.TaskGroup[Unit]] = UninitializedArray::make(
    1,
  )
  store[0]
}

///|
fn dummy_statement() -> @client.Statement {
  // These lookup benchmarks never touch the raw statement handle.
  let store : UninitializedArray[@client.Statement] = UninitializedArray::make(
    1,
  )
  store[0]
}

///|
fn benchmark_cache_entry(
  sql : String,
  param_types? : Array[@client.Type] = [],
) -> CachedStatementEntry {
  {
    sql,
    param_types,
    statement: dummy_statement(),
    in_use: @ref.new(1),
    evicted: @ref.new(false),
  }
}

///|
fn benchmark_connection_state(size : Int) -> ConnectionState {
  let entries : Array[CachedStatementEntry] = []
  for i in 0..<size {
    entries.push(
      benchmark_cache_entry("select $1::int4 as value -- \{i}", param_types=[
        @client.Type::int4(),
      ]),
    )
  }
  {
    id: 1,
    group: dummy_task_group(),
    client: @ref.new(None),
    statement_cache: entries,
  }
}

///|
fn expect_taken_entry(entry : CachedStatementEntry?) -> CachedStatementEntry {
  match entry {
    Some(entry) => entry
    None => abort("expected cached statement entry")
  }
}

///|
test "bench pgpool cache match hit" (it : @bench.T) {
  let entry = benchmark_cache_entry("select $1::int4 as value", param_types=[
    @client.Type::int4(),
  ])
  let param_types = [@client.Type::int4()]
  it.bench(() => {
    let matched = cached_statement_matches(
      entry, "select $1::int4 as value", param_types,
    )
    it.keep(matched)
  })
}

///|
test "bench pgpool cache find hit in 32 entries" (it : @bench.T) {
  let connection = benchmark_connection_state(32)
  let sql = "select $1::int4 as value -- 31"
  let param_types = [@client.Type::int4()]
  it.bench(() => {
    let entry = find_cached_statement_entry(connection, sql, param_types)
    it.keep(entry is Some(_))
  })
}

///|
test "bench pgpool cache miss in 32 entries" (it : @bench.T) {
  let connection = benchmark_connection_state(32)
  let param_types = [@client.Type::int4()]
  it.bench(() => {
    let entry = find_cached_statement_entry(
      connection, "select $1::int4 as value -- missing", param_types,
    )
    it.keep(entry is Some(_))
  })
}

///|
test "bench pgpool cache take and restore" (it : @bench.T) {
  let connection = benchmark_connection_state(32)
  let sql = "select $1::int4 as value -- 16"
  let param_types = [@client.Type::int4()]
  it.bench(() => {
    let entry = expect_taken_entry(
      take_cached_statement_entry(connection, sql, param_types),
    )
    connection.statement_cache.push(entry)
    it.keep(connection.statement_cache.length())
  })
}
