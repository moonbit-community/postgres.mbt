// Pool lifecycle, checkout, release, and recycling logic.

///|
/// Wrap a custom connection-opening callback for pool construction.
///
/// The callback constructs a client and its executor for each physical session.
pub fn Connector::Connector(
  f : async (@client.Config) -> (@client.Client, @client.ClientExecutor),
) -> Connector {
  { run: f, }
}

///|
/// Build runtime options for pool construction.
pub fn PoolOptions::PoolOptions(
  connector? : Connector,
  initialize_session? : async (Session) -> Unit,
  before_acquire? : async (Session) -> Unit,
) -> PoolOptions {
  { connector, initialize_session, before_acquire, }
}

///|
/// Create a pool from declarative config and runtime options.
///
/// This allocates bookkeeping state and checkout slots only. It does not open
/// any physical PostgreSQL connection, so network failures still happen later
/// during checkout.
pub fn Pool::create(
  config : Config,
  options~ : PoolOptions = PoolOptions(),
) -> (Pool, PoolExecutor) raise {
  let pool_config = config.get_pool_config()
  let targets = config.get_connection_targets()
  let slots : @async.Queue[Unit] = Queue(kind=Unbounded)
  for _ in 0..<pool_config.max_size {
    ignore(slots.try_put(()))
  }
  let shared = {
    ready: Completion::new(),
    done: Completion::new(),
    shutdown: Completion::new(),
    started: Ref(false),
    create_requests: Queue(kind=Unbounded),
    close_requests: Queue(kind=Unbounded),
    pending_creations: Ref(0),
    active_creations: [],
    next_creation_id: Ref(0),
    targets,
    connector: options.connector.unwrap_or(default_connector()),
    initialize_session: options.initialize_session,
    before_acquire: options.before_acquire,
    events: Queue(kind=Blocking(pool_config.event_capacity)),
    dropped_events: Ref(0L),
    next_scope_id: Ref(0L),
    target_session_attrs: config.target_session_attrs.unwrap_or(Any),
    load_balance_hosts: config.load_balance_hosts.unwrap_or(Disable),
    pool_config: Ref(pool_config),
    slots,
    resize_debt: Ref(0),
    idle: [],
    connections: [],
    next_connection_id: Ref(0),
    async_messages: Queue(kind=Blocking(pool_config.async_message_capacity)),
    dropped_async_messages: Ref(0L),
    size: Ref(0),
    waiting: Ref(0),
    closed: Ref(false),
  }
  ({ shared, }, { shared, })
}

///|
/// Run pool maintenance and all physical client executors until close completes.
pub async fn PoolExecutor::run(self : PoolExecutor) -> Unit {
  if self.shared.started.val {
    raise PoolError::ExecutorAlreadyStarted
  }
  self.shared.started.val = true
  if self.shared.closed.val {
    self.shared.events.close()
    self.shared.done.complete(None)
    return
  }
  let finished = Ref(false)
  let mut failure : Error? = None
  defer (if !finished.val {
    fail_pool(self.shared, failure.unwrap_or(PoolError::Closed))
  })
  @async.with_task_group(group => {
    group.spawn_bg(() => serve_creations(self.shared, group))
    group.spawn_bg(() => serve_closes(self.shared, group))
    if self.shared.closed.val {
      self.shared.ready.complete(Some(PoolError::Closed))
    }
    self.shared.ready.complete(None)
    self.shared.shutdown.wait()
    self.shared.create_requests.close()
    self.shared.close_requests.close()
  }) catch {
    @async.WaitedTaskAlreadyCancelled as error => {
      fail_pool(self.shared, error)
      finished.val = true
      raise error
    }
    error => failure = Some(error)
  }
  if failure is Some(error) {
    fail_pool(self.shared, error)
    finished.val = true
    raise error
  } else {
    self.shared.events.close()
    self.shared.done.complete(None)
    finished.val = true
  }
}

///|
/// Wait until the pool's maintenance workers can accept requests.
pub async fn Pool::ready(self : Pool) -> Unit {
  self.shared.ready.wait()
}

///|
async fn serve_creations(
  shared : Shared,
  group : @async.TaskGroup[Unit],
) -> Unit {
  while true {
    let request = shared.create_requests.get() catch {
      @aqueue.QueueAlreadyClosed => return
      error => raise error
    }
    if request.cancelled.val || shared.closed.val {
      request.result.close(error=PoolError::Closed)
      finish_creation(shared, request)
      continue
    }
    let task = group.spawn(allow_failure=true, () => {
      let failure : @ref.Ref[Error?] = Ref(None)
      defer {
        request.result.close(error=failure.val.unwrap_or(PoolError::Closed))
        finish_creation(shared, request)
      }
      let (client, executor) = shared.connector.connect(request.target) catch {
        @async.WaitedTaskAlreadyCancelled => {
          request.result.close(error=PoolError::Closed)
          return
        }
        error => {
          failure.val = Some(error)
          request.result.close(error~)
          return
        }
      }
      if request.cancelled.val || shared.closed.val {
        client.abort()
        return
      }
      client.install_async_message_handler(message => {
        push_pool_async_message(shared, {
          connection_id: request.physical_id,
          message,
        })
      }) catch {
        @client.ClientError::Protocol(_) as error => {
          client.abort()
          failure.val = Some(error)
          request.result.close(error~)
          return
        }
        error => {
          client.abort()
          failure.val = Some(error)
          request.result.close(error~)
          raise error
        }
      }
      group.spawn_bg(() => run_physical_executor(client, executor))
      if request.cancelled.val || shared.closed.val {
        client.abort()
      } else {
        ignore(request.result.try_put((client, request.physical_id))) catch {
          @aqueue.QueueAlreadyClosed => client.abort()
          error => {
            client.abort()
            raise error
          }
        }
      }
    })
    request.task.val = Some(task)
    if request.cancelled.val {
      task.cancel()
    }
  }
}

///|
/// Startup errors belong to checkout. A physical connection that fails after
/// readiness is retired on return or on its next checkout, without closing the
/// other connections in the pool.
async fn run_physical_executor(
  client : @client.Client,
  executor : @client.ClientExecutor,
) -> Unit {
  let mut failure : Error? = None
  executor.run() catch {
    @async.WaitedTaskAlreadyCancelled => return
    error => failure = Some(error)
  }
  if failure is Some(_) {
    client.ready() catch {
      @async.WaitedTaskAlreadyCancelled as error => raise error
      _ => return
    }
  }
}

///|
async fn serve_closes(shared : Shared, group : @async.TaskGroup[Unit]) -> Unit {
  while true {
    let client = shared.close_requests.get() catch {
      @aqueue.QueueAlreadyClosed => return
      error => raise error
    }
    group.spawn_bg(allow_failure=true, () => {
      // Abort on failure or cancellation; `catch` no longer sees cancellation.
      errdefer client.abort()
      client.close() catch {
        @client.ClientError::Closed(_) => ()
        error => raise error
      }
    })
  }
}

///|
fn finish_creation(shared : Shared, request : CreateRequest) -> Unit {
  for i in 0..<shared.active_creations.length() {
    if shared.active_creations[i].id == request.id {
      ignore(shared.active_creations.remove(i))
      break
    }
  }
  shared.pending_creations.val -= 1
  maybe_finish_shutdown(shared)
}

///|
fn maybe_finish_shutdown(shared : Shared) -> Unit {
  if shared.closed.val &&
    shared.size.val == 0 &&
    shared.pending_creations.val == 0 {
    shared.shutdown.complete(None)
  }
}

///|
fn fail_pool(shared : Shared, error : Error) -> Unit {
  shared.closed.val = true
  shared.async_messages.close()
  shared.ready.complete(Some(error))
  shared.slots.close(error=PoolError::Closed, clear=true)
  for request in shared.active_creations {
    request.cancelled.val = true
    if request.task.val is Some(task) {
      task.cancel()
    }
    request.result.close(error~, clear=true)
  }
  while shared.idle.length() > 0 {
    ignore(shared.idle.remove(shared.idle.length() - 1))
  }
  while shared.connections.length() > 0 {
    let connection = shared.connections.remove(shared.connections.length() - 1)
    while connection.statement_cache.length() > 0 {
      ignore(
        connection.statement_cache.remove(
          connection.statement_cache.length() - 1,
        ),
      )
    }
    if connection.client.val is Some(client) {
      connection.client.val = None
      client.abort()
      if shared.size.val > 0 {
        shared.size.val -= 1
      }
    }
  }
  shared.create_requests.close(error~, clear=true)
  shared.close_requests.close(clear=true)
  shared.shutdown.complete(Some(error))
  shared.events.close()
  shared.done.complete(Some(error))
}

///|
/// Checkout one internal session using the pool's current default timeouts.
///
/// Preconditions: the pool must not be closed. On success the internal caller
/// receives a scoped session that must be released after its callback.
#warnings("-unused_value")
async fn Pool::checkout_session(self : Pool) -> Session {
  self.checkout_session_with_timeouts(self.shared.pool_config.val.timeouts)
}

///|
/// Checkout one internal session using per-call timeout overrides.
///
/// The provided `timeouts` are validated for this call only and do not mutate
/// the pool's stored defaults. If checkout fails after capacity was reserved,
/// the slot is restored before the error is re-raised. Cancelling checkout
/// during recycling discards that connection and restores the capacity slot.
async fn Pool::checkout_session_with_timeouts(
  self : Pool,
  timeouts : Timeouts,
  deadline? : Deadline,
) -> Session {
  validate_timeout("wait_ms", timeouts.wait_ms)
  validate_timeout("create_ms", timeouts.create_ms)
  validate_timeout("recycle_ms", timeouts.recycle_ms)
  self.assert_open()
  let wait = phase_deadline(deadline, timeouts.wait_ms)
  let reserved = Ref(false)
  let mut handoff_complete = false
  defer (if reserved.val && !handoff_complete { self.restore_slot() })
  // Zero wait is a poll, including executor readiness.
  if timeouts.wait_ms == Some(0) {
    if !self.shared.ready.done.val {
      raise PoolError::Timeout(Wait)
    }
    self.ready()
    ignore(remaining_ms(deadline, Wait))
    self.acquire_slot(Some(0))
    reserved.val = true
  } else {
    with_deadline(wait, Wait, () => {
      self.ready()
      self.assert_open()
      // The enclosing deadline already covers this wait. Mark ownership in
      // this coroutine, before the deadline task can cancel its return value.
      self.acquire_slot(None)
      reserved.val = true
    })
  }
  let connection = self.checkout_client(timeouts, deadline?)
  handoff_complete = true
  Session::new(self.shared, connection, deadline?)
}

///|
/// Borrow a session. Business deadlines include acquisition and the callback;
/// cleanup has a separate, shared, finite grace period.
pub async fn[T] Pool::with_session(
  self : Pool,
  f : async (Session) -> T,
  deadline? : Deadline,
  timeouts? : Timeouts,
) -> T {
  let session = self.checkout_session_with_timeouts(
    timeouts.unwrap_or(self.shared.pool_config.val.timeouts),
    deadline?,
  )
  defer @async.protect_from_cancel(() => session.release())
  with_deadline(deadline, Query, () => f(session))
}

///|
/// Return a point-in-time snapshot of pool bookkeeping counters.
///
/// The returned record is not live and may already be stale by the time the
/// caller inspects it.
pub fn Pool::status(self : Pool) -> Status {
  {
    size: self.shared.size.val,
    available: self.shared.idle.length(),
    waiting: self.shared.waiting.val,
    max_size: self.shared.pool_config.val.max_size,
    closed: self.shared.closed.val,
  }
}

///|
/// Return whether `close()` has started for this pool.
///
/// Once this becomes `true`, new checkouts fail with `PoolError::Closed`.
pub fn Pool::is_closed(self : Pool) -> Bool {
  self.shared.closed.val
}

///|
/// Return the full pool config currently used by this pool.
pub fn Pool::config(self : Pool) -> PoolConfig {
  self.shared.pool_config.val
}

///|
/// Receive one asynchronous message from any physical pool connection.
/// A single consumer should call this method; buffered messages remain
/// readable after the pool closes.
pub async fn Pool::next_message(self : Pool) -> PoolAsyncMessage? {
  Some(self.shared.async_messages.get()) catch {
    @aqueue.QueueAlreadyClosed => None
    error => raise error
  }
}

///|
/// Number of oldest asynchronous messages discarded when the pool buffer filled.
pub fn Pool::dropped_async_messages(self : Pool) -> Int64 {
  self.shared.dropped_async_messages.val
}

///|
fn push_pool_async_message(shared : Shared, message : PoolAsyncMessage) -> Unit {
  if shared.closed.val {
    return
  }
  if (shared.async_messages.try_put(message) catch { _ => false }) {
    return
  }
  if (shared.async_messages.try_get() catch { _ => None }) is Some(_) {
    shared.dropped_async_messages.val += 1L
    ignore(shared.async_messages.try_put(message)) catch {
      _ => ()
    }
  }
}

///|
/// Change the pool's maximum number of live physical connections.
///
/// Preconditions: `max_size` must be at least `1`. Shrinking the pool retires
/// idle connections immediately until the new limit is respected or no idle
/// connections remain. Checked-out clients are not interrupted; when they are
/// later released above the new limit, they are closed instead of returning to
/// the idle queue. Calling this after `close()` is a no-op.
pub fn Pool::resize(self : Pool, max_size : Int32) -> Unit raise {
  if self.shared.closed.val {
    return
  }
  if max_size < 1 {
    raise PoolError::InvalidConfig("pool max_size must be at least 1")
  }
  let current = self.shared.pool_config.val
  if current.max_size == max_size {
    return
  }
  self.shared.pool_config.val = { ..current, max_size, }
  if max_size > current.max_size {
    let mut permits_to_add = max_size - current.max_size
    while permits_to_add > 0 && self.shared.resize_debt.val > 0 {
      self.shared.resize_debt.val -= 1
      permits_to_add -= 1
    }
    for _ in 0..<permits_to_add {
      restore_available_slot(self.shared)
    }
    return
  }
  // Capacity tokens include both idle physical connections and room for
  // connections that have not been opened yet. Remove the whole configured
  // delta first; tying token removal only to idle retirement would allow new
  // checkouts past the smaller limit while existing sessions are checked out.
  let mut permits_to_remove = current.max_size - max_size
  while permits_to_remove > 0 {
    if self.shared.slots.try_get() is Some(_) {
      permits_to_remove -= 1
    } else {
      break
    }
  }
  self.shared.resize_debt.val += permits_to_remove
  while self.shared.size.val > max_size && self.shared.idle.length() > 0 {
    let connection = self.shared.idle.remove(self.shared.idle.length() - 1)
    retire_connection(self.shared, connection, close_client=true)
  }
}

///|
/// Stop accepting new checkouts and schedule every idle connection for closure.
///
/// Existing checked-out clients are not revoked. They can keep running until
/// released, at which point their physical connections are closed instead of
/// being returned to the idle queue. Repeated calls are idempotent.
pub fn Pool::close(self : Pool) -> Unit {
  if self.shared.closed.val {
    return
  }
  self.shared.closed.val = true
  if !self.shared.started.val {
    self.shared.events.close()
  }
  self.shared.async_messages.close()
  self.shared.slots.close(error=PoolError::Closed, clear=true)
  for request in self.shared.active_creations {
    request.cancelled.val = true
    if request.task.val is Some(task) {
      task.cancel()
    }
  }
  while self.shared.idle.length() > 0 {
    let connection = self.shared.idle.remove(self.shared.idle.length() - 1)
    retire_connection(self.shared, connection, close_client=true)
  }
  if !self.shared.ready.done.val {
    self.shared.ready.complete(Some(PoolError::Closed))
  }
  maybe_finish_shutdown(self.shared)
}

///|
/// Fail new checkout attempts once the pool is closing.
fn Pool::assert_open(self : Pool) -> Unit raise {
  if self.shared.closed.val {
    raise PoolError::Closed
  }
}

///|
/// Acquire one checkout slot, waiting if necessary.
async fn Pool::acquire_slot(self : Pool, wait_ms : Int32?) -> Unit {
  let immediate = self.shared.slots.try_get() catch {
    PoolError::Closed => raise PoolError::Closed
    err => raise err
  }
  if immediate is Some(_) {
    ()
  } else {
    match wait_ms {
      Some(0) => raise PoolError::Timeout(Wait)
      Some(wait_ms) => {
        self.shared.waiting.val += 1
        defer {
          self.shared.waiting.val -= 1
        }
        ignore(
          @async.with_timeout(
            wait_ms,
            () => self.shared.slots.get(),
            error=PoolError::Timeout(Wait),
          ),
        )
      }
      None => {
        self.shared.waiting.val += 1
        defer {
          self.shared.waiting.val -= 1
        }
        ignore(self.shared.slots.get())
      }
    }
  }
}

///|
/// Restore one slot if checkout fails before a lease is created.
fn Pool::restore_slot(self : Pool) -> Unit {
  release_capacity(self.shared)
}

///|
/// Release one reserved checkout slot after a failed checkout or lease return.
///
/// A shrink performed while slots are checked out records the unavailable
/// tokens as debt. Future releases pay that debt before making capacity
/// available again, so shrink/expand sequences cannot mint extra tokens.
fn release_capacity(shared : Shared) -> Unit {
  if shared.closed.val {
    return
  }
  if shared.resize_debt.val > 0 {
    shared.resize_debt.val -= 1
    return
  }
  restore_available_slot(shared)
}

///|
/// Put one capacity slot back into the pool's checkout queue.
fn restore_available_slot(shared : Shared) -> Unit {
  if shared.closed.val {
    return
  }
  try {
    guard shared.slots.try_put(()) else { abort("pool slot queue overflow") }
  } catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// Obtain a live client for one checkout, recycling idle clients if needed.
async fn Pool::checkout_client(
  self : Pool,
  timeouts : Timeouts,
  deadline? : Deadline,
) -> ConnectionState {
  let attempts : Array[ConnectionAttempt] = []
  while true {
    self.assert_open()
    ignore(remaining_ms(deadline, Recycle)) catch {
      PoolError::Timeout(kind) as error => {
        if attempts.is_empty() {
          raise error
        }
        attempts.push({
          target: "checkout",
          phase: kind,
          elapsed_ms: 0L,
          cause: error,
        })
        raise AcquireError::AttemptsFailed(attempts)
      }
      error => raise error
    }
    let connection = if self.take_idle_client() is Some(connection) {
      // Own the dequeued candidate before even checking the recycle budget.
      // Checkout alone restores capacity if this check fails.
      errdefer self.discard_client(connection)
      let limit = phase_deadline(deadline, timeouts.recycle_ms)
      if self.try_recycle_client(
          connection,
          remaining_ms(limit, Recycle),
          attempts,
        )
        is Some(connection) {
        connection
      } else {
        continue
      }
    } else {
      let create_deadline = phase_deadline(deadline, timeouts.create_ms)
      let connection = self.create_client(create_deadline, attempts)
      errdefer self.discard_client(connection)
      self.acquire_hook(
        connection,
        self.shared.initialize_session,
        create_deadline,
        phase=Create,
      )
      connection
    }
    errdefer self.discard_client(connection)
    self.acquire_hook(connection, self.shared.before_acquire, deadline)
    self.assert_open()
    return connection
  }
  abort("unreachable")
}

///|
async fn Pool::acquire_hook(
  self : Pool,
  connection : ConnectionState,
  hook : (async (Session) -> Unit)?,
  deadline : Deadline?,
  phase~ : TimeoutKind = Hook,
) -> Unit {
  let client = connection.client.val.unwrap()
  run_with_timeout(
    remaining_ms(deadline, phase),
    phase,
    on_timeout=() => client.abort(),
    () => run_client_hook(self.shared, connection, hook, deadline?),
  ) catch {
    PoolError::Timeout(_) as error => {
      if deadline is Some(deadline) && @async.now() >= deadline.at {
        raise PoolError::Timeout(phase)
      }
      raise error
    }
    error => raise error
  }
}

///|
/// Pop one idle client according to the configured queue mode.
fn Pool::take_idle_client(self : Pool) -> ConnectionState? {
  let idle = self.shared.idle
  if idle.length() == 0 {
    return None
  }
  match self.shared.pool_config.val.queue_mode {
    Fifo => Some(idle.remove(0))
    Lifo => Some(idle.remove(idle.length() - 1))
  }
}

///|
/// Try to recycle an idle client. Failed clients are discarded and ignored.
async fn Pool::try_recycle_client(
  self : Pool,
  connection : ConnectionState,
  recycle_ms : Int32?,
  attempts : Array[ConnectionAttempt],
) -> ConnectionState? {
  let client = if connection.client.val is Some(client) {
    client
  } else {
    self.discard_client(connection, close_client=false)
    return None
  }
  if client.is_closed() {
    self.discard_client(connection, close_client=false)
    return None
  }
  let session = Session::new(self.shared, connection)
  defer {
    session.state.releasing.val = true
    session.state.released.val = true
  }
  self.run_recycle(connection, recycle_ms, attempts, () => {
    session.run_operation(client => {
      match self.shared.pool_config.val.health_check {
        Passive => ()
        Active => client.check_connection()
        Custom(sql) => client.batch_execute(sql)
      }
      if !client.is_transaction_idle() {
        raise PoolError::HookLeftOpenTransaction
      }
    })
  })
}

///|
/// Run one recycle operation with timeout and cancellation cleanup.
async fn Pool::run_recycle(
  self : Pool,
  connection : ConnectionState,
  recycle_ms : Int32?,
  attempts : Array[ConnectionAttempt],
  op : async () -> Unit,
) -> ConnectionState? {
  let client = if connection.client.val is Some(client) {
    client
  } else {
    self.discard_client(connection, close_client=false)
    return None
  }
  let started = @async.now()
  // Checkout separately restores its reserved slot on cancellation.
  errdefer self.discard_client(connection, close_client=true)
  try
    run_with_timeout(recycle_ms, Recycle, on_timeout=() => client.abort(), op)
  catch {
    error => {
      connection.failure.val = Some(error)
      attempts.push({
        target: connection.target,
        phase: Recycle,
        elapsed_ms: @async.now() - started,
        cause: error,
      })
      emit_event(
        self.shared,
        HealthChecked,
        Recycle,
        connection_id=connection.id,
        started~,
        cause=error,
      )
      self.discard_client(connection, close_client=true)
      return None
    }
  } noraise {
    _ =>
      if client.is_closed() || self.shared.closed.val {
        self.discard_client(connection, close_client=false)
        None
      } else {
        emit_event(
          self.shared,
          HealthChecked,
          Recycle,
          connection_id=connection.id,
          started~,
        )
        Some(connection)
      }
  }
}

///|
/// Establish a new connection and await the executor's startup result.
async fn Pool::create_client(
  self : Pool,
  deadline : Deadline?,
  attempts : Array[ConnectionAttempt],
) -> ConnectionState {
  self.assert_open()
  let candidate : @ref.Ref[@client.Client?] = Ref(None)
  errdefer (if candidate.val is Some(client) { client.abort() })
  for target in ordered_targets(self.shared) {
    let started = @async.now()
    let name = "\{target.hostaddr.unwrap_or(target.host)}:\{target.port}"
    try {
      let (client, physical_id) = run_with_timeout(
        remaining_ms(deadline, Create),
        Create,
        on_timeout=() => if candidate.val is Some(client) { client.abort() },
        () => self.connect_target(target, candidate),
      )
      // Register only after the timed operation has transferred ownership.
      self.shared.size.val += 1
      let connection = ConnectionState::new(
        self.shared,
        client,
        id=physical_id,
        target=name,
      )
      emit_event(
        self.shared,
        ConnectionAttempt,
        Create,
        connection_id=connection.id,
        target=name,
        started~,
      )
      return connection
    } catch {
      @async.WaitedTaskAlreadyCancelled as error => raise error
      err => {
        candidate.val = None
        attempts.push({
          target: name,
          phase: Create,
          elapsed_ms: @async.now() - started,
          cause: err,
        })
        emit_event(
          self.shared,
          ConnectionAttempt,
          Create,
          target=name,
          started~,
          cause=err,
        )
        if err is PoolError::Timeout(_) {
          break
        }
      }
    }
  }
  raise AcquireError::AttemptsFailed(attempts)
}

///|
/// Establish one connection for one concrete target.
async fn Pool::connect_target(
  self : Pool,
  target : @client.Config,
  candidate : @ref.Ref[@client.Client?],
) -> (@client.Client, Int32) {
  let (client, physical_id) = self.schedule_connection(target)
  candidate.val = Some(client)
  errdefer client.abort()
  // Startup/target validation can contain protected client I/O. Keep an
  // unprotected waiter able to abort the candidate on acquisition cancellation.
  @async.with_task_group(group => {
    let startup = group.spawn(allow_failure=true, () => {
      client.ready()
      if self.shared.closed.val {
        raise PoolError::Closed
      }
      check_target_session_attrs(self.shared.target_session_attrs, client)
    })
    errdefer client.abort()
    startup.wait()
  })
  (client, physical_id)
}

///|
/// Ask the pool executor to construct and start one physical connection.
async fn Pool::schedule_connection(
  self : Pool,
  target : @client.Config,
) -> (@client.Client, Int32) {
  self.assert_open()
  self.shared.next_creation_id.val += 1
  self.shared.next_connection_id.val += 1
  let request : CreateRequest = {
    id: self.shared.next_creation_id.val,
    physical_id: self.shared.next_connection_id.val,
    target,
    result: Queue(kind=Unbounded),
    cancelled: Ref(false),
    task: Ref(None),
  }
  self.shared.pending_creations.val += 1
  self.shared.active_creations.push(request)
  errdefer {
    request.cancelled.val = true
    if request.task.val is Some(task) {
      task.cancel()
    }
    if (request.result.try_get() catch { _ => None }) is Some((client, _)) {
      client.abort()
    }
  }
  ignore(self.shared.create_requests.try_put(request))
  request.result.get()
}

///|
/// Drop one unusable pooled client from the pool's size accounting.
fn Pool::discard_client(
  self : Pool,
  connection : ConnectionState,
  close_client~ : Bool = true,
) -> Unit {
  retire_connection(self.shared, connection, close_client~)
}

///|
/// Return a checked-out client to the pool or close it if it can no longer be reused.
#warnings("-unused_value")
async fn return_client(shared : Shared, connection : ConnectionState) -> Unit {
  Session::new(shared, connection).release()
}

///|
/// Create and register one new physical connection state.
fn ConnectionState::new(
  shared : Shared,
  client : @client.Client,
  id? : Int32,
  target~ : String = "unknown",
) -> ConnectionState {
  let id = if id is Some(id) {
    id
  } else {
    shared.next_connection_id.val += 1
    shared.next_connection_id.val
  }
  let connection = {
    id,
    target,
    failure: Ref(None),
    client: Ref(Some(client)),
    statement_cache_capacity: shared.pool_config.val.statement_cache_capacity,
    statement_cache: [],
  }
  shared.connections.push(connection)
  connection
}

///|
/// Remove one physical connection from the live pool state and optionally close it.
fn retire_connection(
  shared : Shared,
  connection : ConnectionState,
  close_client~ : Bool = true,
) -> Unit {
  while connection.statement_cache.length() > 0 {
    ignore(
      connection.statement_cache.remove(connection.statement_cache.length() - 1),
    )
  }
  remove_live_connection(shared, connection.id)
  if connection.client.val is Some(client) {
    connection.client.val = None
    emit_event(
      shared,
      ConnectionReplaced,
      Cleanup,
      connection_id=connection.id,
      target=connection.target,
      cause?=connection.failure.val,
    )
    if shared.size.val > 0 {
      shared.size.val -= 1
    }
    // Aborted clients already own transport shutdown. Graceful close would
    // wait behind permits still held by escaped stream/COPY callbacks.
    if close_client && !client.is_closed() {
      ignore(shared.close_requests.try_put(client)) catch {
        _ => client.abort()
      }
    }
  }
  maybe_finish_shutdown(shared)
}

///|
/// Drop one retired connection from the pool's live-connection index.
fn remove_live_connection(shared : Shared, connection_id : Int32) -> Unit {
  for i in 0..<shared.connections.length() {
    if shared.connections[i].id == connection_id {
      ignore(shared.connections.remove(i))
      return
    }
  }
}

///|
/// Run an optional client hook if one is installed.
async fn run_client_hook(
  shared : Shared,
  connection : ConnectionState,
  hook : (async (Session) -> Unit)?,
  deadline? : Deadline,
  cleanup_deadline~ : @ref.Ref[Deadline?] = Ref(None),
  cleanup_mode~ : Bool = false,
) -> Unit {
  if hook is Some(hook) {
    let session = Session::new(
      shared,
      connection,
      deadline?,
      cleanup_deadline~,
      cleanup_mode~,
    )
    let started = @async.now()
    defer {
      session.state.releasing.val = true
      session.state.released.val = true
    }
    let client = connection.client.val.unwrap()
    errdefer client.abort()
    let outcome = try {
      hook(session)
      if !client.is_transaction_idle() || session.state.active_ops.val != 0 {
        raise PoolError::HookLeftOpenTransaction
      }
    } catch {
      error => Err(error)
    } noraise {
      _ => Ok(())
    }
    match outcome {
      Err(error) => {
        emit_event(
          shared,
          HookCompleted,
          Hook,
          connection_id=connection.id,
          scope_id=session.state.id,
          started~,
          cause=error,
        )
        raise error
      }
      Ok(_) => ()
    }
    emit_event(
      shared,
      HookCompleted,
      Hook,
      connection_id=connection.id,
      scope_id=session.state.id,
      started~,
    )
  }
}

///|
async fn reset_session(state : ClientLeaseState) -> Unit {
  let client = state.scoped_client()
  if client.is_closed() {
    return
  }
  if !client.is_transaction_idle() {
    client.batch_execute("ROLLBACK")
  }
  match state.pool.pool_config.val.reset_policy {
    PreserveSession => ()
    Reconnect => client.abort()
    DiscardAll => {
      client.batch_execute("DISCARD ALL")
      state.connection.statement_cache.clear()
      client.clear_type_cache()
      run_client_hook(
        state.pool,
        state.connection,
        state.pool.initialize_session,
        deadline?=state.cleanup_deadline.val,
        cleanup_deadline=state.cleanup_deadline,
        cleanup_mode=true,
      )
    }
  }
}

///|
/// Reject a read-only target when read-write sessions are required.
async fn check_target_session_attrs(
  attrs : TargetSessionAttrs,
  client : @client.Client,
) -> Unit {
  match attrs {
    Any => ()
    ReadWrite => {
      let value : String = client
        .query_one("show transaction_read_only")
        .get_name("transaction_read_only")
      if value != "off" {
        raise PoolError::InvalidConfig("target is read only")
      }
    }
  }
}

///|
/// Return the target list for the next physical connection attempt.
fn ordered_targets(shared : Shared) -> Array[@client.Config] {
  let targets : Array[@client.Config] = []
  for target in shared.targets {
    targets.push(target)
  }
  if shared.load_balance_hosts is Random && targets.length() > 1 {
    let rand = @random.Rand::chacha8(seed=make_shuffle_seed(shared))
    for i in 0..<(targets.length() - 1) {
      let j = i + rand.int(limit=targets.length() - i)
      let tmp = targets[i]
      targets[i] = targets[j]
      targets[j] = tmp
    }
  }
  targets
}

///|
/// Derive one best-effort seed for host-order shuffling without internal APIs.
fn make_shuffle_seed(shared : Shared) -> Bytes {
  let base = @async.now().reinterpret_as_uint64() ^
    shared.next_connection_id.val.to_uint64() ^
    shared.targets.length().to_uint64()
  Bytes::makei(32, i => {
    let word = base + (i / 8).to_uint64() * 0x9e3779b97f4a7c15UL
    (word >> (i % 8 * 8)).to_byte()
  })
}

///|
/// Apply an optional timeout and run synchronous invalidation before failing.
async fn[T] run_with_timeout(
  timeout_ms : Int32?,
  kind : TimeoutKind,
  on_timeout? : () -> Unit,
  op : async () -> T,
) -> T {
  if timeout_ms is Some(timeout_ms) {
    let timed_out = Ref(false)
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true, () => {
        @async.sleep(timeout_ms)
        timed_out.val = true
        if on_timeout is Some(on_timeout) {
          on_timeout()
        }
        raise PoolError::Timeout(kind)
      })
      op()
    }) catch {
      _ if timed_out.val =>
        // The aborted operation may wake with `ClientError::Closed` and race
        // the timer's own failure. Once the timer fired, the public result is
        // deterministically the configured pool timeout.
        raise PoolError::Timeout(kind)
      err => raise err
    }
  } else {
    op()
  }
}
