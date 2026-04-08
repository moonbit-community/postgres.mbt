///|
/// Shared protocol primitives.
///
/// Primary reference:
/// - https://www.postgresql.org/docs/current/protocol.html
/// Protocol error type used when a packet violates the wire-level invariants
/// described in PostgreSQL protocol Sections 54.6 and 54.7.
pub(all) suberror ProtocolError {
  InvalidInput(String)
  UnexpectedEof(String)
  Overflow(String)
} derive(Show, Eq)

///|
/// A PostgreSQL object identifier.
///
/// OIDs are transmitted on the wire as 32-bit unsigned integers and appear in
/// messages such as `ParameterDescription` and `RowDescription`.
pub type Oid = UInt

///|
/// A PostgreSQL Log Sequence Number (LSN).
///
/// On the wire this is a big-endian 64-bit unsigned integer.
pub type Lsn = UInt64

///|
/// Whether a length-prefixed value is present.
///
/// PostgreSQL uses a signed `Int32` length field for many values. `-1` denotes
/// SQL NULL, while any non-negative value is followed by exactly that many
/// payload bytes.
pub(all) enum IsNull {
  Yes
  No
}
