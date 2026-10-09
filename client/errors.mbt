// Error values surfaced by the client package.

///|
/// PostgreSQL `ErrorResponse` and `NoticeResponse` fields.
///
/// Optional fields are independent: one object name does not imply another.
/// Positions preserve PostgreSQL's one-based character indices, not byte or
/// UTF-16 offsets. Unknown protocol tags are ignored.
pub struct DatabaseError {
  /// Localizable human-readable severity from `S`, for example `"ERROR"`.
  severity : String?
  /// Nonlocalized severity from `V`, independent of `severity`.
  severity_nonlocalized : String?
  /// Five-character SQLSTATE code when the server provided one.
  code : String?
  /// Primary error message, defaulting to `"database error"` when absent.
  message : String
  /// Optional extra detail from PostgreSQL.
  detail : String?
  /// Optional hint from PostgreSQL describing a likely fix.
  hint : String?
  /// Schema name associated with the error, if supplied.
  schema : String?
  /// Table name associated with the error, if supplied.
  table : String?
  /// Column name associated with the error, if supplied.
  column : String?
  /// Data type name associated with the error, if supplied.
  datatype : String?
  /// Constraint (or index) name associated with the error, if supplied.
  constraint : String?
  /// One-based character index into the query submitted by the client.
  position : UInt?
  /// One-based character index into `internal_query`.
  internal_position : UInt?
  /// Failed internally generated command, for example from PL/pgSQL.
  internal_query : String?
  /// Error context, including procedural call stacks, possibly multiline.
  where_ : String?
  /// PostgreSQL source file reporting the error.
  file : String?
  /// Line number in the PostgreSQL source file reporting the error.
  line : UInt?
  /// PostgreSQL source routine reporting the error.
  routine : String?
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
  /// The executor has not completed connection startup.
  NotReady
  /// `ClientExecutor::run` was called more than once.
  ExecutorAlreadyStarted
  /// The client, statement, portal, or transaction is closed or its scope expired.
  Closed(String)
  /// The statement belongs to another connection. No request was submitted.
  StatementConnectionMismatch
  /// A server reply violated driver expectations.
  Protocol(String)
  /// A client creation option is invalid.
  InvalidConfig(String)
  /// A savepoint name is empty or contains a NUL character.
  InvalidSavepointName(String)
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
  /// A transaction callback returned while a nested transaction was still open.
  UnfinishedChildTransaction
  /// The driver received a backend message that does not fit the current state.
  UnexpectedMessage(String)
} derive(Debug, Eq)
