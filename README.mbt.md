# PostgreSQL Protocol Library for MoonBit

A pure MoonBit implementation of the PostgreSQL frontend/backend protocol, providing low-level access to PostgreSQL database communication.

## Features

- **Complete Protocol Implementation**: Support for PostgreSQL wire protocol version 3.0
- **Message Parsing**: Parse all backend messages from PostgreSQL server
- **Message Serialization**: Serialize frontend messages to send to PostgreSQL server
- **Authentication Support**: Multiple authentication methods including plaintext, MD5, and SCRAM-SHA-256
- **Connection Management**: High-level connection handling with proper state management
- **Error Handling**: Comprehensive error types for protocol and SQL errors
- **Type Safety**: Fully typed message structures and protocol constants

## Architecture

This library is organized into several modules:

- `types.mbt` - Core protocol types and constants
- `error.mbt` - Error handling and custom error types
- `buffer.mbt` - Low-level buffer reading/writing utilities
- `message/backend.mbt` - Backend message parsing
- `message/frontend.mbt` - Frontend message serialization
- `auth.mbt` - Authentication methods implementation
- `connection.mbt` - High-level connection management

## Basic Usage

### Connection Configuration

```moonbit
test "basic connection setup" {
  // Create default configuration
  let mut config = @postgres.ConnectionConfig::default()
  config.host = "localhost"
  config.port = 5432
  config.database = "mydb"
  config.user = "myuser"
  config.password = Some("mypassword")
  inspect(config.host, content="localhost")
  inspect(config.port, content="5432")
}
```

### Message Parsing

```moonbit
test "parse backend messages" {
  // Parse an authentication OK message
  let auth_data = b"\x00\x00\x00\x00"
  let msg = @postgres.BackendMessage::parse('R', auth_data)
  inspect(msg, content="AuthenticationOk")

  // Parse a ready for query message
  let ready_data = b"I"
  let ready_msg = @postgres.BackendMessage::parse('Z', ready_data)
  inspect(ready_msg, content="ReadyForQuery(Idle)")
}
```

### Message Serialization

```moonbit
test "serialize frontend messages" {
  // Create a simple query message
  let query_msg = @postgres.FrontendMessage::Query("SELECT 1")
  let data = query_msg.serialize()

  // Verify the message format
  inspect(data[0], content="81") // 'Q' tag
  inspect(data.length() > 5, content="true")
}
```

### Authentication

```moonbit
test "authentication methods" {
  // MD5 password hashing
  let hashed = @postgres.hash_md5_password(
    "user", "password", b"\x01\x02\x03\x04",
  )
  inspect(hashed.starts_with("md5"), content="true")

  // SCRAM authentication setup
  let authenticator = @postgres.SCRAMAuthenticator::new("user", "password")
  let initial_response = authenticator.initial_response()
  inspect(initial_response.length() > 0, content="true")
}
```

## Protocol Types

### Message Types

The library provides comprehensive support for all PostgreSQL protocol messages:

#### Backend Messages (Server → Client)
- Authentication messages (AuthenticationOk, AuthenticationMD5Password, etc.)
- Status messages (BackendKeyData, ParameterStatus, ReadyForQuery)
- Data messages (RowDescription, DataRow, CommandComplete)
- Error/Notice messages (ErrorResponse, NoticeResponse)
- Copy protocol messages (CopyInResponse, CopyOutResponse, etc.)

#### Frontend Messages (Client → Server)  
- Connection setup (StartupMessage, PasswordMessage)
- Query execution (Query, Parse, Bind, Execute)
- Prepared statements (Parse, Describe, Close)
- Copy protocol (CopyData, CopyDone, CopyFail)
- Control flow (Sync, Flush, Terminate)

### Error Handling

```moonbit
test "error types" {
  // Protocol errors
  let protocol_err = @postgres.ProtocolError::InvalidMessage("Bad format")
  inspect(protocol_err, content="InvalidMessage(\"Bad format\")")

  // SQL errors
  let sql_err = @postgres.SqlError::SyntaxError("Invalid syntax")
  inspect(sql_err, content="SyntaxError(\"Invalid syntax\")")
}
```

### Format Codes

```moonbit
test "format codes" {
  let text_format = @postgres.FormatCode::Text
  let binary_format = @postgres.FormatCode::Binary
  inspect(text_format.to_int(), content="0")
  inspect(binary_format.to_int(), content="1")

  // Convert back from integer
  let from_int = @postgres.FormatCode::from_int(1)
  inspect(from_int, content="Binary")
}
```

## Buffer Utilities

The library provides efficient buffer reading/writing utilities:

```moonbit
test "buffer operations" {
  // Writing data
  let writer = @postgres.MessageWriter::new()
  writer.write_int32(123456)
  writer.write_cstring("Hello")
  let data = writer.to_bytes()
  inspect(data.length() > 0, content="true")

  // Reading data
  let reader = @postgres.MessageReader::new(data)
  let int_val = reader.read_int32()
  inspect(int_val, content="123456")
  let str_val = reader.read_cstring()
  inspect(str_val, content="Hello")
}
```

## Connection States

The library tracks connection state throughout the lifecycle:

```moonbit
test "connection states" {
  let connecting = @postgres.ConnectionState::Connecting
  inspect(connecting, content="Connecting")
  let ready = @postgres.ConnectionState::ReadyForQuery(
    @postgres.TransactionStatus::Idle,
  )
  inspect(ready, content="ReadyForQuery(Idle)")
  let error = @postgres.ConnectionState::Error("Connection failed")
  inspect(error, content="Error(\"Connection failed\")")
}
```

## Protocol Constants

Key protocol constants are available:

```moonbit
test "protocol constants" {
  inspect(@postgres.PROTOCOL_VERSION_MAJOR, content="3")
  inspect(@postgres.PROTOCOL_VERSION_MINOR, content="0")
  inspect(@postgres.SSL_REQUEST_CODE, content="80877103")
  inspect(@postgres.CANCEL_REQUEST_CODE, content="80877102")
}
```

## SSL Support

The library provides SSL negotiation support:

```moonbit
test "ssl modes" {
  let ssl_disabled = @postgres.SSLMode::Disable
  let ssl_required = @postgres.SSLMode::Require
  let ssl_preferred = @postgres.SSLMode::Prefer
  inspect(ssl_disabled, content="Disable")
  inspect(ssl_required, content="Require")
  inspect(ssl_preferred, content="Prefer")
}
```

## Error Field Types

PostgreSQL error messages contain structured field information:

```moonbit
test "error field types" {
  let severity = @postgres.ErrorFieldType::Severity
  let message = @postgres.ErrorFieldType::Message
  let code = @postgres.ErrorFieldType::Code
  inspect(severity.to_char(), content="S")
  inspect(message.to_char(), content="M")
  inspect(code.to_char(), content="C")

  // Parse from character
  let parsed = @postgres.ErrorFieldType::from_char('S')
  inspect(parsed, content="Severity")
}
```

## Testing

The library includes comprehensive tests covering:

- Message parsing and serialization
- Buffer operations
- Authentication methods
- Error handling
- Protocol constants
- Type conversions

Run tests with:
```bash
moon test
```

## Design Philosophy

This library is designed with the following principles:

1. **Type Safety**: Extensive use of MoonBit's type system to prevent runtime errors
2. **Zero Dependencies**: Pure MoonBit implementation with minimal external dependencies  
3. **Protocol Compliance**: Full adherence to PostgreSQL wire protocol specification
4. **Performance**: Efficient buffer operations and minimal allocations
5. **Testability**: Comprehensive test coverage with snapshot testing

## Comparison with rust-postgres-protocol

This library is inspired by and maintains compatibility with the design of rust-postgres-protocol, while adapting to MoonBit's language features:

- **Error Handling**: Uses MoonBit's checked exception system instead of Result types
- **Memory Management**: Leverages MoonBit's garbage collection instead of manual memory management
- **Type System**: Uses MoonBit's pattern matching and enum types for message handling
- **Async Support**: Built for MoonBit's async/await model

## License

Apache License 2.0

## Contributing

Contributions are welcome! Please ensure that:

1. All tests pass (`moon test`)
2. Code is properly formatted (`moon fmt`)
3. New features include appropriate tests
4. Documentation is updated for public APIs

The library follows PostgreSQL's wire protocol specification and maintains compatibility with standard PostgreSQL servers.
