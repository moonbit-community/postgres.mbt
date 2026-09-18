// Direct, automatically checked-out pool operations.

///|
/// Run one query on an automatically managed pooled session and collect all rows.
pub async fn Pool::query_all(
  self : Pool,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> Array[@client.Row] {
  self.with_session(session => session.query_all(sql, params~))
}

///|
/// Run one query on an automatically managed pooled session and require one row.
pub async fn Pool::query_one(
  self : Pool,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> @client.Row {
  self.with_session(session => session.query_one(sql, params~))
}

///|
/// Run one query on an automatically managed pooled session and allow zero or one rows.
pub async fn Pool::query_opt(
  self : Pool,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> @client.Row? {
  self.with_session(session => session.query_opt(sql, params~))
}

///|
/// Run one typed query on an automatically managed pooled session.
pub async fn Pool::query_typed_all(
  self : Pool,
  sql : String,
  param_types : Array[@client.Type],
  params? : Array[&@client.ToSql] = [],
) -> Array[@client.Row] {
  self.with_session(session => {
    session.query_typed_all(sql, param_types, params~)
  })
}

///|
/// Execute one command on an automatically managed pooled session.
pub async fn Pool::execute(
  self : Pool,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> Int {
  self.with_session(session => session.execute(sql, params~))
}

///|
/// Execute one or more commands on an automatically managed pooled session.
pub async fn Pool::batch_execute(self : Pool, sql : String) -> Unit {
  self.with_session(session => session.batch_execute(sql))
}

///|
/// Check one automatically managed pooled connection.
pub async fn Pool::check_connection(self : Pool) -> Unit {
  self.with_session(session => session.check_connection())
}

///|
/// Run a transaction on one automatically managed pooled session.
pub async fn[T] Pool::with_transaction(
  self : Pool,
  f : async (Transaction) -> T,
  options? : TransactionOptions = TransactionOptions::new(),
) -> T {
  self.with_session(session => session.with_transaction(f, options~))
}
