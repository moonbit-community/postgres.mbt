// Callback-scoped streaming and COPY operations.

///|
/// Finish a row stream while preserving an earlier callback error.
async fn finish_row_stream_best_effort(stream : @client.RowStream) -> Unit {
  try @async.protect_from_cancel(() => ignore(stream.finish())) catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// Run a callback and guarantee that its row stream reaches a terminal state.
async fn[T] with_row_stream(
  stream : @client.RowStream,
  f : async (@client.RowStream) -> T,
) -> T {
  errdefer finish_row_stream_best_effort(stream)
  check_pending_cancellation()
  let result = f(stream)
  check_pending_cancellation()
  {
    defer check_pending_cancellation()
    @async.protect_from_cancel(() => ignore(stream.finish()))
  }
  result
}

///|
/// Run one callback with an extended-query row stream on this session.
pub async fn[T] Session::with_stream(
  self : Session,
  sql : String,
  params? : Array[&@client.ToSql] = [],
  f : async (@client.RowStream) -> T,
) -> T {
  self.with_prepared(sql, prepared => prepared.with_stream(params~, f))
}

///|
/// Run one callback with a typed extended-query row stream on this session.
pub async fn[T] Session::with_typed_stream(
  self : Session,
  sql : String,
  param_types : Array[@client.Type],
  params? : Array[&@client.ToSql] = [],
  f : async (@client.RowStream) -> T,
) -> T {
  self.with_prepared_typed(sql, param_types, prepared => {
    prepared.with_stream(params~, f)
  })
}

///|
/// Run one callback with a simple-query protocol stream on this session.
pub async fn[T] Session::with_simple_query(
  self : Session,
  sql : String,
  f : async (@client.SimpleQueryStream) -> T,
) -> T {
  self.run_scoped_operation(client => client.with_simple_query(sql, f))
}

///|
/// Run one callback with a COPY FROM STDIN sink on this session.
pub async fn[T] Session::with_copy_in(
  self : Session,
  sql : String,
  f : async (@client.CopyInSink) -> T,
) -> T {
  self.run_scoped_operation(client => client.with_copy_in(sql, f))
}

///|
/// Run one callback with a COPY TO STDOUT stream on this session.
pub async fn[T] Session::with_copy_out(
  self : Session,
  sql : String,
  f : async (@client.CopyOutStream) -> T,
) -> T {
  self.run_scoped_operation(client => client.with_copy_out(sql, f))
}

///|
/// Run one callback with an extended-query row stream in this transaction.
pub async fn[T] Transaction::with_stream(
  self : Transaction,
  sql : String,
  params? : Array[&@client.ToSql] = [],
  f : async (@client.RowStream) -> T,
) -> T {
  self.with_prepared(sql, prepared => prepared.with_stream(params~, f))
}

///|
/// Run one typed row-stream callback in this transaction.
pub async fn[T] Transaction::with_typed_stream(
  self : Transaction,
  sql : String,
  param_types : Array[@client.Type],
  params? : Array[&@client.ToSql] = [],
  f : async (@client.RowStream) -> T,
) -> T {
  self.with_prepared_typed(sql, param_types, prepared => {
    prepared.with_stream(params~, f)
  })
}
