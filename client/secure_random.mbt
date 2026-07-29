///|
fn secure_random_bytes(num : Int) -> Bytes raise {
  match @env.rand(num) {
    Some(bytes) => bytes
    None => raise Failure::Failure("failed to generate secure random bytes")
  }
}
