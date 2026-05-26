// High-level pooled-client query helpers.

///|
/// Run one query on this lease and collect all rows before returning.
///
/// Side effects: fully drains the query result, so no stream state escapes the
/// call boundary.
pub async fn Client::query_all(
  self : Client,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> Array[@client.Row] {
  self.run_operation(client => client.query(sql, params~).collect())
}

///|
/// Run one query and require exactly one row.
///
/// Row-count behavior follows the underlying `@client.Client::query_one`.
pub async fn Client::query_one(
  self : Client,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> @client.Row {
  self.run_operation(client => client.query_one(sql, params~))
}

///|
/// Run one query and allow zero or one rows.
///
/// Row-count behavior follows the underlying `@client.Client::query_opt`.
pub async fn Client::query_opt(
  self : Client,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> @client.Row? {
  self.run_operation(client => client.query_opt(sql, params~))
}

///|
/// Run one typed query and collect all rows before returning.
pub async fn Client::query_typed_all(
  self : Client,
  sql : String,
  param_types : Array[@client.Type],
  params? : Array[&@client.ToSql] = [],
) -> Array[@client.Row] {
  self.run_operation(client => {
    client.query_typed(sql, param_types, params~).collect()
  })
}

///|
/// Execute one command on this lease and return its affected row count.
pub async fn Client::execute(
  self : Client,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> Int {
  self.run_operation(client => client.execute(sql, params~))
}

///|
/// Execute one or more SQL commands without returning row data.
///
/// Side effects follow PostgreSQL `batch_execute`: every command in `sql` runs
/// on the current session in order.
pub async fn Client::batch_execute(self : Client, sql : String) -> Unit {
  self.run_operation(client => client.batch_execute(sql))
}

///|
/// Perform a lightweight connection health check on this lease.
pub async fn Client::check_connection(self : Client) -> Unit {
  self.run_operation(client => client.check_connection())
}
