///|
test "md5_hash" {
  let username = b"md5_user"
  let password = b"password"
  let salt = b"\x2a\x3d\x8f\xe0"
  let got = try! md5_hash(username, password, salt)
  assert_eq(got, b"md562af4dd09bbb41884907a838a3233294")
}

///|
test "md5_hash_invalid_salt_len" {
  let username = b"user"
  let password = b"password"
  let salt = b"\x2a\x3d\x8f"
  assert_true((try? md5_hash(username, password, salt)) is Err(_))
}
