///|
/// Frontend message type tags
pub const BIND_TAG : Byte = b'B'

///|
pub const CLOSE_TAG : Byte = b'C'

///|
pub const COPY_DATA_TAG : Byte = b'd'

///|
pub const COPY_DONE_TAG : Byte = b'c'

///|
pub const COPY_FAIL_TAG : Byte = b'f'

///|
pub const DESCRIBE_TAG : Byte = b'D'

///|
pub const EXECUTE_TAG : Byte = b'E'

///|
pub const FLUSH_TAG : Byte = b'H'

///|
pub const FUNCTION_CALL_TAG : Byte = b'F'

///|
pub const PARSE_TAG : Byte = b'P'

///|
pub const PASSWORD_MESSAGE_TAG : Byte = b'p'

///|
pub const QUERY_TAG : Byte = b'Q'

///|
pub const SYNC_TAG : Byte = b'S'

///|
pub const TERMINATE_TAG : Byte = b'X'

///|
/// Frontend messages sent from client to PostgreSQL server
pub enum FrontendMessage {
  // Connection setup
  StartupMessage(Map[String, String])
  PasswordMessage(String)
  SASLInitialResponse(String, Bytes) // mechanism, initial_response
  SASLResponse(Bytes)

  // Query execution
  Query(String)
  Parse(String, String, Array[Int]) // name, query, parameter_types
  Bind(
    String,
    String,
    Array[@postgres.FormatCode],
    Array[Bytes?],
    Array[@postgres.FormatCode]
  ) // portal, statement, param_formats, params, result_formats
  Execute(String, Int) // portal, max_rows (0 = no limit)
  Describe(DescribeTarget, String) // target, name

  // Prepared statement management
  Close(CloseTarget, String) // target, name

  // Flow control
  Sync
  Flush

  // Copy protocol
  CopyData(Bytes)
  CopyDone
  CopyFail(String) // error_message

  // Function calls
  FunctionCall(
    Int,
    Array[@postgres.FormatCode],
    Array[Bytes?],
    @postgres.FormatCode
  ) // function_oid, arg_formats, args, result_format

  // Connection termination
  Terminate

  // Cancel request (sent on separate connection)
  CancelRequest(@postgres.BackendKeyData)

  // SSL request
  SSLRequest

  // GSSAPI encryption request
  GSSENCRequest
} derive(Show, Eq)

///|
pub enum DescribeTarget {
  Statement // 'S'
  Portal // 'P'
} derive(Show, Eq)

///|
pub enum CloseTarget {
  Statement // 'S'
  Portal // 'P'
} derive(Show, Eq)

///|
pub fn DescribeTarget::to_char(self : DescribeTarget) -> Char {
  match self {
    Statement => 'S'
    Portal => 'P'
  }
}

///|
pub fn CloseTarget::to_char(self : CloseTarget) -> Char {
  match self {
    Statement => 'S'
    Portal => 'P'
  }
}

///|
/// Serialize a frontend message to bytes
pub fn FrontendMessage::serialize(
  self : FrontendMessage,
) -> Bytes raise @postgres.ProtocolError {
  let writer = @postgres.MessageWriter::new()
  match self {
    StartupMessage(params) => serialize_startup_message(writer, params)
    PasswordMessage(password) => serialize_password_message(writer, password)
    SASLInitialResponse(mechanism, response) =>
      serialize_sasl_initial_response(writer, mechanism, response)
    SASLResponse(response) => serialize_sasl_response(writer, response)
    Query(sql) => serialize_query(writer, sql)
    Parse(name, query, param_types) =>
      serialize_parse(writer, name, query, param_types)
    Bind(portal, statement, param_formats, params, result_formats) =>
      serialize_bind(
        writer, portal, statement, param_formats, params, result_formats,
      )
    Execute(portal, max_rows) => serialize_execute(writer, portal, max_rows)
    Describe(target, name) => serialize_describe(writer, target, name)
    Close(target, name) => serialize_close(writer, target, name)
    Sync => serialize_sync(writer)
    Flush => serialize_flush(writer)
    CopyData(data) => serialize_copy_data(writer, data)
    CopyDone => serialize_copy_done(writer)
    CopyFail(error) => serialize_copy_fail(writer, error)
    FunctionCall(oid, arg_formats, args, result_format) =>
      serialize_function_call(writer, oid, arg_formats, args, result_format)
    Terminate => serialize_terminate(writer)
    CancelRequest(key_data) => serialize_cancel_request(writer, key_data)
    SSLRequest => serialize_ssl_request(writer)
    GSSENCRequest => serialize_gss_enc_request(writer)
  }
  writer.to_bytes()
}

///|
fn serialize_startup_message(
  writer : @postgres.MessageWriter,
  params : Map[String, String],
) -> Unit {
  // Length placeholder - will be filled later
  let length_pos = writer.data.length()
  writer.write_int32(0)

  // Protocol version
  writer.write_int32(
    (@postgres.PROTOCOL_VERSION_MAJOR << 16) | @postgres.PROTOCOL_VERSION_MINOR,
  )

  // Parameters
  for key, value in params {
    writer.write_cstring(key)
    writer.write_cstring(value)
  }
  writer.write_byte(0) // Null terminator

  // Fill in actual length
  let total_length = writer.data.length()
  let length_bytes = total_length.to_byte_array_big_endian()
  for i = 0; i < 4; i = i + 1 {
    writer.data[length_pos + i] = length_bytes[i]
  }
}

///|
fn serialize_password_message(
  writer : @postgres.MessageWriter,
  password : String,
) -> Unit {
  serialize_message_with_tag(writer, PASSWORD_MESSAGE_TAG, fn() {
    writer.write_cstring(password)
  })
}

///|
fn serialize_sasl_initial_response(
  writer : @postgres.MessageWriter,
  mechanism : String,
  response : Bytes,
) -> Unit {
  serialize_message_with_tag(writer, PASSWORD_MESSAGE_TAG, fn() {
    writer.write_cstring(mechanism)
    writer.write_int32(response.length())
    writer.write_bytes(response)
  })
}

///|
fn serialize_sasl_response(
  writer : @postgres.MessageWriter,
  response : Bytes,
) -> Unit {
  serialize_message_with_tag(writer, PASSWORD_MESSAGE_TAG, fn() {
    writer.write_bytes(response)
  })
}

///|
fn serialize_query(writer : @postgres.MessageWriter, sql : String) -> Unit {
  serialize_message_with_tag(writer, QUERY_TAG, fn() {
    writer.write_cstring(sql)
  })
}

///|
fn serialize_parse(
  writer : @postgres.MessageWriter,
  name : String,
  query : String,
  param_types : Array[Int],
) -> Unit {
  serialize_message_with_tag(writer, PARSE_TAG, fn() {
    writer.write_cstring(name)
    writer.write_cstring(query)
    writer.write_int16(param_types.length())
    for oid in param_types {
      writer.write_int32(oid)
    }
  })
}

///|
fn serialize_bind(
  writer : @postgres.MessageWriter,
  portal : String,
  statement : String,
  param_formats : Array[@postgres.FormatCode],
  params : Array[Bytes?],
  result_formats : Array[@postgres.FormatCode],
) -> Unit {
  serialize_message_with_tag(writer, BIND_TAG, fn() {
    writer.write_cstring(portal)
    writer.write_cstring(statement)

    // Parameter formats
    writer.write_int16(param_formats.length())
    for format in param_formats {
      writer.write_int16(format.to_int())
    }

    // Parameter values
    writer.write_int16(params.length())
    for param in params {
      match param {
        None => writer.write_int32(-1) // NULL
        Some(data) => {
          writer.write_int32(data.length())
          writer.write_bytes(data)
        }
      }
    }

    // Result formats
    writer.write_int16(result_formats.length())
    for format in result_formats {
      writer.write_int16(format.to_int())
    }
  })
}

///|
fn serialize_execute(
  writer : @postgres.MessageWriter,
  portal : String,
  max_rows : Int,
) -> Unit {
  serialize_message_with_tag(writer, EXECUTE_TAG, fn() {
    writer.write_cstring(portal)
    writer.write_int32(max_rows)
  })
}

///|
fn serialize_describe(
  writer : @postgres.MessageWriter,
  target : DescribeTarget,
  name : String,
) -> Unit {
  serialize_message_with_tag(writer, DESCRIBE_TAG, fn() {
    writer.write_char(target.to_char())
    writer.write_cstring(name)
  })
}

///|
fn serialize_close(
  writer : @postgres.MessageWriter,
  target : CloseTarget,
  name : String,
) -> Unit {
  serialize_message_with_tag(writer, CLOSE_TAG, fn() {
    writer.write_char(target.to_char())
    writer.write_cstring(name)
  })
}

///|
fn serialize_sync(writer : @postgres.MessageWriter) -> Unit {
  serialize_message_with_tag(writer, SYNC_TAG, fn() {
    // No payload
  })
}

///|
fn serialize_flush(writer : @postgres.MessageWriter) -> Unit {
  serialize_message_with_tag(writer, FLUSH_TAG, fn() {
    // No payload
  })
}

///|
fn serialize_copy_data(writer : @postgres.MessageWriter, data : Bytes) -> Unit {
  serialize_message_with_tag(writer, COPY_DATA_TAG, fn() {
    writer.write_bytes(data)
  })
}

///|
fn serialize_copy_done(writer : @postgres.MessageWriter) -> Unit {
  serialize_message_with_tag(writer, COPY_DONE_TAG, fn() {
    // No payload
  })
}

///|
fn serialize_copy_fail(
  writer : @postgres.MessageWriter,
  error : String,
) -> Unit {
  serialize_message_with_tag(writer, COPY_FAIL_TAG, fn() {
    writer.write_cstring(error)
  })
}

///|
fn serialize_function_call(
  writer : @postgres.MessageWriter,
  oid : Int,
  arg_formats : Array[@postgres.FormatCode],
  args : Array[Bytes?],
  result_format : @postgres.FormatCode,
) -> Unit {
  serialize_message_with_tag(writer, FUNCTION_CALL_TAG, fn() {
    writer.write_int32(oid)

    // Argument formats
    writer.write_int16(arg_formats.length())
    for format in arg_formats {
      writer.write_int16(format.to_int())
    }

    // Arguments
    writer.write_int16(args.length())
    for arg in args {
      match arg {
        None => writer.write_int32(-1) // NULL
        Some(data) => {
          writer.write_int32(data.length())
          writer.write_bytes(data)
        }
      }
    }
    writer.write_int16(result_format.to_int())
  })
}

///|
fn serialize_terminate(writer : @postgres.MessageWriter) -> Unit {
  serialize_message_with_tag(writer, TERMINATE_TAG, fn() {
    // No payload
  })
}

///|
fn serialize_cancel_request(
  writer : @postgres.MessageWriter,
  key_data : @postgres.BackendKeyData,
) -> Unit {
  writer.write_int32(16) // Total length
  writer.write_int32(@postgres.CANCEL_REQUEST_CODE)
  writer.write_int32(key_data.process_id)
  writer.write_int32(key_data.secret_key)
}

///|
fn serialize_ssl_request(writer : @postgres.MessageWriter) -> Unit {
  writer.write_int32(8) // Total length
  writer.write_int32(@postgres.SSL_REQUEST_CODE)
}

///|
fn serialize_gss_enc_request(writer : @postgres.MessageWriter) -> Unit {
  writer.write_int32(8) // Total length
  writer.write_int32(@postgres.GSSAPI_ENC_REQUEST_CODE)
}

///|
/// Helper function to serialize a message with tag and length prefix
fn serialize_message_with_tag(
  writer : @postgres.MessageWriter,
  tag : Byte,
  payload_fn : () -> Unit,
) -> Unit {
  writer.write_byte(tag)

  // Length placeholder
  let length_pos = writer.data.length()
  writer.write_int32(0)

  // Write payload
  payload_fn()

  // Calculate and fill in length (including the 4-byte length field itself)
  let total_length = writer.data.length() - length_pos
  let length_bytes = total_length.to_byte_array_big_endian()
  for i = 0; i < 4; i = i + 1 {
    writer.data[length_pos + i] = length_bytes[i]
  }
}

///|
/// Helper extension for converting int to big-endian byte array
fn Int::to_byte_array_big_endian(self : Int) -> Array[Byte] {
  [
    ((self >> 24) & 0xFF).to_byte(),
    ((self >> 16) & 0xFF).to_byte(),
    ((self >> 8) & 0xFF).to_byte(),
    (self & 0xFF).to_byte(),
  ]
}

///|
/// Async helper for TCP socket to write C strings
async fn @socket.TCP::write_cstr(
  self : @socket.TCP,
  bytes : Bytes,
) -> Unit raise {
  self.write(bytes)
  self.write(b"\x00")
}

///|
/// Send startup message to establish connection
pub async fn send_startup_message(
  parameters : Map[String, String],
  conn : @socket.TCP,
) -> Unit raise {
  let msg = FrontendMessage::StartupMessage(parameters)
  let data = msg.serialize()
  conn.write(data)
}

///|
/// Send password message for authentication
pub async fn send_password_message(
  password : String,
  conn : @socket.TCP,
) -> Unit raise {
  let msg = FrontendMessage::PasswordMessage(password)
  let data = msg.serialize()
  conn.write(data)
}

///|
/// Send simple query
pub async fn send_query(sql : String, conn : @socket.TCP) -> Unit raise {
  let msg = FrontendMessage::Query(sql)
  let data = msg.serialize()
  conn.write(data)
}

///|
/// Send SSL request
pub async fn send_ssl_request(conn : @socket.TCP) -> Unit raise {
  let msg = FrontendMessage::SSLRequest
  let data = msg.serialize()
  conn.write(data)
}
