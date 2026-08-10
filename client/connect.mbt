// Connection establishment and top-level client lifecycle APIs.

///|
/// Open a PostgreSQL connection and start its private I/O driver.
///
/// The driver is attached to `group`, so structured concurrency guarantees that
/// it cannot outlive the caller's task scope. Call `Client::close` before the
/// group exits to shut the PostgreSQL session down gracefully.
pub async fn connect(config : Config, group : @async.TaskGroup[Unit]) -> Client {
  match config.connect_timeout_ms {
    Some(timeout_ms) =>
      @async.with_timeout(
        timeout_ms,
        () => connect_inner(config, group),
        error=ClientError::Protocol("connection timed out"),
      )
    None => connect_inner(config, group)
  }
}

///|
/// Establish a fully initialized client runtime for one concrete target.
async fn connect_inner(
  config : Config,
  group : @async.TaskGroup[Unit],
) -> Client {
  let setup = connect_stream(config)
  let transferred = @ref.new(false)
  defer (if !transferred.val { setup.stream.close() })
  let startup = startup(setup, config)
  let types : Map[@proto.Oid, Type] = Map([])
  let background_group : @ref.Ref[@async.TaskGroup[Unit]?] = @ref.new(
    Some(group),
  )
  seed_builtin_types(types)
  let shared = {
    config,
    requests: Queue(kind=Unbounded),
    async_messages: Queue(kind=Unbounded),
    background_group,
    parameters: startup.parameters,
    types,
    process_id: @ref.new(startup.process_id),
    secret_key: @ref.new(startup.secret_key),
    transaction_status: @ref.new(startup.transaction_status),
    closed: @ref.new(false),
    closing: @ref.new(false),
    aborted: @ref.new(false),
    operation_gate: OperationGate::new(),
    driver_task: @ref.new(None),
    driver_done: Queue(kind=Unbounded),
    next_id: @ref.new(0),
  }
  let client : Client = { shared, }
  let driver : Driver = { shared, stream: setup.stream }
  shared.driver_task.val = Some(group.spawn(no_wait=true, () => driver.run()))
  transferred.val = true
  client
}

///|
/// Return whether the shared runtime can no longer accept or perform work.
///
/// Graceful close sets this after the driver exits. Abort sets it immediately;
/// the driver then closes the physical transport while cancellation unwinds.
pub fn Client::is_closed(self : Client) -> Bool {
  self.shared.closed.val
}

///|
/// Gracefully shut down the client runtime.
///
/// Close is an operation barrier: it waits behind work already accepted by the
/// FIFO gate, rejects later work, sends `Terminate`, and returns only after the
/// private driver has closed the transport.
pub async fn Client::close(self : Client) -> Unit {
  let permit = self.shared.operation_gate.acquire()
  defer permit.release()
  if self.shared.closed.val {
    return
  }
  if self.shared.closing.val {
    let _ = self.shared.driver_done.get() catch { _ => () }
    return
  }
  self.shared.closing.val = true
  let responses = @async.Queue(kind=Unbounded)
  let submitted = self.shared.requests.try_put({
    kind: Terminate,
    bytes: terminate_bytes(),
    responses,
    copy_input: None,
    copy_error: None,
  }) catch {
    _ => {
      close_runtime(self.shared)
      false
    }
  }
  if !submitted {
    responses.close()
    return
  }
  let _ = self.shared.driver_done.get() catch { _ => () }
}

///|
/// Immediately abandon this physical connection.
///
/// Unlike `close`, abort does not wait behind active work or send PostgreSQL's
/// graceful `Terminate` message. It synchronously rejects new work and requests
/// driver cancellation; the driver closes the transport as cancellation
/// unwinds. Active and queued operations fail with
/// `ClientError::Closed("connection aborted")`. Repeated calls are safe.
pub fn Client::abort(self : Client) -> Unit {
  if self.shared.closed.val || self.shared.aborted.val {
    return
  }
  self.shared.aborted.val = true
  self.shared.closing.val = true
  self.shared.closed.val = true
  let error = ClientError::Closed("connection aborted")
  // Preserve buffered requests so the driver's teardown can close every
  // request-local response queue with the same abort error.
  self.shared.requests.close(error~)
  self.shared.async_messages.close()
  match self.shared.driver_task.val {
    Some(task) => task.cancel()
    None => ()
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
  self.run_operation(context => {
    let responses = context.client.send_request(Messages, sync_bytes())
    drain_sync_response(responses)
  })
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
    self.config.connect_host(),
    port=self.config.port,
  )
  defer conn.close()
  let buf = Buffer()
  @frontend.cancel_request(self.process_id.val, self.secret_key.val, buf)
  conn.write(buf.to_bytes())
}
