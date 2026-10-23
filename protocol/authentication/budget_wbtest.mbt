///|
fn budget_scram() -> ScramSha256 raise @proto.ProtocolError {
  ScramSha256::new_inner(
    b"pencil",
    ChannelBinding::unsupported(),
    b"rOprNGfwEbeRWgbNEkqO",
  )
}

///|
// Fixed transcript independently checked with Python hashlib.pbkdf2_hmac and
// hmac.digest. The empty PostgreSQL SCRAM username is included in auth_message.
test "SCRAM synchronous and incremental derivation match a fixed transcript" {
  let first = b"r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
  let expected_final = b"c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=qvT2SWdEH5Q06albL+hjSYuUhCG7VndFyzIb7CK4n9k="
  let verifier = b"v=3HO6Qt1M4MKJrmlKaoOqLAI0/0TV0HZe7J9H3MBtSOg="
  let synchronous = budget_scram()
  synchronous.update(first)
  assert_eq(synchronous.message().to_owned(), expected_final)
  synchronous.finish(verifier)
  let incremental = budget_scram()
  incremental.begin_update(first, max_iterations=4096)
  let mut batches = 1
  while !incremental.advance_update(max_steps=256) {
    batches += 1
  }
  assert_eq(batches, 17)
  assert_eq(incremental.message().to_owned(), expected_final)
  incremental.finish(verifier)
  assert_true(
    @test.expect_error(() => incremental.message())
    is @proto.ProtocolError::InvalidInput(_),
  )
}

///|
test "PBKDF2 Hi matches fixed vectors and rejects nonpositive iterations" {
  // First block of RFC 7914 section 11's passwd/salt/c=1 vector:
  // https://www.rfc-editor.org/rfc/rfc7914#section-11
  assert_eq(
    hi(b"passwd", b"salt", 1),
    b"\x55\xac\x04\x6e\x56\xe3\x08\x9f\xec\x16\x91\xc2\x25\x44\xb6\x05\xf9\x41\x85\x21\x6d\xde\x04\x65\xe6\x8b\x9d\x57\xc2\x0d\xac\xbc",
  )
  assert_eq(
    hi(b"password", b"salt", 2),
    b"\xae\x4d\x0c\x95\xaf\x6b\x46\xd3\x2d\x0a\xdf\xf9\x28\xf0\x6d\xd0\x2a\x30\x3f\x8e\xf3\xc2\x51\xdf\xd6\xe2\xd8\x5a\x95\x47\x4c\x43",
  )
  assert_eq(
    hi(b"password", b"salt", 4096),
    b"\xc5\xe4\x78\xd5\x92\x88\xc8\x41\xaa\x53\x0d\xb6\x84\x5c\x4c\x8d\x96\x28\x93\xa0\x01\xce\x4e\x11\xa4\x96\x38\x73\xaa\x98\x13\x4a",
  )
  for count in [0, -1] {
    assert_true(
      @test.expect_error(() => hi(b"password", b"salt", count))
      is @proto.ProtocolError::InvalidInput(_),
    )
  }
}

///|
test "SCRAM iteration parser rejects invalid decimal input and overflow before derivation" {
  for
    count in [
      "", "0", "000", "-1", "+1", "1a", "2147483648", "4294967297", "9999999999999999999999999",
      "100001",
    ] {
    let scram = budget_scram()
    let initial = scram.message().to_owned()
    let first = @proto.utf8_encode(
      "r=rOprNGfwEbeRWgbNEkqOserver,s=c2FsdA==,i=\{count}",
    )
    assert_true(
      @test.expect_error(() => scram.update(first))
      is @proto.ProtocolError::InvalidInput(_),
    )
    assert_eq(scram.message().to_owned(), initial)
    assert_true(scram.state is Update(..))
  }
  for
    (count, limit) in [
      (100_000, 100_000),
      (100_001, 100_001),
      (2_147_483_647, 2_147_483_647),
    ] {
    let scram = budget_scram()
    scram.begin_update(
      @proto.utf8_encode("r=rOprNGfwEbeRWgbNEkqOserver,s=c2FsdA==,i=\{count}"),
      max_iterations=limit,
    )
    guard scram.state is Deriving(progress) else { fail("expected derivation") }
    assert_eq(progress.hi.remaining, count)
  }
  for limit in [0, -1] {
    assert_true(
      @test.expect_error(() => {
        budget_scram().update(
          b"r=rOprNGfwEbeRWgbNEkqOserver,s=c2FsdA==,i=1",
          max_iterations=limit,
        )
      })
      is @proto.ProtocolError::InvalidInput(_),
    )
  }
}

///|
test "SCRAM batches include proof HMACs and hide incomplete state" {
  for count in [1, 254, 255, 256, 257, 510, 511, 512, 513] {
    for steps in [1, 256] {
      let first = @proto.utf8_encode(
        "r=rOprNGfwEbeRWgbNEkqOserver,s=c2FsdA==,i=\{count}",
      )
      let scram = budget_scram()
      assert_true(
        @test.expect_error(() => scram.advance_update(max_steps=steps))
        is @proto.ProtocolError::InvalidInput(_),
      )
      scram.begin_update(first, max_iterations=count)
      assert_true(
        @test.expect_error(() => scram.message())
        is @proto.ProtocolError::InvalidInput(_),
      )
      assert_true(
        @test.expect_error(() => scram.update(first))
        is @proto.ProtocolError::InvalidInput(_),
      )
      assert_true(
        @test.expect_error(() => scram.begin_update(first, max_iterations=count))
        is @proto.ProtocolError::InvalidInput(_),
      )
      assert_true(
        @test.expect_error(() => scram.finish(b"v="))
        is @proto.ProtocolError::InvalidInput(_),
      )
      for invalid in [0, -1] {
        assert_true(
          @test.expect_error(() => scram.advance_update(max_steps=invalid))
          is @proto.ProtocolError::InvalidInput(_),
        )
      }
      let mut calls = 1
      while !scram.advance_update(max_steps=steps) {
        calls += 1
        assert_true(
          @test.expect_error(() => scram.message())
          is @proto.ProtocolError::InvalidInput(_),
        )
      }
      assert_eq(calls, (count + 2 + steps - 1) / steps)
      let synchronous = budget_scram()
      synchronous.update(first, max_iterations=count)
      assert_eq(scram.message().to_owned(), synchronous.message().to_owned())
    }
  }
}
