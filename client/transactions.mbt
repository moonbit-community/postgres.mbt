// Transaction and savepoint helpers layered on top of the client API.

///|
/// Options for the `BEGIN` command used when opening a transaction.
pub struct TransactionOptions {
  /// Optional SQL fragment after `ISOLATION LEVEL`, such as `"SERIALIZABLE"`.
  isolation_level : String?
  /// `Some(true)` emits `READ ONLY`; `Some(false)` emits `READ WRITE`.
  read_only : Bool?
  /// `Some(true)` emits `DEFERRABLE`; `Some(false)` emits `NOT DEFERRABLE`.
  deferrable : Bool?
} derive(Eq, Debug)

///|
/// Build transaction options for a future `BEGIN` command.
pub fn TransactionOptions::new(
  isolation_level? : String,
  read_only? : Bool,
  deferrable? : Bool,
) -> TransactionOptions {
  { isolation_level, read_only, deferrable }
}

///|
/// Begin a transaction with PostgreSQL's default `BEGIN` settings or the given
/// `BEGIN` options.
pub async fn Client::transaction(
  self : Client,
  options? : TransactionOptions = TransactionOptions::new(),
) -> Transaction {
  let clauses : Array[String] = []
  match options.isolation_level {
    Some(level) => clauses.push("ISOLATION LEVEL \{level}")
    None => ()
  }
  match options.read_only {
    Some(true) => clauses.push("READ ONLY")
    Some(false) => clauses.push("READ WRITE")
    None => ()
  }
  match options.deferrable {
    Some(true) => clauses.push("DEFERRABLE")
    Some(false) => clauses.push("NOT DEFERRABLE")
    None => ()
  }
  let sql = if clauses.is_empty() {
    "BEGIN"
  } else {
    "BEGIN " + join_clauses(clauses)
  }
  self.batch_execute(sql)
  { client: self, savepoint: None, finished: @ref.new(false) }
}

///|
/// Run one callback inside a transaction and auto-complete it.
///
/// On normal return, the transaction is committed if the callback did not
/// already finish it explicitly. If the callback raises, the transaction is
/// rolled back best-effort unless it was already finished.
pub async fn[T] Client::with_transaction(
  self : Client,
  f : async (Transaction) -> T,
  options? : TransactionOptions = TransactionOptions::new(),
) -> T {
  let transaction = self.transaction(options~)
  try {
    let result = f(transaction)
    if !transaction.finished.val {
      transaction.commit()
    }
    result
  } catch {
    err => {
      if !transaction.finished.val {
        let _ = transaction.rollback() catch { _ => () }
      }
      raise err
    }
  }
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
  self.prepare_typed(sql, [])
}

///|
/// Prepare a statement with explicit parameter types while the transaction is open.
pub async fn Transaction::prepare_typed(
  self : Transaction,
  sql : String,
  types : Array[Type],
) -> Statement {
  self.assert_open()
  self.client.prepare_typed(sql, types)
}

///|
/// Create a named savepoint while the transaction is open.
pub async fn Transaction::savepoint(
  self : Transaction,
  name : String,
) -> Transaction {
  self.assert_open()
  self.client.batch_execute("SAVEPOINT \{name}")
  { client: self.client, savepoint: Some(name), finished: @ref.new(false) }
}

///|
/// Execute a previously prepared statement within this transaction scope.
pub fn Transaction::query_statement(
  self : Transaction,
  statement : Statement,
  params? : Array[&ToSql] = [],
) -> RowStream raise {
  self.assert_open()
  self.client.query_statement(statement, params~)
}

///|
/// Execute a previously prepared statement and return its affected row count.
pub async fn Transaction::execute_raw(
  self : Transaction,
  statement : Statement,
  params? : Array[&ToSql] = [],
) -> Int {
  self.assert_open()
  self.client.execute_raw(statement, params~)
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
