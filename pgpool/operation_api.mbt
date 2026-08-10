// Cancellable pooled operation API.

///|
/// Wait for any late cancel send to finish, then start one request.
async fn OperationScopeState::begin_request(
  self : OperationScopeState,
) -> @client.Client {
  if !self.active.val || self.closing.val {
    raise PoolError::ScopeExpired
  }
  while self.cancel_in_flight.val > 0 {
    if !self.active.val || self.closing.val {
      raise PoolError::ScopeExpired
    }
    @async.pause()
  }
  if !self.active.val || self.closing.val {
    raise PoolError::ScopeExpired
  }
  self.gate.acquire()
  if !self.active.val || self.closing.val {
    self.gate.release()
    raise PoolError::ScopeExpired
  }
  let client = match self.connection.client.val {
    Some(client) => client
    None => {
      self.gate.release()
      raise PoolError::ScopeExpired
    }
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
    self.gate.release()
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
/// Run one callback inside an exclusive cancellable request scope.
///
/// The scope waits in FIFO order for earlier session work. During the callback,
/// requests issued through `Operation` run one at a time so
/// `OperationCancelToken::cancel()` targets the current request. When the
/// callback finishes, the token becomes inert and late cancel work is drained.
pub async fn[T] Session::run_cancellable(
  self : Session,
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
