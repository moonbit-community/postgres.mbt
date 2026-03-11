///|
test "exchange" {
  let password = b"foobar"
  let nonce = b"9IZ2O01zb9IgiIZ1WJ/zgpJB"
  let client_first = b"n,,n=,r=9IZ2O01zb9IgiIZ1WJ/zgpJB"
  let server_first = b"r=9IZ2O01zb9IgiIZ1WJ/zgpJBjx/oIRLs02gGSHcw1KEty3eY,s=fs3IXBy7U7+IvVjZ,i=4096"
  let client_final = b"c=biws,r=9IZ2O01zb9IgiIZ1WJ/zgpJBjx/oIRLs02gGSHcw1KEty3eY,p=AmNKosjJzS31NTlQYNs5BTeQjdHdk7lOflDo5re2an8="
  let server_final = b"v=U+ppxD5XUKtradnv8e2MkeupiA8FU87Sg8CXzXHDAzw="
  let scram = try! ScramSha256::new_inner(
    password,
    ChannelBinding::unsupported(),
    nonce,
  )
  assert_eq((try! scram.message()).to_bytes(), client_first)
  try! scram.update(server_first)
  assert_eq((try! scram.message()).to_bytes(), client_final)
  try! scram.finish(server_final)
}

///|
test "new_encodes_nonce_bytes" {
  let scram = try! ScramSha256::new(
    b"foobar",
    ChannelBinding::unsupported(),
    b"\x00\x01\x02",
  )
  assert_eq((try! scram.message()).to_bytes(), b"n,,n=,r=AAEC")
}

///|
test "new_inner_rejects_invalid_nonce" {
  let result = try? ScramSha256::new_inner(
    b"foobar",
    ChannelBinding::unsupported(),
    b"bad,nonce",
  )
  guard result is Err(@proto.ProtocolError::InvalidInput(_)) else {
    fail("expected invalid input")
  }
}

///|
test "normalize_maps_soft_hyphen_to_nothing" {
  assert_eq(try! normalize(b"I\xc2\xADX"), b"IX")
}

///|
test "normalize_maps_non_ascii_space_to_ascii_space" {
  assert_eq(try! normalize(b"a\xc2\xa0b"), b"a b")
}

///|
test "normalize_nfkc_compatibility_characters" {
  assert_eq(try! normalize(b"\xc2\xaa"), b"a")
  assert_eq(try! normalize(b"\xe2\x85\xa8"), b"IX")
}

///|
test "normalize_rejects_control_characters" {
  let result = try? normalize(b"foo\x07bar")
  guard result is Err(@proto.ProtocolError::InvalidInput(_)) else {
    fail("expected invalid input")
  }
}
