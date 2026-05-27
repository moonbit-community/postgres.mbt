// Pool lifecycle, checkout, release, and recycling logic.

///|
/// Wrap a custom connection-opening callback for pool construction.
///
/// The callback is responsible for returning both the high-level client handle
/// and its background connection driver. It is invoked every time the pool must
/// open a new physical connection.
pub fn Connector::new(
  f : async (@client.Config) -> (@client.Client, @client.Connection),
) -> Connector {
  { run: f }
}

///|
/// Build runtime options for pool construction.
pub fn PoolOptions::new(
  connector? : Connector,
  post_create? : async (@client.Client) -> Unit,
  pre_recycle? : async (@client.Client) -> Unit,
  post_recycle? : async (@client.Client) -> Unit,
) -> PoolOptions {
  { connector, post_create, pre_recycle, post_recycle }
}

///|
/// Create a pool from declarative config and runtime options.
///
/// This allocates bookkeeping state and checkout slots only. It does not open
/// any physical PostgreSQL connection, so network failures still happen later
/// during checkout.
pub fn Pool::new(
  config : Config,
  group : @async.TaskGroup[Unit],
  options? : PoolOptions = PoolOptions::new(),
) -> Pool raise {
  let normalized = normalize_config(config)
  let pool_config = config.get_pool_config()
  let slots : @async.Queue[Unit] = Queue(kind=Unbounded)
  for _ in 0..<pool_config.max_size {
    ignore(slots.try_put(()))
  }
  {
    shared: {
      group,
      targets: config.get_connection_targets(),
      connector: options.connector.unwrap_or(default_connector()),
      post_create: options.post_create,
      pre_recycle: options.pre_recycle,
      post_recycle: options.post_recycle,
      target_session_attrs: normalized.target_session_attrs,
      load_balance_hosts: normalized.load_balance_hosts,
      pool_config: @ref.new(pool_config),
      slots,
      idle: [],
      connections: [],
      next_connection_id: @ref.new(0),
      size: @ref.new(0),
      waiting: @ref.new(0),
      closed: @ref.new(false),
    },
  }
}

///|
/// Borrow one pooled client using the pool's current default timeouts.
///
/// Preconditions: the pool must not be closed. On success the caller receives a
/// checked-out client lease that must eventually be released or consumed by a
/// higher-level helper such as `with_client`.
pub async fn Pool::get(self : Pool) -> Client {
  self.timeout_get(self.shared.pool_config.val.timeouts)
}

///|
/// Borrow one pooled client using per-call timeout overrides.
///
/// The provided `timeouts` are validated for this call only and do not mutate
/// the pool's stored defaults. If checkout fails after capacity was reserved,
/// the slot is restored before the error is re-raised.
pub async fn Pool::timeout_get(self : Pool, timeouts : Timeouts) -> Client {
  validate_pool_config({
    max_size: self.shared.pool_config.val.max_size,
    timeouts,
    queue_mode: self.shared.pool_config.val.queue_mode,
    recycling_method: self.shared.pool_config.val.recycling_method,
  })
  self.assert_open()
  self.acquire_slot(timeouts.wait_ms)
  let mut handoff_complete = false
  defer (if !handoff_complete { self.restore_slot() })
  let connection = self.checkout_client(timeouts)
  handoff_complete = true
  make_pooled_client(self.shared, connection)
}

///|
/// Borrow one pooled client for the duration of a callback.
///
/// The lease is released in a `defer`, so it is returned to the pool on normal
/// completion and also when the callback raises. If the callback detached the
/// raw client, the deferred release becomes a no-op.
pub async fn[T] Pool::with_client(self : Pool, f : async (Client) -> T) -> T {
  let client = self.get()
  defer client.release()
  f(client)
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
/// Return the timeout config currently used by `Pool::get()`.
///
/// This reflects the pool's current stored config.
pub fn Pool::timeouts(self : Pool) -> Timeouts {
  self.shared.pool_config.val.timeouts
}

///|
/// Return the full pool config currently used by this pool.
pub fn Pool::config(self : Pool) -> PoolConfig {
  self.shared.pool_config.val
}

///|
/// Return the administrative manager handle for this pool.
pub fn Pool::manager(self : Pool) -> Manager {
  { shared: self.shared }
}

///|
/// Return a handle that can manage statement caches on all live connections.
pub fn Manager::statement_caches(self : Manager) -> StatementCaches {
  { shared: self.shared }
}

///|
/// Clear every statement cache on connections that are live right now.
///
/// In-use cached statements are marked for eviction and close once their active
/// leases finish. Connections opened after this call are unaffected.
pub async fn StatementCaches::clear(self : StatementCaches) -> Unit {
  for connection in self.shared.connections {
    clear_connection_statement_cache(connection)
  }
}

///|
/// Remove one cached statement key from every statement cache that is live now.
///
/// Matching uses both `sql` and `param_types`. Missing entries are ignored.
pub async fn StatementCaches::remove(
  self : StatementCaches,
  sql : String,
  param_types? : Array[@client.Type] = [],
) -> Unit {
  for connection in self.shared.connections {
    remove_connection_cached_statement(connection, sql, param_types)
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
pub fn Pool::resize(self : Pool, max_size : Int) -> Unit raise {
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
    for _ in current.max_size..<max_size {
      restore_available_slot(self.shared)
    }
    return
  }
  while self.shared.size.val > max_size && self.shared.idle.length() > 0 {
    ignore(self.shared.slots.try_get())
    let connection = self.shared.idle.remove(self.shared.idle.length() - 1)
    retire_connection(self.shared, connection, close_client=true)
  }
}

///|
/// Stop accepting new checkouts and close every idle connection immediately.
///
/// Existing checked-out clients are not revoked. They can keep running until
/// released, at which point their physical connections are closed instead of
/// being returned to the idle queue. Repeated calls are idempotent.
pub fn Pool::close(self : Pool) -> Unit {
  if self.shared.closed.val {
    return
  }
  self.shared.closed.val = true
  self.shared.slots.close(error=PoolError::Closed, clear=true)
  while self.shared.idle.length() > 0 {
    let connection = self.shared.idle.remove(self.shared.idle.length() - 1)
    retire_connection(self.shared, connection, close_client=true)
  }
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
async fn Pool::acquire_slot(self : Pool, wait_ms : Int?) -> Unit {
  let immediate = self.shared.slots.try_get() catch {
    PoolError::Closed => raise PoolError::Closed
    err => raise err
  }
  match immediate {
    Some(_) => ()
    None =>
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
  restore_available_slot(self.shared)
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
) -> ConnectionState {
  while true {
    self.assert_open()
    match self.take_idle_client() {
      Some(connection) =>
        match self.try_recycle_client(connection, timeouts.recycle_ms) {
          Some(connection) => return connection
          None => continue
        }
      None => return self.create_client(timeouts.create_ms)
    }
  }
  abort("unreachable: checkout loop exited without returning a client")
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
  recycle_ms : Int?,
) -> ConnectionState? {
  let client = match connection.client.val {
    Some(client) => client
    None => {
      self.discard_client(connection, close_client=false)
      return None
    }
  }
  if client.is_closed() {
    self.discard_client(connection, close_client=false)
    return None
  }
  self.run_recycle(connection, recycle_ms, () => {
    run_client_hook(self.shared.pre_recycle, client)
    match self.shared.pool_config.val.recycling_method {
      Fast => ()
      Verified => client.check_connection()
      Clean => client.batch_execute(clean_recycle_sql)
      Custom(sql) => client.batch_execute(sql)
    }
    run_client_hook(self.shared.post_recycle, client)
  })
}

///|
/// Run one recycle operation with timeout handling.
async fn Pool::run_recycle(
  self : Pool,
  connection : ConnectionState,
  recycle_ms : Int?,
  op : async () -> Unit,
) -> ConnectionState? {
  let client = match connection.client.val {
    Some(client) => client
    None => {
      self.discard_client(connection, close_client=false)
      return None
    }
  }
  try run_with_timeout(recycle_ms, Recycle, op) catch {
    _ => {
      self.discard_client(connection, close_client=true)
      return None
    }
  } noraise {
    _ =>
      if client.is_closed() || self.shared.closed.val {
        self.discard_client(connection, close_client=false)
        None
      } else {
        Some(connection)
      }
  }
}

///|
/// Establish a new connection and start its background driver task.
async fn Pool::create_client(self : Pool, create_ms : Int?) -> ConnectionState {
  self.assert_open()
  run_with_timeout(create_ms, Create, () => self.create_client_inner())
}

///|
/// Establish a new connection by trying every configured target.
async fn Pool::create_client_inner(self : Pool) -> ConnectionState {
  let targets = ordered_targets(self.shared)
  let mut last_error : Error? = None
  for target in targets {
    try {
      return self.connect_target(target)
    } catch {
      err => {
        last_error = Some(err)
        continue
      }
    }
  }
  match last_error {
    Some(err) => raise err
    None => raise PoolError::Closed
  }
}

///|
/// Establish one connection for one concrete target.
async fn Pool::connect_target(
  self : Pool,
  target : @client.Config,
) -> ConnectionState {
  let (client, connection) = self.shared.connector.connect(target)
  self.shared.group.spawn_bg(no_wait=true, () => connection.run())
  try {
    if self.shared.closed.val {
      client.close()
      raise PoolError::Closed
    }
    check_target_session_attrs(self.shared.target_session_attrs, client)
    run_client_hook(self.shared.post_create, client)
    self.shared.size.val += 1
    make_connection_state(self.shared, client)
  } catch {
    err => {
      client.close()
      raise err
    }
  }
}

///|
/// Drop one unusable pooled client from the pool's size accounting.
fn Pool::discard_client(
  self : Pool,
  connection : ConnectionState,
  close_client? : Bool = true,
) -> Unit {
  retire_connection(self.shared, connection, close_client~)
}

///|
/// Return a checked-out client to the pool or close it if it can no longer be reused.
fn return_client(shared : Shared, connection : ConnectionState) -> Unit {
  match connection.client.val {
    Some(client) => {
      if shared.closed.val {
        retire_connection(shared, connection, close_client=true)
        return
      }
      if client.is_closed() {
        retire_connection(shared, connection, close_client=false)
        restore_available_slot(shared)
        return
      }
      if shared.size.val > shared.pool_config.val.max_size {
        retire_connection(shared, connection, close_client=true)
        return
      }
      shared.idle.push(connection)
      restore_available_slot(shared)
    }
    None => {
      retire_connection(shared, connection, close_client=false)
      restore_available_slot(shared)
    }
  }
}

///|
/// Create and register one new physical connection state.
fn make_connection_state(
  shared : Shared,
  client : @client.Client,
) -> ConnectionState {
  shared.next_connection_id.val += 1
  let connection = {
    id: shared.next_connection_id.val,
    group: shared.group,
    client: @ref.new(Some(client)),
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
  close_client? : Bool = true,
) -> Unit {
  while connection.statement_cache.length() > 0 {
    ignore(
      connection.statement_cache.remove(connection.statement_cache.length() - 1),
    )
  }
  remove_live_connection(shared, connection.id)
  match connection.client.val {
    Some(client) => {
      connection.client.val = None
      if shared.size.val > 0 {
        shared.size.val -= 1
      }
      if close_client {
        client.close()
      }
    }
    None => ()
  }
}

///|
/// Drop one retired connection from the pool's live-connection index.
fn remove_live_connection(shared : Shared, connection_id : Int) -> Unit {
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
  hook : (async (@client.Client) -> Unit)?,
  client : @client.Client,
) -> Unit {
  match hook {
    Some(hook) => hook(client)
    None => ()
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
/// Apply an optional timeout to one async operation.
async fn[T] run_with_timeout(
  timeout_ms : Int?,
  kind : TimeoutKind,
  op : async () -> T,
) -> T {
  match timeout_ms {
    Some(timeout_ms) =>
      @async.with_timeout(timeout_ms, op, error=PoolError::Timeout(kind))
    None => op()
  }
}
