///|
fn auth_sasl_body(
  mechanisms : Array[Bytes],
) -> @backend.AuthenticationSaslBody raise {
  let payload = @buffer.new()
  payload.write_int_be(10)
  for mechanism in mechanisms {
    payload.write_bytes(mechanism)
    payload.write_byte(b'\x00')
  }
  payload.write_byte(b'\x00')

  let packet = @buffer.new()
  packet.write_byte(@backend.AUTHENTICATION_TAG)
  packet.write_int_be(@proto.i32_from_usize(payload.length() + 4))
  packet.write_bytes(payload.to_bytes())

  match @backend.Message::parse(packet.to_bytes()[:]) {
    Some({ message: AuthenticationSasl(body), .. }) => body
    Some(_) => fail("expected AuthenticationSasl message")
    None => fail("expected complete AuthenticationSasl message")
  }
}

///|
test "choose_scram_binding uses SCRAM-SHA-256-PLUS with tls-server-end-point" {
  let body = auth_sasl_body([@auth.SCRAM_SHA_256_PLUS, @auth.SCRAM_SHA_256])
  let (mechanism, binding) = choose_scram_binding(
    body,
    Prefer,
    TlsServerEndPoint(b"binding"),
  )
  @debug.assert_eq(mechanism, @auth.SCRAM_SHA_256_PLUS)
  guard binding is @auth.ChannelBinding::TlsServerEndPoint(signature) else {
    fail("expected tls-server-end-point channel binding")
  }
  @debug.assert_eq(signature, b"binding")
}

///|
test "choose_scram_binding rejects required binding without tls signature" {
  let body = auth_sasl_body([@auth.SCRAM_SHA_256_PLUS, @auth.SCRAM_SHA_256])
  let result : Result[(Bytes, @auth.ChannelBinding), Error] = try? choose_scram_binding(
    body,
    Require,
    NoBinding,
  )
  guard result is Err(ClientError::Authentication(message)) else {
    fail("expected channel binding configuration error")
  }
  @debug.assert_eq(
    message, "channel binding requires TLS with tls-server-end-point support",
  )
}
