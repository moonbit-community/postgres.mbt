///|
/// PostgreSQL protocol errors
pub(all) suberror ProtocolError {
  /// Invalid message format
  InvalidMessage(String)
  /// Unexpected message type
  UnexpectedMessage(Char)
  /// Authentication failure
  AuthenticationFailed(String)
  /// Connection error
  ConnectionError(String)
  /// Encoding/decoding error
  EncodingError(String)
  /// Buffer underflow when reading
  BufferUnderflow
  /// Invalid parameter
  InvalidParameter(String)
} derive(Show, Eq)

///|
/// SQL state error codes
pub(all) suberror SqlError {
  /// Generic error with SQL state and message
  SqlState(String, String)
  /// Specific common errors
  SyntaxError(String)
  DataException(String)
  IntegrityConstraintViolation(String)
  InvalidCursorState(String)
  TransactionRollback(String)
} derive(Show, Eq)
