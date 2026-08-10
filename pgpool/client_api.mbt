// High-level pooled-client query helpers.

///|
/// Run one query on this lease and collect all rows before returning.
///
/// Side effects: fully drains the query result, so no stream state escapes the
/// call boundary.
pub async fn Session::query_all(
  self : Session,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> Array[@client.Row] {
  self.with_prepared(sql, prepared => prepared.query_all(params~))
}

///|
/// Run one query and require exactly one row.
///
/// Row-count behavior follows the underlying `@client.Client::query_one`.
pub async fn Session::query_one(
  self : Session,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> @client.Row {
  self.with_prepared(sql, prepared => prepared.query_one(params~))
}

///|
/// Run one query and allow zero or one rows.
///
/// Row-count behavior follows the underlying `@client.Client::query_opt`.
pub async fn Session::query_opt(
  self : Session,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> @client.Row? {
  self.with_prepared(sql, prepared => prepared.query_opt(params~))
}

///|
/// Run one typed query and collect all rows before returning.
pub async fn Session::query_typed_all(
  self : Session,
  sql : String,
  param_types : Array[@client.Type],
  params? : Array[&@client.ToSql] = [],
) -> Array[@client.Row] {
  self.with_prepared_typed(sql, param_types, prepared => {
    prepared.query_all(params~)
  })
}

///|
/// Execute one command on this lease and return its affected row count.
pub async fn Session::execute(
  self : Session,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> Int {
  self.with_prepared(sql, prepared => prepared.execute(params~))
}

///|
/// Execute one or more SQL commands without returning row data.
///
/// Side effects follow PostgreSQL `batch_execute`: every command in `sql` runs
/// on the current session in order.
pub async fn Session::batch_execute(self : Session, sql : String) -> Unit {
  self.run_operation(client => client.batch_execute(sql))
}

///|
/// Perform a lightweight connection health check on this lease.
pub async fn Session::check_connection(self : Session) -> Unit {
  self.run_operation(client => client.check_connection())
}
