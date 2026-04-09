///|
/// Helpers for PostgreSQL's repeated `Int32 length + payload` layout.
///
/// Primary reference:
/// - https://www.postgresql.org/docs/current/protocol-message-formats.html
/// Write one nullable `Int32 + Byte n` field.
///
/// This is the value layout used by `Bind` parameters, `DataRow` columns, and
/// several composite binary payloads. The serializer writes only the payload
/// bytes; this helper prepends the length word and emits `-1` for NULL.
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
