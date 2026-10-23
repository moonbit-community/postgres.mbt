///|
test "backend parser checks lengths before total length arithmetic" {
  for length in [-2_147_483_648, -1, 0, 1, 2, 3, 2_147_483_647] {
    let prefix = Buffer()
    prefix.write_byte(b'd')
    prefix.write_int_be(length)
    try @backend.Message::parse(prefix.to_bytes()[:]) catch {
      @proto.ProtocolError::InvalidInput(_) => ()
      error => raise error
    } noraise {
      _ => fail("invalid backend length was accepted")
    }
  }
  let prefix = b"d\x7f\xff\xff\xfe"
  assert_true(@backend.Message::parse(prefix) is None)
  assert_true(
    @backend.Header::parse(prefix) is Some({ len: 2_147_483_646, .. }),
  )
  assert_true(@backend.Message::parse(b"1\x00\x00\x00\x04") is Some(_))
}
