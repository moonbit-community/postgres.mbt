// Public configuration and error types for the PostgreSQL connection pool.

///|
/// Strategy used when choosing which idle physical connection to reuse next.
///
/// This setting affects only the order of the pool's idle list. It does not
/// reorder waiting tasks, and it has no effect while the pool must open a new
/// connection because no idle connection is available.
pub enum QueueMode {
  Fifo
  Lifo
} derive(Eq, Debug)

///|
/// Construct FIFO queue mode.
///
/// The oldest idle connection is reused first.
pub fn QueueMode::fifo() -> QueueMode {
  Fifo
}

///|
/// Construct LIFO queue mode.
///
/// The most recently returned idle connection is reused first.
pub fn QueueMode::lifo() -> QueueMode {
  Lifo
}

///|
/// Phase of checkout reported by `PoolError::Timeout`.
///
/// `Wait` means the caller could not obtain pool capacity in time, `Create`
/// means opening a new physical connection timed out, and `Recycle` means
/// checkout-time validation or cleanup of an idle connection timed out.
pub enum TimeoutKind {
  Wait
  Create
  Recycle
} derive(Eq, Debug)

///|
/// PostgreSQL transaction isolation level accepted by `TransactionBuilder`.
pub enum IsolationLevel {
  ReadUncommitted
  ReadCommitted
  RepeatableRead
  Serializable
} derive(Eq, Debug)

///|
/// Construct `READ UNCOMMITTED`.
pub fn IsolationLevel::read_uncommitted() -> IsolationLevel {
  ReadUncommitted
}

///|
/// Construct `READ COMMITTED`.
pub fn IsolationLevel::read_committed() -> IsolationLevel {
  ReadCommitted
}

///|
/// Construct `REPEATABLE READ`.
pub fn IsolationLevel::repeatable_read() -> IsolationLevel {
  RepeatableRead
}

///|
/// Construct `SERIALIZABLE`.
pub fn IsolationLevel::serializable() -> IsolationLevel {
  Serializable
}

///|
/// Optional checkout timeout overrides in milliseconds.
///
/// These values control how long the pool waits in each phase of `get()`:
/// waiting for capacity, creating a new connection, and recycling an idle
/// connection. `None` leaves the phase unbounded. Negative values are rejected
/// later when the timeouts are validated by `PoolConfig::new`, `Pool::get`, or
/// `Pool::timeout_get`.
pub struct Timeouts {
  /// Maximum wait for a checkout slot before raising `PoolError::Timeout(Wait)`.
  wait_ms : Int?
  /// Maximum wait for opening a new physical connection.
  create_ms : Int?
  /// Maximum wait for checkout-time recycling of an idle connection.
  recycle_ms : Int?
} derive(Eq, Debug)

///|
/// Construct one timeout record.
///
/// This constructor stores the values as-is and does not validate them yet.
/// `None` disables the corresponding timeout.
pub fn Timeouts::new(
  wait_ms? : Int? = None,
  create_ms? : Int? = None,
  recycle_ms? : Int? = None,
) -> Timeouts {
  { wait_ms, create_ms, recycle_ms }
}

///|
/// Checkout-time cleanup policy for already-open physical connections.
///
/// This policy runs only when the pool reuses an idle connection. New
/// connections skip it and instead run the optional `post_create` hook.
pub enum RecyclingMethod {
  Fast
  Verified
  Clean
  Custom(String)
} derive(Eq, Debug)

///|
/// Construct fast recycling mode.
///
/// The pool trusts the idle connection without sending any SQL.
pub fn RecyclingMethod::fast() -> RecyclingMethod {
  Fast
}

///|
/// Construct verified recycling mode.
///
/// The pool runs a lightweight connection check before handing the connection
/// out again.
pub fn RecyclingMethod::verified() -> RecyclingMethod {
  Verified
}

///|
/// Construct clean recycling mode.
///
/// The pool runs the same cleanup SQL sequence used by
/// `deadpool-postgres`-style "clean" recycling. In practice this closes
/// prepared statements, resets session settings, clears LISTEN state, releases
/// advisory locks, and discards temporary objects before reuse.
pub fn RecyclingMethod::clean() -> RecyclingMethod {
  Clean
}

///|
/// Construct custom recycling mode.
///
/// `sql` is executed with `batch_execute` during checkout of an idle
/// connection. If it fails or times out, that physical connection is discarded.
pub fn RecyclingMethod::custom(sql : String) -> RecyclingMethod {
  Custom(sql)
}

///|
/// Per-pool policy used by the manager during idle-connection recycling.
pub struct ManagerConfig {
  /// Cleanup strategy applied when reusing an idle connection.
  recycling_method : RecyclingMethod
} derive(Eq, Debug)

///|
/// Construct manager settings for one pool.
///
/// The default is `RecyclingMethod::fast()`, which performs no checkout-time
/// validation of idle connections.
pub fn ManagerConfig::new(
  recycling_method? : RecyclingMethod = Fast,
) -> ManagerConfig {
  { recycling_method, }
}

///|
/// Capacity and checkout policy for one pool instance.
pub struct PoolConfig {
  /// Maximum number of live physical PostgreSQL sessions owned by the pool.
  max_size : Int
  /// Default timeout policy used by `Pool::get()`.
  timeouts : Timeouts
  /// Strategy used when selecting from the idle connection list.
  queue_mode : QueueMode
} derive(Eq, Debug)

///|
/// Construct and validate one pool configuration.
///
/// `max_size` must be at least `1`, and each configured timeout must be
/// non-negative when present. On success this function has no side effects.
pub fn PoolConfig::new(
  max_size : Int,
  timeouts? : Timeouts = Timeouts::new(),
  queue_mode? : QueueMode = Fifo,
) -> PoolConfig raise {
  validate_pool_config({ max_size, timeouts, queue_mode })
  { max_size, timeouts, queue_mode }
}

///|
/// Failures raised while validating or normalizing declarative pool input.
///
/// These errors are reported before the pool opens any physical connection.
pub suberror ConfigError {
  UserMissing
  DbnameMissing
  DbnameEmpty
  PoolConfigMissing
  HostPortArityMismatch
  InvalidConfig(String)
} derive(Eq, Debug)

///|
/// PostgreSQL target-session policy checked right after a new connection opens.
///
/// `Any` accepts the first successfully opened target.
/// `ReadWrite` immediately runs `show transaction_read_only` and rejects a
/// target whose value is `on`, which is useful when the target list may contain
/// replicas.
pub enum TargetSessionAttrs {
  Any
  ReadWrite
} derive(Eq, Debug)

///|
/// Construct `Any`.
pub fn TargetSessionAttrs::any() -> TargetSessionAttrs {
  Any
}

///|
/// Construct `ReadWrite`.
pub fn TargetSessionAttrs::read_write() -> TargetSessionAttrs {
  ReadWrite
}

///|
/// Host-ordering strategy used before opening a new physical connection.
///
/// This affects only the order in which candidate targets are tried for a new
/// connection. It does not reshuffle already-open idle connections, and it does
/// not move a checked-out client from one target to another.
pub(all) enum LoadBalanceHosts {
  Disable
  Random
} derive(Eq, Debug)

///|
/// Declarative input used to derive one pool plus one or more concrete
/// connection targets.
///
/// All fields are explicit. Validation is deferred until callers ask for
/// normalized output via `builder`, `create_pool`, `get_pool_config`, or
/// `get_connection_targets`.
pub(all) struct Config {
  user : String?
  password : String?
  dbname : String?
  options : String?
  application_name : String
  ssl_mode : @client.SslMode?
  ssl_root_cert : String?
  channel_binding : @client.ChannelBinding?
  host : String?
  hosts : Array[String]?
  hostaddr : String?
  hostaddrs : Array[String]?
  port : Int?
  ports : Array[Int]?
  connect_timeout_ms : Int?
  keepalives : Bool?
  keepalives_idle_s : Int?
  target_session_attrs : TargetSessionAttrs?
  load_balance_hosts : LoadBalanceHosts?
  manager : ManagerConfig?
  pool : PoolConfig?
} derive(Eq, Debug)

///|
/// Build declarative pool config with client-style required inputs.
///
/// The first target is described by the same core fields as `@client.Config`,
/// then optional pool-specific multi-target and manager settings can be added
/// on top. Defaults keep the secure client path: port `5432`,
/// `ssl_mode = VerifyFull`, and `dbname = user`.
pub fn Config::new(
  host : String,
  hostaddr? : String,
  port? : Int = 5432,
  user~ : String,
  dbname? : String = user,
  password? : String,
  ssl_mode? : @client.SslMode = @client.SslMode::VerifyFull,
  ssl_root_cert? : String,
  channel_binding? : @client.ChannelBinding = @client.ChannelBinding::Disable,
  application_name~ : String,
  options? : String,
  connect_timeout_ms? : Int,
  keepalives? : Bool,
  keepalives_idle_s? : Int,
  hosts? : Array[String],
  hostaddrs? : Array[String],
  ports? : Array[Int],
  target_session_attrs? : TargetSessionAttrs = Any,
  load_balance_hosts? : LoadBalanceHosts = Disable,
  manager? : ManagerConfig,
  pool? : PoolConfig,
) -> Config {
  {
    user: Some(user),
    password,
    dbname: Some(dbname),
    options,
    application_name,
    ssl_mode: Some(ssl_mode),
    ssl_root_cert,
    channel_binding: Some(channel_binding),
    host: Some(host),
    hosts,
    hostaddr,
    hostaddrs,
    port: Some(port),
    ports,
    connect_timeout_ms,
    keepalives,
    keepalives_idle_s,
    target_session_attrs: Some(target_session_attrs),
    load_balance_hosts: Some(load_balance_hosts),
    manager,
    pool,
  }
}

///|
/// Point-in-time snapshot of one pool's runtime state.
pub struct Status {
  /// Number of currently live physical connections, both idle and checked out.
  size : Int
  /// Number of idle connections immediately available for reuse.
  available : Int
  /// Number of tasks currently waiting for capacity in `get()` or `timeout_get()`.
  waiting : Int
  /// Current configured connection limit for the pool.
  max_size : Int
  /// Whether `Pool::close()` has started and new checkouts are rejected.
  closed : Bool
} derive(Eq, Debug)

///|
/// Failures raised by pool lifecycle, checkout, and scoped-handle operations.
///
/// `LeaseReleased` reports use-after-scope on pooled handles, `Closed` rejects
/// new checkouts after `Pool::close()`, `Timeout` identifies the checkout phase
/// that expired, and `OperationInProgress` reports an exclusive scope conflict.
pub suberror PoolError {
  Closed
  Timeout(TimeoutKind)
  LeaseReleased
  OperationInProgress
  RowCount(String)
  InvalidConfig(String)
} derive(Eq, @debug.Debug)

///|
/// Validate pool config values before the pool is built.
fn validate_pool_config(config : PoolConfig) -> Unit raise {
  if config.max_size < 1 {
    raise PoolError::InvalidConfig("pool max_size must be at least 1")
  }
  validate_timeout("wait_ms", config.timeouts.wait_ms)
  validate_timeout("create_ms", config.timeouts.create_ms)
  validate_timeout("recycle_ms", config.timeouts.recycle_ms)
}

///|
/// Validate that an optional timeout is non-negative.
fn validate_timeout(name : String, timeout_ms : Int?) -> Unit raise {
  match timeout_ms {
    Some(timeout_ms) =>
      if timeout_ms < 0 {
        raise PoolError::InvalidConfig("pool \{name} must be non-negative")
      }
    None => ()
  }
}

///|
/// Fully normalized declarative config ready to create client targets.
priv struct NormalizedConfig {
  hosts : Array[String?]
  hostaddrs : Array[String?]
  ports : Array[Int]
  user : String
  password : String?
  dbname : String
  options : String?
  application_name : String
  ssl_mode : @client.SslMode
  ssl_root_cert : String?
  channel_binding : @client.ChannelBinding
  connect_timeout_ms : Int?
  keepalives : Bool?
  keepalives_idle_s : Int?
  target_session_attrs : TargetSessionAttrs
  load_balance_hosts : LoadBalanceHosts
}

///|
/// Return the manager config that will be used for this pool.
///
/// When `self.manager` is absent this function synthesizes the default
/// `ManagerConfig::new()` value. It does not open any connection or validate
/// other parts of the declarative config.
pub fn Config::get_manager_config(self : Config) -> ManagerConfig {
  self.manager.unwrap_or(ManagerConfig::new())
}

///|
/// Return the validated pool-capacity config for this declarative input.
///
/// The caller must have provided `self.pool`. The returned value is validated on
/// every call, so negative timeouts or `max_size < 1` still fail here even if
/// the `PoolConfig` record was assembled manually.
pub fn Config::get_pool_config(self : Config) -> PoolConfig raise {
  match self.pool {
    Some(pool) => {
      validate_pool_config(pool)
      pool
    }
    None => raise ConfigError::PoolConfigMissing
  }
}

///|
/// Expand declarative host settings into concrete single-target client configs.
///
/// Each returned `@client.Config` describes exactly one target address and is
/// ready to pass to the connector. This step broadcasts host and port arrays
/// when needed and rejects incomplete or contradictory inputs before any
/// network connection is opened.
pub fn Config::get_connection_targets(
  self : Config,
) -> Array[@client.Config] raise {
  let normalized = normalize_config(self)
  let targets : Array[@client.Config] = []
  for i in 0..<normalized.ports.length() {
    targets.push(make_client_config(normalized, i))
  }
  targets
}

///|
/// Normalize explicit config fields into concrete target arrays.
fn normalize_config(config : Config) -> NormalizedConfig raise {
  let hosts : Array[String?] = []
  match config.host {
    Some(host) => hosts.push(Some(host))
    None => ()
  }
  match config.hosts {
    Some(extra_hosts) =>
      for host in extra_hosts {
        hosts.push(Some(host))
      }
    None => ()
  }
  let hostaddrs = choose_optional_string_array(
    config.hostaddr,
    config.hostaddrs,
  )
  let ports = choose_int_array(config.port, config.ports)
  let target_count = infer_target_count(hosts, hostaddrs, ports)
  let has_explicit_host = hosts.length() > 0 || hostaddrs.length() > 0
  if hosts.length() == 0 {
    if target_count == 1 && hostaddrs.length() == 0 {
      hosts.push(Some("127.0.0.1"))
    } else {
      for _ in 0..<target_count {
        hosts.push(None)
      }
    }
  }
  let user = match config.user {
    Some(user) => user
    None => raise ConfigError::UserMissing
  }
  let dbname = match config.dbname {
    Some(dbname) =>
      if dbname == "" {
        raise ConfigError::DbnameEmpty
      } else {
        dbname
      }
    None => raise ConfigError::DbnameMissing
  }
  let ssl_mode = choose_ssl_mode(config.ssl_mode)
  let ssl_root_cert = config.ssl_root_cert
  validate_tls_config(ssl_mode, ssl_root_cert, has_explicit_host)
  {
    hosts,
    hostaddrs: broadcast_optional_strings(hostaddrs, target_count),
    ports: broadcast_ints(ports, target_count, 5432),
    user,
    password: config.password,
    dbname,
    options: config.options,
    application_name: config.application_name,
    ssl_mode,
    ssl_root_cert,
    channel_binding: choose_channel_binding(config.channel_binding),
    connect_timeout_ms: config.connect_timeout_ms,
    keepalives: config.keepalives,
    keepalives_idle_s: config.keepalives_idle_s,
    target_session_attrs: choose_target_session_attrs(
      config.target_session_attrs,
    ),
    load_balance_hosts: choose_load_balance_hosts(config.load_balance_hosts),
  }
}

///|
/// Build one concrete client config from a normalized target entry.
fn make_client_config(
  normalized : NormalizedConfig,
  index : Int,
) -> @client.Config {
  @client.Config::from_parts(
    normalized.hosts[index].unwrap_or(""),
    normalized.hostaddrs[index],
    normalized.ports[index],
    normalized.user,
    normalized.dbname,
    normalized.password,
    normalized.ssl_mode,
    normalized.ssl_root_cert,
    normalized.channel_binding,
    normalized.application_name,
    normalized.options,
    normalized.connect_timeout_ms,
    normalized.keepalives,
    normalized.keepalives_idle_s,
  )
}

///|
/// Return the number of targets implied by the current host, hostaddr, and port arrays.
fn infer_target_count(
  hosts : Array[String?],
  hostaddrs : Array[String],
  ports : Array[Int],
) -> Int {
  let mut count = hosts.length()
  if hostaddrs.length() > count {
    count = hostaddrs.length()
  }
  if ports.length() > count {
    count = ports.length()
  }
  if count == 0 {
    1
  } else {
    count
  }
}

///|
/// Broadcast optional host addresses to the target count.
fn broadcast_optional_strings(
  values : Array[String],
  count : Int,
) -> Array[String?] raise {
  if values.length() == 0 {
    return Array::make(count, None)
  }
  if values.length() == 1 {
    return Array::make(count, Some(values[0]))
  }
  if values.length() != count {
    raise ConfigError::HostPortArityMismatch
  }
  values.map(value => Some(value))
}

///|
/// Broadcast ports to the target count.
fn broadcast_ints(
  values : Array[Int],
  count : Int,
  default : Int,
) -> Array[Int] raise {
  if values.length() == 0 {
    return Array::make(count, default)
  }
  if values.length() == 1 {
    return Array::make(count, values[0])
  }
  if values.length() != count {
    raise ConfigError::HostPortArityMismatch
  }
  values
}

///|
/// Choose one string array override from scalar-or-array values.
fn choose_optional_string_array(
  scalar : String?,
  array : Array[String]?,
) -> Array[String] {
  match array {
    Some(array) => array
    None =>
      match scalar {
        Some(value) => [value]
        None => []
      }
  }
}

///|
/// Choose one integer array override from scalar-or-array values.
fn choose_int_array(scalar : Int?, array : Array[Int]?) -> Array[Int] {
  match array {
    Some(array) => array
    None =>
      match scalar {
        Some(value) => [value]
        None => []
      }
  }
}

///|
/// Choose one SSL mode override.
fn choose_ssl_mode(selected : @client.SslMode?) -> @client.SslMode {
  selected.unwrap_or(@client.SslMode::VerifyFull)
}

///|
fn validate_tls_config(
  ssl_mode : @client.SslMode,
  ssl_root_cert : String?,
  has_explicit_host : Bool,
) -> Unit raise {
  match ssl_root_cert {
    Some(root_cert) =>
      if root_cert == "system" && ssl_mode != @client.SslMode::VerifyFull {
        raise ConfigError::InvalidConfig(
          "sslrootcert=system requires sslmode=verify-full",
        )
      }
    None => ()
  }
  if ssl_mode == @client.SslMode::VerifyFull && !has_explicit_host {
    raise ConfigError::InvalidConfig(
      "sslmode=verify-full requires explicit host or hostaddr",
    )
  }
}

///|
/// Choose one channel-binding override.
fn choose_channel_binding(
  selected : @client.ChannelBinding?,
) -> @client.ChannelBinding {
  selected.unwrap_or(@client.ChannelBinding::Disable)
}

///|
/// Choose one target-session-attrs override.
fn choose_target_session_attrs(
  selected : TargetSessionAttrs?,
) -> TargetSessionAttrs {
  selected.unwrap_or(Any)
}

///|
/// Choose one load-balancing override.
fn choose_load_balance_hosts(selected : LoadBalanceHosts?) -> LoadBalanceHosts {
  selected.unwrap_or(Disable)
}
