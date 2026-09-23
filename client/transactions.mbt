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
pub fn TransactionOptions::TransactionOptions(
  isolation_level? : String,
  read_only? : Bool,
  deferrable? : Bool,
) -> TransactionOptions {
  { isolation_level, read_only, deferrable, }
}

///|
/// Begin a transaction with PostgreSQL's default `BEGIN` settings or the given
/// `BEGIN` options.
pub async fn Client::transaction(
  self : Client,
  options? : TransactionOptions = TransactionOptions(),
) -> Transaction {
  let (context, permit) = self.begin_stream_operation()
  let started = @ref.new(false)
  errdefer {
    defer permit.release()
    if started.val && !self.shared.closed.val {
      let _ = @async.protect_from_cancel(() => context.batch_execute("ROLLBACK")) catch {
        _ => ()
      }
    }
  }
  let transaction = @async.protect_from_cancel(() => {
    let transaction = context.begin_transaction(options, permit)
    started.val = true
    transaction
  })
  check_pending_cancellation()
  transaction
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
    child: @ref.new(None),
    closing: @ref.new(None),
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
/// already finish it explicitly. Unfinished row streams are discarded and
/// drained before completion. An unfinished nested transaction is rolled back
/// and raises `UnfinishedChildTransaction`. If the callback raises or is
/// cancelled, the transaction is rolled back best-effort instead.
pub async fn[T] Client::with_transaction(
  self : Client,
  f : async (Transaction) -> T,
  options? : TransactionOptions = TransactionOptions(),
) -> T {
  let transaction = self.transaction(options~)
  errdefer @async.protect_from_cancel(() => {
    if !transaction.finished.val {
      let _ = transaction.rollback() catch { _ => () }
    }
  })
  let result = f(transaction)
  check_pending_cancellation()
  if !transaction.finished.val {
    transaction.commit()
  }
  result
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
/// Run a callback inside a savepoint-backed child transaction. The callback
/// stays cancellable. An open child is committed on success and rolled back
/// on error or cancellation; its own unfinished children follow the same rules.
pub async fn[T] Transaction::with_transaction(
  self : Transaction,
  f : async (Transaction) -> T,
) -> T {
  let child = self.transaction()
  errdefer @async.protect_from_cancel(() => {
    if !child.finished.val {
      let _ = child.rollback() catch { _ => () }
    }
  })
  let result = f(child)
  check_pending_cancellation()
  if !child.finished.val {
    child.commit()
  }
  result
}

///|
/// Like `with_transaction`, using a named PostgreSQL savepoint.
pub async fn[T] Transaction::with_savepoint(
  self : Transaction,
  name : String,
  f : async (Transaction) -> T,
) -> T {
  let child = self.savepoint(name)
  errdefer @async.protect_from_cancel(() => {
    if !child.finished.val {
      let _ = child.rollback() catch { _ => () }
    }
  })
  let result = f(child)
  check_pending_cancellation()
  if !child.finished.val {
    child.commit()
  }
  result
}

///|
/// Execute a query within this transaction scope. If left unfinished, its
/// remaining rows and temporary statement are cleaned up at transaction end.
pub async fn Transaction::query(
  self : Transaction,
  sql : String,
  params? : Array[&ToSql] = [],
) -> RowStream {
  self.start_stream(permit => self.context.query(sql, params, permit~))
}

///|
/// Execute a query in a cancellable callback. Discard remaining rows and wait
/// for protocol cleanup before returning, including on error or cancellation.
pub async fn[T] Transaction::with_stream(
  self : Transaction,
  sql : String,
  params? : Array[&ToSql] = [],
  f : async (RowStream) -> T,
) -> T {
  with_transaction_stream(() => self.query(sql, params~), f)
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
  let (parent_permit, pending) = self.begin_child_creation()
  let created = @ref.new(false)
  let creation_error : @ref.Ref[Error?] = @ref.new(None)
  errdefer {
    defer {
      self.clear_creating_child(pending, creation_error.val)
      parent_permit.release()
    }
    if created.val && !self.client.shared.closed.val {
      let _ = @async.protect_from_cancel(() => {
        self.context.batch_execute(
          "ROLLBACK TO SAVEPOINT \{name}; RELEASE SAVEPOINT \{name}",
        )
      }) catch {
        error => {
          creation_error.val = Some(error)
          if !(error is ClientError::Database(_)) {
            self.client.abort()
          }
        }
      }
    }
  }
  let made : @ref.Ref[Transaction?] = @ref.new(None)
  let startup_error : Error? = try {
    made.val = Some(
      @async.protect_from_cancel(() => {
        self.context.batch_execute("SAVEPOINT \{name}")
        created.val = true
        {
          client: self.client,
          context: self.context,
          scope_gate: OperationGate::new(),
          child: @ref.new(None),
          closing: @ref.new(None),
          root_permit: None,
          parent_permit: Some(parent_permit),
          savepoint: Some(name),
          finished: @ref.new(false),
        }
      }),
    )
    None
  } catch {
    error => Some(error)
  }
  match startup_error {
    Some(error) => {
      creation_error.val = Some(error)
      if !(error is ClientError::Database(_)) {
        self.client.abort()
      }
      raise error
    }
    None => ()
  }
  let transaction = made.val.unwrap()
  check_pending_cancellation()
  if self.closing.val is Some(_) {
    raise ClientError::Closed("transaction is closing")
  }
  self.child.val = Some(Nested(transaction))
  pending.complete(None)
  transaction
}

///|
/// Execute a previously prepared statement within this transaction scope.
/// An unfinished result is drained at transaction end; the statement remains
/// owned by the caller.
pub async fn Transaction::query_statement(
  self : Transaction,
  statement : Statement,
  params? : Array[&ToSql] = [],
) -> RowStream {
  self.start_stream(permit => {
    self.context.query_statement(statement, params, permit~)
  })
}

///|
/// Scope one prepared statement execution stream. The statement remains owned
/// by the caller and must be closed separately.
pub async fn[T] Transaction::with_statement_stream(
  self : Transaction,
  statement : Statement,
  params? : Array[&ToSql] = [],
  f : async (RowStream) -> T,
) -> T {
  with_transaction_stream(() => self.query_statement(statement, params~), f)
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
/// Execute a portal while the transaction is open. An unfinished result is
/// drained at transaction end; the portal remains owned by the caller.
pub async fn Transaction::query_portal(
  self : Transaction,
  portal : Portal,
  max_rows : Int,
) -> RowStream {
  self.start_stream(permit => {
    self.context.query_portal(portal, max_rows, permit~)
  })
}

///|
/// Scope one portal fetch stream. The portal and its statement remain owned by
/// the caller and must be closed separately.
pub async fn[T] Transaction::with_portal_stream(
  self : Transaction,
  portal : Portal,
  max_rows : Int,
  f : async (RowStream) -> T,
) -> T {
  with_transaction_stream(() => self.query_portal(portal, max_rows), f)
}

///|
async fn[T] with_transaction_stream(
  acquire : async () -> RowStream,
  f : async (RowStream) -> T,
) -> T {
  let stream = acquire()
  errdefer @async.protect_from_cancel(() => {
    stream.detach()
    ignore(stream.finish()) catch {
      _ => ()
    }
  })
  let result = f(stream)
  check_pending_cancellation()
  {
    defer check_pending_cancellation()
    @async.protect_from_cancel(() => {
      stream.detach()
      ignore(stream.finish())
    })
  }
  result
}

///|
/// Finish child streams, then commit this transaction or release its savepoint.
/// An unfinished child transaction is rolled back and raises
/// `UnfinishedChildTransaction` after this transaction is rolled back.
pub async fn Transaction::commit(self : Transaction) -> Unit {
  self.finish("commit")
}

///|
/// Finish child streams and recursively roll back child transactions, then
/// roll back this transaction or to its savepoint.
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
  errdefer self.invalidate_if_connection_closed()
  check_pending_cancellation()
  defer check_pending_cancellation()
  @async.protect_from_cancel(() => f(self.context))
}

///|
async fn Transaction::begin_child_creation(
  self : Transaction,
) -> (OperationPermit, Completion) {
  let permit = self.scope_gate.acquire()
  errdefer permit.release()
  self.assert_open()
  check_pending_cancellation()
  let pending = Completion::new()
  self.child.val = Some(Creating(pending))
  (permit, pending)
}

///|
fn Transaction::clear_creating_child(
  self : Transaction,
  pending : Completion,
  error : Error?,
) -> Unit {
  if self.child.val is Some(Creating(_)) {
    self.child.val = None
  }
  pending.complete(error)
}

///|
async fn Transaction::start_stream(
  self : Transaction,
  build : async (OperationPermit) -> RowStream,
) -> RowStream {
  let (permit, pending) = self.begin_child_creation()
  let completed : @ref.Ref[RowStream?] = @ref.new(None)
  let creation_error : @ref.Ref[Error?] = @ref.new(None)
  errdefer {
    self.clear_creating_child(pending, creation_error.val)
    match completed.val {
      Some(stream) => stream.detach()
      None => permit.release()
    }
  }
  let startup_error : Error? = try {
    completed.val = Some(@async.protect_from_cancel(() => build(permit)))
    None
  } catch {
    error => Some(error)
  }
  match startup_error {
    Some(error) => {
      creation_error.val = Some(error)
      if !(error is ClientError::Database(_)) && !local_child_error(error) {
        self.client.abort()
      }
      raise error
    }
    None => ()
  }
  let stream = completed.val.unwrap()
  self.child.val = Some(Stream(stream))
  pending.complete(None)
  check_pending_cancellation()
  match self.closing.val {
    Some(done) => {
      // The closer owns the registered stream and drains it before this
      // creator reports that the handle could not be delivered.
      @async.protect_from_cancel(() => done.wait())
      raise ClientError::Closed("transaction is closing")
    }
    None => stream
  }
}

///|
async fn Transaction::cleanup_child(self : Transaction) -> Bool {
  match self.child.val {
    None => false
    Some(Creating(pending)) => {
      pending.wait()
      self.cleanup_child()
    }
    Some(Stream(stream)) => {
      defer {
        self.child.val = None
      }
      stream.detach()
      ignore(stream.finish())
      false
    }
    Some(Nested(child)) => {
      defer {
        self.child.val = None
      }
      let unfinished = !child.finished.val
      if unfinished {
        match child.closing.val {
          Some(done) => done.wait()
          None => ()
        }
        if !child.finished.val {
          child.rollback()
        }
      }
      unfinished
    }
  }
}

///|
fn local_child_error(error : Error) -> Bool {
  error is ClientError::Encode(_) ||
  error is ClientError::Decode(_) ||
  error is ClientError::WrongType(_) ||
  error is ClientError::ColumnNotFound(_) ||
  error is ClientError::RowCount(_) ||
  error is ClientError::Closed("statement already closed") ||
  error is ClientError::Closed("portal already closed") ||
  error is ClientError::Closed("transaction is closing")
}

///|
async fn Transaction::finish(self : Transaction, action : String) -> Unit {
  self.assert_open()
  let closing = Completion::new()
  self.closing.val = Some(closing)
  defer {
    if !self.finished.val {
      self.closing.val = None
    }
    closing.complete(None)
  }
  let unfinished_child = @ref.new(false)
  let cleanup_error : @ref.Ref[Error?] = @ref.new(None)
  @async.protect_from_cancel(() => {
    unfinished_child.val = self.cleanup_child() catch {
      error => {
        cleanup_error.val = Some(error)
        false
      }
    }
  })
  match cleanup_error.val {
    Some(ClientError::Database(_)) | None => ()
    Some(error) =>
      if local_child_error(error) {
        // Any protocol work from this rejected child has already completed.
        cleanup_error.val = None
      } else {
        // A protocol or transport failure has no trustworthy ReadyForQuery.
        self.client.abort()
        self.invalidate_if_connection_closed()
        raise error
      }
  }
  let command = if action == "commit" &&
    (unfinished_child.val || cleanup_error.val is Some(_)) {
    "rollback"
  } else {
    action
  }
  // Acquire only after children release their scope permits. Cancellation here
  // leaves a clean transaction open. A child error or unfinished savepoint
  // requires rollback, so protect its final gate acquisition as well.
  let must_rollback = cleanup_error.val is Some(_) || unfinished_child.val
  let permit = if must_rollback {
    @async.protect_from_cancel(() => self.scope_gate.acquire())
  } else {
    self.scope_gate.acquire()
  }
  defer permit.release()
  if self.client.shared.closed.val {
    self.invalidate_if_connection_closed()
    raise ClientError::Closed("connection is closed")
  }
  // Cancellation before sending completion must leave ownership available for
  // rollback. Once COMMIT is sent, finish processing its actual server result.
  if !must_rollback {
    check_pending_cancellation()
  }
  defer check_pending_cancellation()
  let submitted = @ref.new(false)
  errdefer (if submitted.val {
    // Completion drains through ReadyForQuery before reporting SQL errors.
    self.finished.val = true
    self.release_owner_permit()
  })
  @async.protect_from_cancel(() => {
    submitted.val = true
    let command_error : Error? = try {
      match (command, self.savepoint) {
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
      None
    } catch {
      error => Some(error)
    }
    match command_error {
      Some(ClientError::Database(_) as error) => raise error
      Some(error) => {
        self.client.abort()
        raise error
      }
      None => ()
    }
    self.finished.val = true
    self.release_owner_permit()
  })
  match cleanup_error.val {
    Some(error) => raise error
    None => ()
  }
  if action == "commit" && unfinished_child.val {
    raise ClientError::UnfinishedChildTransaction
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
