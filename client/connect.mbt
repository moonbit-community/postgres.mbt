// Connection establishment and top-level client lifecycle APIs.

///|
/// Construct a client handle and its single-use executor without network I/O.
/// Spawn `executor.run()` and await `client.ready()` before reading startup data.
pub fn Client::new(config : Config) -> (Client, ClientExecutor) {
  let types : Map[@proto.Oid, Type] = Map([])
  seed_builtin_types(types)
  let shared = {
    config,
    requests: Queue(kind=Unbounded),
    async_messages: Queue(kind=Unbounded),
    control: DrainControl::new(),
    ready: Completion::new(),
    done: Completion::new(),
    started: @ref.new(false),
    runtime_error: @ref.new(None),
    parameters: Map([]),
    types,
    process_id: @ref.new(0),
    secret_key: @ref.new(0),
    transaction_status: @ref.new(b'I'),
    closed: @ref.new(false),
    closing: @ref.new(false),
    close_requested: @ref.new(false),
    aborted: @ref.new(false),
    operation_gate: OperationGate::new(),
    driver_task: @ref.new(None),
    next_id: @ref.new(0),
  }
  ({ shared, }, { shared, })
}

///|
/// Connect, authenticate, and drive the socket until shutdown.
/// A second invocation fails even after the first has returned.
pub async fn ClientExecutor::run(self : ClientExecutor) -> Unit {
  if self.shared.started.val {
    raise ClientError::ExecutorAlreadyStarted
  }
  self.shared.started.val = true
  if self.shared.closed.val {
    self.shared.ready.complete(
      Some(ClientError::Closed("connection is closed")),
    )
    self.shared.done.complete(None)
    return
  }
  let mut failure : Error? = None
  defer {
    let terminal_error : Error? = if !self.shared.ready.done.val {
      if self.shared.aborted.val {
        Some(ClientError::Closed("connection aborted"))
      } else {
        match failure {
          Some(error) => Some(error)
          None => Some(ClientError::Closed("executor stopped before startup"))
        }
      }
    } else {
      failure
    }
    let runtime_close_error : Error? = if self.shared.aborted.val {
      Some(ClientError::Closed("connection aborted"))
    } else {
      terminal_error
    }
    self.shared.driver_task.val = None
    self.shared.ready.complete(terminal_error)
    close_runtime(self.shared, error?=runtime_close_error)
    if self.shared.aborted.val {
      self.shared.control.close(error=ClientError::Closed("connection aborted"))
    } else {
      self.shared.control.close()
    }
    self.shared.done.complete(failure)
  }
  @async.with_task_group(group => {
    let task = group.spawn(no_wait=true, allow_failure=true, () => {
      self.run_connection(group)
    })
    self.shared.driver_task.val = Some(task)
    task.wait()
  }) catch {
    error =>
      if !self.shared.aborted.val &&
        !(self.shared.close_requested.val && error is @async.TaskCancelled) {
        failure = Some(error)
      }
  }
  match failure {
    Some(error) => raise error
    None => ()
  }
}

///|
async fn ClientExecutor::run_connection(
  self : ClientExecutor,
  group : @async.TaskGroup[Unit],
) -> Unit {
  if self.shared.closing.val {
    return
  }
  defer (if self.shared.aborted.val {
    self.shared.control.close(error=ClientError::Closed("connection aborted"))
  } else {
    self.shared.control.close()
  })
  group.spawn_bg(() => run_control_queue(self.shared.control, group))
  let config = self.shared.config
  let (setup, state) = match config.connect_timeout_ms {
    Some(timeout_ms) =>
      @async.with_timeout(
        timeout_ms,
        () => connect_authenticated(config),
        error=ClientError::Protocol("connection timed out"),
      )
    None => connect_authenticated(config)
  }
  let transferred = @ref.new(false)
  defer (if !transferred.val { setup.stream.close() })
  if self.shared.closing.val {
    return
  }
  for name, value in state.parameters {
    self.shared.parameters[name] = value
  }
  self.shared.process_id.val = state.process_id
  self.shared.secret_key.val = state.secret_key
  self.shared.transaction_status.val = state.transaction_status
  self.shared.ready.complete(None)
  transferred.val = true
  let driver : Driver = { shared: self.shared, stream: setup.stream, }
  driver.run(group)
  match self.shared.runtime_error.val {
    Some(error) if !self.shared.aborted.val => raise error
    _ => ()
  }
}

///|
async fn connect_authenticated(
  config : Config,
) -> (ConnectionSetup, StartupState) {
  let setup = connect_stream(config)
  let transferred = @ref.new(false)
  defer (if !transferred.val { setup.stream.close() })
  let state = startup(setup, config)
  transferred.val = true
  (setup, state)
}

///|
async fn run_control_queue(
  control : DrainControl,
  group : @async.TaskGroup[Unit],
) -> Unit {
  while true {
    let work = control.queue.get() catch { _ => return }
    group.spawn_bg(work)
  }
}

///|
/// Wait for startup. All waiters observe the same result.
pub async fn Client::ready(self : Client) -> Unit {
  self.shared.ready.wait()
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
  if self.shared.closing.val {
    self.shared.done.wait() catch {
      _ => ()
    }
    return
  }
  self.shared.close_requested.val = true
  self.shared.closing.val = true
  if !self.shared.ready.done.val {
    match self.shared.driver_task.val {
      Some(task) => task.cancel()
      None => {
        self.shared.ready.complete(
          Some(ClientError::Closed("connection is closed")),
        )
        close_runtime(self.shared)
        self.shared.control.close()
        self.shared.done.complete(None)
      }
    }
    self.shared.done.wait() catch {
      _ => ()
    }
    return
  }
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
  self.shared.done.wait() catch {
    _ => ()
  }
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
    None => {
      self.shared.ready.complete(Some(error))
      self.shared.control.close(error~)
      self.shared.done.complete(None)
    }
  }
}

///|
/// Create a token capable of cancelling the current backend operation.
///
/// The token stays valid until the underlying connection closes. It can be
/// stored and used from another task or timeout handler when a long-running
/// query should be interrupted.
pub fn Client::cancel_token(self : Client) -> CancelToken raise {
  if !self.shared.ready.done.val || self.shared.ready.error.val is Some(_) {
    raise ClientError::NotReady
  }
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
pub fn Client::parameter(self : Client, name : String) -> String? raise {
  if !self.shared.ready.done.val || self.shared.ready.error.val is Some(_) {
    raise ClientError::NotReady
  }
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
