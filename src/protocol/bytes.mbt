///|
/// Wire-level scalar decoding helpers for PostgreSQL protocol values.
///
/// Primary references:
/// - https://www.postgresql.org/docs/current/protocol-overview.html
/// - https://www.postgresql.org/docs/current/protocol-message-types.html
/// Convert a count to the signed 16-bit representation used by many protocol
/// fields, such as parameter counts and format-code counts.
pub fn i16_from_usize(len : Int) -> Int16 raise ProtocolError {
  if len < 0 || len > 0x7fff {
    raise ProtocolError::Overflow("value too large to transmit")
  }
  Int16::from_int(len)
}

///|
/// Convert a length to the signed 32-bit representation used by PostgreSQL
/// length fields.
///
/// Whether the resulting value includes the length word itself depends on the
/// surrounding message format.
pub fn i32_from_usize(len : Int) -> Int raise ProtocolError {
  if len < 0 || len > 0x7fff_ffff {
    raise ProtocolError::Overflow("value too large to transmit")
  }
  len
}

///|
/// Ensure a value fits in the signed 32-bit range accepted by wire `Int32`
/// fields.
pub fn checked_i32(value : Int) -> Int raise ProtocolError {
  if value < -0x8000_0000 || value > 0x7fff_ffff {
    raise ProtocolError::Overflow("value out of range for i32")
  }
  value
}

///|
/// Ensure a value fits in the signed 16-bit range accepted by wire `Int16`
/// fields.
pub fn checked_i16(value : Int) -> Int16 raise ProtocolError {
  if value < -0x8000 || value > 0x7fff {
    raise ProtocolError::Overflow("value out of range for i16")
  }
  Int16::from_int(value)
}

///|
/// Convert signed i32 (stored in Int) to u32 bits in UInt.
pub fn u32_from_i32(value : Int) -> UInt raise ProtocolError {
  let _ = checked_i32(value)
  value.reinterpret_as_uint()
}

///|
/// Convert u32 bits to signed i32 (stored in Int).
pub fn i32_from_u32(value : UInt) -> Int {
  value.reinterpret_as_int()
}

///|
/// Cursor-based reader for the scalar types from protocol Section 54.6.
///
/// All integer reads use network byte order, and `read_cstr` implements the
/// protocol `String` type (a NUL-terminated byte sequence).
pub struct ByteReader {
  buf : BytesView
  mut idx : Int
}

///|
/// Create a byte reader over `buf`.
pub fn ByteReader::new(buf : BytesView) -> ByteReader {
  { buf, idx: 0 }
}

///|
/// Return the number of unread bytes.
pub fn ByteReader::remaining(self : ByteReader) -> Int {
  self.buf.length() - self.idx
}

///|
/// Return whether all bytes have been consumed.
pub fn ByteReader::is_empty(self : ByteReader) -> Bool {
  self.remaining() <= 0
}

///|
/// Ensure that at least `n` unread bytes remain before reading a fixed-width
/// field.
fn ByteReader::ensure(self : ByteReader, n : Int) -> Unit raise ProtocolError {
  if self.remaining() < n {
    raise ProtocolError::UnexpectedEof("unexpected EOF")
  }
}

///|
/// Read the next byte.
pub fn ByteReader::read_u8(self : ByteReader) -> Byte raise ProtocolError {
  self.ensure(1)
  let b = self.buf[self.idx]
  self.idx = self.idx + 1
  b
}

///|
/// Read the next big-endian unsigned 16-bit integer.
pub fn ByteReader::read_u16_be(self : ByteReader) -> UInt16 raise ProtocolError {
  self.ensure(2)
  let b0 = self.buf[self.idx].to_uint16()
  let b1 = self.buf[self.idx + 1].to_uint16()
  self.idx = self.idx + 2
  (b0 << 8) | b1
}

///|
/// Read the next big-endian signed 16-bit integer.
pub fn ByteReader::read_i16_be(self : ByteReader) -> Int raise ProtocolError {
  let u = self.read_u16_be()
  let v = Int16::reinterpret_from_uint16(u)
  v.to_int()
}

///|
/// Read the next big-endian unsigned 32-bit integer.
pub fn ByteReader::read_u32_be(self : ByteReader) -> UInt raise ProtocolError {
  self.ensure(4)
  let b0 = self.buf[self.idx].to_uint()
  let b1 = self.buf[self.idx + 1].to_uint()
  let b2 = self.buf[self.idx + 2].to_uint()
  let b3 = self.buf[self.idx + 3].to_uint()
  self.idx = self.idx + 4
  (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

///|
/// Read the next big-endian signed 32-bit integer.
pub fn ByteReader::read_i32_be(self : ByteReader) -> Int raise ProtocolError {
  let u = self.read_u32_be()
  i32_from_u32(u)
}

///|
/// Read the next big-endian unsigned 64-bit integer.
pub fn ByteReader::read_u64_be(self : ByteReader) -> UInt64 raise ProtocolError {
  self.ensure(8)
  let b0 = self.buf[self.idx].to_uint64()
  let b1 = self.buf[self.idx + 1].to_uint64()
  let b2 = self.buf[self.idx + 2].to_uint64()
  let b3 = self.buf[self.idx + 3].to_uint64()
  let b4 = self.buf[self.idx + 4].to_uint64()
  let b5 = self.buf[self.idx + 5].to_uint64()
  let b6 = self.buf[self.idx + 6].to_uint64()
  let b7 = self.buf[self.idx + 7].to_uint64()
  self.idx = self.idx + 8
  (b0 << 56) |
  (b1 << 48) |
  (b2 << 40) |
  (b3 << 32) |
  (b4 << 24) |
  (b5 << 16) |
  (b6 << 8) |
  b7
}

///|
/// Read the next big-endian signed 64-bit integer.
pub fn ByteReader::read_i64_be(self : ByteReader) -> Int64 raise ProtocolError {
  let u = self.read_u64_be()
  u.reinterpret_as_int64()
}

///|
/// Read the next big-endian IEEE-754 `Float`.
pub fn ByteReader::read_f32_be(self : ByteReader) -> Float raise ProtocolError {
  let u = self.read_u32_be()
  Float::reinterpret_from_uint(u)
}

///|
/// Read the next big-endian IEEE-754 `Double`.
pub fn ByteReader::read_f64_be(self : ByteReader) -> Double raise ProtocolError {
  let u = self.read_u64_be()
  u.reinterpret_as_double()
}

///|
/// Read the next `len` bytes from a preceding `Byte n` or length-prefixed
/// field.
pub fn ByteReader::read_bytes(
  self : ByteReader,
  len : Int,
) -> BytesView raise ProtocolError {
  if len < 0 {
    raise ProtocolError::InvalidInput("invalid length")
  }
  self.ensure(len)
  let start = self.idx
  let end = self.idx + len
  self.idx = end
  self.buf[start:end]
}

///|
/// Consume and return all remaining bytes.
///
/// Many message formats end with `Byte n`, where `n` is implied by the overall
/// message length. This helper returns that trailing payload.
pub fn ByteReader::read_all(self : ByteReader) -> BytesView {
  let start = self.idx
  self.idx = self.buf.length()
  self.buf[start:]
}

///|
/// Find the next NUL terminator used by a protocol `String`.
fn find_null(buf : BytesView, start : Int) -> Int raise ProtocolError {
  let mut i = start
  while i < buf.length() {
    if buf[i] == 0 {
      return i
    }
    i = i + 1
  }
  raise ProtocolError::UnexpectedEof("unexpected EOF")
}

///|
/// Read a protocol `String`.
///
/// PostgreSQL protocol strings are C-style NUL-terminated byte sequences with
/// no separate length prefix.
pub fn ByteReader::read_cstr(self : ByteReader) -> Bytes raise ProtocolError {
  let end = find_null(self.buf, self.idx)
  let slice = self.buf[self.idx:end]
  self.idx = end + 1
  Bytes::from_iter(slice.iter())
}
