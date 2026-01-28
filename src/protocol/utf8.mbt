///|
/// Validate that bytes are valid UTF-8.
pub fn validate_utf8(bytes : BytesView) -> Unit raise ProtocolError {
  ignore(@utf8.decode(bytes)) catch {
    _ => raise ProtocolError::InvalidInput("invalid UTF-8")
  }
}

///|
/// Encode a String (UTF-16) as UTF-8 bytes.
pub fn utf8_encode(s : String) -> Bytes {
  @utf8.encode(s)
}
