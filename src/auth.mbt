///|
/// Authentication methods supported by PostgreSQL
pub enum AuthMethod {
  None
  Password
  MD5
  SCRAM_SHA_256
  GSS
  SSPI
  Cert
} derive(Show, Eq)

///|
/// SCRAM authentication state
struct SCRAMState {
  mut client_nonce : String?
  mut server_nonce : String?
  mut salt : Bytes?
  mut iteration_count : Int
  mut client_first_message_bare : String?
  mut server_first_message : String?
} derive(Show)

///|
/// MD5 password hash for PostgreSQL
pub fn hash_md5_password(
  username : String,
  password : String,
  salt : Bytes,
) -> String {
  // PostgreSQL uses: md5(md5(password + username) + salt)
  let inner_hash = md5_hash(password + username)
  let salt_str = @encoding/utf8.decode(salt) catch { _ => "" }
  let final_hash = md5_hash(inner_hash + salt_str)
  "md5" + final_hash
}

///|
/// Simple MD5 hash implementation (placeholder)
/// In a real implementation, you'd use a proper crypto library
fn md5_hash(input : String) -> String {
  // This is a placeholder implementation
  // In practice, you would use a proper MD5 implementation
  let bytes = @encoding.encode(input, encoding=UTF8)
  let mut hash = 0
  for i = 0; i < bytes.length(); i = i + 1 {
    hash = hash * 31 + bytes[i].to_int()
  }
  hash.to_string()
}

///|
/// Generate a random nonce for SCRAM authentication
fn generate_nonce() -> String {
  // In a real implementation, this would use cryptographically secure random
  let mut nonce = ""
  for i = 0; i < 16; i = i + 1 {
    nonce += (i * 7 + 42).to_string()
  }
  nonce
}

///|
/// SCRAM-SHA-256 authentication handler
pub(all) struct SCRAMAuthenticator {
  username : String
  password : String
  mut state : SCRAMState
} derive(Show)

///|
pub fn SCRAMAuthenticator::new(
  username : String,
  password : String,
) -> SCRAMAuthenticator {
  {
    username,
    password,
    state: {
      client_nonce: None,
      server_nonce: None,
      salt: None,
      iteration_count: 0,
      client_first_message_bare: None,
      server_first_message: None,
    },
  }
}

///|
/// Generate initial SCRAM response
pub fn SCRAMAuthenticator::initial_response(self : SCRAMAuthenticator) -> Bytes {
  let client_nonce = generate_nonce()
  self.state.client_nonce = Some(client_nonce)
  let client_first_message_bare = "n=" + self.username + ",r=" + client_nonce
  self.state.client_first_message_bare = Some(client_first_message_bare)
  let client_first_message = "n,," + client_first_message_bare
  @encoding.encode(client_first_message, encoding=UTF8)
}

///|
/// Process server challenge and generate response
pub fn SCRAMAuthenticator::process_challenge(
  self : SCRAMAuthenticator,
  challenge : Bytes,
) -> Bytes raise ProtocolError {
  let challenge_str = match @encoding.decode(challenge, encoding=UTF8) {
    Ok(s) => s
    Err(_) =>
      raise ProtocolError::InvalidMessage("Invalid UTF-8 in SCRAM challenge")
  }
  self.state.server_first_message = Some(challenge_str)

  // Parse server first message: r=<nonce>,s=<salt>,i=<iteration_count>
  // For now, use a simplified parsing approach
  let mut server_nonce = challenge_str // Simplified
  let mut salt_b64 = "c2FsdA==" // Base64 of "salt" - placeholder
  let mut iteration_count = 4096 // Default SCRAM iteration count
  self.state.server_nonce = Some(server_nonce)
  self.state.iteration_count = iteration_count

  // Decode salt from base64 (simplified implementation)
  let salt = decode_base64_simple(salt_b64)
  self.state.salt = Some(salt)

  // Generate client final message
  let channel_binding = "c=biws" // base64 of "n,,"
  let client_nonce = self.state.client_nonce.unwrap()
  let client_final_without_proof = channel_binding + ",r=" + server_nonce

  // Calculate proof (simplified)
  let auth_message = self.state.client_first_message_bare.unwrap() +
    "," +
    challenge_str +
    "," +
    client_final_without_proof
  let client_key = self.calculate_client_key(salt, iteration_count)
  let client_signature = self.hmac_sha256(client_key, auth_message)
  let client_proof = self.xor_bytes(client_key, client_signature)
  let proof_b64 = encode_base64_simple(client_proof)
  let client_final_message = client_final_without_proof + ",p=" + proof_b64
  @encoding.encode(client_final_message, encoding=UTF8)
}

///|
/// Verify server final message
pub fn SCRAMAuthenticator::verify_server_final(
  self : SCRAMAuthenticator,
  server_final : Bytes,
) -> Bool {
  // In a real implementation, this would verify the server signature
  // For now, we'll just check if it starts with "v="
  match @encoding.decode(server_final, encoding=UTF8) {
    Ok(s) => s.starts_with("v=")
    Err(_) => false
  }
}

///|
/// Calculate client key for SCRAM (simplified implementation)
fn SCRAMAuthenticator::calculate_client_key(
  self : SCRAMAuthenticator,
  salt : Bytes,
  iteration_count : Int,
) -> Bytes {
  // This is a simplified implementation
  // Real SCRAM would use PBKDF2 with HMAC-SHA-256
  let salted_password = self.pbkdf2_simple(self.password, salt, iteration_count)
  self.hmac_sha256(salted_password, "Client Key")
}

///|
/// Simplified PBKDF2 implementation
fn SCRAMAuthenticator::pbkdf2_simple(
  self : SCRAMAuthenticator,
  password : String,
  salt : Bytes,
  iterations : Int,
) -> Bytes {
  // Simplified implementation - not cryptographically secure
  let password_bytes = @encoding.encode(password, encoding=UTF8)
  let mut result = Bytes::new(32) // SHA-256 output size
  for i = 0; i < result.length(); i = i + 1 {
    let mut val = 0
    for j = 0; j < iterations; j = j + 1 {
      val = val ^
        (
          password_bytes[i % password_bytes.length()].to_int() +
          salt[i % salt.length()].to_int() +
          j
        )
    }
    result[i] = (val % 256).to_byte()
  }
  result
}

///|
/// Simplified HMAC-SHA-256 implementation
fn SCRAMAuthenticator::hmac_sha256(
  self : SCRAMAuthenticator,
  key : Bytes,
  message : String,
) -> Bytes {
  // Simplified implementation - not cryptographically secure
  let message_bytes = @encoding.encode(message, encoding=UTF8)
  let mut result = Bytes::new(32)
  for i = 0; i < result.length(); i = i + 1 {
    let mut val = 0
    for j = 0; j < key.length(); j = j + 1 {
      val = val ^ key[j].to_int()
    }
    for j = 0; j < message_bytes.length(); j = j + 1 {
      val = val ^ message_bytes[j].to_int()
    }
    result[i] = (val % 256).to_byte()
  }
  result
}

///|
/// XOR two byte arrays
fn SCRAMAuthenticator::xor_bytes(
  self : SCRAMAuthenticator,
  a : Bytes,
  b : Bytes,
) -> Bytes {
  let len = if a.length() < b.length() { a.length() } else { b.length() }
  let result = Bytes::new(len)
  for i = 0; i < len; i = i + 1 {
    result[i] = (a[i].to_int() ^ b[i].to_int()).to_byte()
  }
  result
}

///|
/// Simplified base64 decode (placeholder implementation)
fn decode_base64_simple(input : String) -> Bytes {
  // This is a placeholder - use a proper base64 implementation in production
  @encoding.encode(input, encoding=UTF8)
}

///|
/// Simplified base64 encode (placeholder implementation)
fn encode_base64_simple(input : Bytes) -> String {
  // This is a placeholder - use a proper base64 implementation in production
  match @encoding.decode(input, encoding=UTF8) {
    Ok(s) => s
    Err(_) => ""
  }
}

///|
/// Authenticate using the specified method
pub async fn authenticate(
  socket : @socket.TCP,
  method : AuthMethod,
  username : String,
  password : String,
  salt : Bytes?,
) -> Unit {
  match method {
    AuthMethod::None => () // No authentication required
    AuthMethod::Password => send_password_message(password, socket)
    AuthMethod::MD5 =>
      match salt {
        Some(s) => {
          let hashed = hash_md5_password(username, password, s)
          send_password_message(hashed, socket)
        }
        None => raise ProtocolError::AuthenticationFailed("MD5 salt required")
      }
    AuthMethod::SCRAM_SHA_256 => {
      let authenticator = SCRAMAuthenticator::new(username, password)

      // Send initial response
      let initial = authenticator.initial_response()
      let sasl_msg = FrontendMessage::SASLInitialResponse(
        "SCRAM-SHA-256", initial,
      )
      let data = sasl_msg.serialize()
      socket.write(data)
    }
    _ =>
      raise ProtocolError::AuthenticationFailed(
        "Authentication method not supported",
      )
  }
}
