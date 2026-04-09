// Transaction and savepoint helpers layered on top of the client API.

///|
/// Begin a transaction with PostgreSQL's default `BEGIN` settings.
pub async fn Client::transaction(self : Client) -> Transaction {
  self.batch_execute("BEGIN")
  { client: self, savepoint: None, finished: @ref.new(false) }
}

///|
/// Build a transaction with custom `BEGIN` clauses.
///
/// This keeps the common `client.transaction()` path small while still exposing
/// explicit control over isolation level and read-only / deferrable flags.
pub fn Client::build_transaction(self : Client) -> TransactionBuilder {
  { client: self, isolation_level: None, read_only: None, deferrable: None }
}

///|
/// Set the `ISOLATION LEVEL` clause for the future transaction.
pub fn TransactionBuilder::isolation_level(
  self : TransactionBuilder,
  level : String,
) -> TransactionBuilder {
  { ..self, isolation_level: Some(level) }
}

///|
/// Set whether the future transaction should be read only.
pub fn TransactionBuilder::read_only(
  self : TransactionBuilder,
  enabled? : Bool = true,
) -> TransactionBuilder {
  { ..self, read_only: Some(enabled) }
}

///|
/// Set whether the future transaction should be deferrable.
pub fn TransactionBuilder::deferrable(
  self : TransactionBuilder,
  enabled? : Bool = true,
) -> TransactionBuilder {
  { ..self, deferrable: Some(enabled) }
}

///|
/// Issue `BEGIN ...` with the builder's accumulated clauses.
pub async fn TransactionBuilder::start(
  self : TransactionBuilder,
) -> Transaction {
  let clauses : Array[String] = []
  match self.isolation_level {
    Some(level) => clauses.push("ISOLATION LEVEL \{level}")
    None => ()
  }
  match self.read_only {
    Some(true) => clauses.push("READ ONLY")
    Some(false) => clauses.push("READ WRITE")
    None => ()
  }
  match self.deferrable {
    Some(true) => clauses.push("DEFERRABLE")
    Some(false) => clauses.push("NOT DEFERRABLE")
    None => ()
  }
  let sql = if clauses.is_empty() {
    "BEGIN"
  } else {
    "BEGIN " + join_clauses(clauses)
  }
  self.client.batch_execute(sql)
  { client: self.client, savepoint: None, finished: @ref.new(false) }
}

///|
/// Start a nested transaction backed by a PostgreSQL savepoint.
///
/// The returned handle behaves like a transaction, but `commit` releases the
/// savepoint and `rollback` rolls back to it before releasing it.
pub async fn Transaction::transaction(self : Transaction) -> Transaction {
  self.assert_open()
  let name = "moon_tx_\{next_id(self.client.shared).to_string()}"
  self.client.batch_execute("SAVEPOINT \{name}")
  { client: self.client, savepoint: Some(name), finished: @ref.new(false) }
}

///|
/// Execute a query within this transaction scope.
pub async fn Transaction::query(
  self : Transaction,
  sql : String,
  params? : Array[&ToSql] = [],
) -> RowStream {
  self.assert_open()
  self.client.query(sql, params~)
}

///|
/// Execute SQL within this transaction and return the affected row count.
pub async fn Transaction::execute(
  self : Transaction,
  sql : String,
  params? : Array[&ToSql] = [],
) -> Int {
  self.assert_open()
  self.client.execute(sql, params~)
}

///|
/// Execute one or more SQL commands within this transaction.
pub async fn Transaction::batch_execute(
  self : Transaction,
  sql : String,
) -> Unit {
  self.assert_open()
  self.client.batch_execute(sql)
}

///|
/// Prepare a statement while the transaction is open.
pub async fn Transaction::prepare(
  self : Transaction,
  sql : String,
) -> Statement {
  self.assert_open()
  self.client.prepare(sql)
}

///|
/// Bind parameters to a statement while the transaction is open.
pub async fn Transaction::bind(
  self : Transaction,
  statement : Statement,
  params? : Array[&ToSql] = [],
) -> Portal {
  self.assert_open()
  self.client.bind(statement, params~)
}

///|
/// Execute a portal while the transaction is open.
pub fn Transaction::query_portal(
  self : Transaction,
  portal : Portal,
  max_rows : Int,
) -> RowStream raise {
  self.assert_open()
  self.client.query_portal(portal, max_rows)
}

///|
/// Commit this transaction or release its savepoint.
pub async fn Transaction::commit(self : Transaction) -> Unit {
  self.assert_open()
  match self.savepoint {
    None => self.client.batch_execute("COMMIT")
    Some(name) => self.client.batch_execute("RELEASE SAVEPOINT \{name}")
  }
  self.finished.val = true
}

///|
/// Roll back this transaction or roll back to its savepoint.
pub async fn Transaction::rollback(self : Transaction) -> Unit {
  self.assert_open()
  match self.savepoint {
    None => self.client.batch_execute("ROLLBACK")
    Some(name) =>
      self.client.batch_execute(
        "ROLLBACK TO SAVEPOINT \{name}; RELEASE SAVEPOINT \{name}",
      )
  }
  self.finished.val = true
}
