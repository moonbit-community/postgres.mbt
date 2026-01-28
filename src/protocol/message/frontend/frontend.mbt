///|
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
/// Serialize a Bind message.
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
  write_body(buf, fn(b) {
    write_cstr(portal, b)
    write_cstr(statement, b)
    write_counted(
      formats,
      fn(f, b) { b.write_int16_be(@proto.checked_i16(f)) },
      b,
    )
    write_counted(
      values,
      fn(v, b) { @proto.write_nullable(fn(b2) { serializer(v, b2) }, b) },
      b,
    )
    write_counted(
      result_formats,
      fn(f, b) { b.write_int16_be(@proto.checked_i16(f)) },
      b,
    )
  })
}

///|
/// Serialize a CancelRequest message.
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
/// Serialize a Close message.
pub fn close(
  variant : Byte,
  name : BytesView,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_byte(b'C')
  write_body(buf, fn(b) {
    b.write_byte(variant)
    write_cstr(name, b)
  })
}

///|
/// A CopyData message writer.
pub struct CopyData {
  buf : Bytes
  len : Int
}

///|
pub fn CopyData::new(buf : BytesView) -> CopyData raise @proto.ProtocolError {
  let len = buf.length() + 4
  let _ = @proto.checked_i32(len)
  { buf: buf.to_bytes(), len }
}

///|
pub fn CopyData::write(self : CopyData, out : @buffer.Buffer) -> Unit {
  out.write_byte(b'd')
  out.write_int_be(self.len)
  out.write_bytes(self.buf)
}

///|
/// Serialize a CopyDone message.
pub fn copy_done(buf : @buffer.Buffer) -> Unit {
  buf.write_byte(b'c')
  try! write_body(buf, fn(_) { () })
}

///|
/// Serialize a CopyFail message.
pub fn copy_fail(
  message : BytesView,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_byte(b'f')
  write_body(buf, fn(b) { write_cstr(message, b) })
}

///|
/// Serialize a Describe message.
pub fn describe(
  variant : Byte,
  name : BytesView,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_byte(b'D')
  write_body(buf, fn(b) {
    b.write_byte(variant)
    write_cstr(name, b)
  })
}

///|
/// Serialize an Execute message.
pub fn execute(
  portal : BytesView,
  max_rows : Int,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_byte(b'E')
  write_body(buf, fn(b) {
    write_cstr(portal, b)
    b.write_int_be(@proto.checked_i32(max_rows))
  })
}

///|
/// Serialize a Parse message.
pub fn parse(
  name : BytesView,
  query : BytesView,
  param_types : Iter[@proto.Oid],
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_byte(b'P')
  write_body(buf, fn(b) {
    write_cstr(name, b)
    write_cstr(query, b)
    write_counted(param_types, fn(t, b) { b.write_uint_be(t) }, b)
  })
}

///|
/// Serialize a PasswordMessage.
pub fn password_message(
  password : BytesView,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_byte(b'p')
  write_body(buf, fn(b) { write_cstr(password, b) })
}

///|
/// Serialize a Query message.
pub fn query(
  query : BytesView,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_byte(b'Q')
  write_body(buf, fn(b) { write_cstr(query, b) })
}

///|
/// Serialize a SASLInitialResponse message.
pub fn sasl_initial_response(
  mechanism : BytesView,
  data : BytesView,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_byte(b'p')
  write_body(buf, fn(b) {
    write_cstr(mechanism, b)
    let len = @proto.i32_from_usize(data.length())
    b.write_int_be(len)
    b.write_bytesview(data)
  })
}

///|
/// Serialize a SASLResponse message.
pub fn sasl_response(
  data : BytesView,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_byte(b'p')
  write_body(buf, fn(b) { b.write_bytesview(data) })
}

///|
/// Serialize an SSLRequest message.
pub fn ssl_request(buf : @buffer.Buffer) -> Unit {
  try! write_body(buf, fn(b) { b.write_int_be(80_877_103) })
}

///|
/// Serialize a StartupMessage.
pub fn startup_message(
  parameters : Iter[(BytesView, BytesView)],
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  write_body(buf, fn(b) {
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
/// Serialize a Flush message.
pub fn flush(buf : @buffer.Buffer) -> Unit {
  buf.write_byte(b'H')
  try! write_body(buf, fn(_) { () })
}

///|
/// Serialize a Sync message.
pub fn sync(buf : @buffer.Buffer) -> Unit {
  buf.write_byte(b'S')
  try! write_body(buf, fn(_) { () })
}

///|
/// Serialize a Terminate message.
pub fn terminate(buf : @buffer.Buffer) -> Unit {
  buf.write_byte(b'X')
  try! write_body(buf, fn(_) { () })
}
