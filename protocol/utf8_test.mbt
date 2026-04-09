///|
fn bytes_of(bytes : ArrayView[Byte]) -> Bytes {
  Bytes::from_array(bytes)
}

///|
fn expect_invalid_utf8(bytes : Bytes) -> Unit raise {
  let result = try? @protocol.validate_utf8(bytes[:])
  guard result is Err(@protocol.ProtocolError::InvalidInput(message)) else {
    fail("expected invalid UTF-8 error")
  }
  assert_eq(message, "invalid UTF-8")
}

///|
fn expect_valid_utf8(bytes : Bytes) -> Unit raise {
  ignore(@protocol.validate_utf8(bytes[:]))
}

///|
test "protocol.validate_utf8 accepts well-formed UTF-8" {
  let valid : Array[Bytes] = [
    b"", b"Postgres", b"Português", b"数据库", b"감사합니다", b"こんにちは世界",
    b"Привет, мир", b"γειά σου κόσμε", b"مرحبا بالعالم",
    b"שלום עולם", b"नमस्ते दुनिया", b"สวัสดีชาวโลก",
    b"வணக்கம் உலகம்", b"გამარჯობა მსოფლიო",
    b"ሰላም ዓለም", b"𐍈", b"✂️📋", b"Ω≈ç√∫˜µ≤≥÷",
    b"⌘⇧⌥⎋", b"┌─┬─┐", b"♻︎⚗︎∞", b"1️⃣2️⃣3️⃣",
    b"🙂🚀", b"🧑🏽‍💻", b"🏳️‍🌈", b"👨‍👩‍👧‍👦",
  ]
  for bytes in valid {
    expect_valid_utf8(bytes)
  }
}

///|
test "protocol.validate_utf8 accepts scalar boundary sequences" {
  let valid : Array[Bytes] = [
    bytes_of([b'\x00']),
    bytes_of([b'\x7F']),
    bytes_of([b'\xC2', b'\x80']),
    bytes_of([b'\xDF', b'\xBF']),
    bytes_of([b'\xE0', b'\xA0', b'\x80']),
    bytes_of([b'\xEC', b'\xBF', b'\xBF']),
    bytes_of([b'\xED', b'\x9F', b'\xBF']),
    bytes_of([b'\xEE', b'\x80', b'\x80']),
    bytes_of([b'\xEF', b'\xBF', b'\xBF']),
    bytes_of([b'\xF0', b'\x90', b'\x80', b'\x80']),
    bytes_of([b'\xF3', b'\xBF', b'\xBF', b'\xBF']),
    bytes_of([b'\xF4', b'\x8F', b'\xBF', b'\xBF']),
    bytes_of([
      b'A', b'\xC2', b'\x80', b'\xE0', b'\xA0', b'\x80', b'\xF4', b'\x8F', b'\xBF',
      b'\xBF', b'Z',
    ]),
  ]
  for bytes in valid {
    expect_valid_utf8(bytes)
  }
}

///|
test "protocol.validate_utf8 rejects malformed UTF-8" {
  let invalid : Array[Bytes] = [
    bytes_of([b'\x80']),
    bytes_of([b'\xC0', b'\x80']),
    bytes_of([b'\xC1', b'\xBF']),
    bytes_of([b'\xC2']),
    bytes_of([b'\xC2', b'\x7F']),
    bytes_of([b'\xE0', b'\x80', b'\x80']),
    bytes_of([b'\xE0', b'\x9F', b'\xBF']),
    bytes_of([b'\xE2', b'\x82']),
    bytes_of([b'\xE2', b'\x28', b'\xA1']),
    bytes_of([b'\xED', b'\xA0', b'\x80']),
    bytes_of([b'\xF0', b'\x80', b'\x80', b'\x80']),
    bytes_of([b'\xF0', b'\x90', b'\x80']),
    bytes_of([b'\xF4', b'\x90', b'\x80', b'\x80']),
    bytes_of([b'\xF5', b'\x80', b'\x80', b'\x80']),
  ]
  for bytes in invalid {
    expect_invalid_utf8(bytes)
  }
}

///|
test "protocol.validate_utf8 rejects boundary violations and invalid continuations" {
  let invalid : Array[Bytes] = [
    bytes_of([b'\xDF', b'\x7F']),
    bytes_of([b'\xE0', b'\x9F', b'\x80']),
    bytes_of([b'\xE0', b'\xA0', b'\x7F']),
    bytes_of([b'\xED', b'\xA0', b'\x80']),
    bytes_of([b'\xEE', b'\x80', b'\x41']),
    bytes_of([b'\xF0', b'\x8F', b'\xBF', b'\xBF']),
    bytes_of([b'\xF0', b'\x90', b'\x80', b'\x41']),
    bytes_of([b'\xF4', b'\x90', b'\x80', b'\x80']),
    bytes_of([b'\xF4', b'\x8F', b'\xBF', b'\x41']),
    bytes_of([b'\xF8', b'\x80', b'\x80', b'\x80', b'\x80']),
    bytes_of([b'\xFF']),
    bytes_of([b'A', b'\x80']),
    bytes_of([b'\xE2', b'\x82', b'\xAC', b'\x80']),
  ]
  for bytes in invalid {
    expect_invalid_utf8(bytes)
  }
}

///|
test "protocol.validate_utf8 rejects truncated multi-byte sequences" {
  let invalid : Array[Bytes] = [
    bytes_of([b'\xC2']),
    bytes_of([b'\xDF']),
    bytes_of([b'\xE0']),
    bytes_of([b'\xE0', b'\xA0']),
    bytes_of([b'\xEF', b'\xBF']),
    bytes_of([b'\xF0']),
    bytes_of([b'\xF0', b'\x90']),
    bytes_of([b'\xF0', b'\x90', b'\x80']),
    bytes_of([b'\xF4', b'\x8F', b'\xBF']),
    bytes_of([b'A', b'\xF0', b'\x90', b'\x80']),
  ]
  for bytes in invalid {
    expect_invalid_utf8(bytes)
  }
}
