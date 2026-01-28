///|
let nonce_length = 24

///|
/// Identifier of SCRAM-SHA-256 SASL authentication mechanism.
pub const SCRAM_SHA_256 : Bytes = b"SCRAM-SHA-256"

///|
/// Identifier of SCRAM-SHA-256-PLUS SASL authentication mechanism.
pub const SCRAM_SHA_256_PLUS : Bytes = b"SCRAM-SHA-256-PLUS"

///|
/// Normalize a password for SCRAM. This is a best-effort UTF-8 decode without SASLprep.
pub fn normalize(pass : BytesView) -> Bytes {
  try {
    let s = @utf8.decode(pass)
    @utf8.encode(s)
  } catch {
    _ => pass.to_bytes()
  }
}

///|
/// PBKDF2-HMAC-SHA256.
pub fn hi(
  str : BytesView,
  salt : BytesView,
  iterations : Int,
) -> Bytes raise @proto.ProtocolError {
  if iterations <= 0 {
    raise @proto.ProtocolError::InvalidInput("iteration count must be positive")
  }
  let buf = @buffer.new(size_hint=salt.length() + 4)
  buf.write_bytesview(salt)
  buf.write_bytesview(b"\x00\x00\x00\x01"[:])
  let mut prev = @crypto.hmac_sha256(str, buf.to_bytes()[:])
  let mut hi = prev
  for _ in 1..<iterations {
    prev = @crypto.hmac_sha256(str, prev[:])
    hi = xor_bytes(hi[:], prev[:])
  }
  hi
}

///|
fn xor_bytes(a : BytesView, b : BytesView) -> Bytes {
  let len = if a.length() < b.length() { a.length() } else { b.length() }
  let out = Array::make(len, b'\x00')
  for i in 0..<len {
    out[i] = a[i] ^ b[i]
  }
  Bytes::from_array(out[:])
}

///|
/// Channel binding configuration for SCRAM authentication.
pub enum ChannelBinding {
  Unrequested
  Unsupported
  TlsServerEndPoint(Bytes)
}

///|
pub fn ChannelBinding::unrequested() -> ChannelBinding {
  Unrequested
}

///|
pub fn ChannelBinding::unsupported() -> ChannelBinding {
  Unsupported
}

///|
pub fn ChannelBinding::tls_server_end_point(
  signature : Bytes,
) -> ChannelBinding {
  TlsServerEndPoint(signature)
}

///|
fn ChannelBinding::gs2_header(self : ChannelBinding) -> BytesView {
  match self {
    Unrequested => b"y,,"[:]
    Unsupported => b"n,,"[:]
    TlsServerEndPoint(_) => b"p=tls-server-end-point,,"[:]
  }
}

///|
fn ChannelBinding::cbind_data(self : ChannelBinding) -> BytesView {
  match self {
    Unrequested | Unsupported => b""[:]
    TlsServerEndPoint(sig) => sig[:]
  }
}

///|
enum State {
  Update(nonce~ : Bytes, password~ : Bytes, channel_binding~ : ChannelBinding)
  Finish(salted_password~ : Bytes, auth_message~ : Bytes)
  Done
}

///|
/// Client-side SCRAM-SHA-256 handler.
pub struct ScramSha256 {
  mut message : Bytes
  mut state : State
}

///|
/// Construct a new SCRAM-SHA-256 exchange using a random nonce.
pub fn ScramSha256::new(
  password : BytesView,
  channel_binding : ChannelBinding,
) -> ScramSha256 {
  let rng = @random.Rand::new()
  let nonce_bytes = Array::make(nonce_length, b'a')
  let span = 0x7e - 0x21 + 1
  for i in 0..<nonce_length {
    let mut v = rng.int(limit=span) + 0x21
    if v == 0x2c {
      v = 0x7e
    }
    nonce_bytes[i] = v.to_byte()
  }
  let nonce = Bytes::from_array(nonce_bytes[:])
  ScramSha256::new_inner(password, channel_binding, nonce)
}

///|
/// Construct a new SCRAM-SHA-256 exchange with a provided nonce (for tests).
pub fn ScramSha256::new_inner(
  password : BytesView,
  channel_binding : ChannelBinding,
  nonce : Bytes,
) -> ScramSha256 {
  let msg = @buffer.new(
    size_hint=channel_binding.gs2_header().length() + 4 + nonce.length(),
  )
  msg.write_bytesview(channel_binding.gs2_header())
  msg.write_bytesview(b"n=,r="[:])
  msg.write_bytesview(nonce[:])
  {
    message: msg.to_bytes(),
    state: Update(nonce~, password=normalize(password), channel_binding~),
  }
}

///|
/// Get the current client message to send.
pub fn ScramSha256::message(
  self : ScramSha256,
) -> BytesView raise @proto.ProtocolError {
  match self.state {
    Done => raise @proto.ProtocolError::InvalidInput("invalid SCRAM state")
    _ => self.message[:]
  }
}

///|
/// Update state with server first message.
pub fn ScramSha256::update(
  self : ScramSha256,
  message : BytesView,
) -> Unit raise @proto.ProtocolError {
  let (client_nonce, password, channel_binding) = match self.state {
    Update(nonce~, password~, channel_binding~) =>
      (nonce, password, channel_binding)
    _ => raise @proto.ProtocolError::InvalidInput("invalid SCRAM state")
  }
  let parsed = Parser::new(message).server_first_message()
  if not(starts_with(parsed.nonce[:], client_nonce[:])) {
    raise @proto.ProtocolError::InvalidInput("invalid nonce")
  }
  let salt_str = @base64.bytes2str(parsed.salt)
  let salt = @base64.std_decode2bytes(salt_str) catch {
    _ => raise @proto.ProtocolError::InvalidInput("invalid base64 salt")
  }
  let salted_password = hi(password[:], salt[:], parsed.iteration_count)
  let client_key = @crypto.hmac_sha256(salted_password[:], b"Client Key"[:])
  let stored_key = @crypto.sha256_bytes(client_key[:])
  let cbind = @buffer.new(
    size_hint=channel_binding.gs2_header().length() +
      channel_binding.cbind_data().length(),
  )
  cbind.write_bytesview(channel_binding.gs2_header())
  cbind.write_bytesview(channel_binding.cbind_data())
  let cbind_b64 = @base64.std_encode2bytes(cbind.to_bytes().to_fixedarray())
  let client_final = @buffer.new(
    size_hint=2 + cbind_b64.length() + 3 + parsed.nonce.length(),
  )
  client_final.write_bytesview(b"c="[:])
  client_final.write_bytesview(cbind_b64[:])
  client_final.write_bytesview(b",r="[:])
  client_final.write_bytesview(parsed.nonce[:])
  let client_final_without_proof = client_final.to_bytes()
  let auth = @buffer.new(
    size_hint=4 +
      client_nonce.length() +
      1 +
      message.length() +
      1 +
      client_final_without_proof.length(),
  )
  auth.write_bytesview(b"n=,r="[:])
  auth.write_bytesview(client_nonce[:])
  auth.write_bytesview(b","[:])
  auth.write_bytesview(message)
  auth.write_bytesview(b","[:])
  auth.write_bytesview(client_final_without_proof[:])
  let auth_message = auth.to_bytes()
  let client_signature = @crypto.hmac_sha256(stored_key[:], auth_message[:])
  let client_proof = xor_bytes(client_key[:], client_signature[:])
  let client_proof_b64 = @base64.std_encode2bytes(client_proof.to_fixedarray())
  let final_msg = @buffer.new(
    size_hint=client_final_without_proof.length() +
      3 +
      client_proof_b64.length(),
  )
  final_msg.write_bytesview(client_final_without_proof[:])
  final_msg.write_bytesview(b",p="[:])
  final_msg.write_bytesview(client_proof_b64[:])
  self.message = final_msg.to_bytes()
  self.state = Finish(salted_password~, auth_message~)
}

///|
/// Finish SCRAM exchange with server final message.
pub fn ScramSha256::finish(
  self : ScramSha256,
  message : BytesView,
) -> Unit raise @proto.ProtocolError {
  let (salted_password, auth_message) = match self.state {
    Finish(salted_password~, auth_message~) => (salted_password, auth_message)
    _ => raise @proto.ProtocolError::InvalidInput("invalid SCRAM state")
  }
  let parsed = Parser::new(message).server_final_message()
  let verifier_b64 = match parsed {
    ServerFinalMessage::Error(err) => {
      let msg = @base64.bytes2str(err)
      raise @proto.ProtocolError::InvalidInput("SCRAM error: \{msg}")
    }
    ServerFinalMessage::Verifier(v) => v
  }
  let verifier_str = @base64.bytes2str(verifier_b64)
  let verifier = @base64.std_decode2bytes(verifier_str) catch {
    _ => raise @proto.ProtocolError::InvalidInput("invalid base64 verifier")
  }
  let server_key = @crypto.hmac_sha256(salted_password[:], b"Server Key"[:])
  let server_signature = @crypto.hmac_sha256(server_key[:], auth_message[:])
  if not(bytes_equal(server_signature[:], verifier[:])) {
    raise @proto.ProtocolError::InvalidInput("SCRAM verification error")
  }
  self.state = Done
}

///|
fn bytes_equal(a : BytesView, b : BytesView) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i in 0..<a.length() {
    if a[i] != b[i] {
      return false
    }
  }
  true
}

///|
fn starts_with(haystack : BytesView, needle : BytesView) -> Bool {
  if needle.length() > haystack.length() {
    return false
  }
  for i in 0..<needle.length() {
    if haystack[i] != needle[i] {
      return false
    }
  }
  true
}

///|
priv struct Parser {
  buf : BytesView
  mut idx : Int
}

///|
fn Parser::new(buf : BytesView) -> Parser {
  { buf, idx: 0 }
}

///|
fn Parser::peek(self : Parser) -> Byte? {
  if self.idx >= self.buf.length() {
    None
  } else {
    Some(self.buf[self.idx])
  }
}

///|
fn Parser::eat(self : Parser, target : Byte) -> Unit raise @proto.ProtocolError {
  match self.peek() {
    Some(c) if c == target => self.idx = self.idx + 1
    Some(c) =>
      raise @proto.ProtocolError::InvalidInput(
        "unexpected character: expected \{target.to_char()} got \{c.to_char()}",
      )
    None => raise @proto.ProtocolError::UnexpectedEof("unexpected EOF")
  }
}

///|
fn Parser::take_while(self : Parser, f : (Byte) -> Bool) -> BytesView {
  let start = self.idx
  while self.idx < self.buf.length() && f(self.buf[self.idx]) {
    self.idx = self.idx + 1
  }
  self.buf[start:self.idx]
}

///|
fn Parser::printable(self : Parser) -> BytesView {
  self.take_while(fn(b) { (b >= 0x21 && b <= 0x2b) || (b >= 0x2d && b <= 0x7e) })
}

///|
fn Parser::nonce(self : Parser) -> BytesView raise @proto.ProtocolError {
  self.eat(b'r')
  self.eat(b'=')
  self.printable()
}

///|
fn Parser::base64(self : Parser) -> BytesView {
  self.take_while(fn(b) {
    (b >= b'a' && b <= b'z') ||
    (b >= b'A' && b <= b'Z') ||
    (b >= b'0' && b <= b'9') ||
    b == b'/' ||
    b == b'+' ||
    b == b'='
  })
}

///|
fn Parser::salt(self : Parser) -> BytesView raise @proto.ProtocolError {
  self.eat(b's')
  self.eat(b'=')
  self.base64()
}

///|
fn Parser::posit_number(self : Parser) -> Int raise @proto.ProtocolError {
  let digits = self.take_while(fn(b) { b >= b'0' && b <= b'9' })
  if digits.length() == 0 {
    raise @proto.ProtocolError::InvalidInput("expected number")
  }
  let mut n = 0
  for b in digits {
    n = n * 10 + (b.to_int() - '0'.to_int())
  }
  n
}

///|
fn Parser::iteration_count(self : Parser) -> Int raise @proto.ProtocolError {
  self.eat(b'i')
  self.eat(b'=')
  self.posit_number()
}

///|
fn Parser::eof(self : Parser) -> Unit raise @proto.ProtocolError {
  if self.idx < self.buf.length() {
    raise @proto.ProtocolError::InvalidInput("unexpected trailing data")
  }
}

///|
fn Parser::server_first_message(
  self : Parser,
) -> ServerFirstMessage raise @proto.ProtocolError {
  let nonce = self.nonce()
  self.eat(b',')
  let salt = self.salt()
  self.eat(b',')
  let iteration_count = self.iteration_count()
  self.eof()
  { nonce: nonce.to_bytes(), salt: salt.to_bytes(), iteration_count }
}

///|
fn Parser::server_final_message(
  self : Parser,
) -> ServerFinalMessage raise @proto.ProtocolError {
  match self.peek() {
    Some(b'e') => {
      self.eat(b'e')
      self.eat(b'=')
      let err = self.buf[self.idx:]
      self.idx = self.buf.length()
      self.eof()
      ServerFinalMessage::Error(err.to_bytes())
    }
    _ => {
      self.eat(b'v')
      self.eat(b'=')
      let v = self.base64()
      self.eof()
      ServerFinalMessage::Verifier(v.to_bytes())
    }
  }
}

///|
priv struct ServerFirstMessage {
  nonce : Bytes
  salt : Bytes
  iteration_count : Int
}

///|
priv enum ServerFinalMessage {
  Error(Bytes)
  Verifier(Bytes)
}
