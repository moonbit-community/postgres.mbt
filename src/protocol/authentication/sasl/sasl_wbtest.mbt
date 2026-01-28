///|
test "parse_server_first_message" {
  let message = b"r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096"
  let parsed = Parser::new(message).server_first_message()
  assert_eq(parsed.nonce, b"fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j")
  assert_eq(parsed.salt, b"QSXCR+Q6sek8bf92")
  assert_eq(parsed.iteration_count, 4096)
}
