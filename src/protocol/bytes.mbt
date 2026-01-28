///|
/// Convert a length to an i16 with overflow checks.
pub fn i16_from_usize(len : Int) -> Int16 raise ProtocolError {
  if len < 0 || len > 0x7fff {
    raise ProtocolError::Overflow("value too large to transmit")
  }
  Int16::from_int(len)
}

///|
/// Convert a length to an i32 with overflow checks.
pub fn i32_from_usize(len : Int) -> Int raise ProtocolError {
  if len < 0 || len > 0x7fff_ffff {
    raise ProtocolError::Overflow("value too large to transmit")
  }
  len
}

///|
/// Ensure value fits in signed i32.
pub fn checked_i32(value : Int) -> Int raise ProtocolError {
  if value < -0x8000_0000 || value > 0x7fff_ffff {
    raise ProtocolError::Overflow("value out of range for i32")
  }
  value
}

///|
/// Ensure value fits in signed i16.
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
/// A byte reader for protocol parsing.
pub struct ByteReader {
  buf : BytesView
  mut idx : Int
}

///|
pub fn ByteReader::new(buf : BytesView) -> ByteReader {
  { buf, idx: 0 }
}

///|
pub fn ByteReader::remaining(self : ByteReader) -> Int {
  self.buf.length() - self.idx
}

///|
pub fn ByteReader::is_empty(self : ByteReader) -> Bool {
  self.remaining() <= 0
}

///|
fn ByteReader::ensure(self : ByteReader, n : Int) -> Unit raise ProtocolError {
  if self.remaining() < n {
    raise ProtocolError::UnexpectedEof("unexpected EOF")
  }
}

///|
pub fn ByteReader::read_u8(self : ByteReader) -> Byte raise ProtocolError {
  self.ensure(1)
  let b = self.buf[self.idx]
  self.idx = self.idx + 1
  b
}

///|
pub fn ByteReader::read_u16_be(self : ByteReader) -> UInt16 raise ProtocolError {
  self.ensure(2)
  let b0 = self.buf[self.idx].to_uint16()
  let b1 = self.buf[self.idx + 1].to_uint16()
  self.idx = self.idx + 2
  (b0 << 8) | b1
}

///|
pub fn ByteReader::read_i16_be(self : ByteReader) -> Int raise ProtocolError {
  let u = self.read_u16_be()
  let v = Int16::reinterpret_from_uint16(u)
  v.to_int()
}

///|
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
pub fn ByteReader::read_i32_be(self : ByteReader) -> Int raise ProtocolError {
  let u = self.read_u32_be()
  i32_from_u32(u)
}

///|
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
pub fn ByteReader::read_i64_be(self : ByteReader) -> Int64 raise ProtocolError {
  let u = self.read_u64_be()
  u.reinterpret_as_int64()
}

///|
pub fn ByteReader::read_f32_be(self : ByteReader) -> Float raise ProtocolError {
  let u = self.read_u32_be()
  Float::reinterpret_from_uint(u)
}

///|
pub fn ByteReader::read_f64_be(self : ByteReader) -> Double raise ProtocolError {
  let u = self.read_u64_be()
  u.reinterpret_as_double()
}

///|
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
pub fn ByteReader::read_all(self : ByteReader) -> BytesView {
  let start = self.idx
  self.idx = self.buf.length()
  self.buf[start:]
}

///|
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
/// Read a NULL-terminated byte string.
pub fn ByteReader::read_cstr(self : ByteReader) -> Bytes raise ProtocolError {
  let end = find_null(self.buf, self.idx)
  let slice = self.buf[self.idx:end]
  self.idx = end + 1
  Bytes::from_iter(slice.iter())
}
