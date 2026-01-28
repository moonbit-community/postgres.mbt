///|
test "scram_sha_256_salt" {
  let salt = b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10"
  let got = scram_sha_256_salt(b"secret", salt)
  assert_eq(
    got, b"SCRAM-SHA-256$4096:AQIDBAUGBwgJCgsMDQ4PEA==$8rrDg00OqaiWXJ7p+sCgHEIaBSHY89ZJl3mfIsf32oY=:05L1f+yZbiN8O0AnO40Og85NNRhvzTS57naKRWCcsIA=",
  )
}

///|
test "md5_password" {
  let got = md5(b"secret", b"foo")
  assert_eq(got, b"md54ab2c5d00339c4b2a4e921d2dc4edec7")
}
