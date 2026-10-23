// Pure PBKDF2 state shared by synchronous Hi and incremental SCRAM. Construction
// performs no HMAC, so the caller controls every unit of derivation work.

///|
priv struct HiState {
  password : Bytes
  mut previous : Bytes
  mut result : Bytes
  mut remaining : Int32
}

///|
fn HiState::new(
  password : BytesView,
  salt : BytesView,
  iterations : Int32,
) -> HiState raise @proto.ProtocolError {
  if iterations <= 0 {
    raise InvalidInput("iteration count must be positive")
  }
  let first = Buffer(size_hint=salt.length() + 4)
  first.write_bytesview(salt)
  first.write_bytes(b"\x00\x00\x00\x01")
  {
    password: password.to_owned(),
    previous: first.to_bytes(),
    result: Bytes::make(32, 0),
    remaining: iterations,
  }
}

///|
/// Return the actual number of HMAC operations performed, up to `max_steps`.
fn HiState::advance(self : HiState, max_steps : Int32) -> Int32 {
  let steps = Int32::min(self.remaining, max_steps)
  for _ in 0..<steps {
    self.previous = @crypto.hmac_sha256(self.password[:], self.previous[:])
    self.result = xor_bytes(self.result[:], self.previous[:])
    self.remaining -= 1
  }
  steps
}
