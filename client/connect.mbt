// Connection establishment and top-level client lifecycle APIs.

///|
/// Open a PostgreSQL connection and return both cooperating runtime handles.
///
/// The returned `Client` only enqueues work; no I/O happens unless the paired
/// `Connection` is actively driven by calling `Connection::run` in another task.
/// This split keeps request submission cheap and makes backpressure explicit.
pub async fn connect(config : Config) -> (Client, Connection) {
  let stream = connect_stream(config)
  let startup = startup(stream, config)
  let types : Map[@proto.Oid, Type] = {}
  let background_group : @ref.Ref[@async.TaskGroup[Unit]?] = @ref.new(None)
  seed_builtin_types(types)
  let shared = {
    config,
    requests: @async.Queue::new(kind=Unbounded),
    async_messages: @async.Queue::new(kind=Unbounded),
    background_group,
    parameters: startup.parameters,
    types,
    process_id: @ref.new(startup.process_id),
    secret_key: @ref.new(startup.secret_key),
    transaction_status: @ref.new(startup.transaction_status),
    closed: @ref.new(false),
    closing: @ref.new(false),
    next_id: @ref.new(0),
  }
  ({ shared, }, { shared, stream })
}

///|
/// Return whether the shared runtime has fully closed.
///
/// This becomes `true` after the connection loop exits or after a graceful
/// shutdown request has been processed to completion.
pub fn Client::is_closed(self : Client) -> Bool {
  self.shared.closed.val
}

///|
/// Request a graceful shutdown of the client runtime.
///
/// This method only enqueues a `Terminate` request; it does not block waiting
/// for the socket to close. Callers that need to observe completion should wait
/// for the `Connection::run` task to return.
pub fn Client::close(self : Client) -> Unit {
  if self.shared.closed.val || self.shared.closing.val {
    return
  }
  self.shared.closing.val = true
  let responses = @async.Queue::new(kind=Unbounded)
  try
    self.shared.requests.try_put({
      kind: RequestKind::Terminate,
      bytes: terminate_bytes(),
      responses,
      copy_input: None,
    })
  catch {
    _ => {
      self.shared.closed.val = true
      responses.close()
    }
  } noraise {
    _ => ()
  }
}

///|
/// Create a token capable of cancelling the current backend operation.
///
/// The token stays valid until the underlying connection closes. It can be
/// stored and used from another task or timeout handler when a long-running
/// query should be interrupted.
pub fn Client::cancel_token(self : Client) -> CancelToken {
  {
    config: self.shared.config,
    process_id: self.shared.process_id,
    secret_key: self.shared.secret_key,
    closed: self.shared.closed,
  }
}

///|
/// Return the backend process ID embedded in the cancellation token.
pub fn CancelToken::process_id(self : CancelToken) -> Int {
  self.process_id.val
}

///|
/// Return the backend secret key embedded in the cancellation token.
pub fn CancelToken::secret_key(self : CancelToken) -> Int {
  self.secret_key.val
}

///|
/// Reset the shared type cache to the built-in PostgreSQL descriptors only.
///
/// Use this when the application expects server-side type definitions to change
/// and wants later queries to re-fetch catalog metadata lazily.
pub fn Client::clear_type_cache(self : Client) -> Unit {
  self.shared.types.clear()
  seed_builtin_types(self.shared.types)
}

///|
/// Look up a server parameter learned during startup or later async updates.
pub fn Client::parameter(self : Client, name : String) -> String? {
  self.shared.parameters.get(name)
}

///|
/// Perform a cheap round trip that validates the connection is still usable.
///
/// The method sends a bare `Sync`, waits for the matching `ReadyForQuery`, and
/// therefore confirms that both the outbound request path and inbound response
/// path are still alive.
pub async fn Client::check_connection(self : Client) -> Unit {
  ensure_open(self.shared)
  let responses = self.send_request(RequestKind::Messages, sync_bytes())
  drain_sync_response(responses)
}

///|
/// Send a PostgreSQL cancel request over a short-lived control connection.
///
/// PostgreSQL requires cancellation to happen on a separate TCP connection that
/// carries only the backend process ID and secret key from startup.
pub async fn CancelToken::cancel(self : CancelToken) -> Unit {
  if self.closed.val {
    return
  }
  let conn = @socket.Tcp::connect_to_host(
    self.config.host,
    port=self.config.port,
  )
  defer conn.close()
  let buf = @buffer.new()
  @frontend.cancel_request(self.process_id.val, self.secret_key.val, buf)
  conn.write(buf.to_bytes())
}
