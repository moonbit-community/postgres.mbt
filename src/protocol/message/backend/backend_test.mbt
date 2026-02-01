///|
fn write_cstr(buf : @buffer.Buffer, s : BytesView) -> Unit {
  buf.write_bytesview(s)
  buf.write_byte(b'\x00')
}

///|
fn build_message(tag : Byte, payload : BytesView) -> Bytes {
  let buf = @buffer.new()
  buf.write_byte(tag)
  buf.write_int_be(payload.length() + 4)
  buf.write_bytesview(payload)
  buf.to_bytes()
}

///|
fn parse_message(bytes : BytesView) -> Message raise @proto.ProtocolError {
  match Message::parse(bytes) {
    Some(parsed) => parsed.message()
    None => raise @proto.ProtocolError::UnexpectedEof("incomplete message")
  }
}

///|
test "utf8_accessors" {
  let cmd_payload = @buffer.new()
  write_cstr(cmd_payload, b"SELECT 1")
  let cmd_msg = build_message(COMMAND_COMPLETE_TAG, cmd_payload.to_bytes()[:])
  match (try! parse_message(cmd_msg[:])) {
    CommandComplete(body) => assert_eq(try! body.tag_str(), "SELECT 1")
    _ => fail("unexpected message")
  }
  let notify_payload = @buffer.new()
  notify_payload.write_int_be(42)
  write_cstr(notify_payload, b"chan")
  write_cstr(notify_payload, b"msg")
  let notify_msg = build_message(
    NOTIFICATION_RESPONSE_TAG,
    notify_payload.to_bytes()[:],
  )
  match (try! parse_message(notify_msg[:])) {
    NotificationResponse(body) => {
      assert_eq(try! body.channel_str(), "chan")
      assert_eq(try! body.message_str(), "msg")
    }
    _ => fail("unexpected message")
  }
  let status_payload = @buffer.new()
  write_cstr(status_payload, b"server_version")
  write_cstr(status_payload, b"15")
  let status_msg = build_message(
    PARAMETER_STATUS_TAG,
    status_payload.to_bytes()[:],
  )
  match (try! parse_message(status_msg[:])) {
    ParameterStatus(body) => {
      assert_eq(try! body.name_str(), "server_version")
      assert_eq(try! body.value_str(), "15")
    }
    _ => fail("unexpected message")
  }
  let fields_payload = @buffer.new()
  fields_payload.write_uint16_be((1).to_uint16())
  write_cstr(fields_payload, b"col")
  fields_payload.write_uint_be(0U)
  fields_payload.write_int16_be(@proto.checked_i16(0))
  fields_payload.write_uint_be(0U)
  fields_payload.write_int16_be(@proto.checked_i16(0))
  fields_payload.write_int_be(0)
  fields_payload.write_int16_be(@proto.checked_i16(0))
  let fields_msg = build_message(
    ROW_DESCRIPTION_TAG,
    fields_payload.to_bytes()[:],
  )
  match (try! parse_message(fields_msg[:])) {
    RowDescription(body) => {
      let iter = body.fields()
      match (try! iter.next()) {
        Some(field) => assert_eq(try! field.name_str(), "col")
        None => fail("missing field")
      }
    }
    _ => fail("unexpected message")
  }
}

///|
test "utf8_accessors_invalid" {
  let payload = @buffer.new()
  payload.write_int_be(1)
  write_cstr(payload, b"\xff")
  write_cstr(payload, b"ok")
  let msg = build_message(NOTIFICATION_RESPONSE_TAG, payload.to_bytes()[:])
  match (try! parse_message(msg[:])) {
    NotificationResponse(body) =>
      assert_true((try? body.channel_str()) is Err(_))
    _ => fail("unexpected message")
  }
}

///|
test "sasl_mechanisms_str" {
  let payload = @buffer.new()
  payload.write_int_be(10)
  payload.write_bytesview(b"SCRAM-SHA-256\x00SCRAM-SHA-256-PLUS\x00\x00"[:])
  let msg = build_message(AUTHENTICATION_TAG, payload.to_bytes()[:])
  match (try! parse_message(msg[:])) {
    AuthenticationSasl(body) => {
      let mechs = body.mechanisms()
      assert_eq(try! mechs.next_str(), Some("SCRAM-SHA-256"))
      assert_eq(try! mechs.next_str(), Some("SCRAM-SHA-256-PLUS"))
      assert_eq(try! mechs.next_str(), None)
    }
    _ => fail("unexpected message")
  }
}
