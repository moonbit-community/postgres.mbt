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
pub struct ScopedStatement {
  /// Parameter types resolved by PostgreSQL.
  params : Array[Type]
  /// Result columns resolved by PostgreSQL.
  columns : Array[Column]
  priv state : ScopedStatementState
}

///|
priv struct ScopedPortalState {
  transaction : Transaction
  portal : Portal
  active : @ref.Ref[Bool]
  active_calls : @ref.Ref[Int]
}

///|
/// A bound portal usable only during its `with_portal` callback.
pub struct ScopedPortal {
  /// Result columns associated with the portal.
  columns : Array[Column]
  priv state : ScopedPortalState
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
fn ScopedPortal::new(
  transaction : Transaction,
  portal : Portal,
) -> ScopedPortal {
  {
    columns: portal.columns.copy(),
    state: {
      transaction,
      portal,
      active: @ref.new(true),
      active_calls: @ref.new(0),
    },
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
fn ScopedPortalState::begin_call(self : ScopedPortalState) -> Unit raise {
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
async fn ScopedPortalState::finish(self : ScopedPortalState) -> Unit {
  self.active.val = false
  while self.active_calls.val > 0 {
    @async.pause()
  }
  errdefer {
    self.transaction.client.abort()
    self.transaction.invalidate_if_connection_closed()
  }
  self.transaction.close_portal(self.portal)
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
      _ => ()
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
      _ => ()
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
/// Execute this prepared statement and return its affected row count.
pub async fn ScopedStatement::execute(
  self : ScopedStatement,
  params? : Array[&ToSql] = [],
) -> Int {
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
/// Bind a portal from a transaction-owned scoped statement.
pub async fn[T] ScopedStatement::with_portal(
  self : ScopedStatement,
  params? : Array[&ToSql] = [],
  f : async (ScopedPortal) -> T,
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
pub async fn[T] Transaction::with_portal(
  self : Transaction,
  statement : Statement,
  params? : Array[&ToSql] = [],
  f : async (ScopedPortal) -> T,
) -> T {
  self.assert_open()
  self.scoped_resources.val += 1
  defer {
    self.scoped_resources.val -= 1
  }
  let portal = self.bind(statement, params~)
  let scoped = ScopedPortal::new(self, portal)
  errdefer @async.protect_from_cancel(() => {
    scoped.state.finish() catch {
      _ => ()
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
/// Fetch rows from this portal, finishing the stream on every exit.
pub async fn[T] ScopedPortal::with_stream(
  self : ScopedPortal,
  max_rows : Int,
  f : async (RowStream) -> T,
) -> T {
  self.state.begin_call()
  defer {
    self.state.active_calls.val -= 1
  }
  self.state.transaction.with_portal_stream(self.state.portal, max_rows, f)
}

///|
/// Execute this portal to completion and return its affected row count.
pub async fn ScopedPortal::execute(self : ScopedPortal) -> Int {
  self.with_stream(0, stream => {
    let summary = stream.finish()
    rows_affected(summary.command_tag)
  })
}
