///|
test "SCRAM normalization preserves mapping and NFKC behavior" {
  let cases = [
    ("", ""),
    ("moonpass", "moonpass"),
    ("I\u{00AD}X", "IX"),
    ("moon\u{00A0}pass", "moon pass"),
    ("\u{2168}", "IX"),
    ("\u{FF21}\u{FB03}", "Affi"),
    ("e\u{0301}", "\u{00E9}"),
    ("\u{1D400}", "A"),
  ]
  for (input, expected) in cases {
    let normalized = @authentication.normalize(@utf8.encode(input))
    assert_eq(normalized, @utf8.encode(expected))
    assert_eq(@authentication.normalize(normalized), normalized)
  }
}

///|
test "SCRAM normalization rejects invalid UTF-8 and prohibited characters" {
  let error = @test.expect_error(() => @authentication.normalize(b"\xFF"))
  assert_true(error is @proto.ProtocolError::InvalidInput("invalid UTF-8"))
  for input in ["a\u{0007}b", "\u{E000}", "\u{FDD0}", "\u{206A}", "\u{E0001}"] {
    let error = @test.expect_error(() => {
      @authentication.normalize(@utf8.encode(input))
    })
    assert_true(
      error
      is @proto.ProtocolError::InvalidInput(
        "SCRAM password contains prohibited characters"
      ),
    )
  }
}
