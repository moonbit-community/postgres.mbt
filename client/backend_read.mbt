// Shared framing boundary for startup and the established connection driver.

///|
/// Validate the header before reading or allocating any body bytes. The budget
/// covers one frame, not the accumulated results of a request or connection.
async fn read_backend_message(
  stream : Stream,
  max_body_bytes : Int32,
) -> @backend.Message {
  try {
    let prefix = stream.read_exactly(5)
    guard @backend.Header::parse(prefix[:]) is Some(header) else {
      raise ClientError::Protocol("incomplete backend header")
    }
    if header.len > 2_147_483_646 {
      raise ClientError::Protocol("backend message total length overflow")
    }
    let body_len = header.len - 4
    if body_len > max_body_bytes {
      raise ClientError::Protocol(
        "backend message body exceeds max_backend_message_body_bytes",
      )
    }
    let body = stream.read_exactly(body_len)
    let packet = Buffer(size_hint=body_len + 5)
    packet.write_bytes(prefix)
    packet.write_bytes(body)
    guard @backend.Message::parse(packet.to_bytes()[:]) is Some(parsed) else {
      raise ClientError::Protocol("incomplete backend message")
    }
    parsed.message
  } catch {
    @proto.ProtocolError::InvalidInput(message)
    | @proto.ProtocolError::UnexpectedEof(message)
    | @proto.ProtocolError::Overflow(message) =>
      raise ClientError::Protocol(message)
    error => raise error
  }
}
