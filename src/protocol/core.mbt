///|
/// Protocol error type.
pub(all) suberror ProtocolError {
  InvalidInput(String)
  UnexpectedEof(String)
  Overflow(String)
} derive(Show, Eq)

///|
/// A Postgres OID.
pub type Oid = UInt

///|
/// A Postgres Log Sequence Number (LSN).
pub type Lsn = UInt64

///|
/// An enum indicating if a value is NULL or not.
pub(all) enum IsNull {
  Yes
  No
}
