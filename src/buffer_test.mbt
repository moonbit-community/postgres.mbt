//|

///|
test "MessageReader basic operations" {
  let data = b"Hello\x00World\x01\x02\x03\x04"
  let reader = @postgres.MessageReader::new(data)

  // Test remaining and is_empty
  inspect(reader.remaining(), content="14")
  inspect(reader.is_empty(), content="false")

  // Test read_byte
  let byte1 = reader.read_byte()
  inspect(byte1, content="72") // 'H'
  inspect(reader.remaining(), content="13")

  // Test read_char
  let char1 = reader.read_char()
  inspect(char1, content="e")

  // Test read_cstring
  reader.position = 0 // Reset position
  let cstr = reader.read_cstring()
  inspect(cstr, content="Hello")

  // Test read_int32
  reader.position = 10 // Position after "World\x00"
  let int_val = reader.read_int32()
  inspect(int_val, content="16909060") // 0x01020304 in big-endian
}

///|
test "MessageWriter basic operations" {
  let writer = @postgres.MessageWriter::new()

  // Test write_byte and write_char
  writer.write_byte(b'H')
  writer.write_char('i')

  // Test write_int16 and write_int32
  writer.write_int16(0x1234)
  writer.write_int32(0x12345678)

  // Test write_cstring
  writer.write_cstring("test")
  let result = writer.to_bytes()
  inspect(result.length(), content="11")

  // Verify the written data
  inspect(result[0], content="72") // 'H'
  inspect(result[1], content="105") // 'i'
  inspect(result[2], content="18") // 0x12
  inspect(result[3], content="52") // 0x34
  inspect(result[4], content="18") // 0x12 (from int32)
}

///|
test "MessageReader error handling" {
  let data = b"ab"
  let reader = @postgres.MessageReader::new(data)

  // Read all bytes
  reader.read_byte()
  reader.read_byte()

  // Try to read beyond buffer
  inspect(
    try? reader.read_byte(),
    content=(
      #|Err(InvalidMessage("Buffer underflow reading byte"))
    ),
  )
}

///|
test "MessageReader read_bytes and read_string" {
  let data = b"Hello\x00World"
  let reader = @postgres.MessageReader::new(data)

  // Test read_bytes
  let bytes = reader.read_bytes(5)
  inspect(@encoding.decode(bytes, encoding=UTF8), content="Ok(\"Hello\")")

  // Skip null byte
  reader.read_byte()

  // Test read_string
  let str = reader.read_string(5)
  inspect(str, content="World")
}
