// Connection configuration and TLS policy for the PostgreSQL client package.

///|
/// Controls how the client negotiates TLS when opening a TCP connection.
///
/// The modes are intentionally strict:
/// plaintext is opt-in via `Disable`, while TLS-using callers choose between
/// certificate-chain verification with or without endpoint identity checks.
pub(all) enum SslMode {
  /// Explicit plaintext mode.
  ///
  /// The client skips PostgreSQL SSL negotiation, does not encrypt traffic,
  /// and does not verify the server's identity.
  Disable
  /// Require TLS and verify the server certificate chain.
  ///
  /// This mode never falls back to plaintext. It validates the certificate
  /// chain against the configured trust roots, **but it does not verify that the
  /// certificate matches the requested hostname or IP address!**
  ///
  /// Its security can approach `VerifyFull` only when a private CA issues
  /// certificates exclusively for the intended PostgreSQL endpoints.
  VerifyCa
  /// Require TLS, verify the certificate chain, and verify endpoint identity.
  ///
  /// This mode never falls back to plaintext. It validates both the server
  /// certificate chain and the requested hostname or IP address, and is the
  /// default and recommended mode.
  VerifyFull
} derive(Debug, Eq)

///|
/// Controls whether SCRAM channel binding is disabled, preferred, or required.
///
/// This setting matters only when PostgreSQL authenticates with SCRAM. It does
/// not enable TLS by itself and it does not affect non-SCRAM methods such as
/// plain password authentication.
/// It is also unrelated to TLS `sslmode`: this package still does not support
/// the removed libpq-style TLS aliases `sslmode=prefer` or `sslmode=require`.
///
/// `Disable` always uses plain `SCRAM-SHA-256`.
/// `Prefer` uses `SCRAM-SHA-256-PLUS` when the TLS transport exposes a
/// supported binding and the server advertises it, otherwise it falls back to
/// plain `SCRAM-SHA-256`.
/// `Require` insists on `SCRAM-SHA-256-PLUS` and fails when TLS or server
/// support is missing.
pub(all) enum ChannelBinding {
  Disable
  Prefer
  Require
} derive(Debug, Eq)

///|
/// Immutable configuration used by `connect` to establish a PostgreSQL session.
///
/// The same value is also retained inside the client runtime so that later
/// features, such as cancellation, can reopen a control connection with the
/// exact same host and port.
pub struct Config {
  /// Hostname used for TLS verification and default server-name handling.
  host : String
  /// Optional concrete address used for the TCP socket connection.
  hostaddr : String?
  /// TCP port for the PostgreSQL server.
  port : Int
  /// Login role used during startup authentication.
  user : String
  /// Database selected in the startup packet.
  database : String
  /// Optional password consumed by password-based authentication methods.
  password : String?
  /// TLS negotiation policy.
  ssl_mode : SslMode
  /// Root certificate file used to verify the server certificate chain.
  ///
  /// `None` keeps the platform default trust-store behavior. The special value
  /// `"system"` also selects the platform trust store and requires
  /// `ssl_mode == SslMode::VerifyFull`.
  ssl_root_cert : String?
  /// Channel-binding preference for SCRAM authentication.
  channel_binding : ChannelBinding
  /// Value sent as PostgreSQL `application_name`.
  application_name : String
  /// Optional PostgreSQL `options` startup parameter.
  options : String?
  /// Optional end-to-end connection timeout in milliseconds.
  connect_timeout_ms : Int?
  /// Whether TCP keepalive should be enabled on the socket.
  keepalives : Bool?
  /// Idle time in seconds before the first TCP keepalive probe.
  keepalives_idle_s : Int?
} derive(Debug, Eq)

///|
/// Build a configuration with PostgreSQL-friendly defaults.
///
/// Defaults are chosen to keep secure TLS on the main path: port `5432`,
/// `ssl_mode = SslMode::VerifyFull`, and database name equal to the user name.
/// Callers pass `application_name` explicitly.
pub fn Config::new(
  host : String,
  hostaddr? : String,
  port? : Int = 5432,
  user~ : String,
  database? : String = user,
  password? : String,
  ssl_mode? : SslMode = VerifyFull,
  ssl_root_cert? : String,
  channel_binding? : ChannelBinding = Disable,
  application_name~ : String,
  options? : String,
  connect_timeout_ms? : Int,
  keepalives? : Bool,
  keepalives_idle_s? : Int,
) -> Config {
  {
    host,
    hostaddr,
    port,
    user,
    database,
    password,
    ssl_mode,
    ssl_root_cert,
    channel_binding,
    application_name,
    options,
    connect_timeout_ms,
    keepalives,
    keepalives_idle_s,
  }
}

///|
/// Construct a fully resolved single-target config from explicit parts.
pub fn Config::from_parts(
  host : String,
  hostaddr : String?,
  port : Int,
  user : String,
  database : String,
  password : String?,
  ssl_mode : SslMode,
  ssl_root_cert : String?,
  channel_binding : ChannelBinding,
  application_name : String,
  options : String?,
  connect_timeout_ms : Int?,
  keepalives : Bool?,
  keepalives_idle_s : Int?,
) -> Config {
  {
    host,
    hostaddr,
    port,
    user,
    database,
    password,
    ssl_mode,
    ssl_root_cert,
    channel_binding,
    application_name,
    options,
    connect_timeout_ms,
    keepalives,
    keepalives_idle_s,
  }
}
