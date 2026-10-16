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
fn[T] take_and_promote_index(values : Array[T], index : Int32) -> T {
  let value = values.remove(index)
  values.push(value)
  value
}

///|
/// Return whether inserting a new entry must evict the current LRU entry.
fn statement_cache_needs_eviction(size : Int32, capacity : Int32) -> Bool {
  capacity > 0 && size >= capacity
}

///|
/// Return whether an evicted statement no longer has an active lease.
fn evicted_statement_can_close(in_use : Int32, evicted : Bool) -> Bool {
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
  if take_and_promote_cached_statement_entry(connection, sql, param_types)
    is Some(entry) {
    entry.in_use.val += 1
    { entry, }
  } else {
    let statement = prepare()
    if take_and_promote_cached_statement_entry(connection, sql, param_types)
      is Some(entry) {
      entry.in_use.val += 1
      close(statement) catch {
        @client.ClientError::Database(_) => ()
        _ => if connection.client.val is Some(client) { client.abort() }
      }
      { entry, }
    } else {
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
        in_use: Ref(1),
        evicted: Ref(false),
      }
      connection.statement_cache.push(entry)
      { entry, }
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
    close(lease.entry.statement) catch {
      @client.ClientError::Database(database) if database.code == Some("26000") =>
        ()
      error => raise error
    }
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
fn PreparedStatementScope::state(
  self : PreparedStatementScope,
) -> ClientLeaseState {
  match self {
    ClientScope(state) => state
  }
}

///|
fn PreparedStatementState::raw_statement(
  self : PreparedStatementState,
) -> @client.Statement {
  match self.handle {
    Temporary(statement) => statement
    Cached(lease) => lease.entry.statement
  }
}

///|
async fn release_handle(handle : PreparedStatementHandle) -> Unit {
  match handle {
    Temporary(statement) => statement.close()
    Cached(lease) =>
      release_cached_statement_lease(lease, statement => statement.close())
  }
}

///|
async fn[T] cached_query(
  state : ClientLeaseState,
  client : @client.Client,
  sql : String,
  types : Array[@client.Type],
  f : async (@client.Statement) -> T,
) -> T {
  let (handle, statement) = acquire_prepared_handle(
    state.connection,
    sql,
    types,
    () => client.prepare_typed(sql, types),
    statement => statement.close(),
  )
  errdefer state.cleanup_best_effort(() => release_handle(handle))
  let outcome = try f(statement) catch {
    error => Err(error)
  } noraise {
    value => Ok(value)
  }
  let result = match outcome {
    Ok(value) => value
    Err(error) => {
      invalidate_handle(state, handle, error)
      raise error
    }
  }
  state.cleanup(() => release_handle(handle))
  if !state.cleanup_mode {
    state.cleanup_deadline.val = None
  }
  result
}

///|
async fn PreparedStatement::release_internal(self : PreparedStatement) -> Unit {
  if self.state.released.val {
    return
  }
  self.state.active.val = false
  self.state.released.val = true
  let state = self.state.scope.state()
  state.cleanup(() => {
    if !state.gate.try_acquire() {
      // An escaped task still owns the socket. Retire rather than race Close
      // against that task or wait on a callback that can wait on this one.
      state.scoped_client().abort()
      raise PoolError::OperationInProgress
    }
    defer state.gate.release()
    release_handle(self.state.handle)
  })
}

///|
async fn[T] prepared_scope(
  state : ClientLeaseState,
  sql : String,
  types : Array[@client.Type],
  f : async (PreparedStatement) -> T,
  deadline : Deadline?,
) -> T {
  state.assert_active()
  state.active_ops.val += 1
  defer {
    state.active_ops.val -= 1
  }
  let session : Session = { state, }
  let deadline = earlier_deadline(state.deadline, deadline)
  let acquired : @ref.Ref[PreparedStatementHandle?] = Ref(None)
  errdefer (if acquired.val is Some(handle) {
    state.cleanup_best_effort(() => {
      if !state.gate.try_acquire() {
        state.scoped_client().abort()
        raise PoolError::OperationInProgress
      }
      defer state.gate.release()
      release_handle(handle)
    })
  })
  let (handle, statement) = session.run_operation(
    client => {
      let result = acquire_prepared_handle(
        state.connection,
        sql,
        types,
        () => client.prepare_typed(sql, types),
        statement => statement.close(),
      )
      acquired.val = Some(result.0)
      result
    },
    deadline?,
  )
  acquired.val = None
  let prepared = PreparedStatement::new(
    ClientScope(state),
    handle,
    statement,
    deadline?,
  )
  errdefer (prepared.release_internal() catch { _ => () })
  check_pending_cancellation()
  let result = with_deadline(deadline, Query, () => f(prepared))
  check_pending_cancellation()
  // Observe cancellation received during protected release on both success
  // and failure. Unwinding a callback error still preserves its original cause.
  {
    defer check_pending_cancellation()
    prepared.release_internal()
  }
  if !state.cleanup_mode {
    state.cleanup_deadline.val = None
  }
  result
}

///|
async fn[T] PreparedStatement::run(
  self : PreparedStatement,
  f : async (@client.Client, @client.Statement) -> T,
  deadline : Deadline?,
) -> T {
  if !self.state.active.val {
    raise PoolError::ScopeExpired
  }
  let session : Session = { state: self.state.scope.state(), }
  session.run_operation(
    client => {
      let outcome = try f(client, self.state.raw_statement()) catch {
        error => Err(error)
      } noraise {
        value => Ok(value)
      }
      match outcome {
        Ok(value) => value
        Err(error) => {
          invalidate_handle(session.state, self.state.handle, error)
          raise error
        }
      }
    },
    deadline?=earlier_deadline(self.state.deadline, deadline),
  )
}

///|
/// Prepare a scoped handle. The callback itself does not occupy the connection.
/// Release uses the shared cleanup budget. Cancellation received during release
/// propagates before returning to user code, even if release fails.
pub async fn[T] Session::with_prepared(
  self : Session,
  sql : String,
  f : async (PreparedStatement) -> T,
  deadline? : Deadline,
) -> T {
  prepared_scope(self.state, sql, [], f, deadline)
}

///|
/// Prepare a scoped handle. The callback itself does not occupy the connection.
pub async fn[T] Session::with_prepared_typed(
  self : Session,
  sql : String,
  param_types : Array[@client.Type],
  f : async (PreparedStatement) -> T,
  deadline? : Deadline,
) -> T {
  prepared_scope(self.state, sql, param_types, f, deadline)
}

///|
/// Prepare a scoped handle. The callback itself does not occupy the connection.
pub async fn[T] Transaction::with_prepared(
  self : Transaction,
  sql : String,
  f : async (PreparedStatement) -> T,
  deadline? : Deadline,
) -> T {
  prepared_scope(self.state, sql, [], f, deadline)
}

///|
/// Prepare a scoped handle. The callback itself does not occupy the connection.
pub async fn[T] Transaction::with_prepared_typed(
  self : Transaction,
  sql : String,
  param_types : Array[@client.Type],
  f : async (PreparedStatement) -> T,
  deadline? : Deadline,
) -> T {
  prepared_scope(self.state, sql, param_types, f, deadline)
}

///|
pub async fn PreparedStatement::query_all(
  self : PreparedStatement,
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
) -> Array[@client.Row] {
  self.run(
    (client, statement) => client.query_statement(statement, params~).collect(),
    deadline,
  )
}

///|
pub async fn PreparedStatement::query_one(
  self : PreparedStatement,
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
) -> @client.Row {
  self.run(
    (client, statement) => client.query_statement(statement, params~).one(),
    deadline,
  )
}

///|
pub async fn PreparedStatement::query_opt(
  self : PreparedStatement,
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
) -> @client.Row? {
  self.run(
    (client, statement) => client.query_statement(statement, params~).opt(),
    deadline,
  )
}

///|
pub async fn PreparedStatement::execute(
  self : PreparedStatement,
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
) -> UInt64 {
  self.run(
    (client, statement) => client.execute_raw(statement, params~),
    deadline,
  )
}

///|
fn invalidate_handle(
  state : ClientLeaseState,
  handle : PreparedStatementHandle,
  error : Error,
) -> Unit {
  guard error is @client.ClientError::Database(database) else { return }
  guard database.code == Some("26000") || database.code == Some("0A000") else {
    return
  }
  guard handle is Cached(lease) else { return }
  if lease.entry.evicted.val {
    return
  }
  ignore(
    take_cached_statement_entry(
      state.connection,
      lease.entry.sql,
      lease.entry.param_types,
    ),
  )
  lease.entry.evicted.val = true
}
