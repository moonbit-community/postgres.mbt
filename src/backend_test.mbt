///|
test "parse AuthenticationOk message" {
  let data = b"\x00\x00\x00\x00" // Auth type 0
  let msg = @postgres.BackendMessage::parse('R', data)
  inspect(msg, content="AuthenticationOk")
}

///|
test "parse AuthenticationMD5Password message" {
  let data = b"\x00\x00\x00\x05\x01\x02\x03\x04" // Auth type 5 + 4-byte salt
  let msg = @postgres.BackendMessage::parse('R', data)
  inspect(msg, content="AuthenticationMD5Password([1, 2, 3, 4])")
}

///|
test "parse ParameterStatus message" {
  let writer = @postgres.MessageWriter::new()
  writer.write_cstring("server_version")
  writer.write_cstring("13.3")
  let data = writer.to_bytes()
  let msg = @postgres.BackendMessage::parse('S', data)
  inspect(msg, content="ParameterStatus(\"server_version\", \"13.3\")")
}

///|
test "parse ReadyForQuery message" {
  let data = b"I" // Idle status
  let msg = @postgres.BackendMessage::parse('Z', data)
  inspect(msg, content="ReadyForQuery(Idle)")
  let data2 = b"T" // In transaction
  let msg2 = @postgres.BackendMessage::parse('Z', data2)
  inspect(msg2, content="ReadyForQuery(InTransaction)")
}

///|
test "parse CommandComplete message" {
  let writer = @postgres.MessageWriter::new()
  writer.write_cstring("SELECT 5")
  let data = writer.to_bytes()
  let msg = @postgres.BackendMessage::parse('C', data)
  inspect(msg, content="CommandComplete(\"SELECT 5\")")
}

///|
test "parse DataRow message" {
  let writer = @postgres.MessageWriter::new()
  writer.write_int16(2) // 2 columns
  writer.write_int32(5) // First column length
  writer.write_string("hello") // First column data
  writer.write_int32(-1) // Second column is NULL
  let data = writer.to_bytes()
  let msg = @postgres.BackendMessage::parse('D', data)
  match msg {
    DataRow(values) => {
      inspect(values.length(), content="2")
      inspect(values[0] is Some(_), content="true")
      inspect(values[1] is None, content="true")
    }
    _ => panic("Expected DataRow message")
  }
}

///|
test "parse RowDescription message" {
  let writer = @postgres.MessageWriter::new()
  writer.write_int16(1) // 1 column
  writer.write_cstring("id") // Column name
  writer.write_int32(0) // Table OID
  writer.write_int32(1) // Column attribute number
  writer.write_int32(23) // Data type OID (INT4)
  writer.write_int16(4) // Data type size
  writer.write_int32(-1) // Type modifier
  writer.write_int16(0) // Format code (text)
  let data = writer.to_bytes()
  let msg = @postgres.BackendMessage::parse('T', data)
  match msg {
    RowDescription(columns) => {
      inspect(columns.length(), content="1")
      inspect(columns[0].name, content="id")
      inspect(columns[0].data_type_oid, content="23")
    }
    _ => panic("Expected RowDescription message")
  }
}

///|
test "parse ErrorResponse message" {
  let writer = @postgres.MessageWriter::new()
  writer.write_char('S') // Severity
  writer.write_cstring("ERROR")
  writer.write_char('C') // Code
  writer.write_cstring("42P01")
  writer.write_char('M') // Message
  writer.write_cstring("relation \"nonexistent\" does not exist")
  writer.write_byte(0) // End of fields
  let data = writer.to_bytes()
  let msg = @postgres.BackendMessage::parse('E', data)
  match msg {
    ErrorResponse(fields) => {
      inspect(fields.get(Severity), content="Some(\"ERROR\")")
      inspect(fields.get(Code), content="Some(\"42P01\")")
    }
    _ => panic("Expected ErrorResponse message")
  }
}

///|
test "parse BackendKeyData message" {
  let writer = @postgres.MessageWriter::new()
  writer.write_int32(12345) // Process ID
  writer.write_int32(67890) // Secret key
  let data = writer.to_bytes()
  let msg = @postgres.BackendMessage::parse('K', data)
  match msg {
    BackendKeyData(key_data) => {
      inspect(key_data.process_id, content="12345")
      inspect(key_data.secret_key, content="67890")
    }
    _ => panic("Expected BackendKeyData message")
  }
}

///|
test "parse simple completion messages" {
  inspect(@postgres.BackendMessage::parse('1', b""), content="ParseComplete")
  inspect(@postgres.BackendMessage::parse('2', b""), content="BindComplete")
  inspect(@postgres.BackendMessage::parse('3', b""), content="CloseComplete")
  inspect(
    @postgres.BackendMessage::parse('I', b""),
    content="EmptyQueryResponse",
  )
  inspect(@postgres.BackendMessage::parse('n', b""), content="NoData")
  inspect(@postgres.BackendMessage::parse('s', b""), content="PortalSuspended")
  inspect(@postgres.BackendMessage::parse('c', b""), content="CopyDone")
}

///|
test "parse unknown message type" {
  let msg = @postgres.BackendMessage::parse('X', b"test")
  match msg {
    UnknownMessage(typ, data) => {
      inspect(typ, content="X")
      inspect(data, content="[116, 101, 115, 116]")
    }
    _ => panic("Expected UnknownMessage")
  }
}
