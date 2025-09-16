///|
test "serialize Query message" {
  let msg = FrontendMessage::Query("SELECT 1")
  let data = msg.serialize()

  // Check message starts with 'Q' tag
  inspect(data[0], content="81") // 'Q'

  // Check length field (5 bytes for length + 8 bytes for "SELECT 1\0")
  let length = (data[1].to_int() << 24) |
    (data[2].to_int() << 16) |
    (data[3].to_int() << 8) |
    data[4].to_int()
  inspect(length, content="13") // 4 (length field) + 9 (SELECT 1\0)

  // Check the SQL string
  let sql_bytes = data[5:]
  let sql = @encoding.decode(sql_bytes, encoding=UTF8)
  inspect(sql, content="SELECT 1\x00")
}

///|
test "serialize PasswordMessage" {
  let msg = FrontendMessage::PasswordMessage("secret123")
  let data = msg.serialize()
  inspect(data[0], content="112") // 'p'

  // Verify password content
  let password_bytes = data[5:]
  let password = @encoding.decode(password_bytes, encoding=UTF8)
  inspect(password, content="secret123\x00")
}

///|
test "serialize Parse message" {
  let msg = FrontendMessage::Parse("stmt1", "SELECT $1", [23]) // INT4 type
  let data = msg.serialize()
  inspect(data[0], content="80") // 'P'

  // The message should contain:
  // - statement name "stmt1\0"
  // - query "SELECT $1\0" 
  // - parameter count (2 bytes): 1
  // - parameter type (4 bytes): 23
  inspect(data.length() > 20, content="true") // Should be reasonably long
}

///|
test "serialize Bind message" {
  let param_formats = [FormatCode::Text]
  let params = [Some(b"42")]
  let result_formats = [FormatCode::Text]
  let msg = FrontendMessage::Bind(
    "portal1", "stmt1", param_formats, params, result_formats,
  )
  let data = msg.serialize()
  inspect(data[0], content="66") // 'B'
  inspect(data.length() > 15, content="true") // Should contain all the bind data
}

///|
test "serialize Execute message" {
  let msg = FrontendMessage::Execute("portal1", 100)
  let data = msg.serialize()
  inspect(data[0], content="69") // 'E'

  // Should contain portal name and max rows
  let portal_start = 5 // After tag and length
  let portal_bytes = data[portal_start:portal_start + 8]
  let portal = @encoding.decode(portal_bytes, encoding=UTF8)
  inspect(portal, content="portal1\x00")
}

///|
test "serialize Sync message" {
  let msg = FrontendMessage::Sync
  let data = msg.serialize()
  inspect(data[0], content="83") // 'S'
  inspect(data.length(), content="5") // Just tag + length (4 bytes)
}

///|
test "serialize Terminate message" {
  let msg = FrontendMessage::Terminate
  let data = msg.serialize()
  inspect(data[0], content="88") // 'X'
  inspect(data.length(), content="5") // Just tag + length
}

///|
test "serialize StartupMessage" {
  let params = { "user": "testuser", "database": "testdb" }
  let msg = FrontendMessage::StartupMessage(params)
  let data = msg.serialize()

  // StartupMessage doesn't have a type tag, starts with length
  let length = (data[0].to_int() << 24) |
    (data[1].to_int() << 16) |
    (data[2].to_int() << 8) |
    data[3].to_int()
  inspect(length > 20, content="true") // Should be reasonably long

  // Check protocol version
  let version = (data[4].to_int() << 24) |
    (data[5].to_int() << 16) |
    (data[6].to_int() << 8) |
    data[7].to_int()
  inspect(version, content="196608") // 3.0 = (3 << 16) | 0
}

///|
test "serialize SSLRequest" {
  let msg = FrontendMessage::SSLRequest
  let data = msg.serialize()

  // Check length (8 bytes total)
  let length = (data[0].to_int() << 24) |
    (data[1].to_int() << 16) |
    (data[2].to_int() << 8) |
    data[3].to_int()
  inspect(length, content="8")

  // Check SSL request code
  let code = (data[4].to_int() << 24) |
    (data[5].to_int() << 16) |
    (data[6].to_int() << 8) |
    data[7].to_int()
  inspect(code, content="80877103") // SSL_REQUEST_CODE
}

///|
test "serialize CancelRequest" {
  let key_data = BackendKeyData::{
    process_id: 12345,
    secret_key: 67890,
  }
  let msg = FrontendMessage::CancelRequest(key_data)
  let data = msg.serialize()

  // Check length (16 bytes total)
  let length = (data[0].to_int() << 24) |
    (data[1].to_int() << 16) |
    (data[2].to_int() << 8) |
    data[3].to_int()
  inspect(length, content="16")

  // Check cancel request code
  let code = (data[4].to_int() << 24) |
    (data[5].to_int() << 16) |
    (data[6].to_int() << 8) |
    data[7].to_int()
  inspect(code, content="80877102") // CANCEL_REQUEST_CODE
}

///|
test "DescribeTarget and CloseTarget conversions" {
  inspect(DescribeTarget::Statement.to_char(), content="S")
  inspect(DescribeTarget::Portal.to_char(), content="P")
  inspect(CloseTarget::Statement.to_char(), content="S")
  inspect(CloseTarget::Portal.to_char(), content="P")
}
