///|
/// Write a length-prefixed nullable value.
pub fn write_nullable(
  serializer : (@buffer.Buffer) -> IsNull raise ProtocolError,
  buf : @buffer.Buffer,
) -> Unit raise ProtocolError {
  let payload = @buffer.new()
  let is_null = serializer(payload)
  let size = match is_null {
    IsNull::No => i32_from_usize(payload.length())
    IsNull::Yes => -1
  }
  buf.write_int_be(size)
  if is_null is IsNull::No {
    buf.write_bytes(payload.to_bytes())
  }
}
