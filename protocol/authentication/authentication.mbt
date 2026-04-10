///|
/// Authentication helpers for PostgreSQL startup negotiation.
///
/// Primary references:
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-START-UP
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-AUTHENTICATIONMD5PASSWORD
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-PASSWORDMESSAGE
/// Build the legacy response for `AuthenticationMD5Password`.
///
/// PostgreSQL sends a 4-byte salt in the backend authentication request. The
/// frontend must reply with ASCII `md5` followed by the hex-encoded digest of
/// `md5(md5(password || username) || salt)`.
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-AUTHENTICATIONMD5PASSWORD
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-PASSWORDMESSAGE
pub fn md5_hash(
  username : BytesView,
  password : BytesView,
  salt : BytesView,
) -> Bytes raise @proto.ProtocolError {
  if salt.length() != 4 {
    raise @proto.ProtocolError::InvalidInput("invalid MD5 salt length")
  }
  let input = @buffer.new(size_hint=password.length() + username.length())
  input.write_bytesview(password)
  input.write_bytesview(username)
  let first_hex = @crypto.md5_hex(input.to_bytes()[:])
  let second_input = @buffer.new(size_hint=first_hex.length() + salt.length())
  second_input.write_bytesview(first_hex[:])
  second_input.write_bytesview(salt)
  let second_hex = @crypto.md5_hex(second_input.to_bytes()[:])
  let out = @buffer.new(size_hint=3 + second_hex.length())
  out.write_bytesview(b"md5"[:])
  out.write_bytesview(second_hex[:])
  out.to_bytes()
}
