// Safe pooled-client, prepared-statement, and pooled-transaction APIs.

///|
/// Start one client operation or reject work after release begins.
fn ClientLeaseState::begin_operation(
  self : ClientLeaseState,
) -> @client.Client raise {
  if self.releasing.val || self.released.val {
    raise PoolError::LeaseReleased
  }
  if self.scope_active.val {
    raise PoolError::OperationInProgress
  }
  match self.connection.client.val {
    Some(client) => {
      self.active_ops.val += 1
      client
    }
    None => raise PoolError::LeaseReleased
  }
}

///|
/// Finish one client operation and finalize delayed release if needed.
fn ClientLeaseState::finish_operation(self : ClientLeaseState) -> Unit {
  if self.active_ops.val > 0 {
    self.active_ops.val -= 1
  }
  if self.releasing.val && !self.released.val && self.active_ops.val == 0 {
    self.finalize_release()
  }
}

///|
/// Start one exclusive cancellable scope on this lease.
fn ClientLeaseState::begin_cancellable_scope(
  self : ClientLeaseState,
) -> ConnectionState raise {
  if self.releasing.val || self.released.val {
    raise PoolError::LeaseReleased
  }
  if self.scope_active.val || self.active_ops.val > 0 {
    raise PoolError::OperationInProgress
  }
  match self.connection.client.val {
    Some(_) => {
      self.scope_active.val = true
      self.active_ops.val += 1
      self.connection
    }
    None => raise PoolError::LeaseReleased
  }
}

///|
/// Finish one exclusive cancellable scope on this lease.
fn ClientLeaseState::finish_cancellable_scope(self : ClientLeaseState) -> Unit {
  self.scope_active.val = false
  self.finish_operation()
}

///|
/// Start one exclusive transaction scope on this lease.
fn ClientLeaseState::begin_transaction_scope(
  self : ClientLeaseState,
) -> (@client.Client, ConnectionState) raise {
  if self.releasing.val || self.released.val {
    raise PoolError::LeaseReleased
  }
  if self.scope_active.val || self.active_ops.val > 0 {
    raise PoolError::OperationInProgress
  }
  match self.connection.client.val {
    Some(client) => {
      self.scope_active.val = true
      self.active_ops.val += 1
      (client, self.connection)
    }
    None => raise PoolError::LeaseReleased
  }
}

///|
/// Finish one exclusive transaction scope on this lease.
fn ClientLeaseState::finish_transaction_scope(self : ClientLeaseState) -> Unit {
  self.scope_active.val = false
  self.finish_operation()
}

///|
/// Return the client to the pool once no active operations remain.
fn ClientLeaseState::finalize_release(self : ClientLeaseState) -> Unit {
  if self.released.val {
    return
  }
  self.released.val = true
  return_client(self.pool, self.connection)
}

///|
/// Run one async operation against the checked-out client.
async fn[T] Client::run_operation(
  self : Client,
  op : async (@client.Client) -> T,
) -> T {
  let client = self.state.begin_operation()
  defer self.state.finish_operation()
  @async.protect_from_cancel(() => op(client), resume_on_cancel=true)
}

///|
/// Wait for any late cancel send to finish, then start one request.
async fn OperationScopeState::begin_request(
  self : OperationScopeState,
) -> @client.Client {
  if !self.active.val || self.closing.val {
    raise PoolError::LeaseReleased
  }
  while self.cancel_in_flight.val > 0 {
    if !self.active.val || self.closing.val {
      raise PoolError::LeaseReleased
    }
    @async.pause()
  }
  if !self.active.val || self.closing.val {
    raise PoolError::LeaseReleased
  }
  if self.request_in_flight.val {
    raise PoolError::OperationInProgress
  }
  let client = match self.connection.client.val {
    Some(client) => client
    None => raise PoolError::LeaseReleased
  }
  self.next_request_id.val += 1
  self.active_request_id.val = self.next_request_id.val
  self.request_in_flight.val = true
  client
}

///|
/// Mark the current request as finished.
fn OperationScopeState::finish_request(self : OperationScopeState) -> Unit {
  if self.request_in_flight.val {
    self.request_in_flight.val = false
    self.active_request_id.val = 0
  }
}

///|
/// Close this operation scope and wait for late cancel cleanup.
async fn OperationScopeState::finish_scope(self : OperationScopeState) -> Unit {
  if self.closing.val {
    while self.request_in_flight.val || self.cancel_in_flight.val > 0 {
      @async.pause()
    }
    self.active.val = false
    return
  }
  self.closing.val = true
  while self.request_in_flight.val || self.cancel_in_flight.val > 0 {
    @async.pause()
  }
  self.active.val = false
}

///|
/// Run one request inside the active cancellable scope.
async fn[T] Operation::run_request(
  self : Operation,
  op : async (@client.Client) -> T,
) -> T {
  let client = self.state.begin_request()
  defer self.state.finish_request()
  @async.protect_from_cancel(() => op(client), resume_on_cancel=true)
}

///|
/// Run one callback inside a cancellable pooled-operation scope.
async fn[T] run_cancellable_scope(
  connection : ConnectionState,
  f : async (Operation, OperationCancelToken) -> T,
) -> T {
  let (operation, token) = make_pooled_operation(connection)
  try {
    let result = f(operation, token)
    operation.state.finish_scope()
    result
  } catch {
    err => {
      operation.state.finish_scope()
      raise err
    }
  }
}

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
/// Fail low-level stream operations after a background detach started.
fn raise_detached_stream_error() -> Unit raise {
  raise PoolError::LeaseReleased
}

///|
/// Refresh the public column metadata cached on one pooled row stream.
fn RowStream::sync_columns(self : RowStream) -> Unit {
  self.columns = self.raw.columns
}

///|
/// Reject further direct use once the row stream has detached into the background.
fn RowStream::assert_attached(self : RowStream) -> Unit raise {
  if self.detached_task.val is Some(_) {
    raise_detached_stream_error()
  }
}

///|
/// Run the optional deferred cleanup attached to one pooled row stream.
async fn RowStream::run_cleanup(self : RowStream) -> Unit {
  if self.cleanup_done.val {
    return
  }
  self.cleanup_done.val = true
  match self.cleanup {
    Some(cleanup) => cleanup()
    None => ()
  }
}

///|
/// Ignore row-stream cleanup failures when another error is already in flight.
async fn RowStream::run_cleanup_best_effort(self : RowStream) -> Unit {
  try
    @async.protect_from_cancel(() => self.run_cleanup(), resume_on_cancel=true)
  catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// Wait for one detached row-stream drain or finish it synchronously.
async fn RowStream::finish_scope(self : RowStream) -> Unit {
  match self.detached_task.val {
    Some(task) => {
      task.wait()
      self.completed.val = true
    }
    None => if !self.completed.val { ignore(self.finish()) }
  }
}

///|
/// Ignore row-stream closeout failures when another error already won.
async fn RowStream::finish_scope_best_effort(self : RowStream) -> Unit {
  try
    @async.protect_from_cancel(() => self.finish_scope(), resume_on_cancel=true)
  catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// Read the next row from this scoped row stream.
///
/// Preconditions: the stream must still be attached to the current callback
/// scope, meaning `detach()` has not been called. Returning `None` means the
/// stream is exhausted; in that case the package also runs any deferred cleanup
/// needed before the underlying connection can be reused.
pub async fn RowStream::next(self : RowStream) -> @client.Row? {
  self.assert_attached()
  let row = self.raw.next()
  self.sync_columns()
  match row {
    Some(_) => row
    None => {
      self.completed.val = true
      self.run_cleanup()
      None
    }
  }
}

///|
/// Collect every remaining row from this scoped row stream.
///
/// Side effects: drains the underlying protocol stream to completion, updates
/// `columns` with the latest metadata, and runs deferred cleanup before
/// returning. If the collect operation fails, cleanup still runs best-effort.
pub async fn RowStream::collect(self : RowStream) -> Array[@client.Row] {
  try {
    let rows = self.raw.collect()
    self.sync_columns()
    self.completed.val = true
    self.run_cleanup()
    rows
  } catch {
    err => {
      self.sync_columns()
      self.completed.val = true
      self.run_cleanup_best_effort()
      raise err
    }
  }
}

///|
/// Drain this scoped row stream and return the final query summary.
///
/// This is the explicit close path for callers that need command-tag metadata
/// instead of materializing all rows. As with `collect()`, cleanup runs before
/// the call returns and also runs best-effort on error.
pub async fn RowStream::finish(self : RowStream) -> @client.QuerySummary {
  try {
    let summary = self.raw.finish()
    self.sync_columns()
    self.completed.val = true
    self.run_cleanup()
    summary
  } catch {
    err => {
      self.sync_columns()
      self.completed.val = true
      self.run_cleanup_best_effort()
      raise err
    }
  }
}

///|
/// Detach background draining for this scoped row stream.
///
/// After detaching, direct calls such as `next()`, `collect()`, and `finish()`
/// fail with `PoolError::LeaseReleased`. The pool waits for the detached task
/// when the owning callback exits so the underlying connection is still cleaned
/// up before reuse.
pub fn RowStream::detach(self : RowStream) -> Unit {
  if self.completed.val || self.detached_task.val is Some(_) {
    return
  }
  let task = self.group.spawn(no_wait=true, allow_failure=true, () => {
    try {
      ignore(self.raw.finish())
      self.sync_columns()
      self.completed.val = true
      self.run_cleanup()
    } catch {
      err => {
        self.sync_columns()
        self.completed.val = true
        self.run_cleanup_best_effort()
        raise err
      }
    }
  })
  self.detached_task.val = Some(task)
}

///|
/// Reject further direct use once the simple-query stream detached.
fn SimpleQueryStream::assert_attached(self : SimpleQueryStream) -> Unit raise {
  if self.detached_task.val is Some(_) {
    raise_detached_stream_error()
  }
}

///|
/// Wait for one detached simple-query drain or finish it synchronously.
async fn SimpleQueryStream::finish_scope(self : SimpleQueryStream) -> Unit {
  match self.detached_task.val {
    Some(task) => {
      task.wait()
      self.completed.val = true
    }
    None => if !self.completed.val { self.finish() }
  }
}

///|
/// Ignore simple-query closeout failures when another error already won.
async fn SimpleQueryStream::finish_scope_best_effort(
  self : SimpleQueryStream,
) -> Unit {
  try
    @async.protect_from_cancel(() => self.finish_scope(), resume_on_cancel=true)
  catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// Read the next message from this scoped simple-query stream.
///
/// Preconditions: the stream must not have been detached. Returning `None`
/// means PostgreSQL finished the simple-query response stream.
pub async fn SimpleQueryStream::next(
  self : SimpleQueryStream,
) -> @client.SimpleQueryMessage? {
  self.assert_attached()
  let message = self.raw.next()
  if message is None {
    self.completed.val = true
  }
  message
}

///|
/// Collect every remaining message from this scoped simple-query stream.
///
/// Side effects: drains the underlying stream fully before returning.
pub async fn SimpleQueryStream::collect(
  self : SimpleQueryStream,
) -> Array[@client.SimpleQueryMessage] {
  let messages = self.raw.collect()
  self.completed.val = true
  messages
}

///|
/// Drain this scoped simple-query stream to completion.
pub async fn SimpleQueryStream::finish(self : SimpleQueryStream) -> Unit {
  self.raw.finish()
  self.completed.val = true
}

///|
/// Detach background draining for this scoped simple-query stream.
///
/// After detaching, direct use fails with `PoolError::LeaseReleased`, and the
/// owning callback waits for the detached drain before the connection is reused.
pub fn SimpleQueryStream::detach(self : SimpleQueryStream) -> Unit {
  if self.completed.val || self.detached_task.val is Some(_) {
    return
  }
  let task = self.group.spawn(no_wait=true, allow_failure=true, () => {
    self.raw.finish()
    self.completed.val = true
  })
  self.detached_task.val = Some(task)
}

///|
/// Wait for one detached COPY OUT drain or finish it synchronously.
async fn CopyOutStream::finish_scope(self : CopyOutStream) -> Unit {
  match self.detached_task.val {
    Some(task) => {
      task.wait()
      self.completed.val = true
    }
    None => if !self.completed.val { self.finish() }
  }
}

///|
/// Ignore COPY OUT closeout failures when another error already won.
async fn CopyOutStream::finish_scope_best_effort(self : CopyOutStream) -> Unit {
  try
    @async.protect_from_cancel(() => self.finish_scope(), resume_on_cancel=true)
  catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// Reject further direct use once the COPY OUT stream detached.
fn CopyOutStream::assert_attached(self : CopyOutStream) -> Unit raise {
  if self.detached_task.val is Some(_) {
    raise_detached_stream_error()
  }
}

///|
/// Read the next chunk from this scoped COPY OUT stream.
///
/// Preconditions: the stream must still be attached to the current callback
/// scope. Returning `None` means COPY OUT finished normally.
pub async fn CopyOutStream::next(self : CopyOutStream) -> Bytes? {
  self.assert_attached()
  let chunk = self.raw.next()
  if chunk is None {
    self.completed.val = true
  }
  chunk
}

///|
/// Collect every remaining chunk from this scoped COPY OUT stream.
///
/// Side effects: drains the COPY response fully before returning.
pub async fn CopyOutStream::collect(self : CopyOutStream) -> Array[Bytes] {
  let chunks = self.raw.collect()
  self.completed.val = true
  chunks
}

///|
/// Drain this scoped COPY OUT stream to completion.
pub async fn CopyOutStream::finish(self : CopyOutStream) -> Unit {
  self.raw.finish()
  self.completed.val = true
}

///|
/// Detach background draining for this scoped COPY OUT stream.
///
/// After detaching, direct use fails with `PoolError::LeaseReleased`, and pool
/// cleanup waits for the detached task before reusing the connection.
pub fn CopyOutStream::detach(self : CopyOutStream) -> Unit {
  if self.completed.val || self.detached_task.val is Some(_) {
    return
  }
  let task = self.group.spawn(no_wait=true, allow_failure=true, () => {
    self.raw.finish()
    self.completed.val = true
  })
  self.detached_task.val = Some(task)
}

///|
/// Finish or abort the COPY IN sink before the pooled callback returns.
async fn CopyInSink::finish_scope(self : CopyInSink) -> Unit {
  if self.finished.val {
    return
  }
  self.finished.val = true
  self.raw.abort(message="pool scope ended before copy was finished")
}

///|
/// Ignore COPY IN cleanup failures when another error already won.
async fn CopyInSink::finish_scope_best_effort(self : CopyInSink) -> Unit {
  try
    @async.protect_from_cancel(() => self.finish_scope(), resume_on_cancel=true)
  catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// Send one chunk into the active COPY FROM STDIN operation.
///
/// Preconditions: the COPY sink must still be active. After `finish()`,
/// `abort()`, or callback-scope cleanup, further behavior follows the
/// underlying raw sink and may raise.
pub async fn CopyInSink::send(self : CopyInSink, data : BytesView) -> Unit {
  self.raw.send(data)
}

///|
/// Finish the active COPY FROM STDIN operation and return PostgreSQL's row count.
///
/// Side effects: marks the sink as finished so scope cleanup stops aborting it.
pub async fn CopyInSink::finish(self : CopyInSink) -> Int {
  self.finished.val = true
  self.raw.finish()
}

///|
/// Abort the active COPY FROM STDIN operation.
///
/// If the sink was not finished yet, this marks it finished and sends the abort
/// request. If the sink was already finished, the abort is still forwarded to
/// the raw sink, so repeated calls follow the raw client's edge-case behavior
/// instead of silently becoming a no-op.
pub async fn CopyInSink::abort(
  self : CopyInSink,
  message? : String = "COPY aborted",
) -> Unit {
  if self.finished.val {
    self.raw.abort(message~)
    return
  }
  self.finished.val = true
  self.raw.abort(message~)
}

///|
/// Run one pooled row-stream callback and guarantee cleanup.
async fn[T] run_row_stream_callback(
  stream : RowStream,
  f : async (RowStream) -> T,
) -> T {
  try {
    let result = @async.protect_from_cancel(
      () => f(stream),
      resume_on_cancel=true,
    )
    stream.finish_scope()
    result
  } catch {
    err => {
      stream.finish_scope_best_effort()
      raise err
    }
  }
}

///|
/// Run one pooled simple-query callback and guarantee cleanup.
async fn[T] run_simple_query_callback(
  stream : SimpleQueryStream,
  f : async (SimpleQueryStream) -> T,
) -> T {
  try {
    let result = @async.protect_from_cancel(
      () => f(stream),
      resume_on_cancel=true,
    )
    stream.finish_scope()
    result
  } catch {
    err => {
      stream.finish_scope_best_effort()
      raise err
    }
  }
}

///|
/// Run one pooled COPY OUT callback and guarantee cleanup.
async fn[T] run_copy_out_callback(
  stream : CopyOutStream,
  f : async (CopyOutStream) -> T,
) -> T {
  try {
    let result = @async.protect_from_cancel(
      () => f(stream),
      resume_on_cancel=true,
    )
    stream.finish_scope()
    result
  } catch {
    err => {
      stream.finish_scope_best_effort()
      raise err
    }
  }
}

///|
/// Run one pooled COPY IN callback and guarantee cleanup.
async fn[T] run_copy_in_callback(
  sink : CopyInSink,
  f : async (CopyInSink) -> T,
) -> T {
  try {
    let result = @async.protect_from_cancel(
      () => f(sink),
      resume_on_cancel=true,
    )
    sink.finish_scope()
    result
  } catch {
    err => {
      sink.finish_scope_best_effort()
      raise err
    }
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
/// Mark this pooled client lease for release.
///
/// Side effects: new scoped operations start failing with `PoolError::LeaseReleased`.
/// Existing in-flight operations are allowed to finish first, and the physical
/// connection is returned to the pool only after the active-operation count
/// reaches zero. Repeated calls are idempotent.
pub fn Client::release(self : Client) -> Unit {
  if self.state.releasing.val || self.state.released.val {
    return
  }
  self.state.releasing.val = true
  if self.state.active_ops.val == 0 {
    self.state.finalize_release()
  }
}

///|
/// Permanently detach the raw client from pool management.
///
/// Preconditions: the lease must still be active, and no operation,
/// transaction-building scope, or cancellable scope may be in progress.
/// Side effects: the pool forgets this physical connection, frees one capacity
/// slot, and stops recycling or closing the detached client for you. The caller
/// becomes responsible for closing the returned raw client. The returned
/// `@client.Client` keeps using the existing background connection driver, so it
/// can continue ordinary client operations immediately after detaching.
pub fn Client::detach_raw(self : Client) -> @client.Client raise {
  if self.state.releasing.val || self.state.released.val {
    raise PoolError::LeaseReleased
  }
  if self.state.scope_active.val || self.state.active_ops.val > 0 {
    raise PoolError::OperationInProgress
  }
  let client = match self.state.connection.client.val {
    Some(client) => client
    None => raise PoolError::LeaseReleased
  }
  self.state.releasing.val = true
  self.state.released.val = true
  retire_connection(self.state.pool, self.state.connection, close_client=false)
  restore_available_slot(self.state.pool)
  client
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
/// Run one callback inside an exclusive cancellable request scope.
///
/// Preconditions: the client lease must still be active and no other exclusive
/// scope may already be open on it. During the callback, requests issued through
/// `Operation` run one at a time so `OperationCancelToken::cancel()` can target
/// the current request. When the callback finishes, the cancel token becomes
/// inert and the scope waits for any late cancel-send task to finish. A common
/// pattern is to pass the token to another task or timeout handler while the
/// callback uses `Operation` for the actual query work.
pub async fn[T] Client::run_cancellable(
  self : Client,
  f : async (Operation, OperationCancelToken) -> T,
) -> T {
  let connection = self.state.begin_cancellable_scope()
  defer self.state.finish_cancellable_scope()
  @async.protect_from_cancel(
    () => run_cancellable_scope(connection, f),
    resume_on_cancel=true,
  )
}

///|
/// Run one callback with an extended-query row stream on this lease.
///
/// Side effects: opens a protocol stream that keeps the physical connection busy
/// until the stream is drained, finished, or detached into background cleanup.
/// The helper guarantees stream cleanup before the lease becomes reusable.
pub async fn[T] Client::with_stream(
  self : Client,
  sql : String,
  params? : Array[&@client.ToSql] = [],
  f : async (RowStream) -> T,
) -> T {
  let client = self.state.begin_operation()
  defer self.state.finish_operation()
  let stream = make_row_stream(
    self.state.connection.group,
    client.query(sql, params~),
  )
  run_row_stream_callback(stream, f)
}

///|
/// Run one callback with a typed extended-query row stream on this lease.
///
/// `param_types` is passed to PostgreSQL when preparing the typed query. As with
/// `with_stream`, the helper guarantees cleanup of unfinished stream state.
pub async fn[T] Client::with_typed_stream(
  self : Client,
  sql : String,
  param_types : Array[@client.Type],
  params? : Array[&@client.ToSql] = [],
  f : async (RowStream) -> T,
) -> T {
  let client = self.state.begin_operation()
  defer self.state.finish_operation()
  let stream = make_row_stream(
    self.state.connection.group,
    client.query_typed(sql, param_types, params~),
  )
  run_row_stream_callback(stream, f)
}

///|
/// Run one callback with a simple-query protocol stream on this lease.
///
/// The callback may read messages incrementally, collect them, finish the
/// stream, or detach cleanup into the background.
pub async fn[T] Client::with_simple_query(
  self : Client,
  sql : String,
  f : async (SimpleQueryStream) -> T,
) -> T {
  let client = self.state.begin_operation()
  defer self.state.finish_operation()
  let stream = make_simple_query_stream(
    self.state.connection.group,
    client.simple_query(sql),
  )
  run_simple_query_callback(stream, f)
}

///|
/// Run one callback with a COPY FROM STDIN sink on this lease.
///
/// The callback should normally call `finish()` or `abort()` explicitly. If it
/// returns with COPY still open, the pool aborts the COPY operation before the
/// lease is reused.
pub async fn[T] Client::with_copy_in(
  self : Client,
  sql : String,
  f : async (CopyInSink) -> T,
) -> T {
  let client = self.state.begin_operation()
  defer self.state.finish_operation()
  let sink = make_copy_in_sink(client.copy_in(sql))
  run_copy_in_callback(sink, f)
}

///|
/// Run one callback with a COPY TO STDOUT stream on this lease.
///
/// As with other scoped stream helpers, unfinished stream state is cleaned up
/// automatically before the lease can be reused.
pub async fn[T] Client::with_copy_out(
  self : Client,
  sql : String,
  f : async (CopyOutStream) -> T,
) -> T {
  let client = self.state.begin_operation()
  defer self.state.finish_operation()
  let stream = make_copy_out_stream(
    self.state.connection.group,
    client.copy_out(sql),
  )
  run_copy_out_callback(stream, f)
}

///|
/// Run one query on this lease and collect all rows before returning.
///
/// Side effects: fully drains the query result, so no stream state escapes the
/// call boundary.
pub async fn Client::query_all(
  self : Client,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> Array[@client.Row] {
  self.run_operation(client => client.query(sql, params~).collect())
}

///|
/// Run one query and require exactly one row.
///
/// Row-count behavior follows the underlying `@client.Client::query_one`.
pub async fn Client::query_one(
  self : Client,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> @client.Row {
  self.run_operation(client => client.query_one(sql, params~))
}

///|
/// Run one query and allow zero or one rows.
///
/// Row-count behavior follows the underlying `@client.Client::query_opt`.
pub async fn Client::query_opt(
  self : Client,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> @client.Row? {
  self.run_operation(client => client.query_opt(sql, params~))
}

///|
/// Run one typed query and collect all rows before returning.
pub async fn Client::query_typed_all(
  self : Client,
  sql : String,
  param_types : Array[@client.Type],
  params? : Array[&@client.ToSql] = [],
) -> Array[@client.Row] {
  self.run_operation(client => {
    client.query_typed(sql, param_types, params~).collect()
  })
}

///|
/// Execute one command on this lease and return its affected row count.
pub async fn Client::execute(
  self : Client,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> Int {
  self.run_operation(client => client.execute(sql, params~))
}

///|
/// Execute one or more SQL commands without returning row data.
///
/// Side effects follow PostgreSQL `batch_execute`: every command in `sql` runs
/// on the current session in order.
pub async fn Client::batch_execute(self : Client, sql : String) -> Unit {
  self.run_operation(client => client.batch_execute(sql))
}

///|
/// Perform a lightweight connection health check on this lease.
pub async fn Client::check_connection(self : Client) -> Unit {
  self.run_operation(client => client.check_connection())
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
/// Run one request in the cancellable scope and collect all rows.
///
/// Preconditions: the surrounding `run_cancellable` scope must still be active.
/// Only one request may be in flight on the `Operation` at a time.
pub async fn Operation::query_all(
  self : Operation,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> Array[@client.Row] {
  self.run_request(client => client.query(sql, params~).collect())
}

///|
/// Run one request in the cancellable scope and require exactly one row.
pub async fn Operation::query_one(
  self : Operation,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> @client.Row {
  self.run_request(client => client.query_one(sql, params~))
}

///|
/// Run one request in the cancellable scope and allow zero or one rows.
pub async fn Operation::query_opt(
  self : Operation,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> @client.Row? {
  self.run_request(client => client.query_opt(sql, params~))
}

///|
/// Run one typed request in the cancellable scope and collect all rows.
pub async fn Operation::query_typed_all(
  self : Operation,
  sql : String,
  param_types : Array[@client.Type],
  params? : Array[&@client.ToSql] = [],
) -> Array[@client.Row] {
  self.run_request(client => {
    client.query_typed(sql, param_types, params~).collect()
  })
}

///|
/// Execute one command in the cancellable scope and return its affected row count.
pub async fn Operation::execute(
  self : Operation,
  sql : String,
  params? : Array[&@client.ToSql] = [],
) -> Int {
  self.run_request(client => client.execute(sql, params~))
}

///|
/// Execute one or more SQL commands inside the cancellable scope.
pub async fn Operation::batch_execute(self : Operation, sql : String) -> Unit {
  self.run_request(client => client.batch_execute(sql))
}

///|
/// Perform a lightweight health check inside the cancellable scope.
pub async fn Operation::check_connection(self : Operation) -> Unit {
  self.run_request(client => client.check_connection())
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
/// Best-effort cancel the request currently running inside the paired `Operation`.
///
/// Edge cases: if the scope is already closing, no request is in flight, or the
/// current request was already cancelled through this token, the call is a
/// no-op. Any backend error while sending the cancel packet is suppressed.
pub async fn OperationCancelToken::cancel(self : OperationCancelToken) -> Unit {
  if !self.state.active.val || self.state.closing.val {
    return
  }
  if !self.state.request_in_flight.val {
    return
  }
  let request_id = self.state.active_request_id.val
  if request_id == 0 || request_id <= self.state.last_cancelled_request_id.val {
    return
  }
  self.state.last_cancelled_request_id.val = request_id
  self.state.cancel_in_flight.val += 1
  defer (if self.state.cancel_in_flight.val > 0 {
    self.state.cancel_in_flight.val -= 1
  })
  try
    @async.protect_from_cancel(
      () => self.state.cancel_token.cancel(),
      resume_on_cancel=true,
    )
  catch {
    _ => ()
  } noraise {
    _ => ()
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
/// Run one callback with an extended-query row stream inside this transaction.
///
/// The stream is callback-scoped and cleaned up before the transaction becomes
/// available for later operations.
pub async fn[T] Transaction::with_stream(
  self : Transaction,
  sql : String,
  params? : Array[&@client.ToSql] = [],
  f : async (RowStream) -> T,
) -> T {
  let transaction = self.state.begin_operation()
  defer self.state.finish_operation()
  let stream = make_row_stream(
    self.state.connection.group,
    transaction.query(sql, params~),
  )
  run_row_stream_callback(stream, f)
}

///|
/// Run one callback with a typed extended-query row stream inside this transaction.
///
/// Side effects: prepares a temporary typed statement, uses it to create the
/// stream, and closes that statement during stream cleanup.
pub async fn[T] Transaction::with_typed_stream(
  self : Transaction,
  sql : String,
  param_types : Array[@client.Type],
  params? : Array[&@client.ToSql] = [],
  f : async (RowStream) -> T,
) -> T {
  let transaction = self.state.begin_operation()
  defer self.state.finish_operation()
  let statement = transaction.prepare_typed(sql, param_types)
  try {
    let stream = make_row_stream(
      self.state.connection.group,
      transaction.query_statement(statement, params~),
      cleanup=Some(() => statement.close()),
    )
    run_row_stream_callback(stream, f)
  } catch {
    err => {
      close_statement_best_effort(statement)
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
/// Fetch rows from this portal and expose them as a callback-scoped row stream.
///
/// Preconditions: the portal must not already be closed. `max_rows` is passed
/// directly to PostgreSQL's portal fetch. The portal itself remains open after
/// the row-stream callback ends, so callers may fetch again or close it
/// explicitly.
pub async fn[T] Portal::with_stream(
  self : Portal,
  max_rows : Int,
  f : async (RowStream) -> T,
) -> T {
  if self.closed.val {
    raise PoolError::LeaseReleased
  }
  let raw = self.scope.run_request(
    client => client.query_portal(self.raw, max_rows),
    transaction => transaction.query_portal(self.raw, max_rows),
  )
  let stream = make_row_stream(self.scope.group(), raw)
  run_row_stream_callback(stream, f)
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

///|
/// Pooled clients implement the shared high-level query trait.
pub impl GenericClient for Client with query_all(self, sql, params?) {
  self.query_all(sql, params=params.unwrap_or([]))
}

///|
/// Pooled clients implement the shared high-level query trait.
pub impl GenericClient for Client with query_one(self, sql, params?) {
  self.query_one(sql, params=params.unwrap_or([]))
}

///|
/// Pooled clients implement the shared high-level query trait.
pub impl GenericClient for Client with query_opt(self, sql, params?) {
  self.query_opt(sql, params=params.unwrap_or([]))
}

///|
/// Pooled clients implement the shared high-level query trait.
pub impl GenericClient for Client with query_typed_all(
  self,
  sql,
  param_types,
  params?,
) {
  self.query_typed_all(sql, param_types, params=params.unwrap_or([]))
}

///|
/// Pooled clients implement the shared high-level query trait.
pub impl GenericClient for Client with execute(self, sql, params?) {
  self.execute(sql, params=params.unwrap_or([]))
}

///|
/// Pooled clients implement the shared high-level query trait.
pub impl GenericClient for Client with batch_execute(self, sql) {
  self.batch_execute(sql)
}

///|
/// Pooled clients implement the shared high-level query trait.
pub impl GenericClient for Client with check_connection(self) {
  self.check_connection()
}

///|
/// Pooled transactions implement the shared high-level query trait.
pub impl GenericClient for Transaction with query_all(self, sql, params?) {
  self.query_all(sql, params=params.unwrap_or([]))
}

///|
/// Pooled transactions implement the shared high-level query trait.
pub impl GenericClient for Transaction with query_one(self, sql, params?) {
  self.query_one(sql, params=params.unwrap_or([]))
}

///|
/// Pooled transactions implement the shared high-level query trait.
pub impl GenericClient for Transaction with query_opt(self, sql, params?) {
  self.query_opt(sql, params=params.unwrap_or([]))
}

///|
/// Pooled transactions implement the shared high-level query trait.
pub impl GenericClient for Transaction with query_typed_all(
  self,
  sql,
  param_types,
  params?,
) {
  self.query_typed_all(sql, param_types, params=params.unwrap_or([]))
}

///|
/// Pooled transactions implement the shared high-level query trait.
pub impl GenericClient for Transaction with execute(self, sql, params?) {
  self.execute(sql, params=params.unwrap_or([]))
}

///|
/// Pooled transactions implement the shared high-level query trait.
pub impl GenericClient for Transaction with batch_execute(self, sql) {
  self.batch_execute(sql)
}

///|
/// Pooled transactions implement the shared high-level query trait.
pub impl GenericClient for Transaction with check_connection(self) {
  self.check_connection()
}
