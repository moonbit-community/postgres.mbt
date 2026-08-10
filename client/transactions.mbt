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
  let (context, permit) = self.begin_stream_operation()
  let started = @ref.new(false)
  @async.protect_from_cancel(
    () => {
      let transaction = context.begin_transaction(options, permit)
      started.val = true
      transaction
    },
    resume_on_cancel=true,
  ) catch {
    err => {
      if started.val && !self.shared.closed.val {
        let _ = @async.protect_from_cancel(
          () => context.batch_execute("ROLLBACK"),
          resume_on_cancel=false,
        ) catch {
          _ => ()
        }
      }
      permit.release()
      raise err
    }
  }
}

///|
async fn OpContext::begin_transaction(
  self : OpContext,
  options : TransactionOptions,
  permit : OperationPermit,
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
  {
    client: self.client,
    context: self,
    scope_gate: OperationGate::new(),
    root_permit: Some(permit),
    parent_permit: None,
    savepoint: None,
    finished: @ref.new(false),
  }
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
  let name = "moon_tx_\{next_id(self.client.shared).to_string()}"
  self.begin_savepoint(name)
}

///|
/// Execute a query within this transaction scope.
pub async fn Transaction::query(
  self : Transaction,
  sql : String,
  params? : Array[&ToSql] = [],
) -> RowStream {
  let permit = self.begin_scope_stream()
  let completed : @ref.Ref[RowStream?] = @ref.new(None)
  @async.protect_from_cancel(
    () => {
      let stream = self.context.query(sql, params, permit~)
      completed.val = Some(stream)
      stream
    },
    resume_on_cancel=true,
  ) catch {
    err => {
      match completed.val {
        Some(stream) => stream.detach()
        None => permit.release()
      }
      raise err
    }
  }
}

///|
/// Execute SQL within this transaction and return the affected row count.
pub async fn Transaction::execute(
  self : Transaction,
  sql : String,
  params? : Array[&ToSql] = [],
) -> Int {
  self.run_scope_operation(context => context.execute(sql, params))
}

///|
/// Execute one or more SQL commands within this transaction.
pub async fn Transaction::batch_execute(
  self : Transaction,
  sql : String,
) -> Unit {
  self.run_scope_operation(context => context.batch_execute(sql))
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
  self.run_scope_operation(context => context.prepare_typed(sql, types))
}

///|
/// Close a prepared statement without leaving this transaction's operation
/// scope.
///
/// Calling `Statement::close` directly while the transaction is open would
/// wait for the transaction's outer client permit. This scoped variant uses the
/// transaction capability that already owns that permit.
pub async fn Transaction::close_statement(
  self : Transaction,
  statement : Statement,
) -> Unit {
  self.run_scope_operation(context => context.close_statement(statement))
}

///|
/// Close a portal without leaving this transaction's operation scope.
pub async fn Transaction::close_portal(
  self : Transaction,
  portal : Portal,
) -> Unit {
  self.run_scope_operation(context => context.close_portal(portal))
}

///|
/// Create a named savepoint while the transaction is open.
pub async fn Transaction::savepoint(
  self : Transaction,
  name : String,
) -> Transaction {
  self.begin_savepoint(name)
}

///|
async fn Transaction::begin_savepoint(
  self : Transaction,
  name : String,
) -> Transaction {
  let parent_permit = self.begin_scope_stream()
  let created = @ref.new(false)
  @async.protect_from_cancel(
    () => {
      self.context.batch_execute("SAVEPOINT \{name}")
      created.val = true
      {
        client: self.client,
        context: self.context,
        scope_gate: OperationGate::new(),
        root_permit: None,
        parent_permit: Some(parent_permit),
        savepoint: Some(name),
        finished: @ref.new(false),
      }
    },
    resume_on_cancel=true,
  ) catch {
    err => {
      if created.val && !self.client.shared.closed.val {
        let _ = @async.protect_from_cancel(
          () => {
            self.context.batch_execute(
              "ROLLBACK TO SAVEPOINT \{name}; RELEASE SAVEPOINT \{name}",
            )
          },
          resume_on_cancel=false,
        ) catch {
          _ => ()
        }
      }
      parent_permit.release()
      raise err
    }
  }
}

///|
/// Execute a previously prepared statement within this transaction scope.
pub async fn Transaction::query_statement(
  self : Transaction,
  statement : Statement,
  params? : Array[&ToSql] = [],
) -> RowStream {
  let permit = self.begin_scope_stream()
  self.context.query_statement(statement, params, permit~) catch {
    err => {
      permit.release()
      raise err
    }
  }
}

///|
/// Execute a previously prepared statement and return its affected row count.
pub async fn Transaction::execute_raw(
  self : Transaction,
  statement : Statement,
  params? : Array[&ToSql] = [],
) -> Int {
  self.run_scope_operation(context => context.execute_raw(statement, params))
}

///|
/// Bind parameters to a statement while the transaction is open.
pub async fn Transaction::bind(
  self : Transaction,
  statement : Statement,
  params? : Array[&ToSql] = [],
) -> Portal {
  self.run_scope_operation(context => context.bind(statement, params))
}

///|
/// Execute a portal while the transaction is open.
pub async fn Transaction::query_portal(
  self : Transaction,
  portal : Portal,
  max_rows : Int,
) -> RowStream {
  let permit = self.begin_scope_stream()
  self.context.query_portal(portal, max_rows, permit~) catch {
    err => {
      permit.release()
      raise err
    }
  }
}

///|
/// Commit this transaction or release its savepoint.
pub async fn Transaction::commit(self : Transaction) -> Unit {
  self.finish("commit")
}

///|
/// Roll back this transaction or roll back to its savepoint.
pub async fn Transaction::rollback(self : Transaction) -> Unit {
  self.finish("rollback")
}

///|
async fn[T] Transaction::run_scope_operation(
  self : Transaction,
  f : async (OpContext) -> T,
) -> T {
  let permit = self.scope_gate.acquire()
  defer permit.release()
  self.assert_open()
  @async.protect_from_cancel(() => f(self.context), resume_on_cancel=true) catch {
    err => {
      self.invalidate_if_connection_closed()
      raise err
    }
  }
}

///|
async fn Transaction::begin_scope_stream(self : Transaction) -> OperationPermit {
  let permit = self.scope_gate.acquire()
  try {
    self.assert_open()
    permit
  } catch {
    err => {
      permit.release()
      raise err
    }
  }
}

///|
async fn Transaction::finish(self : Transaction, action : String) -> Unit {
  let permit = self.scope_gate.acquire()
  defer permit.release()
  self.assert_open()
  @async.protect_from_cancel(
    () => {
      match (action, self.savepoint) {
        ("commit", None) => self.context.batch_execute("COMMIT")
        ("commit", Some(name)) =>
          self.context.batch_execute("RELEASE SAVEPOINT \{name}")
        ("rollback", None) => self.context.batch_execute("ROLLBACK")
        ("rollback", Some(name)) =>
          self.context.batch_execute(
            "ROLLBACK TO SAVEPOINT \{name}; RELEASE SAVEPOINT \{name}",
          )
        _ => abort("invalid transaction action")
      }
      self.finished.val = true
      self.release_owner_permit()
    },
    resume_on_cancel=true,
  ) catch {
    err => {
      // COMMIT/ROLLBACK and savepoint completion responses have already
      // drained through ReadyForQuery before `batch_execute` raises. The
      // finishing handle cannot be reused after any such failure: a failed
      // top-level COMMIT has ended the transaction, while a failed nested
      // completion must return control to its parent so it can roll back.
      if !self.finished.val {
        self.finished.val = true
        self.release_owner_permit()
      }
      raise err
    }
  }
}

///|
fn Transaction::invalidate_if_connection_closed(self : Transaction) -> Unit {
  if self.client.shared.closed.val && !self.finished.val {
    self.finished.val = true
    self.release_owner_permit()
  }
}

///|
fn Transaction::release_owner_permit(self : Transaction) -> Unit {
  match self.parent_permit {
    Some(parent_permit) => parent_permit.release()
    None =>
      match self.root_permit {
        Some(root_permit) => root_permit.release()
        None => ()
      }
  }
}
