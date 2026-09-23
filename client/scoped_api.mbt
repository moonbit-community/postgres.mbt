// Scoped ownership of one client stream or COPY exchange.

///|
async fn[R, T] Client::with_scoped_resource(
  self : Client,
  acquire : async (OpContext, OperationPermit) -> R,
  finalize : async (R) -> Unit,
  f : async (R) -> T,
) -> T {
  // Waiting for readiness and the operation gate remains cancellable. Protect
  // only protocol startup, so cancellation cannot strand an undelivered handle.
  let (context, permit) = self.begin_stream_operation()
  let resource = {
    errdefer permit.release()
    @async.protect_from_cancel(() => acquire(context, permit))
  }
  errdefer @async.protect_from_cancel(() => {
    let _ = finalize(resource) catch { _ => () }
  })
  check_pending_cancellation()
  let result = f(resource)
  check_pending_cancellation()
  // Also observe cancellation received while cleanup was protected, even if
  // cleanup itself fails. An error from f keeps its original cause instead.
  {
    defer check_pending_cancellation()
    @async.protect_from_cancel(() => finalize(resource))
  }
  result
}

///|
/// Execute a query in a scope and return the callback's result.
///
/// The callback remains cancellable. On return, error, or cancellation, finish
/// the stream and close its temporary statement under cancellation protection.
/// Cleanup errors propagate on success, but never replace a callback error or
/// cancellation. Cleanup waits for ReadyForQuery and does not send CancelRequest.
pub async fn[T] Client::with_stream(
  self : Client,
  sql : String,
  params? : Array[&ToSql] = [],
  f : async (RowStream) -> T,
) -> T {
  self.with_scoped_resource(
    (context, permit) => context.query(sql, params, permit~),
    stream => ignore(stream.finish()),
    f,
  )
}

///|
/// Like `with_stream`, with explicit PostgreSQL parameter types.
pub async fn[T] Client::with_typed_stream(
  self : Client,
  sql : String,
  param_types : Array[Type],
  params? : Array[&ToSql] = [],
  f : async (RowStream) -> T,
) -> T {
  self.with_scoped_resource(
    (context, permit) => context.query_typed(sql, param_types, params, permit~),
    stream => ignore(stream.finish()),
    f,
  )
}

///|
/// Execute a prepared statement with the cleanup semantics of `with_stream`.
/// Only this execution stream is finished; the caller retains the statement.
pub async fn[T] Client::with_statement_stream(
  self : Client,
  statement : Statement,
  params? : Array[&ToSql] = [],
  f : async (RowStream) -> T,
) -> T {
  self.with_scoped_resource(
    (context, permit) => context.query_statement(statement, params, permit~),
    stream => ignore(stream.finish()),
    f,
  )
}

///|
/// Consume simple-query frames in a cancellable callback and return its result.
/// Finish the stream on every exit, with the same error and cancellation
/// semantics as `with_stream`.
pub async fn[T] Client::with_simple_query(
  self : Client,
  sql : String,
  f : async (SimpleQueryStream) -> T,
) -> T {
  self.with_scoped_resource(
    (_, permit) => {
      let responses = self.send_request(Messages, simple_query_bytes(sql))
      SimpleQueryStream::new(self.shared.control, responses, Some(permit))
    },
    stream => stream.finish(),
    f,
  )
}

///|
/// Produce COPY input in a cancellable callback and return its result.
///
/// The callback must explicitly call `sink.finish()` to commit the COPY. An
/// unfinished sink is aborted on return, error, or cancellation. Protected
/// cleanup waits for protocol completion and preserves the callback's error.
pub async fn[T] Client::with_copy_in(
  self : Client,
  sql : String,
  f : async (CopyInSink) -> T,
) -> T {
  self.with_scoped_resource(
    (context, permit) => context.copy_in(sql, permit),
    sink => {
      sink.abort()
      // send/finish/abort may already have handed cleanup to the driver when
      // the callback was cancelled. The scope still waits for that cleanup.
      if sink.abandoned_done.val is Some(done) {
        done.wait()
      }
    },
    f,
  )
}

///|
/// Consume COPY output in a cancellable callback and return its result.
/// Finish the stream on every exit, with the same error and cancellation
/// semantics as `with_stream`.
pub async fn[T] Client::with_copy_out(
  self : Client,
  sql : String,
  f : async (CopyOutStream) -> T,
) -> T {
  self.with_scoped_resource(
    (_, permit) => {
      let responses = self.send_request(Messages, simple_query_bytes(sql))
      start_copy_out(self.shared.control, responses, Some(permit))
    },
    stream => stream.finish(),
    f,
  )
}
