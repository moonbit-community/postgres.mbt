///|
/// Backend message type tags
pub const PARSE_COMPLETE_TAG : Byte = b'1'

///|
pub const BIND_COMPLETE_TAG : Byte = b'2'

///|
pub const CLOSE_COMPLETE_TAG : Byte = b'3'

///|
pub const NOTIFICATION_RESPONSE_TAG : Byte = b'A'

///|
pub const COMMAND_COMPLETE_TAG : Byte = b'C'

///|
pub const DATA_ROW_TAG : Byte = b'D'

///|
pub const ERROR_RESPONSE_TAG : Byte = b'E'

///|
pub const COPY_IN_RESPONSE_TAG : Byte = b'G'

///|
pub const COPY_OUT_RESPONSE_TAG : Byte = b'H'

///|
pub const COPY_BOTH_RESPONSE_TAG : Byte = b'W'

///|
pub const EMPTY_QUERY_RESPONSE_TAG : Byte = b'I'

///|
pub const BACKEND_KEY_DATA_TAG : Byte = b'K'

///|
pub const NO_DATA_TAG : Byte = b'n'

///|
pub const NOTICE_RESPONSE_TAG : Byte = b'N'

///|
pub const AUTHENTICATION_TAG : Byte = b'R'

///|
pub const PORTAL_SUSPENDED_TAG : Byte = b's'

///|
pub const PARAMETER_STATUS_TAG : Byte = b'S'

///|
pub const PARAMETER_DESCRIPTION_TAG : Byte = b't'

///|
pub const ROW_DESCRIPTION_TAG : Byte = b'T'

///|
pub const FUNCTION_CALL_RESPONSE_TAG : Byte = b'V'

///|
pub const READY_FOR_QUERY_TAG : Byte = b'Z'

///|
/// Backend messages sent from PostgreSQL server to client
pub enum BackendMessage {
  // Authentication messages
  AuthenticationOk
  AuthenticationKerberosV5
  AuthenticationCleartextPassword
  AuthenticationMD5Password(Bytes) // 4-byte salt
  AuthenticationSCMCredential
  AuthenticationGSS
  AuthenticationGSSContinue(Bytes)
  AuthenticationSSPI
  AuthenticationSASL(Array[String]) // List of SASL mechanisms
  AuthenticationSASLContinue(Bytes)
  AuthenticationSASLFinal(Bytes)

  // Status messages
  BackendKeyData(@postgres.BackendKeyData)
  ParameterStatus(String, String) // name, value
  ReadyForQuery(@postgres.TransactionStatus)

  // Command completion
  ParseComplete
  BindComplete
  CloseComplete
  CommandComplete(String) // command tag
  EmptyQueryResponse
  NoData
  PortalSuspended

  // Data messages
  RowDescription(Array[@postgres.ColumnInfo])
  DataRow(Array[Bytes?]) // column values (null if None)
  ParameterDescription(Array[@postgres.ParameterInfo])
  FunctionCallResponse(Bytes?)

  // Copy protocol
  CopyInResponse(@postgres.FormatCode, Array[@postgres.FormatCode]) // overall format, column formats
  CopyOutResponse(@postgres.FormatCode, Array[@postgres.FormatCode])
  CopyBothResponse(@postgres.FormatCode, Array[@postgres.FormatCode])
  CopyData(Bytes)
  CopyDone

  // Error and notice
  ErrorResponse(Map[@postgres.ErrorFieldType, String])
  NoticeResponse(Map[@postgres.ErrorFieldType, String])

  // Notifications
  NotificationResponse(@postgres.Notification)

  // Unknown/unsupported
  UnknownMessage(Char, Bytes)
} derive(Show, Eq)

///|
/// Parse a backend message from message type and data
pub fn BackendMessage::parse(
  msg_type : Char,
  data : Bytes,
) -> BackendMessage raise @postgres.ProtocolError {
  let reader = @postgres.MessageReader::new(data)
  match msg_type {
    'R' => parse_authentication(reader)
    'K' => parse_backend_key_data(reader)
    'S' => parse_parameter_status(reader)
    'Z' => parse_ready_for_query(reader)
    '1' => ParseComplete
    '2' => BindComplete
    '3' => CloseComplete
    'C' => parse_command_complete(reader)
    'I' => EmptyQueryResponse
    'n' => NoData
    's' => PortalSuspended
    'T' => parse_row_description(reader)
    'D' => parse_data_row(reader)
    't' => parse_parameter_description(reader)
    'V' => parse_function_call_response(reader)
    'G' => parse_copy_in_response(reader)
    'H' => parse_copy_out_response(reader)
    'W' => parse_copy_both_response(reader)
    'd' => parse_copy_data(reader)
    'c' => CopyDone
    'E' => parse_error_response(reader)
    'N' => parse_notice_response(reader)
    'A' => parse_notification_response(reader)
    _ => UnknownMessage(msg_type, data)
  }
}

///|
fn parse_authentication(
  reader : @postgres.MessageReader,
) -> BackendMessage raise @postgres.ProtocolError {
  let auth_type = reader.read_int32()
  match auth_type {
    0 => AuthenticationOk
    2 => AuthenticationKerberosV5
    3 => AuthenticationCleartextPassword
    4 => {
      let salt = reader.read_bytes(2)
      AuthenticationMD5Password(salt)
    }
    5 => {
      let salt = reader.read_bytes(4)
      AuthenticationMD5Password(salt)
    }
    6 => AuthenticationSCMCredential
    7 => AuthenticationGSS
    8 => {
      let data = reader.read_bytes(reader.remaining())
      AuthenticationGSSContinue(data)
    }
    9 => AuthenticationSSPI
    10 => {
      let mechanisms = Array::new()
      while not(reader.is_empty()) {
        let mechanism = reader.read_cstring()
        if mechanism.is_empty() {
          break
        }
        mechanisms.push(mechanism)
      }
      AuthenticationSASL(mechanisms)
    }
    11 => {
      let data = reader.read_bytes(reader.remaining())
      AuthenticationSASLContinue(data)
    }
    12 => {
      let data = reader.read_bytes(reader.remaining())
      AuthenticationSASLFinal(data)
    }
    _ =>
      raise @postgres.ProtocolError::InvalidMessage(
        "Unknown authentication type: \{auth_type}",
      )
  }
}

///|
fn parse_backend_key_data(
  reader : @postgres.MessageReader,
) -> BackendMessage raise @postgres.ProtocolError {
  let process_id = reader.read_int32()
  let secret_key = reader.read_int32()
  BackendKeyData({ process_id, secret_key })
}

///|
fn parse_parameter_status(
  reader : @postgres.MessageReader,
) -> BackendMessage raise @postgres.ProtocolError {
  let name = reader.read_cstring()
  let value = reader.read_cstring()
  ParameterStatus(name, value)
}

///|
fn parse_ready_for_query(
  reader : @postgres.MessageReader,
) -> BackendMessage raise @postgres.ProtocolError {
  let status_char = reader.read_char()
  let status = match status_char {
    'I' => @postgres.TransactionStatus::Idle
    'T' => @postgres.TransactionStatus::InTransaction
    'E' => @postgres.TransactionStatus::InFailedTransaction
    _ =>
      raise @postgres.ProtocolError::InvalidMessage(
        "Invalid transaction status: \{status_char}",
      )
  }
  ReadyForQuery(status)
}

///|
fn parse_command_complete(
  reader : @postgres.MessageReader,
) -> BackendMessage raise @postgres.ProtocolError {
  let command_tag = reader.read_cstring()
  CommandComplete(command_tag)
}

///|
fn parse_row_description(
  reader : @postgres.MessageReader,
) -> BackendMessage raise @postgres.ProtocolError {
  let num_fields = reader.read_int16()
  let columns = Array::new()
  for i = 0; i < num_fields; i = i + 1 {
    let name = reader.read_cstring()
    let table_oid = reader.read_int32()
    let column_attr_num = reader.read_int32()
    let data_type_oid = reader.read_int32()
    let data_type_size = reader.read_int16()
    let type_modifier = reader.read_int32()
    let format_code = @postgres.FormatCode::from_int(reader.read_int16())
    columns.push({
      name,
      table_oid,
      column_attribute_number: column_attr_num,
      data_type_oid,
      data_type_size,
      type_modifier,
      format_code,
    })
  }
  RowDescription(columns)
}

///|
fn parse_data_row(
  reader : @postgres.MessageReader,
) -> BackendMessage raise @postgres.ProtocolError {
  let num_columns = reader.read_int16()
  let values = Array::new()
  for i = 0; i < num_columns; i = i + 1 {
    let length = reader.read_int32()
    if length == -1 {
      values.push(None) // NULL value
    } else {
      let data = reader.read_bytes(length)
      values.push(Some(data))
    }
  }
  DataRow(values)
}

///|
fn parse_parameter_description(
  reader : @postgres.MessageReader,
) -> BackendMessage raise @postgres.ProtocolError {
  let num_params = reader.read_int16()
  let params = Array::new()
  for i = 0; i < num_params; i = i + 1 {
    let data_type_oid = reader.read_int32()
    params.push({ data_type_oid, })
  }
  ParameterDescription(params)
}

///|
fn parse_function_call_response(
  reader : @postgres.MessageReader,
) -> BackendMessage raise @postgres.ProtocolError {
  let length = reader.read_int32()
  if length == -1 {
    FunctionCallResponse(None)
  } else {
    let data = reader.read_bytes(length)
    FunctionCallResponse(Some(data))
  }
}

///|
fn parse_copy_in_response(
  reader : @postgres.MessageReader,
) -> BackendMessage raise @postgres.ProtocolError {
  let overall_format = @postgres.FormatCode::from_int(
    reader.read_byte().to_int(),
  )
  let num_columns = reader.read_int16()
  let column_formats = Array::new()
  for i = 0; i < num_columns; i = i + 1 {
    let format = @postgres.FormatCode::from_int(reader.read_int16())
    column_formats.push(format)
  }
  CopyInResponse(overall_format, column_formats)
}

///|
fn parse_copy_out_response(
  reader : @postgres.MessageReader,
) -> BackendMessage raise @postgres.ProtocolError {
  let overall_format = @postgres.FormatCode::from_int(
    reader.read_byte().to_int(),
  )
  let num_columns = reader.read_int16()
  let column_formats = Array::new()
  for i = 0; i < num_columns; i = i + 1 {
    let format = @postgres.FormatCode::from_int(reader.read_int16())
    column_formats.push(format)
  }
  CopyOutResponse(overall_format, column_formats)
}

///|
fn parse_copy_both_response(
  reader : @postgres.MessageReader,
) -> BackendMessage raise @postgres.ProtocolError {
  let overall_format = @postgres.FormatCode::from_int(
    reader.read_byte().to_int(),
  )
  let num_columns = reader.read_int16()
  let column_formats = Array::new()
  for i = 0; i < num_columns; i = i + 1 {
    let format = @postgres.FormatCode::from_int(reader.read_int16())
    column_formats.push(format)
  }
  CopyBothResponse(overall_format, column_formats)
}

///|
fn parse_copy_data(
  reader : @postgres.MessageReader,
) -> BackendMessage raise @postgres.ProtocolError {
  let data = reader.read_bytes(reader.remaining())
  CopyData(data)
}

///|
fn parse_error_response(
  reader : @postgres.MessageReader,
) -> BackendMessage raise @postgres.ProtocolError {
  let fields = parse_error_notice_fields(reader)
  ErrorResponse(fields)
}

///|
fn parse_notice_response(
  reader : @postgres.MessageReader,
) -> BackendMessage raise @postgres.ProtocolError {
  let fields = parse_error_notice_fields(reader)
  NoticeResponse(fields)
}

///|
fn parse_error_notice_fields(
  reader : @postgres.MessageReader,
) -> Map[@postgres.ErrorFieldType, String] raise @postgres.ProtocolError {
  let fields = Map::new()
  while not(reader.is_empty()) {
    let field_type_char = reader.read_char()
    if field_type_char == '\x00' {
      break // End of fields
    }
    let field_type = @postgres.ErrorFieldType::from_char(field_type_char)
    let value = reader.read_cstring()
    fields[field_type] = value
  }
  fields
}

///|
fn parse_notification_response(
  reader : @postgres.MessageReader,
) -> BackendMessage raise @postgres.ProtocolError {
  let process_id = reader.read_int32()
  let channel = reader.read_cstring()
  let payload = reader.read_cstring()
  NotificationResponse({ process_id, channel, payload })
}
