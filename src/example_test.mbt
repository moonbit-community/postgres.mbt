///|
test "example connection config" {
  let config = @postgres.ConnectionConfig::default()
  inspect(config.host, content="localhost")
  inspect(config.port, content="5432")
  inspect(config.database, content="postgres")
  inspect(config.user, content="postgres")
  inspect(config.ssl_mode, content="Prefer")
}

///|
test "example custom config" {
  let mut config = @postgres.ConnectionConfig::default()
  config.host = "example.com"
  config.port = 5433
  config.database = "mydb"
  config.user = "myuser"
  config.password = Some("secret")
  config.ssl_mode = @postgres.SSLMode::Require
  inspect(config.host, content="example.com")
  inspect(config.port, content="5433")
  inspect(config.database, content="mydb")
  inspect(config.user, content="myuser")
  inspect(config.password, content="Some(\"secret\")")
  inspect(config.ssl_mode, content="Require")
}

///|
test "example MD5 password hashing" {
  let hashed = @postgres.hash_md5_password(
    "testuser", "password123", b"\x01\x02\x03\x04",
  )
  inspect(hashed.starts_with("md5"), content="true")
  inspect(hashed.length() > 3, content="true")
}

///|
test "example SCRAM authenticator" {
  let auth = @postgres.SCRAMAuthenticator::new("testuser", "password123")
  let initial = auth.initial_response()
  inspect(initial.length() > 10, content="true")

  // Check that initial response contains username
  let response_str = @encoding.decode(initial, encoding=UTF8).unwrap()
  inspect(response_str.contains("testuser"), content="true")
}

///|
test "example format code conversions" {
  let text_format = @postgres.FormatCode::Text
  let binary_format = @postgres.FormatCode::Binary
  inspect(text_format.to_int(), content="0")
  inspect(binary_format.to_int(), content="1")
  let text_from_int = @postgres.FormatCode::from_int(0)
  let binary_from_int = @postgres.FormatCode::from_int(1)
  inspect(text_from_int, content="Text")
  inspect(binary_from_int, content="Binary")
}

///|
test "example error field type conversions" {
  let severity = @postgres.ErrorFieldType::Severity
  let message = @postgres.ErrorFieldType::Message
  let code = @postgres.ErrorFieldType::Code
  inspect(severity.to_char(), content="S")
  inspect(message.to_char(), content="M")
  inspect(code.to_char(), content="C")
  inspect(@postgres.ErrorFieldType::from_char('S'), content="Severity")
  inspect(@postgres.ErrorFieldType::from_char('M'), content="Message")
  inspect(@postgres.ErrorFieldType::from_char('C'), content="Code")
  inspect(@postgres.ErrorFieldType::from_char('X'), content="Unknown('X')")
}

///|
test "example connection state transitions" {
  let conn_state = @postgres.ConnectionState::Connecting
  inspect(conn_state, content="Connecting")
  let ready_state = @postgres.ConnectionState::ReadyForQuery(
    @postgres.TransactionStatus::Idle,
  )
  inspect(ready_state, content="ReadyForQuery(Idle)")
  let error_state = @postgres.ConnectionState::Error("Connection failed")
  inspect(error_state, content="Error(\"Connection failed\")")
}

///|
test "example protocol constants" {
  inspect(@postgres.PROTOCOL_VERSION_MAJOR, content="3")
  inspect(@postgres.PROTOCOL_VERSION_MINOR, content="0")
  inspect(@postgres.SSL_REQUEST_CODE, content="80877103")
  inspect(@postgres.CANCEL_REQUEST_CODE, content="80877102")
}
