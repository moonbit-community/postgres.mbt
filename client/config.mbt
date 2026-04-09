// Connection configuration and TLS policy for the PostgreSQL client package.

///|
/// Controls how the client negotiates TLS when opening a TCP connection.
///
/// `Disable` skips PostgreSQL SSL negotiation and always uses a plain socket.
/// `Prefer` first asks the server for TLS support and falls back to plain TCP
/// when the server replies with `N`.
/// `Require` also asks for TLS support, but treats a negative response as a
/// connection error because the caller explicitly requested encryption.
pub enum SslMode {
  Disable
  Prefer
  Require
} derive(Debug, Eq)

///|
/// Convenience constructor returning `SslMode::Disable`.
pub fn SslMode::disable() -> SslMode {
  Disable
}

///|
/// Convenience constructor returning `SslMode::Prefer`.
pub fn SslMode::prefer() -> SslMode {
  Prefer
}

///|
/// Convenience constructor returning `SslMode::Require`.
pub fn SslMode::require() -> SslMode {
  Require
}

///|
/// Immutable configuration used by `connect` to establish a PostgreSQL session.
///
/// The same value is also retained inside the client runtime so that later
/// features, such as cancellation, can reopen a control connection with the
/// exact same host and port.
pub struct Config {
  /// Hostname or IP address passed to the socket layer.
  host : String
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
  /// Value sent as PostgreSQL `application_name`.
  application_name : String
} derive(Debug, Eq)

///|
/// Build a configuration with PostgreSQL-friendly defaults.
///
/// Defaults are chosen to match common local-development expectations:
/// port `5432`, SSL disabled, database name equal to the user name, and an
/// application name of `"moonbit-postgres"`.
pub fn Config::new(
  host : String,
  user~ : String,
  database? : String = user,
  password? : String,
  port? : Int = 5432,
  ssl_mode? : SslMode = Disable,
  application_name? : String = "moonbit-postgres",
) -> Config {
  { host, port, user, database, password, ssl_mode, application_name }
}
