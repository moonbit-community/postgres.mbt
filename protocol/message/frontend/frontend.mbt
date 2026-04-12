///|
/// Frontend message serializers for PostgreSQL protocol 3.x.
///
/// Primary references:
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-START-UP
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-SIMPLE-QUERY
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-EXT-QUERY
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS
/// Write the length-prefixed body portion shared by almost all frontend
/// messages.
///
/// In PostgreSQL's normal message framing, the tag byte is followed by an
/// `Int32` length that includes itself but not the tag byte. Callers are
/// responsible for writing the tag first. `StartupMessage` is the one exception
/// and therefore calls this helper without writing a tag.
fn write_body(
  buf : @buffer.Buffer,
  f : (@buffer.Buffer) -> Unit raise @proto.ProtocolError,
) -> Unit raise @proto.ProtocolError {
  let body = @buffer.new()
  f(body)
  let size = @proto.i32_from_usize(body.length() + 4)
  buf.write_int_be(size)
  buf.write_bytes(body.to_bytes())
}

///|
/// Write an `Int16` count followed by that many values.
///
/// Protocol Section 54.7 uses this pattern for format-code arrays and OID
/// arrays in messages such as `Bind` and `Parse`.
fn[T] write_counted(
  items : Iter[T],
  serializer : (T, @buffer.Buffer) -> Unit raise @proto.ProtocolError,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  let payload = @buffer.new()
  let mut count = 0
  for item in items {
    serializer(item, payload)
    count = count + 1
  }
  let count_i16 = @proto.i16_from_usize(count)
  buf.write_uint16_be(count_i16.reinterpret_as_uint16())
  buf.write_bytes(payload.to_bytes())
}

///|
/// Write a protocol `String`.
///
/// PostgreSQL message strings are NUL-terminated, so embedded zero bytes would
/// truncate the field and are therefore rejected here.
fn write_cstr(
  s : BytesView,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  for b in s {
    if b == 0 {
      raise @proto.ProtocolError::InvalidInput("string contains embedded null")
    }
  }
  buf.write_bytesview(s)
  buf.write_byte(b'\x00')
}

///|
/// Serialize a `Bind` message for the extended query protocol.
///
/// The parameter payloads are written as repeated `Int32 len + Byte n` fields,
/// where `-1` denotes NULL. Result format codes follow PostgreSQL's usual
/// convention of `0 = text` and `1 = binary`.
///
/// Wire order:
/// 1. `String` destination portal name
/// 2. `String` source prepared-statement name
/// 3. `Int16 C`, then `Int16[C]` parameter format codes
/// 4. `Int16 N`, then `N` times: `Int32 len` plus `Byte n` payload
/// 5. `Int16 R`, then `Int16[R]` result-column format codes
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-EXT-QUERY
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-BIND
pub fn[T] bind(
  portal : BytesView,
  statement : BytesView,
  formats : Iter[Int],
  values : Iter[T],
  serializer : (T, @buffer.Buffer) -> @proto.IsNull raise @proto.ProtocolError,
  result_formats : Iter[Int],
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_byte(b'B')
  write_body(buf, b => {
    write_cstr(portal, b)
    write_cstr(statement, b)
    write_counted(formats, (f, b) => b.write_int16_be(@proto.checked_i16(f)), b)
    write_counted(
      values,
      (v, b) => @proto.write_nullable(b2 => serializer(v, b2), b),
      b,
    )
    write_counted(
      result_formats,
      (f, b) => b.write_int16_be(@proto.checked_i16(f)),
      b,
    )
  })
}

///|
/// Serialize a `CancelRequest` startup packet.
///
/// The current implementation writes the historical 4-byte secret key used by
/// protocol 3.0. PostgreSQL 3.2 redefines this field as variable-length.
///
/// Wire order in this implementation:
/// 1. `Int32(16)` total message length
/// 2. `Int32(80877102)` cancel request code
/// 3. `Int32` backend process ID
/// 4. `Int32` backend secret key
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-CANCELING-REQUESTS
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-CANCELREQUEST
pub fn cancel_request(
  process_id : Int,
  secret_key : Int,
  buf : @buffer.Buffer,
) -> Unit {
  try! write_body(buf, fn(b) {
    b.write_int_be(80_877_102)
    b.write_int_be(process_id)
    b.write_int_be(secret_key)
  })
}

///|
/// Serialize a `Close` message.
///
/// `variant` must be `S` for a prepared statement or `P` for a portal.
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-EXT-QUERY
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-CLOSE
pub fn close(
  variant : Byte,
  name : BytesView,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_byte(b'C')
  write_body(buf, b => {
    b.write_byte(variant)
    write_cstr(name, b)
  })
}

///|
/// Prepared writer for a `CopyData` frame.
///
/// Backend `CopyData` messages always correspond to a single row, while
/// frontend `CopyData` messages may chunk the copy stream arbitrarily.
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-SIMPLE-QUERY
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-EXT-QUERY
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-COPYDATA
pub struct CopyData {
  buf : Bytes
  len : Int
}

///|
/// Construct a `CopyData` frame from raw payload bytes.
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-COPYDATA
pub fn CopyData::new(buf : BytesView) -> CopyData raise @proto.ProtocolError {
  let len = buf.length() + 4
  let _ = @proto.checked_i32(len)
  { buf: buf.to_bytes(), len }
}

///|
/// Write this `CopyData` message to `out`.
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-COPYDATA
pub fn CopyData::write(self : CopyData, out : @buffer.Buffer) -> Unit {
  out.write_byte(b'd')
  out.write_int_be(self.len)
  out.write_bytes(self.buf)
}

///|
/// Serialize `CopyDone`, indicating that the sender has finished a COPY stream.
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-SIMPLE-QUERY
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-EXT-QUERY
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-COPYDONE
pub fn copy_done(buf : @buffer.Buffer) -> Unit {
  buf.write_byte(b'c')
  try! write_body(buf, fn(_) { () })
}

///|
/// Serialize `CopyFail`, aborting a frontend COPY IN stream with an error
/// message.
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-SIMPLE-QUERY
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-EXT-QUERY
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-COPYFAIL
pub fn copy_fail(
  message : BytesView,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_byte(b'f')
  write_body(buf, b => write_cstr(message, b))
}

///|
/// Serialize a `Describe` message.
///
/// `variant` must be `S` to describe a prepared statement or `P` to describe a
/// portal.
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-EXT-QUERY
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-DESCRIBE
pub fn describe(
  variant : Byte,
  name : BytesView,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_byte(b'D')
  write_body(buf, b => {
    b.write_byte(variant)
    write_cstr(name, b)
  })
}

///|
/// Serialize an `Execute` message for a portal.
///
/// `max_rows == 0` means "no limit". A positive row limit can cause the backend
/// to stop early and emit `PortalSuspended`.
///
/// Wire order:
/// 1. `String` portal name
/// 2. `Int32` maximum rows to return before suspension
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-EXT-QUERY
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-EXECUTE
pub fn execute(
  portal : BytesView,
  max_rows : Int,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_byte(b'E')
  write_body(buf, b => {
    write_cstr(portal, b)
    b.write_int_be(@proto.checked_i32(max_rows))
  })
}

///|
/// Serialize a `Parse` message.
///
/// Each OID in `param_types` prespecifies one parameter type. A zero OID leaves
/// that parameter type unspecified for the backend to infer later.
///
/// Wire order:
/// 1. `String` prepared-statement name
/// 2. `String` query text
/// 3. `Int16 N`, then `Int32[N]` parameter type OIDs
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-EXT-QUERY
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-PARSE
pub fn parse(
  name : BytesView,
  query : BytesView,
  param_types : Iter[@proto.Oid],
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_byte(b'P')
  write_body(buf, b => {
    write_cstr(name, b)
    write_cstr(query, b)
    write_counted(param_types, fn(t, b) { b.write_uint_be(t) }, b)
  })
}

///|
/// Serialize the context-dependent `PasswordMessage` (`p`) frame.
///
/// During startup this is used for cleartext password responses. Older
/// PostgreSQL servers also used the same wire tag for deprecated MD5 password
/// replies, though this package no longer implements MD5 authentication. The
/// same wire tag is also reused by GSS and SASL messages, which have dedicated
/// helpers below.
///
/// Wire order for password authentication:
/// 1. `String` password payload
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-START-UP
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-AUTHENTICATIONCLEARTEXTPASSWORD
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-AUTHENTICATIONMD5PASSWORD
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-PASSWORDMESSAGE
pub fn password_message(
  password : BytesView,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_byte(b'p')
  write_body(buf, b => write_cstr(password, b))
}

///|
/// Serialize a simple-query `Query` message.
///
/// The query string may contain multiple semicolon-separated SQL statements,
/// which the backend executes as one simple-query cycle.
///
/// Wire order:
/// 1. `String` query text
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-SIMPLE-QUERY
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-QUERY
pub fn query(
  query : BytesView,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_byte(b'Q')
  write_body(buf, b => write_cstr(query, b))
}

///|
/// Serialize `SASLInitialResponse`.
///
/// This writes the selected mechanism name, then an explicit initial-response
/// length, then the mechanism-specific bytes. It does not encode PostgreSQL's
/// special `-1` form for "no initial response".
///
/// Wire order:
/// 1. `String` selected SASL mechanism
/// 2. `Int32` initial-response length
/// 3. `Byte n` initial-response payload
///
/// See:
/// - https://www.postgresql.org/docs/current/sasl-authentication.html#SASL-AUTH-INITIAL-RESPONSE
/// - https://www.postgresql.org/docs/current/sasl-authentication.html#SCRAM-CLIENT-FIRST
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-SASLINITIALRESPONSE
pub fn sasl_initial_response(
  mechanism : BytesView,
  data : BytesView,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_byte(b'p')
  write_body(buf, b => {
    write_cstr(mechanism, b)
    let len = @proto.i32_from_usize(data.length())
    b.write_int_be(len)
    b.write_bytesview(data)
  })
}

///|
/// Serialize `SASLResponse`, the follow-up client message used after an
/// `AuthenticationSASLContinue` challenge.
///
/// Wire order:
/// 1. `Byte n` mechanism-specific response payload
///
/// See:
/// - https://www.postgresql.org/docs/current/sasl-authentication.html#SASL-AUTH-CONTINUE
/// - https://www.postgresql.org/docs/current/sasl-authentication.html#SCRAM-CLIENT-FINAL
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-SASLRESPONSE
pub fn sasl_response(
  data : BytesView,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_byte(b'p')
  write_body(buf, fn(b) { b.write_bytesview(data) })
}

///|
/// Serialize the tagless `SSLRequest` startup packet.
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-SSL
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-SSLREQUEST
pub fn ssl_request(buf : @buffer.Buffer) -> Unit {
  try! write_body(buf, fn(b) { b.write_int_be(80_877_103) })
}

///|
/// Serialize a tagless `StartupMessage`.
///
/// Although the current PostgreSQL documentation describes protocol 3.2 as the
/// latest version, libpq still defaults to protocol 3.0 for compatibility. This
/// implementation follows that compatibility path and sends `0x00030000`
/// without attempting minor-version negotiation.
///
/// Wire order:
/// 1. `Int32` total message length
/// 2. `Int32(0x00030000)` startup protocol version
/// 3. repeated `String` parameter name + `String` parameter value pairs
/// 4. trailing zero byte terminator
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-START-UP
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-STARTUPMESSAGE
pub fn startup_message(
  parameters : Iter[(BytesView, BytesView)],
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  write_body(buf, b => {
    b.write_int_be(0x00_03_00_00)
    for pair in parameters {
      let (key, value) = pair
      write_cstr(key, b)
      write_cstr(value, b)
    }
    b.write_byte(b'\x00')
  })
}

///|
/// Serialize `Flush`, forcing the backend to emit any response messages it has
/// buffered so far.
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-EXT-QUERY
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-FLUSH
pub fn flush(buf : @buffer.Buffer) -> Unit {
  buf.write_byte(b'H')
  try! write_body(buf, fn(_) { () })
}

///|
/// Serialize `Sync`, ending the current extended-query cycle and asking the
/// backend to return to a clean `ReadyForQuery` state.
///
/// Wire order:
/// 1. no body; the length word is always `4`
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-EXT-QUERY
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-SYNC
pub fn sync(buf : @buffer.Buffer) -> Unit {
  buf.write_byte(b'S')
  try! write_body(buf, fn(_) { () })
}

///|
/// Serialize `Terminate`, requesting a graceful end to the session.
///
/// See:
/// - https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-TERMINATION
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-TERMINATE
pub fn terminate(buf : @buffer.Buffer) -> Unit {
  buf.write_byte(b'X')
  try! write_body(buf, fn(_) { () })
}
