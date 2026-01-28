///|
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
pub struct Header {
  tag : Byte
  len : Int
} derive(Show)

///|
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
pub fn Header::tag(self : Header) -> Byte {
  self.tag
}

///|
pub fn Header::len(self : Header) -> Int {
  self.len
}

///|
/// Parsed backend message plus consumed bytes.
pub struct ParsedMessage {
  message : Message
  consumed : Int
}

///|
pub fn ParsedMessage::message(self : ParsedMessage) -> Message {
  self.message
}

///|
pub fn ParsedMessage::consumed(self : ParsedMessage) -> Int {
  self.consumed
}

///|
/// Backend messages.
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
  if not(reader.is_empty()) {
    raise @proto.ProtocolError::InvalidInput(
      "invalid message length: expected buffer to be empty",
    )
  }
  Some({ message, consumed: total_len })
}

///|
pub struct AuthenticationMd5PasswordBody {
  salt : Bytes
}

///|
pub fn AuthenticationMd5PasswordBody::salt(
  self : AuthenticationMd5PasswordBody,
) -> Bytes {
  self.salt
}

///|
pub struct AuthenticationGssContinueBody {
  data : Bytes
}

///|
pub fn AuthenticationGssContinueBody::data(
  self : AuthenticationGssContinueBody,
) -> BytesView {
  self.data[:]
}

///|
pub struct AuthenticationSaslBody {
  data : Bytes
}

///|
pub fn AuthenticationSaslBody::mechanisms(
  self : AuthenticationSaslBody,
) -> SaslMechanisms {
  { buf: self.data[:] }
}

///|
pub struct SaslMechanisms {
  mut buf : BytesView
}

///|
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
pub struct AuthenticationSaslContinueBody {
  data : Bytes
}

///|
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
pub fn AuthenticationSaslFinalBody::data(
  self : AuthenticationSaslFinalBody,
) -> BytesView {
  self.data[:]
}

///|
pub struct BackendKeyDataBody {
  process_id : Int
  secret_key : Int
}

///|
pub fn BackendKeyDataBody::process_id(self : BackendKeyDataBody) -> Int {
  self.process_id
}

///|
pub fn BackendKeyDataBody::secret_key(self : BackendKeyDataBody) -> Int {
  self.secret_key
}

///|
pub struct CommandCompleteBody {
  tag : Bytes
}

///|
pub fn CommandCompleteBody::tag_bytes(self : CommandCompleteBody) -> BytesView {
  self.tag[:]
}

///|
pub struct CopyDataBody {
  storage : Bytes
}

///|
pub fn CopyDataBody::data(self : CopyDataBody) -> BytesView {
  self.storage[:]
}

///|
pub fn CopyDataBody::into_bytes(self : CopyDataBody) -> Bytes {
  self.storage
}

///|
pub struct CopyInResponseBody {
  format : Byte
  len : Int
  storage : Bytes
}

///|
pub fn CopyInResponseBody::format(self : CopyInResponseBody) -> Byte {
  self.format
}

///|
pub fn CopyInResponseBody::column_formats(
  self : CopyInResponseBody,
) -> ColumnFormats {
  { remaining: self.len, buf: self.storage[:] }
}

///|
pub struct ColumnFormats {
  mut buf : BytesView
  mut remaining : Int
}

///|
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
pub struct CopyOutResponseBody {
  format : Byte
  len : Int
  storage : Bytes
}

///|
pub fn CopyOutResponseBody::format(self : CopyOutResponseBody) -> Byte {
  self.format
}

///|
pub fn CopyOutResponseBody::column_formats(
  self : CopyOutResponseBody,
) -> ColumnFormats {
  { remaining: self.len, buf: self.storage[:] }
}

///|
pub struct DataRowBody {
  storage : Bytes
  len : Int
} derive(Show, Eq)

///|
pub fn DataRowBody::ranges(self : DataRowBody) -> DataRowRanges {
  { buf: self.storage[:], len: self.storage.length(), remaining: self.len }
}

///|
pub fn DataRowBody::buffer(self : DataRowBody) -> BytesView {
  self.storage[:]
}

///|
pub fn DataRowBody::buffer_bytes(self : DataRowBody) -> Bytes {
  self.storage
}

///|
pub struct ByteRange {
  start : Int
  end : Int
}

///|
pub fn ByteRange::start(self : ByteRange) -> Int {
  self.start
}

///|
pub fn ByteRange::end(self : ByteRange) -> Int {
  self.end
}

///|
pub struct DataRowRanges {
  mut buf : BytesView
  len : Int
  mut remaining : Int
}

///|
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
pub struct ErrorResponseBody {
  storage : Bytes
}

///|
pub fn ErrorResponseBody::fields(self : ErrorResponseBody) -> ErrorFields {
  { buf: self.storage[:] }
}

///|
pub struct ErrorFields {
  mut buf : BytesView
}

///|
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
pub struct ErrorField {
  type_ : Byte
  value : Bytes
}

///|
pub fn ErrorField::type_(self : ErrorField) -> Byte {
  self.type_
}

///|
pub fn ErrorField::value_bytes(self : ErrorField) -> BytesView {
  self.value[:]
}

///|
pub struct NoticeResponseBody {
  storage : Bytes
}

///|
pub fn NoticeResponseBody::fields(self : NoticeResponseBody) -> ErrorFields {
  { buf: self.storage[:] }
}

///|
pub struct NotificationResponseBody {
  process_id : Int
  channel : Bytes
  message : Bytes
}

///|
pub fn NotificationResponseBody::process_id(
  self : NotificationResponseBody,
) -> Int {
  self.process_id
}

///|
pub fn NotificationResponseBody::channel_bytes(
  self : NotificationResponseBody,
) -> BytesView {
  self.channel[:]
}

///|
pub fn NotificationResponseBody::message_bytes(
  self : NotificationResponseBody,
) -> BytesView {
  self.message[:]
}

///|
pub struct ParameterDescriptionBody {
  storage : Bytes
  len : Int
}

///|
pub fn ParameterDescriptionBody::parameters(
  self : ParameterDescriptionBody,
) -> Parameters {
  { buf: self.storage[:], remaining: self.len }
}

///|
pub struct Parameters {
  mut buf : BytesView
  mut remaining : Int
}

///|
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
pub struct ParameterStatusBody {
  name : Bytes
  value : Bytes
}

///|
pub fn ParameterStatusBody::name_bytes(self : ParameterStatusBody) -> BytesView {
  self.name[:]
}

///|
pub fn ParameterStatusBody::value_bytes(
  self : ParameterStatusBody,
) -> BytesView {
  self.value[:]
}

///|
pub struct ReadyForQueryBody {
  status : Byte
}

///|
pub fn ReadyForQueryBody::status(self : ReadyForQueryBody) -> Byte {
  self.status
}

///|
pub struct RowDescriptionBody {
  storage : Bytes
  len : Int
}

///|
pub fn RowDescriptionBody::fields(self : RowDescriptionBody) -> Fields {
  { buf: self.storage[:], remaining: self.len }
}

///|
pub struct Fields {
  mut buf : BytesView
  mut remaining : Int
}

///|
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
pub fn Field::name_bytes(self : Field) -> BytesView {
  self.name[:]
}

///|
pub fn Field::table_oid(self : Field) -> @proto.Oid {
  self.table_oid
}

///|
pub fn Field::column_id(self : Field) -> Int {
  self.column_id
}

///|
pub fn Field::type_oid(self : Field) -> @proto.Oid {
  self.type_oid
}

///|
pub fn Field::type_size(self : Field) -> Int {
  self.type_size
}

///|
pub fn Field::type_modifier(self : Field) -> Int {
  self.type_modifier
}

///|
pub fn Field::format(self : Field) -> Int {
  self.format
}

///|
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
