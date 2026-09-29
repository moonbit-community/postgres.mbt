///|
fn secure_random_bytes(num : Int) -> Bytes raise {
  if @env.rand(num) is Some(bytes) {
    bytes
  } else {
    raise Failure::Failure("failed to generate secure random bytes")
  }
}
