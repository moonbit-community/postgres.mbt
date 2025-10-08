///|
/// PostgreSQL connection state
pub enum ConnectionState {
  Connecting
  Connected
  Authenticating
  Authenticated
  ReadyForQuery(TransactionStatus)
  Terminated
  Error(String)
} derive(Show, Eq)

///|
/// Connection configuration
pub(all) struct ConnectionConfig {
  host : String
  port : Int
  database : String
  user : String
  password : String?
  ssl_mode : SSLMode
  connection_timeout : Int // milliseconds
  parameters : Map[String, String]
} derive(Show, Eq)

///|
/// SSL mode configuration
pub enum SSLMode {
  Disable
  Allow
  Prefer
  Require
  VerifyCA
  VerifyFull
} derive(Show, Eq)

///|
/// PostgreSQL connection
pub(all) struct Connection {
  mut socket : @socket.TCP?
  mut state : ConnectionState
  config : ConnectionConfig
  mut backend_key_data : BackendKeyData?
  mut parameters : Map[String, String]
  mut transaction_status : TransactionStatus
}

///|
pub fn Connection::new(config : ConnectionConfig) -> Connection {
  {
    socket: None,
    state: Connecting,
    config,
    backend_key_data: None,
    parameters: Map::new(),
    transaction_status: TransactionStatus::Idle,
  }
}

///|
/// Connect to PostgreSQL server
pub async fn Connection::connect(self : Connection) -> Unit {
  // Create socket connection
  let socket = @socket.TCP::new()
  socket.connect(self.config.host, self.config.port)
  self.socket = Some(socket)

  // Handle SSL if required
  if self.config.ssl_mode != SSLMode::Disable {
    self.handle_ssl_negotiation() catch {
      e =>
        if self.config.ssl_mode == SSLMode::Require ||
          self.config.ssl_mode == SSLMode::VerifyCA ||
          self.config.ssl_mode == SSLMode::VerifyFull {
          raise ProtocolError::ConnectionError("SSL required but not available")
        }
      // For Allow/Prefer modes, continue without SSL
    }
  }
  self.state = Connected

  // Send startup message
  self.send_startup_message()

  // Enter authentication loop
  self.state = Authenticating
  self.handle_authentication()
}

///|
/// Handle SSL negotiation
async fn Connection::handle_ssl_negotiation(self : Connection) -> Unit {
  let socket = match self.socket {
    Some(s) => s
    None => raise ProtocolError::ConnectionError("No socket connection")
  }

  // Send SSL request
  send_ssl_request(socket)

  // Read response (single byte)
  let response = Bytes::new(1)
  socket.read_exact(response)
  match response[0] {
    b'S' =>
      // SSL accepted - would need to upgrade to TLS here
      // For now, we'll just note that SSL was accepted
      ...
    b'N' =>
      // SSL not supported
      if self.config.ssl_mode == SSLMode::Require ||
        self.config.ssl_mode == SSLMode::VerifyCA ||
        self.config.ssl_mode == SSLMode::VerifyFull {
        raise ProtocolError::ConnectionError(
          "SSL required but server doesn't support it",
        )
      }
    _ => raise ProtocolError::InvalidMessage("Invalid SSL response")
  }
}

///|
/// Send startup message to server
async fn Connection::send_startup_message(self : Connection) -> Unit {
  let socket = match self.socket {
    Some(s) => s
    None => raise ProtocolError::ConnectionError("No socket connection")
  }
  let mut params = self.config.parameters
  params["user"] = self.config.user
  params["database"] = self.config.database

  // Add default parameters if not specified
  if not(params.contains("client_encoding")) {
    params["client_encoding"] = "UTF8"
  }
  if not(params.contains("application_name")) {
    params["application_name"] = "moonbit-postgres"
  }
  send_startup_message(params, socket)
}

///|
/// Handle authentication process
async fn Connection::handle_authentication(self : Connection) -> Unit {
  let socket = match self.socket {
    Some(s) => s
    None => raise ProtocolError::ConnectionError("No socket connection")
  }
  while true {
    let msg = self.read_message()
    match msg {
      BackendMessage::AuthenticationOk => {
        self.state = Authenticated
        break
      }
      BackendMessage::AuthenticationCleartextPassword =>
        match self.config.password {
          Some(pwd) => send_password_message(pwd, socket)
          None => raise ProtocolError::AuthenticationFailed("Password required")
        }
      BackendMessage::AuthenticationMD5Password(salt) =>
        match self.config.password {
          Some(pwd) => {
            let hashed = self.hash_md5_password(pwd, salt)
            send_password_message(hashed, socket)
          }
          None => raise ProtocolError::AuthenticationFailed("Password required")
        }
      BackendMessage::AuthenticationSASL(mechanisms) =>
        // For now, we'll implement SCRAM-SHA-256 if available
        if mechanisms.contains("SCRAM-SHA-256") {
          self.handle_scram_authentication(socket, "SCRAM-SHA-256")
        } else {
          raise ProtocolError::AuthenticationFailed(
            "No supported SASL mechanisms",
          )
        }
      BackendMessage::ParameterStatus(name, value) =>
        self.parameters[name] = value
      BackendMessage::BackendKeyData(key_data) =>
        self.backend_key_data = Some(key_data)
      BackendMessage::ReadyForQuery(status) => {
        self.transaction_status = status
        self.state = ReadyForQuery(status)
        return
      }
      BackendMessage::ErrorResponse(fields) => {
        let error_msg = match fields.get(ErrorFieldType::Message) {
          Some(msg) => msg
          None => "Authentication failed"
        }
        raise ProtocolError::AuthenticationFailed(error_msg)
      }
      _ =>
        // Handle other messages during authentication
        continue
    }
  }
}

///|
/// Read a complete message from the server
async fn Connection::read_message(self : Connection) -> BackendMessage {
  let socket = match self.socket {
    Some(s) => s
    None => raise ProtocolError::ConnectionError("No socket connection")
  }

  // Read message type (1 byte)
  let type_buf = Bytes::new(1)
  socket.read_exact(type_buf)
  let msg_type = type_buf[0].to_int().to_char()

  // Read message length (4 bytes, big-endian)
  let length_buf = Bytes::new(4)
  socket.read_exact(length_buf)
  let length = (
      (length_buf[0].to_int() << 24) |
      (length_buf[1].to_int() << 16) |
      (length_buf[2].to_int() << 8) |
      length_buf[3].to_int()
    ) -
    4 // Subtract length field itself

  // Read message body
  let body = Bytes::new(length)
  if length > 0 {
    socket.read_exact(body)
  }
  BackendMessage::parse(msg_type, body)
}

///|
/// Hash password for MD5 authentication
fn Connection::hash_md5_password(
  self : Connection,
  password : String,
  salt : Bytes,
) -> String {
  // PostgreSQL MD5 authentication:
  // md5(md5(password + username) + salt)
  // For now, we'll use a placeholder implementation
  "md5" +
  @encoding/utf8.encode(password + self.config.user).to_string() +
  salt.to_string()
}

///|
/// Handle SCRAM authentication (placeholder)
async fn Connection::handle_scram_authentication(
  self : Connection,
  socket : @socket.TCP,
  mechanism : String,
) -> Unit {
  // This would implement SCRAM-SHA-256 authentication
  // For now, we'll just raise an error
  raise ProtocolError::AuthenticationFailed(
    "SCRAM authentication not yet implemented",
  )
}

///|
/// Execute a simple query
pub async fn Connection::query(
  self : Connection,
  sql : String,
) -> Array[BackendMessage] {
  match self.state {
    ReadyForQuery(_) => () // Continue
    _ =>
      raise ProtocolError::ConnectionError("Connection not ready for queries")
  }
  let socket = match self.socket {
    Some(s) => s
    None => raise ProtocolError::ConnectionError("No socket connection")
  }

  // Send query
  send_query(sql, socket)

  // Collect response messages
  let messages = Array::new()
  while true {
    let msg = self.read_message()
    messages.push(msg)
    match msg {
      BackendMessage::ReadyForQuery(status) => {
        self.transaction_status = status
        self.state = ReadyForQuery(status)
        break
      }
      BackendMessage::ErrorResponse(_) =>
        // Continue reading until ReadyForQuery
        continue
      _ => continue
    }
  }
  messages
}

///|
/// Close the connection
pub async fn Connection::close(self : Connection) -> Unit {
  match self.socket {
    Some(socket) => {
      // Send terminate message
      let terminate_msg = FrontendMessage::Terminate
      let data = terminate_msg.serialize()
      socket.write(data)
      socket.close()
      self.socket = None
      self.state = Terminated
    }
    None => () // Already closed
  }
}

///|
/// Default connection configuration
pub fn ConnectionConfig::default() -> ConnectionConfig {
  {
    host: "localhost",
    port: 5432,
    database: "postgres",
    user: "postgres",
    password: None,
    ssl_mode: SSLMode::Prefer,
    connection_timeout: 30000, // 30 seconds
    parameters: Map::new(),
  }
}
