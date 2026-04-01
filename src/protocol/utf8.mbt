///|
fn[T] invalid_utf8() -> T raise ProtocolError {
  raise ProtocolError::InvalidInput("invalid UTF-8")
}

///|
fn byte_in_range(b : Byte, lower : Int, upper : Int) -> Bool {
  let value = b.to_int()
  value >= lower && value <= upper
}

///|
fn is_continuation_byte(b : Byte) -> Bool {
  byte_in_range(b, 0x80, 0xBF)
}

///|
fn consume_two_byte_scalar(bytes : BytesView) -> BytesView raise ProtocolError {
  match bytes {
    [_, b1, .. tail] =>
      if is_continuation_byte(b1) {
        tail
      } else {
        invalid_utf8()
      }
    _ => invalid_utf8()
  }
}

///|
fn consume_three_byte_scalar(
  bytes : BytesView,
  second_lower : Int,
  second_upper : Int,
) -> BytesView raise ProtocolError {
  match bytes {
    [_, b1, b2, .. tail] =>
      if byte_in_range(b1, second_lower, second_upper) &&
        is_continuation_byte(b2) {
        tail
      } else {
        invalid_utf8()
      }
    _ => invalid_utf8()
  }
}

///|
fn consume_four_byte_scalar(
  bytes : BytesView,
  second_lower : Int,
  second_upper : Int,
) -> BytesView raise ProtocolError {
  match bytes {
    [_, b1, b2, b3, .. tail] =>
      if byte_in_range(b1, second_lower, second_upper) &&
        is_continuation_byte(b2) &&
        is_continuation_byte(b3) {
        tail
      } else {
        invalid_utf8()
      }
    _ => invalid_utf8()
  }
}

///|
fn consume_utf8_scalar(bytes : BytesView) -> BytesView raise ProtocolError {
  match bytes {
    [b0, .. tail] => {
      let lead = b0.to_int()
      if lead <= 0x7F {
        tail
      } else if lead <= 0xC1 {
        invalid_utf8()
      } else if lead <= 0xDF {
        consume_two_byte_scalar(bytes)
      } else if lead == 0xE0 {
        consume_three_byte_scalar(bytes, 0xA0, 0xBF)
      } else if lead == 0xED {
        consume_three_byte_scalar(bytes, 0x80, 0x9F)
      } else if lead <= 0xEF {
        consume_three_byte_scalar(bytes, 0x80, 0xBF)
      } else if lead == 0xF0 {
        consume_four_byte_scalar(bytes, 0x90, 0xBF)
      } else if lead <= 0xF3 {
        consume_four_byte_scalar(bytes, 0x80, 0xBF)
      } else if lead == 0xF4 {
        consume_four_byte_scalar(bytes, 0x80, 0x8F)
      } else {
        invalid_utf8()
      }
    }
    [] => bytes
  }
}

///|
/// Validate that bytes are valid UTF-8.
pub fn validate_utf8(bytes : BytesView) -> Unit raise ProtocolError {
  let mut rest = bytes
  while !rest.is_empty() {
    rest = consume_utf8_scalar(rest)
  }
}

///|
/// Encode a String (UTF-16) as UTF-8 bytes.
pub fn utf8_encode(s : String) -> Bytes {
  @utf8.encode(s)
}
