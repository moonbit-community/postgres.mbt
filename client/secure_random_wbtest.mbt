///|
test "secure_random_bytes returns requested length" {
  let bytes = secure_random_bytes(18)
  @debug.assert_eq(bytes.length(), 18)
}
