// Callback-scoped streaming and COPY operations.

///|
/// Finish a row stream while preserving an earlier callback error.
async fn finish_row_stream_best_effort(stream : @client.RowStream) -> Unit {
  try
    @async.protect_from_cancel(
      () => ignore(stream.finish()),
      resume_on_cancel=true,
    )
  catch {
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
  try {
    let result = @async.protect_from_cancel(
      () => f(stream),
      resume_on_cancel=true,
    )
    ignore(stream.finish())
    result
  } catch {
    err => {
      finish_row_stream_best_effort(stream)
      raise err
    }
  }
}

///|
/// Finish a simple-query stream while preserving an earlier callback error.
async fn finish_simple_stream_best_effort(
  stream : @client.SimpleQueryStream,
) -> Unit {
  try
    @async.protect_from_cancel(() => stream.finish(), resume_on_cancel=true)
  catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// Run a callback and guarantee that its simple-query stream is drained.
async fn[T] with_simple_stream(
  stream : @client.SimpleQueryStream,
  f : async (@client.SimpleQueryStream) -> T,
) -> T {
  try {
    let result = @async.protect_from_cancel(
      () => f(stream),
      resume_on_cancel=true,
    )
    stream.finish()
    result
  } catch {
    err => {
      finish_simple_stream_best_effort(stream)
      raise err
    }
  }
}

///|
/// Finish a COPY OUT stream while preserving an earlier callback error.
async fn finish_copy_out_best_effort(stream : @client.CopyOutStream) -> Unit {
  try
    @async.protect_from_cancel(() => stream.finish(), resume_on_cancel=true)
  catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// Run a callback and guarantee that its COPY OUT stream is drained.
async fn[T] with_copy_out_stream(
  stream : @client.CopyOutStream,
  f : async (@client.CopyOutStream) -> T,
) -> T {
  try {
    let result = @async.protect_from_cancel(
      () => f(stream),
      resume_on_cancel=true,
    )
    stream.finish()
    result
  } catch {
    err => {
      finish_copy_out_best_effort(stream)
      raise err
    }
  }
}

///|
/// Abort unfinished COPY IN work while preserving an earlier callback error.
async fn abort_copy_in_best_effort(sink : @client.CopyInSink) -> Unit {
  try
    @async.protect_from_cancel(() => sink.abort(), resume_on_cancel=true)
  catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// Run a callback and abort COPY IN if the callback did not finish it.
async fn[T] with_copy_in_sink(
  sink : @client.CopyInSink,
  f : async (@client.CopyInSink) -> T,
) -> T {
  try {
    let result = @async.protect_from_cancel(
      () => f(sink),
      resume_on_cancel=true,
    )
    sink.abort()
    result
  } catch {
    err => {
      abort_copy_in_best_effort(sink)
      raise err
    }
  }
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
  self.run_operation(client => with_simple_stream(client.simple_query(sql), f))
}

///|
/// Run one callback with a COPY FROM STDIN sink on this session.
pub async fn[T] Session::with_copy_in(
  self : Session,
  sql : String,
  f : async (@client.CopyInSink) -> T,
) -> T {
  self.run_operation(client => with_copy_in_sink(client.copy_in(sql), f))
}

///|
/// Run one callback with a COPY TO STDOUT stream on this session.
pub async fn[T] Session::with_copy_out(
  self : Session,
  sql : String,
  f : async (@client.CopyOutStream) -> T,
) -> T {
  self.run_operation(client => with_copy_out_stream(client.copy_out(sql), f))
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
