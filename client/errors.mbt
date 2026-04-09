// Error values surfaced by the client package.

///|
/// Structured subset of PostgreSQL `ErrorResponse` and `NoticeResponse` fields.
///
/// PostgreSQL emits many optional fields in protocol-level errors. The client
/// currently preserves the most actionable ones so callers can branch on SQL
/// state code, log a human-readable message, and surface hints or details to
/// operators.
pub struct DatabaseError {
  /// Human-readable severity, for example `"ERROR"` or `"NOTICE"`.
  severity : String?
  /// Five-character SQLSTATE code when the server provided one.
  code : String?
  /// Primary error message. This field is always populated.
  message : String
  /// Optional extra detail from PostgreSQL.
  detail : String?
  /// Optional hint from PostgreSQL describing a likely fix.
  hint : String?
} derive(Debug, Eq)

///|
/// Describes an early type mismatch detected by the driver.
///
/// The client validates encoder and decoder compatibility before invoking the
/// user-provided `ToSql` or `FromSql` implementation. That keeps failures
/// deterministic and prevents custom codec code from seeing obviously
/// incompatible PostgreSQL types.
pub struct WrongTypeError {
  /// The MoonBit-side type name reported by the codec implementation.
  moonbit_type : String
  /// The PostgreSQL column or parameter type that failed the compatibility check.
  postgres_type : Type
} derive(Debug, Eq)

///|
/// Top-level error union raised by client operations.
///
/// The variants are intentionally grouped by failure source:
/// database-originated failures, startup/authentication problems, connection
/// lifecycle issues, protocol violations, codec errors, and higher-level query
/// shape checks such as row-count assertions.
pub suberror ClientError {
  /// Server returned an `ErrorResponse`.
  Database(DatabaseError)
  /// Startup authentication could not be completed.
  Authentication(String)
  /// The client, statement, portal, or transaction is already closed.
  Closed(String)
  /// A server reply violated driver expectations.
  Protocol(String)
  /// TLS negotiation or handshake failed.
  Ssl(String)
  /// Query parameter encoding failed.
  Encode(String)
  /// Result value decoding failed.
  Decode(String)
  /// A `ToSql` or `FromSql` implementation does not accept the PostgreSQL type.
  WrongType(WrongTypeError)
  /// A named column lookup failed.
  ColumnNotFound(String)
  /// A helper such as `query_one` observed an unexpected row count.
  RowCount(String)
  /// The driver received a backend message that does not fit the current state.
  UnexpectedMessage(String)
} derive(Debug, Eq)
