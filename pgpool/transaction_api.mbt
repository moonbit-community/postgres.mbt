// Pooled transaction and transaction-builder APIs.

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
/// Create a transaction builder bound to this checked-out client lease.
///
/// This has no side effects yet; the SQL `BEGIN` is sent only when `start()` or
/// `run()` is called on the builder.
pub fn Client::build_transaction(self : Client) -> TransactionBuilder {
  make_transaction_builder(self)
}

///|
/// Start one transaction using PostgreSQL's default `BEGIN` settings.
///
/// Preconditions: no exclusive scope may already be active on this lease. The
/// returned `Transaction` keeps the connection checked out until it is
/// committed or rolled back.
pub async fn Client::transaction(self : Client) -> Transaction {
  self.build_transaction().start()
}

///|
/// Set the isolation level clause for the future transaction.
///
/// This only changes the builder value. No SQL is sent until the transaction is
/// started.
pub fn TransactionBuilder::isolation_level(
  self : TransactionBuilder,
  level : IsolationLevel,
) -> TransactionBuilder {
  { ..self, isolation_level: Some(level) }
}

///|
/// Set whether the future transaction should be `READ ONLY`.
///
/// This records the option on the builder; it has no side effects until start.
pub fn TransactionBuilder::read_only(
  self : TransactionBuilder,
  enabled? : Bool = true,
) -> TransactionBuilder {
  { ..self, read_only: Some(enabled) }
}

///|
/// Set whether the future transaction should be `DEFERRABLE`.
///
/// PostgreSQL applies this only where that clause is valid for the final `BEGIN`
/// command.
pub fn TransactionBuilder::deferrable(
  self : TransactionBuilder,
  enabled? : Bool = true,
) -> TransactionBuilder {
  { ..self, deferrable: Some(enabled) }
}

///|
/// Start the configured transaction and keep the client lease checked out.
///
/// Preconditions: the client lease must still be active and no other exclusive
/// scope may already be open on it. Side effects: sends `BEGIN` with the
/// configured clauses and returns a `Transaction` handle that must later be
/// committed or rolled back. If startup fails, the outer client scope is
/// released before the error is re-raised.
pub async fn TransactionBuilder::start(
  self : TransactionBuilder,
) -> Transaction {
  let (client, connection) = self.client.state.begin_transaction_scope()
  try {
    let mut builder = client.build_transaction()
    match self.isolation_level {
      Some(level) =>
        builder = builder.isolation_level(isolation_level_sql(level))
      None => ()
    }
    match self.read_only {
      Some(enabled) => builder = builder.read_only(enabled~)
      None => ()
    }
    match self.deferrable {
      Some(enabled) => builder = builder.deferrable(enabled~)
      None => ()
    }
    let transaction = builder.start()
    make_pooled_transaction(
      connection,
      transaction,
      ClientLease(self.client.state),
    )
  } catch {
    err => {
      self.client.state.finish_transaction_scope()
      raise err
    }
  }
}

///|
/// Run one callback inside a configured transaction and auto-complete it.
///
/// On normal return, the transaction is committed if the callback did not
/// already finish it explicitly. If the callback raises, the transaction is
/// rolled back best-effort unless it was already finished.
pub async fn[T] TransactionBuilder::run(
  self : TransactionBuilder,
  f : async (Transaction) -> T,
) -> T {
  let transaction = self.start()
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
fn TransactionState::begin_operation(
  self : TransactionState,
) -> @client.Transaction raise {
  if self.closing.val || self.finished.val {
    raise PoolError::LeaseReleased
  }
  if self.scope_active.val {
    raise PoolError::OperationInProgress
  }
  match self.transaction.val {
    Some(transaction) => {
      self.active_ops.val += 1
      transaction
    }
    None => raise PoolError::LeaseReleased
  }
}

///|
/// Finish one transaction operation.
fn TransactionState::finish_operation(self : TransactionState) -> Unit {
  if self.active_ops.val > 0 {
    self.active_ops.val -= 1
  }
}

///|
/// Start one nested transaction or savepoint scope on this transaction.
fn TransactionState::begin_nested_scope(
  self : TransactionState,
) -> (@client.Transaction, ConnectionState) raise {
  if self.closing.val || self.finished.val {
    raise PoolError::LeaseReleased
  }
  if self.scope_active.val || self.active_ops.val > 0 {
    raise PoolError::OperationInProgress
  }
  match self.transaction.val {
    Some(transaction) => {
      self.scope_active.val = true
      self.active_ops.val += 1
      (transaction, self.connection)
    }
    None => raise PoolError::LeaseReleased
  }
}

///|
/// Finish one nested transaction or savepoint scope on this transaction.
fn TransactionState::finish_nested_scope(self : TransactionState) -> Unit {
  self.scope_active.val = false
  self.finish_operation()
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
    raise PoolError::LeaseReleased
  }
  if self.state.scope_active.val {
    raise PoolError::OperationInProgress
  }
  self.state.closing.val = true
  while self.state.active_ops.val > 0 {
    @async.pause()
  }
  self.state.finished.val = true
  match self.state.transaction.val {
    Some(transaction) => {
      self.state.transaction.val = None
      transaction
    }
    None => raise PoolError::LeaseReleased
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
/// Run one callback inside a transaction and auto-complete it.
///
/// This is a convenience wrapper for `build_transaction().run(...)`.
pub async fn[T] Client::with_transaction(
  self : Client,
  f : async (Transaction) -> T,
) -> T {
  self.build_transaction().run(f)
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
pub async fn Transaction::transaction(self : Transaction) -> Transaction {
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
pub async fn Transaction::savepoint(
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
  self.run_operation(txn => txn.query(sql, params~).collect())
}

///|
/// Run one query inside this transaction and require exactly one row.
///
/// Edge behavior: this helper materializes all rows first and raises
/// `PoolError::RowCount` when PostgreSQL returned anything other than exactly
/// one row.
pub async fn Transaction::query_one(
  self : Transaction,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> @client.Row {
  let rows = self.query_all(sql, params~)
  guard rows.length() == 1 else {
    raise PoolError::RowCount(
      "expected exactly one row, got \{rows.length().to_string()}",
    )
  }
  rows[0]
}

///|
/// Run one query inside this transaction and allow zero or one rows.
///
/// Edge behavior: raises `PoolError::RowCount` when more than one row is
/// returned.
pub async fn Transaction::query_opt(
  self : Transaction,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> @client.Row? {
  let rows = self.query_all(sql, params~)
  guard rows.length() <= 1 else {
    raise PoolError::RowCount(
      "expected zero or one row, got \{rows.length().to_string()}",
    )
  }
  if rows.length() == 0 {
    None
  } else {
    Some(rows[0])
  }
}

///|
/// Run one typed query inside the transaction and collect all rows.
///
/// Side effects: prepares a temporary typed statement for this call and closes
/// it before returning.
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
  self.run_operation(txn => txn.execute(sql, params~))
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
