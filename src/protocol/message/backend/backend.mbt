///|
/// Backend message parsers for PostgreSQL protocol 3.x.
///
/// Primary references:
/// - https://www.postgresql.org/docs/current/protocol-overview.html
/// - https://www.postgresql.org/docs/current/protocol-flow.html
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html
/// - https://www.postgresql.org/docs/current/protocol-error-fields.html
/// Backend message tags from protocol Section 54.7.
///
/// This parser covers the tags needed for authentication, simple query,
/// extended query, notifications, and COPY IN/OUT. Replication-specific tags
/// such as `W` (`CopyBothResponse`) and protocol-negotiation tag `v`
/// (`NegotiateProtocolVersion`) are intentionally not parsed here.
pub const PARSE_COMPLETE_TAG : Byte = b'1'

///|
pub const BIND_COMPLETE_TAG : Byte = b'2'

///|
pub const CLOSE_COMPLETE_TAG : Byte = b'3'

///|
pub const NOTIFICATION_RESPONSE_TAG : Byte = b'A'

///|
pub const COPY_DONE_TAG : Byte = b'c'

///|
pub const COMMAND_COMPLETE_TAG : Byte = b'C'

///|
pub const COPY_DATA_TAG : Byte = b'd'

///|
pub const DATA_ROW_TAG : Byte = b'D'

///|
pub const ERROR_RESPONSE_TAG : Byte = b'E'

///|
pub const COPY_IN_RESPONSE_TAG : Byte = b'G'

///|
pub const COPY_OUT_RESPONSE_TAG : Byte = b'H'

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
pub const READY_FOR_QUERY_TAG : Byte = b'Z'

///|
/// Parsed `Byte1 tag + Int32 len` prefix of a backend message.
///
/// `len` includes the 4-byte length word itself, but not the initial tag byte.
pub struct Header {
  tag : Byte
  len : Int
} derive(Show)

///|
/// Parse a backend message header if enough bytes are available.
///
/// Returns `None` until the full 5-byte prefix has been buffered.
pub fn Header::parse(buf : BytesView) -> Header? raise @proto.ProtocolError {
  if buf.length() < 5 {
    return None
  }
  let tag = buf[0]
  let r = @proto.ByteReader::new(buf[1:5])
  let len = r.read_i32_be()
  if len < 4 {
    raise @proto.ProtocolError::InvalidInput(
      "invalid message length: header length < 4",
    )
  }
  Some({ tag, len })
}

///|
/// Parsed backend message plus the number of bytes consumed from the input
/// buffer.
///
/// `consumed` includes the tag byte, the 4-byte length word, and the message
/// body.
pub struct ParsedMessage {
  message : Message
  consumed : Int
}

///|
/// Backend messages understood by this package.
///
/// `Authentication*` variants come from the single wire tag `R` and are
/// distinguished by the authentication subtype carried in the body.
pub enum Message {
  AuthenticationCleartextPassword
  AuthenticationGss
  AuthenticationKerberosV5
  AuthenticationMd5Password(AuthenticationMd5PasswordBody)
  AuthenticationOk
  AuthenticationScmCredential
  AuthenticationSspi
  AuthenticationGssContinue(AuthenticationGssContinueBody)
  AuthenticationSasl(AuthenticationSaslBody)
  AuthenticationSaslContinue(AuthenticationSaslContinueBody)
  AuthenticationSaslFinal(AuthenticationSaslFinalBody)
  BackendKeyData(BackendKeyDataBody)
  BindComplete
  CloseComplete
  CommandComplete(CommandCompleteBody)
  CopyData(CopyDataBody)
  CopyDone
  CopyInResponse(CopyInResponseBody)
  CopyOutResponse(CopyOutResponseBody)
  DataRow(DataRowBody)
  EmptyQueryResponse
  ErrorResponse(ErrorResponseBody)
  NoData
  NoticeResponse(NoticeResponseBody)
  NotificationResponse(NotificationResponseBody)
  ParameterDescription(ParameterDescriptionBody)
  ParameterStatus(ParameterStatusBody)
  ParseComplete
  PortalSuspended
  ReadyForQuery(ReadyForQueryBody)
  RowDescription(RowDescriptionBody)
}

///|
/// Parse one complete backend message from the front of `buf`.
///
/// Returns `None` until the whole frame is buffered. The parser validates the
/// declared length before decoding the message-specific body.
pub fn Message::parse(
  buf : BytesView,
) -> ParsedMessage? raise @proto.ProtocolError {
  if buf.length() < 5 {
    return None
  }
  let tag = buf[0]
  let len_reader = @proto.ByteReader::new(buf[1:5])
  let len = len_reader.read_i32_be()
  if len < 4 {
    raise @proto.ProtocolError::InvalidInput(
      "invalid message length: header length < 4",
    )
  }
  let total_len = len + 1
  if buf.length() < total_len {
    return None
  }
  let body = buf[5:total_len]
  let reader = @proto.ByteReader::new(body)
  let message = match tag {
    PARSE_COMPLETE_TAG => Message::ParseComplete
    BIND_COMPLETE_TAG => Message::BindComplete
    CLOSE_COMPLETE_TAG => Message::CloseComplete
    NOTIFICATION_RESPONSE_TAG => {
      let process_id = reader.read_i32_be()
      let channel = reader.read_cstr()
      let msg = reader.read_cstr()
      Message::NotificationResponse({ process_id, channel, message: msg })
    }
    COPY_DONE_TAG => Message::CopyDone
    COMMAND_COMPLETE_TAG => {
      let tag_bytes = reader.read_cstr()
      Message::CommandComplete({ tag: tag_bytes })
    }
    COPY_DATA_TAG => {
      let storage = reader.read_all().to_bytes()
      Message::CopyData({ storage, })
    }
    DATA_ROW_TAG => {
      let len = reader.read_u16_be().to_int()
      let storage = reader.read_all().to_bytes()
      Message::DataRow({ storage, len })
    }
    ERROR_RESPONSE_TAG => {
      let storage = reader.read_all().to_bytes()
      Message::ErrorResponse({ storage, })
    }
    COPY_IN_RESPONSE_TAG => {
      let format = reader.read_u8()
      let len = reader.read_u16_be().to_int()
      let storage = reader.read_all().to_bytes()
      Message::CopyInResponse({ format, len, storage })
    }
    COPY_OUT_RESPONSE_TAG => {
      let format = reader.read_u8()
      let len = reader.read_u16_be().to_int()
      let storage = reader.read_all().to_bytes()
      Message::CopyOutResponse({ format, len, storage })
    }
    EMPTY_QUERY_RESPONSE_TAG => Message::EmptyQueryResponse
    BACKEND_KEY_DATA_TAG => {
      let process_id = reader.read_i32_be()
      let secret_key = reader.read_i32_be()
      Message::BackendKeyData({ process_id, secret_key })
    }
    NO_DATA_TAG => Message::NoData
    NOTICE_RESPONSE_TAG => {
      let storage = reader.read_all().to_bytes()
      Message::NoticeResponse({ storage, })
    }
    AUTHENTICATION_TAG => {
      // `AuthenticationRequest` reuses tag `R`; a 32-bit subtype selects the
      // concrete authentication method or challenge frame.
      let auth_tag = reader.read_i32_be()
      match auth_tag {
        0 => Message::AuthenticationOk
        2 => Message::AuthenticationKerberosV5
        3 => Message::AuthenticationCleartextPassword
        5 => {
          let salt = reader.read_bytes(4).to_bytes()
          Message::AuthenticationMd5Password({ salt, })
        }
        6 => Message::AuthenticationScmCredential
        7 => Message::AuthenticationGss
        8 => {
          let data = reader.read_all().to_bytes()
          Message::AuthenticationGssContinue({ data, })
        }
        9 => Message::AuthenticationSspi
        10 => {
          let data = reader.read_all().to_bytes()
          Message::AuthenticationSasl({ data, })
        }
        11 => {
          let data = reader.read_all().to_bytes()
          Message::AuthenticationSaslContinue({ data, })
        }
        12 => {
          let data = reader.read_all().to_bytes()
          Message::AuthenticationSaslFinal({ data, })
        }
        _ =>
          raise @proto.ProtocolError::InvalidInput("unknown authentication tag")
      }
    }
    PORTAL_SUSPENDED_TAG => Message::PortalSuspended
    PARAMETER_STATUS_TAG => {
      let name = reader.read_cstr()
      let value = reader.read_cstr()
      Message::ParameterStatus({ name, value })
    }
    PARAMETER_DESCRIPTION_TAG => {
      let len = reader.read_u16_be().to_int()
      let storage = reader.read_all().to_bytes()
      Message::ParameterDescription({ storage, len })
    }
    ROW_DESCRIPTION_TAG => {
      let len = reader.read_u16_be().to_int()
      let storage = reader.read_all().to_bytes()
      Message::RowDescription({ storage, len })
    }
    READY_FOR_QUERY_TAG => {
      let status = reader.read_u8()
      Message::ReadyForQuery({ status, })
    }
    _ => raise @proto.ProtocolError::InvalidInput("unknown message tag")
  }
  if !reader.is_empty() {
    raise @proto.ProtocolError::InvalidInput(
      "invalid message length: expected buffer to be empty",
    )
  }
  Some({ message, consumed: total_len })
}

///|
/// Body of `AuthenticationMD5Password`.
///
/// The server provides a 4-byte salt that the frontend must mix into the MD5
/// password response.
pub struct AuthenticationMd5PasswordBody {
  salt : Bytes
}

///|
pub struct AuthenticationGssContinueBody {
  data : Bytes
}

///|
/// Return the opaque GSS continuation payload.
pub fn AuthenticationGssContinueBody::data(
  self : AuthenticationGssContinueBody,
) -> BytesView {
  self.data[:]
}

///|
/// Body of `AuthenticationSASL`.
///
/// The payload is a sequence of protocol `String` mechanism names terminated by
/// an extra zero byte.
///
/// Wire order after the authentication subtype:
/// 1. repeated `String` SASL mechanism names
/// 2. trailing zero byte terminator
///
/// See:
/// - https://www.postgresql.org/docs/current/sasl-authentication.html
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html
pub struct AuthenticationSaslBody {
  data : Bytes
}

///|
/// Return an iterator over the advertised SASL mechanisms.
pub fn AuthenticationSaslBody::mechanisms(
  self : AuthenticationSaslBody,
) -> SaslMechanisms {
  { buf: self.data[:] }
}

///|
/// Iterator over the NUL-terminated SASL mechanism list carried by
/// `AuthenticationSASL`.
///
/// Each successful `next()` consumes one mechanism `String`. The final empty
/// string on the wire is represented only as end-of-iterator.
pub struct SaslMechanisms {
  mut buf : BytesView
}

///|
/// Read the next advertised SASL mechanism as raw bytes.
pub fn SaslMechanisms::next(
  self : SaslMechanisms,
) -> Bytes? raise @proto.ProtocolError {
  if self.buf.length() == 0 {
    return None
  }
  let pos = find_null(self.buf, 0)
  if pos == 0 {
    if self.buf.length() != 1 {
      raise @proto.ProtocolError::InvalidInput(
        "invalid message length: expected to be at end of iterator for sasl",
      )
    }
    self.buf = b""[:]
    None
  } else {
    let value = self.buf[0:pos]
    self.buf = self.buf[pos + 1:]
    Some(value.to_bytes())
  }
}

///|
/// Read the next advertised SASL mechanism as UTF-8 text.
pub fn SaslMechanisms::next_str(
  self : SaslMechanisms,
) -> String? raise @proto.ProtocolError {
  match self.next() {
    None => None
    Some(value) => Some(decode_utf8(value[:]))
  }
}

///|
pub struct AuthenticationSaslContinueBody {
  data : Bytes
}

///|
/// Return the server-first SCRAM payload.
pub fn AuthenticationSaslContinueBody::data(
  self : AuthenticationSaslContinueBody,
) -> BytesView {
  self.data[:]
}

///|
pub struct AuthenticationSaslFinalBody {
  data : Bytes
}

///|
/// Return the server-final SCRAM payload.
pub fn AuthenticationSaslFinalBody::data(
  self : AuthenticationSaslFinalBody,
) -> BytesView {
  self.data[:]
}

///|
/// Body of `BackendKeyData`.
///
/// Protocol 3.2 extends the secret key to a variable-length byte field. This
/// parser still models the pre-3.2 fixed-width integer form and therefore
/// documents the current implementation boundary.
///
/// Wire order on the server side:
/// 1. `Int32` backend process ID
/// 2. `Byte n` secret key bytes to end of message
///
/// Current implementation boundary:
/// - parses step 2 as the historical pre-3.2 `Int32` form
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-flow.html
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html
/// - https://www.postgresql.org/docs/current/protocol-overview.html
pub struct BackendKeyDataBody {
  process_id : Int
  secret_key : Int
}

///|
/// Body of `CommandComplete`.
///
/// The backend command tag is textual metadata such as `INSERT 0 1` or
/// `SELECT 3`.
pub struct CommandCompleteBody {
  tag : Bytes
}

///|
/// Return the raw command tag bytes.
pub fn CommandCompleteBody::tag_bytes(self : CommandCompleteBody) -> BytesView {
  self.tag[:]
}

///|
/// Decode the command tag as UTF-8 text.
pub fn CommandCompleteBody::tag_str(
  self : CommandCompleteBody,
) -> String raise @proto.ProtocolError {
  decode_utf8(self.tag[:])
}

///|
pub struct CopyDataBody {
  storage : Bytes
}

///|
/// Return the raw COPY data payload.
pub fn CopyDataBody::data(self : CopyDataBody) -> BytesView {
  self.storage[:]
}

///|
/// Body of `CopyInResponse`.
///
/// `format` is the overall COPY format (`0` text, `1` binary). The remaining
/// payload is an `Int16[N]` array of per-column format codes.
///
/// Wire order:
/// 1. `Int8` overall COPY format
/// 2. `Int16 N` column count
/// 3. `Int16[N]` per-column format codes
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-flow.html
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html
pub struct CopyInResponseBody {
  format : Byte
  len : Int
  storage : Bytes
}

///|
/// Return an iterator over the COPY IN column format codes.
pub fn CopyInResponseBody::column_formats(
  self : CopyInResponseBody,
) -> ColumnFormats {
  { remaining: self.len, buf: self.storage[:] }
}

///|
/// Iterator over the `Int16[N]` column-format array used by COPY response
/// messages.
pub struct ColumnFormats {
  mut buf : BytesView
  mut remaining : Int
}

///|
/// Read the next COPY column format code.
pub fn ColumnFormats::next(
  self : ColumnFormats,
) -> Int? raise @proto.ProtocolError {
  if self.remaining == 0 {
    if self.buf.length() == 0 {
      return None
    }
    raise @proto.ProtocolError::InvalidInput(
      "invalid message length: wrong column formats",
    )
  }
  self.remaining = self.remaining - 1
  let r = @proto.ByteReader::new(self.buf)
  let v = r.read_u16_be().to_int()
  self.buf = self.buf[2:]
  Some(v)
}

///|
/// Body of `CopyOutResponse`.
///
/// Wire order matches `CopyInResponse`:
/// 1. `Int8` overall COPY format
/// 2. `Int16 N` column count
/// 3. `Int16[N]` per-column format codes
pub struct CopyOutResponseBody {
  format : Byte
  len : Int
  storage : Bytes
}

///|
/// Return an iterator over the COPY OUT column format codes.
pub fn CopyOutResponseBody::column_formats(
  self : CopyOutResponseBody,
) -> ColumnFormats {
  { remaining: self.len, buf: self.storage[:] }
}

///|
/// Body of `DataRow`.
///
/// `len` is the number of columns. `storage` contains only the repeated
/// `Int32 len + Byte n` field payloads that follow that count.
///
/// Full wire order:
/// 1. `Int16 N` column count
/// 2. repeated `N` times: `Int32 len`, then `Byte n` value bytes
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html
pub struct DataRowBody {
  storage : Bytes
  len : Int
} derive(Show, Eq)

///|
/// Return an iterator over the raw value ranges in this row.
pub fn DataRowBody::ranges(self : DataRowBody) -> DataRowRanges {
  { buf: self.storage[:], len: self.storage.length(), remaining: self.len }
}

///|
/// Return the raw row payload buffer.
pub fn DataRowBody::buffer(self : DataRowBody) -> BytesView {
  self.storage[:]
}

///|
/// Half-open byte range into `DataRowBody::buffer`.
pub struct ByteRange {
  start : Int
  end : Int
}

///|
/// Iterator over the raw field slots of a `DataRow`.
///
/// Each element is `None` for SQL NULL or `Some(range)` identifying the value
/// bytes inside the row buffer.
///
/// The returned byte ranges are offsets into `DataRowBody::buffer()`, not into
/// the original full message frame.
pub struct DataRowRanges {
  mut buf : BytesView
  len : Int
  mut remaining : Int
}

///|
/// Read the next field range from a data row.
pub fn DataRowRanges::next(
  self : DataRowRanges,
) -> ByteRange?? raise @proto.ProtocolError {
  if self.remaining == 0 {
    if self.buf.length() == 0 {
      return None
    }
    raise @proto.ProtocolError::InvalidInput(
      "invalid message length: datarowrange is not empty",
    )
  }
  self.remaining = self.remaining - 1
  let r = @proto.ByteReader::new(self.buf)
  let len = r.read_i32_be()
  if len < 0 {
    if len != -1 {
      raise @proto.ProtocolError::InvalidInput("invalid value length")
    }
    self.buf = self.buf[4:]
    return Some(None)
  }
  let len = len
  if self.buf.length() < 4 + len {
    raise @proto.ProtocolError::UnexpectedEof("unexpected EOF")
  }
  let base = self.len - self.buf.length()
  let start = base + 4
  let end = start + len
  self.buf = self.buf[4 + len:]
  Some(Some({ start, end }))
}

///|
/// Body of `ErrorResponse`.
///
/// The payload is an unordered sequence of identified string fields terminated
/// by a zero byte.
///
/// Wire order:
/// 1. repeated fields: `Byte1 field_code`, then `String field_value`
/// 2. trailing zero byte terminator
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html
/// - https://www.postgresql.org/docs/current/protocol-error-fields.html
pub struct ErrorResponseBody {
  storage : Bytes
}

///|
/// Return an iterator over error fields.
pub fn ErrorResponseBody::fields(self : ErrorResponseBody) -> ErrorFields {
  { buf: self.storage[:] }
}

///|
/// Iterator over the field list contained in `ErrorResponse` and
/// `NoticeResponse`.
///
/// Field order is not semantically significant, but the iterator preserves the
/// order received from the server.
pub struct ErrorFields {
  mut buf : BytesView
}

///|
/// Read the next error field.
pub fn ErrorFields::next(
  self : ErrorFields,
) -> ErrorField? raise @proto.ProtocolError {
  if self.buf.length() == 0 {
    return None
  }
  let type_ = self.buf[0]
  self.buf = self.buf[1:]
  if type_ == 0 {
    if self.buf.length() == 0 {
      return None
    }
    raise @proto.ProtocolError::InvalidInput(
      "invalid message length: error fields is not drained",
    )
  }
  let value_end = find_null(self.buf, 0)
  let value = self.buf[0:value_end]
  self.buf = self.buf[value_end + 1:]
  Some({ type_, value: value.to_bytes() })
}

///|
/// One identified field from `ErrorResponse` or `NoticeResponse`.
///
/// `type_` is the field code from protocol Section 54.8, such as `S`, `V`,
/// `C`, or `M`.
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-error-fields.html
pub struct ErrorField {
  type_ : Byte
  value : Bytes
}

///|
/// Return the raw field value bytes.
pub fn ErrorField::value_bytes(self : ErrorField) -> BytesView {
  self.value[:]
}

///|
/// Body of `NoticeResponse`.
pub struct NoticeResponseBody {
  storage : Bytes
}

///|
/// Return an iterator over notice fields.
pub fn NoticeResponseBody::fields(self : NoticeResponseBody) -> ErrorFields {
  { buf: self.storage[:] }
}

///|
/// Body of `NotificationResponse`.
///
/// Carries the notifying backend PID, channel name, and textual payload.
pub struct NotificationResponseBody {
  process_id : Int
  channel : Bytes
  message : Bytes
}

///|
/// Return the notification channel as raw bytes.
pub fn NotificationResponseBody::channel_bytes(
  self : NotificationResponseBody,
) -> BytesView {
  self.channel[:]
}

///|
/// Decode the notification channel as UTF-8 text.
pub fn NotificationResponseBody::channel_str(
  self : NotificationResponseBody,
) -> String raise @proto.ProtocolError {
  decode_utf8(self.channel[:])
}

///|
/// Return the notification payload as raw bytes.
pub fn NotificationResponseBody::message_bytes(
  self : NotificationResponseBody,
) -> BytesView {
  self.message[:]
}

///|
/// Decode the notification payload as UTF-8 text.
pub fn NotificationResponseBody::message_str(
  self : NotificationResponseBody,
) -> String raise @proto.ProtocolError {
  decode_utf8(self.message[:])
}

///|
/// Body of `ParameterDescription`.
///
/// The payload is a count followed by one OID per query parameter.
///
/// Full wire order:
/// 1. `Int16 N` parameter count
/// 2. `Int32[N]` parameter type OIDs
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html
pub struct ParameterDescriptionBody {
  storage : Bytes
  len : Int
}

///|
/// Return an iterator over described parameter type OIDs.
pub fn ParameterDescriptionBody::parameters(
  self : ParameterDescriptionBody,
) -> Parameters {
  { buf: self.storage[:], remaining: self.len }
}

///|
/// Iterator over the parameter type OIDs stored in `ParameterDescription`.
///
/// The leading `Int16` count has already been stripped; `buf` starts at the
/// first 4-byte OID.
pub struct Parameters {
  mut buf : BytesView
  mut remaining : Int
}

///|
/// Read the next described parameter type OID.
pub fn Parameters::next(
  self : Parameters,
) -> @proto.Oid? raise @proto.ProtocolError {
  if self.remaining == 0 {
    if self.buf.length() == 0 {
      return None
    }
    raise @proto.ProtocolError::InvalidInput(
      "invalid message length: parameters is not drained",
    )
  }
  self.remaining = self.remaining - 1
  let r = @proto.ByteReader::new(self.buf)
  let v = r.read_u32_be()
  self.buf = self.buf[4:]
  Some(v)
}

///|
/// Body of `ParameterStatus`.
///
/// These messages report run-time parameters such as `client_encoding` and
/// `server_version`.
pub struct ParameterStatusBody {
  name : Bytes
  value : Bytes
}

///|
/// Return the parameter name as raw bytes.
pub fn ParameterStatusBody::name_bytes(self : ParameterStatusBody) -> BytesView {
  self.name[:]
}

///|
/// Return the parameter value as raw bytes.
pub fn ParameterStatusBody::value_bytes(
  self : ParameterStatusBody,
) -> BytesView {
  self.value[:]
}

///|
/// Decode the parameter name as UTF-8 text.
pub fn ParameterStatusBody::name_str(
  self : ParameterStatusBody,
) -> String raise @proto.ProtocolError {
  decode_utf8(self.name[:])
}

///|
/// Decode the parameter value as UTF-8 text.
pub fn ParameterStatusBody::value_str(
  self : ParameterStatusBody,
) -> String raise @proto.ProtocolError {
  decode_utf8(self.value[:])
}

///|
/// Body of `ReadyForQuery`.
///
/// `status` is `I` when idle, `T` when inside a transaction block, and `E`
/// when the transaction is failed and can only accept rollback-like commands.
///
/// Wire order:
/// 1. single `Byte1` transaction status indicator
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-flow.html
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html
pub struct ReadyForQueryBody {
  status : Byte
}

///|
/// Body of `RowDescription`.
///
/// The payload is a field count followed by one field descriptor per result
/// column.
///
/// Full wire order:
/// 1. `Int16 N` result-column count
/// 2. repeated `N` times:
///    `String name`
///    `Int32 table_oid`
///    `Int16 column_id`
///    `Int32 type_oid`
///    `Int16 type_size`
///    `Int32 type_modifier`
///    `Int16 format`
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html
pub struct RowDescriptionBody {
  storage : Bytes
  len : Int
}

///|
/// Return an iterator over described result fields.
pub fn RowDescriptionBody::fields(self : RowDescriptionBody) -> Fields {
  { buf: self.storage[:], remaining: self.len }
}

///|
/// Iterator over the field descriptors stored in `RowDescription`.
///
/// The leading `Int16` field count has already been stripped; `buf` points at
/// the first column descriptor.
pub struct Fields {
  mut buf : BytesView
  mut remaining : Int
}

///|
/// Read the next described result field.
///
/// This decodes one descriptor in the exact order defined by protocol Section
/// 54.7: name, table OID, attribute number, type OID, type size, type modifier,
/// and format code.
pub fn Fields::next(self : Fields) -> Field? raise @proto.ProtocolError {
  if self.remaining == 0 {
    if self.buf.length() == 0 {
      return None
    }
    raise @proto.ProtocolError::InvalidInput(
      "invalid message length: field is not drained",
    )
  }
  self.remaining = self.remaining - 1
  let name_end = find_null(self.buf, 0)
  let name = self.buf[0:name_end]
  self.buf = self.buf[name_end + 1:]
  let r = @proto.ByteReader::new(self.buf)
  let table_oid = r.read_u32_be()
  let column_id = r.read_i16_be()
  let type_oid = r.read_u32_be()
  let type_size = r.read_i16_be()
  let type_modifier = r.read_i32_be()
  let format = r.read_i16_be()
  self.buf = self.buf[18:]
  Some({
    name: name.to_bytes(),
    table_oid,
    column_id,
    type_oid,
    type_size,
    type_modifier,
    format,
  })
}

///|
/// One result-column descriptor from `RowDescription`.
///
/// `table_oid` and `column_id` are zero when the field does not map to a base
/// table column. `format` follows the standard convention `0 = text`,
/// `1 = binary`. Negative `type_size` values denote variable-width types.
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html
pub struct Field {
  name : Bytes
  table_oid : @proto.Oid
  column_id : Int
  type_oid : @proto.Oid
  type_size : Int
  type_modifier : Int
  format : Int
}

///|
/// Return the field name as raw bytes.
pub fn Field::name_bytes(self : Field) -> BytesView {
  self.name[:]
}

///|
/// Decode the field name as UTF-8 text.
pub fn Field::name_str(self : Field) -> String raise @proto.ProtocolError {
  decode_utf8(self.name[:])
}

///|
/// Find the next NUL terminator used by backend protocol `String` values.
fn find_null(buf : BytesView, start : Int) -> Int raise @proto.ProtocolError {
  let mut i = start
  while i < buf.length() {
    if buf[i] == 0 {
      return i
    }
    i = i + 1
  }
  raise @proto.ProtocolError::UnexpectedEof("unexpected EOF")
}

///|
/// Decode a backend string as UTF-8.
///
/// The client configures `client_encoding=UTF8` during startup, so backend text
/// fields handled by this package are expected to decode successfully.
fn decode_utf8(bytes : BytesView) -> String raise @proto.ProtocolError {
  @utf8.decode(bytes) catch {
    _ => raise @proto.ProtocolError::InvalidInput("invalid UTF-8")
  }
}
