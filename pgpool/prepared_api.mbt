// Callback-scoped prepared statements and the connection-local LRU cache.

///|
/// Run one operation through the scope that owns a prepared statement.
async fn[T] PreparedStatementScope::run_request(
  self : PreparedStatementScope,
  client_op : async (@client.Client) -> T,
  transaction_op : async (@client.Transaction) -> T,
) -> T {
  check_pending_cancellation()
  // Fully consumed requests keep the session gate only for their database work.
  match self {
    ClientScope(state) => {
      let session : Session = { state, }
      session.run_operation(client_op)
    }
    TransactionScope(state) =>
      @async.protect_from_cancel(() => {
        transaction_op(state.scoped_transaction())
      })
  }
}

///|
/// Close a statement through its owning operation context. Client callers
/// already hold the Session gate while changing the cache or closing it.
async fn PreparedStatementScope::close_statement(
  self : PreparedStatementScope,
  statement : @client.Statement,
) -> Unit {
  match self {
    ClientScope(_) => statement.close()
    TransactionScope(state) =>
      state.scoped_transaction().close_statement(statement)
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
/// Snapshot caller-owned parameter metadata before it becomes a cache key.
fn snapshot_statement_cache_param_types(
  param_types : Array[@client.Type],
) -> Array[@client.Type] {
  param_types.copy()
}

///|
/// Move one array element to the MRU end and return it.
fn[T] take_and_promote_index(values : Array[T], index : Int) -> T {
  let value = values.remove(index)
  values.push(value)
  value
}

///|
/// Return whether inserting a new entry must evict the current LRU entry.
fn statement_cache_needs_eviction(size : Int, capacity : Int) -> Bool {
  capacity > 0 && size >= capacity
}

///|
/// Return whether an evicted statement no longer has an active lease.
fn evicted_statement_can_close(in_use : Int, evicted : Bool) -> Bool {
  in_use == 0 && evicted
}

///|
/// Take a matching cache entry and move it to the most-recently-used end.
fn take_and_promote_cached_statement_entry(
  connection : ConnectionState,
  sql : String,
  param_types : Array[@client.Type],
) -> CachedStatementEntry? {
  for i in 0..<connection.statement_cache.length() {
    let entry = connection.statement_cache[i]
    if cached_statement_matches(entry, sql, param_types) {
      return Some(take_and_promote_index(connection.statement_cache, i))
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
/// Acquire one cached prepared statement lease, preparing on miss.
async fn acquire_cached_statement(
  connection : ConnectionState,
  sql : String,
  param_types : Array[@client.Type],
  prepare : async () -> @client.Statement,
  close : async (@client.Statement) -> Unit,
) -> CachedStatementLease {
  match take_and_promote_cached_statement_entry(connection, sql, param_types) {
    Some(entry) => {
      entry.in_use.val += 1
      { entry, }
    }
    None => {
      let statement = prepare()
      match
        take_and_promote_cached_statement_entry(connection, sql, param_types) {
        Some(entry) => {
          entry.in_use.val += 1
          close(statement) catch {
            _ => ()
          }
          { entry, }
        }
        None => {
          while statement_cache_needs_eviction(
                  connection.statement_cache.length(),
                  connection.statement_cache_capacity,
                ) {
            let lru = connection.statement_cache.remove(0)
            evict_cached_statement_entry(lru, close)
          }
          let entry = {
            sql,
            param_types: snapshot_statement_cache_param_types(param_types),
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
/// Prepare a temporary statement when caching is disabled, otherwise acquire an
/// LRU cache lease for this physical connection.
async fn acquire_prepared_handle(
  connection : ConnectionState,
  sql : String,
  param_types : Array[@client.Type],
  prepare : async () -> @client.Statement,
  close : async (@client.Statement) -> Unit,
) -> (PreparedStatementHandle, @client.Statement) {
  if connection.statement_cache_capacity == 0 {
    let statement = prepare()
    return (Temporary(statement), statement)
  }
  let lease = acquire_cached_statement(
    connection, sql, param_types, prepare, close,
  )
  (Cached(lease), lease.entry.statement)
}

///|
/// Release one cached statement lease and close it if it was evicted meanwhile.
async fn release_cached_statement_lease(
  lease : CachedStatementLease,
  close : async (@client.Statement) -> Unit,
) -> Unit {
  if lease.entry.in_use.val > 0 {
    lease.entry.in_use.val -= 1
  }
  if evicted_statement_can_close(
      lease.entry.in_use.val,
      lease.entry.evicted.val,
    ) {
    close(lease.entry.statement)
  }
}

///|
/// Mark one cached statement entry as evicted and close it once no lease remains.
async fn evict_cached_statement_entry(
  entry : CachedStatementEntry,
  close : async (@client.Statement) -> Unit,
) -> Unit {
  entry.evicted.val = true
  if evicted_statement_can_close(entry.in_use.val, entry.evicted.val) {
    close(entry.statement)
  }
}

///|
/// Fail when a scoped prepared statement is used after its callback finished.
fn PreparedStatementState::assert_active(
  self : PreparedStatementState,
) -> Unit raise {
  if !self.active.val {
    raise PoolError::ScopeExpired
  }
}

///|
/// Count a call before it can wait for the session gate. Cleanup closes the
/// scope first, then waits for all calls that already entered to finish.
fn PreparedStatementState::begin_call(
  self : PreparedStatementState,
) -> Unit raise {
  self.assert_active()
  self.active_calls.val += 1
}

///|
fn PreparedStatementState::finish_call(self : PreparedStatementState) -> Unit {
  self.active_calls.val -= 1
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
/// Return whether PostgreSQL invalidated a prepared statement or its cached plan.
fn invalidates_cached_statement(error : Error) -> Bool {
  guard error is @client.ClientError::Database(database) else { return false }
  database.code == Some("26000") || database.code == Some("0A000")
}

///|
/// Evict the current cached entry after a server-side invalidation error.
async fn PreparedStatementState::invalidate_on_error(
  self : PreparedStatementState,
  error : Error,
) -> Unit {
  guard invalidates_cached_statement(error) else { return }
  guard self.handle is Cached(lease) else { return }
  let connection = match self.scope {
    ClientScope(state) => state.connection
    TransactionScope(state) => state.connection
  }
  // An evicted lease may share a key with a newer cache entry. Never evict the
  // replacement for an error produced by the older statement.
  if lease.entry.evicted.val {
    return
  }
  match self.scope {
    ClientScope(state) =>
      try
        @async.protect_from_cancel(() => {
          state.gate.acquire()
          defer state.gate.release()
          self.evict_invalidated_entry(connection, lease)
        })
      catch {
        _ => ()
      } noraise {
        _ => ()
      }
    TransactionScope(_) => self.evict_invalidated_entry(connection, lease)
  }
}

///|
/// The caller holds the connection's cache gate, or the transaction's
/// exclusive gate. The original database error takes precedence over Close.
async fn PreparedStatementState::evict_invalidated_entry(
  self : PreparedStatementState,
  connection : ConnectionState,
  lease : CachedStatementLease,
) -> Unit {
  if lease.entry.evicted.val {
    return
  }
  match
    take_cached_statement_entry(
      connection,
      lease.entry.sql,
      lease.entry.param_types,
    ) {
    Some(entry) => {
      let _ = evict_cached_statement_entry(entry, statement => {
        match self.scope {
          ClientScope(_) => statement.close()
          TransactionScope(state) =>
            state.scoped_transaction().close_statement(statement)
        }
      }) catch {
        _ => ()
      }
    }
    None => ()
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
  while self.state.active_calls.val > 0 {
    @async.pause()
  }
  let close = () => {
    match self.state.handle {
      Temporary(statement) => self.state.scope.close_statement(statement)
      Cached(lease) =>
        release_cached_statement_lease(lease, statement => {
          self.state.scope.close_statement(statement)
        })
    }
  }
  match self.state.scope {
    ClientScope(state) => {
      errdefer (if state.connection.client.val is Some(client) {
        client.abort()
      })
      state.prepared_cleanup_step(_ => close())
    }
    TransactionScope(_) => close()
  }
}

///|
/// Best-effort release for cleanup paths that must not mask an earlier error.
async fn PreparedStatement::release_best_effort(
  self : PreparedStatement,
) -> Unit {
  try @async.protect_from_cancel(() => self.release_internal()) catch {
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
  errdefer prepared.release_best_effort()
  check_pending_cancellation()
  let result = f(prepared)
  check_pending_cancellation()
  {
    defer check_pending_cancellation()
    @async.protect_from_cancel(() => prepared.release_internal())
  }
  result
}

///|
/// Run one query using a prepared statement and collect every row.
async fn PreparedStatement::run_query_all(
  self : PreparedStatement,
  params : Array[&@client.ToSql],
) -> Array[@client.Row] {
  let statement = self.state.raw_statement()
  self.state.scope.run_request(
    client => client.query_statement(statement, params~).collect(),
    transaction => transaction.query_statement(statement, params~).collect(),
  )
}

///|
/// Run one prepared statement and require exactly one returned row.
async fn PreparedStatement::run_query_one(
  self : PreparedStatement,
  params : Array[&@client.ToSql],
) -> @client.Row {
  let statement = self.state.raw_statement()
  self.state.scope.run_request(
    client => client.query_statement(statement, params~).one(),
    transaction => transaction.query_statement(statement, params~).one(),
  )
}

///|
/// Run one prepared statement and allow zero or one rows.
async fn PreparedStatement::run_query_opt(
  self : PreparedStatement,
  params : Array[&@client.ToSql],
) -> @client.Row? {
  let statement = self.state.raw_statement()
  self.state.scope.run_request(
    client => client.query_statement(statement, params~).opt(),
    transaction => transaction.query_statement(statement, params~).opt(),
  )
}

///|
/// Execute one prepared statement and return its affected row count.
async fn PreparedStatement::run_execute(
  self : PreparedStatement,
  params : Array[&@client.ToSql],
) -> Int {
  let statement = self.state.raw_statement()
  self.state.scope.run_request(
    client => client.execute_raw(statement, params~),
    transaction => transaction.execute_raw(statement, params~),
  )
}

///|
/// Prepare or reuse one connection-local cached statement for this callback.
///
/// A pool configured with `statement_cache_capacity = 0` prepares a temporary
/// statement instead. In either case the callback-scoped handle expires when
/// this method returns.
pub async fn[T] Session::with_prepared(
  self : Session,
  sql : String,
  f : async (PreparedStatement) -> T,
) -> T {
  self.state.begin_prepared_lease()
  defer self.state.finish_prepared_lease()
  let (handle, statement) = self.state.prepare_step(client => {
    acquire_prepared_handle(
      self.state.connection,
      sql,
      [],
      () => client.prepare(sql),
      statement => statement.close(),
    )
  })
  let prepared = PreparedStatement::new(
    ClientScope(self.state),
    handle,
    statement,
  )
  run_prepared_callback(prepared, f)
}

///|
/// Prepare or reuse one typed connection-local cached statement.
pub async fn[T] Session::with_prepared_typed(
  self : Session,
  sql : String,
  param_types : Array[@client.Type],
  f : async (PreparedStatement) -> T,
) -> T {
  self.state.begin_prepared_lease()
  defer self.state.finish_prepared_lease()
  let (handle, statement) = self.state.prepare_step(client => {
    acquire_prepared_handle(
      self.state.connection,
      sql,
      param_types,
      () => client.prepare_typed(sql, param_types),
      statement => statement.close(),
    )
  })
  let prepared = PreparedStatement::new(
    ClientScope(self.state),
    handle,
    statement,
  )
  run_prepared_callback(prepared, f)
}

///|
/// Prepare or reuse one connection-local cached statement in this transaction.
pub async fn[T] Transaction::with_prepared(
  self : Transaction,
  sql : String,
  f : async (PreparedStatement) -> T,
) -> T {
  let transaction = self.state.begin_operation()
  defer self.state.finish_operation()
  let (handle, statement) = @async.protect_from_cancel(() => {
    acquire_prepared_handle(
      self.state.connection,
      sql,
      [],
      () => transaction.prepare(sql),
      statement => transaction.close_statement(statement),
    )
  })
  let prepared = PreparedStatement::new(
    TransactionScope(self.state),
    handle,
    statement,
  )
  run_prepared_callback(prepared, f)
}

///|
/// Prepare or reuse one typed connection-local cached statement in this transaction.
pub async fn[T] Transaction::with_prepared_typed(
  self : Transaction,
  sql : String,
  param_types : Array[@client.Type],
  f : async (PreparedStatement) -> T,
) -> T {
  let transaction = self.state.begin_operation()
  defer self.state.finish_operation()
  let (handle, statement) = @async.protect_from_cancel(() => {
    acquire_prepared_handle(
      self.state.connection,
      sql,
      param_types,
      () => transaction.prepare_typed(sql, param_types),
      statement => transaction.close_statement(statement),
    )
  })
  let prepared = PreparedStatement::new(
    TransactionScope(self.state),
    handle,
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
  self.state.begin_call()
  defer self.state.finish_call()
  self.run_query_all(params) catch {
    @client.ClientError::Database(_) as err => {
      self.state.invalidate_on_error(err)
      raise err
    }
    err => raise err
  }
}

///|
/// Execute this scoped prepared statement and require exactly one row.
///
/// Edge behavior: fully drains the stream and lets `@client.ClientError::RowCount`
/// report an unexpected result size.
pub async fn PreparedStatement::query_one(
  self : PreparedStatement,
  params? : Array[&@client.ToSql] = [],
) -> @client.Row {
  self.state.begin_call()
  defer self.state.finish_call()
  self.run_query_one(params) catch {
    @client.ClientError::Database(_) as err => {
      self.state.invalidate_on_error(err)
      raise err
    }
    err => raise err
  }
}

///|
/// Execute this scoped prepared statement and allow zero or one rows.
///
/// Edge behavior: raises `@client.ClientError::RowCount` when more than one row
/// is returned.
pub async fn PreparedStatement::query_opt(
  self : PreparedStatement,
  params? : Array[&@client.ToSql] = [],
) -> @client.Row? {
  self.state.begin_call()
  defer self.state.finish_call()
  self.run_query_opt(params) catch {
    @client.ClientError::Database(_) as err => {
      self.state.invalidate_on_error(err)
      raise err
    }
    err => raise err
  }
}

///|
/// Execute this scoped prepared statement and return the affected row count.
pub async fn PreparedStatement::execute(
  self : PreparedStatement,
  params? : Array[&@client.ToSql] = [],
) -> Int {
  self.state.begin_call()
  defer self.state.finish_call()
  self.run_execute(params) catch {
    @client.ClientError::Database(_) as err => {
      self.state.invalidate_on_error(err)
      raise err
    }
    err => raise err
  }
}

///|
/// Execute this scoped prepared statement as a callback-scoped row stream.
pub async fn[T] PreparedStatement::with_stream(
  self : PreparedStatement,
  params? : Array[&@client.ToSql] = [],
  f : async (@client.RowStream) -> T,
) -> T {
  self.state.begin_call()
  defer self.state.finish_call()
  let statement = self.state.raw_statement()
  let run = () => {
    match self.state.scope {
      ClientScope(state) => {
        let session : Session = { state, }
        session.run_scoped_operation(client => {
          client.with_statement_stream(statement, params~, f)
        })
      }
      TransactionScope(state) => {
        let stream = @async.protect_from_cancel(() => {
          state.scoped_transaction().query_statement(statement, params~)
        })
        with_row_stream(stream, f)
      }
    }
  }
  run() catch {
    @client.ClientError::Database(_) as err => {
      self.state.invalidate_on_error(err)
      raise err
    }
    err => raise err
  }
}
