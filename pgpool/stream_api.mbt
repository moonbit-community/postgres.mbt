// Scoped row, simple-query, and COPY stream APIs.

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
