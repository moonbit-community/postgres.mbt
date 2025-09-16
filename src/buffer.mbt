///|
/// Buffer reader for parsing PostgreSQL messages
pub(all) struct MessageReader {
  data : Bytes
  mut position : Int
} derive(Show)

///|
pub fn MessageReader::new(data : Bytes) -> MessageReader {
  { data, position: 0 }
}

///|
pub fn MessageReader::remaining(self : MessageReader) -> Int {
  self.data.length() - self.position
}

///|
pub fn MessageReader::is_empty(self : MessageReader) -> Bool {
  self.position >= self.data.length()
}

///|
pub fn MessageReader::read_byte(
  self : MessageReader,
) -> Byte raise ProtocolError {
  if self.position >= self.data.length() {
    raise ProtocolError::InvalidMessage("Buffer underflow reading byte")
  }
  let byte = self.data[self.position]
  self.position += 1
  byte
}

///|
pub fn MessageReader::read_char(
  self : MessageReader,
) -> Char raise ProtocolError {
  self.read_byte().to_int().to_char()
}

///|
pub fn MessageReader::read_int16(
  self : MessageReader,
) -> Int raise ProtocolError {
  if self.remaining() < 2 {
    raise ProtocolError::InvalidMessage("Buffer underflow reading int16")
  }
  let b1 = self.read_byte().to_int()
  let b2 = self.read_byte().to_int()
  (b1 << 8) | b2
}

///|
pub fn MessageReader::read_int32(
  self : MessageReader,
) -> Int raise ProtocolError {
  if self.remaining() < 4 {
    raise ProtocolError::InvalidMessage("Buffer underflow reading int32")
  }
  let b1 = self.read_byte().to_int()
  let b2 = self.read_byte().to_int()
  let b3 = self.read_byte().to_int()
  let b4 = self.read_byte().to_int()
  (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
}

///|
pub fn MessageReader::read_cstring(
  self : MessageReader,
) -> String raise ProtocolError {
  let start = self.position
  while self.position < self.data.length() && self.data[self.position] != 0 {
    self.position += 1
  }
  if self.position >= self.data.length() {
    raise ProtocolError::InvalidMessage("Unterminated C string")
  }
  let result = @encoding.decode(self.data[start:self.position], encoding=UTF8)
  self.position += 1 // Skip null terminator
  match result {
    Ok(s) => s
    Err(_) => raise ProtocolError::EncodingError("Invalid UTF-8 in C string")
  }
}

///|
pub fn MessageReader::read_bytes(
  self : MessageReader,
  length : Int,
) -> Bytes raise ProtocolError {
  if self.remaining() < length {
    raise ProtocolError::InvalidMessage("Buffer underflow reading bytes")
  }
  let result = self.data[self.position:self.position + length].to_bytes()
  self.position += length
  result
}

///|
pub fn MessageReader::read_string(
  self : MessageReader,
  length : Int,
) -> String raise ProtocolError {
  let bytes = self.read_bytes(length)
  match @encoding.decode(bytes, encoding=UTF8) {
    Ok(s) => s
    Err(_) => raise ProtocolError::EncodingError("Invalid UTF-8 in string")
  }
}

///|
/// Buffer writer for building PostgreSQL messages
pub(all) struct MessageWriter {
  mut data : Array[Byte]
} derive(Show)

///|
pub fn MessageWriter::new() -> MessageWriter {
  { data: [] }
}

///|
pub fn MessageWriter::to_bytes(self : MessageWriter) -> Bytes {
  self.data[:].to_bytes()
}

///|
pub fn MessageWriter::write_byte(self : MessageWriter, byte : Byte) -> Unit {
  self.data.push(byte)
}

///|
pub fn MessageWriter::write_char(self : MessageWriter, c : Char) -> Unit {
  self.write_byte(c.to_int().to_byte())
}

///|
pub fn MessageWriter::write_int16(self : MessageWriter, value : Int) -> Unit {
  self.write_byte(((value >> 8) & 0xFF).to_byte())
  self.write_byte((value & 0xFF).to_byte())
}

///|
pub fn MessageWriter::write_int32(self : MessageWriter, value : Int) -> Unit {
  self.write_byte(((value >> 24) & 0xFF).to_byte())
  self.write_byte(((value >> 16) & 0xFF).to_byte())
  self.write_byte(((value >> 8) & 0xFF).to_byte())
  self.write_byte((value & 0xFF).to_byte())
}

///|
pub fn MessageWriter::write_cstring(self : MessageWriter, s : String) -> Unit {
  let bytes = @encoding.encode(s, encoding=UTF8)
  for i = 0; i < bytes.length(); i = i + 1 {
    self.write_byte(bytes[i])
  }
  self.write_byte(0) // Null terminator
}

///|
pub fn MessageWriter::write_bytes(self : MessageWriter, bytes : Bytes) -> Unit {
  for i = 0; i < bytes.length(); i = i + 1 {
    self.write_byte(bytes[i])
  }
}

///|
pub fn MessageWriter::write_string(self : MessageWriter, s : String) -> Unit {
  let bytes = @encoding.encode(s, encoding=UTF8)
  self.write_bytes(bytes)
}
