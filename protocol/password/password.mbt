///|
/// PostgreSQL-compatible password hash helpers used by authentication code.
///
/// Primary references:
/// - https://www.postgresql.org/docs/current/auth-password.html#AUTH-PASSWORD
/// - https://www.postgresql.org/docs/current/sasl-authentication.html#SASL-SCRAM-SHA-256

///|
let scram_default_iterations = 4096

///|
let scram_default_salt_len = 16

///|
/// Hash password using SCRAM-SHA-256 with a caller-provided salt.
///
/// See:
/// - https://www.postgresql.org/docs/current/auth-password.html#AUTH-PASSWORD
/// - https://www.postgresql.org/docs/current/sasl-authentication.html#SASL-SCRAM-SHA-256
pub fn scram_sha_256(
  password : BytesView,
  salt : BytesView,
) -> Bytes raise @proto.ProtocolError {
  scram_sha_256_salt(password, salt)
}

///|
/// Hash password using SCRAM-SHA-256 with a provided salt.
///
/// See:
/// - https://www.postgresql.org/docs/current/auth-password.html#AUTH-PASSWORD
/// - https://www.postgresql.org/docs/current/sasl-authentication.html#SASL-SCRAM-SHA-256
pub fn scram_sha_256_salt(
  password : BytesView,
  salt : BytesView,
) -> Bytes raise @proto.ProtocolError {
  if salt.length() != scram_default_salt_len {
    raise @proto.ProtocolError::InvalidInput("invalid SCRAM salt length")
  }
  let prepared = @auth.normalize(password)
  let salted_password = @auth.hi(prepared[:], salt, scram_default_iterations)
  let client_key = @crypto.hmac_sha256(salted_password[:], b"Client Key"[:])
  let stored_key = @crypto.sha256_bytes(client_key[:])
  let server_key = @crypto.hmac_sha256(salted_password[:], b"Server Key"[:])
  let salt_b64 = @proto.utf8_encode(@base64.encode(salt))
  let stored_b64 = @proto.utf8_encode(@base64.encode(stored_key[:]))
  let server_b64 = @proto.utf8_encode(@base64.encode(server_key[:]))
  let out = @buffer.new(
    size_hint=11 +
      1 +
      4 +
      1 +
      salt_b64.length() +
      1 +
      stored_b64.length() +
      1 +
      server_b64.length(),
  )
  out.write_bytesview(b"SCRAM-SHA-256"[:])
  out.write_bytesview(b"$"[:])
  out.write_bytesview(
    @proto.utf8_encode(scram_default_iterations.to_string())[:],
  )
  out.write_bytesview(b":"[:])
  out.write_bytesview(salt_b64[:])
  out.write_bytesview(b"$"[:])
  out.write_bytesview(stored_b64[:])
  out.write_bytesview(b":"[:])
  out.write_bytesview(server_b64[:])
  out.to_bytes()
}
