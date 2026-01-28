///|
/// Escape a literal and surround result with single quotes.
pub fn escape_literal(input : BytesView) -> Bytes raise @proto.ProtocolError {
  @proto.validate_utf8(input)
  escape_internal(input, false)
}

///|
/// Escape an identifier and surround result with double quotes.
pub fn escape_identifier(input : BytesView) -> Bytes raise @proto.ProtocolError {
  @proto.validate_utf8(input)
  escape_internal(input, true)
}

///|
fn escape_internal(input : BytesView, as_ident : Bool) -> Bytes {
  let quote_char = if as_ident { b'"' } else { b'\'' }
  let mut num_backslashes = 0
  let mut num_quotes = 0
  for b in input {
    if b == quote_char {
      num_quotes = num_quotes + 1
    } else if b == b'\\' {
      num_backslashes = num_backslashes + 1
    }
  }
  let mut result_size = input.length() + num_quotes + 2
  if not(as_ident) && num_backslashes > 0 {
    result_size = result_size + num_backslashes + 2
  }
  let out = @buffer.new(size_hint=result_size)
  if not(as_ident) && num_backslashes > 0 {
    out.write_bytesview(b" "[:])
    out.write_bytesview(b"E"[:])
  }
  out.write_byte(quote_char)
  if num_quotes == 0 && (num_backslashes == 0 || as_ident) {
    out.write_bytesview(input)
  } else {
    for b in input {
      if b == quote_char || (not(as_ident) && b == b'\\') {
        out.write_byte(b)
      }
      out.write_byte(b)
    }
  }
  out.write_byte(quote_char)
  out.to_bytes()
}
