// Stream capabilities share the owning connection but have a separate
// per-handle gate. A handle expires before protocol cleanup begins.

///|
priv struct StreamScope {
  owner : ClientLeaseState
  active : @ref.Ref[Bool]
  gate : @async.Mutex
}

///|
fn StreamScope::check(self : StreamScope) -> Unit raise {
  self.owner.assert_active()
  if !self.active.val {
    raise PoolError::ScopeExpired
  }
}

///|
async fn[T] StreamScope::run(
  self : StreamScope,
  f : async () -> T,
  deadline? : Deadline,
) -> T {
  self.check()
  if !self.gate.try_acquire() {
    raise PoolError::OperationInProgress
  }
  defer self.gate.release()
  errdefer self.owner.cleanup_best_effort(() => self.owner.cancel_active())
  self.owner.supervise_worker(f, deadline?, protect=false)
}

///|
/// A returned SQL error means synchronization and resource cleanup succeeded.
/// Raised cleanup failures still retire the connection through owner.cleanup.
async fn[R, T] resource_scope(
  owner : ClientLeaseState,
  callback_error : @ref.Ref[Error?],
  acquire : async () -> R,
  finish : async (R) -> @client.DatabaseError?,
  f : async (R, StreamScope) -> T,
) -> T {
  let raw = @async.protect_from_cancel(acquire)
  let scope : StreamScope = { owner, active: Ref(true), gate: Mutex(), }
  let cleanup = () => {
    scope.active.val = false
    owner.cleanup(() => {
      if !scope.gate.try_acquire() {
        owner.scoped_client().abort()
        raise PoolError::OperationInProgress
      }
      defer scope.gate.release()
      finish(raw)
    })
  }
  let result = with_scope_exit(
    () => {
      let outcome = try f(raw, scope) catch {
        error => Err(error)
      } noraise {
        value => Ok(value)
      }
      match outcome {
        Ok(value) => value
        Err(error) => {
          // Publish before cleanup suspends so the supervising waiter can
          // preserve a callback exception across later task cancellation.
          callback_error.val = Some(error)
          raise error
        }
      }
    },
    // A synchronized SQL failure is reported outside owner.cleanup, so it
    // does not retire the socket or repeat cleanup during error propagation.
    _ => if cleanup() is Some(error) { raise error.into_client_error() },
    () => ignore(cleanup()),
  )
  if !owner.cleanup_mode {
    owner.cleanup_deadline.val = None
  }
  result
}

///|
struct RowStream {
  raw : @client.RowStream
  scope : StreamScope
}

///|
pub async fn RowStream::next(
  self : RowStream,
  deadline? : Deadline,
) -> @client.Row? {
  self.scope.run(() => self.raw.next(), deadline?)
}

///|
pub async fn RowStream::finish(
  self : RowStream,
  deadline? : Deadline,
) -> @client.QuerySummary {
  self.scope.run(() => self.raw.finish(), deadline?)
}

///|
pub async fn RowStream::collect(
  self : RowStream,
  deadline? : Deadline,
) -> Array[@client.Row] {
  self.scope.run(() => self.raw.collect(), deadline?)
}

///|
pub async fn RowStream::one(
  self : RowStream,
  deadline? : Deadline,
) -> @client.Row {
  self.scope.run(() => self.raw.one(), deadline?)
}

///|
pub async fn RowStream::opt(
  self : RowStream,
  deadline? : Deadline,
) -> @client.Row? {
  self.scope.run(() => self.raw.opt(), deadline?)
}

///|
struct SimpleQueryStream {
  raw : @client.SimpleQueryStream
  scope : StreamScope
}

///|
pub async fn SimpleQueryStream::next(
  self : SimpleQueryStream,
  deadline? : Deadline,
) -> @client.SimpleQueryMessage? {
  self.scope.run(() => self.raw.next(), deadline?)
}

///|
pub async fn SimpleQueryStream::finish(
  self : SimpleQueryStream,
  deadline? : Deadline,
) -> Unit {
  self.scope.run(() => self.raw.finish(), deadline?)
}

///|
pub async fn SimpleQueryStream::collect(
  self : SimpleQueryStream,
  deadline? : Deadline,
) -> Array[@client.SimpleQueryMessage] {
  self.scope.run(() => self.raw.collect(), deadline?)
}

///|
struct CopyInSink {
  raw : @client.CopyInSink
  scope : StreamScope
}

///|
pub async fn CopyInSink::send(
  self : CopyInSink,
  data : BytesView,
  deadline? : Deadline,
) -> Unit {
  self.scope.run(() => self.raw.send(data), deadline?)
}

///|
pub async fn CopyInSink::finish(
  self : CopyInSink,
  deadline? : Deadline,
) -> UInt64 {
  self.scope.run(() => self.raw.finish(), deadline?)
}

///|
pub async fn CopyInSink::abort(
  self : CopyInSink,
  message~ : String = "COPY aborted",
  deadline? : Deadline,
) -> Unit {
  self.scope.run(() => self.raw.abort(message~), deadline?)
}

///|
struct CopyOutStream {
  raw : @client.CopyOutStream
  scope : StreamScope
}

///|
pub async fn CopyOutStream::next(
  self : CopyOutStream,
  deadline? : Deadline,
) -> Bytes? {
  self.scope.run(() => self.raw.next(), deadline?)
}

///|
pub async fn CopyOutStream::finish(
  self : CopyOutStream,
  deadline? : Deadline,
) -> Unit {
  self.scope.run(() => self.raw.finish(), deadline?)
}

///|
pub async fn CopyOutStream::collect(
  self : CopyOutStream,
  deadline? : Deadline,
) -> Array[Bytes] {
  self.scope.run(() => self.raw.collect(), deadline?)
}

///|
pub fn RowStream::columns(self : RowStream) -> ArrayView[@client.Column] raise {
  self.scope.check()
  self.raw.columns()
}

///|
pub fn CopyOutStream::formats(
  self : CopyOutStream,
) -> ArrayView[@client.WireFormat] raise {
  self.scope.check()
  self.raw.formats()
}

///|
pub async fn[T] Session::with_stream(
  self : Session,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
  f : async (RowStream) -> T,
  deadline? : Deadline,
) -> T {
  self.run_scoped_operation(
    (client, callback_error) => {
      resource_scope(
        self.state,
        callback_error,
        () => client.query(sql, params~),
        raw => raw.finish_scope(),
        (raw, scope) => f({ raw, scope, }),
      )
    },
    deadline?,
  )
}

///|
pub async fn[T] Pool::with_stream(
  self : Pool,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
  f : async (RowStream) -> T,
  deadline? : Deadline,
  timeouts? : Timeouts,
) -> T {
  self.with_session(
    session => session.with_stream(sql, params~, f),
    deadline?,
    timeouts?,
  )
}

///|
pub async fn[T] Session::with_typed_stream(
  self : Session,
  sql : String,
  param_types : Array[@client.Type],
  params~ : Array[&@client.ToSql] = [],
  f : async (RowStream) -> T,
  deadline? : Deadline,
) -> T {
  self.run_scoped_operation(
    (client, callback_error) => {
      resource_scope(
        self.state,
        callback_error,
        () => client.query_typed(sql, param_types, params~),
        raw => raw.finish_scope(),
        (raw, scope) => f({ raw, scope, }),
      )
    },
    deadline?,
  )
}

///|
pub async fn[T] Pool::with_typed_stream(
  self : Pool,
  sql : String,
  param_types : Array[@client.Type],
  params~ : Array[&@client.ToSql] = [],
  f : async (RowStream) -> T,
  deadline? : Deadline,
  timeouts? : Timeouts,
) -> T {
  self.with_session(
    session => session.with_typed_stream(sql, param_types, params~, f),
    deadline?,
    timeouts?,
  )
}

///|
pub async fn[T] Session::with_simple_query(
  self : Session,
  sql : String,
  f : async (SimpleQueryStream) -> T,
  deadline? : Deadline,
) -> T {
  self.run_scoped_operation(
    (client, callback_error) => {
      resource_scope(
        self.state,
        callback_error,
        () => client.simple_query(sql),
        raw => raw.finish_scope(),
        (raw, scope) => f({ raw, scope, }),
      )
    },
    deadline?,
  )
}

///|
pub async fn[T] Pool::with_simple_query(
  self : Pool,
  sql : String,
  f : async (SimpleQueryStream) -> T,
  deadline? : Deadline,
  timeouts? : Timeouts,
) -> T {
  self.with_session(
    session => session.with_simple_query(sql, f),
    deadline?,
    timeouts?,
  )
}

///|
pub async fn[T] Session::with_copy_in(
  self : Session,
  sql : String,
  f : async (CopyInSink) -> T,
  deadline? : Deadline,
) -> T {
  self.run_scoped_operation(
    (client, callback_error) => {
      resource_scope(
        self.state,
        callback_error,
        () => client.copy_in(sql),
        raw => {
          raw.finish_scope()
          None
        },
        (raw, scope) => f({ raw, scope, }),
      )
    },
    deadline?,
  )
}

///|
pub async fn[T] Pool::with_copy_in(
  self : Pool,
  sql : String,
  f : async (CopyInSink) -> T,
  deadline? : Deadline,
  timeouts? : Timeouts,
) -> T {
  self.with_session(
    session => session.with_copy_in(sql, f),
    deadline?,
    timeouts?,
  )
}

///|
pub async fn[T] Session::with_copy_out(
  self : Session,
  sql : String,
  f : async (CopyOutStream) -> T,
  deadline? : Deadline,
) -> T {
  self.run_scoped_operation(
    (client, callback_error) => {
      resource_scope(
        self.state,
        callback_error,
        () => client.copy_out(sql),
        raw => raw.finish_scope(),
        (raw, scope) => f({ raw, scope, }),
      )
    },
    deadline?,
  )
}

///|
pub async fn[T] Pool::with_copy_out(
  self : Pool,
  sql : String,
  f : async (CopyOutStream) -> T,
  deadline? : Deadline,
  timeouts? : Timeouts,
) -> T {
  self.with_session(
    session => session.with_copy_out(sql, f),
    deadline?,
    timeouts?,
  )
}

///|
pub async fn[T] Transaction::with_stream(
  self : Transaction,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
  f : async (RowStream) -> T,
  deadline? : Deadline,
) -> T {
  self.run_scoped_operation(
    (client, callback_error) => {
      resource_scope(
        self.state,
        callback_error,
        () => client.query(sql, params~),
        raw => raw.finish_scope(),
        (raw, scope) => f({ raw, scope, }),
      )
    },
    deadline?,
  )
}

///|
pub async fn[T] Transaction::with_typed_stream(
  self : Transaction,
  sql : String,
  param_types : Array[@client.Type],
  params~ : Array[&@client.ToSql] = [],
  f : async (RowStream) -> T,
  deadline? : Deadline,
) -> T {
  self.run_scoped_operation(
    (client, callback_error) => {
      resource_scope(
        self.state,
        callback_error,
        () => client.query_typed(sql, param_types, params~),
        raw => raw.finish_scope(),
        (raw, scope) => f({ raw, scope, }),
      )
    },
    deadline?,
  )
}

///|
pub async fn[T] Transaction::with_simple_query(
  self : Transaction,
  sql : String,
  f : async (SimpleQueryStream) -> T,
  deadline? : Deadline,
) -> T {
  self.run_scoped_operation(
    (client, callback_error) => {
      resource_scope(
        self.state,
        callback_error,
        () => client.simple_query(sql),
        raw => raw.finish_scope(),
        (raw, scope) => f({ raw, scope, }),
      )
    },
    deadline?,
  )
}

///|
pub async fn[T] Transaction::with_copy_in(
  self : Transaction,
  sql : String,
  f : async (CopyInSink) -> T,
  deadline? : Deadline,
) -> T {
  self.run_scoped_operation(
    (client, callback_error) => {
      resource_scope(
        self.state,
        callback_error,
        () => client.copy_in(sql),
        raw => {
          raw.finish_scope()
          None
        },
        (raw, scope) => f({ raw, scope, }),
      )
    },
    deadline?,
  )
}

///|
pub async fn[T] Transaction::with_copy_out(
  self : Transaction,
  sql : String,
  f : async (CopyOutStream) -> T,
  deadline? : Deadline,
) -> T {
  self.run_scoped_operation(
    (client, callback_error) => {
      resource_scope(
        self.state,
        callback_error,
        () => client.copy_out(sql),
        raw => raw.finish_scope(),
        (raw, scope) => f({ raw, scope, }),
      )
    },
    deadline?,
  )
}

///|
/// Stream one prepared execution. SQLSTATE 26000 and 0A000 invalidate the
/// cached handle even when first observed during cleanup; SQL is not retried.
pub async fn[T] PreparedStatement::with_stream(
  self : PreparedStatement,
  params~ : Array[&@client.ToSql] = [],
  f : async (RowStream) -> T,
  deadline? : Deadline,
) -> T {
  if !self.state.active.val {
    raise PoolError::ScopeExpired
  }
  let state = self.state.scope.state()
  let session : Session = { state, }
  session.run_scoped_operation(
    (client, callback_error) => {
      resource_scope(
        state,
        callback_error,
        () => {
          let outcome = try
            client.query_statement(self.state.raw_statement(), params~)
          catch {
            error => Err(error)
          } noraise {
            stream => Ok(stream)
          }
          match outcome {
            Ok(stream) => stream
            Err(error) => {
              invalidate_handle(state, self.state.handle, error)
              raise error
            }
          }
        },
        raw => {
          let database_error = raw.finish_scope()
          if database_error is Some(error) {
            invalidate_handle(
              state,
              self.state.handle,
              error.into_client_error(),
            )
          }
          database_error
        },
        (raw, scope) => f({ raw, scope, }),
      )
    },
    deadline?=earlier_deadline(self.state.deadline, deadline),
  )
}

///|
pub async fn[T] Pool::with_prepared(
  self : Pool,
  sql : String,
  f : async (PreparedStatement) -> T,
  deadline? : Deadline,
  timeouts? : Timeouts,
) -> T {
  self.with_session(
    session => session.with_prepared(sql, f),
    deadline?,
    timeouts?,
  )
}

///|
pub async fn[T] Pool::with_prepared_typed(
  self : Pool,
  sql : String,
  param_types : Array[@client.Type],
  f : async (PreparedStatement) -> T,
  deadline? : Deadline,
  timeouts? : Timeouts,
) -> T {
  self.with_session(
    session => session.with_prepared_typed(sql, param_types, f),
    deadline?,
    timeouts?,
  )
}
