// Callback-owned prepared statements and portals.

///|
priv enum ScopedStatementOwner {
  ClientOwner(Client)
  TransactionOwner(Transaction)
}

///|
priv struct ScopedStatementState {
  owner : ScopedStatementOwner
  statement : Statement
  active : @ref.Ref[Bool]
  active_calls : @ref.Ref[Int]
}

///|
/// A prepared statement usable only during its `with_prepared` callback.
/// Keep operations inside this handle so streams finish before the statement
/// is closed. A saved handle reports `Closed` after its callback ends.
struct ScopedStatement {
  /// Parameter types resolved by PostgreSQL.
  params : Array[Type]
  /// Result columns resolved by PostgreSQL.
  columns : Array[Column]
  state : ScopedStatementState
}

///|
/// A bound portal usable only during its `with_portal` callback.
/// Fetch multiple windows with `with_stream` or execute to completion with
/// `execute`. The scope waits for started calls before closing the portal.
/// Database operations through a saved handle report `Closed` after its
/// callback ends.
struct Portal {
  transaction : Transaction
  name : Bytes
  /// Result columns associated with the portal.
  columns : Array[Column]
  closed : @ref.Ref[Bool]
  active : @ref.Ref[Bool]
  active_calls : @ref.Ref[Int]
}

///|
/// Return a read-only view of the scoped statement's parameter types.
pub fn ScopedStatement::params(self : ScopedStatement) -> ArrayView[Type] {
  self.params[:]
}

///|
/// Return a read-only view of the scoped statement's result columns.
pub fn ScopedStatement::columns(self : ScopedStatement) -> ArrayView[Column] {
  self.columns[:]
}

///|
/// Return a read-only view of the portal's result columns.
pub fn Portal::columns(self : Portal) -> ArrayView[Column] {
  self.columns[:]
}

///|
fn ScopedStatement::new(
  owner : ScopedStatementOwner,
  statement : Statement,
) -> ScopedStatement {
  {
    params: statement.params.copy(),
    columns: statement.columns.copy(),
    state: {
      owner,
      statement,
      active: @ref.new(true),
      active_calls: @ref.new(0),
    },
  }
}

///|
fn Portal::new(
  transaction : Transaction,
  name : Bytes,
  columns : Array[Column],
) -> Portal {
  {
    transaction,
    name,
    columns,
    closed: @ref.new(false),
    active: @ref.new(true),
    active_calls: @ref.new(0),
  }
}

///|
fn ScopedStatementState::begin_call(self : ScopedStatementState) -> Unit raise {
  if !self.active.val {
    raise ClientError::Closed("prepared statement scope expired")
  }
  self.active_calls.val += 1
}

///|
fn Portal::begin_call(self : Portal) -> Unit raise {
  if !self.active.val {
    raise ClientError::Closed("portal scope expired")
  }
  self.active_calls.val += 1
}

///|
async fn ScopedStatementState::finish(self : ScopedStatementState) -> Unit {
  self.active.val = false
  while self.active_calls.val > 0 {
    @async.pause()
  }
  match self.owner {
    ClientOwner(client) => client.close_statement_for_scope(self.statement)
    TransactionOwner(transaction) => {
      errdefer {
        transaction.client.abort()
        transaction.invalidate_if_connection_closed()
      }
      transaction.close_statement(self.statement)
    }
  }
}

///|
async fn Client::close_statement_for_scope(
  self : Client,
  statement : Statement,
) -> Unit {
  errdefer self.abort()
  statement.close()
}

///|
async fn Portal::finish(self : Portal) -> Unit {
  self.active.val = false
  while self.active_calls.val > 0 {
    @async.pause()
  }
  errdefer {
    self.transaction.client.abort()
    self.transaction.invalidate_if_connection_closed()
  }
  self.transaction.close_portal(self)
}

///|
/// Prepare a statement, run one callback, and close it on every exit.
pub async fn[T] Client::with_prepared(
  self : Client,
  sql : String,
  f : async (ScopedStatement) -> T,
) -> T {
  self.with_prepared_typed(sql, [], f)
}

///|
/// Like `with_prepared`, with explicit parameter types.
pub async fn[T] Client::with_prepared_typed(
  self : Client,
  sql : String,
  types : Array[Type],
  f : async (ScopedStatement) -> T,
) -> T {
  let statement = self.prepare_typed(sql, types)
  let scoped = ScopedStatement::new(ClientOwner(self), statement)
  errdefer @async.protect_from_cancel(() => {
    scoped.state.finish() catch {
      ClientError::Closed(_) => ()
      _ => self.abort()
    }
  })
  check_pending_cancellation()
  let result = f(scoped)
  check_pending_cancellation()
  {
    defer check_pending_cancellation()
    @async.protect_from_cancel(() => scoped.state.finish())
  }
  result
}

///|
/// Prepare a transaction-owned statement and close it within the transaction.
/// Explicit commit or rollback reports an error until this scope has finished.
pub async fn[T] Transaction::with_prepared(
  self : Transaction,
  sql : String,
  f : async (ScopedStatement) -> T,
) -> T {
  self.with_prepared_typed(sql, [], f)
}

///|
/// Like `with_prepared`, with explicit parameter types.
pub async fn[T] Transaction::with_prepared_typed(
  self : Transaction,
  sql : String,
  types : Array[Type],
  f : async (ScopedStatement) -> T,
) -> T {
  self.assert_open()
  self.scoped_resources.val += 1
  defer {
    self.scoped_resources.val -= 1
  }
  let statement = self.prepare_typed(sql, types)
  let scoped = ScopedStatement::new(TransactionOwner(self), statement)
  errdefer @async.protect_from_cancel(() => {
    scoped.state.finish() catch {
      ClientError::Closed(_) => ()
      _ => self.client.abort()
    }
  })
  check_pending_cancellation()
  let result = f(scoped)
  check_pending_cancellation()
  {
    defer check_pending_cancellation()
    @async.protect_from_cancel(() => scoped.state.finish())
  }
  result
}

///|
/// Execute one statement stream and finish it before this call returns.
pub async fn[T] ScopedStatement::with_stream(
  self : ScopedStatement,
  params? : Array[&ToSql] = [],
  f : async (RowStream) -> T,
) -> T {
  self.state.begin_call()
  defer {
    self.state.active_calls.val -= 1
  }
  match self.state.owner {
    ClientOwner(client) =>
      client.with_statement_stream(self.state.statement, params~, f)
    TransactionOwner(transaction) =>
      transaction.with_statement_stream(self.state.statement, params~, f)
  }
}

///|
/// Execute this prepared statement and return its affected row count as `UInt64`.
pub async fn ScopedStatement::execute(
  self : ScopedStatement,
  params? : Array[&ToSql] = [],
) -> UInt64 {
  self.state.begin_call()
  defer {
    self.state.active_calls.val -= 1
  }
  match self.state.owner {
    ClientOwner(client) => client.execute_raw(self.state.statement, params~)
    TransactionOwner(transaction) =>
      transaction.execute_raw(self.state.statement, params~)
  }
}

///|
/// Bind a portal from a transaction-owned scoped statement and close it on
/// every callback exit. The statement remains usable within its own scope.
pub async fn[T] ScopedStatement::with_portal(
  self : ScopedStatement,
  params? : Array[&ToSql] = [],
  f : async (Portal) -> T,
) -> T {
  self.state.begin_call()
  defer {
    self.state.active_calls.val -= 1
  }
  match self.state.owner {
    TransactionOwner(transaction) =>
      transaction.with_portal(self.state.statement, params~, f)
    ClientOwner(_) =>
      raise ClientError::Closed("portal requires a transaction scope")
  }
}

///|
/// Bind a portal, run one callback, and close the portal on every exit.
/// The caller retains the statement and may reuse it after this scope ends.
/// Explicit commit or rollback reports an error until this scope has finished.
pub async fn[T] Transaction::with_portal(
  self : Transaction,
  statement : Statement,
  params? : Array[&ToSql] = [],
  f : async (Portal) -> T,
) -> T {
  self.client.assert_statement_connection(statement)
  self.assert_open()
  self.scoped_resources.val += 1
  defer {
    self.scoped_resources.val -= 1
  }
  let portal = self.bind(statement, params~)
  errdefer @async.protect_from_cancel(() => {
    portal.finish() catch {
      ClientError::Closed(_) => ()
      _ => self.client.abort()
    }
  })
  check_pending_cancellation()
  let result = f(portal)
  check_pending_cancellation()
  {
    defer check_pending_cancellation()
    @async.protect_from_cancel(() => portal.finish())
  }
  result
}

///|
/// Fetch rows from this portal, finishing the stream on every exit.
/// The portal remains available for later fetches within its callback. A zero
/// row limit fetches all remaining rows; `QuerySummary.suspended` reports when
/// PostgreSQL stops at a row limit.
pub async fn[T] Portal::with_stream(
  self : Portal,
  max_rows : Int,
  f : async (RowStream) -> T,
) -> T {
  self.begin_call()
  defer {
    self.active_calls.val -= 1
  }
  self.transaction.with_portal_stream(self, max_rows, f)
}

///|
/// Execute this portal to completion and return its affected row count as `UInt64`.
pub async fn Portal::execute(self : Portal) -> UInt64 {
  self.with_stream(0, stream => {
    let summary = stream.finish()
    rows_affected(summary.command_tag)
  })
}
