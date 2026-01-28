///|
test "escape_identifier" {
  assert_eq(try! escape_identifier(b"foo"), b"\"foo\"")
  assert_eq(try! escape_identifier(b"f\\oo"), b"\"f\\oo\"")
  assert_eq(try! escape_identifier(b"f'oo"), b"\"f'oo\"")
  assert_eq(try! escape_identifier(b"f\"oo"), b"\"f\"\"oo\"")
}

///|
test "escape_literal" {
  assert_eq(try! escape_literal(b"foo"), b"'foo'")
  assert_eq(try! escape_literal(b"f\\oo"), b" E'f\\\\oo'")
  assert_eq(try! escape_literal(b"f'oo"), b"'f''oo'")
  assert_eq(try! escape_literal(b"f\"oo"), b"'f\"oo'")
}
