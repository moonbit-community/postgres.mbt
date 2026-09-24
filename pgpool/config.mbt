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
/// Re-export the client isolation level for pooled transaction options.
pub using @client {type IsolationLevel}

///|
/// Options for the `BEGIN` command used when opening a pooled transaction.
pub struct TransactionOptions {
  /// Optional transaction isolation level.
  isolation_level : IsolationLevel?
  /// `Some(true)` emits `READ ONLY`; `Some(false)` emits `READ WRITE`.
  read_only : Bool?
  /// `Some(true)` emits `DEFERRABLE`; `Some(false)` emits `NOT DEFERRABLE`.
  deferrable : Bool?
} derive(Eq, Debug)

///|
/// Build transaction options for a future `BEGIN` command.
pub fn TransactionOptions::TransactionOptions(
  isolation_level? : IsolationLevel,
  read_only? : Bool,
  deferrable? : Bool,
) -> TransactionOptions {
  { isolation_level, read_only, deferrable, }
}

///|
/// Optional checkout timeout overrides in milliseconds.
///
/// These values control how long the pool waits for capacity, creates a new
/// connection, or recycles an idle connection. `None` leaves the phase
/// unbounded. Negative values are rejected by `PoolConfig::PoolConfig` or checkout.
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
pub fn Timeouts::Timeouts(
  wait_ms? : Int? = None,
  create_ms? : Int? = None,
  recycle_ms? : Int? = None,
) -> Timeouts {
  { wait_ms, create_ms, recycle_ms, }
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
/// open portals/cursors, resets session settings, clears LISTEN state, releases
/// advisory locks, and discards temporary objects before reuse.
/// Prepared statements and their cached plans are preserved so the
/// connection-local statement cache remains effective across checkouts.
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
/// Capacity and checkout policy for one pool instance.
pub struct PoolConfig {
  /// Maximum number of live physical PostgreSQL sessions owned by the pool.
  max_size : Int
  /// Default timeout policy used by automatic checkout.
  timeouts : Timeouts
  /// Strategy used when selecting from the idle connection list.
  queue_mode : QueueMode
  /// Cleanup strategy applied when reusing an idle connection.
  recycling_method : RecyclingMethod
  /// Maximum prepared statements cached on each physical connection.
  ///
  /// `0` disables caching.
  statement_cache_capacity : Int
  /// Maximum asynchronous messages retained across physical connections.
  async_message_capacity : Int
} derive(Eq, Debug)

///|
/// Construct and validate one pool configuration.
///
/// `max_size` and `async_message_capacity` must be positive. Each configured
/// timeout must be non-negative when present. On success this has no side effects.
pub fn PoolConfig::PoolConfig(
  max_size : Int,
  timeouts? : Timeouts = Timeouts(),
  queue_mode? : QueueMode = Fifo,
  recycling_method? : RecyclingMethod = Fast,
  statement_cache_capacity? : Int = 100,
  async_message_capacity? : Int = 256,
) -> PoolConfig raise {
  validate_pool_config({
    max_size,
    timeouts,
    queue_mode,
    recycling_method,
    statement_cache_capacity,
    async_message_capacity,
  })
  {
    max_size,
    timeouts,
    queue_mode,
    recycling_method,
    statement_cache_capacity,
    async_message_capacity,
  }
}

///|
/// Failures raised while validating declarative pool input.
///
/// These errors are reported before the pool opens any physical connection.
pub suberror ConfigError {
  UsernameEmpty
  DbnameEmpty
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
/// One PostgreSQL endpoint. When both addresses are set, the client connects
/// to `hostaddr` and uses `host` for TLS hostname verification.
pub struct ConnectionTarget {
  /// Hostname used for TLS verification and DNS connection when no address is set.
  host : String?
  /// Concrete address used for the TCP connection when present.
  hostaddr : String?
  /// TCP port for this endpoint.
  port : Int
} derive(Eq, Debug)

///|
/// Construct one endpoint. `Config::Config` validates its address and port.
pub fn ConnectionTarget::ConnectionTarget(
  host? : String,
  hostaddr? : String,
  port? : Int = 5432,
) -> ConnectionTarget {
  { host, hostaddr, port, }
}

///|
/// Declarative input used to derive one pool and its connection targets.
///
/// The constructor validates all endpoints and common connection settings.
pub struct Config {
  user : String
  /// Optional in the declarative config, but required at connection startup
  /// when PostgreSQL selects password or SCRAM authentication.
  password : String?
  dbname : String
  options : String?
  application_name : String
  ssl_mode : @client.SslMode?
  ssl_root_cert : String?
  channel_binding : @client.ChannelBinding?
  priv targets : Array[ConnectionTarget]
  connect_timeout_ms : Int?
  keepalives : Bool?
  keepalives_idle_s : Int?
  target_session_attrs : TargetSessionAttrs?
  load_balance_hosts : LoadBalanceHosts?
  pool : PoolConfig
} derive(Eq, Debug)

///|
/// Return a read-only view of the configured endpoints in connection order.
pub fn Config::targets(self : Config) -> ArrayView[ConnectionTarget] {
  self.targets[:]
}

///|
/// Build a pool config from an ordered, non-empty list of endpoints.
///
/// The target array is copied. Defaults keep the secure client path:
/// `ssl_mode = VerifyFull` and `dbname = user`.
pub fn Config::Config(
  targets : Array[ConnectionTarget],
  user~ : String,
  dbname? : String = user,
  password? : String,
  ssl_mode? : @client.SslMode = VerifyFull,
  ssl_root_cert? : String,
  channel_binding? : @client.ChannelBinding = Disable,
  application_name~ : String,
  options? : String,
  connect_timeout_ms? : Int,
  keepalives? : Bool,
  keepalives_idle_s? : Int,
  target_session_attrs? : TargetSessionAttrs = Any,
  load_balance_hosts? : LoadBalanceHosts = Disable,
  pool~ : PoolConfig,
) -> Config raise {
  validate_connection_targets(targets)
  if user == "" {
    raise ConfigError::UsernameEmpty
  }
  if dbname == "" {
    raise ConfigError::DbnameEmpty
  }
  validate_tls_config(ssl_mode, ssl_root_cert)
  {
    user,
    password,
    dbname,
    options,
    application_name,
    ssl_mode: Some(ssl_mode),
    ssl_root_cert,
    channel_binding: Some(channel_binding),
    targets: targets.copy(),
    connect_timeout_ms,
    keepalives,
    keepalives_idle_s,
    target_session_attrs: Some(target_session_attrs),
    load_balance_hosts: Some(load_balance_hosts),
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
  /// Number of tasks currently waiting for pool capacity.
  waiting : Int
  /// Current configured connection limit for the pool.
  max_size : Int
  /// Whether `Pool::close()` has started and new checkouts are rejected.
  closed : Bool
} derive(Eq, Debug)

///|
/// Failures raised by pool lifecycle, checkout, and scoped-handle operations.
///
/// `ScopeExpired` reports use-after-scope on pooled handles, `Closed` rejects
/// new checkouts after `Pool::close()`, and `Timeout` identifies the checkout
/// phase that expired.
pub suberror PoolError {
  Closed
  ExecutorAlreadyStarted
  Timeout(TimeoutKind)
  ScopeExpired
  /// A lifecycle hook returned with an open transaction; the connection was discarded.
  HookLeftOpenTransaction
  InvalidConfig(String)
} derive(Eq, @debug.Debug)

///|
/// Validate pool config values before the pool is built.
fn validate_pool_config(config : PoolConfig) -> Unit raise {
  if config.max_size < 1 {
    raise PoolError::InvalidConfig("pool max_size must be at least 1")
  }
  if config.statement_cache_capacity < 0 {
    raise PoolError::InvalidConfig(
      "statement_cache_capacity must be non-negative",
    )
  }
  if config.async_message_capacity < 1 {
    raise PoolError::InvalidConfig("async_message_capacity must be positive")
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
/// Return the validated pool-capacity config for this declarative input.
pub fn Config::get_pool_config(self : Config) -> PoolConfig raise {
  validate_pool_config(self.pool)
  self.pool
}

///|
/// Build one client config per endpoint, preserving the configured order.
///
/// Each target connects to its own address and port. When both addresses are
/// present, the client connects to `hostaddr` and verifies TLS against `host`.
pub fn Config::get_connection_targets(self : Config) -> Array[@client.Config] {
  let targets : Array[@client.Config] = []
  for target in self.targets {
    targets.push(
      @client.Config::new_internal(
        target.host.unwrap_or(""),
        target.hostaddr,
        target.port,
        self.user,
        self.dbname,
        self.password,
        self.ssl_mode.unwrap_or(VerifyFull),
        self.ssl_root_cert,
        self.channel_binding.unwrap_or(Disable),
        self.application_name,
        self.options,
        self.connect_timeout_ms,
        self.keepalives,
        self.keepalives_idle_s,
      ),
    )
  }
  targets
}

///|
/// Validate every address and port before a config can be constructed.
fn validate_connection_targets(targets : Array[ConnectionTarget]) -> Unit raise {
  if targets.length() == 0 {
    raise ConfigError::InvalidConfig("targets must not be empty")
  }
  for index in 0..<targets.length() {
    let target = targets[index]
    if !is_non_empty_string(target.host) &&
      !is_non_empty_string(target.hostaddr) {
      raise ConfigError::InvalidConfig(
        "target \{index}: host or hostaddr must be non-empty",
      )
    }
    if target.port < 1 || target.port > 65535 {
      raise ConfigError::InvalidConfig(
        "target \{index}: port must be between 1 and 65535",
      )
    }
  }
}

///|
fn is_non_empty_string(value : String?) -> Bool {
  match value {
    Some(value) => value != ""
    None => false
  }
}

///|
fn validate_tls_config(
  ssl_mode : @client.SslMode,
  ssl_root_cert : String?,
) -> Unit raise {
  match ssl_root_cert {
    Some(root_cert) =>
      if root_cert == "system" && ssl_mode != VerifyFull {
        raise ConfigError::InvalidConfig(
          "sslrootcert=system requires sslmode=verify-full",
        )
      }
    None => ()
  }
}
