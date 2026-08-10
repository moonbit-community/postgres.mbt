// Pooled transaction APIs.

///|
/// Convert one pooled isolation level into the SQL clause expected by `BEGIN`.
fn isolation_level_sql(level : IsolationLevel) -> String {
  match level {
    ReadUncommitted => "READ UNCOMMITTED"
    ReadCommitted => "READ COMMITTED"
    RepeatableRead => "REPEATABLE READ"
    Serializable => "SERIALIZABLE"
  }
}

///|
/// Start one transaction using PostgreSQL's default `BEGIN` settings or the
/// given `BEGIN` options.
///
/// The call waits in FIFO order for earlier session work. The returned
/// `Transaction` keeps the connection checked out until commit or rollback.
async fn Session::transaction(
  self : Session,
  options? : TransactionOptions = TransactionOptions::new(),
) -> Transaction {
  let (client, connection) = self.state.begin_transaction_scope()
  try {
    let client_options = @client.TransactionOptions::new(
      isolation_level?=options.isolation_level.map(isolation_level_sql),
      read_only?=options.read_only,
      deferrable?=options.deferrable,
    )
    let transaction = client.transaction(options=client_options)
    make_pooled_transaction(connection, transaction, ClientLease(self.state))
  } catch {
    err => {
      self.state.finish_transaction_scope()
      raise err
    }
  }
}

///|
/// Run one callback inside a transaction and auto-complete it.
///
/// On normal return, the transaction is committed if the callback did not
/// already finish it explicitly. If the callback raises, the transaction is
/// rolled back best-effort unless it was already finished.
pub async fn[T] Session::with_transaction(
  self : Session,
  f : async (Transaction) -> T,
  options? : TransactionOptions = TransactionOptions::new(),
) -> T {
  let transaction = self.transaction(options~)
  try {
    let result = f(transaction)
    if !transaction.state.finished.val {
      transaction.commit_internal()
    }
    result
  } catch {
    err => {
      if !transaction.state.finished.val {
        transaction.rollback_best_effort()
      }
      raise err
    }
  }
}

///|
/// Release the outer scope holding a pooled transaction's connection lease.
fn TransactionOwner::finish_scope(self : TransactionOwner) -> Unit {
  match self {
    ClientLease(state) => state.finish_transaction_scope()
    ParentTransaction(state) => state.finish_nested_scope()
  }
}

///|
/// Start one transaction operation or reject work after completion begins.
async fn TransactionState::begin_operation(
  self : TransactionState,
) -> @client.Transaction {
  if self.finished.val {
    raise PoolError::ScopeExpired
  }
  self.gate.acquire()
  if self.finished.val {
    self.gate.release()
    raise PoolError::ScopeExpired
  }
  match self.transaction.val {
    Some(transaction) => transaction
    None => {
      self.gate.release()
      raise PoolError::ScopeExpired
    }
  }
}

///|
/// Finish one transaction operation.
fn TransactionState::finish_operation(self : TransactionState) -> Unit {
  self.gate.release()
}

///|
/// Start one nested transaction or savepoint scope on this transaction.
async fn TransactionState::begin_nested_scope(
  self : TransactionState,
) -> (@client.Transaction, ConnectionState) {
  if self.finished.val {
    raise PoolError::ScopeExpired
  }
  self.gate.acquire()
  if self.finished.val {
    self.gate.release()
    raise PoolError::ScopeExpired
  }
  match self.transaction.val {
    Some(transaction) => (transaction, self.connection)
    None => {
      self.gate.release()
      raise PoolError::ScopeExpired
    }
  }
}

///|
/// Finish one nested transaction or savepoint scope on this transaction.
fn TransactionState::finish_nested_scope(self : TransactionState) -> Unit {
  self.finish_operation()
}

///|
/// Access the raw transaction while an outer transaction scope owns the gate.
fn TransactionState::scoped_transaction(
  self : TransactionState,
) -> @client.Transaction raise {
  if self.finished.val {
    raise PoolError::ScopeExpired
  }
  match self.transaction.val {
    Some(transaction) => transaction
    None => raise PoolError::ScopeExpired
  }
}

///|
/// Release the outer client or parent transaction once this transaction completes.
fn TransactionState::release_owner_scope(self : TransactionState) -> Unit {
  if self.owner_released.val {
    return
  }
  self.owner_released.val = true
  self.owner.finish_scope()
}

///|
/// Wait for every active operation to finish and take ownership of the transaction.
async fn Transaction::take_for_completion(
  self : Transaction,
) -> @client.Transaction {
  if self.state.finished.val {
    raise PoolError::ScopeExpired
  }
  self.state.gate.acquire()
  if self.state.finished.val {
    self.state.gate.release()
    raise PoolError::ScopeExpired
  }
  self.state.finished.val = true
  match self.state.transaction.val {
    Some(transaction) => {
      self.state.transaction.val = None
      self.state.gate.release()
      transaction
    }
    None => {
      self.state.gate.release()
      raise PoolError::ScopeExpired
    }
  }
}

///|
/// Commit one pooled transaction after all in-flight operations finish.
async fn Transaction::commit_internal(self : Transaction) -> Unit {
  let transaction = self.take_for_completion()
  defer self.state.release_owner_scope()
  @async.protect_from_cancel(() => transaction.commit(), resume_on_cancel=true)
}

///|
/// Roll back one pooled transaction while ignoring rollback failures.
async fn Transaction::rollback_best_effort(self : Transaction) -> Unit {
  try {
    let transaction = self.take_for_completion()
    defer self.state.release_owner_scope()
    @async.protect_from_cancel(
      () => transaction.rollback(),
      resume_on_cancel=true,
    )
  } catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// Run one async operation against the live transaction.
async fn[T] Transaction::run_operation(
  self : Transaction,
  op : async (@client.Transaction) -> T,
) -> T {
  let transaction = self.state.begin_operation()
  defer self.state.finish_operation()
  @async.protect_from_cancel(() => op(transaction), resume_on_cancel=true)
}

///|
/// Commit this pooled transaction explicitly.
///
/// Preconditions: the transaction must not already be finished, and no nested
/// transaction/savepoint scope may still be active. The call waits for any
/// in-flight non-exclusive operation to finish first.
pub async fn Transaction::commit(self : Transaction) -> Unit {
  self.commit_internal()
}

///|
/// Roll back this pooled transaction explicitly.
///
/// Preconditions and completion behavior match `commit()`, except the final SQL
/// action is `ROLLBACK`.
pub async fn Transaction::rollback(self : Transaction) -> Unit {
  let transaction = self.take_for_completion()
  defer self.state.release_owner_scope()
  @async.protect_from_cancel(
    () => transaction.rollback(),
    resume_on_cancel=true,
  )
}

///|
/// Start one nested transaction backed by an unnamed savepoint.
///
/// Preconditions: the parent transaction must still be active and must not
/// already be inside another nested transaction scope. The returned nested
/// transaction must also be committed or rolled back.
async fn Transaction::transaction(self : Transaction) -> Transaction {
  let (transaction, connection) = self.state.begin_nested_scope()
  try {
    let nested = transaction.transaction()
    make_pooled_transaction(connection, nested, ParentTransaction(self.state))
  } catch {
    err => {
      self.state.finish_nested_scope()
      raise err
    }
  }
}

///|
/// Start one nested transaction backed by a named savepoint.
///
/// `name` is passed directly to the underlying client savepoint API.
async fn Transaction::savepoint(
  self : Transaction,
  name : String,
) -> Transaction {
  let (transaction, connection) = self.state.begin_nested_scope()
  try {
    let nested = transaction.savepoint(name)
    make_pooled_transaction(connection, nested, ParentTransaction(self.state))
  } catch {
    err => {
      self.state.finish_nested_scope()
      raise err
    }
  }
}

///|
/// Run one callback inside an unnamed savepoint-backed nested transaction.
///
/// On success the nested transaction is committed if still unfinished; on error
/// it is rolled back best-effort.
pub async fn[T] Transaction::with_transaction(
  self : Transaction,
  f : async (Transaction) -> T,
) -> T {
  let nested = self.transaction()
  try {
    let result = f(nested)
    if !nested.state.finished.val {
      nested.commit_internal()
    }
    result
  } catch {
    err => {
      if !nested.state.finished.val {
        nested.rollback_best_effort()
      }
      raise err
    }
  }
}

///|
/// Run one callback inside a named savepoint-backed nested transaction.
///
/// On success the nested transaction is committed if still unfinished; on error
/// it is rolled back best-effort.
pub async fn[T] Transaction::with_savepoint(
  self : Transaction,
  name : String,
  f : async (Transaction) -> T,
) -> T {
  let nested = self.savepoint(name)
  try {
    let result = f(nested)
    if !nested.state.finished.val {
      nested.commit_internal()
    }
    result
  } catch {
    err => {
      if !nested.state.finished.val {
        nested.rollback_best_effort()
      }
      raise err
    }
  }
}

///|
/// Run one query inside this transaction and collect all rows.
pub async fn Transaction::query_all(
  self : Transaction,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> Array[@client.Row] {
  self.with_prepared(sql, prepared => prepared.query_all(params~))
}

///|
/// Run one query inside this transaction and require exactly one row.
///
/// Edge behavior: this helper materializes all rows first and raises
/// `@client.ClientError::RowCount` when PostgreSQL returned anything other than
/// exactly one row.
pub async fn Transaction::query_one(
  self : Transaction,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> @client.Row {
  self.with_prepared(sql, prepared => prepared.query_one(params~))
}

///|
/// Run one query inside this transaction and allow zero or one rows.
///
/// Edge behavior: raises `@client.ClientError::RowCount` when more than one row is
/// returned.
pub async fn Transaction::query_opt(
  self : Transaction,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> @client.Row? {
  self.with_prepared(sql, prepared => prepared.query_opt(params~))
}

///|
/// Run one typed query inside the transaction and collect all rows.
///
/// The connection-local statement cache is used unless caching is disabled.
pub async fn Transaction::query_typed_all(
  self : Transaction,
  sql : String,
  param_types : Array[@client.Type],
  params? : Array[&@client.ToSql] = [],
) -> Array[@client.Row] {
  self.with_prepared_typed(sql, param_types, prepared => {
    prepared.query_all(params~)
  })
}

///|
/// Execute one command inside this transaction and return its affected row count.
pub async fn Transaction::execute(
  self : Transaction,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> Int {
  self.with_prepared(sql, prepared => prepared.execute(params~))
}

///|
/// Execute one or more SQL commands inside this transaction.
pub async fn Transaction::batch_execute(
  self : Transaction,
  sql : String,
) -> Unit {
  self.run_operation(txn => txn.batch_execute(sql))
}

///|
/// Perform a lightweight health check while the transaction is open.
///
/// Side effects: executes `select 1::int4 as value` inside the current
/// transaction instead of using a transaction-independent probe.
pub async fn Transaction::check_connection(self : Transaction) -> Unit {
  self.run_operation(txn => {
    ignore(txn.query("select 1::int4 as value").finish())
  })
}
