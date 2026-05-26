// Prepared statement, portal, and statement-cache APIs.

///|
/// Run one operation through the scope that owns a prepared statement or portal.
async fn[T] PreparedStatementScope::run_request(
  self : PreparedStatementScope,
  client_op : async (@client.Client) -> T,
  transaction_op : async (@client.Transaction) -> T,
) -> T {
  match self {
    ClientScope(state) => {
      let client = state.begin_operation()
      defer state.finish_operation()
      @async.protect_from_cancel(() => client_op(client), resume_on_cancel=true)
    }
    OperationScope(state) => {
      let client = state.begin_request()
      defer state.finish_request()
      @async.protect_from_cancel(() => client_op(client), resume_on_cancel=true)
    }
    TransactionScope(state) => {
      let transaction = state.begin_operation()
      defer state.finish_operation()
      @async.protect_from_cancel(
        () => transaction_op(transaction),
        resume_on_cancel=true,
      )
    }
  }
}

///|
/// Return the task group that should host detached low-level cleanup work.
fn PreparedStatementScope::group(
  self : PreparedStatementScope,
) -> @async.TaskGroup[Unit] {
  match self {
    ClientScope(state) => state.connection.group
    OperationScope(state) => state.connection.group
    TransactionScope(state) => state.connection.group
  }
}

///|
/// Check whether a cache entry matches one SQL + type tuple.
fn cached_statement_matches(
  entry : CachedStatementEntry,
  sql : String,
  param_types : Array[@client.Type],
) -> Bool {
  entry.sql == sql && entry.param_types == param_types
}

///|
/// Find one cached prepared statement entry on a physical connection.
fn find_cached_statement_entry(
  connection : ConnectionState,
  sql : String,
  param_types : Array[@client.Type],
) -> CachedStatementEntry? {
  for entry in connection.statement_cache {
    if cached_statement_matches(entry, sql, param_types) {
      return Some(entry)
    }
  }
  None
}

///|
/// Remove one cached statement entry from a physical connection.
fn take_cached_statement_entry(
  connection : ConnectionState,
  sql : String,
  param_types : Array[@client.Type],
) -> CachedStatementEntry? {
  for i in 0..<connection.statement_cache.length() {
    let entry = connection.statement_cache[i]
    if cached_statement_matches(entry, sql, param_types) {
      ignore(connection.statement_cache.remove(i))
      return Some(entry)
    }
  }
  None
}

///|
/// Best-effort close one raw prepared statement.
async fn close_statement_best_effort(statement : @client.Statement) -> Unit {
  try
    @async.protect_from_cancel(() => statement.close(), resume_on_cancel=true)
  catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// Acquire one cached prepared statement lease, preparing on miss.
async fn acquire_cached_statement(
  connection : ConnectionState,
  sql : String,
  param_types : Array[@client.Type],
  prepare : async () -> @client.Statement,
) -> CachedStatementLease {
  match find_cached_statement_entry(connection, sql, param_types) {
    Some(entry) => {
      entry.in_use.val += 1
      { entry, }
    }
    None => {
      let statement = prepare()
      match find_cached_statement_entry(connection, sql, param_types) {
        Some(entry) => {
          entry.in_use.val += 1
          close_statement_best_effort(statement)
          { entry, }
        }
        None => {
          let entry = {
            sql,
            param_types,
            statement,
            in_use: @ref.new(1),
            evicted: @ref.new(false),
          }
          connection.statement_cache.push(entry)
          { entry, }
        }
      }
    }
  }
}

///|
/// Release one cached statement lease and close it if it was evicted meanwhile.
async fn release_cached_statement_lease(lease : CachedStatementLease) -> Unit {
  if lease.entry.in_use.val > 0 {
    lease.entry.in_use.val -= 1
  }
  if lease.entry.in_use.val == 0 && lease.entry.evicted.val {
    lease.entry.statement.close()
  }
}

///|
/// Mark one cached statement entry as evicted and close it once no lease remains.
async fn evict_cached_statement_entry(entry : CachedStatementEntry) -> Unit {
  entry.evicted.val = true
  if entry.in_use.val == 0 {
    entry.statement.close()
  }
}

///|
/// Clear every cached statement for one physical connection.
async fn clear_connection_statement_cache(connection : ConnectionState) -> Unit {
  while connection.statement_cache.length() > 0 {
    let entry = connection.statement_cache.remove(
      connection.statement_cache.length() - 1,
    )
    evict_cached_statement_entry(entry)
  }
}

///|
/// Remove one cached statement from a physical connection if present.
async fn remove_connection_cached_statement(
  connection : ConnectionState,
  sql : String,
  param_types : Array[@client.Type],
) -> Unit {
  match take_cached_statement_entry(connection, sql, param_types) {
    Some(entry) => evict_cached_statement_entry(entry)
    None => ()
  }
}

///|
/// Fail when a scoped prepared statement is used after its callback finished.
fn PreparedStatementState::assert_active(
  self : PreparedStatementState,
) -> Unit raise {
  if !self.active.val {
    raise PoolError::LeaseReleased
  }
}

///|
/// Access the raw statement handle behind one scoped prepared statement.
fn PreparedStatementState::raw_statement(
  self : PreparedStatementState,
) -> @client.Statement {
  match self.handle {
    Temporary(statement) => statement
    Cached(lease) => lease.entry.statement
  }
}

///|
/// Release one scoped prepared statement exactly once.
async fn PreparedStatement::release_internal(self : PreparedStatement) -> Unit {
  if self.state.released.val {
    return
  }
  self.state.active.val = false
  self.state.released.val = true
  match self.state.handle {
    Temporary(statement) => statement.close()
    Cached(lease) => release_cached_statement_lease(lease)
  }
}

///|
/// Best-effort release for cleanup paths that must not mask an earlier error.
async fn PreparedStatement::release_best_effort(
  self : PreparedStatement,
) -> Unit {
  try
    @async.protect_from_cancel(
      () => self.release_internal(),
      resume_on_cancel=true,
    )
  catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// Run one scoped prepared-statement callback and guarantee cleanup.
async fn[T] run_prepared_callback(
  prepared : PreparedStatement,
  f : async (PreparedStatement) -> T,
) -> T {
  try {
    let result = @async.protect_from_cancel(
      () => f(prepared),
      resume_on_cancel=true,
    )
    prepared.release_internal()
    result
  } catch {
    err => {
      prepared.release_best_effort()
      raise err
    }
  }
}

///|
/// Run one query using a prepared statement and collect every row.
async fn PreparedStatement::run_query_all(
  self : PreparedStatement,
  params : Array[&@client.ToSql],
) -> Array[@client.Row] {
  self.state.assert_active()
  let statement = self.state.raw_statement()
  match self.state.scope {
    ClientScope(state) => {
      let client = state.begin_operation()
      defer state.finish_operation()
      client.query_statement(statement, params~).collect()
    }
    OperationScope(state) => {
      let client = state.begin_request()
      defer state.finish_request()
      client.query_statement(statement, params~).collect()
    }
    TransactionScope(state) => {
      let transaction = state.begin_operation()
      defer state.finish_operation()
      transaction.query_statement(statement, params~).collect()
    }
  }
}

///|
/// Run one prepared statement and require exactly one returned row.
async fn PreparedStatement::run_query_one(
  self : PreparedStatement,
  params : Array[&@client.ToSql],
) -> @client.Row {
  let rows = self.run_query_all(params)
  guard rows.length() == 1 else {
    raise PoolError::RowCount(
      "expected exactly one row, got \{rows.length().to_string()}",
    )
  }
  rows[0]
}

///|
/// Run one prepared statement and allow zero or one rows.
async fn PreparedStatement::run_query_opt(
  self : PreparedStatement,
  params : Array[&@client.ToSql],
) -> @client.Row? {
  let rows = self.run_query_all(params)
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
/// Execute one prepared statement and return its affected row count.
async fn PreparedStatement::run_execute(
  self : PreparedStatement,
  params : Array[&@client.ToSql],
) -> Int {
  self.state.assert_active()
  let statement = self.state.raw_statement()
  match self.state.scope {
    ClientScope(state) => {
      let client = state.begin_operation()
      defer state.finish_operation()
      client.execute_raw(statement, params~)
    }
    OperationScope(state) => {
      let client = state.begin_request()
      defer state.finish_request()
      client.execute_raw(statement, params~)
    }
    TransactionScope(state) => {
      let transaction = state.begin_operation()
      defer state.finish_operation()
      transaction.execute_raw(statement, params~)
    }
  }
}

///|
/// Return the statement-cache handle bound to this physical connection.
///
/// Preconditions: the pooled client lease must still be active. The returned
/// handle manages cached prepared statements on this one connection only. It is
/// not a pool-wide cache view; different physical connections have different
/// statement caches.
pub fn Client::statement_cache(self : Client) -> StatementCache raise {
  if self.state.released.val {
    raise PoolError::LeaseReleased
  }
  { connection: self.state.connection }
}

///|
/// Prepare one non-cached statement scoped to this callback.
///
/// Side effects: creates a fresh PostgreSQL prepared statement and closes it
/// automatically when the callback finishes, even on error.
pub async fn[T] Client::with_prepared(
  self : Client,
  sql : String,
  f : async (PreparedStatement) -> T,
) -> T {
  self.run_operation(client => {
    let statement = client.prepare(sql)
    let prepared = make_prepared_statement(
      ClientScope(self.state),
      Temporary(statement),
      statement,
    )
    run_prepared_callback(prepared, f)
  })
}

///|
/// Prepare one typed non-cached statement scoped to this callback.
///
/// `param_types` is sent when PostgreSQL parses the statement. The prepared
/// statement is always closed when the callback ends.
pub async fn[T] Client::with_prepared_typed(
  self : Client,
  sql : String,
  param_types : Array[@client.Type],
  f : async (PreparedStatement) -> T,
) -> T {
  self.run_operation(client => {
    let statement = client.prepare_typed(sql, param_types)
    let prepared = make_prepared_statement(
      ClientScope(self.state),
      Temporary(statement),
      statement,
    )
    run_prepared_callback(prepared, f)
  })
}

///|
/// Prepare or reuse one cached statement scoped to this callback.
///
/// The cache is connection-local. On a cache miss this creates and stores a new
/// prepared statement; on a hit it reuses the existing statement and releases
/// only the cache lease when the callback finishes.
pub async fn[T] Client::with_prepared_cached(
  self : Client,
  sql : String,
  f : async (PreparedStatement) -> T,
) -> T {
  self.run_operation(client => {
    let lease = acquire_cached_statement(self.state.connection, sql, [], () => {
      client.prepare(sql)
    })
    let statement = lease.entry.statement
    let prepared = make_prepared_statement(
      ClientScope(self.state),
      Cached(lease),
      statement,
    )
    run_prepared_callback(prepared, f)
  })
}

///|
/// Prepare or reuse one typed cached statement scoped to this callback.
///
/// Matching uses both `sql` and `param_types`, so the same SQL text prepared
/// with different inferred types occupies different cache entries.
pub async fn[T] Client::with_prepared_typed_cached(
  self : Client,
  sql : String,
  param_types : Array[@client.Type],
  f : async (PreparedStatement) -> T,
) -> T {
  self.run_operation(client => {
    let lease = acquire_cached_statement(
      self.state.connection,
      sql,
      param_types,
      () => client.prepare_typed(sql, param_types),
    )
    let statement = lease.entry.statement
    let prepared = make_prepared_statement(
      ClientScope(self.state),
      Cached(lease),
      statement,
    )
    run_prepared_callback(prepared, f)
  })
}

///|
/// Prepare one non-cached statement inside the active cancellable scope.
///
/// The prepared statement is bound to the `run_cancellable` callback and is
/// closed automatically when the prepared-statement callback ends.
pub async fn[T] Operation::with_prepared(
  self : Operation,
  sql : String,
  f : async (PreparedStatement) -> T,
) -> T {
  let statement = self.run_request(client => client.prepare(sql))
  let prepared = make_prepared_statement(
    OperationScope(self.state),
    Temporary(statement),
    statement,
  )
  run_prepared_callback(prepared, f)
}

///|
/// Prepare one typed non-cached statement inside the active cancellable scope.
pub async fn[T] Operation::with_prepared_typed(
  self : Operation,
  sql : String,
  param_types : Array[@client.Type],
  f : async (PreparedStatement) -> T,
) -> T {
  let statement = self.run_request(client => {
    client.prepare_typed(sql, param_types)
  })
  let prepared = make_prepared_statement(
    OperationScope(self.state),
    Temporary(statement),
    statement,
  )
  run_prepared_callback(prepared, f)
}

///|
/// Prepare or reuse one cached statement inside the active cancellable scope.
///
/// The cache is local to the underlying physical connection.
pub async fn[T] Operation::with_prepared_cached(
  self : Operation,
  sql : String,
  f : async (PreparedStatement) -> T,
) -> T {
  let lease = self.run_request(client => {
    acquire_cached_statement(self.state.connection, sql, [], () => {
      client.prepare(sql)
    })
  })
  let statement = lease.entry.statement
  let prepared = make_prepared_statement(
    OperationScope(self.state),
    Cached(lease),
    statement,
  )
  run_prepared_callback(prepared, f)
}

///|
/// Prepare or reuse one typed cached statement inside the active cancellable scope.
pub async fn[T] Operation::with_prepared_typed_cached(
  self : Operation,
  sql : String,
  param_types : Array[@client.Type],
  f : async (PreparedStatement) -> T,
) -> T {
  let lease = self.run_request(client => {
    acquire_cached_statement(self.state.connection, sql, param_types, () => {
      client.prepare_typed(sql, param_types)
    })
  })
  let statement = lease.entry.statement
  let prepared = make_prepared_statement(
    OperationScope(self.state),
    Cached(lease),
    statement,
  )
  run_prepared_callback(prepared, f)
}

///|
/// Return the statement-cache handle for this transaction's physical connection.
///
/// Preconditions: the transaction must not already be finished.
pub fn Transaction::statement_cache(self : Transaction) -> StatementCache raise {
  if self.state.finished.val {
    raise PoolError::LeaseReleased
  }
  { connection: self.state.connection }
}

///|
/// Return the current number of cached prepared statements on this connection.
///
/// Preconditions: the underlying physical connection must still be live.
pub fn StatementCache::size(self : StatementCache) -> Int raise {
  match self.connection.client.val {
    Some(_) => self.connection.statement_cache.length()
    None => raise PoolError::LeaseReleased
  }
}

///|
/// Clear this connection's statement cache.
///
/// In-use statements are evicted immediately from the cache and are closed once
/// the last active lease on them ends.
pub async fn StatementCache::clear(self : StatementCache) -> Unit {
  clear_connection_statement_cache(self.connection)
}

///|
/// Remove one cached statement key from this connection's statement cache.
///
/// Matching uses both `sql` and `param_types`. Missing entries are ignored.
pub async fn StatementCache::remove(
  self : StatementCache,
  sql : String,
  param_types? : Array[@client.Type] = [],
) -> Unit {
  remove_connection_cached_statement(self.connection, sql, param_types)
}

///|
/// Prepare one non-cached statement scoped to the current transaction callback.
///
/// The statement is closed automatically when the prepared-statement callback
/// ends, even if that callback raises.
pub async fn[T] Transaction::with_prepared(
  self : Transaction,
  sql : String,
  f : async (PreparedStatement) -> T,
) -> T {
  let statement = self.run_operation(txn => txn.prepare(sql))
  let prepared = make_prepared_statement(
    TransactionScope(self.state),
    Temporary(statement),
    statement,
  )
  run_prepared_callback(prepared, f)
}

///|
/// Prepare one typed non-cached statement scoped to the current transaction callback.
///
/// `param_types` is sent when PostgreSQL parses the statement.
pub async fn[T] Transaction::with_prepared_typed(
  self : Transaction,
  sql : String,
  param_types : Array[@client.Type],
  f : async (PreparedStatement) -> T,
) -> T {
  let statement = self.run_operation(txn => txn.prepare_typed(sql, param_types))
  let prepared = make_prepared_statement(
    TransactionScope(self.state),
    Temporary(statement),
    statement,
  )
  run_prepared_callback(prepared, f)
}

///|
/// Prepare or reuse one cached statement scoped to the current transaction callback.
///
/// The cache is local to the underlying physical connection.
pub async fn[T] Transaction::with_prepared_cached(
  self : Transaction,
  sql : String,
  f : async (PreparedStatement) -> T,
) -> T {
  let lease = self.run_operation(txn => {
    acquire_cached_statement(self.state.connection, sql, [], () => {
      txn.prepare(sql)
    })
  })
  let statement = lease.entry.statement
  let prepared = make_prepared_statement(
    TransactionScope(self.state),
    Cached(lease),
    statement,
  )
  run_prepared_callback(prepared, f)
}

///|
/// Prepare or reuse one typed cached statement scoped to the current transaction callback.
///
/// Matching uses both `sql` and `param_types`.
pub async fn[T] Transaction::with_prepared_typed_cached(
  self : Transaction,
  sql : String,
  param_types : Array[@client.Type],
  f : async (PreparedStatement) -> T,
) -> T {
  let lease = self.run_operation(txn => {
    acquire_cached_statement(self.state.connection, sql, param_types, () => {
      txn.prepare_typed(sql, param_types)
    })
  })
  let statement = lease.entry.statement
  let prepared = make_prepared_statement(
    TransactionScope(self.state),
    Cached(lease),
    statement,
  )
  run_prepared_callback(prepared, f)
}

///|
/// Execute this scoped prepared statement and collect all rows.
///
/// Preconditions: the statement must still be active inside its callback scope.
pub async fn PreparedStatement::query_all(
  self : PreparedStatement,
  params? : Array[&@client.ToSql] = [],
) -> Array[@client.Row] {
  self.run_query_all(params)
}

///|
/// Execute this scoped prepared statement and require exactly one row.
///
/// Edge behavior: materializes all rows first and raises `PoolError::RowCount`
/// when the result does not contain exactly one row.
pub async fn PreparedStatement::query_one(
  self : PreparedStatement,
  params? : Array[&@client.ToSql] = [],
) -> @client.Row {
  self.run_query_one(params)
}

///|
/// Execute this scoped prepared statement and allow zero or one rows.
///
/// Edge behavior: raises `PoolError::RowCount` when more than one row is
/// returned.
pub async fn PreparedStatement::query_opt(
  self : PreparedStatement,
  params? : Array[&@client.ToSql] = [],
) -> @client.Row? {
  self.run_query_opt(params)
}

///|
/// Execute this scoped prepared statement and return the affected row count.
pub async fn PreparedStatement::execute(
  self : PreparedStatement,
  params? : Array[&@client.ToSql] = [],
) -> Int {
  self.run_execute(params)
}

///|
/// Bind parameters to this scoped prepared statement and create one portal.
///
/// Preconditions: the prepared statement must still be active. The returned
/// portal remains open until `Portal::close()` runs or higher-level cleanup such
/// as `with_portal()` closes it for you.
pub async fn PreparedStatement::bind(
  self : PreparedStatement,
  params? : Array[&@client.ToSql] = [],
) -> Portal {
  self.state.assert_active()
  let statement = self.state.raw_statement()
  let raw = self.state.scope.run_request(
    client => client.bind(statement, params~),
    transaction => transaction.bind(statement, params~),
  )
  make_portal(self.state.scope, raw)
}

///|
/// Best-effort close path used when a portal callback already failed.
async fn Portal::close_best_effort(self : Portal) -> Unit {
  try
    @async.protect_from_cancel(() => self.close(), resume_on_cancel=true)
  catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// Run one portal-scoped callback and guarantee portal cleanup.
async fn[T] run_portal_callback(portal : Portal, f : async (Portal) -> T) -> T {
  try {
    let result = @async.protect_from_cancel(
      () => f(portal),
      resume_on_cancel=true,
    )
    portal.close()
    result
  } catch {
    err => {
      portal.close_best_effort()
      raise err
    }
  }
}

///|
/// Run one callback with a freshly bound scoped portal.
///
/// Side effects: binds the parameters, runs the callback, and then closes the
/// portal on both success and error paths.
pub async fn[T] PreparedStatement::with_portal(
  self : PreparedStatement,
  params? : Array[&@client.ToSql] = [],
  f : async (Portal) -> T,
) -> T {
  let portal = self.bind(params~)
  run_portal_callback(portal, f)
}

///|
/// Close this scoped portal.
///
/// Repeated calls are idempotent. Closing uses the owning pooled scope so the
/// close request is ordered correctly with respect to other operations on the
/// same connection.
pub async fn Portal::close(self : Portal) -> Unit {
  if self.closed.val {
    return
  }
  self.scope.run_request(_client => self.raw.close(), _transaction => {
    self.raw.close()
  })
  self.closed.val = true
}

///|
/// Explicitly release this scoped prepared statement early.
///
/// Repeated calls are idempotent. For temporary statements this closes the raw
/// PostgreSQL statement; for cached statements it only releases the cache lease
/// unless the entry was already evicted.
pub async fn PreparedStatement::close(self : PreparedStatement) -> Unit {
  self.release_internal()
}
