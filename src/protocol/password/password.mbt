///|
let scram_default_iterations = 4096

///|
let scram_default_salt_len = 16

///|
/// Hash password using SCRAM-SHA-256 with a random salt.
pub fn scram_sha_256(password : BytesView) -> Bytes {
  let rng = @random.Rand::new()
  let salt = Array::make(scram_default_salt_len, b'\x00')
  for i in 0..<scram_default_salt_len {
    salt[i] = rng.int(limit=256).to_byte()
  }
  scram_sha_256_salt(password, Bytes::from_array(salt[:]))
}

///|
/// Hash password using SCRAM-SHA-256 with a provided salt.
pub fn scram_sha_256_salt(password : BytesView, salt : BytesView) -> Bytes {
  let prepared = @sasl.normalize(password)
  let salted_password = try! @sasl.hi(
    prepared[:],
    salt,
    scram_default_iterations,
  )
  let client_key = @crypto.hmac_sha256(salted_password[:], b"Client Key"[:])
  let stored_key = @crypto.sha256_bytes(client_key[:])
  let server_key = @crypto.hmac_sha256(salted_password[:], b"Server Key"[:])
  let salt_b64 = @base64.std_encode2bytes(salt.to_fixedarray())
  let stored_b64 = @base64.std_encode2bytes(stored_key.to_fixedarray())
  let server_b64 = @base64.std_encode2bytes(server_key.to_fixedarray())
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

///|
/// **Not recommended**. Hash password using MD5 with username as salt.
pub fn md5(password : BytesView, username : BytesView) -> Bytes {
  let input = @buffer.new(size_hint=password.length() + username.length())
  input.write_bytesview(password)
  input.write_bytesview(username)
  let digest = @crypto.md5_hex(input.to_bytes()[:])
  let out = @buffer.new(size_hint=3 + digest.length())
  out.write_bytesview(b"md5"[:])
  out.write_bytesview(digest[:])
  out.to_bytes()
}
